import AetherRouteKit
import Foundation

public protocol AppleTCPFlowAccess: Sendable {
    /// One raw NetworkExtension read. The OS API has no caller-supplied size
    /// limit, so the adapter below owns bounded staging and chunking.
    func readData(
        completion: @escaping @Sendable (
            Result<Data?, FlowIOError>
        ) -> Void
    )

    func writeData(
        _ data: Data,
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    )

    func finishWriting()
    func cancel()
    func cancelAndDrain(completion: @escaping @Sendable () -> Void)
}

public extension AppleTCPFlowAccess {
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        cancel()
        completion()
    }
}

public protocol AppleUDPFlowAccess: Sendable {
    /// One raw NetworkExtension batch read. Production implementations convert
    /// every returned NWEndpoint before invoking the completion.
    func readDatagrams(
        completion: @escaping @Sendable (
            Result<[UDPDatagram]?, FlowIOError>
        ) -> Void
    )

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    )

    func cancel()
    func cancelAndDrain(completion: @escaping @Sendable () -> Void)
}

public extension AppleUDPFlowAccess {
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        cancel()
        completion()
    }
}

public enum FlowStagingMemoryBudgetError: Error, Sendable, Equatable {
    case invalidMaximumBytes
}

/// A process-wide accounting boundary for bytes retained between Apple flow
/// callbacks. Per-flow limits alone are insufficient: thousands of otherwise
/// valid flows could collectively exhaust an extension process.
public final class FlowStagingMemoryBudget: @unchecked Sendable {
    public static let defaultMaximumBytes = 64 * 1_024 * 1_024

    /// Production adapters share one bounded pool. Tests may inject a smaller
    /// independent pool to exercise exhaustion deterministically.
    public static let shared = FlowStagingMemoryBudget(
        validatedMaximumBytes: defaultMaximumBytes
    )

    private let maximumBytes: Int
    private let lock = NSLock()
    private var reservedBytes = 0

    public convenience init(maximumBytes: Int) throws {
        guard maximumBytes > 0 else {
            throw FlowStagingMemoryBudgetError.invalidMaximumBytes
        }
        self.init(validatedMaximumBytes: maximumBytes)
    }

    private init(validatedMaximumBytes: Int) {
        maximumBytes = validatedMaximumBytes
    }

    public var currentReservedBytes: Int {
        lock.withLock { reservedBytes }
    }

    fileprivate func reserve(_ bytes: Int) -> Bool {
        guard bytes >= 0 else { return false }
        guard bytes > 0 else { return true }
        return lock.withLock {
            guard bytes <= maximumBytes - reservedBytes else { return false }
            reservedBytes += bytes
            return true
        }
    }

    fileprivate func release(_ bytes: Int) {
        guard bytes > 0 else { return }
        lock.withLock {
            // Every release is paired with an adapter-owned reservation. Keep
            // the existing charge if a future caller violates that invariant;
            // clearing other flows' reservations would fail open.
            guard bytes <= reservedBytes else { return }
            reservedBytes -= bytes
        }
    }
}

/// Bounded adapter for `NEAppProxyTCPFlow.readData`. A single OS read may be
/// larger than the state-machine request; it is retained only up to the hard
/// staging ceiling and emitted in policy-sized chunks without another OS read.
public final class BoundedAppleTCPFlowAdapter:
    TransparentTCPFlowIO,
    @unchecked Sendable
{
    public static let defaultMaximumStagingBytes = 1_024 * 1_024

    private let access: any AppleTCPFlowAccess
    private let maximumStagingBytes: Int
    private let stagingBudget: FlowStagingMemoryBudget
    private let lock = NSLock()
    private var staged = Data()
    private var reservedStagingBytes = 0
    private var nextOperationID: UInt64 = 0
    private var pendingReadID: UInt64?
    private var pendingWriteID: UInt64?
    private var cancelled = false
    private var nativeDrainFinished = false
    private var drainCompletions: [@Sendable () -> Void] = []

    public init(
        access: any AppleTCPFlowAccess,
        maximumStagingBytes: Int = defaultMaximumStagingBytes,
        stagingBudget: FlowStagingMemoryBudget = .shared
    ) throws {
        guard
            (1...TCPFlowStateMachine.hardMaximumReadBytes)
                .contains(maximumStagingBytes)
        else {
            throw FlowStateMachineConfigurationError.invalidMaximumReadBytes(
                maximumStagingBytes
            )
        }
        self.access = access
        self.maximumStagingBytes = maximumStagingBytes
        self.stagingBudget = stagingBudget
    }

    deinit {
        stagingBudget.release(lock.withLock {
            let bytes = reservedStagingBytes
            reservedStagingBytes = 0
            staged.removeAll(keepingCapacity: false)
            return bytes
        })
    }

    public func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            completion(token, .failure(.cancelled))
            return
        }
        guard (1...maximumStagingBytes).contains(maximumBytes) else {
            lock.unlock()
            completion(
                token,
                .failure(.invalidData("Invalid Apple TCP read policy"))
            )
            return
        }
        guard pendingReadID == nil else {
            lock.unlock()
            completion(
                token,
                .failure(.invalidData("Overlapping Apple TCP read"))
            )
            return
        }
        if !staged.isEmpty {
            let count = min(maximumBytes, staged.count)
            let data = Data(staged.prefix(count))
            staged.removeFirst(count)
            reservedStagingBytes -= count
            lock.unlock()
            stagingBudget.release(count)
            completion(token, .success(.bytes(data)))
            return
        }
        let operationID = makeOperationIDLocked()
        pendingReadID = operationID
        lock.unlock()

        access.readData { [self] result in
            completeRead(
                result,
                operationID: operationID,
                maximumBytes: maximumBytes,
                token: token,
                completion: completion
            )
        }
    }

    public func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        guard !data.isEmpty, data.count <= maximumStagingBytes else {
            completion(
                token,
                .failure(.invalidData("Invalid Apple TCP write size"))
            )
            return
        }
        guard case let .success(operationID) = beginWrite() else {
            completion(token, .failure(writeRejection()))
            return
        }
        access.writeData(data) { [self] result in
            completeWrite(
                result,
                operationID: operationID,
                token: token,
                completion: completion
            )
        }
    }

    public func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        guard case let .success(operationID) = beginWrite() else {
            completion(token, .failure(writeRejection()))
            return
        }
        access.finishWriting()
        completeWrite(
            .success(()),
            operationID: operationID,
            token: token,
            completion: completion
        )
    }

    public func cancel() {
        cancelAndDrain {}
    }

    public func cancelAndDrain(
        completion: @escaping @Sendable () -> Void
    ) {
        let action = lock.withLock { () -> CancelAction in
            if nativeDrainFinished {
                return .complete(completion)
            }
            drainCompletions.append(completion)
            guard !cancelled else { return .none }
            cancelled = true
            pendingReadID = nil
            pendingWriteID = nil
            let bytes = reservedStagingBytes
            reservedStagingBytes = 0
            staged.removeAll(keepingCapacity: false)
            return .start(bytesToRelease: bytes)
        }

        switch action {
        case .none:
            break
        case let .complete(completion):
            completion()
        case let .start(bytes):
            stagingBudget.release(bytes)
            access.cancelAndDrain { [self] in
                nativeDrainCompleted()
            }
        }
    }

    private func completeRead(
        _ result: Result<Data?, FlowIOError>,
        operationID: UInt64,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: TCPReadCompletion
    ) {
        lock.lock()
        guard pendingReadID == operationID else {
            lock.unlock()
            return
        }
        pendingReadID = nil
        if cancelled {
            lock.unlock()
            completion(token, .failure(.cancelled))
            return
        }

        switch result {
        case let .failure(error):
            lock.unlock()
            completion(token, .failure(error))
        case let .success(data):
            guard let data, !data.isEmpty else {
                lock.unlock()
                completion(token, .success(.endOfStream))
                return
            }
            // NetworkExtension has already allocated this raw Data value. Do
            // not create prefix/remainder copies until its full size passes
            // the adapter's hard staging ceiling.
            guard data.count <= maximumStagingBytes else {
                lock.unlock()
                completion(
                    token,
                    .failure(.invalidData("Apple TCP staging limit exceeded"))
                )
                return
            }
            let count = min(maximumBytes, data.count)
            let output = Data(data.prefix(count))
            let remainderBytes = data.count - count
            guard stagingBudget.reserve(remainderBytes) else {
                lock.unlock()
                completion(
                    token,
                    .failure(.invalidData("Apple TCP global staging budget exceeded"))
                )
                return
            }
            staged = Data(data.dropFirst(count))
            reservedStagingBytes = remainderBytes
            lock.unlock()
            completion(token, .success(.bytes(output)))
        }
    }

    private func beginWrite() -> Result<UInt64, FlowIOError> {
        lock.withLock {
            guard !cancelled else { return .failure(.cancelled) }
            guard pendingWriteID == nil else {
                return .failure(.invalidData("Overlapping Apple TCP write"))
            }
            let operationID = makeOperationIDLocked()
            pendingWriteID = operationID
            return .success(operationID)
        }
    }

    private func completeWrite(
        _ result: Result<Void, FlowIOError>,
        operationID: UInt64,
        token: FlowOperationToken,
        completion: TCPWriteCompletion
    ) {
        lock.lock()
        guard pendingWriteID == operationID else {
            lock.unlock()
            return
        }
        pendingWriteID = nil
        let result: Result<Void, FlowIOError> = cancelled
            ? .failure(.cancelled)
            : result
        lock.unlock()
        completion(token, result)
    }

    private func writeRejection() -> FlowIOError {
        lock.withLock {
            cancelled
                ? .cancelled
                : .invalidData("Overlapping Apple TCP write")
        }
    }

    private func makeOperationIDLocked() -> UInt64 {
        nextOperationID &+= 1
        return nextOperationID
    }

    private func nativeDrainCompleted() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            guard !nativeDrainFinished else { return [] }
            nativeDrainFinished = true
            defer { drainCompletions.removeAll(keepingCapacity: false) }
            return drainCompletions
        }
        completions.forEach { $0() }
    }

    private enum CancelAction {
        case none
        case start(bytesToRelease: Int)
        case complete(@Sendable () -> Void)
    }
}

/// Bounded batch adapter for `NEAppProxyUDPFlow`. It may stage a larger raw OS
/// batch, but never splits a datagram and never retains more than the explicit
/// hard count/byte ceilings.
public final class BoundedAppleUDPFlowAdapter:
    TransparentUDPFlowIO,
    @unchecked Sendable
{
    public static let defaultMaximumStagingDatagrams = 256
    public static let defaultMaximumStagingBytes = 4 * 1_024 * 1_024

    private let access: any AppleUDPFlowAccess
    private let maximumStagingDatagrams: Int
    private let maximumStagingBytes: Int
    private let stagingBudget: FlowStagingMemoryBudget
    private let lock = NSLock()
    private var staged: [UDPDatagram] = []
    private var reservedStagingBytes = 0
    private var nextOperationID: UInt64 = 0
    private var pendingReadID: UInt64?
    private var pendingWriteID: UInt64?
    private var cancelled = false
    private var nativeDrainFinished = false
    private var drainCompletions: [@Sendable () -> Void] = []

    public init(
        access: any AppleUDPFlowAccess,
        maximumStagingDatagrams: Int = defaultMaximumStagingDatagrams,
        maximumStagingBytes: Int = defaultMaximumStagingBytes,
        stagingBudget: FlowStagingMemoryBudget = .shared
    ) throws {
        guard
            (1...Self.defaultMaximumStagingDatagrams)
                .contains(maximumStagingDatagrams),
            (1...Self.defaultMaximumStagingBytes).contains(maximumStagingBytes)
        else {
            throw FlowStateMachineConfigurationError.invalidMaximumBatchBytes(
                maximumStagingBytes
            )
        }
        self.access = access
        self.maximumStagingDatagrams = maximumStagingDatagrams
        self.maximumStagingBytes = maximumStagingBytes
        self.stagingBudget = stagingBudget
    }

    deinit {
        stagingBudget.release(lock.withLock {
            let bytes = reservedStagingBytes
            reservedStagingBytes = 0
            staged.removeAll(keepingCapacity: false)
            return bytes
        })
    }

    public func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {
        lock.lock()
        if cancelled {
            lock.unlock()
            completion(token, .failure(.cancelled))
            return
        }
        guard
            (1...UDPBatchPolicy.maximumDatagrams).contains(maximumDatagrams),
            (1...UDPBatchPolicy.maximumBatchBytes).contains(maximumBytes)
        else {
            lock.unlock()
            completion(
                token,
                .failure(.invalidData("Invalid Apple UDP read policy"))
            )
            return
        }
        guard pendingReadID == nil else {
            lock.unlock()
            completion(
                token,
                .failure(.invalidData("Overlapping Apple UDP read"))
            )
            return
        }
        if !staged.isEmpty {
            let batch = takeStaged(
                maximumDatagrams: maximumDatagrams,
                maximumBytes: maximumBytes
            )
            let releasedBytes = batch.reduce(into: 0) {
                $0 += $1.payload.count
            }
            reservedStagingBytes -= releasedBytes
            lock.unlock()
            stagingBudget.release(releasedBytes)
            completion(token, .success(.datagrams(batch)))
            return
        }
        let operationID = makeOperationIDLocked()
        pendingReadID = operationID
        lock.unlock()

        access.readDatagrams { [self] result in
            completeRead(
                result,
                operationID: operationID,
                maximumDatagrams: maximumDatagrams,
                maximumBytes: maximumBytes,
                token: token,
                completion: completion
            )
        }
    }

    public func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {
        do {
            try UDPBatchValidator.validate(datagrams)
        } catch {
            completion(
                token,
                .failure(.invalidData("Invalid Apple UDP write batch"))
            )
            return
        }
        lock.lock()
        guard !cancelled, pendingWriteID == nil else {
            let error: FlowIOError = cancelled
                ? .cancelled
                : .invalidData("Overlapping Apple UDP write")
            lock.unlock()
            completion(token, .failure(error))
            return
        }
        let operationID = makeOperationIDLocked()
        pendingWriteID = operationID
        lock.unlock()

        access.writeDatagrams(datagrams) { [self] result in
            lock.lock()
            guard pendingWriteID == operationID else {
                lock.unlock()
                return
            }
            pendingWriteID = nil
            let result: Result<Void, FlowIOError> = cancelled
                ? .failure(.cancelled)
                : result
            lock.unlock()
            completion(token, result)
        }
    }

    public func cancel() {
        cancelAndDrain {}
    }

    public func cancelAndDrain(
        completion: @escaping @Sendable () -> Void
    ) {
        let action = lock.withLock { () -> CancelAction in
            if nativeDrainFinished {
                return .complete(completion)
            }
            drainCompletions.append(completion)
            guard !cancelled else { return .none }
            cancelled = true
            pendingReadID = nil
            pendingWriteID = nil
            let bytes = reservedStagingBytes
            reservedStagingBytes = 0
            staged.removeAll(keepingCapacity: false)
            return .start(bytesToRelease: bytes)
        }

        switch action {
        case .none:
            break
        case let .complete(completion):
            completion()
        case let .start(bytes):
            stagingBudget.release(bytes)
            access.cancelAndDrain { [self] in
                nativeDrainCompleted()
            }
        }
    }

    private func completeRead(
        _ result: Result<[UDPDatagram]?, FlowIOError>,
        operationID: UInt64,
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: UDPReadCompletion
    ) {
        lock.lock()
        guard pendingReadID == operationID else {
            lock.unlock()
            return
        }
        pendingReadID = nil
        if cancelled {
            lock.unlock()
            completion(token, .failure(.cancelled))
            return
        }
        switch result {
        case let .failure(error):
            lock.unlock()
            completion(token, .failure(error))
        case let .success(datagrams):
            guard let datagrams, !datagrams.isEmpty else {
                lock.unlock()
                completion(token, .success(.endOfStream))
                return
            }
            guard validateRawBatch(datagrams) else {
                lock.unlock()
                completion(
                    token,
                    .failure(.invalidData("Apple UDP staging limit exceeded"))
                )
                return
            }
            let rawBytes = datagrams.reduce(into: 0) {
                $0 += $1.payload.count
            }
            guard stagingBudget.reserve(rawBytes) else {
                lock.unlock()
                completion(
                    token,
                    .failure(.invalidData("Apple UDP global staging budget exceeded"))
                )
                return
            }
            staged = datagrams
            reservedStagingBytes = rawBytes
            let batch = takeStaged(
                maximumDatagrams: maximumDatagrams,
                maximumBytes: maximumBytes
            )
            let releasedBytes = batch.reduce(into: 0) {
                $0 += $1.payload.count
            }
            reservedStagingBytes -= releasedBytes
            lock.unlock()
            stagingBudget.release(releasedBytes)
            completion(token, .success(.datagrams(batch)))
        }
    }

    private func validateRawBatch(_ datagrams: [UDPDatagram]) -> Bool {
        guard datagrams.count <= maximumStagingDatagrams else { return false }
        var total = 0
        for datagram in datagrams {
            guard
                datagram.payload.count <= UDPBatchPolicy.maximumPayloadBytes,
                datagram.remoteEndpoint.transport == .udp,
                (try? datagram.remoteEndpoint.validated()) != nil,
                datagram.payload.count <= maximumStagingBytes - total
            else {
                return false
            }
            total += datagram.payload.count
        }
        return true
    }

    /// Caller holds `lock` and `staged` is non-empty. The configured state
    /// machine byte ceiling is larger than one legal UDP payload, so progress
    /// is always possible without splitting a datagram.
    private func takeStaged(
        maximumDatagrams: Int,
        maximumBytes: Int
    ) -> [UDPDatagram] {
        var count = 0
        var bytes = 0
        while count < staged.count, count < maximumDatagrams {
            let next = staged[count].payload.count
            if next > maximumBytes - bytes { break }
            bytes += next
            count += 1
        }
        let batch = Array(staged.prefix(count))
        staged.removeFirst(count)
        return batch
    }

    private func makeOperationIDLocked() -> UInt64 {
        nextOperationID &+= 1
        return nextOperationID
    }

    private func nativeDrainCompleted() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            guard !nativeDrainFinished else { return [] }
            nativeDrainFinished = true
            defer { drainCompletions.removeAll(keepingCapacity: false) }
            return drainCompletions
        }
        completions.forEach { $0() }
    }

    private enum CancelAction {
        case none
        case start(bytesToRelease: Int)
        case complete(@Sendable () -> Void)
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

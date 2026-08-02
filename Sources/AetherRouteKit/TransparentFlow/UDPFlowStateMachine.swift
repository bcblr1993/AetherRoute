import Foundation

public struct UDPDatagram: Sendable, Equatable {
    public let payload: Data
    public let remoteEndpoint: FlowEndpoint

    public init(payload: Data, remoteEndpoint: FlowEndpoint) {
        self.payload = payload
        self.remoteEndpoint = remoteEndpoint
    }
}

public struct UDPBatchPolicy: Sendable, Equatable {
    public static let maximumDatagrams = 64
    public static let maximumBatchBytes = 1_024 * 1_024
    public static let maximumPayloadBytes = 65_507
    public static let strict = UDPBatchPolicy(
        maximumDatagrams: maximumDatagrams,
        maximumBatchBytes: maximumBatchBytes
    )

    public let maximumDatagrams: Int
    public let maximumBatchBytes: Int

    public init(
        maximumDatagrams: Int,
        maximumBatchBytes: Int
    ) {
        self.maximumDatagrams = maximumDatagrams
        self.maximumBatchBytes = maximumBatchBytes
    }

    @discardableResult
    public func validated() throws -> UDPBatchPolicy {
        guard (1...Self.maximumDatagrams).contains(maximumDatagrams) else {
            throw FlowStateMachineConfigurationError.invalidMaximumDatagrams(
                maximumDatagrams
            )
        }
        guard (1...Self.maximumBatchBytes).contains(maximumBatchBytes) else {
            throw FlowStateMachineConfigurationError.invalidMaximumBatchBytes(
                maximumBatchBytes
            )
        }
        return self
    }
}

public enum UDPBatchValidationError: Error, Sendable, Equatable {
    case emptyBatch
    case tooManyDatagrams(Int)
    case payloadTooLarge(index: Int, bytes: Int)
    case batchTooLarge(Int)
    case nonUDPRemoteEndpoint(index: Int)
    case invalidRemoteEndpoint(index: Int)
}

public enum UDPBatchValidator {
    public static func validate(
        _ datagrams: [UDPDatagram],
        policy: UDPBatchPolicy = .strict
    ) throws {
        try policy.validated()
        guard !datagrams.isEmpty else {
            throw UDPBatchValidationError.emptyBatch
        }
        guard datagrams.count <= policy.maximumDatagrams else {
            throw UDPBatchValidationError.tooManyDatagrams(datagrams.count)
        }

        var aggregateBytes = 0
        for (index, datagram) in datagrams.enumerated() {
            guard datagram.payload.count <= UDPBatchPolicy.maximumPayloadBytes else {
                throw UDPBatchValidationError.payloadTooLarge(
                    index: index,
                    bytes: datagram.payload.count
                )
            }
            guard datagram.remoteEndpoint.transport == .udp else {
                throw UDPBatchValidationError.nonUDPRemoteEndpoint(index: index)
            }
            do {
                try datagram.remoteEndpoint.validated()
            } catch {
                throw UDPBatchValidationError.invalidRemoteEndpoint(index: index)
            }
            guard
                datagram.payload.count
                    <= policy.maximumBatchBytes - aggregateBytes
            else {
                throw UDPBatchValidationError.batchTooLarge(
                    aggregateBytes + datagram.payload.count
                )
            }
            aggregateBytes += datagram.payload.count
        }
    }
}

public enum UDPReadResult: Sendable, Equatable {
    case datagrams([UDPDatagram])
    case endOfStream
}

public typealias UDPReadCompletion = @Sendable (
    FlowOperationToken,
    Result<UDPReadResult, FlowIOError>
) -> Void

public typealias UDPWriteCompletion = @Sendable (
    FlowOperationToken,
    Result<Void, FlowIOError>
) -> Void

public protocol TransparentUDPFlowIO: Sendable {
    /// The limits are the bridge policy, not an OS-level read cap. A
    /// NetworkExtension adapter must pass through the delivered datagrams and
    /// let the state machine reject any oversized batch before Rust sees it.
    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    )

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    )

    func cancel()

    /// Completion is a callback barrier for the native Apple flow: all close
    /// calls have run and every accepted raw read/write callback has returned.
    func cancelAndDrain(completion: @escaping @Sendable () -> Void)
}

public extension TransparentUDPFlowIO {
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        cancel()
        completion()
    }
}

/// Rust-to-Swift datagram source abstraction. No FFI is linked in phase 1.
public protocol RustUDPSource: AnyObject, Sendable {
    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    )

    func cancel()
}

/// Swift-to-Rust datagram sink abstraction. No FFI is linked in phase 1.
public protocol RustUDPSink: AnyObject, Sendable {
    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    )

    func cancel()
}

public struct UDPFlowSnapshot: Sendable, Equatable {
    public let lifecycle: FlowLifecycle
    public let inFlight: Set<FlowOperationKind>
}

/// Bidirectional UDP batch pump. Each source observes backpressure from its
/// destination: another batch is not read until the current write completes.
public actor UDPFlowStateMachine {
    private let flow: any TransparentUDPFlowIO
    private let bridgeSource: any RustUDPSource
    private let bridgeSink: any RustUDPSink
    private let bridgeSourceAndSinkShareIdentity: Bool
    private let policy: UDPBatchPolicy
    private let onTermination: FlowTerminationHandler
    private let sessionID = UUID()

    private var lifecycle: FlowLifecycle = .idle
    private var sequence: UInt64 = 0
    private var flowReadToken: FlowOperationToken?
    private var flowWriteToken: FlowOperationToken?
    private var bridgeReadToken: FlowOperationToken?
    private var bridgeWriteToken: FlowOperationToken?
    private var didReportTermination = false

    public init(
        flow: any TransparentUDPFlowIO,
        bridgeSource: any RustUDPSource,
        bridgeSink: any RustUDPSink,
        policy: UDPBatchPolicy = .strict,
        onTermination: @escaping FlowTerminationHandler = { _ in }
    ) throws {
        self.flow = flow
        self.bridgeSource = bridgeSource
        self.bridgeSink = bridgeSink
        self.bridgeSourceAndSinkShareIdentity =
            ObjectIdentifier(bridgeSource) == ObjectIdentifier(bridgeSink)
        self.policy = try policy.validated()
        self.onTermination = onTermination
    }

    public func start() throws {
        guard lifecycle == .idle else {
            throw FlowStateMachineStartError.alreadyStarted
        }
        lifecycle = .running
        issueFlowRead()
        issueBridgeRead()
    }

    public func cancel() {
        guard lifecycle == .idle || lifecycle == .running else {
            return
        }
        lifecycle = .cancelled
        invalidateOperations()
        cancelTransports()
        reportTermination()
    }

    public func snapshot() -> UDPFlowSnapshot {
        let tokens = [
            flowReadToken,
            flowWriteToken,
            bridgeReadToken,
            bridgeWriteToken,
        ]
        return UDPFlowSnapshot(
            lifecycle: lifecycle,
            inFlight: Set(tokens.compactMap(\.?.kind))
        )
    }

    private func nextToken(_ kind: FlowOperationKind) -> FlowOperationToken {
        sequence &+= 1
        return FlowOperationToken(
            sessionID: sessionID,
            sequence: sequence,
            kind: kind
        )
    }

    private func issueFlowRead() {
        guard lifecycle == .running, flowReadToken == nil else {
            return
        }
        let token = nextToken(.flowRead)
        flowReadToken = token
        flow.readDatagrams(
            maximumDatagrams: policy.maximumDatagrams,
            maximumBytes: policy.maximumBatchBytes,
            token: token
        ) { [weak self] returnedToken, result in
            Task {
                await self?.completeFlowRead(returnedToken, result: result)
            }
        }
    }

    private func issueBridgeRead() {
        guard lifecycle == .running, bridgeReadToken == nil else {
            return
        }
        let token = nextToken(.bridgeRead)
        bridgeReadToken = token
        bridgeSource.readDatagrams(
            maximumDatagrams: policy.maximumDatagrams,
            maximumBytes: policy.maximumBatchBytes,
            token: token
        ) { [weak self] returnedToken, result in
            Task {
                await self?.completeBridgeRead(returnedToken, result: result)
            }
        }
    }

    private func completeFlowRead(
        _ token: FlowOperationToken,
        result: Result<UDPReadResult, FlowIOError>
    ) {
        guard lifecycle == .running, flowReadToken == token else {
            return
        }
        flowReadToken = nil
        switch result {
        case let .failure(error):
            fail(error)
        case .success(.endOfStream):
            finish()
        case let .success(.datagrams(datagrams)):
            guard validate(datagrams) else { return }
            issueBridgeWrite(datagrams)
        }
    }

    private func completeBridgeRead(
        _ token: FlowOperationToken,
        result: Result<UDPReadResult, FlowIOError>
    ) {
        guard lifecycle == .running, bridgeReadToken == token else {
            return
        }
        bridgeReadToken = nil
        switch result {
        case let .failure(error):
            fail(error)
        case .success(.endOfStream):
            finish()
        case let .success(.datagrams(datagrams)):
            guard validate(datagrams) else { return }
            issueFlowWrite(datagrams)
        }
    }

    private func validate(_ datagrams: [UDPDatagram]) -> Bool {
        do {
            try UDPBatchValidator.validate(datagrams, policy: policy)
            return true
        } catch {
            fail(.invalidData("UDP batch violates bounded flow policy"))
            return false
        }
    }

    private func issueBridgeWrite(_ datagrams: [UDPDatagram]) {
        guard lifecycle == .running, bridgeWriteToken == nil else {
            fail(.invalidData("Overlapping UDP bridge write"))
            return
        }
        let token = nextToken(.bridgeWrite)
        bridgeWriteToken = token
        bridgeSink.writeDatagrams(datagrams, token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeBridgeWrite(returnedToken, result: result)
            }
        }
    }

    private func completeBridgeWrite(
        _ token: FlowOperationToken,
        result: Result<Void, FlowIOError>
    ) {
        guard lifecycle == .running, bridgeWriteToken == token else {
            return
        }
        bridgeWriteToken = nil
        switch result {
        case let .failure(error):
            fail(error)
        case .success:
            issueFlowRead()
        }
    }

    private func issueFlowWrite(_ datagrams: [UDPDatagram]) {
        guard lifecycle == .running, flowWriteToken == nil else {
            fail(.invalidData("Overlapping UDP flow write"))
            return
        }
        let token = nextToken(.flowWrite)
        flowWriteToken = token
        flow.writeDatagrams(datagrams, token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeFlowWrite(returnedToken, result: result)
            }
        }
    }

    private func completeFlowWrite(
        _ token: FlowOperationToken,
        result: Result<Void, FlowIOError>
    ) {
        guard lifecycle == .running, flowWriteToken == token else {
            return
        }
        flowWriteToken = nil
        switch result {
        case let .failure(error):
            fail(error)
        case .success:
            issueBridgeRead()
        }
    }

    private func finish() {
        guard lifecycle == .running else { return }
        lifecycle = .finished
        invalidateOperations()
        cancelTransports()
        reportTermination()
    }

    private func fail(_ error: FlowIOError) {
        guard lifecycle == .running else { return }
        lifecycle = .failed(error)
        invalidateOperations()
        cancelTransports()
        reportTermination()
    }

    private func invalidateOperations() {
        flowReadToken = nil
        flowWriteToken = nil
        bridgeReadToken = nil
        bridgeWriteToken = nil
    }

    private func cancelTransports() {
        flow.cancel()
        bridgeSource.cancel()
        if !bridgeSourceAndSinkShareIdentity {
            bridgeSink.cancel()
        }
    }

    private func reportTermination() {
        guard !didReportTermination else { return }
        didReportTermination = true
        onTermination(lifecycle)
    }
}

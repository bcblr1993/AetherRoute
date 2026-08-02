import AetherRouteKit
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class AppleFlowAdapterTests: XCTestCase, @unchecked Sendable {
    func testTCPStagesOversizedOSReadIntoBoundedChunks() async throws {
        let access = StubAppleTCPFlowAccess()
        let adapter = try BoundedAppleTCPFlowAdapter(
            access: access,
            maximumStagingBytes: 16
        )
        access.nextRead = .success(Data((0..<10).map(UInt8.init)))

        let first = await readTCP(adapter, maximumBytes: 4, sequence: 1)
        let second = await readTCP(adapter, maximumBytes: 4, sequence: 2)
        let third = await readTCP(adapter, maximumBytes: 4, sequence: 3)

        XCTAssertEqual(try bytes(first), Data((0..<4).map(UInt8.init)))
        XCTAssertEqual(try bytes(second), Data((4..<8).map(UInt8.init)))
        XCTAssertEqual(try bytes(third), Data((8..<10).map(UInt8.init)))
        XCTAssertEqual(access.readCallCount, 1)
    }

    func testTCPRejectsRawReadBeyondAbsoluteStagingLimit() async throws {
        let access = StubAppleTCPFlowAccess()
        let adapter = try BoundedAppleTCPFlowAdapter(
            access: access,
            maximumStagingBytes: 8
        )
        access.nextRead = .success(Data(repeating: 1, count: 9))

        let result = await readTCP(adapter, maximumBytes: 4, sequence: 1)
        XCTAssertEqual(
            result,
            .failure(.invalidData("Apple TCP staging limit exceeded"))
        )
    }

    func testUDPStagesLargeOSBatchWithoutSplittingDatagrams() async throws {
        let access = StubAppleUDPFlowAccess()
        let adapter = try BoundedAppleUDPFlowAdapter(
            access: access,
            maximumStagingDatagrams: 100,
            maximumStagingBytes: 1_024
        )
        access.nextRead = .success(
            (0..<70).map { datagram(byte: UInt8($0)) }
        )

        let first = await readUDP(
            adapter,
            maximumDatagrams: 64,
            maximumBytes: 1_024,
            sequence: 1
        )
        let second = await readUDP(
            adapter,
            maximumDatagrams: 64,
            maximumBytes: 1_024,
            sequence: 2
        )

        XCTAssertEqual(try datagrams(first).count, 64)
        XCTAssertEqual(try datagrams(second).count, 6)
        XCTAssertEqual(access.readCallCount, 1)
    }

    func testAdaptersCancelUnderlyingAppleFlowExactlyOnce() throws {
        let tcpAccess = StubAppleTCPFlowAccess()
        let tcp = try BoundedAppleTCPFlowAdapter(access: tcpAccess)
        tcp.cancel()
        tcp.cancel()
        XCTAssertEqual(tcpAccess.cancelCallCount, 1)

        let udpAccess = StubAppleUDPFlowAccess()
        let udp = try BoundedAppleUDPFlowAdapter(access: udpAccess)
        udp.cancel()
        udp.cancel()
        XCTAssertEqual(udpAccess.cancelCallCount, 1)
    }

    func testTCPDuplicateRawCallbacksCannotReleaseNextOperation() throws {
        let access = ControlledAppleTCPFlowAccess()
        let adapter = try BoundedAppleTCPFlowAdapter(
            access: access,
            maximumStagingBytes: 16
        )
        let firstRead = LockedCallbackCounter()
        let secondRead = LockedCallbackCounter()
        let rejectedRead = LockedCallbackCounter()

        adapter.read(maximumBytes: 4, token: token(sequence: 1, kind: .flowRead)) {
            _, _ in firstRead.increment()
        }
        access.completeRead(at: 0, with: .success(Data([1])))
        adapter.read(maximumBytes: 4, token: token(sequence: 2, kind: .flowRead)) {
            _, _ in secondRead.increment()
        }

        // A buggy/raw implementation invokes operation 1 again after operation
        // 2 is pending. It must neither call operation 1 twice nor clear 2.
        access.completeRead(at: 0, with: .success(Data([2])))
        adapter.read(maximumBytes: 4, token: token(sequence: 3, kind: .flowRead)) {
            _, _ in rejectedRead.increment()
        }
        XCTAssertEqual(access.readCallCount, 2)
        XCTAssertEqual(firstRead.value, 1)
        XCTAssertEqual(secondRead.value, 0)
        XCTAssertEqual(rejectedRead.value, 1)

        access.completeRead(at: 1, with: .success(Data([3])))
        XCTAssertEqual(secondRead.value, 1)

        let firstWrite = LockedCallbackCounter()
        let secondWrite = LockedCallbackCounter()
        let rejectedWrite = LockedCallbackCounter()
        adapter.write(
            Data([1]),
            token: token(sequence: 4, kind: .flowWrite)
        ) { _, _ in firstWrite.increment() }
        access.completeWrite(at: 0, with: .success(()))
        adapter.write(
            Data([2]),
            token: token(sequence: 5, kind: .flowWrite)
        ) { _, _ in secondWrite.increment() }
        access.completeWrite(at: 0, with: .success(()))
        adapter.write(
            Data([3]),
            token: token(sequence: 6, kind: .flowWrite)
        ) { _, _ in rejectedWrite.increment() }

        XCTAssertEqual(access.writeCallCount, 2)
        XCTAssertEqual(firstWrite.value, 1)
        XCTAssertEqual(secondWrite.value, 0)
        XCTAssertEqual(rejectedWrite.value, 1)
        access.completeWrite(at: 1, with: .success(()))
        XCTAssertEqual(secondWrite.value, 1)
    }

    func testUDPDuplicateRawCallbacksCannotReleaseNextOperation() throws {
        let access = ControlledAppleUDPFlowAccess()
        let adapter = try BoundedAppleUDPFlowAdapter(
            access: access,
            maximumStagingDatagrams: 8,
            maximumStagingBytes: 64
        )
        let firstRead = LockedCallbackCounter()
        let secondRead = LockedCallbackCounter()
        let rejectedRead = LockedCallbackCounter()

        adapter.readDatagrams(
            maximumDatagrams: 1,
            maximumBytes: 16,
            token: token(sequence: 1, kind: .flowRead)
        ) { _, _ in firstRead.increment() }
        access.completeRead(at: 0, with: .success([datagram(byte: 1)]))
        adapter.readDatagrams(
            maximumDatagrams: 1,
            maximumBytes: 16,
            token: token(sequence: 2, kind: .flowRead)
        ) { _, _ in secondRead.increment() }
        access.completeRead(at: 0, with: .success([datagram(byte: 2)]))
        adapter.readDatagrams(
            maximumDatagrams: 1,
            maximumBytes: 16,
            token: token(sequence: 3, kind: .flowRead)
        ) { _, _ in rejectedRead.increment() }

        XCTAssertEqual(access.readCallCount, 2)
        XCTAssertEqual(firstRead.value, 1)
        XCTAssertEqual(secondRead.value, 0)
        XCTAssertEqual(rejectedRead.value, 1)
        access.completeRead(at: 1, with: .success([datagram(byte: 3)]))
        XCTAssertEqual(secondRead.value, 1)

        let firstWrite = LockedCallbackCounter()
        let secondWrite = LockedCallbackCounter()
        let rejectedWrite = LockedCallbackCounter()
        adapter.writeDatagrams(
            [datagram(byte: 1)],
            token: token(sequence: 4, kind: .flowWrite)
        ) { _, _ in firstWrite.increment() }
        access.completeWrite(at: 0, with: .success(()))
        adapter.writeDatagrams(
            [datagram(byte: 2)],
            token: token(sequence: 5, kind: .flowWrite)
        ) { _, _ in secondWrite.increment() }
        access.completeWrite(at: 0, with: .success(()))
        adapter.writeDatagrams(
            [datagram(byte: 3)],
            token: token(sequence: 6, kind: .flowWrite)
        ) { _, _ in rejectedWrite.increment() }

        XCTAssertEqual(access.writeCallCount, 2)
        XCTAssertEqual(firstWrite.value, 1)
        XCTAssertEqual(secondWrite.value, 0)
        XCTAssertEqual(rejectedWrite.value, 1)
        access.completeWrite(at: 1, with: .success(()))
        XCTAssertEqual(secondWrite.value, 1)
    }

    func testGlobalStagingBudgetFailsClosedAndReleasesReservations() async throws {
        let budget = try FlowStagingMemoryBudget(maximumBytes: 4)
        let access = StubAppleTCPFlowAccess()
        let adapter = try BoundedAppleTCPFlowAdapter(
            access: access,
            maximumStagingBytes: 8,
            stagingBudget: budget
        )
        access.nextRead = .success(Data((0..<6).map(UInt8.init)))

        _ = await readTCP(adapter, maximumBytes: 2, sequence: 1)
        XCTAssertEqual(budget.currentReservedBytes, 4)
        _ = await readTCP(adapter, maximumBytes: 2, sequence: 2)
        XCTAssertEqual(budget.currentReservedBytes, 2)
        adapter.cancel()
        XCTAssertEqual(budget.currentReservedBytes, 0)

        let exhaustedBudget = try FlowStagingMemoryBudget(maximumBytes: 3)
        let exhaustedAccess = StubAppleTCPFlowAccess()
        let exhausted = try BoundedAppleTCPFlowAdapter(
            access: exhaustedAccess,
            maximumStagingBytes: 8,
            stagingBudget: exhaustedBudget
        )
        exhaustedAccess.nextRead = .success(Data((0..<6).map(UInt8.init)))
        let result = await readTCP(exhausted, maximumBytes: 2, sequence: 3)
        XCTAssertEqual(
            result,
            .failure(.invalidData("Apple TCP global staging budget exceeded"))
        )
        XCTAssertEqual(exhaustedBudget.currentReservedBytes, 0)
    }

    func testAdapterDrainWaitsForAcceptedNativeCallbackAndIsIdempotent() throws {
        let access = DelayedDrainAppleTCPFlowAccess()
        let adapter = try BoundedAppleTCPFlowAdapter(access: access)
        let read = LockedCallbackCounter()
        let drained = LockedCallbackCounter()

        adapter.read(
            maximumBytes: 64,
            token: token(sequence: 1, kind: .flowRead)
        ) { _, _ in read.increment() }
        adapter.cancelAndDrain { drained.increment() }

        XCTAssertEqual(access.cancelCallCount, 1)
        XCTAssertEqual(drained.value, 0)
        access.completeRead(.failure(.cancelled))
        XCTAssertEqual(read.value, 0)
        XCTAssertEqual(drained.value, 1)

        adapter.cancelAndDrain { drained.increment() }
        XCTAssertEqual(access.cancelCallCount, 1)
        XCTAssertEqual(drained.value, 2)
    }

    private func readTCP(
        _ adapter: BoundedAppleTCPFlowAdapter,
        maximumBytes: Int,
        sequence: UInt64
    ) async -> Result<TCPReadResult, FlowIOError> {
        await withCheckedContinuation { continuation in
            let token = token(sequence: sequence, kind: .flowRead)
            adapter.read(maximumBytes: maximumBytes, token: token) {
                _, result in continuation.resume(returning: result)
            }
        }
    }

    private func readUDP(
        _ adapter: BoundedAppleUDPFlowAdapter,
        maximumDatagrams: Int,
        maximumBytes: Int,
        sequence: UInt64
    ) async -> Result<UDPReadResult, FlowIOError> {
        await withCheckedContinuation { continuation in
            let token = token(sequence: sequence, kind: .flowRead)
            adapter.readDatagrams(
                maximumDatagrams: maximumDatagrams,
                maximumBytes: maximumBytes,
                token: token
            ) { _, result in continuation.resume(returning: result) }
        }
    }

    private func bytes(
        _ result: Result<TCPReadResult, FlowIOError>
    ) throws -> Data {
        guard case let .bytes(data) = try result.get() else {
            throw TestError.unexpectedResult
        }
        return data
    }

    private func datagrams(
        _ result: Result<UDPReadResult, FlowIOError>
    ) throws -> [UDPDatagram] {
        guard case let .datagrams(datagrams) = try result.get() else {
            throw TestError.unexpectedResult
        }
        return datagrams
    }

    private func datagram(byte: UInt8) -> UDPDatagram {
        UDPDatagram(
            payload: Data([byte]),
            remoteEndpoint: FlowEndpoint(
                host: .name("example.com"),
                port: 443,
                transport: .udp
            )
        )
    }

    private func token(
        sequence: UInt64,
        kind: FlowOperationKind
    ) -> FlowOperationToken {
        FlowOperationToken(
            sessionID: UUID(),
            sequence: sequence,
            kind: kind
        )
    }

    private enum TestError: Error {
        case unexpectedResult
    }
}

private final class LockedCallbackCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { locked { count } }
    func increment() { locked { count += 1 } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ControlledAppleTCPFlowAccess:
    AppleTCPFlowAccess,
    @unchecked Sendable
{
    typealias ReadCompletion = @Sendable (Result<Data?, FlowIOError>) -> Void
    typealias WriteCompletion = @Sendable (Result<Void, FlowIOError>) -> Void

    private let lock = NSLock()
    private var reads: [ReadCompletion] = []
    private var writes: [WriteCompletion] = []

    var readCallCount: Int { locked { reads.count } }
    var writeCallCount: Int { locked { writes.count } }

    func readData(completion: @escaping ReadCompletion) {
        locked { reads.append(completion) }
    }

    func writeData(_ data: Data, completion: @escaping WriteCompletion) {
        locked { writes.append(completion) }
    }

    func finishWriting() {}
    func cancel() {}

    func completeRead(
        at index: Int,
        with result: Result<Data?, FlowIOError>
    ) {
        locked { reads[index] }(result)
    }

    func completeWrite(
        at index: Int,
        with result: Result<Void, FlowIOError>
    ) {
        locked { writes[index] }(result)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class DelayedDrainAppleTCPFlowAccess:
    AppleTCPFlowAccess,
    @unchecked Sendable
{
    typealias ReadCompletion = @Sendable (Result<Data?, FlowIOError>) -> Void

    private let lock = NSLock()
    private var readCompletion: ReadCompletion?
    private var drainCompletions: [@Sendable () -> Void] = []
    private var cancellations = 0

    var cancelCallCount: Int { locked { cancellations } }

    func readData(completion: @escaping ReadCompletion) {
        locked { readCompletion = completion }
    }

    func writeData(
        _ data: Data,
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        completion(.success(()))
    }

    func finishWriting() {}
    func cancel() { cancelAndDrain {} }

    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        locked {
            if cancellations == 0 { cancellations = 1 }
            drainCompletions.append(completion)
        }
    }

    func completeRead(_ result: Result<Data?, FlowIOError>) {
        let action = locked { () -> (
            ReadCompletion?,
            [@Sendable () -> Void]
        ) in
            defer { readCompletion = nil }
            defer { drainCompletions.removeAll(keepingCapacity: false) }
            return (readCompletion, drainCompletions)
        }
        action.0?(result)
        action.1.forEach { $0() }
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class ControlledAppleUDPFlowAccess:
    AppleUDPFlowAccess,
    @unchecked Sendable
{
    typealias ReadCompletion = @Sendable (
        Result<[UDPDatagram]?, FlowIOError>
    ) -> Void
    typealias WriteCompletion = @Sendable (Result<Void, FlowIOError>) -> Void

    private let lock = NSLock()
    private var reads: [ReadCompletion] = []
    private var writes: [WriteCompletion] = []

    var readCallCount: Int { locked { reads.count } }
    var writeCallCount: Int { locked { writes.count } }

    func readDatagrams(completion: @escaping ReadCompletion) {
        locked { reads.append(completion) }
    }

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        completion: @escaping WriteCompletion
    ) {
        locked { writes.append(completion) }
    }

    func cancel() {}

    func completeRead(
        at index: Int,
        with result: Result<[UDPDatagram]?, FlowIOError>
    ) {
        locked { reads[index] }(result)
    }

    func completeWrite(
        at index: Int,
        with result: Result<Void, FlowIOError>
    ) {
        locked { writes[index] }(result)
    }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class StubAppleTCPFlowAccess:
    AppleTCPFlowAccess,
    @unchecked Sendable
{
    private let lock = NSLock()
    var nextRead: Result<Data?, FlowIOError> = .success(nil)
    private var reads = 0
    private var cancellations = 0

    var readCallCount: Int { locked { reads } }
    var cancelCallCount: Int { locked { cancellations } }

    func readData(
        completion: @escaping @Sendable (
            Result<Data?, FlowIOError>
        ) -> Void
    ) {
        let result = locked { () -> Result<Data?, FlowIOError> in
            reads += 1
            return nextRead
        }
        completion(result)
    }

    func writeData(
        _ data: Data,
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    ) {
        completion(.success(()))
    }

    func finishWriting() {}
    func cancel() { locked { cancellations += 1 } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class StubAppleUDPFlowAccess:
    AppleUDPFlowAccess,
    @unchecked Sendable
{
    private let lock = NSLock()
    var nextRead: Result<[UDPDatagram]?, FlowIOError> = .success(nil)
    private var reads = 0
    private var cancellations = 0

    var readCallCount: Int { locked { reads } }
    var cancelCallCount: Int { locked { cancellations } }

    func readDatagrams(
        completion: @escaping @Sendable (
            Result<[UDPDatagram]?, FlowIOError>
        ) -> Void
    ) {
        let result = locked { () -> Result<[UDPDatagram]?, FlowIOError> in
            reads += 1
            return nextRead
        }
        completion(result)
    }

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    ) {
        completion(.success(()))
    }

    func cancel() { locked { cancellations += 1 } }

    private func locked<Value>(_ body: () -> Value) -> Value {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

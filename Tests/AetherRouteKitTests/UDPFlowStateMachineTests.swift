import Foundation
import XCTest
@testable import AetherRouteKit

final class UDPFlowStateMachineTests: XCTestCase, @unchecked Sendable {
    func testStrictBatchBoundsAcceptEdgesAndRejectOverflow() throws {
        let endpoint = udpEndpoint()
        let sixtyFour = (0..<64).map { _ in
            UDPDatagram(payload: Data([1]), remoteEndpoint: endpoint)
        }
        XCTAssertNoThrow(try UDPBatchValidator.validate(sixtyFour))
        XCTAssertNoThrow(
            try UDPBatchValidator.validate([
                UDPDatagram(
                    payload: Data(
                        repeating: 1,
                        count: UDPBatchPolicy.maximumPayloadBytes
                    ),
                    remoteEndpoint: endpoint
                ),
            ])
        )

        XCTAssertThrowsError(try UDPBatchValidator.validate([]))
        XCTAssertThrowsError(
            try UDPBatchValidator.validate(sixtyFour + [sixtyFour[0]])
        )
        XCTAssertThrowsError(
            try UDPBatchValidator.validate([
                UDPDatagram(
                    payload: Data(
                        repeating: 1,
                        count: UDPBatchPolicy.maximumPayloadBytes + 1
                    ),
                    remoteEndpoint: endpoint
                ),
            ])
        )

        let aggregateOverflow = (0..<17).map { _ in
            UDPDatagram(
                payload: Data(
                    repeating: 1,
                    count: UDPBatchPolicy.maximumPayloadBytes
                ),
                remoteEndpoint: endpoint
            )
        }
        XCTAssertThrowsError(
            try UDPBatchValidator.validate(aggregateOverflow)
        )
        XCTAssertThrowsError(
            try UDPBatchValidator.validate([
                UDPDatagram(
                    payload: Data([1]),
                    remoteEndpoint: FlowEndpoint(
                        host: .name("example.com"),
                        port: 443,
                        transport: .tcp
                    )
                ),
            ])
        )
    }

    func testBatchBackpressureAndSingleWritesInFlight() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        XCTAssertEqual(
            flow.firstReadLimits?.0,
            UDPBatchPolicy.maximumDatagrams
        )
        XCTAssertEqual(
            flow.firstReadLimits?.1,
            UDPBatchPolicy.maximumBatchBytes
        )
        XCTAssertEqual(
            source.firstReadLimits?.0,
            UDPBatchPolicy.maximumDatagrams
        )

        let outbound = [datagram("outbound")]
        XCTAssertTrue(flow.completeNextRead(.success(.datagrams(outbound))))
        let outboundWriteStarted = await eventually {
            sink.writeCallCount == 1
        }
        XCTAssertTrue(outboundWriteStarted)
        XCTAssertEqual(sink.writtenDatagrams, [outbound])
        XCTAssertEqual(flow.readCallCount, 1)

        let inbound = [datagram("inbound")]
        XCTAssertTrue(source.completeNextRead(.success(.datagrams(inbound))))
        let inboundWriteStarted = await eventually {
            flow.writeCallCount == 1
        }
        XCTAssertTrue(inboundWriteStarted)
        XCTAssertEqual(flow.writtenDatagrams, [inbound])
        XCTAssertEqual(source.readCallCount, 1)

        XCTAssertTrue(sink.completeNextWrite(.success(())))
        XCTAssertTrue(flow.completeNextWrite(.success(())))
        let nextReadsStarted = await eventually {
            flow.readCallCount == 2 && source.readCallCount == 2
        }
        XCTAssertTrue(nextReadsStarted)

        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .running)
        XCTAssertEqual(snapshot.inFlight, [.flowRead, .bridgeRead])
    }

    func testOversizedBatchFailsBeforeAnyWrite() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        let oversized = UDPDatagram(
            payload: Data(
                repeating: 1,
                count: UDPBatchPolicy.maximumPayloadBytes + 1
            ),
            remoteEndpoint: udpEndpoint()
        )
        XCTAssertTrue(
            flow.completeNextRead(.success(.datagrams([oversized])))
        )
        let didCancel = await eventually { flow.cancelCallCount == 1 }
        XCTAssertTrue(didCancel)

        let snapshot = await machine.snapshot()
        XCTAssertEqual(
            snapshot.lifecycle,
            .failed(.invalidData("UDP batch violates bounded flow policy"))
        )
        XCTAssertEqual(sink.writeCallCount, 0)
        XCTAssertEqual(source.cancelCallCount, 1)
        XCTAssertEqual(sink.cancelCallCount, 1)
    }

    func testCancellationInvalidatesLateAndWrongTokens() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        let token = try XCTUnwrap(flow.firstReadToken)
        let wrongToken = FlowOperationToken(
            sessionID: UUID(),
            sequence: token.sequence,
            kind: token.kind
        )
        XCTAssertTrue(
            flow.completeNextRead(
                .success(.datagrams([datagram("ignored")])),
                returnedToken: wrongToken
            )
        )
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(sink.writeCallCount, 0)

        await machine.cancel()
        XCTAssertTrue(
            source.completeNextRead(
                .success(.datagrams([datagram("late")]))
            )
        )
        try? await Task.sleep(for: .milliseconds(10))

        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .cancelled)
        XCTAssertTrue(snapshot.inFlight.isEmpty)
        XCTAssertEqual(flow.writeCallCount, 0)
        XCTAssertEqual(flow.cancelCallCount, 1)
        XCTAssertEqual(source.cancelCallCount, 1)
        XCTAssertEqual(sink.cancelCallCount, 1)
    }

    func testEndOfStreamFinishesAndCancelsOutstandingPeerRead() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
        let didFinish = await eventually(machine) {
            $0.lifecycle == .finished
        }
        XCTAssertTrue(didFinish)

        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .finished)
        XCTAssertTrue(snapshot.inFlight.isEmpty)
        XCTAssertEqual(source.cancelCallCount, 1)
        XCTAssertEqual(sink.cancelCallCount, 1)
    }

    func testCompletionCancelRacesNeverRestartBatchReads() async throws {
        for index in 0..<100 {
            let (machine, flow, source, sink) = try makeMachine()
            try await machine.start()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = flow.completeNextRead(
                        .success(.datagrams([self.datagram("f\(index)")]))
                    )
                }
                group.addTask {
                    _ = source.completeNextRead(
                        .success(.datagrams([self.datagram("b\(index)")]))
                    )
                }
                group.addTask {
                    await machine.cancel()
                }
            }

            _ = sink.completeNextWrite(.success(()))
            _ = flow.completeNextWrite(.success(()))
            let cancelled = await eventually(machine) {
                $0.lifecycle == .cancelled
            }
            XCTAssertTrue(cancelled, "iteration \(index)")
            XCTAssertEqual(flow.readCallCount, 1, "iteration \(index)")
            XCTAssertEqual(source.readCallCount, 1, "iteration \(index)")
            XCTAssertLessThanOrEqual(flow.writeCallCount, 1)
            XCTAssertLessThanOrEqual(sink.writeCallCount, 1)
        }
    }

    func testTerminationIsReportedExactlyOnceAfterFailureAndCancel() async throws {
        let recorder = FlowTerminationRecorder()
        let (machine, flow, _, _) = try makeMachine {
            recorder.record($0)
        }
        try await machine.start()

        XCTAssertTrue(flow.completeNextRead(.success(.datagrams([]))))
        let didFail = await eventually(machine) {
            if case .failed = $0.lifecycle { return true }
            return false
        }
        XCTAssertTrue(didFail)
        await machine.cancel()

        XCTAssertEqual(
            recorder.values,
            [.failed(.invalidData("UDP batch violates bounded flow policy"))]
        )
    }

    func testSharedRustSourceAndSinkIsCancelledExactlyOnce() async throws {
        let flow = FakeUDPFlow()
        let bridge = SharedRustUDPBridge()
        let machine = try UDPFlowStateMachine(
            flow: flow,
            bridgeSource: bridge,
            bridgeSink: bridge
        )

        await machine.cancel()

        XCTAssertEqual(flow.cancelCallCount, 1)
        XCTAssertEqual(bridge.cancelCallCount, 1)
    }

    private func makeMachine(
        onTermination: @escaping FlowTerminationHandler = { _ in }
    ) throws -> (
        UDPFlowStateMachine,
        FakeUDPFlow,
        FakeRustUDPSource,
        FakeRustUDPSink
    ) {
        let flow = FakeUDPFlow()
        let source = FakeRustUDPSource()
        let sink = FakeRustUDPSink()
        return (
            try UDPFlowStateMachine(
                flow: flow,
                bridgeSource: source,
                bridgeSink: sink,
                onTermination: onTermination
            ),
            flow,
            source,
            sink
        )
    }

    private func datagram(_ string: String) -> UDPDatagram {
        UDPDatagram(
            payload: Data(string.utf8),
            remoteEndpoint: udpEndpoint()
        )
    }

    private func udpEndpoint() -> FlowEndpoint {
        FlowEndpoint(
            host: .name("example.com"),
            port: 443,
            transport: .udp
        )
    }
}

private final class SharedRustUDPBridge:
    RustUDPSource,
    RustUDPSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancellations = 0

    var cancelCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {}

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {}

    func cancel() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }
}

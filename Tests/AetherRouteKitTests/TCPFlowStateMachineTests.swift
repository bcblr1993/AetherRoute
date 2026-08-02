import Foundation
import XCTest
@testable import AetherRouteKit

final class TCPFlowStateMachineTests: XCTestCase, @unchecked Sendable {
    func testBackpressureKeepsOneReadAndWriteInFlightPerDirection() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        XCTAssertEqual(flow.readCallCount, 1)
        XCTAssertEqual(source.readCallCount, 1)

        let outbound = Data("outbound".utf8)
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(outbound))))
        let outboundWriteStarted = await eventually {
            sink.writeCallCount == 1
        }
        XCTAssertTrue(outboundWriteStarted)
        XCTAssertEqual(sink.writtenData, [outbound])
        XCTAssertEqual(flow.readCallCount, 1)

        let inbound = Data("inbound".utf8)
        XCTAssertTrue(source.completeNextRead(.success(.bytes(inbound))))
        let inboundWriteStarted = await eventually {
            flow.writeCallCount == 1
        }
        XCTAssertTrue(inboundWriteStarted)
        XCTAssertEqual(flow.writtenData, [inbound])
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

    func testHalfCloseKeepsReverseDirectionAliveUntilItsEOF() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
        let bridgeFinishStarted = await eventually {
            sink.finishCallCount == 1
        }
        XCTAssertTrue(bridgeFinishStarted)
        XCTAssertEqual(source.readCallCount, 1)
        XCTAssertTrue(sink.completeNextFinish(.success(())))

        let inbound = Data("still-open".utf8)
        XCTAssertTrue(source.completeNextRead(.success(.bytes(inbound))))
        let inboundWriteStarted = await eventually {
            flow.writeCallCount == 1
        }
        XCTAssertTrue(inboundWriteStarted)
        XCTAssertEqual(flow.writtenData, [inbound])

        var snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .running)
        XCTAssertTrue(snapshot.flowInputEnded)
        XCTAssertTrue(snapshot.bridgeOutputFinished)
        XCTAssertFalse(snapshot.bridgeInputEnded)

        XCTAssertTrue(flow.completeNextWrite(.success(())))
        let nextBridgeReadStarted = await eventually {
            source.readCallCount == 2
        }
        XCTAssertTrue(nextBridgeReadStarted)
        XCTAssertTrue(source.completeNextRead(.success(.endOfStream)))
        let flowFinishStarted = await eventually {
            flow.finishCallCount == 1
        }
        XCTAssertTrue(flowFinishStarted)
        XCTAssertTrue(flow.completeNextFinish(.success(())))

        let didFinish = await eventually(machine) {
            $0.lifecycle == .finished
        }
        XCTAssertTrue(didFinish)
        snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .finished)
        XCTAssertTrue(snapshot.flowOutputFinished)
        XCTAssertTrue(snapshot.bridgeOutputFinished)
        XCTAssertEqual(flow.cancelCallCount, 0)
        XCTAssertEqual(source.cancelCallCount, 0)
        XCTAssertEqual(sink.cancelCallCount, 0)
    }

    func testMismatchedAndLateCompletionTokensAreIgnored() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        let original = try XCTUnwrap(flow.firstReadToken)
        let wrong = FlowOperationToken(
            sessionID: original.sessionID,
            sequence: original.sequence + 1_000,
            kind: original.kind
        )
        XCTAssertTrue(
            flow.completeNextRead(
                .success(.bytes(Data("ignored".utf8))),
                returnedToken: wrong
            )
        )
        try? await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(sink.writeCallCount, 0)

        await machine.cancel()
        XCTAssertTrue(
            source.completeNextRead(.success(.bytes(Data("late".utf8))))
        )
        try? await Task.sleep(for: .milliseconds(10))

        let snapshot = await machine.snapshot()
        XCTAssertEqual(snapshot.lifecycle, .cancelled)
        XCTAssertTrue(snapshot.inFlight.isEmpty)
        XCTAssertEqual(flow.writeCallCount, 0)
        XCTAssertEqual(sink.writeCallCount, 0)
        XCTAssertEqual(flow.cancelCallCount, 1)
        XCTAssertEqual(source.cancelCallCount, 1)
        XCTAssertEqual(sink.cancelCallCount, 1)
    }

    func testInvalidReadFailsClosedAndCancelsEveryTransport() async throws {
        let (machine, flow, source, sink) = try makeMachine()
        try await machine.start()

        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data()))))
        let didCancel = await eventually { flow.cancelCallCount == 1 }
        XCTAssertTrue(didCancel)

        let snapshot = await machine.snapshot()
        XCTAssertEqual(
            snapshot.lifecycle,
            .failed(.invalidData("TCP flow returned an invalid read size"))
        )
        XCTAssertEqual(source.cancelCallCount, 1)
        XCTAssertEqual(sink.cancelCallCount, 1)
        XCTAssertTrue(snapshot.inFlight.isEmpty)
    }

    func testOSReadThatIgnoresRequestedMaximumFailsBeforeRustWrite() async throws {
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let sink = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow,
            bridgeSource: source,
            bridgeSink: sink,
            maximumReadBytes: 4
        )
        try await machine.start()

        XCTAssertTrue(
            flow.completeNextRead(
                .success(.bytes(Data(repeating: 7, count: 5)))
            )
        )
        let didFail = await eventually(machine) {
            if case .failed = $0.lifecycle { return true }
            return false
        }
        XCTAssertTrue(didFail)
        XCTAssertEqual(sink.writeCallCount, 0)
        XCTAssertEqual(flow.cancelCallCount, 1)
        XCTAssertEqual(source.cancelCallCount, 1)
    }

    func testConfigurationAndRepeatedStartAreRejected() async throws {
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let sink = FakeRustTCPSink()
        XCTAssertThrowsError(
            try TCPFlowStateMachine(
                flow: flow,
                bridgeSource: source,
                bridgeSink: sink,
                maximumReadBytes: 0
            )
        )

        let machine = try TCPFlowStateMachine(
            flow: flow,
            bridgeSource: source,
            bridgeSink: sink
        )
        try await machine.start()
        do {
            try await machine.start()
            XCTFail("Expected repeated start to fail")
        } catch {
            XCTAssertEqual(error as? FlowStateMachineStartError, .alreadyStarted)
        }
        await machine.cancel()
    }

    func testCompletionCancelRacesNeverRestartReads() async throws {
        for index in 0..<100 {
            let (machine, flow, source, sink) = try makeMachine()
            try await machine.start()

            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    _ = flow.completeNextRead(
                        .success(.bytes(Data("flow-\(index)".utf8)))
                    )
                }
                group.addTask {
                    _ = source.completeNextRead(
                        .success(.bytes(Data("bridge-\(index)".utf8)))
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

    func testTerminationIsReportedExactlyOnceAfterCancelAndLateCompletion() async throws {
        let recorder = FlowTerminationRecorder()
        let (machine, flow, source, _) = try makeMachine {
            recorder.record($0)
        }
        try await machine.start()

        await machine.cancel()
        await machine.cancel()
        _ = flow.completeNextRead(.success(.endOfStream))
        _ = source.completeNextRead(.failure(.transport("late")))
        try? await Task.sleep(for: .milliseconds(10))

        XCTAssertEqual(recorder.values, [.cancelled])
    }

    func testSharedRustSourceAndSinkIsCancelledExactlyOnce() async throws {
        let flow = FakeTCPFlow()
        let bridge = SharedRustTCPBridge()
        let machine = try TCPFlowStateMachine(
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
        TCPFlowStateMachine,
        FakeTCPFlow,
        FakeRustTCPSource,
        FakeRustTCPSink
    ) {
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let sink = FakeRustTCPSink()
        return (
            try TCPFlowStateMachine(
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
}

private final class SharedRustTCPBridge:
    RustTCPSource,
    RustTCPSink,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var cancellations = 0

    var cancelCallCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancellations
    }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {}

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {}

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {}

    func cancel() {
        lock.lock()
        cancellations += 1
        lock.unlock()
    }
}

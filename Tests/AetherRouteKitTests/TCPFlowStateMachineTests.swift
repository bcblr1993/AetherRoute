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

    /// The old pump silently failed writes and only logged read failures.
    /// A terminal record must survive standard (non-verbose) diagnostics and
    /// must never interpolate a transport's potentially private description.
    func testBridgeWriteFailureRecordsCorrelatedPrivateSafeTerminationOnce() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcp-termination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "tcp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let sessionID = UUID()
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow, bridgeSource: source, bridgeSink: bridge,
            sessionID: sessionID, diagnosticLog: log
        )
        try await machine.start()
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data(repeating: 7, count: 1024)))))
        let started = await eventually { bridge.writeCallCount == 1 }
        XCTAssertTrue(started)
        XCTAssertTrue(bridge.completeNextWrite(.failure(.transport("SECRET credentials.example"))))
        let stopped = await eventually(machine) { if case .failed = $0.lifecycle { return true }; return false }
        XCTAssertTrue(stopped)
        await machine.cancel()
        _ = source.completeNextRead(.failure(.closed))
        let flushed = expectation(description: "termination flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertEqual(text.components(separatedBy: "stage=tcpTermination").count - 1, 1)
        XCTAssertTrue(text.contains("session=\(sessionID.uuidString)"))
        XCTAssertTrue(text.contains("trigger=bridgeWrite outcome=failed error=transport"))
        XCTAssertTrue(text.contains("flowReadBytes=1024 bridgeWrittenBytes=0"))
        XCTAssertTrue(text.contains("firstEOF=none"))
        XCTAssertFalse(text.contains("SECRET"))
        XCTAssertFalse(text.contains("credentials.example"))
    }

    func testClientEOFAndDownstreamWriteFailureRemainDistinct() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcp-termination-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "tcp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow, bridgeSource: source, bridgeSink: bridge, diagnosticLog: log
        )
        try await machine.start()
        XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
        let finishing = await eventually { bridge.finishCallCount == 1 }
        XCTAssertTrue(finishing)
        XCTAssertTrue(bridge.completeNextFinish(.success(())))
        XCTAssertTrue(source.completeNextRead(.success(.bytes(Data(repeating: 1, count: 64)))))
        let writing = await eventually { flow.writeCallCount == 1 }
        XCTAssertTrue(writing)
        XCTAssertTrue(flow.completeNextWrite(.failure(.closed)))
        let stopped = await eventually(machine) { if case .failed = $0.lifecycle { return true }; return false }
        XCTAssertTrue(stopped)
        let flushed = expectation(description: "termination flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertTrue(text.contains("trigger=flowWrite outcome=failed error=closed"))
        XCTAssertTrue(text.contains("firstEOF=flowRead"))
        XCTAssertTrue(text.contains("bridgeReadBytes=64 flowWrittenBytes=0"))
    }

    func testEveryTCPFailureStageEmitsOneTerminalRecord() async throws {
        for stage in [FlowOperationKind.flowRead, .bridgeRead, .bridgeWrite,
                      .flowWrite, .bridgeFinishWriting, .flowFinishWriting] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("tcp-stages-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "tcp"))
            let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
            let flow = FakeTCPFlow()
            let source = FakeRustTCPSource()
            let bridge = FakeRustTCPSink()
            let machine = try TCPFlowStateMachine(
                flow: flow, bridgeSource: source, bridgeSink: bridge, diagnosticLog: log
            )
            try await machine.start()
            switch stage {
            case .flowRead: XCTAssertTrue(flow.completeNextRead(.failure(.closed)))
            case .bridgeRead: XCTAssertTrue(source.completeNextRead(.failure(.closed)))
            case .bridgeWrite:
                XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data([1])))))
                let ready = await eventually { bridge.writeCallCount == 1 }
                XCTAssertTrue(ready)
                XCTAssertTrue(bridge.completeNextWrite(.failure(.closed)))
            case .flowWrite:
                XCTAssertTrue(source.completeNextRead(.success(.bytes(Data([1])))))
                let ready = await eventually { flow.writeCallCount == 1 }
                XCTAssertTrue(ready)
                XCTAssertTrue(flow.completeNextWrite(.failure(.closed)))
            case .bridgeFinishWriting:
                XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
                let ready = await eventually { bridge.finishCallCount == 1 }
                XCTAssertTrue(ready)
                XCTAssertTrue(bridge.completeNextFinish(.failure(.closed)))
            case .flowFinishWriting:
                XCTAssertTrue(source.completeNextRead(.success(.endOfStream)))
                let ready = await eventually { flow.finishCallCount == 1 }
                XCTAssertTrue(ready)
                XCTAssertTrue(flow.completeNextFinish(.failure(.closed)))
            }
            let stopped = await eventually(machine) { if case .failed = $0.lifecycle { return true }; return false }
            XCTAssertTrue(stopped)
            let flushed = expectation(description: "stage flushed")
            sink.flush { flushed.fulfill() }
            await fulfillment(of: [flushed], timeout: 5)
            let text = sink.tail(maximumBytes: 8192)
            XCTAssertTrue(text.contains("trigger=\(stage.rawValue) outcome=failed error=closed"), stage.rawValue)
            XCTAssertEqual(text.components(separatedBy: "stage=tcpTermination").count - 1, 1)
        }
    }

    func testHalfCloseIdleDeadlineFollowsActiveUploadAndLogsRealIdleExpiry() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tcp-idle-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "tcp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow, bridgeSource: source, bridgeSink: bridge,
            halfCloseIdleTimeout: .milliseconds(150), diagnosticLog: log
        )
        try await machine.start()
        XCTAssertTrue(source.completeNextRead(.success(.endOfStream)))
        let finishing = await eventually { flow.finishCallCount == 1 }
        XCTAssertTrue(finishing)
        XCTAssertTrue(flow.completeNextFinish(.success(())))
        for index in 1...8 {
            XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data([1])))))
            let writing = await eventually { bridge.writeCallCount == index }
            XCTAssertTrue(writing)
            XCTAssertTrue(bridge.completeNextWrite(.success(())))
            let reading = await eventually { flow.readCallCount == index + 1 }
            XCTAssertTrue(reading)
            try await Task.sleep(for: .milliseconds(40))
            let state = await machine.snapshot()
            guard state.lifecycle == .running else {
                XCTFail("active reverse upload was cut off at iteration \(index)")
                return
            }
        }
        let expired = await eventually(machine) { $0.lifecycle == .cancelled }
        XCTAssertTrue(expired, "quiet half-closed clients must still be reclaimed")
        let flushed = expectation(description: "idle expiry log flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertTrue(text.contains("trigger=halfCloseTimeout outcome=cancelled"))
        XCTAssertEqual(text.components(separatedBy: "stage=tcpTermination").count - 1, 1)
    }

    func testHalfCloseExpiryIsVisibleAtStandardLevel() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tcp-idle-log-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "tcp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow, bridgeSource: source, bridgeSink: bridge,
            halfCloseIdleTimeout: .milliseconds(50), diagnosticLog: log
        )
        try await machine.start()
        XCTAssertTrue(source.completeNextRead(.success(.endOfStream)))
        let ready = await eventually { flow.finishCallCount == 1 }
        XCTAssertTrue(ready)
        XCTAssertTrue(flow.completeNextFinish(.success(())))
        let expired = await eventually(machine) { $0.lifecycle == .cancelled }
        XCTAssertTrue(expired)
        let flushed = expectation(description: "timeout flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        XCTAssertTrue(sink.tail(maximumBytes: 8192).contains("trigger=halfCloseTimeout"))
    }

    func testHalfCloseDoesNotExpireWhileBridgeWriteIsInFlight() async throws {
        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow, bridgeSource: source, bridgeSink: bridge,
            halfCloseIdleTimeout: .milliseconds(80)
        )
        try await machine.start()
        XCTAssertTrue(source.completeNextRead(.success(.endOfStream)))
        let finishing = await eventually { flow.finishCallCount == 1 }
        XCTAssertTrue(finishing)
        XCTAssertTrue(flow.completeNextFinish(.success(())))
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data([1])))))
        let writing = await eventually { bridge.writeCallCount == 1 }
        XCTAssertTrue(writing)
        try await Task.sleep(for: .milliseconds(200))
        let state = await machine.snapshot()
        XCTAssertEqual(state.lifecycle, .running, "backpressure is not idle")
        await machine.cancel()
    }

    func testTCPActualWritesFeedAggregateCountersAndFailureExactlyOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tcp-metrics-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "aggregate"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let aggregate = DiagnosticAggregator(log: log)
        DiagnosticFlowOpenObserver.shared.attach(aggregate)
        defer { DiagnosticFlowOpenObserver.shared.detach() }
        let (machine, flow, source, bridge) = try makeMachine()
        try await machine.start()
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data(repeating: 1, count: 8)))))
        let uploading = await eventually { bridge.writeCallCount == 1 }
        XCTAssertTrue(uploading)
        XCTAssertTrue(bridge.completeNextWrite(.success(())))
        let uploaded = await eventually { flow.readCallCount == 2 }
        XCTAssertTrue(uploaded)
        XCTAssertTrue(source.completeNextRead(.success(.bytes(Data(repeating: 2, count: 3)))))
        let downloading = await eventually { flow.writeCallCount == 1 }
        XCTAssertTrue(downloading)
        XCTAssertTrue(flow.completeNextWrite(.success(())))
        let downloaded = await eventually { source.readCallCount == 2 }
        XCTAssertTrue(downloaded)
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data(repeating: 3, count: 5)))))
        let pending = await eventually { bridge.writeCallCount == 2 }
        XCTAssertTrue(pending)
        XCTAssertTrue(bridge.completeNextWrite(.failure(.closed)))
        let failed = await eventually(machine) { if case .failed = $0.lifecycle { return true }; return false }
        XCTAssertTrue(failed)
        await machine.cancel()
        _ = source.completeNextRead(.failure(.closed))
        aggregate.emit()
        let flushed = expectation(description: "TCP aggregate flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertTrue(text.contains("up=8 down=3"), "count only successful sink acknowledgements")
        XCTAssertTrue(text.contains("sessionsFailed=1"))
    }

    func testBridgeFinishClosedAfterBridgeEOFCompletesCleanlyWithoutFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherroute-bridge-finish-after-eof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: dir, baseName: "tp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let aggregate = DiagnosticAggregator(log: log)
        DiagnosticFlowOpenObserver.shared.attach(aggregate)
        defer { DiagnosticFlowOpenObserver.shared.detach() }

        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow,
            bridgeSource: source,
            bridgeSink: bridge,
            diagnosticLog: log
        )
        DiagnosticFlowOpenObserver.shared.record(.tcpOpened)
        try await machine.start()

        // Remote server closes first (bridgeRead EOF) -> finishWriting on flow succeeds.
        XCTAssertTrue(source.completeNextRead(.success(.endOfStream)))
        let flowFinishing = await eventually { flow.finishCallCount == 1 }
        XCTAssertTrue(flowFinishing)
        XCTAssertTrue(flow.completeNextFinish(.success(())))

        // Local client then closes (flowRead EOF) -> finishWriting on bridge returns .closed
        // because Rust stream relay already closed its input receiver upon sending EOF.
        XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
        let bridgeFinishing = await eventually { bridge.finishCallCount == 1 }
        XCTAssertTrue(bridgeFinishing)
        XCTAssertTrue(bridge.completeNextFinish(.failure(.closed)))

        let finished = await eventually(machine) { $0.lifecycle == .finished }
        XCTAssertTrue(finished, "Half-close finish returning .closed after remote EOF must finish cleanly")

        aggregate.emit()
        let flushed = expectation(description: "bridgeFinishClosedAfterEOF flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertTrue(text.contains("sessionsFailed=0"), "Expected sessionsFailed=0, got: \(text)")
        XCTAssertFalse(text.contains("outcome=failed"), "Must not log failure record: \(text)")
    }

    func testTrailingPeerCloseAfterCompletedBidirectionalExchangeAndClientEOFIsNotCountedAsFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherroute-trailing-close-after-eof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: dir, baseName: "tp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let aggregate = DiagnosticAggregator(log: log)
        DiagnosticFlowOpenObserver.shared.attach(aggregate)
        defer { DiagnosticFlowOpenObserver.shared.detach() }

        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow,
            bridgeSource: source,
            bridgeSink: bridge,
            diagnosticLog: log
        )
        DiagnosticFlowOpenObserver.shared.record(.tcpOpened)
        try await machine.start()

        // 1. Client sends request and receives response (flowWrittenBytes > 0).
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data(repeating: 0x41, count: 64)))))
        let bridgeWrite1 = await eventually { bridge.writeCallCount == 1 }
        XCTAssertTrue(bridgeWrite1)
        XCTAssertTrue(bridge.completeNextWrite(.success(())))
        let flowRead2 = await eventually { flow.readCallCount == 2 }
        XCTAssertTrue(flowRead2)

        XCTAssertTrue(source.completeNextRead(.success(.bytes(Data(repeating: 0x42, count: 128)))))
        let flowWrite1 = await eventually { flow.writeCallCount == 1 }
        XCTAssertTrue(flowWrite1)
        XCTAssertTrue(flow.completeNextWrite(.success(())))
        let sourceRead2 = await eventually { source.readCallCount == 2 }
        XCTAssertTrue(sourceRead2)

        // 2. Client finishes and closes its socket (flowRead EOF -> bridgeFinishWriting).
        XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
        let bridgeFinishing = await eventually { bridge.finishCallCount == 1 }
        XCTAssertTrue(bridgeFinishing)
        XCTAssertTrue(bridge.completeNextFinish(.success(())))

        // 3. Server sends trailing 24-byte TLS close_notify, which fails to write because client already closed fd.
        XCTAssertTrue(source.completeNextRead(.success(.bytes(Data(repeating: 0x15, count: 24)))))
        let flowWrite2 = await eventually { flow.writeCallCount == 2 }
        XCTAssertTrue(flowWrite2)
        XCTAssertTrue(flow.completeNextWrite(.failure(.closed)))

        let finished = await eventually(machine) { $0.lifecycle == .finished }
        XCTAssertTrue(finished, "Trailing write failure (.closed) after completed response and client EOF must finish cleanly")

        aggregate.emit()
        let flushed = expectation(description: "trailingPeerCloseAfterEOF flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertTrue(text.contains("sessionsFailed=0"), "Expected sessionsFailed=0, got: \(text)")
        XCTAssertFalse(text.contains("outcome=failed"), "Must not log failure record: \(text)")
    }

    func testFirstDownstreamWriteClosedAfterClientRequestAndEOFIsNotCountedAsFailure() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherroute-first-write-close-after-request-eof-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: dir, baseName: "tp"))
        let log = DiagnosticLog(category: "test", sink: sink, levelProvider: { .standard })
        let aggregate = DiagnosticAggregator(log: log)
        DiagnosticFlowOpenObserver.shared.attach(aggregate)
        defer { DiagnosticFlowOpenObserver.shared.detach() }

        let flow = FakeTCPFlow()
        let source = FakeRustTCPSource()
        let bridge = FakeRustTCPSink()
        let machine = try TCPFlowStateMachine(
            flow: flow,
            bridgeSource: source,
            bridgeSink: bridge,
            diagnosticLog: log
        )
        DiagnosticFlowOpenObserver.shared.record(.tcpOpened)
        try await machine.start()

        // 1. Client sends a 1545-byte request (bridgeWrittenBytes = 1545), then closes its socket (flowRead EOF).
        XCTAssertTrue(flow.completeNextRead(.success(.bytes(Data(repeating: 0x47, count: 1545)))))
        let bridgeWrite1 = await eventually { bridge.writeCallCount == 1 }
        XCTAssertTrue(bridgeWrite1)
        XCTAssertTrue(bridge.completeNextWrite(.success(())))
        let flowRead2 = await eventually { flow.readCallCount == 2 }
        XCTAssertTrue(flowRead2)

        XCTAssertTrue(flow.completeNextRead(.success(.endOfStream)))
        let bridgeFinishing = await eventually { bridge.finishCallCount == 1 }
        XCTAssertTrue(bridgeFinishing)
        XCTAssertTrue(bridge.completeNextFinish(.success(())))

        // 2. Server delivers its first 4591-byte response chunk (flowWrittenBytes == 0),
        // which fails flow.write with .closed because the client already closed its fd after sending the request.
        XCTAssertTrue(source.completeNextRead(.success(.bytes(Data(repeating: 0x48, count: 4591)))))
        let flowWrite1 = await eventually { flow.writeCallCount == 1 }
        XCTAssertTrue(flowWrite1)
        XCTAssertTrue(flow.completeNextWrite(.failure(.closed)))

        let finished = await eventually(machine) { $0.lifecycle == .finished }
        XCTAssertTrue(finished, "First downstream write (.closed) after client sent request + EOF must finish cleanly")

        aggregate.emit()
        let flushed = expectation(description: "firstDownstreamWriteClosedAfterClientRequestAndEOF flushed")
        sink.flush { flushed.fulfill() }
        await fulfillment(of: [flushed], timeout: 5)
        let text = sink.tail(maximumBytes: 8192)
        XCTAssertTrue(text.contains("sessionsFailed=0"), "Expected sessionsFailed=0, got: \(text)")
        XCTAssertFalse(text.contains("outcome=failed"), "Must not log failure record: \(text)")
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

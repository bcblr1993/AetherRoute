@testable import AetherRouteKit
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxyConcurrencyAndBudgetFixesTests: XCTestCase, @unchecked Sendable {
    func testFlowResourceBudgetSupports4096ConcurrentTCPAndUDPSessionsUnder512MiBCeiling() throws {
        let tcpBudget = try FlowResourceBudget()
        XCTAssertEqual(tcpBudget.snapshot().maximumBytes, 512 * 1_024 * 1_024)

        var tcpLeases: [FlowResourceLease] = []
        tcpLeases.reserveCapacity(4_096)
        for _ in 0..<4_096 {
            tcpLeases.append(try tcpBudget.lease(for: .tcp))
        }
        XCTAssertEqual(tcpBudget.snapshot().activeLeaseCount, 4_096)
        XCTAssertThrowsError(try tcpBudget.lease(for: .tcp))

        let udpBudget = try FlowResourceBudget()
        var udpLeases: [FlowResourceLease] = []
        udpLeases.reserveCapacity(4_096)
        for _ in 0..<4_096 {
            udpLeases.append(try udpBudget.lease(for: .udp))
        }
        XCTAssertEqual(udpBudget.snapshot().activeLeaseCount, 4_096)
        XCTAssertThrowsError(try udpBudget.lease(for: .udp))
    }

    func testUDPFlowStateMachineIdleTimeoutTerminatesInactiveAssociation() async throws {
        let terminated = expectation(description: "UDP association terminated on idle timeout")
        let flow = HangingUDPFlowIO()
        let bridge = HangingUDPRustBridge()
        let outcome = LockedBox<FlowLifecycle?>(nil)

        let machine = try UDPFlowStateMachine(
            flow: flow,
            bridgeSource: bridge,
            bridgeSink: bridge,
            idleTimeout: .milliseconds(60),
            onTermination: { lifecycle in
                outcome.set(lifecycle)
                terminated.fulfill()
            }
        )
        try await machine.start()
        await fulfillment(of: [terminated], timeout: 1.5)
        XCTAssertEqual(outcome.get(), .finished)
        XCTAssertGreaterThanOrEqual(flow.cancelCount, 1)
        XCTAssertGreaterThanOrEqual(bridge.cancelCount, 1)
    }

    func testTCPFlowStateMachineHalfCloseWatchdogTriggersOnClientEOF() async throws {
        let terminated = expectation(description: "TCP half-close watchdog terminated hung server after client EOF")
        let flow = ClientEOFTCPFlowIO()
        let bridge = HangingTCPRustBridge()
        let outcome = LockedBox<FlowLifecycle?>(nil)

        let machine = try TCPFlowStateMachine(
            flow: flow,
            bridgeSource: bridge,
            bridgeSink: bridge,
            halfCloseIdleTimeout: .milliseconds(60),
            onTermination: { lifecycle in
                outcome.set(lifecycle)
                terminated.fulfill()
            }
        )
        try await machine.start()
        await fulfillment(of: [terminated], timeout: 1.5)
        XCTAssertEqual(outcome.get(), .finished)
    }

    func testTransparentProxyRuntimeDoesNotHoldAdmissionLockDuringMakeFlowOrResetNetworkState() throws {
        let engine = NonBlockingAdmissionMockEngine()
        let runtime = try TransparentProxyFlowRuntime(engine: engine)
        let tcpIdentity = TransparentProxyAppleFlowIdentity()
        let udpIdentity = TransparentProxyAppleFlowIdentity()

        let tcpAdmissionDone = expectation(description: "TCP admission completes after FFI unblocks")
        DispatchQueue.global().async {
            let result = runtime.claimTCP(
                components: TransparentTCPIngressComponents(
                    opening: InstantOpenAdapter(),
                    flow: HangingTCPFlowIO(),
                    openingIdentity: tcpIdentity,
                    flowIdentity: tcpIdentity
                ),
                source: nil,
                destination: FlowEndpoint(host: .name("example.com"), port: 443, transport: .tcp),
                sourceApp: nil
            )
            XCTAssertNotNil(result.sessionID)
            XCTAssertNil(result.failurePoint)
            tcpAdmissionDone.fulfill()
        }

        XCTAssertTrue(engine.waitForMakeTCPEntry(timeout: 1.0))

        // While TCP admission is stalled inside FFI `makeTCPFlow`, UDP admission and resetNetworkState must NOT block on `admissionLock`.
        let udpAcceptedWhileTCPBlocked = expectation(description: "UDP admitted without waiting on blocked TCP FFI")
        DispatchQueue.global().async {
            let result = runtime.claimUDP(
                components: TransparentUDPIngressComponents(
                    opening: InstantOpenAdapter(),
                    flow: HangingUDPFlowIO(),
                    openingIdentity: udpIdentity,
                    flowIdentity: udpIdentity
                ),
                localSource: nil,
                sourceApp: nil
            )
            XCTAssertNotNil(result.sessionID)
            XCTAssertNil(result.failurePoint)
            udpAcceptedWhileTCPBlocked.fulfill()
        }
        wait(for: [udpAcceptedWhileTCPBlocked], timeout: 1.0)
        XCTAssertEqual(runtime.resetNetworkState(interfaceIndex: 1), .reset)

        engine.releaseMakeTCP()
        wait(for: [tcpAdmissionDone], timeout: 1.0)

        let stopDone = expectation(description: "runtime stop")
        runtime.stop { stopDone.fulfill() }
        wait(for: [stopDone], timeout: 2.0)
        XCTAssertEqual(runtime.snapshot().registry.activeSessionCount, 0)
    }

    func testTransparentTCPProxySessionConcurrentStartAndCancelReleasesLeaseCleanly() throws {
        let budget = try FlowResourceBudget()
        let registry = try TransparentProxySessionRegistry()

        for _ in 0..<80 {
            let opening = DeferredOpenAdapter()
            let flow = InstantDrainTCPFlowIO()
            let rust = InstantDestroyTCPRustBridge()
            let lease = try budget.lease(for: .tcp)
            let session = try TransparentTCPProxySession(
                opening: opening,
                flow: flow,
                rust: rust,
                resourceLease: lease,
                registry: registry
            )
            try registry.insert(session)

            let group = DispatchGroup()
            session.start()
            group.enter()
            DispatchQueue.global().async {
                opening.complete(.success(()))
                group.leave()
            }
            group.enter()
            DispatchQueue.global().async {
                session.cancel()
                group.leave()
            }
            group.wait()
        }

        let stopDone = expectation(description: "registry drain")
        registry.stopAll { stopDone.fulfill() }
        wait(for: [stopDone], timeout: 5.0)
        XCTAssertEqual(registry.snapshot().activeSessionCount, 0)
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 0)
    }

    func testTransparentProxyReloadPayloadPolicyRejectsEmptyPayloadAndDecodesValidPayload() throws {
        XCTAssertThrowsError(try TransparentProxyReloadPayloadPolicy.decode(Data())) { error in
            XCTAssertEqual(error as? TransparentProxyReloadPayloadError, .emptyPayload)
        }

        let payload = ReloadProfilePayload(
            profileYAML: "proxies:\n  - {name: P1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: pass}\n",
            routingMode: .rule,
            bypassPolicy: .empty,
            dnsPolicy: .inherited,
            proxySelections: ["GLOBAL": "P1"],
            diagnosticLogLevel: .verbose
        )
        let encoded = try ReloadProfilePayloadCodec.encode(payload)
        let decoded = try TransparentProxyReloadPayloadPolicy.decode(encoded)
        XCTAssertEqual(decoded, payload)
    }
}

private final class LockedBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func set(_ newValue: Value) { lock.withLock { value = newValue } }
    func get() -> Value { lock.withLock { value } }
}

private final class InstantOpenAdapter: AppleProxyFlowOpening, @unchecked Sendable {
    func open(completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void) {
        completion(.success(()))
    }
}

private final class DeferredOpenAdapter: AppleProxyFlowOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var completion: (@Sendable (Result<Void, FlowIOError>) -> Void)?
    private var pendingResult: Result<Void, FlowIOError>?

    func open(completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void) {
        let resultToDeliver = lock.withLock { () -> Result<Void, FlowIOError>? in
            if let pending = pendingResult {
                pendingResult = nil
                return pending
            }
            self.completion = completion
            return nil
        }
        if let resultToDeliver {
            completion(resultToDeliver)
        }
    }

    func complete(_ result: Result<Void, FlowIOError>) {
        let callback = lock.withLock { () -> (@Sendable (Result<Void, FlowIOError>) -> Void)? in
            if let completion {
                self.completion = nil
                return completion
            }
            pendingResult = result
            return nil
        }
        callback?(result)
    }
}

private final class HangingTCPFlowIO: TransparentTCPFlowIO, @unchecked Sendable {
    func read(maximumBytes _: Int, token _: FlowOperationToken, completion _: @escaping TCPReadCompletion) {}
    func write(_: Data, token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func finishWriting(token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func cancel() {}
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) { completion() }
}

private final class InstantDrainTCPFlowIO: TransparentTCPFlowIO, @unchecked Sendable {
    func read(maximumBytes _: Int, token _: FlowOperationToken, completion _: @escaping TCPReadCompletion) {}
    func write(_: Data, token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func finishWriting(token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func cancel() {}
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) { completion() }
}

private final class ClientEOFTCPFlowIO: TransparentTCPFlowIO, @unchecked Sendable {
    func read(maximumBytes _: Int, token: FlowOperationToken, completion: @escaping TCPReadCompletion) {
        completion(token, .success(.endOfStream))
    }
    func write(_: Data, token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func finishWriting(token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func cancel() {}
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) { completion() }
}

private final class HangingTCPRustBridge: RustTCPFlowBridge, @unchecked Sendable {
    func activate(completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void) { completion(.success(())) }
    func read(maximumBytes _: Int, token _: FlowOperationToken, completion _: @escaping TCPReadCompletion) {}
    func write(_: Data, token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func finishWriting(token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func cancel() {}
    func destroy(completion: @escaping @Sendable () -> Void) { completion() }
}

private final class InstantDestroyTCPRustBridge: RustTCPFlowBridge, @unchecked Sendable {
    func activate(completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void) {
        DispatchQueue.global().async { completion(.success(())) }
    }
    func read(maximumBytes _: Int, token _: FlowOperationToken, completion _: @escaping TCPReadCompletion) {}
    func write(_: Data, token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func finishWriting(token: FlowOperationToken, completion: @escaping TCPWriteCompletion) { completion(token, .success(())) }
    func cancel() {}
    func destroy(completion: @escaping @Sendable () -> Void) { completion() }
}

private final class HangingUDPFlowIO: TransparentUDPFlowIO, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var cancelCount = 0
    func readDatagrams(maximumDatagrams _: Int, maximumBytes _: Int, token _: FlowOperationToken, completion _: @escaping UDPReadCompletion) {}
    func writeDatagrams(_: [UDPDatagram], token: FlowOperationToken, completion: @escaping UDPWriteCompletion) { completion(token, .success(())) }
    func cancel() { lock.withLock { cancelCount += 1 } }
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) { cancel(); completion() }
}

private final class HangingUDPRustBridge: RustUDPFlowBridge, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var cancelCount = 0
    func activate(completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void) { completion(.success(())) }
    func readDatagrams(maximumDatagrams _: Int, maximumBytes _: Int, token _: FlowOperationToken, completion _: @escaping UDPReadCompletion) {}
    func writeDatagrams(_: [UDPDatagram], token: FlowOperationToken, completion: @escaping UDPWriteCompletion) { completion(token, .success(())) }
    func cancel() { lock.withLock { cancelCount += 1 } }
    func destroy(completion: @escaping @Sendable () -> Void) { completion() }
}

private final class NonBlockingAdmissionMockEngine: TransparentProxyFlowEngine, @unchecked Sendable {
    private let makeTCPEntered = DispatchSemaphore(value: 0)
    private let makeTCPRelease = DispatchSemaphore(value: 0)

    func makeTCPFlow(source _: FlowEndpoint?, destination _: FlowEndpoint, sourceApp _: FlowSourceApp?) throws -> any RustTCPFlowBridge {
        makeTCPEntered.signal()
        makeTCPRelease.wait()
        return InstantDestroyTCPRustBridge()
    }

    func makeUDPFlow(source _: FlowEndpoint, sourceApp _: FlowSourceApp?) throws -> any RustUDPFlowBridge {
        HangingUDPRustBridge()
    }

    func resetNetworkState(interfaceIndex _: UInt32) throws -> EngineNetworkResetOutcome { .reset }
    func shutdown(completion: @escaping @Sendable () -> Void) { completion() }
    func waitForMakeTCPEntry(timeout: TimeInterval) -> Bool {
        makeTCPEntered.wait(timeout: .now() + timeout) == .success
    }
    func releaseMakeTCP() { makeTCPRelease.signal() }
}

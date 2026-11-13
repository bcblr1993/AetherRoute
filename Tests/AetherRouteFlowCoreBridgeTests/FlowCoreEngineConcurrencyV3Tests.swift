@testable import AetherRouteFlowCoreBridge
import AetherRouteFlowABI
import AetherRouteKit
import AetherRouteTransparentProxySupport
import XCTest

final class FlowCoreEngineConcurrencyV3Tests: XCTestCase {
    func testConcurrentFlowCreationAndControlDoNotBlockBehindSlowResetNetworkState() throws {
        let backend = ConcurrentMockFlowCoreABI()
        backend.blockReset = true
        let engine = try FlowCoreEngine(
            profile: Data("proxies: []\nrules: []\n".utf8),
            runtimeDirectory: URL(fileURLWithPath: "/tmp/aetherroute-flow-v3-tests"),
            configuration: .default,
            backend: backend
        )

        let resetCompleted = expectation(description: "reset completed")
        DispatchQueue.global().async {
            _ = try? engine.resetNetworkState(interfaceIndex: 1)
            resetCompleted.fulfill()
        }
        XCTAssertTrue(backend.waitForResetEntry(timeout: 1.0))

        // While resetNetworkState is blocked on the FFI call, read-shared
        // operations (makeTCPFlow, makeUDPFlow, telemetrySnapshot, selectorSnapshot)
        // must proceed without blocking behind a serial engine queue.
        let tcpDone = expectation(description: "tcp flow created")
        let udpDone = expectation(description: "udp flow created")
        let telemetryDone = expectation(description: "telemetry fetched")
        let selectorDone = expectation(description: "selector fetched")

        DispatchQueue.global().async {
            if (try? engine.makeTCPFlow(
                source: nil,
                destination: FlowEndpoint(host: .name("example.com"), port: 443, transport: .tcp)
            )) != nil {
                tcpDone.fulfill()
            }
        }
        DispatchQueue.global().async {
            if (try? engine.makeUDPFlow(
                source: FlowEndpoint(host: .ipv4([127, 0, 0, 1]), port: 50_100, transport: .udp)
            )) != nil {
                udpDone.fulfill()
            }
        }
        DispatchQueue.global().async {
            if (try? engine.telemetrySnapshot()) != nil {
                telemetryDone.fulfill()
            }
        }
        DispatchQueue.global().async {
            if (try? engine.selectorSnapshot(group: "Route")) != nil {
                selectorDone.fulfill()
            }
        }

        wait(for: [tcpDone, udpDone, telemetryDone, selectorDone], timeout: 1.0)

        backend.releaseReset()
        wait(for: [resetCompleted], timeout: 1.0)

        let stopped = expectation(description: "shutdown")
        engine.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 1.0)
    }

    func testShutdownWaitsForActiveReadLeaseBeforeDestroyingEngine() throws {
        let backend = ConcurrentMockFlowCoreABI()
        backend.blockReset = true
        let engine = try FlowCoreEngine(
            profile: Data("proxies: []\nrules: []\n".utf8),
            runtimeDirectory: URL(fileURLWithPath: "/tmp/aetherroute-flow-v3-tests"),
            configuration: .default,
            backend: backend
        )

        let resetCompleted = expectation(description: "reset completed")
        DispatchQueue.global().async {
            _ = try? engine.resetNetworkState(interfaceIndex: 2)
            resetCompleted.fulfill()
        }
        XCTAssertTrue(backend.waitForResetEntry(timeout: 1.0))

        let shutdownDone = expectation(description: "shutdown completed")
        engine.shutdown {
            shutdownDone.fulfill()
        }

        // Shutdown must reject new work immediately, yet wait for the active
        // read lease before calling engineDestroy.
        XCTAssertThrowsError(try engine.telemetrySnapshot()) { error in
            XCTAssertEqual(error as? FlowCoreEngineError, .engineClosed)
        }
        XCTAssertFalse(backend.waitForEngineDestroy(timeout: 0.05))
        XCTAssertEqual(backend.engineDestroyCalls, 0)

        backend.releaseReset()
        wait(for: [resetCompleted, shutdownDone], timeout: 1.5)
        XCTAssertEqual(backend.engineDestroyCalls, 1)
    }
}

private final class ConcurrentMockFlowCoreABI: FlowCoreABIBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var nextAddress = 0x2_000
    private let resetEntered = DispatchSemaphore(value: 0)
    private let resetRelease = DispatchSemaphore(value: 0)
    private let engineDestroyed = DispatchSemaphore(value: 0)

    var blockReset = false
    private(set) var engineDestroyCalls = 0

    func engineCreate(
        profile _: Data,
        workingDirectory _: Data,
        configuration _: FlowCoreEngineConfiguration
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        let addr = lock.withLock { () -> Int in
            nextAddress += 0x10
            return nextAddress
        }
        return (
            FlowCoreABIStatus.success,
            FlowCoreABIHandle(rawValue: UnsafeMutableRawPointer(bitPattern: addr)!)
        )
    }

    func engineDestroy(_: FlowCoreABIHandle) -> Int32 {
        lock.withLock { engineDestroyCalls += 1 }
        engineDestroyed.signal()
        return FlowCoreABIStatus.success
    }

    func engineSetRoutingMode(_: FlowCoreABIHandle, mode _: RoutingMode) -> Int32 {
        FlowCoreABIStatus.success
    }

    func selectorSnapshot(engine _: FlowCoreABIHandle, group _: Data) -> (status: Int32, snapshot: Data?) {
        var result = Data([0x41, 0x52, 0x53, 0x31])
        appendUInt32(0, to: &result)
        appendUInt32(1, to: &result)
        let member = Data("ProxyA".utf8)
        appendUInt32(UInt32(member.count), to: &result)
        result.append(member)
        return (FlowCoreABIStatus.success, result)
    }

    func selectorSelect(engine _: FlowCoreABIHandle, group _: Data, member _: Data) -> Int32 {
        FlowCoreABIStatus.success
    }

    func selectorLatency(engine _: FlowCoreABIHandle, group _: Data, url _: Data, timeoutMilliseconds _: UInt32) -> (status: Int32, latencies: Data?) {
        (FlowCoreABIStatus.success, Data([0x41, 0x52, 0x4c, 0x31, 0, 0, 0, 0]))
    }

    func selectorActiveLatency(engine _: FlowCoreABIHandle, group _: Data, url _: Data, timeoutMilliseconds _: UInt32) -> (status: Int32, latencies: Data?) {
        (FlowCoreABIStatus.success, Data([0x41, 0x52, 0x4c, 0x31, 0, 0, 0, 0]))
    }

    func telemetrySnapshot(engine _: FlowCoreABIHandle, maximumConnections _: UInt32) -> (status: Int32, snapshot: Data?) {
        let snapshot = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 1,
            downloadBytesPerSecond: 2,
            uploadTotal: 3,
            downloadTotal: 4,
            memoryBytes: 5,
            connections: []
        )
        return (FlowCoreABIStatus.success, try? NetworkTelemetryCodec.encode(snapshot))
    }

    func closeConnections(engine _: FlowCoreABIHandle, request _: Data) -> (status: Int32, closedCount: UInt64) {
        (FlowCoreABIStatus.success, 0)
    }

    func resetNetworkState(engine _: FlowCoreABIHandle, interfaceIndex _: UInt32) -> Int32 {
        if lock.withLock({ blockReset }) {
            resetEntered.signal()
            resetRelease.wait()
        }
        return FlowCoreABIStatus.success
    }

    func tcpCreate(engine _: FlowCoreABIHandle, source _: Data?, destination _: Data, sourceApp _: Data?) -> (status: Int32, handle: FlowCoreABIHandle?) {
        let addr = lock.withLock { () -> Int in
            nextAddress += 0x10
            return nextAddress
        }
        return (
            FlowCoreABIStatus.success,
            FlowCoreABIHandle(rawValue: UnsafeMutableRawPointer(bitPattern: addr)!)
        )
    }

    func udpCreate(engine _: FlowCoreABIHandle, source _: Data, sourceApp _: Data?) -> (status: Int32, handle: FlowCoreABIHandle?) {
        let addr = lock.withLock { () -> Int in
            nextAddress += 0x10
            return nextAddress
        }
        return (
            FlowCoreABIStatus.success,
            FlowCoreABIHandle(rawValue: UnsafeMutableRawPointer(bitPattern: addr)!)
        )
    }

    func activate(_: FlowCoreABIHandle) -> Int32 { FlowCoreABIStatus.success }

    func tcpWrite(_: FlowCoreABIHandle, data _: Data, token: UInt64, completion: @escaping @Sendable (UInt64, Int32) -> Void) -> Int32 {
        completion(token, FlowCoreABIStatus.success)
        return FlowCoreABIStatus.success
    }

    func tcpFinishWrite(_: FlowCoreABIHandle, token: UInt64, completion: @escaping @Sendable (UInt64, Int32) -> Void) -> Int32 {
        completion(token, FlowCoreABIStatus.success)
        return FlowCoreABIStatus.success
    }

    func tcpRead(_: FlowCoreABIHandle, maximumBytes _: Int, token _: UInt64, completion _: @escaping @Sendable (FlowCoreABITCPReadResponse) -> Void) -> Int32 {
        FlowCoreABIStatus.success
    }

    func udpWrite(_: FlowCoreABIHandle, datagrams _: [FlowCoreABIUDPDatagram], token: UInt64, completion: @escaping @Sendable (UInt64, Int32) -> Void) -> Int32 {
        completion(token, FlowCoreABIStatus.success)
        return FlowCoreABIStatus.success
    }

    func udpRead(_: FlowCoreABIHandle, maximumDatagrams _: Int, maximumBytes _: Int, token: UInt64, completion _: @escaping @Sendable (FlowCoreABIUDPReadResponse) -> Void) -> Int32 {
        FlowCoreABIStatus.success
    }

    func cancel(_: FlowCoreABIHandle) -> Int32 { FlowCoreABIStatus.success }
    func destroy(_: FlowCoreABIHandle) -> Int32 { FlowCoreABIStatus.success }

    func waitForResetEntry(timeout: TimeInterval) -> Bool {
        resetEntered.wait(timeout: .now() + timeout) == .success
    }

    func releaseReset() {
        resetRelease.signal()
    }

    func waitForEngineDestroy(timeout: TimeInterval) -> Bool {
        engineDestroyed.wait(timeout: .now() + timeout) == .success
    }

    private func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}

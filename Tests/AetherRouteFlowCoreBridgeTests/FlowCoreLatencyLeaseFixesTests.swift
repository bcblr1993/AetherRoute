@testable import AetherRouteFlowCoreBridge
import AetherRouteFlowABI
import AetherRouteKit
import AetherRouteTransparentProxySupport
import XCTest

final class FlowCoreLatencyLeaseFixesTests: XCTestCase {
    func testShutdownWaitsForActiveProxyLatencyAndActiveRouteLatencyBeforeDestroyingEngine() throws {
        for activeMode in [false, true] {
            let backend = LatencyBlockingMockFlowCoreABI()
            let engine = try FlowCoreEngine(
                profile: Data("proxies: []\nrules: []\n".utf8),
                runtimeDirectory: URL(fileURLWithPath: "/tmp/aetherroute-flow-latency-lease-tests"),
                configuration: .default,
                backend: backend
            )

            let probeCompleted = expectation(description: "latency probe finished")
            DispatchQueue.global().async {
                if activeMode {
                    _ = try? engine.testActiveProxyLatency(group: "PROXY", url: "https://cp.cloudflare.com/generate_204", timeoutMilliseconds: 3_000)
                } else {
                    _ = try? engine.testProxyLatency(group: "PROXY", url: "https://cp.cloudflare.com/generate_204", timeoutMilliseconds: 3_000)
                }
                probeCompleted.fulfill()
            }
            XCTAssertTrue(backend.waitForLatencyEntry(timeout: 1.0))

            let shutdownCompleted = expectation(description: "shutdown completed")
            engine.shutdown { shutdownCompleted.fulfill() }

            XCTAssertFalse(
                backend.waitForEngineDestroy(timeout: 0.05),
                "engineDestroy must wait for active \(activeMode ? "active" : "group") latency probe read lease"
            )
            XCTAssertEqual(backend.engineDestroyCalls, 0)

            backend.releaseLatency()
            wait(for: [probeCompleted, shutdownCompleted], timeout: 1.5)
            XCTAssertEqual(backend.engineDestroyCalls, 1)
        }
    }

    func testEngineAccepts12MiBProfileAndCapsTelemetryConnectionCount() throws {
        let backend = LatencyBlockingMockFlowCoreABI()
        let largeProfile = Data(repeating: UInt8(ascii: "#"), count: 12 * 1_024 * 1_024)
        let engine = try FlowCoreEngine(
            profile: largeProfile,
            runtimeDirectory: URL(fileURLWithPath: "/tmp/aetherroute-flow-12mb-test"),
            configuration: .default,
            backend: backend
        )
        _ = try engine.telemetrySnapshot(maximumConnections: 512)
        XCTAssertLessThanOrEqual(
            backend.lastRequestedTelemetryConnections,
            UInt32(FlowCoreEngine.maximumSafeTelemetryConnections)
        )
        let stopped = expectation(description: "engine stopped")
        engine.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 1.5)
    }

    func testLiveBackendUDPWriteHandlesEmptyRemoteEndpointWithoutNullDereference() throws {
        let liveBackend = try LiveFlowCoreABIBackend()
        let engine = try FlowCoreEngine(
            profile: Data("mode: rule\nproxies: []\nrules: []\n".utf8),
            runtimeDirectory: FileManager.default.temporaryDirectory,
            configuration: FlowCoreEngineConfiguration(routingMode: .direct),
            backend: liveBackend
        )
        let created = liveBackend.udpCreate(
            engine: FlowCoreABIHandle(rawValue: UnsafeMutableRawPointer(bitPattern: 0x1)!),
            source: Data(),
            sourceApp: nil
        )
        XCTAssertNotEqual(created.status, FlowCoreABIStatus.success)

        // Calling udpWrite with empty `remoteEndpoint: Data()` must cleanly return an ABI error
        // instead of crashing inside `NSData.bytes.assumingMemoryBound(to:)`.
        let status = liveBackend.udpWrite(
            FlowCoreABIHandle(rawValue: UnsafeMutableRawPointer(bitPattern: 0x1)!),
            datagrams: [FlowCoreABIUDPDatagram(payload: Data([1, 2, 3]), remoteEndpoint: Data())],
            token: 1
        ) { _, _ in }
        XCTAssertNotEqual(status, FlowCoreABIStatus.success)

        let stopped = expectation(description: "live engine stopped")
        engine.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 2.0)
    }
}

private final class LatencyBlockingMockFlowCoreABI: FlowCoreABIBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var nextAddress = 0x3_000
    private let latencyEntered = DispatchSemaphore(value: 0)
    private let latencyRelease = DispatchSemaphore(value: 0)
    private let engineDestroyed = DispatchSemaphore(value: 0)
    private(set) var engineDestroyCalls = 0
    private(set) var lastRequestedTelemetryConnections: UInt32 = 0

    func engineCreate(
        profile _: Data,
        workingDirectory _: Data,
        configuration _: FlowCoreEngineConfiguration
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        let addr = lock.withLock { () -> Int in
            nextAddress += 0x10
            return nextAddress
        }
        return (FlowCoreABIStatus.success, FlowCoreABIHandle(rawValue: UnsafeMutableRawPointer(bitPattern: addr)!))
    }

    func engineDestroy(_: FlowCoreABIHandle) -> Int32 {
        lock.withLock { engineDestroyCalls += 1 }
        engineDestroyed.signal()
        return FlowCoreABIStatus.success
    }

    func engineSetRoutingMode(_: FlowCoreABIHandle, mode _: RoutingMode) -> Int32 { FlowCoreABIStatus.success }

    func selectorSnapshot(engine _: FlowCoreABIHandle, group _: Data) -> (status: Int32, snapshot: Data?) {
        (FlowCoreABIStatus.success, Data([0x41, 0x52, 0x53, 0x31, 0, 0, 0, 0, 0, 0, 0, 0]))
    }

    func selectorSelect(engine _: FlowCoreABIHandle, group _: Data, member _: Data) -> Int32 { FlowCoreABIStatus.success }

    func selectorLatency(engine _: FlowCoreABIHandle, group _: Data, url _: Data, timeoutMilliseconds _: UInt32) -> (status: Int32, latencies: Data?) {
        latencyEntered.signal()
        latencyRelease.wait()
        return (FlowCoreABIStatus.success, Data([0x41, 0x52, 0x4c, 0x31, 0, 0, 0, 0]))
    }

    func selectorActiveLatency(engine _: FlowCoreABIHandle, group _: Data, url _: Data, timeoutMilliseconds _: UInt32) -> (status: Int32, latencies: Data?) {
        latencyEntered.signal()
        latencyRelease.wait()
        return (FlowCoreABIStatus.success, Data([0x41, 0x52, 0x4c, 0x31, 0, 0, 0, 0]))
    }

    func telemetrySnapshot(engine _: FlowCoreABIHandle, maximumConnections: UInt32) -> (status: Int32, snapshot: Data?) {
        lock.withLock { lastRequestedTelemetryConnections = maximumConnections }
        return (FlowCoreABIStatus.success, try? NetworkTelemetryCodec.encode(.empty))
    }

    func closeConnections(engine _: FlowCoreABIHandle, request _: Data) -> (status: Int32, closedCount: UInt64) { (FlowCoreABIStatus.success, 0) }
    func resetNetworkState(engine _: FlowCoreABIHandle, interfaceIndex _: UInt32) -> Int32 { FlowCoreABIStatus.success }

    func tcpCreate(engine _: FlowCoreABIHandle, source _: Data?, destination _: Data, sourceApp _: Data?) -> (status: Int32, handle: FlowCoreABIHandle?) {
        (FlowCoreABIStatus.success, nil)
    }

    func udpCreate(engine _: FlowCoreABIHandle, source _: Data, sourceApp _: Data?) -> (status: Int32, handle: FlowCoreABIHandle?) {
        (FlowCoreABIStatus.success, nil)
    }

    func activate(_: FlowCoreABIHandle) -> Int32 { FlowCoreABIStatus.success }
    func tcpWrite(_: FlowCoreABIHandle, data _: Data, token _: UInt64, completion _: @escaping @Sendable (UInt64, Int32) -> Void) -> Int32 { FlowCoreABIStatus.success }
    func tcpFinishWrite(_: FlowCoreABIHandle, token _: UInt64, completion _: @escaping @Sendable (UInt64, Int32) -> Void) -> Int32 { FlowCoreABIStatus.success }
    func tcpRead(_: FlowCoreABIHandle, maximumBytes _: Int, token _: UInt64, completion _: @escaping @Sendable (FlowCoreABITCPReadResponse) -> Void) -> Int32 { FlowCoreABIStatus.success }
    func udpWrite(_: FlowCoreABIHandle, datagrams _: [FlowCoreABIUDPDatagram], token _: UInt64, completion _: @escaping @Sendable (UInt64, Int32) -> Void) -> Int32 { FlowCoreABIStatus.success }
    func udpRead(_: FlowCoreABIHandle, maximumDatagrams _: Int, maximumBytes _: Int, token _: UInt64, completion _: @escaping @Sendable (FlowCoreABIUDPReadResponse) -> Void) -> Int32 { FlowCoreABIStatus.success }
    func cancel(_: FlowCoreABIHandle) -> Int32 { FlowCoreABIStatus.success }
    func destroy(_: FlowCoreABIHandle) -> Int32 { FlowCoreABIStatus.success }

    func waitForLatencyEntry(timeout: TimeInterval) -> Bool { latencyEntered.wait(timeout: .now() + timeout) == .success }
    func releaseLatency() { latencyRelease.signal() }
    func waitForEngineDestroy(timeout: TimeInterval) -> Bool { engineDestroyed.wait(timeout: .now() + timeout) == .success }
}

@testable import AetherRouteFlowCoreBridge
import AetherRouteFlowABI
import AetherRouteKit
import AetherRouteTransparentProxySupport
import XCTest

final class FlowCoreBridgeTests: XCTestCase {
    func testOnlyClosedAndCancelledAreExpectedFlowTerminationStatuses() {
        XCTAssertTrue(
            FlowCoreABIStatus.isExpectedTermination(FlowCoreABIStatus.closed)
        )
        XCTAssertTrue(
            FlowCoreABIStatus.isExpectedTermination(
                FlowCoreABIStatus.cancelled
            )
        )
        XCTAssertFalse(
            FlowCoreABIStatus.isExpectedTermination(
                FlowCoreABIStatus.invalidState
            )
        )
        XCTAssertFalse(
            FlowCoreABIStatus.isExpectedTermination(
                FlowCoreABIStatus.internalError
            )
        )
    }

    func testLiveStrongLinkedABIAndFiveHundredStagedFlowCycles() throws {
        XCTAssertNoThrow(try LiveFlowCoreABIBackend())
        let engine = try FlowCoreEngine(
            profile: Data("mode: rule\nproxies: []\nrules: []\n".utf8),
            runtimeDirectory: FileManager.default.temporaryDirectory,
            configuration: FlowCoreEngineConfiguration(routingMode: .direct)
        )
        let telemetry = try engine.telemetrySnapshot()
        XCTAssertEqual(telemetry.uploadBytesPerSecond, 0)
        XCTAssertEqual(telemetry.downloadBytesPerSecond, 0)
        XCTAssertEqual(telemetry.uploadTotal, 0)
        XCTAssertEqual(telemetry.downloadTotal, 0)
        XCTAssertTrue(telemetry.connections.isEmpty)
        let barriers = DispatchGroup()
        for index in 0..<500 {
            if index.isMultiple(of: 2) {
                let flow = try engine.makeTCPFlow(
                    source: nil,
                    destination: FlowEndpoint(
                        host: .ipv4([127, 0, 0, 1]),
                        port: 9,
                        transport: .tcp
                    )
                )
                barriers.enter()
                flow.destroy { barriers.leave() }
            } else {
                let flow = try engine.makeUDPFlow(
                    source: udpSource(port: UInt16(49_152 + index))
                )
                barriers.enter()
                flow.destroy { barriers.leave() }
            }
        }
        XCTAssertEqual(barriers.wait(timeout: .now() + 10), .success)

        let stopped = expectation(description: "live engine stopped")
        engine.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 10)
    }

    func testConfigurationRejectsOutOfRangeLimitsBeforeABI() {
        XCTAssertThrowsError(
            try FlowCoreEngineConfiguration(workerThreads: 0).validated()
        )
        XCTAssertThrowsError(
            try FlowCoreEngineConfiguration(queueDepth: 65).validated()
        )
        XCTAssertThrowsError(
            try FlowCoreEngineConfiguration(
                maximumTCPChunkBytes: 1_024 * 1_024 + 1
            ).validated()
        )
        XCTAssertThrowsError(
            try FlowCoreEngineConfiguration(
                maximumUDPPayloadBytes: 65_508
            ).validated()
        )
    }

    func testRoutingModeUpdatesLiveEngineWithoutRecreation() throws {
        let backend = MockFlowCoreABI()
        let engine = try makeEngine(backend: backend)

        try engine.setRoutingMode(.global)
        try engine.setRoutingMode(.direct)

        XCTAssertEqual(backend.routingModeUpdates, [.global, .direct])
        XCTAssertEqual(backend.engineDestroyCalls, 0)
    }

    func testSelectorSelectionReturnsVerifiedCoreSnapshot() throws {
        let backend = MockFlowCoreABI()
        let engine = try makeEngine(backend: backend)

        XCTAssertEqual(
            try engine.selectorSnapshot(group: "Route"),
            ProxySelectionSnapshot(
                selectedMember: "Singapore",
                members: ["Singapore", "Tokyo"]
            )
        )
        XCTAssertEqual(
            try engine.selectProxy(group: "Route", member: "Tokyo"),
            ProxySelectionSnapshot(
                selectedMember: "Tokyo",
                members: ["Singapore", "Tokyo"]
            )
        )
        XCTAssertEqual(backend.selectorSelectCalls, 1)
    }

    func testSelectorRejectsMalformedSnapshotAndLateSelection() throws {
        let backend = MockFlowCoreABI()
        backend.selectorSnapshotOverride = Data("not-a-snapshot".utf8)
        let engine = try makeEngine(backend: backend)

        XCTAssertThrowsError(try engine.selectorSnapshot(group: "Route")) {
            XCTAssertEqual(
                $0 as? FlowCoreEngineError,
                .invalidSelectorSnapshot
            )
        }
        let stopped = expectation(description: "selector engine stopped")
        engine.shutdown { stopped.fulfill() }
        wait(for: [stopped], timeout: 1)
        XCTAssertThrowsError(
            try engine.selectProxy(group: "Route", member: "Tokyo")
        ) {
            XCTAssertEqual($0 as? FlowCoreEngineError, .engineClosed)
        }
    }

    func testSelectorLatencyUsesBoundedCoreResult() throws {
        let backend = MockFlowCoreABI()
        let engine = try makeEngine(backend: backend)

        XCTAssertEqual(
            try engine.testProxyLatency(
                group: "Route",
                url: "https://example.invalid/generate_204",
                timeoutMilliseconds: 5_000
            ),
            ProxyLatencyState(
                results: [
                    ProxyLatencyResult(
                        member: "Singapore",
                        delayMilliseconds: 21
                    ),
                    ProxyLatencyResult(member: "Tokyo", delayMilliseconds: nil),
                ]
            )
        )
        XCTAssertEqual(backend.selectorLatencyCalls, 1)
    }

    func testTelemetrySnapshotUsesSingleBoundedABICall() throws {
        let backend = MockFlowCoreABI()
        let engine = try makeEngine(backend: backend)

        XCTAssertEqual(
            try engine.telemetrySnapshot(),
            NetworkTelemetrySnapshot(
                uploadBytesPerSecond: 100,
                downloadBytesPerSecond: 200,
                uploadTotal: 300,
                downloadTotal: 400,
                memoryBytes: 500,
                connections: []
            )
        )
        XCTAssertEqual(backend.telemetryCalls, 1)
        XCTAssertThrowsError(
            try engine.telemetrySnapshot(maximumConnections: 0)
        )
        XCTAssertEqual(backend.telemetryCalls, 1)
    }

    func testSynchronousABIRejectionCompletesExactlyOnceWithFullToken() throws {
        let backend = MockFlowCoreABI()
        backend.tcpWriteStatus = FlowCoreABIStatus.backpressure
        let engine = try makeEngine(backend: backend)
        let flow = try engine.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )
        try activate(flow)

        let token = FlowOperationToken(
            sessionID: UUID(),
            sequence: UInt64.max - 7,
            kind: .bridgeWrite
        )
        let completion = expectation(description: "write rejected")
        let returned = LockedBox<[FlowOperationToken]>([])
        flow.write(Data([1, 2, 3]), token: token) { returnedToken, result in
            returned.mutate { $0.append(returnedToken) }
            guard case let .failure(error) = result else {
                return XCTFail("Expected synchronous rejection")
            }
            XCTAssertEqual(error, .transport("Flow ABI backpressure"))
            completion.fulfill()
        }
        wait(for: [completion], timeout: 1)
        XCTAssertEqual(returned.value, [token])
        XCTAssertEqual(backend.tcpWriteCalls, 1)

        let destroyed = expectation(description: "destroy")
        flow.destroy { destroyed.fulfill() }
        wait(for: [destroyed], timeout: 1)
    }

    func testABITokenMismatchFailsWithoutLosingSwiftTokenIdentity() throws {
        let backend = MockFlowCoreABI()
        backend.tcpWriteReturnedTokenOffset = 1
        let engine = try makeEngine(backend: backend)
        let flow = try engine.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )
        try activate(flow)

        let token = FlowOperationToken(
            sessionID: UUID(),
            sequence: 0xfedc_ba98_7654_3210,
            kind: .bridgeWrite
        )
        let completed = expectation(description: "token mismatch")
        flow.write(Data([9]), token: token) { returned, result in
            XCTAssertEqual(returned, token)
            guard case let .failure(error) = result else {
                return XCTFail("Expected token mismatch failure")
            }
            XCTAssertEqual(error, .invalidData("FFI token mismatch"))
            completed.fulfill()
        }
        wait(for: [completed], timeout: 1)

        let destroyed = expectation(description: "destroy")
        flow.destroy { destroyed.fulfill() }
        wait(for: [destroyed], timeout: 1)
    }

    func testDestroyDrainsCopiedCallbackBeforeExposingBarrier() throws {
        let backend = MockFlowCoreABI()
        backend.holdTCPReadsUntilDestroy = true
        let engine = try makeEngine(backend: backend)
        let flow = try engine.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )
        try activate(flow)

        let events = LockedBox<[String]>([])
        let read = expectation(description: "cancelled read delivered")
        let destroyed = expectation(description: "destroy barrier")
        let token = FlowOperationToken(
            sessionID: UUID(),
            sequence: 99,
            kind: .bridgeRead
        )
        flow.read(maximumBytes: 64, token: token) { _, result in
            XCTAssertEqual(result, .failure(.cancelled))
            events.mutate { $0.append("callback") }
            read.fulfill()
        }

        XCTAssertTrue(backend.waitForPendingTCPRead(timeout: 1))
        flow.destroy {
            events.mutate { $0.append("destroy") }
            destroyed.fulfill()
        }
        wait(for: [read, destroyed], timeout: 1)
        XCTAssertEqual(events.value, ["callback", "destroy"])
        XCTAssertEqual(backend.flowDestroyCalls, 1)
    }

    func testDestroyClosesAdmissionBeforeQueuedBarrier() throws {
        let backend = MockFlowCoreABI()
        let engine = try makeEngine(backend: backend)
        let flow = try engine.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )
        try activate(flow)

        let destroyed = expectation(description: "destroy")
        let rejected = expectation(description: "late operation")
        flow.destroy { destroyed.fulfill() }
        let token = FlowOperationToken(
            sessionID: UUID(),
            sequence: 1,
            kind: .bridgeWrite
        )
        flow.write(Data([1]), token: token) { returned, result in
            XCTAssertEqual(returned, token)
            guard case let .failure(error) = result else {
                return XCTFail("Expected a closed flow")
            }
            XCTAssertEqual(error, .closed)
            rejected.fulfill()
        }
        wait(for: [destroyed, rejected], timeout: 1)
        XCTAssertEqual(backend.tcpWriteCalls, 0)
    }

    func testEngineShutdownWaitsForChildrenAndIsIdempotent() throws {
        let backend = MockFlowCoreABI()
        let engine = try makeEngine(backend: backend)
        _ = try engine.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )
        _ = try engine.makeUDPFlow(source: udpSource(port: 50_001))

        let first = expectation(description: "first shutdown")
        let second = expectation(description: "second shutdown")
        engine.shutdown { first.fulfill() }
        engine.shutdown { second.fulfill() }
        wait(for: [first, second], timeout: 1)
        XCTAssertEqual(backend.flowDestroyCalls, 2)
        XCTAssertEqual(backend.engineDestroyCalls, 1)

        let late = expectation(description: "late shutdown")
        engine.shutdown { late.fulfill() }
        wait(for: [late], timeout: 1)
        XCTAssertEqual(backend.engineDestroyCalls, 1)
        XCTAssertThrowsError(
            try engine.makeUDPFlow(source: udpSource(port: 50_002))
        ) { error in
            XCTAssertEqual(error as? FlowCoreEngineError, .engineClosed)
        }
    }

    func testConcurrentMakeFlowIsOrderedBeforeShutdownGate() throws {
        let backend = MockFlowCoreABI()
        backend.blockTCPCreate = true
        let engine = try makeEngine(backend: backend)
        let made = expectation(description: "flow made")
        let shutdown = expectation(description: "shutdown")
        let result = LockedBox<Result<any RustTCPFlowBridge, Error>?>(nil)
        let destination = tcpDestination(port: 443)

        DispatchQueue.global().async {
            let value = Result {
                try engine.makeTCPFlow(
                    source: nil,
                    destination: destination
                )
            }
            result.set(value)
            made.fulfill()
        }
        XCTAssertTrue(backend.waitForTCPCreateEntry(timeout: 1))
        DispatchQueue.global().async {
            engine.shutdown { shutdown.fulfill() }
        }
        backend.releaseTCPCreate()

        wait(for: [made, shutdown], timeout: 2)
        guard case .success? = result.value else {
            return XCTFail("The gate-admitted create must finish before shutdown")
        }
        XCTAssertEqual(backend.flowDestroyCalls, 1)
        XCTAssertEqual(backend.engineDestroyCalls, 1)
    }

    func testTwoEnginesHaveIndependentHandlesAndLifecycles() throws {
        let backend = MockFlowCoreABI()
        let first = try makeEngine(backend: backend)
        let second = try makeEngine(backend: backend)
        _ = try first.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )

        let firstStopped = expectation(description: "first stopped")
        first.shutdown { firstStopped.fulfill() }
        wait(for: [firstStopped], timeout: 1)

        _ = try second.makeUDPFlow(source: udpSource(port: 50_003))
        let secondStopped = expectation(description: "second stopped")
        second.shutdown { secondStopped.fulfill() }
        wait(for: [secondStopped], timeout: 1)

        XCTAssertEqual(Set(backend.destroyedEngineAddresses).count, 2)
        XCTAssertEqual(backend.engineDestroyCalls, 2)
    }

    func testDroppingFacadeRetainsStorageThroughShutdownBarrier() throws {
        let backend = MockFlowCoreABI()
        var engine: FlowCoreEngine? = try makeEngine(backend: backend)
        _ = try engine?.makeTCPFlow(
            source: nil,
            destination: tcpDestination(port: 443)
        )
        engine = nil

        XCTAssertTrue(backend.waitForEngineDestroy(timeout: 1))
        XCTAssertEqual(backend.flowDestroyCalls, 1)
        XCTAssertEqual(backend.engineDestroyCalls, 1)
    }

    func testRawTCPCallbackCopiesBorrowedBytesSynchronously() {
        let completed = expectation(description: "raw callback")
        let response = LockedBox<FlowCoreABITCPReadResponse?>(nil)
        let context = FlowCoreTCPReadContext(
            expectedToken: 7,
            maximumBytes: 4
        ) { value in
            response.set(value)
            completed.fulfill()
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var bytes: [UInt8] = [1, 2, 3, 4]
        bytes.withUnsafeBufferPointer { buffer in
            flowCoreTCPReadCallback(
                token: 7,
                status: FlowCoreABIStatus.success,
                data: buffer.baseAddress,
                dataLength: buffer.count,
                endOfStream: 0,
                context: opaque
            )
        }
        bytes = [9, 9, 9, 9]
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(response.value?.data, Data([1, 2, 3, 4]))
    }

    func testRawUDPCallbackRejectsOversizedEndpointBeforeCopy() {
        let completed = expectation(description: "raw UDP callback")
        let response = LockedBox<FlowCoreABIUDPReadResponse?>(nil)
        let context = FlowCoreUDPReadContext(
            expectedToken: 8,
            maximumDatagrams: 1,
            maximumBytes: 16
        ) { value in
            response.set(value)
            completed.fulfill()
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var sentinel: UInt8 = 0
        withUnsafePointer(to: &sentinel) { pointer in
            var descriptor = clash_flow_datagram_v1_t(
                payload: nil,
                payload_length: 0,
                remote_endpoint: pointer,
                remote_endpoint_length:
                    FlowEndpointCodec.maximumEncodedBytes + 1
            )
            withUnsafePointer(to: &descriptor) { descriptorPointer in
                flowCoreUDPReadCallback(
                    token: 8,
                    status: FlowCoreABIStatus.success,
                    datagrams: descriptorPointer,
                    datagramCount: 1,
                    endOfStream: 0,
                    context: opaque
                )
            }
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(response.value?.malformed, true)
        XCTAssertEqual(response.value?.datagrams, [])
    }

    func testRawUDPCallbackCopiesBorrowedBytesSynchronously() {
        let completed = expectation(description: "raw UDP callback")
        let response = LockedBox<FlowCoreABIUDPReadResponse?>(nil)
        let context = FlowCoreUDPReadContext(
            expectedToken: 9,
            maximumDatagrams: 1,
            maximumBytes: 16
        ) { value in
            response.set(value)
            completed.fulfill()
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var payload: [UInt8] = [1, 2, 3, 4]
        var endpoint: [UInt8] = [5, 6, 7]
        payload.withUnsafeBufferPointer { payloadBuffer in
            endpoint.withUnsafeBufferPointer { endpointBuffer in
                var descriptor = clash_flow_datagram_v1_t(
                    payload: payloadBuffer.baseAddress,
                    payload_length: payloadBuffer.count,
                    remote_endpoint: endpointBuffer.baseAddress,
                    remote_endpoint_length: endpointBuffer.count
                )
                withUnsafePointer(to: &descriptor) { descriptorPointer in
                    flowCoreUDPReadCallback(
                        token: 9,
                        status: FlowCoreABIStatus.success,
                        datagrams: descriptorPointer,
                        datagramCount: 1,
                        endOfStream: 0,
                        context: opaque
                    )
                }
            }
        }
        payload = [9, 9, 9, 9]
        endpoint = [8, 8, 8]
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(
            response.value?.datagrams,
            [
                FlowCoreABIUDPDatagram(
                    payload: Data([1, 2, 3, 4]),
                    remoteEndpoint: Data([5, 6, 7])
                ),
            ]
        )
        XCTAssertEqual(response.value?.malformed, false)
    }

    func testRawUDPCallbackRejectsNonEmptyNilPayload() {
        let completed = expectation(description: "raw UDP nil payload callback")
        let response = LockedBox<FlowCoreABIUDPReadResponse?>(nil)
        let context = FlowCoreUDPReadContext(
            expectedToken: 10,
            maximumDatagrams: 1,
            maximumBytes: 16
        ) { value in
            response.set(value)
            completed.fulfill()
        }
        let opaque = Unmanaged.passRetained(context).toOpaque()
        var endpoint: UInt8 = 0
        withUnsafePointer(to: &endpoint) { endpointPointer in
            var descriptor = clash_flow_datagram_v1_t(
                payload: nil,
                payload_length: 1,
                remote_endpoint: endpointPointer,
                remote_endpoint_length: 1
            )
            withUnsafePointer(to: &descriptor) { descriptorPointer in
                flowCoreUDPReadCallback(
                    token: 10,
                    status: FlowCoreABIStatus.success,
                    datagrams: descriptorPointer,
                    datagramCount: 1,
                    endOfStream: 0,
                    context: opaque
                )
            }
        }
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(response.value?.malformed, true)
        XCTAssertEqual(response.value?.datagrams, [])
    }

    private func makeEngine(backend: MockFlowCoreABI) throws -> FlowCoreEngine {
        try FlowCoreEngine(
            profile: Data("proxies: []\nrules: []\n".utf8),
            runtimeDirectory: URL(fileURLWithPath: "/tmp/aetherroute-flow-tests"),
            configuration: .default,
            backend: backend
        )
    }

    private func activate(_ flow: any RustStagedFlowLifecycle) throws {
        let activated = expectation(description: "activated")
        let result = LockedBox<Result<Void, FlowIOError>?>(nil)
        flow.activate { value in
            result.set(value)
            activated.fulfill()
        }
        wait(for: [activated], timeout: 1)
        try result.value?.get()
    }

    private func tcpDestination(port: UInt16) -> FlowEndpoint {
        FlowEndpoint(
            host: .name("example.com"),
            port: port,
            transport: .tcp
        )
    }

    private func udpSource(port: UInt16) -> FlowEndpoint {
        FlowEndpoint(
            host: .ipv4([127, 0, 0, 1]),
            port: port,
            transport: .udp
        )
    }
}

private final class MockFlowCoreABI: FlowCoreABIBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var nextAddress = 0x1_000
    private var pendingTCPReads: [UInt: PendingTCPRead] = [:]
    private let tcpReadEntered = DispatchSemaphore(value: 0)
    private let tcpCreateEntered = DispatchSemaphore(value: 0)
    private let tcpCreateRelease = DispatchSemaphore(value: 0)
    private let engineDestroyed = DispatchSemaphore(value: 0)

    var tcpWriteStatus = FlowCoreABIStatus.success
    var tcpWriteReturnedTokenOffset: UInt64 = 0
    var holdTCPReadsUntilDestroy = false
    var blockTCPCreate = false
    var selectorSnapshotOverride: Data?

    private(set) var tcpWriteCalls = 0
    private(set) var flowDestroyCalls = 0
    private(set) var engineDestroyCalls = 0
    private(set) var destroyedEngineAddresses: [UInt] = []
    private(set) var selectorSelectCalls = 0
    private(set) var routingModeUpdates: [RoutingMode] = []
    private(set) var selectorLatencyCalls = 0
    private(set) var telemetryCalls = 0
    private var selectedSelectorMember = "Singapore"
    private let selectorMembers = ["Singapore", "Tokyo"]

    func engineCreate(
        profile _: Data,
        workingDirectory _: Data,
        configuration _: FlowCoreEngineConfiguration
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        (FlowCoreABIStatus.success, makeHandle())
    }

    func engineDestroy(_ engine: FlowCoreABIHandle) -> Int32 {
        lock.withLock {
            engineDestroyCalls += 1
            destroyedEngineAddresses.append(UInt(bitPattern: engine.rawValue))
        }
        engineDestroyed.signal()
        return FlowCoreABIStatus.success
    }

    func engineSetRoutingMode(
        _: FlowCoreABIHandle,
        mode: RoutingMode
    ) -> Int32 {
        lock.withLock { routingModeUpdates.append(mode) }
        return FlowCoreABIStatus.success
    }

    func selectorSnapshot(
        engine _: FlowCoreABIHandle,
        group: Data
    ) -> (status: Int32, snapshot: Data?) {
        guard String(data: group, encoding: .utf8) == "Route" else {
            return (FlowCoreABIStatus.invalidArgument, nil)
        }
        return lock.withLock {
            if let selectorSnapshotOverride {
                return (FlowCoreABIStatus.success, selectorSnapshotOverride)
            }
            return (
                FlowCoreABIStatus.success,
                Self.selectorSnapshotData(
                    members: selectorMembers,
                    selected: selectedSelectorMember
                )
            )
        }
    }

    func selectorSelect(
        engine _: FlowCoreABIHandle,
        group: Data,
        member: Data
    ) -> Int32 {
        guard
            String(data: group, encoding: .utf8) == "Route",
            let member = String(data: member, encoding: .utf8)
        else {
            return FlowCoreABIStatus.invalidArgument
        }
        return lock.withLock {
            guard selectorMembers.contains(member) else {
                return FlowCoreABIStatus.invalidArgument
            }
            selectedSelectorMember = member
            selectorSelectCalls += 1
            return FlowCoreABIStatus.success
        }
    }

    func selectorLatency(
        engine _: FlowCoreABIHandle,
        group: Data,
        url: Data,
        timeoutMilliseconds: UInt32
    ) -> (status: Int32, latencies: Data?) {
        guard
            String(data: group, encoding: .utf8) == "Route",
            String(data: url, encoding: .utf8)
                == "https://example.invalid/generate_204",
            timeoutMilliseconds == 5_000
        else { return (FlowCoreABIStatus.invalidArgument, nil) }
        return lock.withLock {
            selectorLatencyCalls += 1
            var data = Data([0x41, 0x52, 0x4c, 0x31])
            Self.appendUInt32(2, to: &data)
            for (member, delay) in [
                ("Singapore", UInt32(21)),
                ("Tokyo", UInt32.max),
            ] {
                let name = Data(member.utf8)
                Self.appendUInt32(UInt32(name.count), to: &data)
                data.append(name)
                Self.appendUInt32(delay, to: &data)
            }
            return (FlowCoreABIStatus.success, data)
        }
    }

    func selectorActiveLatency(
        engine: FlowCoreABIHandle,
        group: Data,
        url: Data,
        timeoutMilliseconds: UInt32
    ) -> (status: Int32, latencies: Data?) {
        selectorLatency(
            engine: engine,
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    func telemetrySnapshot(
        engine _: FlowCoreABIHandle,
        maximumConnections: UInt32
    ) -> (status: Int32, snapshot: Data?) {
        guard maximumConnections == 50 else {
            return (FlowCoreABIStatus.invalidArgument, nil)
        }
        return lock.withLock {
            telemetryCalls += 1
            let snapshot = NetworkTelemetrySnapshot(
                uploadBytesPerSecond: 100,
                downloadBytesPerSecond: 200,
                uploadTotal: 300,
                downloadTotal: 400,
                memoryBytes: 500,
                connections: []
            )
            return (
                FlowCoreABIStatus.success,
                try? NetworkTelemetryCodec.encode(snapshot)
            )
        }
    }

    func tcpCreate(
        engine _: FlowCoreABIHandle,
        source _: Data?,
        destination _: Data
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        if lock.withLock({ blockTCPCreate }) {
            tcpCreateEntered.signal()
            tcpCreateRelease.wait()
        }
        return (FlowCoreABIStatus.success, makeHandle())
    }

    func udpCreate(
        engine _: FlowCoreABIHandle,
        source _: Data
    ) -> (status: Int32, handle: FlowCoreABIHandle?) {
        (FlowCoreABIStatus.success, makeHandle())
    }

    func activate(_: FlowCoreABIHandle) -> Int32 {
        FlowCoreABIStatus.success
    }

    func tcpWrite(
        _: FlowCoreABIHandle,
        data _: Data,
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32 {
        let values = lock.withLock { () -> (Int32, UInt64) in
            tcpWriteCalls += 1
            return (tcpWriteStatus, tcpWriteReturnedTokenOffset)
        }
        if values.0 == FlowCoreABIStatus.success {
            completion(token &+ values.1, FlowCoreABIStatus.success)
        }
        return values.0
    }

    func tcpFinishWrite(
        _: FlowCoreABIHandle,
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32 {
        completion(token, FlowCoreABIStatus.success)
        return FlowCoreABIStatus.success
    }

    func tcpRead(
        _ flow: FlowCoreABIHandle,
        maximumBytes _: Int,
        token: UInt64,
        completion: @escaping @Sendable (FlowCoreABITCPReadResponse) -> Void
    ) -> Int32 {
        let shouldHold = lock.withLock { () -> Bool in
            if holdTCPReadsUntilDestroy {
                pendingTCPReads[UInt(bitPattern: flow.rawValue)] = PendingTCPRead(
                    token: token,
                    completion: completion
                )
                return true
            }
            return false
        }
        if shouldHold {
            tcpReadEntered.signal()
        } else {
            completion(
                FlowCoreABITCPReadResponse(
                    token: token,
                    status: FlowCoreABIStatus.success,
                    data: Data([1]),
                    endOfStream: false,
                    malformed: false
                )
            )
        }
        return FlowCoreABIStatus.success
    }

    func udpWrite(
        _: FlowCoreABIHandle,
        datagrams _: [FlowCoreABIUDPDatagram],
        token: UInt64,
        completion: @escaping @Sendable (UInt64, Int32) -> Void
    ) -> Int32 {
        completion(token, FlowCoreABIStatus.success)
        return FlowCoreABIStatus.success
    }

    func udpRead(
        _: FlowCoreABIHandle,
        maximumDatagrams _: Int,
        maximumBytes _: Int,
        token: UInt64,
        completion: @escaping @Sendable (FlowCoreABIUDPReadResponse) -> Void
    ) -> Int32 {
        completion(
            FlowCoreABIUDPReadResponse(
                token: token,
                status: FlowCoreABIStatus.success,
                datagrams: [],
                endOfStream: true,
                malformed: false
            )
        )
        return FlowCoreABIStatus.success
    }

    func cancel(_: FlowCoreABIHandle) -> Int32 {
        FlowCoreABIStatus.success
    }

    func destroy(_ flow: FlowCoreABIHandle) -> Int32 {
        let pending = lock.withLock { () -> PendingTCPRead? in
            flowDestroyCalls += 1
            return pendingTCPReads.removeValue(
                forKey: UInt(bitPattern: flow.rawValue)
            )
        }
        if let pending {
            pending.completion(
                FlowCoreABITCPReadResponse(
                    token: pending.token,
                    status: FlowCoreABIStatus.cancelled,
                    data: nil,
                    endOfStream: false,
                    malformed: false
                )
            )
        }
        return FlowCoreABIStatus.success
    }

    func waitForPendingTCPRead(timeout: TimeInterval) -> Bool {
        tcpReadEntered.wait(timeout: .now() + timeout) == .success
    }

    func waitForTCPCreateEntry(timeout: TimeInterval) -> Bool {
        tcpCreateEntered.wait(timeout: .now() + timeout) == .success
    }

    func releaseTCPCreate() {
        tcpCreateRelease.signal()
    }

    func waitForEngineDestroy(timeout: TimeInterval) -> Bool {
        engineDestroyed.wait(timeout: .now() + timeout) == .success
    }

    private func makeHandle() -> FlowCoreABIHandle {
        lock.withLock {
            nextAddress += 0x10
            return FlowCoreABIHandle(
                rawValue: UnsafeMutableRawPointer(bitPattern: nextAddress)!
            )
        }
    }

    private static func selectorSnapshotData(
        members: [String],
        selected: String?
    ) -> Data {
        var result = Data([0x41, 0x52, 0x53, 0x31])
        let selectedIndex = selected
            .flatMap { members.firstIndex(of: $0) }
            .map(UInt32.init) ?? UInt32.max
        appendUInt32(selectedIndex, to: &result)
        appendUInt32(UInt32(members.count), to: &result)
        for member in members {
            let bytes = Data(member.utf8)
            appendUInt32(UInt32(bytes.count), to: &result)
            result.append(bytes)
        }
        return result
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private struct PendingTCPRead: @unchecked Sendable {
        let token: UInt64
        let completion: @Sendable (FlowCoreABITCPReadResponse) -> Void
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        lock.withLock { stored }
    }

    func set(_ value: Value) {
        lock.withLock { stored = value }
    }

    func mutate(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&stored) }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}

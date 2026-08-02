@testable import AetherRouteKit
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxyProviderRuntimeTests: XCTestCase,
    @unchecked Sendable
{
    func testRunningProviderExposesControlPlaneAndRejectsAfterStop() throws {
        let telemetry = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 1_024,
            downloadBytesPerSecond: 4_096,
            uploadTotal: 8_192,
            downloadTotal: 32_768,
            memoryBytes: 16_384,
            connections: []
        )
        let engine = RuntimeFakeEngine(telemetry: telemetry)
        let controller = TransparentProxyProviderLifecycleController {
            try self.makeRuntime(engine: engine)
        }
        let started = expectation(description: "started")
        controller.start(
            installNetworkSettings: { $0(true) },
            completion: { error in
                XCTAssertNil(error)
                started.fulfill()
            }
        )
        wait(for: [started], timeout: 2)

        XCTAssertEqual(
            try controller.selectorSnapshot(group: "Route"),
            ProxySelectionState(
                selectedMember: "Tokyo",
                members: ["Tokyo", "DIRECT"]
            )
        )
        XCTAssertEqual(
            try controller.selectProxy(group: "Route", member: "DIRECT")
                .selectedMember,
            "DIRECT"
        )
        XCTAssertEqual(
            try controller.telemetrySnapshot(maximumConnections: 50),
            telemetry
        )

        let stopped = expectation(description: "stopped")
        controller.stop { stopped.fulfill() }
        wait(for: [stopped], timeout: 2)
        XCTAssertThrowsError(
            try controller.selectorSnapshot(group: "Route")
        ) {
            XCTAssertEqual(
                $0 as? TransparentProxySelectionError,
                .providerUnavailable
            )
        }
        XCTAssertThrowsError(
            try controller.telemetrySnapshot(maximumConnections: 50)
        ) {
            XCTAssertEqual(
                $0 as? TransparentProxySelectionError,
                .providerUnavailable
            )
        }
    }

    func testRuntimeExistsBeforeNetworkSettingsAndStartCompletesOnce() throws {
        let events = RuntimeEventRecorder()
        let engine = RuntimeFakeEngine(events: events)
        let controller = TransparentProxyProviderLifecycleController {
            events.append("runtime")
            return try self.makeRuntime(engine: engine)
        }
        let started = expectation(description: "started")
        let completionCount = RuntimeLockedBox(0)

        controller.start(
            installNetworkSettings: { completion in
                events.append("settings")
                completion(true)
                completion(false)
            },
            completion: { error in
                XCTAssertNil(error)
                completionCount.mutate { $0 += 1 }
                started.fulfill()
            }
        )

        wait(for: [started], timeout: 2)
        XCTAssertEqual(events.values.prefix(2), ["runtime", "settings"])
        XCTAssertEqual(completionCount.value, 1)
        XCTAssertEqual(controller.snapshot().phase, .running)
    }

    func testRuntimePreparationFailureNeverOffersNetworkSettings() {
        let settings = expectation(description: "settings")
        settings.isInverted = true
        let started = expectation(description: "start failed")
        let controller = TransparentProxyProviderLifecycleController {
            throw RuntimeTestError.injected
        }

        controller.start(
            installNetworkSettings: { _ in settings.fulfill() },
            completion: { error in
                XCTAssertEqual(error, .runtimePreparationFailed)
                started.fulfill()
            }
        )

        wait(for: [started, settings], timeout: 0.25)
        XCTAssertEqual(controller.snapshot().phase, .idle)
    }

    func testSettingsFailureShutsEngineBeforeReportingStartFailure() throws {
        let events = RuntimeEventRecorder()
        let engine = RuntimeFakeEngine(
            events: events,
            automaticallyShutsDown: false
        )
        let controller = TransparentProxyProviderLifecycleController {
            try self.makeRuntime(engine: engine)
        }
        let shutdownBegan = expectation(description: "shutdown began")
        engine.onShutdown = { shutdownBegan.fulfill() }
        let started = expectation(description: "start failed after shutdown")

        controller.start(
            installNetworkSettings: { completion in completion(false) },
            completion: { error in
                XCTAssertEqual(error, .networkSettingsInstallationFailed)
                XCTAssertEqual(events.values.last, "engine.shutdown.finished")
                started.fulfill()
            }
        )

        wait(for: [shutdownBegan], timeout: 2)
        XCTAssertEqual(controller.snapshot().phase, .stopping)
        engine.finishShutdown()
        wait(for: [started], timeout: 2)
        XCTAssertEqual(controller.snapshot().phase, .idle)
    }

    func testStopDuringRuntimePreparationCancelsStartWithoutInstallingSettings() {
        let factoryEntered = expectation(description: "factory entered")
        let releaseFactory = DispatchSemaphore(value: 0)
        let settings = expectation(description: "settings")
        settings.isInverted = true
        let startFinished = expectation(description: "start finished")
        let stopFinished = expectation(description: "stop finished")
        let controller = TransparentProxyProviderLifecycleController {
            factoryEntered.fulfill()
            _ = releaseFactory.wait(timeout: .now() + 2)
            return try self.makeRuntime(engine: RuntimeFakeEngine())
        }

        controller.start(
            installNetworkSettings: { _ in settings.fulfill() },
            completion: { error in
                XCTAssertEqual(error, .startCancelled)
                startFinished.fulfill()
            }
        )
        wait(for: [factoryEntered], timeout: 1)
        controller.stop { stopFinished.fulfill() }
        releaseFactory.signal()

        wait(
            for: [startFinished, stopFinished, settings],
            timeout: 1
        )
        XCTAssertEqual(controller.snapshot().phase, .idle)
    }

    func testStopClosesControllerAdmissionAndCoalescesCompletions() throws {
        let engine = RuntimeFakeEngine(automaticallyShutsDown: false)
        let controller = TransparentProxyProviderLifecycleController {
            try self.makeRuntime(engine: engine)
        }
        let started = expectation(description: "started")
        controller.start(
            installNetworkSettings: { $0(true) },
            completion: { error in
                XCTAssertNil(error)
                started.fulfill()
            }
        )
        wait(for: [started], timeout: 2)

        let stopOne = expectation(description: "stop one")
        let stopTwo = expectation(description: "stop two")
        controller.stop { stopOne.fulfill() }
        controller.stop { stopTwo.fulfill() }
        XCTAssertTrue(engine.waitForShutdown(timeout: 1))
        XCTAssertEqual(controller.snapshot().phase, .stopping)

        let components = makeTCPComponents()
        XCTAssertFalse(
            controller.claimTCP(
                components: components.ingress,
                source: nil,
                destination: tcpDestination()
            )
        )

        engine.finishShutdown()
        wait(for: [stopOne, stopTwo], timeout: 2)
        XCTAssertEqual(engine.shutdownCallCount, 1)
        XCTAssertEqual(controller.snapshot().phase, .idle)
    }

    func testStopDuringSuccessfulSettingsCallbackCompletesStartAndStopOnce() throws {
        let engine = RuntimeFakeEngine(automaticallyShutsDown: false)
        let controller = TransparentProxyProviderLifecycleController {
            try self.makeRuntime(engine: engine)
        }
        let installerEntered = expectation(description: "installer entered")
        let settingsCompletion = RuntimeLockedBox<
            (@Sendable (Bool) -> Void)?
        >(nil)
        let startFinished = expectation(description: "start cancelled")
        let stopFinished = expectation(description: "stop finished")
        let startCount = RuntimeLockedBox(0)
        let stopCount = RuntimeLockedBox(0)

        controller.start(
            installNetworkSettings: { completion in
                settingsCompletion.mutate { $0 = completion }
                installerEntered.fulfill()
            },
            completion: { error in
                XCTAssertEqual(error, .startCancelled)
                startCount.mutate { $0 += 1 }
                startFinished.fulfill()
            }
        )
        wait(for: [installerEntered], timeout: 1)
        controller.stop {
            stopCount.mutate { $0 += 1 }
            stopFinished.fulfill()
        }
        // A synchronous snapshot is a lifecycle-queue barrier; stopRequested
        // is now set while the settings callback is still pending.
        XCTAssertEqual(
            controller.snapshot().phase,
            .installingNetworkSettings
        )
        settingsCompletion.value?(true)
        settingsCompletion.value?(false)
        XCTAssertTrue(engine.waitForShutdown(timeout: 1))
        engine.finishShutdown()

        wait(for: [startFinished, stopFinished], timeout: 2)
        XCTAssertEqual(startCount.value, 1)
        XCTAssertEqual(stopCount.value, 1)
        XCTAssertEqual(engine.shutdownCallCount, 1)
        XCTAssertEqual(controller.snapshot().phase, .idle)
    }

    func testPendingRawClaimDrainsBeforeRuntimeEngineAndStopCompletion() throws {
        let events = RuntimeEventRecorder()
        let engine = RuntimeFakeEngine(
            events: events,
            automaticallyShutsDown: false
        )
        let controller = TransparentProxyProviderLifecycleController {
            try self.makeRuntime(engine: engine)
        }
        let started = expectation(description: "started")
        controller.start(
            installNetworkSettings: { $0(true) },
            completion: { _ in started.fulfill() }
        )
        wait(for: [started], timeout: 1)

        let access = RuntimeFailClosedAccess(events: events)
        XCTAssertEqual(
            controller.withFlowAdmission {
                controller.claimAndCloseRawFlow(access: access)
            },
            true
        )
        XCTAssertEqual(
            controller.snapshot().pendingFailClosedClaimCount,
            1
        )
        let stopped = expectation(description: "provider stopped")
        controller.stop { stopped.fulfill() }
        XCTAssertTrue(
            waitUntil(timeout: 1) {
                controller.snapshot().phase == .stopping
            }
        )
        XCTAssertFalse(engine.waitForShutdown(timeout: 0.05))
        XCTAssertEqual(events.values, ["raw.open"])

        access.completeOpen()
        XCTAssertTrue(engine.waitForShutdown(timeout: 1))
        XCTAssertEqual(
            events.values,
            [
                "raw.open",
                "raw.close",
                "engine.shutdown.started",
            ]
        )
        engine.finishShutdown()
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(events.values.last, "engine.shutdown.finished")
    }

    func testStopWaitsForEnteredHandlerToRegisterRawClaimBeforeSealing() throws {
        let engine = RuntimeFakeEngine(automaticallyShutsDown: false)
        let controller = TransparentProxyProviderLifecycleController {
            try self.makeRuntime(engine: engine)
        }
        let started = expectation(description: "started")
        controller.start(
            installNetworkSettings: { $0(true) },
            completion: { _ in started.fulfill() }
        )
        wait(for: [started], timeout: 1)

        let handlerEntered = expectation(description: "handler entered")
        let handlerFinished = expectation(description: "handler finished")
        let releaseHandler = DispatchSemaphore(value: 0)
        let access = RuntimeFailClosedAccess()
        DispatchQueue.global().async {
            _ = controller.withFlowAdmission {
                handlerEntered.fulfill()
                _ = releaseHandler.wait(timeout: .now() + 2)
                XCTAssertTrue(
                    controller.claimAndCloseRawFlow(access: access)
                )
            }
            handlerFinished.fulfill()
        }
        wait(for: [handlerEntered], timeout: 1)

        let stopped = expectation(description: "stopped")
        controller.stop { stopped.fulfill() }
        XCTAssertTrue(
            waitUntil(timeout: 1) {
                controller.snapshot().phase == .stopping
            }
        )
        XCTAssertFalse(engine.waitForShutdown(timeout: 0.05))

        releaseHandler.signal()
        wait(for: [handlerFinished], timeout: 1)
        XCTAssertEqual(
            controller.snapshot().pendingFailClosedClaimCount,
            1
        )
        XCTAssertFalse(engine.waitForShutdown(timeout: 0.05))

        access.completeOpen()
        XCTAssertTrue(engine.waitForShutdown(timeout: 1))
        engine.finishShutdown()
        wait(for: [stopped], timeout: 1)
    }

    func testRuntimeStopWaitsForRegistryBeforeEngineShutdown() throws {
        let events = RuntimeEventRecorder()
        let engine = RuntimeFakeEngine(events: events)
        let registry = try TransparentProxySessionRegistry()
        let budget = try FlowResourceBudget()
        let pool = try SyntheticSourceEndpointPool()
        let runtime = TransparentProxyFlowRuntime(
            engine: engine,
            identityGuard: .init(),
            registry: registry,
            coordinator: TransparentProxyIngressCoordinator(
                resourceBudget: budget,
                sourceEndpointPool: pool,
                registry: registry
            )
        )
        let session = RuntimeRegistrySession(
            registry: registry,
            events: events
        )
        try registry.insert(session)
        let stopped = expectation(description: "runtime stopped")

        runtime.stop { stopped.fulfill() }
        XCTAssertEqual(events.values, ["session.cancel"])
        XCTAssertEqual(engine.shutdownCallCount, 0)

        session.finish()
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(
            events.values,
            [
                "session.cancel",
                "session.finished",
                "engine.shutdown.started",
                "engine.shutdown.finished",
            ]
        )
    }

    func testRuntimeRejectsNewFlowOpenThenCloseAfterStopBegins() throws {
        let engine = RuntimeFakeEngine(automaticallyShutsDown: false)
        let runtime = try makeRuntime(engine: engine)
        let opening = RuntimeOpening()
        let flow = RuntimeTCPFlow()
        let identity = TransparentProxyAppleFlowIdentity()
        let components = TransparentTCPIngressComponents(
            opening: opening,
            flow: flow,
            openingIdentity: identity,
            flowIdentity: identity
        )

        runtime.stop {}
        _ = runtime.claimTCP(
            components: components,
            source: nil,
            destination: tcpDestination()
        )

        XCTAssertEqual(opening.openCallCount, 1)
        XCTAssertEqual(flow.cancelAndDrainCallCount, 1)
        XCTAssertEqual(engine.makeTCPCallCount, 0)
        XCTAssertFalse(runtime.snapshot().isAcceptingFlows)
        engine.finishShutdown()
    }

    func testRuntimeReportsOnlyFixedIngressFailurePoint() throws {
        let engine = RuntimeFakeEngine()
        let failures = RuntimeLockedBox(
            [TransparentProxyIngressFailurePoint]()
        )
        let runtime = try TransparentProxyFlowRuntime(
            engine: engine,
            failureObserver: { point in
                failures.mutate { $0.append(point) }
            }
        )

        _ = runtime.claimTCP(
            components: makeTCPComponents().ingress,
            source: nil,
            destination: tcpDestination()
        )

        XCTAssertEqual(failures.value, [.rustStagedCreation])
        XCTAssertEqual(engine.makeTCPCallCount, 1)
    }

    func testIdentityControllerBypassesOnlyVerifiedSelf() {
        let token = Data(repeating: 0xA5, count: 32)
        let verified = TransparentProxySelfIdentityGuard(
            identityVerifier: RuntimeIdentityVerifier(
                processIdentifier: 410,
                requirementSucceeds: true
            ),
            currentProcessIdentifier: { 410 }
        )
        let otherProcess = TransparentProxySelfIdentityGuard(
            identityVerifier: RuntimeIdentityVerifier(
                processIdentifier: 411,
                requirementSucceeds: true
            ),
            currentProcessIdentifier: { 410 }
        )
        let verifiedController = TransparentProxyProviderLifecycleController(
            identityGuard: verified,
            runtimeFactory: { throw RuntimeTestError.injected }
        )
        let otherController = TransparentProxyProviderLifecycleController(
            identityGuard: otherProcess,
            runtimeFactory: { throw RuntimeTestError.injected }
        )

        XCTAssertEqual(
            verifiedController.identityDisposition(auditToken: token),
            .bypass
        )
        XCTAssertEqual(
            otherController.identityDisposition(auditToken: token),
            .proxy
        )
        XCTAssertEqual(
            verifiedController.identityDisposition(auditToken: nil),
            .reject
        )
        XCTAssertEqual(
            verifiedController.identityDisposition(
                auditToken: Data(repeating: 0, count: 31)
            ),
            .reject
        )
    }

    func testRawFailClosedRegistryOrdersOpenBeforeCloseAndOwnsStopBarrier() {
        let access = RuntimeFailClosedAccess()
        let registry = NetworkExtensionFailClosedFlowRegistry()
        XCTAssertTrue(registry.claim(access: access))
        XCTAssertEqual(registry.activeClaimCount, 1)
        XCTAssertEqual(access.events, ["open"])

        let stopped = expectation(description: "raw registry stopped")
        registry.stopAll { stopped.fulfill() }
        XCTAssertEqual(registry.activeClaimCount, 1)

        access.completeOpen()
        XCTAssertEqual(access.events, ["open", "close"])
        wait(for: [stopped], timeout: 1)
        XCTAssertEqual(registry.activeClaimCount, 0)
    }

    func testEncryptedProfileLoadsOnlyIntoMemoryAndPrivateRuntimeDirectory() throws {
        try withTemporaryDirectory { directory in
            let store = ActiveProfileStore(
                directoryURL: directory,
                keyStore: InMemoryProfileKeyStore(
                    keys: [
                        EncryptedProfileCodec.defaultKeyID:
                            Data(repeating: 0x44, count: 32),
                    ]
                )
            )
            let profile = validProfile(password: "runtime-secret-sentinel")
            try store.saveValidated(
                data: profile,
                suggestedName: "Runtime test"
            )

            let input = try TransparentProxyRuntimeInputLoader.load(
                store: store,
                fileManager: .default
            )

            XCTAssertEqual(input.profile, profile)
            XCTAssertEqual(input.runtimeDirectory.lastPathComponent, "FlowCore")
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: input.runtimeDirectory.path
                ),
                []
            )
            let attributes = try FileManager.default.attributesOfItem(
                atPath: input.runtimeDirectory.path
            )
            let permissions = try XCTUnwrap(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertEqual(permissions & 0o777, 0o700)
            XCTAssertEqual(
                try input.runtimeDirectory.resourceValues(
                    forKeys: [.isExcludedFromBackupKey]
                ).isExcludedFromBackup,
                true
            )

            let ciphertext = try Data(
                contentsOf: directory.appendingPathComponent(
                    "active-profile.v2.json"
                )
            )
            XCTAssertFalse(ciphertext.contains(Data("runtime-secret-sentinel".utf8)))
        }
    }

    func testRuntimeDirectorySymlinkIsRejectedBeforeWritingOutsideContainer() throws {
        try withTemporaryDirectory { parent in
            let base = parent.appendingPathComponent("Application Support")
            let outside = parent.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(
                at: base,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: base.appendingPathComponent("Runtime"),
                withDestinationURL: outside
            )

            XCTAssertThrowsError(
                try TransparentProxyRuntimeInputLoader.prepareRuntimeDirectory(
                    beneath: base,
                    fileManager: .default
                )
            ) { error in
                XCTAssertEqual(
                    error as? TransparentProxyRuntimeInputError,
                    .unsafeRuntimeDirectory
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: outside.appendingPathComponent("FlowCore").path
                )
            )
        }
    }

    func testApplicationSupportBaseSymlinkIsRejected() throws {
        try withTemporaryDirectory { parent in
            let outside = parent.appendingPathComponent("Outside")
            let base = parent.appendingPathComponent("Application Support")
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: base,
                withDestinationURL: outside
            )

            XCTAssertThrowsError(
                try TransparentProxyRuntimeInputLoader.prepareRuntimeDirectory(
                    beneath: base,
                    fileManager: .default
                )
            ) { error in
                XCTAssertEqual(
                    error as? TransparentProxyRuntimeInputError,
                    .unsafeRuntimeDirectory
                )
            }
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: outside.appendingPathComponent("Runtime").path
                )
            )
        }
    }

    func testExistingFlowCoreSymlinkIsRejectedBeforeWritingOutsideContainer() throws {
        try withTemporaryDirectory { parent in
            let base = parent.appendingPathComponent("Application Support")
            let runtime = base.appendingPathComponent("Runtime")
            let outside = parent.appendingPathComponent("Outside")
            try FileManager.default.createDirectory(
                at: runtime,
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: outside,
                withIntermediateDirectories: true
            )
            try FileManager.default.createSymbolicLink(
                at: runtime.appendingPathComponent("FlowCore"),
                withDestinationURL: outside
            )

            XCTAssertThrowsError(
                try TransparentProxyRuntimeInputLoader.prepareRuntimeDirectory(
                    beneath: base,
                    fileManager: .default
                )
            ) { error in
                XCTAssertEqual(
                    error as? TransparentProxyRuntimeInputError,
                    .unsafeRuntimeDirectory
                )
            }
            XCTAssertEqual(
                try FileManager.default.contentsOfDirectory(
                    atPath: outside.path
                ),
                []
            )
        }
    }

    private func makeRuntime(
        engine: RuntimeFakeEngine
    ) throws -> TransparentProxyFlowRuntime {
        try TransparentProxyFlowRuntime(engine: engine)
    }

    private func makeTCPComponents() -> NetworkExtensionTestTCPComponents {
        let identity = TransparentProxyAppleFlowIdentity()
        return NetworkExtensionTestTCPComponents(
            ingress: TransparentTCPIngressComponents(
                opening: RuntimeOpening(),
                flow: RuntimeTCPFlow(),
                openingIdentity: identity,
                flowIdentity: identity
            )
        )
    }

    private func tcpDestination() -> FlowEndpoint {
        FlowEndpoint(
            host: .ipv4([127, 0, 0, 1]),
            port: 443,
            transport: .tcp
        )
    }

    private func validProfile(password: String) -> Data {
        Data(
            """
            proxies:
              - name: runtime-test
                type: trojan
                server: example.com
                port: 443
                password: \(password)
            """.utf8
        )
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        return condition()
    }
}

private struct NetworkExtensionTestTCPComponents {
    let ingress: TransparentTCPIngressComponents
}

private enum RuntimeTestError: Error {
    case injected
}

private final class RuntimeEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.withLock { storage }
    }

    func append(_ value: String) {
        lock.withLock { storage.append(value) }
    }
}

private final class RuntimeLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value {
        lock.withLock { storage }
    }

    func mutate(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&storage) }
    }
}

private final class RuntimeFakeEngine:
    TransparentProxyFlowEngine,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let events: RuntimeEventRecorder?
    private let automaticallyShutsDown: Bool
    private let telemetry: NetworkTelemetrySnapshot
    private var shutdownCompletions: [@Sendable () -> Void] = []
    private let shutdownSemaphore = DispatchSemaphore(value: 0)
    private var shutdownCalls = 0
    private var tcpCalls = 0
    private var selectorState = ProxySelectionState(
        selectedMember: "Tokyo",
        members: ["Tokyo", "DIRECT"]
    )
    var onShutdown: (@Sendable () -> Void)?

    init(
        events: RuntimeEventRecorder? = nil,
        automaticallyShutsDown: Bool = true,
        telemetry: NetworkTelemetrySnapshot = .empty
    ) {
        self.events = events
        self.automaticallyShutsDown = automaticallyShutsDown
        self.telemetry = telemetry
    }

    var shutdownCallCount: Int { lock.withLock { shutdownCalls } }
    var makeTCPCallCount: Int { lock.withLock { tcpCalls } }

    func makeTCPFlow(
        source: FlowEndpoint?,
        destination: FlowEndpoint
    ) throws -> any RustTCPFlowBridge {
        lock.withLock { tcpCalls += 1 }
        throw RuntimeTestError.injected
    }

    func makeUDPFlow(
        source: FlowEndpoint
    ) throws -> any RustUDPFlowBridge {
        throw RuntimeTestError.injected
    }

    func selectorSnapshot(group: String) throws -> ProxySelectionState {
        try lock.withLock {
            guard group == "Route" else {
                throw TransparentProxySelectionError.unsupported
            }
            return selectorState
        }
    }

    func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionState {
        try lock.withLock {
            guard group == "Route", selectorState.members.contains(member) else {
                throw TransparentProxySelectionError.unsupported
            }
            selectorState = ProxySelectionState(
                selectedMember: member,
                members: selectorState.members
            )
            return selectorState
        }
    }

    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        guard maximumConnections > 0,
              maximumConnections <= NetworkTelemetryCodec.maximumConnections
        else {
            throw TransparentProxySelectionError.unsupported
        }
        return telemetry
    }

    func shutdown(completion: @escaping @Sendable () -> Void) {
        events?.append("engine.shutdown.started")
        lock.withLock {
            shutdownCalls += 1
            shutdownCompletions.append(completion)
        }
        shutdownSemaphore.signal()
        onShutdown?()
        if automaticallyShutsDown {
            finishShutdown()
        }
    }

    func waitForShutdown(timeout: TimeInterval) -> Bool {
        shutdownSemaphore.wait(timeout: .now() + timeout) == .success
    }

    func finishShutdown() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            defer { shutdownCompletions.removeAll() }
            return shutdownCompletions
        }
        guard !completions.isEmpty else { return }
        events?.append("engine.shutdown.finished")
        completions.forEach { $0() }
    }
}

private final class RuntimeRegistrySession:
    TransparentProxySessionLifetime,
    @unchecked Sendable
{
    let sessionID = UUID()
    private weak var registry: TransparentProxySessionRegistry?
    private let events: RuntimeEventRecorder

    init(
        registry: TransparentProxySessionRegistry,
        events: RuntimeEventRecorder
    ) {
        self.registry = registry
        self.events = events
    }

    func cancel() {
        events.append("session.cancel")
    }

    func finish() {
        events.append("session.finished")
        registry?.didTerminate(sessionID: sessionID)
    }
}

private final class RuntimeOpening: AppleProxyFlowOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var calls = 0

    var openCallCount: Int { lock.withLock { calls } }

    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        lock.withLock { calls += 1 }
        completion(.success(()))
    }
}

private final class RuntimeTCPFlow: TransparentTCPFlowIO,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var drainCalls = 0

    var cancelAndDrainCallCount: Int { lock.withLock { drainCalls } }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        completion(token, .failure(.cancelled))
    }

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        completion(token, .failure(.cancelled))
    }

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        completion(token, .failure(.cancelled))
    }
    func cancel() {}

    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        lock.withLock { drainCalls += 1 }
        completion()
    }
}

private struct RuntimeIdentityVerifier: TransparentProxyFlowIdentityVerifying {
    let auditTokenByteCount = 32
    let processIdentifier: pid_t
    let requirementSucceeds: Bool

    func processIdentifier(from auditToken: Data) throws -> pid_t {
        processIdentifier
    }

    func validateCurrentDesignatedRequirement(for auditToken: Data) throws {
        if !requirementSucceeds { throw RuntimeTestError.injected }
    }
}

private final class RuntimeFailClosedAccess:
    FailClosedAppleFlowAccess,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let recorder: RuntimeEventRecorder?
    private var storage: [String] = []
    private var openCompletion: (@Sendable (Result<Void, FlowIOError>) -> Void)?

    init(events: RuntimeEventRecorder? = nil) {
        recorder = events
    }

    var events: [String] { lock.withLock { storage } }

    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        lock.withLock {
            storage.append("open")
            openCompletion = completion
        }
        recorder?.append("raw.open")
    }

    func close(completion: @escaping @Sendable () -> Void) {
        lock.withLock { storage.append("close") }
        recorder?.append("raw.close")
        completion()
    }

    func completeOpen() {
        let completion = lock.withLock { () -> (@Sendable (Result<Void, FlowIOError>) -> Void)? in
            defer { openCompletion = nil }
            return openCompletion
        }
        completion?(.success(()))
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

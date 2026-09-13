import AetherRouteKit
import Foundation
@preconcurrency import NetworkExtension
import OSLog

private enum TransparentLifecycleLog {
    static let logger = AppLog.logger(category: AppLog.Category.proxyRuntime)
}

/// The narrow engine surface owned by one transparent-proxy provider runtime.
/// The production conformance lives in AetherRouteFlowCoreBridge; tests use an
/// in-memory engine and never load or start a Network Extension.
public protocol TransparentProxyFlowEngine: AnyObject, Sendable {
    func makeTCPFlow(
        source: FlowEndpoint?,
        destination: FlowEndpoint
    ) throws -> any RustTCPFlowBridge

    func makeUDPFlow(
        source: FlowEndpoint
    ) throws -> any RustUDPFlowBridge

    func selectorSnapshot(group: String) throws -> ProxySelectionState

    func setRoutingMode(_ mode: RoutingMode) throws

    func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionState

    func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState

    func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState

    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot

    func shutdown(completion: @escaping @Sendable () -> Void)
}

public extension TransparentProxyFlowEngine {
    func setRoutingMode(_: RoutingMode) throws {
        throw TransparentProxySelectionError.unsupported
    }

    func selectorSnapshot(group _: String) throws -> ProxySelectionState {
        throw TransparentProxySelectionError.unsupported
    }

    func selectProxy(
        group _: String,
        member _: String
    ) throws -> ProxySelectionState {
        throw TransparentProxySelectionError.unsupported
    }

    func testProxyLatency(
        group _: String,
        url _: String,
        timeoutMilliseconds _: UInt32
    ) throws -> ProxyLatencyState {
        throw TransparentProxySelectionError.unsupported
    }

    func testActiveProxyLatency(
        group _: String,
        url _: String,
        timeoutMilliseconds _: UInt32
    ) throws -> ProxyLatencyState {
        throw TransparentProxySelectionError.unsupported
    }

    func telemetrySnapshot(
        maximumConnections _: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        throw TransparentProxySelectionError.unsupported
    }
}

public enum TransparentProxySelectionError: Error, Sendable, Equatable {
    case unsupported
    case runtimeStopping
    case providerUnavailable
}

public enum TransparentProxyProviderLifecycleError:
    LocalizedError,
    Sendable,
    Equatable
{
    case alreadyActive
    case runtimePreparationFailed
    case networkSettingsInstallationFailed
    case startCancelled

    public var errorDescription: String? {
        switch self {
        case .alreadyActive:
            "The transparent proxy is already starting, running, or stopping."
        case .runtimePreparationFailed:
            "The transparent proxy runtime could not be prepared."
        case .networkSettingsInstallationFailed:
            "The transparent proxy network settings could not be installed."
        case .startCancelled:
            "Transparent proxy startup was cancelled."
        }
    }
}

public struct TransparentProxyRuntimeSnapshot: Sendable, Equatable {
    public let isAcceptingFlows: Bool
    public let registry: TransparentProxySessionRegistrySnapshot
}

/// One FlowOnly data plane. It owns the engine, weighted admission, synthetic
/// UDP source namespace, session registry, ingress transaction coordinator,
/// and the only identity guard permitted to authorize direct self-egress.
///
/// Admission and stop share one lock. A flow is therefore either inserted in
/// the registry before stop closes admission, or is rejected through the same
/// open-then-close transaction. The stop completion is a joint Apple/Rust
/// callback barrier: registry.stopAll -> engine.shutdown.
public final class TransparentProxyFlowRuntime: @unchecked Sendable {
    private let engine: any TransparentProxyFlowEngine
    private let identityGuard: TransparentProxySelfIdentityGuard
    private let registry: TransparentProxySessionRegistry
    private let coordinator: TransparentProxyIngressCoordinator
    private let admissionLock = NSLock()
    private var acceptingFlows = true
    private var stopStarted = false
    private var stopFinished = false
    private var stopCompletions: [@Sendable () -> Void] = []

    public convenience init(
        engine: any TransparentProxyFlowEngine,
        identityGuard: TransparentProxySelfIdentityGuard = .init(),
        maximumFlowBytes: Int = FlowResourceBudget.defaultMaximumBytes,
        maximumSessionCount: Int =
            TransparentProxySessionRegistry.defaultMaximumSessionCount,
        failureObserver: @escaping
            TransparentProxyIngressCoordinator.FailureObserver = { _ in }
    ) throws {
        let registry = try TransparentProxySessionRegistry(
            maximumSessionCount: maximumSessionCount
        )
        let resourceBudget = try FlowResourceBudget(
            maximumBytes: maximumFlowBytes
        )
        let sourceEndpointPool = try SyntheticSourceEndpointPool()
        self.init(
            engine: engine,
            identityGuard: identityGuard,
            registry: registry,
            coordinator: TransparentProxyIngressCoordinator(
                resourceBudget: resourceBudget,
                sourceEndpointPool: sourceEndpointPool,
                registry: registry,
                failureObserver: failureObserver
            )
        )
    }

    init(
        engine: any TransparentProxyFlowEngine,
        identityGuard: TransparentProxySelfIdentityGuard,
        registry: TransparentProxySessionRegistry,
        coordinator: TransparentProxyIngressCoordinator
    ) {
        self.engine = engine
        self.identityGuard = identityGuard
        self.registry = registry
        self.coordinator = coordinator
    }

    public func identityDisposition(
        for flow: NEAppProxyFlow
    ) -> TransparentProxySelfIdentityGuard.Disposition {
        identityGuard.evaluate(flow: flow).disposition
    }

    func identityDisposition(
        auditToken: Data?
    ) -> TransparentProxySelfIdentityGuard.Disposition {
        identityGuard.evaluate(auditToken: auditToken).disposition
    }

    /// Returns a claimed result for both successful and failed admission. The
    /// caller must return true to NetworkExtension after invoking this method.
    @discardableResult
    public func claimTCP(
        components: TransparentTCPIngressComponents,
        source: FlowEndpoint?,
        destination: FlowEndpoint
    ) -> TransparentProxyIngressClaimResult {
        admissionLock.lock()
        guard acceptingFlows else {
            admissionLock.unlock()
            return coordinator.rejectTCP(components: components)
        }
        let result = coordinator.claimTCP(components: components) { [engine] in
            try engine.makeTCPFlow(
                source: source,
                destination: destination
            )
        }
        admissionLock.unlock()
        return result
    }

    /// UDP source identity is validated and, when absent, leased by the
    /// coordinator before the engine can create a flow handle.
    @discardableResult
    public func claimUDP(
        components: TransparentUDPIngressComponents,
        localSource: FlowEndpoint?
    ) -> TransparentProxyIngressClaimResult {
        admissionLock.lock()
        guard acceptingFlows else {
            admissionLock.unlock()
            return coordinator.rejectUDP(components: components)
        }
        let result = coordinator.claimUDP(
            components: components,
            localSource: localSource
        ) { [engine] source in
            try engine.makeUDPFlow(source: source)
        }
        admissionLock.unlock()
        return result
    }

    public func stop(completion: @escaping @Sendable () -> Void) {
        TransparentLifecycleLog.logger.info("stage=flowRuntimeStop requested")
        let action = admissionLock.withLock { () -> RuntimeStopAction in
            if stopFinished {
                return .completeNow
            }
            stopCompletions.append(completion)
            guard !stopStarted else { return .wait }
            acceptingFlows = false
            stopStarted = true
            return .start
        }

        switch action {
        case .completeNow:
            TransparentLifecycleLog.logger.info("stage=flowRuntimeStop alreadyComplete")
            completion()
        case .wait:
            TransparentLifecycleLog.logger.info("stage=flowRuntimeStop coalesced")
            break
        case .start:
            TransparentLifecycleLog.logger.info("stage=flowRuntimeDrain begin")
            registry.stopAll { [self] in
                TransparentLifecycleLog.logger.info("stage=flowRuntimeDrain success")
                TransparentLifecycleLog.logger.info("stage=flowEngineShutdown begin")
                engine.shutdown { [self] in
                    TransparentLifecycleLog.logger.info("stage=flowEngineShutdown success")
                    finishStop()
                }
            }
        }
    }

    public func resetNetworkState() {
        admissionLock.withLock {
            guard acceptingFlows else { return }
            TransparentLifecycleLog.logger.info("stage=flowRuntimeResetNetwork begin")
            registry.cancelActiveSessions()
            TransparentLifecycleLog.logger.info("stage=flowRuntimeResetNetwork success")
        }
    }

    public func snapshot() -> TransparentProxyRuntimeSnapshot {
        TransparentProxyRuntimeSnapshot(
            isAcceptingFlows: admissionLock.withLock { acceptingFlows },
            registry: registry.snapshot()
        )
    }

    public func selectorSnapshot(
        group: String
    ) throws -> ProxySelectionState {
        try admissionLock.withLock {
            guard acceptingFlows else {
                throw TransparentProxySelectionError.runtimeStopping
            }
            return try engine.selectorSnapshot(group: group)
        }
    }

    public func setRoutingMode(_ mode: RoutingMode) throws {
        try admissionLock.withLock {
            guard acceptingFlows else {
                throw TransparentProxySelectionError.runtimeStopping
            }
            try engine.setRoutingMode(mode)
        }
    }

    public func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionState {
        try admissionLock.withLock {
            guard acceptingFlows else {
                throw TransparentProxySelectionError.runtimeStopping
            }
            return try engine.selectProxy(group: group, member: member)
        }
    }

    public func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        try admissionLock.withLock {
            guard acceptingFlows else {
                throw TransparentProxySelectionError.runtimeStopping
            }
            return try engine.testProxyLatency(
                group: group,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
    }

    public func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        try admissionLock.withLock {
            guard acceptingFlows else {
                throw TransparentProxySelectionError.runtimeStopping
            }
            return try engine.testActiveProxyLatency(
                group: group,
                url: url,
                timeoutMilliseconds: timeoutMilliseconds
            )
        }
    }

    public func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        try admissionLock.withLock {
            guard acceptingFlows else {
                throw TransparentProxySelectionError.runtimeStopping
            }
            return try engine.telemetrySnapshot(
                maximumConnections: maximumConnections
            )
        }
    }

    private func finishStop() {
        let completions = admissionLock.withLock {
            guard !stopFinished else { return [@Sendable () -> Void]() }
            stopFinished = true
            defer { stopCompletions.removeAll(keepingCapacity: false) }
            return stopCompletions
        }
        TransparentLifecycleLog.logger.info(
            "stage=flowRuntimeStop complete callbacks=\(completions.count, privacy: .public)"
        )
        completions.forEach { $0() }
    }

    private enum RuntimeStopAction {
        case completeNow
        case wait
        case start
    }
}

public struct TransparentProxyProviderLifecycleSnapshot:
    Sendable,
    Equatable
{
    public enum Phase: Sendable, Equatable {
        case idle
        case preparingRuntime
        case installingNetworkSettings
        case running
        case stopping
    }

    public let phase: Phase
    public let pendingFailClosedClaimCount: Int
}

/// Pure-testable provider lifecycle state machine. Runtime construction is
/// performed off the NetworkExtension callback queue. Network settings are
/// not offered for installation until a complete engine-backed runtime exists.
/// Stop closes provider admission before waiting for registry and engine
/// barriers, and every external completion is delivered at most once.
public final class TransparentProxyProviderLifecycleController:
    @unchecked Sendable
{
    public typealias RuntimeFactory =
        @Sendable () throws -> TransparentProxyFlowRuntime
    public typealias SettingsInstaller = @Sendable (
        @escaping @Sendable (Bool) -> Void
    ) -> Void
    public typealias StartCompletion = @Sendable (
        TransparentProxyProviderLifecycleError?
    ) -> Void
    public typealias StopCompletion = @Sendable () -> Void

    private let runtimeFactory: RuntimeFactory
    private let identityGuard: TransparentProxySelfIdentityGuard
    private let flowHandlerGate = ProviderFlowHandlerGate()
    private let failClosedRegistry = NetworkExtensionFailClosedFlowRegistry()
    private let lifecycleQueue = DispatchQueue(
        label: "com.example.aetherroute.transparent-provider.lifecycle"
    )
    private let preparationQueue = DispatchQueue(
        label: "com.example.aetherroute.transparent-provider.prepare",
        qos: .userInitiated
    )
    private let callbackQueue = DispatchQueue(
        label: "com.example.aetherroute.transparent-provider.callbacks"
    )

    // Access is confined to lifecycleQueue.
    private var phase: TransparentProxyProviderLifecycleSnapshot.Phase = .idle
    private var operationID: UUID?
    private var runtime: TransparentProxyFlowRuntime?
    private var pendingStart: ProviderStartCompletion?
    private var pendingStartError: TransparentProxyProviderLifecycleError?
    private var stopRequested = false
    private var stopCompletions: [ProviderStopCompletion] = []

    public init(
        identityGuard: TransparentProxySelfIdentityGuard = .init(),
        runtimeFactory: @escaping RuntimeFactory
    ) {
        self.identityGuard = identityGuard
        self.runtimeFactory = runtimeFactory
    }

    public func start(
        runtimeFactory startRuntimeFactory: RuntimeFactory? = nil,
        installNetworkSettings: @escaping SettingsInstaller,
        completion: @escaping StartCompletion
    ) {
        TransparentLifecycleLog.logger.info("stage=lifecycleStart requested")
        let completion = ProviderStartCompletion(
            queue: callbackQueue,
            handler: completion
        )
        lifecycleQueue.async { [self] in
            guard phase == .idle else {
                TransparentLifecycleLog.logger.error(
                    "stage=lifecycleStart rejected reason=alreadyActive"
                )
                completion.call(.alreadyActive)
                return
            }
            guard
                failClosedRegistry.resetForStart(),
                flowHandlerGate.resetForStart()
            else {
                TransparentLifecycleLog.logger.error(
                    "stage=lifecycleStart rejected reason=gateReset"
                )
                completion.call(.alreadyActive)
                return
            }

            let id = UUID()
            phase = .preparingRuntime
            TransparentLifecycleLog.logger.info(
                "stage=lifecyclePhase value=preparingRuntime"
            )
            operationID = id
            pendingStart = completion
            pendingStartError = nil
            stopRequested = false

            let selectedRuntimeFactory = startRuntimeFactory ?? runtimeFactory
            preparationQueue.async { [self, selectedRuntimeFactory] in
                TransparentLifecycleLog.logger.info("stage=runtimeFactory begin")
                let result: Result<TransparentProxyFlowRuntime, Error>
                do {
                    result = .success(try selectedRuntimeFactory())
                    TransparentLifecycleLog.logger.info("stage=runtimeFactory success")
                } catch {
                    TransparentLifecycleLog.logger.error(
                        "stage=runtimeFactory failed error=\(String(reflecting: error), privacy: .public)"
                    )
                    result = .failure(error)
                }
                lifecycleQueue.async { [self] in
                    completePreparation(
                        id: id,
                        result: result,
                        installer: installNetworkSettings
                    )
                }
            }
        }
    }

    public func stop(completion: @escaping StopCompletion) {
        TransparentLifecycleLog.logger.info("stage=lifecycleStop requested")
        let completion = ProviderStopCompletion(
            queue: callbackQueue,
            handler: completion
        )
        lifecycleQueue.async { [self] in
            switch phase {
            case .idle:
                TransparentLifecycleLog.logger.info("stage=lifecycleStop phase=idle")
                stopRequested = true
                stopCompletions.append(completion)
                phase = .stopping
                TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=stopping")
                beginProviderDrain()
            case .preparingRuntime, .installingNetworkSettings:
                TransparentLifecycleLog.logger.info(
                    "stage=lifecycleStop phase=startInFlight"
                )
                stopRequested = true
                stopCompletions.append(completion)
            case .running:
                TransparentLifecycleLog.logger.info("stage=lifecycleStop phase=running")
                stopRequested = true
                stopCompletions.append(completion)
                phase = .stopping
                TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=stopping")
                beginProviderDrain()
            case .stopping:
                TransparentLifecycleLog.logger.info("stage=lifecycleStop phase=stopping")
                stopCompletions.append(completion)
            }
        }
    }

    /// Brackets the complete synchronous provider handler, including identity
    /// evaluation, component construction, runtime admission, or raw rejection.
    /// Stop seals this gate and waits for every handler that entered before it
    /// can seal/drain the raw-claim registry.
    public func withFlowAdmission<Result>(
        _ operation: () -> Result
    ) -> Result? {
        guard flowHandlerGate.enter() else { return nil }
        defer { flowHandlerGate.leave() }
        return operation()
    }

    /// Must be called from a withFlowAdmission scope. A false result means the
    /// provider admission invariant was violated; production then uses only a
    /// synchronous terminal close because an asynchronous callback can no
    /// longer be admitted after stop.
    @discardableResult
    public func claimAndCloseRawFlow(_ flow: NEAppProxyFlow) -> Bool {
        failClosedRegistry.claimAndClose(flow)
    }

    @discardableResult
    func claimAndCloseRawFlow(
        access: any FailClosedAppleFlowAccess
    ) -> Bool {
        failClosedRegistry.claim(access: access)
    }

    public func identityDisposition(
        for flow: NEAppProxyFlow
    ) -> TransparentProxySelfIdentityGuard.Disposition {
        identityGuard.evaluate(flow: flow).disposition
    }

    func identityDisposition(
        auditToken: Data?
    ) -> TransparentProxySelfIdentityGuard.Disposition {
        identityGuard.evaluate(auditToken: auditToken).disposition
    }

    /// Returns false only when no running runtime was available. Once a
    /// runtime reference is obtained, its admission gate owns the stop race
    /// and always converts rejection into a claimed open-then-close result.
    @discardableResult
    public func claimTCP(
        components: TransparentTCPIngressComponents,
        source: FlowEndpoint?,
        destination: FlowEndpoint
    ) -> Bool {
        guard let runtime = runningRuntime() else { return false }
        runtime.claimTCP(
            components: components,
            source: source,
            destination: destination
        )
        return true
    }

    @discardableResult
    public func claimUDP(
        components: TransparentUDPIngressComponents,
        localSource: FlowEndpoint?
    ) -> Bool {
        guard let runtime = runningRuntime() else { return false }
        runtime.claimUDP(
            components: components,
            localSource: localSource
        )
        return true
    }

    public func snapshot() -> TransparentProxyProviderLifecycleSnapshot {
        lifecycleQueue.sync {
            TransparentProxyProviderLifecycleSnapshot(
                phase: phase,
                pendingFailClosedClaimCount:
                    failClosedRegistry.activeClaimCount
            )
        }
    }

    public func selectorSnapshot(
        group: String
    ) throws -> ProxySelectionState {
        guard let runtime = runningRuntime() else {
            throw TransparentProxySelectionError.providerUnavailable
        }
        return try runtime.selectorSnapshot(group: group)
    }

    public func setRoutingMode(_ mode: RoutingMode) throws {
        guard let runtime = runningRuntime() else {
            throw TransparentProxySelectionError.providerUnavailable
        }
        try runtime.setRoutingMode(mode)
    }

    public func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionState {
        guard let runtime = runningRuntime() else {
            throw TransparentProxySelectionError.providerUnavailable
        }
        return try runtime.selectProxy(group: group, member: member)
    }

    public func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        guard let runtime = runningRuntime() else {
            throw TransparentProxySelectionError.providerUnavailable
        }
        return try runtime.testProxyLatency(
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        guard let runtime = runningRuntime() else {
            throw TransparentProxySelectionError.providerUnavailable
        }
        return try runtime.testActiveProxyLatency(
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        guard let runtime = runningRuntime() else {
            throw TransparentProxySelectionError.providerUnavailable
        }
        return try runtime.telemetrySnapshot(
            maximumConnections: maximumConnections
        )
    }

    public func resetNetworkState() {
        guard let runtime = runningRuntime() else { return }
        runtime.resetNetworkState()
    }

    private func completePreparation(
        id: UUID,
        result: Result<TransparentProxyFlowRuntime, Error>,
        installer: @escaping SettingsInstaller
    ) {
        guard phase == .preparingRuntime, operationID == id else {
            TransparentLifecycleLog.logger.info(
                "stage=completePreparation ignored reason=stale"
            )
            return
        }
        switch result {
        case let .failure(error):
            TransparentLifecycleLog.logger.error(
                "stage=completePreparation failed error=\(String(reflecting: error), privacy: .public)"
            )
            pendingStartError = stopRequested
                ? .startCancelled
                : .runtimePreparationFailed
            phase = .stopping
            TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=stopping")
            beginProviderDrain()
        case let .success(preparedRuntime):
            TransparentLifecycleLog.logger.info("stage=completePreparation success")
            runtime = preparedRuntime
            if stopRequested {
                TransparentLifecycleLog.logger.info(
                    "stage=completePreparation cancelledByStop"
                )
                pendingStartError = .startCancelled
                phase = .stopping
                TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=stopping")
                beginProviderDrain()
                return
            }

            phase = .installingNetworkSettings
            TransparentLifecycleLog.logger.info(
                "stage=lifecyclePhase value=installingNetworkSettings"
            )
            callbackQueue.async { [self] in
                TransparentLifecycleLog.logger.info("stage=settingsInstaller submitted")
                let once = SettingsInstallationCompletion { [self] installed in
                    lifecycleQueue.async { [self] in
                        completeSettingsInstallation(
                            id: id,
                            installed: installed
                        )
                    }
                }
                installer { installed in
                    once.call(installed)
                }
            }
        }
    }

    private func completeSettingsInstallation(id: UUID, installed: Bool) {
        guard
            phase == .installingNetworkSettings,
            operationID == id
        else {
            TransparentLifecycleLog.logger.info(
                "stage=settingsInstallation ignored reason=stale"
            )
            return
        }

        TransparentLifecycleLog.logger.info(
            "stage=settingsInstallation result=\(installed, privacy: .public)"
        )

        if installed, !stopRequested {
            phase = .running
            TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=running")
            operationID = nil
            let completion = pendingStart
            pendingStart = nil
            completion?.call(nil)
            return
        }

        pendingStartError = installed
            ? .startCancelled
            : .networkSettingsInstallationFailed
        phase = .stopping
        TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=stopping")
        beginProviderDrain()
    }

    private func beginProviderDrain() {
        TransparentLifecycleLog.logger.info("stage=providerDrain begin")
        flowHandlerGate.stop { [self] in
            failClosedRegistry.stopAll { [self] in
                TransparentLifecycleLog.logger.info("stage=providerDrain gatesClosed")
                lifecycleQueue.async { [self] in
                    providerDrainFinished()
                }
            }
        }
    }

    private func providerDrainFinished() {
        TransparentLifecycleLog.logger.info("stage=providerDrain finished")
        guard let runtime else {
            finishWithoutRuntime()
            return
        }
        runtime.stop { [self] in
            lifecycleQueue.async { [self] in
                finishRuntimeStop()
            }
        }
    }

    private func finishRuntimeStop() {
        TransparentLifecycleLog.logger.info("stage=finishRuntimeStop")
        let startCompletion = pendingStart
        let startError = pendingStartError
        let stopCallbacks = stopCompletions
        resetToIdle()
        startCompletion?.call(startError)
        stopCallbacks.forEach { $0.call() }
    }

    private func finishWithoutRuntime() {
        TransparentLifecycleLog.logger.info("stage=finishWithoutRuntime")
        let startCompletion = pendingStart
        let startError = pendingStartError ?? .runtimePreparationFailed
        let stopCallbacks = stopCompletions
        resetToIdle()
        startCompletion?.call(startError)
        stopCallbacks.forEach { $0.call() }
    }

    private func resetToIdle() {
        phase = .idle
        TransparentLifecycleLog.logger.info("stage=lifecyclePhase value=idle")
        operationID = nil
        runtime = nil
        pendingStart = nil
        pendingStartError = nil
        stopRequested = false
        stopCompletions.removeAll(keepingCapacity: false)
    }

    private func runningRuntime() -> TransparentProxyFlowRuntime? {
        lifecycleQueue.sync {
            phase == .running ? runtime : nil
        }
    }
}

/// Counts complete synchronous handleNewFlow scopes. Stop seals admission,
/// waits for scopes that already entered, and only then permits the raw-flow
/// registry to close its own admission. NetworkExtension must not deliver a
/// new flow after stop has sealed this provider callback boundary.
private final class ProviderFlowHandlerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lifecycle: Lifecycle = .accepting
    private var activeHandlerCount = 0
    private var stopCompletions: [@Sendable () -> Void] = []

    func enter() -> Bool {
        lock.withLock {
            guard lifecycle == .accepting else { return false }
            activeHandlerCount += 1
            return true
        }
    }

    func leave() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            guard activeHandlerCount > 0 else { return [] }
            activeHandlerCount -= 1
            guard lifecycle == .stopping, activeHandlerCount == 0 else {
                return []
            }
            lifecycle = .stopped
            defer { stopCompletions.removeAll(keepingCapacity: false) }
            return stopCompletions
        }
        completions.forEach { $0() }
    }

    func stop(completion: @escaping @Sendable () -> Void) {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            switch lifecycle {
            case .stopped:
                return [completion]
            case .stopping:
                stopCompletions.append(completion)
                return []
            case .accepting:
                lifecycle = .stopping
                stopCompletions.append(completion)
                guard activeHandlerCount == 0 else { return [] }
                lifecycle = .stopped
                defer { stopCompletions.removeAll(keepingCapacity: false) }
                return stopCompletions
            }
        }
        completions.forEach { $0() }
    }

    func resetForStart() -> Bool {
        lock.withLock {
            switch lifecycle {
            case .accepting:
                return activeHandlerCount == 0
            case .stopping:
                return false
            case .stopped:
                guard activeHandlerCount == 0 else { return false }
                lifecycle = .accepting
                return true
            }
        }
    }

    private enum Lifecycle {
        case accepting
        case stopping
        case stopped
    }
}

private final class ProviderStartCompletion: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var handler: TransparentProxyProviderLifecycleController
        .StartCompletion?

    init(
        queue: DispatchQueue,
        handler: @escaping TransparentProxyProviderLifecycleController
            .StartCompletion
    ) {
        self.queue = queue
        self.handler = handler
    }

    func call(_ error: TransparentProxyProviderLifecycleError?) {
        let handler = lock.withLock { () -> TransparentProxyProviderLifecycleController.StartCompletion? in
            defer { self.handler = nil }
            return self.handler
        }
        guard let handler else { return }
        queue.async { handler(error) }
    }
}

private final class ProviderStopCompletion: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var handler: TransparentProxyProviderLifecycleController
        .StopCompletion?

    init(
        queue: DispatchQueue,
        handler: @escaping TransparentProxyProviderLifecycleController
            .StopCompletion
    ) {
        self.queue = queue
        self.handler = handler
    }

    func call() {
        let handler = lock.withLock { () -> TransparentProxyProviderLifecycleController.StopCompletion? in
            defer { self.handler = nil }
            return self.handler
        }
        guard let handler else { return }
        queue.async(execute: handler)
    }
}

private final class SettingsInstallationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    init(handler: @escaping @Sendable (Bool) -> Void) {
        self.handler = handler
    }

    func call(_ installed: Bool) {
        let handler = lock.withLock { () -> (@Sendable (Bool) -> Void)? in
            defer { self.handler = nil }
            return self.handler
        }
        handler?(installed)
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

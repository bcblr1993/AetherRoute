import AetherRouteFlowCoreBridge
import AetherRouteKit
import AetherRouteTransparentProxySupport
import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog
import SystemConfiguration

/// Native direct-flow provider embedded beside the Packet Tunnel extension.
/// Compile/link, synthetic lifecycle, and loopback flow gates exercise this
/// provider; organization-signed real NetworkExtension lifecycle tests remain
/// required before production promotion.
final class TransparentProxyProvider: NETransparentProxyProvider,
    @unchecked Sendable
{
    private static let runtimeLog = DiagnosticLogCenter.current.log(
        category: "transparent-runtime"
    )
    private static let osLogger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "transparent-runtime"
    )
    /// Standard-level summary of the data plane. Counting is O(1) per flow and
    /// emission is on a fixed interval, so this stays affordable at any volume.
    private static let aggregator = DiagnosticAggregator(log: runtimeLog)

    private let identityGuard: TransparentProxySelfIdentityGuard
    private let diagnostics: ProviderDiagnosticAccumulator
    private let runtimeController: TransparentProxyProviderLifecycleController
    private let providerMessageQueue = DispatchQueue(
        label: "com.aetherroute.desktop.transparent-proxy.provider-message",
        qos: .userInitiated
    )
    private let probeMessageQueue = DispatchQueue(
        label: "com.aetherroute.desktop.transparent-proxy.probe-message",
        qos: .userInitiated,
        attributes: .concurrent,
        autoreleaseFrequency: .workItem
    )
    private let reloadWorkerQueue = DispatchQueue(
        label: "com.aetherroute.desktop.transparent-proxy.reload",
        qos: .userInitiated
    )
    private let reloadGate = AsyncSerialOperationGate()
    private let resourceChunkReceiver = RoutingResourceChunkStagingReceiver {
        try RoutingResourceStore.applicationGroup()
    }
    /// Short enough that the whole schedule still fits inside the recovery
    /// window, long enough not to fail a link that has just come up.
    private static let healthProbeTimeoutMilliseconds: UInt32 = 3_000
    /// Built in `init`, not lazily. `wake`, `sleep` and the provider message
    /// queue can all reach it first, and a `lazy var` has no synchronisation on
    /// that first access.
    private var recovery: NetworkRecoveryCoordinator!
    private let resetLedgerLock = NSLock()
    private var resetLedger = UplinkResetLedger()
    /// Recovery attempt (zero-based) at which a run that has not regained a
    /// data path replaces the engine, as a disconnect and reconnect would.
    /// Attempts 0–1 already reset it onto the current uplink, about three
    /// seconds and two health checks earlier.
    private static let rebuildAttemptIndex = 2
    private static let rebuildWaitSeconds: TimeInterval = 20

    /// Everything the running engine was built from, plus the selections and
    /// routing mode applied since, so a rebuild comes back as the user left
    /// it. Guarded by `recipeLock`.
    private struct RuntimeRecipe: Sendable {
        let snapshot: ProviderLaunchSnapshot
        var selections: [String: String]
        var routingMode: RoutingMode
    }
    private let recipeLock = NSLock()
    private var runtimeRecipe: RuntimeRecipe?
    private var cachedSummary: (digest: String, summary: ProfileConfigurationSummary)?

    private let pathStateLock = NSLock()
    private var pathMonitor: NWPathMonitor?
    private var uplinkStore: SCDynamicStore?
    private final class UplinkObserverContext {
        weak var provider: TransparentProxyProvider?
        init(_ provider: TransparentProxyProvider) { self.provider = provider }
    }
    private let pathMonitorQueue = DispatchQueue(
        label: "com.aetherroute.desktop.transparent-proxy.path",
        qos: .utility
    )
    private static let pathChangeDebounceMilliseconds: Int = 150
    private var pendingPathChangeWorkItem: DispatchWorkItem?
    private var lastPathSignature: String?
    private let uplinkLock = NSLock()
    private var physicalInterfaces: [NWInterface] = []
    private var providerStopping = false

    override init() {
        let identityGuard = TransparentProxySelfIdentityGuard()
        let diagnostics = ProviderDiagnosticAccumulator()
        self.identityGuard = identityGuard
        self.diagnostics = diagnostics
        runtimeController = TransparentProxyProviderLifecycleController(
            identityGuard: identityGuard
        ) {
            do {
                Self.runtimeLog.aggregate("stage=loadSharedProfile begin")
                let input = try TransparentProxyRuntimeInputLoader
                    .loadApplicationGroup()
                Self.runtimeLog.aggregate("stage=loadSharedProfile success")
                Self.runtimeLog.aggregate("stage=createFlowCore begin")
                let rawYAML = String(
                    decoding: input.profile,
                    as: UTF8.self
                )
                let profileYAML = DomesticRoutingOptimizer.optimizedProfile(
                    for: rawYAML,
                    enableDomesticDirect: DomesticRoutingOptimizer.isEnabled
                )
                let engineProfile = Data(profileYAML.utf8)
                let engine = try FlowCoreEngine(
                    profile: engineProfile,
                    runtimeDirectory: input.runtimeDirectory
                )
                Self.runtimeLog.aggregate("stage=createFlowCore success")
                Self.runtimeLog.aggregate("stage=loadSelections begin")
                let rawSelections = try ProxySelectionStore.applicationGroup()
                    .selections(forProfileYAML: rawYAML)
                let appliedCount = Self.restoreSelections(
                    rawSelections,
                    profileYAML: profileYAML,
                    to: engine
                )
                Self.runtimeLog.aggregate(
                    "stage=loadSelections success count=\(appliedCount)"
                )
                Self.runtimeLog.aggregate("stage=createFlowRuntime begin")
                let runtime = try TransparentProxyFlowRuntime(
                    engine: engine,
                    identityGuard: identityGuard,
                    failureObserver: { failure in
                        Self.runtimeLog.failure(
                            "stage=flowIngress failed point=\(String(describing: failure))"
                        )
                        Self.aggregator.record(.admissionRejected)
                        diagnostics.record(.flowAdmissionFailure)
                    }
                )
                Self.runtimeLog.aggregate("stage=createFlowRuntime success")
                return runtime
            } catch let error as FlowCoreEngineError {
                Self.runtimeLog.failure(
                    "stage=createFlowCore failed error=\(error.description)"
                )
                throw error
            } catch {
                Self.runtimeLog.failure(
                    "runtime preparation failed: \(String(reflecting: error))"
                )
                throw error
            }
        }
        super.init()
        recovery = NetworkRecoveryCoordinator(
            perform: { [weak self] reason, attempt in
                Self.runtimeLog.aggregate(
                    "stage=flowRecovery attempt reason=\(reason) index=\(attempt)"
                )
                self?.performNetworkRecovery(reason: reason, attempt: attempt)
            },
            verify: { [weak self] in self?.dataPathIsHealthy() ?? false },
            observer: { [weak self] event in
                switch event {
                case let .started(reason):
                    guard let self else { break }
                    self.resetLedgerLock.withLock {
                        self.resetLedger.runStarted(reason: reason)
                    }
                case .exhausted:
                    // Resets and one rebuild did not bring the data path back.
                    // The link may have come up only now; one more rebuild is
                    // cheap next to leaving the user offline until they
                    // reconnect by hand. Without an uplink there is nothing to
                    // rebuild onto; the next path change starts a new run.
                    if self?.currentPhysicalUplink() != nil {
                        self?.rebuildRuntimeForRecovery(reason: "exhausted")
                    }
                default:
                    break
                }
                // Exhaustion means the host never regained a data path, which
                // is the one outcome that must stay visible with debug logging
                // switched off.
                if case let .exhausted(reason, attempts) = event {
                    Self.runtimeLog.failure(
                        "stage=flowRecovery exhausted reason=\(reason) attempts=\(attempts)"
                    )
                } else {
                    Self.runtimeLog.aggregate("stage=flowRecovery event=\(event)")
                }
            }
        )
    }

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        Self.runtimeLog.lifecycle("stage=startProxy requested")
        let initialSignature = sampleCurrentPathSignature()
        uplinkLock.withLock {
            providerStopping = false
            lastPathSignature = initialSignature
        }
        resetLedgerLock.withLock {
            resetLedger.invalidate()
        }
        let completion = ProxyStartCompletion(completionHandler)
        let snapshot: ProviderLaunchSnapshot
        let bypassPlan: BypassNetworkSettingsPlan
        do {
            Self.runtimeLog.aggregate("stage=decodeLaunchSnapshot begin")
            snapshot = try ProviderLaunchSnapshotCodec.decode(options: options)
            DiagnosticLogCenter.current.applyLevelOverride(
                snapshot.diagnosticLogLevel
            )
            Self.runtimeLog.aggregate(
                "stage=decodeLaunchSnapshot success mode=\(snapshot.routingMode.rawValue) selections=\(snapshot.proxySelections.count) resources=\(snapshot.routingResources.count)"
            )
            Self.runtimeLog.aggregate("stage=loadBypassPolicy begin source=launchSnapshot")
            bypassPlan = try BypassNetworkSettingsPlan(
                policy: snapshot.bypassPolicy
            )
            Self.runtimeLog.aggregate("stage=loadBypassPolicy success")
        } catch {
            diagnostics.record(.startupFailure)
            Self.runtimeLog.failure(
                "stage=loadBypassPolicy failed error=\(String(reflecting: error))"
            )
            completion.call(error)
            return
        }
        recipeLock.withLock {
            runtimeRecipe = RuntimeRecipe(
                snapshot: snapshot,
                selections: snapshot.proxySelections,
                routingMode: snapshot.routingMode
            )
        }
        // Resolve upstream endpoints off the NE caller thread so DNS queries
        // never block NetworkExtension's lifecycle callback queue.
        reloadWorkerQueue.async { [weak self] in
            guard let self else {
                completion.call(CancellationError())
                return
            }
            guard !self.uplinkLock.withLock({ self.providerStopping }) else {
                completion.call(CancellationError())
                return
            }
            let upstreamExclusions: [TransparentProxyUpstreamExclusion]
            do {
                Self.runtimeLog.aggregate("stage=resolveUpstreamEndpoints begin")
                do {
                    upstreamExclusions = try TransparentProxyUpstreamEndpointResolver
                        .resolve(profileYAML: snapshot.profileYAML)
                    Self.runtimeLog.aggregate(
                        "stage=resolveUpstreamEndpoints success count=\(upstreamExclusions.count)"
                    )
                } catch TransparentProxyUpstreamEndpointResolutionError.unresolvedEndpoint {
                    upstreamExclusions = []
                    Self.runtimeLog.aggregate(
                        "stage=resolveUpstreamEndpoints fallbackEmpty reason=relyingOnSelfIdentityGuard"
                    )
                }
            } catch {
                self.diagnostics.record(.startupFailure)
                Self.runtimeLog.failure(
                    "stage=resolveUpstreamEndpoints failed error=\(String(reflecting: error))"
                )
                completion.call(error)
                return
            }

            let identityGuard = self.identityGuard
            let diagnostics = self.diagnostics
            self.runtimeController.start(
                runtimeFactory: {
                    try Self.makeRuntime(
                        snapshot: snapshot,
                        selections: snapshot.proxySelections,
                        routingMode: snapshot.routingMode,
                        identityGuard: identityGuard,
                        diagnostics: diagnostics
                    )
                },
                installNetworkSettings: { [weak self] installed in
                    guard let self else {
                        installed(false)
                        return
                    }
                    let once = ProxySettingsCompletion(installed)
                    let settings: NETransparentProxyNetworkSettings
                    do {
                        Self.runtimeLog.aggregate("stage=makeNetworkSettings begin")
                        settings = try Self.makeNetworkSettings(
                            bypassPlan: bypassPlan,
                            upstreamExclusions: upstreamExclusions
                        )
                        Self.runtimeLog.aggregate("stage=makeNetworkSettings success")
                    } catch {
                        Self.runtimeLog.failure(
                            "stage=makeNetworkSettings failed error=\(String(reflecting: error))"
                        )
                        once.call(false)
                        return
                    }
                    Self.runtimeLog.aggregate("stage=installNetworkSettings begin")
                    self.setTunnelNetworkSettings(settings) { error in
                        if let error {
                            Self.runtimeLog.failure(
                                "stage=installNetworkSettings failed error=\(String(reflecting: error))"
                            )
                        } else {
                            Self.runtimeLog.aggregate(
                                "stage=installNetworkSettings success"
                            )
                        }
                        once.call(error == nil)
                    }
                },
                completion: { [weak self, diagnostics] error in
                    switch error {
                    case .runtimePreparationFailed:
                        diagnostics.record(.startupFailure)
                    case .networkSettingsInstallationFailed:
                        diagnostics.record(.networkSettingsFailure)
                    case .alreadyActive, .startCancelled, nil:
                        break
                    }
                    if let error {
                        Self.runtimeLog.failure(
                            "stage=startProxy failed error=\(String(reflecting: error))"
                        )
                    } else if let self, !self.uplinkLock.withLock({ self.providerStopping }) {
                        DiagnosticFlowOpenObserver.shared.attach(Self.aggregator)
                        Self.aggregator.start()
                        self.startPathMonitoring()
                        Self.runtimeLog.lifecycle("stage=startProxy success")
                    }
                    completion.call(error)
                }
            )
        }
    }

    /// Builds an engine and its flow runtime from a launch snapshot. Startup,
    /// a profile reload and a recovery rebuild all go through here, so they
    /// cannot drift apart. `selections` and `routingMode` start from the
    /// snapshot's and, for a rebuild, include what the user changed since.
    private static func makeRuntime(
        snapshot: ProviderLaunchSnapshot,
        selections: [String: String],
        routingMode: RoutingMode,
        identityGuard: TransparentProxySelfIdentityGuard,
        diagnostics: ProviderDiagnosticAccumulator
    ) throws -> TransparentProxyFlowRuntime {
        do {
            runtimeLog.aggregate("stage=loadLaunchProfile begin")
            let input = try TransparentProxyRuntimeInputLoader.load(
                snapshot: snapshot
            )
            runtimeLog.aggregate("stage=loadLaunchProfile success")
            runtimeLog.aggregate("stage=createFlowCore begin")
            let engine = try FlowCoreEngine(
                profile: input.profile,
                runtimeDirectory: input.runtimeDirectory,
                configuration: FlowCoreEngineConfiguration(
                    routingMode: routingMode
                )
            )
            runtimeLog.aggregate("stage=createFlowCore success")
            runtimeLog.aggregate("stage=restoreSelections begin")
            let profileYAML = String(decoding: input.profile, as: UTF8.self)
            let appliedCount = restoreSelections(
                selections,
                profileYAML: profileYAML,
                to: engine
            )
            runtimeLog.aggregate(
                "stage=restoreSelections success count=\(appliedCount)"
            )
            runtimeLog.aggregate("stage=createFlowRuntime begin")
            let runtime = try TransparentProxyFlowRuntime(
                engine: engine,
                identityGuard: identityGuard,
                failureObserver: { failure in
                    runtimeLog.failure(
                        "stage=flowIngress failed point=\(String(describing: failure))"
                    )
                    aggregator.record(.admissionRejected)
                    diagnostics.record(.flowAdmissionFailure)
                }
            )
            runtimeLog.aggregate("stage=createFlowRuntime success")
            return runtime
        } catch {
            runtimeLog.failure(
                "runtime preparation failed: \(String(reflecting: error))"
            )
            throw error
        }
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Self.runtimeLog.lifecycle("stage=stopProxy requested")
        uplinkLock.withLock {
            providerStopping = true
            lastPathSignature = nil
        }
        resetLedgerLock.withLock {
            resetLedger.invalidate()
        }
        stopPathMonitoring()
        recovery.cancel(reason: "stopProxy")
        recipeLock.withLock { runtimeRecipe = nil }
        let completion = ProxyStopCompletion(completionHandler)
        runtimeController.stop {
            // NETransparentProxyProvider accepts only
            // NETransparentProxyNetworkSettings. Passing nil through
            // setTunnelNetworkSettings during teardown is rejected by macOS
            // and can turn a clean disconnect into an apparent provider
            // failure. The system owns removal after this completion returns.
            DiagnosticFlowOpenObserver.shared.detach()
            Self.aggregator.stop()
            Self.runtimeLog.lifecycle("stage=stopProxy success")
            completion.call()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        Self.runtimeLog.lifecycle("stage=sleep requested")
        recovery.cancel(reason: "sleep")
        completionHandler()
    }

    override func wake() {
        Self.runtimeLog.lifecycle("stage=wake requested")
        // Was a fixed pair of resets at +0s and +1.5s. A laptop reopening onto
        // Wi-Fi is rarely ready that soon, and nothing re-ran afterwards.
        recovery.trigger(reason: "wake", supersedes: true)
    }

    /// One recovery attempt, on the coordinator's queue.
    ///
    /// Resets the engine onto the current physical uplink whenever that uplink
    /// (interface or addresses) differs from the last successful reset. An
    /// unchanged uplink is left alone: repeating the reset would close
    /// connections that were only just becoming usable. If the run still has
    /// no data path at `rebuildAttemptIndex`, the engine is replaced outright,
    /// once per run, and only once there is an uplink for it to start on.
    private func performNetworkRecovery(reason: String, attempt: Int) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        guard let uplink = currentPhysicalUplink() else {
            resetLedgerLock.withLock {
                resetLedger.invalidate()
            }
            Self.runtimeLog.aggregate(
                "stage=networkRecovery waitingForPhysicalUplink attempt=\(attempt)"
            )
            return
        }
        if attempt >= Self.rebuildAttemptIndex,
           resetLedgerLock.withLock({ resetLedger.claimRebuild() }) {
            if rebuildRuntimeForRecovery(reason: reason) {
                // A fresh engine selects its uplink as it starts.
                let sig = pathSignature(for: uplink)
                resetLedgerLock.withLock {
                    resetLedger.resetCompleted(
                        interfaceIndex: UInt32(uplink.index),
                        signature: sig
                    )
                }
                return
            }
            // The rebuild did not happen; fall through to a plain reset.
        }
        let index = UInt32(uplink.index)
        let signature = pathSignature(for: uplink)
        let needsReset = resetLedgerLock.withLock {
            resetLedger.needsReset(interfaceIndex: index, signature: signature)
        }
        guard needsReset else {
            if attempt == 0 {
                // A path change an earlier run (usually the wake run) already
                // reset onto. Resetting again would close every connection.
                Self.runtimeLog.aggregate(
                    "stage=networkRecovery coreReset skipped reason=\(reason) interface=\(uplink.name) index=\(index) cause=unchangedUplink"
                )
            }
            return
        }
        resetLedgerLock.withLock {
            resetLedger.invalidate()
        }
        var outcome = runtimeController.resetNetworkState(interfaceIndex: index)
        if outcome == .interfaceUnavailable {
            // The engine enumerates interfaces itself and may not list one
            // that has only just appeared; let it choose rather than give up.
            outcome = runtimeController.resetNetworkState(interfaceIndex: 0)
        }
        Self.runtimeLog.aggregate(
            "stage=networkRecovery coreReset reason=\(reason) attempt=\(attempt) interface=\(uplink.name) index=\(index) outcome=\(String(describing: outcome))"
        )
        guard outcome == .reset else { return }
        resetLedgerLock.withLock {
            resetLedger.resetCompleted(interfaceIndex: index, signature: signature)
        }
    }

    /// Replaces the engine in place from the current recipe and waits for the
    /// swap. Returns whether a fresh engine is now serving flows.
    @discardableResult
    private func rebuildRuntimeForRecovery(reason: String) -> Bool {
        guard !uplinkLock.withLock({ providerStopping }),
              let recipe = recipeLock.withLock({ runtimeRecipe }) else {
            return false
        }
        Self.runtimeLog.aggregate("stage=networkRecovery rebuild begin reason=\(reason)")
        let result = RebuildResult()
        runtimeController.rebuildRuntime(
            runtimeFactory: { [identityGuard, diagnostics] in
                try Self.makeRuntime(
                    snapshot: recipe.snapshot,
                    selections: recipe.selections,
                    routingMode: recipe.routingMode,
                    identityGuard: identityGuard,
                    diagnostics: diagnostics
                )
            },
            completion: { swapped in result.finish(swapped) }
        )
        let swapped = result.wait(seconds: Self.rebuildWaitSeconds)
        if swapped {
            Self.runtimeLog.aggregate("stage=networkRecovery rebuild swapped reason=\(reason)")
        } else {
            Self.runtimeLog.failure("stage=networkRecovery rebuild failed reason=\(reason)")
        }
        return swapped
    }

    private func currentPhysicalUplink() -> PhysicalUplink? {
        guard let store = SCDynamicStoreCreate(
            nil,
            "AetherRoute transparent recovery uplink" as CFString,
            nil,
            nil
        ) else { return nil }
        let cached = uplinkLock.withLock { physicalInterfaces }
        return PhysicalUplinkDetector.currentPhysicalUplink(
            store: store,
            cachedPathInterfaces: cached
        )
    }

    private func pathSignature(for uplink: PhysicalUplink) -> String? {
        SCDynamicStoreCreate(
            nil,
            "AetherRoute transparent recovery signature" as CFString,
            nil,
            nil
        ).flatMap { PhysicalUplinkDetector.pathSignature(store: $0, uplink: uplink) }
    }

    /// Probes the live route end to end. The provider's own sockets do not pass
    /// through the flows it proxies, so asking the core to URL-test the current
    /// route is the only way to see whether traffic can leave the host.
    ///
    /// Received bytes used to count as health too. Any flow does that,
    /// including ones that never touch the engine's broken outbound path, so a
    /// run could report `recovered` while proxied traffic was still dead. Only
    /// a probe through the engine is evidence now.
    private func dataPathIsHealthy() -> Bool {
        guard !uplinkLock.withLock({ providerStopping }),
              resetLedgerLock.withLock({ resetLedger.resetSucceeded }) else { return false }
        let routingMode = recipeLock.withLock { runtimeRecipe?.routingMode } ?? .rule
        return NetworkRecoveryHealthPolicy.isReachable(
            groups: NetworkRecoveryHealthPolicy.probeGroups(routingMode: routingMode)
        ) { group, url in
            let state = try runtimeController.testActiveProxyLatency(
                group: group,
                url: url,
                timeoutMilliseconds: Self.healthProbeTimeoutMilliseconds
            )
            return state.results.contains { $0.delayMilliseconds != nil }
        }
    }

    private func startPathMonitoring() {
        pathMonitorQueue.async { [weak self] in
            guard let self, !self.uplinkLock.withLock({ self.providerStopping }) else { return }
            let alreadyStarted = self.pathStateLock.withLock { self.pathMonitor != nil }
            guard !alreadyStarted else { return }

            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { [weak self] path in
                guard let self, !self.uplinkLock.withLock({ self.providerStopping }) else { return }
                Self.osLogger.debug(
                    "stage=pathUpdate status=\(String(describing: path.status), privacy: .public) isExpensive=\(path.isExpensive, privacy: .public)"
                )
                self.uplinkLock.withLock { self.physicalInterfaces = path.availableInterfaces }
                self.physicalPathDidChange(reason: "pathChanged")
            }
            let observerContext = UplinkObserverContext(self)
            var context = SCDynamicStoreContext(
                version: 0,
                info: Unmanaged.passUnretained(observerContext).toOpaque(),
                retain: { pointer in
                    _ = Unmanaged<UplinkObserverContext>.fromOpaque(pointer).retain()
                    return pointer
                },
                release: { pointer in
                    Unmanaged<UplinkObserverContext>.fromOpaque(pointer).release()
                },
                copyDescription: nil
            )
            let createdStore = SCDynamicStoreCreate(
                nil,
                "AetherRoute transparent uplink changes" as CFString,
                { _, _, context in
                    guard let context else { return }
                    guard let provider = Unmanaged<UplinkObserverContext>.fromOpaque(context)
                        .takeUnretainedValue().provider else { return }
                    guard !provider.uplinkLock.withLock({ provider.providerStopping }) else { return }
                    provider.physicalPathDidChange(reason: "physicalLinkChanged")
                },
                &context
            )
            if let createdStore {
                SCDynamicStoreSetNotificationKeys(
                    createdStore,
                    nil,
                    [
                        "State:/Network/Interface/en[0-9]+/(Link|IPv4|IPv6)",
                        "State:/Network/Interface/pdp_ip[0-9]+/(Link|IPv4|IPv6)",
                        "State:/Network/Global/IPv4",
                    ] as CFArray
                )
                SCDynamicStoreSetDispatchQueue(createdStore, self.pathMonitorQueue)
            }
            self.pathStateLock.withLock {
                self.pathMonitor = monitor
                self.uplinkStore = createdStore
            }
            monitor.start(queue: self.pathMonitorQueue)
        }
    }

    private func stopPathMonitoring() {
        let (workItem, store, monitor) = pathStateLock.withLock {
            () -> (DispatchWorkItem?, SCDynamicStore?, NWPathMonitor?) in
            let w = pendingPathChangeWorkItem
            let s = uplinkStore
            let m = pathMonitor
            pendingPathChangeWorkItem = nil
            uplinkStore = nil
            pathMonitor = nil
            return (w, s, m)
        }
        workItem?.cancel()
        if let store { SCDynamicStoreSetDispatchQueue(store, nil) }
        monitor?.cancel()
    }

    private func sampleCurrentPathSignature() -> String? {
        guard let store = SCDynamicStoreCreate(
            nil,
            "AetherRoute transparent initial uplink signature" as CFString,
            nil,
            nil
        ) else { return nil }
        let cached = uplinkLock.withLock { physicalInterfaces }
        let uplink = PhysicalUplinkDetector.currentPhysicalUplink(
            store: store,
            cachedPathInterfaces: cached
        )
        return PhysicalUplinkDetector.pathSignature(store: store, uplink: uplink)
    }

    /// Both notification sources run on pathMonitorQueue. A secondary link or
    /// duplicate DHCP notification must not destroy a healthy active transport.
    ///
    /// Coalesces rapid successive notifications within a 150ms window to prevent
    /// notification storms during network reconfiguration and avoid redundant
    /// dynamic store queries.
    private func physicalPathDidChange(reason: String) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.uplinkLock.withLock({ self.providerStopping }) else { return }
            self.evaluatePhysicalPathChange(reason: reason)
        }
        pathStateLock.withLock {
            pendingPathChangeWorkItem?.cancel()
            pendingPathChangeWorkItem = workItem
        }
        pathMonitorQueue.asyncAfter(
            deadline: .now() + .milliseconds(Self.pathChangeDebounceMilliseconds),
            execute: workItem
        )
    }

    private func evaluatePhysicalPathChange(reason: String) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        let existingStore = pathStateLock.withLock { uplinkStore }
        let store = existingStore ?? SCDynamicStoreCreate(nil, "AetherRoute transparent uplink identity" as CFString, nil, nil)
        guard let store else { return }
        let cached = uplinkLock.withLock { physicalInterfaces }
        let uplink = PhysicalUplinkDetector.currentPhysicalUplink(
            store: store,
            cachedPathInterfaces: cached
        )
        let signature = PhysicalUplinkDetector.pathSignature(store: store, uplink: uplink)
        let previous = uplinkLock.withLock { () -> String? in
            let prev = lastPathSignature
            lastPathSignature = signature
            return prev
        }
        guard let previous, previous != signature else { return }
        Self.osLogger.info(
            "stage=physicalUplinkChanged scheduling recovery reason=\(reason, privacy: .public) signature=\(signature, privacy: .public) previous=\(previous, privacy: .public)"
        )
        recovery.trigger(reason: reason, supersedes: true)
    }

    private static func transportLogLabel(for flow: NEAppProxyFlow) -> String {
        if flow is NEAppProxyUDPFlow { return "udp" }
        if flow is NEAppProxyTCPFlow { return "tcp" }
        return "unknown"
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        let transport = Self.transportLogLabel(for: flow)
        Self.runtimeLog.verbose("stage=handleNewFlow transport=\(transport) begin")
        return runtimeController.withFlowAdmission { [self] in
            handleAdmittedFlow(flow)
        } ?? NetworkExtensionStoppedProviderFlow
            .claimAndCloseSynchronously(flow)
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        let completion = ProxyMessageCompletion(completionHandler)

        let request: ProxySelectionProviderRequest
        let messageClass: ProviderMessageClass
        switch ProviderMessageRouting.classify(messageData) {
        case let .routed(decoded, kind):
            request = decoded
            messageClass = kind
        case let .undecodable(failure):
            completion.call(ProviderMessageRouting.encodedFailure(failure))
            return
        }

        let targetQueue = messageClass == .probe
            ? probeMessageQueue
            : providerMessageQueue

        let watchdogSeconds = Self.watchdogTimeoutSeconds(for: request)
        let watchdogState = WatchdogState()
        let watchdog = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        watchdog.schedule(deadline: .now() + .seconds(watchdogSeconds))
        watchdog.setEventHandler { [completion, request, watchdogState] in
            guard watchdogState.markTimedOut() else { return }
            Self.runtimeLog.failure(
                "stage=providerMessage stalled request=\(Self.messageKind(request)) elapsed=\(watchdogSeconds)s"
            )
            completion.call(ProviderMessageRouting.encodedFailure(.unavailable))
            watchdog.cancel()
        }
        watchdog.resume()

        targetQueue.async { [self, runtimeController, diagnostics, watchdogState] in
            if case let .reloadProfile(payloadData) = request {
                self.handleReloadProfile(
                    payloadData: payloadData,
                    watchdogState: watchdogState
                ) { response in
                    self.finishTimedProviderResponse(
                        response,
                        watchdog: watchdog,
                        watchdogState: watchdogState,
                        completion: completion
                    )
                }
                return
            }
            if case let .hotReloadRules(payloadData, reloadOutbounds) = request {
                self.handleHotReloadRules(
                    payloadData: payloadData,
                    reloadOutbounds: reloadOutbounds,
                    watchdogState: watchdogState
                ) { response in
                    self.finishTimedProviderResponse(
                        response,
                        watchdog: watchdog,
                        watchdogState: watchdogState,
                        completion: completion
                    )
                }
                return
            }

            let response: ProxySelectionProviderResponse
            do {
                Self.runtimeLog.verbose(
                    "stage=providerMessage request=\(Self.messageKind(request)) bytes=\(messageData.count)"
                )
                response = switch request {
                case let .snapshot(group):
                    .snapshot(try runtimeController.selectorSnapshot(group: group))
                case let .select(group, member):
                    .snapshot(try self.applySelection(group: group, member: member))
                case let .latency(group, url, timeoutMilliseconds, unifiedDelay):
                    .latency(
                        try runtimeController.testProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: ProxySelectionProviderMessageCodec
                                .packLatencyTimeoutMilliseconds(
                                    timeoutMilliseconds,
                                    unifiedDelay: unifiedDelay
                                )
                        )
                    )
                case let .activeLatency(group, url, timeoutMilliseconds, unifiedDelay):
                    .latency(
                        try runtimeController.testActiveProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: ProxySelectionProviderMessageCodec
                                .packLatencyTimeoutMilliseconds(
                                    timeoutMilliseconds,
                                    unifiedDelay: unifiedDelay
                                )
                        )
                    )
                case let .telemetry(maximumConnections):
                    .telemetry(
                        try runtimeController.telemetrySnapshot(
                            maximumConnections: maximumConnections
                        )
                    )
                case .diagnostics:
                    .diagnostics(diagnostics.snapshot())
                case let .setRoutingMode(mode):
                    try self.applyRoutingMode(mode)
                case .resetNetwork:
                    self.handleResetNetwork()
                case let .closeConnections(request):
                    .connectionsClosed(
                        UInt32(clamping: try runtimeController.closeConnections(request: request))
                    )
                case let .recentLog(maximumKilobytes):
                    .recentLog(
                        DiagnosticLogCenter.current.recentLogData(
                            maximumBytes: Int(maximumKilobytes) * 1_024
                        )
                    )
                case let .setDiagnosticLogLevel(level):
                    self.applyDiagnosticLogLevel(level)
                case let .traceRoute(traceRequest):
                    try self.handleTraceRoute(traceRequest)
                case let .stageRoutingResourceChunk(chunk):
                    try self.handleStageRoutingResourceChunk(chunk)
                case .installedRoutingResourceDigests:
                    .routingResourceDigests(self.resourceChunkReceiver.installedDigests())
                case let .setMITMConfig(configData):
                    try {
                        try self.runtimeController.setMITMConfig(configData)
                        return .mitmConfigApplied
                    }()
                case .httpCaptures:
                    .httpCaptures(try self.runtimeController.httpCapturesJSON())
                case .reloadProfile, .hotReloadRules:
                    // Answered by the early branches above; never crash the
                    // extension (and the user's network) if that changes.
                    .failure(.invalidRequest)
                }
            } catch is ProxySelectionProviderMessageError {
                response = .failure(.invalidRequest)
            } catch let error as TransparentProxySelectionError {
                response = .failure(
                    error == .unsupported ? .rejected : .unavailable
                )
            } catch let error as FlowCoreEngineError {
                response = .failure(Self.failure(for: error))
            } catch {
                response = .failure(.internalFailure)
            }

            if case let .failure(failure) = response {
                Self.runtimeLog.failure(
                    "stage=providerMessage response=failure code=\(failure.rawValue)"
                )
                diagnostics.record(failure)
            } else {
                Self.runtimeLog.verbose("stage=providerMessage response=success")
            }

            guard watchdogState.markCompleted() else { return }
            watchdog.cancel()
            do {
                completion.call(
                    try ProxySelectionProviderMessageCodec.encode(
                        response: response
                    )
                )
            } catch ProxySelectionProviderMessageError.tooLarge {
                if case .telemetry = request,
                   let compactSnapshot = try? runtimeController.telemetrySnapshot(maximumConnections: 64),
                   let compactData = try? ProxySelectionProviderMessageCodec.encode(
                       response: .telemetry(compactSnapshot)
                   ) {
                    completion.call(compactData)
                    return
                }
                diagnostics.record(.oversizedControlResponse)
                completion.call(
                    try? ProxySelectionProviderMessageCodec.encode(
                        response: .failure(.responseTooLarge)
                    )
                )
            } catch {
                diagnostics.record(.oversizedControlResponse)
                completion.call(
                    try? ProxySelectionProviderMessageCodec.encode(
                        response: .failure(.responseTooLarge)
                    )
                )
            }
        }
    }

    private static func watchdogTimeoutSeconds(
        for request: ProxySelectionProviderRequest
    ) -> Int {
        switch request {
        case let .latency(_, _, timeoutMilliseconds, _):
            let perBatchSeconds = max(1, Int((timeoutMilliseconds + 999) / 1_000))
            return max(15, perBatchSeconds * 8 + 5)
        case let .activeLatency(_, _, timeoutMilliseconds, _):
            let probeSeconds = max(1, Int((timeoutMilliseconds + 999) / 1_000))
            return max(15, probeSeconds + 5)
        case .reloadProfile, .hotReloadRules, .stageRoutingResourceChunk:
            return 30
        default:
            return 15
        }
    }

    @discardableResult
    static func restoreSelections(
        _ rawSelections: [String: String],
        profileYAML: String,
        to engine: FlowCoreEngine
    ) -> Int {
        let profileSummary = ProfileConfigurationInspector.inspect(yaml: profileYAML)
        let seededSelections = InitialProxySelectionPolicy.selections(
            persisted: rawSelections,
            summary: profileSummary
        )
        let manualGroups = Set(
            profileSummary.proxyGroups
                .filter { $0.strategy.caseInsensitiveCompare("select") == .orderedSame }
                .map(\.name)
        )
        let restorable = seededSelections.filter {
            manualGroups.contains($0.key) || $0.key == "GLOBAL"
        }
        var appliedCount = 0
        for (group, member) in restorable.sorted(by: { $0.key < $1.key }) where group != "GLOBAL" {
            if (try? engine.selectProxy(group: group, member: member)) != nil {
                appliedCount += 1
            }
        }
        var globalApplied = false
        if let explicitGlobal = restorable["GLOBAL"] {
            globalApplied = (try? engine.selectProxy(group: "GLOBAL", member: explicitGlobal)) != nil
        }
        if !globalApplied,
           let defaultGlobal = resolveDefaultGlobalOutbound(summary: profileSummary)
        {
            globalApplied = (try? engine.selectProxy(group: "GLOBAL", member: defaultGlobal)) != nil
        }
        if !globalApplied,
           let globalSnapshot = try? engine.selectorSnapshot(group: "GLOBAL"),
           let candidate = globalSnapshot.members.first(where: InitialProxySelectionPolicy.isRouteCandidate)
        {
            globalApplied = (try? engine.selectProxy(group: "GLOBAL", member: candidate)) != nil
        }
        if !globalApplied {
            globalApplied = (try? engine.selectProxy(group: "GLOBAL", member: "DIRECT")) != nil
        }
        if globalApplied {
            appliedCount += 1
        }
        return appliedCount
    }

    static func resolveDefaultGlobalOutbound(
        summary: ProfileConfigurationSummary
    ) -> String? {
        let nonGlobalGroups = summary.proxyGroups.filter {
            $0.name.caseInsensitiveCompare("GLOBAL") != .orderedSame
        }
        let groupNames = Set(nonGlobalGroups.map(\.name))
        let usableProxies = summary.proxies.filter(\.recognition.isUsable)
        let usableProxyNames = Set(usableProxies.map(\.name))

        if let matchTarget = summary.allRules.last(where: {
            let kind = $0.kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return kind == "MATCH" || kind == "FINAL"
        })?.target,
           InitialProxySelectionPolicy.isRouteCandidate(matchTarget),
           groupNames.contains(matchTarget) || usableProxyNames.contains(matchTarget)
        {
            return matchTarget
        }

        if let primarySelectGroup = nonGlobalGroups.first(where: {
            $0.strategy.caseInsensitiveCompare("select") == .orderedSame
                && InitialProxySelectionPolicy.isRouteCandidate($0.name)
        }) {
            return primarySelectGroup.name
        }

        if let primaryGroup = nonGlobalGroups.first(where: {
            InitialProxySelectionPolicy.isRouteCandidate($0.name)
        }) ?? nonGlobalGroups.first {
            return primaryGroup.name
        }

        if let primaryProxy = usableProxies.first(where: {
            InitialProxySelectionPolicy.isRouteCandidate($0.name)
        }) ?? usableProxies.first {
            return primaryProxy.name
        }

        return nil
    }

    private func applyRoutingMode(
        _ mode: RoutingMode
    ) throws -> ProxySelectionProviderResponse {
        try runtimeController.setRoutingMode(mode)
        recipeLock.withLock { runtimeRecipe?.routingMode = mode }
        return .routingMode(mode)
    }

    /// Selections made while running must survive a recovery rebuild, which
    /// would otherwise bring back the ones from launch.
    private func applySelection(
        group: String,
        member: String
    ) throws -> ProxySelectionState {
        let state = try runtimeController.selectProxy(group: group, member: member)
        recipeLock.withLock { runtimeRecipe?.selections[group] = member }
        return state
    }

    /// The host's level reaches this root-owned extension only through a
    /// message: it cannot see the level file the app writes.
    private func applyDiagnosticLogLevel(
        _ level: DiagnosticLogLevel
    ) -> ProxySelectionProviderResponse {
        DiagnosticLogCenter.current.applyLevelOverride(level)
        Self.runtimeLog.lifecycle("stage=appMessage setDiagnosticLogLevel applied")
        return .diagnosticLogLevelApplied
    }

    private func handleResetNetwork() -> ProxySelectionProviderResponse {
        Self.runtimeLog.lifecycle("stage=appMessage resetNetwork requested")
        // `NEProvider.wake()` is not guaranteed to arrive, so the host's wake
        // request has to start the same converging run rather than a single
        // best-effort reset.
        recovery.trigger(reason: "appMessage", supersedes: true)
        return .networkReset
    }

    private func handleStageRoutingResourceChunk(
        _ chunk: RoutingResourceTransferChunk
    ) throws -> ProxySelectionProviderResponse {
        try resourceChunkReceiver.receive(chunk)
        return .routingResourceChunkStaged
    }

    private func finishTimedProviderResponse(
        _ response: ProxySelectionProviderResponse,
        watchdog: DispatchSourceTimer,
        watchdogState: WatchdogState,
        completion: ProxyMessageCompletion
    ) {
        guard watchdogState.markCompleted() else { return }
        watchdog.cancel()
        if case let .failure(failure) = response {
            Self.runtimeLog.failure(
                "stage=providerMessage response=failure code=\(failure.rawValue)"
            )
            diagnostics.record(failure)
        } else {
            Self.runtimeLog.verbose("stage=providerMessage response=success")
        }
        do {
            completion.call(
                try ProxySelectionProviderMessageCodec.encode(
                    response: response
                )
            )
        } catch {
            diagnostics.record(.oversizedControlResponse)
            completion.call(
                try? ProxySelectionProviderMessageCodec.encode(
                    response: .failure(.responseTooLarge)
                )
            )
        }
    }

    private func decodeReloadSnapshot(
        payloadData: Data
    ) throws -> ProviderLaunchSnapshot {
        let reloadPayload = try TransparentProxyReloadPayloadPolicy.decode(payloadData)
        let previousRecipe = self.recipeLock.withLock { self.runtimeRecipe }
        let fallbackDiagnosticLevel = previousRecipe?.snapshot.diagnosticLogLevel ?? DiagnosticLogCenter.current.level
        let effectiveDiagnosticLevel = reloadPayload.diagnosticLogLevel ?? fallbackDiagnosticLevel
        DiagnosticLogCenter.current.applyLevelOverride(effectiveDiagnosticLevel)
        let store = try ActiveProfileStore.applicationGroup()
        let resourceStore = RoutingResourceStore(
            applicationSupportDirectory: store.directoryURL
        )
        let resources = try resourceStore.resolveReloadResourceSnapshot(
            for: reloadPayload.profileYAML,
            inlineResources: reloadPayload.routingResources
        )
        return try ProviderLaunchSnapshot(
            profileYAML: reloadPayload.profileYAML,
            routingMode: reloadPayload.routingMode,
            bypassPolicy: reloadPayload.bypassPolicy,
            dnsPolicy: reloadPayload.dnsPolicy,
            proxySelections: reloadPayload.proxySelections,
            routingResources: resources,
            diagnosticLogLevel: effectiveDiagnosticLevel
        )
    }

    private func handleHotReloadRules(
        payloadData: Data,
        reloadOutbounds: Bool,
        watchdogState: WatchdogState,
        outerCompletion: @escaping @Sendable (ProxySelectionProviderResponse) -> Void
    ) {
        reloadGate.enqueue { [weak self] finishReload in
            let completion: @Sendable (ProxySelectionProviderResponse) -> Void = { response in
                finishReload()
                outerCompletion(response)
            }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            if watchdogState.hasTimedOut {
                finishReload()
                return
            }
            self.reloadWorkerQueue.async { [weak self] in
                guard let self else {
                    completion(.failure(.unavailable))
                    return
                }
                if watchdogState.hasTimedOut {
                    finishReload()
                    return
                }
                Self.runtimeLog.aggregate("stage=handleHotReloadRules requested reloadOutbounds=\(reloadOutbounds)")
                guard !self.uplinkLock.withLock({ self.providerStopping }), !watchdogState.hasTimedOut else {
                    completion(.failure(.unavailable))
                    return
                }
                let snapshot: ProviderLaunchSnapshot
                do {
                    snapshot = try self.decodeReloadSnapshot(payloadData: payloadData)
                } catch TransparentProxyReloadPayloadError.emptyPayload {
                    Self.runtimeLog.failure("stage=handleHotReloadRules failed reason=emptyPayload")
                    completion(.failure(.invalidRequest))
                    return
                } catch {
                    Self.runtimeLog.failure(
                        "stage=handleHotReloadRules decodeFailed error=\(String(reflecting: error))"
                    )
                    completion(.failure(.invalidRequest))
                    return
                }
                do {
                    let previousRecipe = self.recipeLock.withLock { self.runtimeRecipe }
                    let input = try TransparentProxyRuntimeInputLoader.load(snapshot: snapshot)
                    let nextInputs = try Self.networkSettingsInputs(for: snapshot)
                    let previousInputs = previousRecipe.flatMap {
                        try? Self.networkSettingsInputs(for: $0.snapshot)
                    }
                    let profileYAML = String(decoding: input.profile, as: UTF8.self)
                    try self.runtimeController.reloadRules(
                        profileYAML: profileYAML,
                        workingDirectory: input.runtimeDirectory,
                        reloadOutbounds: reloadOutbounds
                    )
                    try self.runtimeController.setRoutingMode(snapshot.routingMode)
                    if reloadOutbounds {
                        for (group, member) in snapshot.proxySelections.sorted(by: { $0.key < $1.key })
                        where group != "GLOBAL" {
                            _ = try? self.runtimeController.selectProxy(group: group, member: member)
                        }
                        if let global = snapshot.proxySelections["GLOBAL"] {
                            _ = try? self.runtimeController.selectProxy(group: "GLOBAL", member: global)
                        }
                    }
                    let newRecipe = RuntimeRecipe(
                        snapshot: snapshot,
                        selections: snapshot.proxySelections,
                        routingMode: snapshot.routingMode
                    )
                    let sameSettings = previousInputs.map {
                        $0.bypassPlan == nextInputs.bypassPlan && $0.exclusions == nextInputs.exclusions
                    } ?? false
                    if sameSettings {
                        self.recipeLock.withLock {
                            if !self.uplinkLock.withLock({ self.providerStopping }) {
                                self.runtimeRecipe = newRecipe
                            }
                        }
                        Self.runtimeLog.lifecycle("stage=handleHotReloadRules success skippedNetworkSettings=true")
                        completion(.profileReloaded)
                        return
                    }
                    let nextSettings = try Self.makeNetworkSettings(
                        bypassPlan: nextInputs.bypassPlan,
                        upstreamExclusions: nextInputs.exclusions
                    )
                    self.setTunnelNetworkSettings(nextSettings) { [weak self] settingsError in
                        guard let self else {
                            completion(.failure(.unavailable))
                            return
                        }
                        if self.uplinkLock.withLock({ self.providerStopping }) {
                            completion(.failure(.unavailable))
                            return
                        }
                        if let settingsError {
                            Self.runtimeLog.failure(
                                "stage=handleHotReloadRules settingsFailed error=\(String(reflecting: settingsError))"
                            )
                            completion(.failure(.internalFailure))
                            return
                        }
                        self.recipeLock.withLock {
                            if !self.uplinkLock.withLock({ self.providerStopping }) {
                                self.runtimeRecipe = newRecipe
                            }
                        }
                        Self.runtimeLog.lifecycle("stage=handleHotReloadRules success skippedNetworkSettings=false")
                        completion(.profileReloaded)
                    }
                } catch is ProxySelectionProviderMessageError {
                    completion(.failure(.invalidRequest))
                } catch TransparentProxySelectionError.unsupported {
                    completion(.failure(.rejected))
                } catch TransparentProxySelectionError.providerUnavailable,
                        TransparentProxySelectionError.runtimeStopping {
                    completion(.failure(.unavailable))
                } catch {
                    Self.runtimeLog.failure("stage=handleHotReloadRules failed error=\(String(reflecting: error))")
                    completion(.failure(.internalFailure))
                }
            }
        }
    }

    private func handleReloadProfile(
        payloadData: Data,
        watchdogState: WatchdogState,
        outerCompletion: @escaping @Sendable (ProxySelectionProviderResponse) -> Void
    ) {
        reloadGate.enqueue { [weak self] finishReload in
            let completion: @Sendable (ProxySelectionProviderResponse) -> Void = { response in
                finishReload()
                outerCompletion(response)
            }
            guard let self else {
                completion(.failure(.unavailable))
                return
            }
            if watchdogState.hasTimedOut {
                finishReload()
                return
            }
            self.reloadWorkerQueue.async { [weak self] in
                guard let self else {
                    completion(.failure(.unavailable))
                    return
                }
                if watchdogState.hasTimedOut {
                    finishReload()
                    return
                }
                Self.runtimeLog.lifecycle("stage=handleReloadProfile requested")
                guard !self.uplinkLock.withLock({ self.providerStopping }), !watchdogState.hasTimedOut else {
                    completion(.failure(.unavailable))
                    return
                }
                let reloadPayload: ReloadProfilePayload
                do {
                    reloadPayload = try TransparentProxyReloadPayloadPolicy.decode(payloadData)
                } catch TransparentProxyReloadPayloadError.emptyPayload {
                    Self.runtimeLog.failure("stage=handleReloadProfile failed reason=emptyPayload")
                    completion(.failure(.invalidRequest))
                    return
                } catch {
                    Self.runtimeLog.failure(
                        "stage=handleReloadProfile decodeFailed error=\(String(reflecting: error))"
                    )
                    completion(.failure(.invalidRequest))
                    return
                }
                do {
                    let previousRecipe = self.recipeLock.withLock { self.runtimeRecipe }
                    let fallbackDiagnosticLevel = previousRecipe?.snapshot.diagnosticLogLevel ?? DiagnosticLogCenter.current.level
                    let effectiveDiagnosticLevel = reloadPayload.diagnosticLogLevel ?? fallbackDiagnosticLevel
                    DiagnosticLogCenter.current.applyLevelOverride(effectiveDiagnosticLevel)
                    let store = try ActiveProfileStore.applicationGroup()
                    let resourceStore = RoutingResourceStore(
                        applicationSupportDirectory: store.directoryURL
                    )
                    let resources = try resourceStore.resolveReloadResourceSnapshot(
                        for: reloadPayload.profileYAML,
                        inlineResources: reloadPayload.routingResources
                    )
                    let snapshot = try ProviderLaunchSnapshot(
                        profileYAML: reloadPayload.profileYAML,
                        routingMode: reloadPayload.routingMode,
                        bypassPolicy: reloadPayload.bypassPolicy,
                        dnsPolicy: reloadPayload.dnsPolicy,
                        proxySelections: reloadPayload.proxySelections,
                        routingResources: resources,
                        diagnosticLogLevel: effectiveDiagnosticLevel
                    )

                    let settings = try Self.makeNetworkSettings(for: snapshot)
                    guard !self.uplinkLock.withLock({ self.providerStopping }), !watchdogState.hasTimedOut else {
                        completion(.failure(.unavailable))
                        return
                    }
                    let newRecipe = RuntimeRecipe(
                        snapshot: snapshot,
                        selections: snapshot.proxySelections,
                        routingMode: snapshot.routingMode
                    )
                    let identityGuard = self.identityGuard
                    let diagnostics = self.diagnostics

                    self.runtimeController.rebuildRuntime(
                        runtimeFactory: {
                            try Self.makeRuntime(
                                snapshot: snapshot,
                                selections: snapshot.proxySelections,
                                routingMode: snapshot.routingMode,
                                identityGuard: identityGuard,
                                diagnostics: diagnostics
                            )
                        },
                        completion: { [weak self] swapped in
                            guard let self else {
                                completion(.failure(.unavailable))
                                return
                            }
                            guard !self.uplinkLock.withLock({ self.providerStopping }) else {
                                completion(.failure(.unavailable))
                                return
                            }
                            if watchdogState.hasTimedOut {
                                if swapped {
                                    self.rollbackReloadedRuntime(
                                        to: previousRecipe,
                                        triggerError: CancellationError(),
                                        identityGuard: identityGuard,
                                        diagnostics: diagnostics,
                                        completion: { _ in }
                                    )
                                }
                                completion(.failure(.unavailable))
                                return
                            }
                            guard swapped else {
                                Self.runtimeLog.failure("stage=handleReloadProfile rebuildFailed")
                                completion(.failure(.internalFailure))
                                return
                            }
                            self.setTunnelNetworkSettings(settings) { [weak self] settingsError in
                                guard let self else {
                                    completion(.failure(.unavailable))
                                    return
                                }
                                guard !self.uplinkLock.withLock({ self.providerStopping }) else {
                                    completion(.failure(.unavailable))
                                    return
                                }
                                if let settingsError {
                                    Self.runtimeLog.failure(
                                        "stage=handleReloadProfile settingsFailed error=\(String(reflecting: settingsError))"
                                    )
                                    self.rollbackReloadedRuntime(
                                        to: previousRecipe,
                                        triggerError: settingsError,
                                        identityGuard: identityGuard,
                                        diagnostics: diagnostics,
                                        completion: completion
                                    )
                                    return
                                }
                                self.recipeLock.withLock {
                                    if !self.uplinkLock.withLock({ self.providerStopping }) {
                                        self.runtimeRecipe = newRecipe
                                    }
                                }
                                completion(.profileReloaded)
                            }
                        }
                    )
                } catch {
                    Self.runtimeLog.failure("stage=handleReloadProfile failed error=\(String(reflecting: error))")
                    completion(.failure(.internalFailure))
                }
            }
        }
    }

    private func rollbackReloadedRuntime(
        to previousRecipe: RuntimeRecipe?,
        triggerError: Error,
        identityGuard: TransparentProxySelfIdentityGuard,
        diagnostics: ProviderDiagnosticAccumulator,
        completion: @escaping @Sendable (ProxySelectionProviderResponse) -> Void
    ) {
        guard !uplinkLock.withLock({ providerStopping }) else {
            completion(.failure(.unavailable))
            return
        }
        guard let previousRecipe else {
            Self.runtimeLog.failure("stage=handleReloadProfile rollbackFailed reason=missingPreviousRecipe")
            completion(.failure(.internalFailure))
            cancelProxyWithError(triggerError)
            return
        }
        let rollbackSettings: NETransparentProxyNetworkSettings
        do {
            rollbackSettings = try Self.makeNetworkSettings(for: previousRecipe.snapshot)
        } catch {
            Self.runtimeLog.failure(
                "stage=handleReloadProfile rollbackSettingsPrepareFailed error=\(String(reflecting: error))"
            )
            completion(.failure(.internalFailure))
            cancelProxyWithError(error)
            return
        }
        runtimeController.rebuildRuntime(
            runtimeFactory: {
                try Self.makeRuntime(
                    snapshot: previousRecipe.snapshot,
                    selections: previousRecipe.selections,
                    routingMode: previousRecipe.routingMode,
                    identityGuard: identityGuard,
                    diagnostics: diagnostics
                )
            },
            completion: { [weak self] rolledBack in
                guard let self else {
                    completion(.failure(.unavailable))
                    return
                }
                guard rolledBack else {
                    Self.runtimeLog.failure("stage=handleReloadProfile rollbackFailed")
                    completion(.failure(.internalFailure))
                    self.cancelProxyWithError(triggerError)
                    return
                }
                self.setTunnelNetworkSettings(rollbackSettings) { [weak self] rollbackSettingsError in
                    if let rollbackSettingsError {
                        Self.runtimeLog.failure(
                            "stage=handleReloadProfile rollbackSettingsFailed error=\(String(reflecting: rollbackSettingsError))"
                        )
                        completion(.failure(.internalFailure))
                        self?.cancelProxyWithError(rollbackSettingsError)
                        return
                    }
                    if let self {
                        self.recipeLock.withLock {
                            self.runtimeRecipe = previousRecipe
                        }
                    }
                    completion(.failure(.internalFailure))
                }
            }
        )
    }

    private static func networkSettingsInputs(
        for snapshot: ProviderLaunchSnapshot
    ) throws -> (bypassPlan: BypassNetworkSettingsPlan, exclusions: [TransparentProxyUpstreamExclusion]) {
        let bypassPlan = try BypassNetworkSettingsPlan(policy: snapshot.bypassPolicy)
        let upstreamExclusions: [TransparentProxyUpstreamExclusion]
        do {
            upstreamExclusions = try TransparentProxyUpstreamEndpointResolver.resolve(profileYAML: snapshot.profileYAML)
        } catch TransparentProxyUpstreamEndpointResolutionError.unresolvedEndpoint {
            upstreamExclusions = []
        }
        return (bypassPlan, upstreamExclusions)
    }

    private static func makeNetworkSettings(
        for snapshot: ProviderLaunchSnapshot
    ) throws -> NETransparentProxyNetworkSettings {
        let inputs = try networkSettingsInputs(for: snapshot)
        return try makeNetworkSettings(
            bypassPlan: inputs.bypassPlan,
            upstreamExclusions: inputs.exclusions
        )
    }

    private func handleAdmittedFlow(_ flow: NEAppProxyFlow) -> Bool {
        let transport = Self.transportLogLabel(for: flow)
        let evaluation = runtimeController.identityEvaluation(for: flow)
        switch evaluation.disposition {
        case .bypass:
            Self.aggregator.record(.flowBypassed)
            Self.runtimeLog.verbose(
                "stage=handleNewFlow transport=\(transport) disposition=bypass"
            )
            // This is the only false return in the provider: code-identity-
            // verified egress from this extension must escape recursion.
            return false
        case .reject:
            Self.runtimeLog.failure(
                "stage=handleNewFlow transport=\(transport) disposition=reject"
            )
            return failClosed(flow)
        case .proxy:
            Self.runtimeLog.verbose(
                "stage=handleNewFlow transport=\(transport) disposition=proxy"
            )
            guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
                Self.runtimeLog.failure(
                    "stage=handleNewFlow transport=\(transport) error=unexpectedFlowType"
                )
                return failClosed(flow)
            }
            return claimTCP(
                tcpFlow,
                sourceApp: TransparentProxySourceAppResolver
                    .sourceApp(for: evaluation)
            )
        }
    }

    private func claimTCP(
        _ flow: NEAppProxyTCPFlow,
        sourceApp: FlowSourceApp?
    ) -> Bool {
        do {
            Self.runtimeLog.verbose("stage=claimTCP destinationDecode begin")
            let destination = try NetworkExtensionFlowLifecycle
                .tcpDestination(for: flow)
            Self.runtimeLog.verbose("stage=claimTCP components begin")
            let components = try NetworkExtensionTCPFlowComponents(flow: flow)
            guard runtimeController.claimTCP(
                components: components.ingress,
                // NEAppProxyTCPFlow does not expose the original local socket
                // endpoint. Source-IP/source-port rules are intentionally
                // outside this first honest transparent mode.
                source: nil,
                destination: destination,
                sourceApp: sourceApp
            ) else {
                Self.runtimeLog.failure(
                    "stage=claimTCP result=rejected destination=\(String(describing: destination))"
                )
                return failClosed(flow)
            }
            Self.aggregator.record(.flowAdmitted)
            Self.runtimeLog.verbose(
                "stage=claimTCP result=accepted destination=\(String(describing: destination))"
            )
            return true
        } catch {
            Self.runtimeLog.failure(
                "stage=claimTCP failed error=\(String(reflecting: error))"
            )
            return failClosed(flow)
        }
    }

    private func claimUDP(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: Network.NWEndpoint,
        admittedAt: UInt64,
        sourceApp: FlowSourceApp?
    ) -> Bool {
        do {
            Self.runtimeLog.verbose("stage=claimUDP endpointDecode begin")
            // The first target is validated even though subsequent datagrams
            // carry their own endpoint. This prevents malformed initial flow
            // metadata from reaching the data plane.
            _ = try NetworkFlowEndpointCodec.decode(
                initialRemoteEndpoint,
                transport: .udp
            )
            Self.runtimeLog.verbose("stage=claimUDP localSource begin")
            let localSource = try NetworkExtensionFlowLifecycle
                .udpLocalSource(for: flow)
            Self.runtimeLog.verbose(
                "stage=claimUDP localSource status=\(localSource == nil ? "synthetic" : "native")"
            )
            let components = try NetworkExtensionUDPFlowComponents(flow: flow)
            Self.runtimeLog.verbose("stage=claimUDP components success")
            guard runtimeController.claimUDP(
                components: components.ingress,
                localSource: localSource,
                sourceApp: sourceApp
            ) else {
                Self.runtimeLog.failure(
                    "stage=claimUDP result=rejected endpoint=\(String(describing: initialRemoteEndpoint))"
                )
                return failClosed(flow)
            }
            Self.aggregator.record(.flowAdmitted)
            Self.runtimeLog.verbose(
                "stage=claimUDP result=accepted endpoint=\(String(describing: initialRemoteEndpoint)) setupUs=\((DispatchTime.now().uptimeNanoseconds &- admittedAt) / 1_000)"
            )
            return true
        } catch {
            Self.runtimeLog.failure(
                "stage=claimUDP failed error=\(String(reflecting: error))"
            )
            return failClosed(flow)
        }
    }

    private func failClosed(_ flow: NEAppProxyFlow) -> Bool {
        Self.runtimeLog.failure(
            "stage=failClosed flowType=\(String(describing: type(of: flow)))"
        )
        diagnostics.record(.flowAdmissionFailure)
        guard runtimeController.claimAndCloseRawFlow(flow) else {
            return NetworkExtensionStoppedProviderFlow
                .claimAndCloseSynchronously(flow)
        }
        return true
    }

    private static func makeNetworkSettings(
        bypassPlan: BypassNetworkSettingsPlan,
        upstreamExclusions: [TransparentProxyUpstreamExclusion]
    ) throws -> NETransparentProxyNetworkSettings {
        let settings = NETransparentProxyNetworkSettings(
            tunnelRemoteAddress: "127.0.0.1"
        )
        settings.includedNetworkRules = [
            NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .TCP,
                direction: .outbound
            ),
            NENetworkRule(
                remoteNetworkEndpoint: nil,
                remotePrefix: 0,
                localNetworkEndpoint: nil,
                localPrefix: 0,
                protocol: .UDP,
                direction: .outbound
            ),
        ]
        var excludedDomainSuffixes: [String] = []
        var seenExcludedDomains = Set<String>()
        for domain in ["localhost", "local"] + bypassPlan.domainSuffixes {
            let normalized = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !normalized.isEmpty, seenExcludedDomains.insert(normalized).inserted {
                excludedDomainSuffixes.append(domain)
            }
        }
        var exclusions = excludedDomainSuffixes.map { domain in
            NENetworkRule(
                destinationHostEndpoint: .hostPort(
                    host: .name(domain, nil),
                    port: .any
                ),
                protocol: .any
            )
        }
        for (base, prefix) in BypassNetworkSettingsPlan.transparentProxyInfrastructureIPv4Exclusions {
            if let address = Network.IPv4Address(base) {
                exclusions.append(
                    NENetworkRule(
                        destinationNetworkEndpoint: .hostPort(
                            host: .ipv4(address),
                            port: .any
                        ),
                        prefix: prefix,
                        protocol: .any
                    )
                )
            }
        }
        for (base, prefix) in BypassNetworkSettingsPlan.transparentProxyInfrastructureIPv6Exclusions {
            if let address = Network.IPv6Address(base) {
                exclusions.append(
                    NENetworkRule(
                        destinationNetworkEndpoint: .hostPort(
                            host: .ipv6(address),
                            port: .any
                        ),
                        prefix: prefix,
                        protocol: .any
                    )
                )
            }
        }
        for route in bypassPlan.ipv4Routes {
            guard let address = Network.IPv4Address(route.destinationAddress)
            else {
                throw BypassPolicyError.invalidCIDR
            }
            exclusions.append(
                NENetworkRule(
                    destinationNetworkEndpoint: .hostPort(
                        host: .ipv4(address),
                        port: .any
                    ),
                    prefix: route.prefixLength,
                    protocol: .any
                )
            )
        }
        for route in bypassPlan.ipv6Routes {
            guard let address = Network.IPv6Address(route.destinationAddress)
            else {
                throw BypassPolicyError.invalidCIDR
            }
            exclusions.append(
                NENetworkRule(
                    destinationNetworkEndpoint: .hostPort(
                        host: .ipv6(address),
                        port: .any
                    ),
                    prefix: route.prefixLength,
                    protocol: .any
                )
            )
        }
        for endpoint in upstreamExclusions {
            // Apple forbids port 53 in address-based transparent-proxy
            // exclusions, and a whole-host (`port: .any`) exclusion would let
            // all user traffic (e.g. HTTPS 443) to that IP bypass the proxy.
            // Extension egress on port 53 is already bypassed via code-signed
            // `TransparentProxySelfIdentityGuard`.
            guard BypassNetworkSettingsPlan.shouldInstallAddressExclusionForUpstreamPort(endpoint.port) else {
                continue
            }
            guard let port = NWEndpoint.Port(rawValue: endpoint.port) else {
                throw TransparentProxyUpstreamEndpointResolutionError
                    .invalidEndpoint(index: 0)
            }
            let host: NWEndpoint.Host
            let prefix: Int
            switch endpoint.addressFamily {
            case .ipv4:
                guard let address = Network.IPv4Address(endpoint.address) else {
                    throw TransparentProxyUpstreamEndpointResolutionError
                        .invalidEndpoint(index: 0)
                }
                host = .ipv4(address)
                prefix = 32
            case .ipv6:
                guard let address = Network.IPv6Address(endpoint.address) else {
                    throw TransparentProxyUpstreamEndpointResolutionError
                        .invalidEndpoint(index: 0)
                }
                host = .ipv6(address)
                prefix = 128
            }
            exclusions.append(
                NENetworkRule(
                    destinationNetworkEndpoint: .hostPort(
                        host: host,
                        port: port
                    ),
                    prefix: prefix,
                    protocol: .any
                )
            )
        }
        settings.excludedNetworkRules = exclusions
        return settings
    }

    private static func failure(
        for error: FlowCoreEngineError
    ) -> ProxySelectionProviderFailure {
        switch error {
        case .engineClosed:
            .unavailable
        case .selectionRejected, .selectorUnavailable:
            .rejected
        case .resourceExhausted, .invalidSelectorSnapshot, .invalidLatencyResult:
            .responseTooLarge
        default:
            .internalFailure
        }
    }

    private static func messageKind(
        _ request: ProxySelectionProviderRequest
    ) -> String {
        switch request {
        case .snapshot: "snapshot"
        case .select: "select"
        case .latency: "latency"
        case .activeLatency: "activeLatency"
        case .telemetry: "telemetry"
        case .diagnostics: "diagnostics"
        case .setRoutingMode: "setRoutingMode"
        case .resetNetwork: "resetNetwork"
        case .reloadProfile: "reloadProfile"
        case .hotReloadRules: "hotReloadRules"
        case .closeConnections: "closeConnections"
        case .recentLog: "recentLog"
        case .setDiagnosticLogLevel: "setDiagnosticLogLevel"
        case .traceRoute: "traceRoute"
        case .stageRoutingResourceChunk: "stageRoutingResourceChunk"
        case .installedRoutingResourceDigests: "installedRoutingResourceDigests"
        case .setMITMConfig: "setMITMConfig"
        case .httpCaptures: "httpCaptures"
        }
    }

    private func cachedProfileSummary(for yaml: String) -> ProfileConfigurationSummary {
        let digest = ProxySelectionStore.profileDigest(yaml: yaml)
        if let existing = recipeLock.withLock({ cachedSummary }), existing.digest == digest {
            return existing.summary
        }
        let inspected = ProfileConfigurationInspector.inspect(yaml: yaml)
        recipeLock.withLock {
            cachedSummary = (digest: digest, summary: inspected)
        }
        return inspected
    }

    private func handleTraceRoute(
        _ request: RouteTraceRequest
    ) throws -> ProxySelectionProviderResponse {
        let recipe = recipeLock.withLock { runtimeRecipe }
        let mode = recipe?.routingMode ?? .rule
        let profileYAML = recipe?.snapshot.profileYAML
        let summary = profileYAML.map { cachedProfileSummary(for: $0) }
        var liveSelections = recipe?.selections ?? recipe?.snapshot.proxySelections ?? [:]
        if let summary {
            for group in summary.proxyGroups {
                if let groupSnapshot = try? runtimeController.selectorSnapshot(group: group.name),
                   let selected = groupSnapshot.selectedMember,
                   !selected.isEmpty {
                    liveSelections[group.name] = selected
                }
            }
        }
        let customRules = (try? CustomRuleStore.applicationGroup().load()) ?? []
        let result = RouteSimulationInspector.evaluate(
            request: request,
            routingMode: mode,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: liveSelections,
            customRules: customRules,
            customHosts: request.customHosts,
            geoSiteData: recipe?.snapshot.routingResources[.geoSite],
            countryMMDBData: recipe?.snapshot.routingResources[.countryMMDB],
            asnMMDBData: recipe?.snapshot.routingResources[.asnMMDB],
            resolvedAddresses: request.resolvedAddresses,
            source: .liveProvider
        )
        return .traceRoute(result)
    }
}

// Swift 6 exposes UDP delivery through this typed macOS 15 protocol.
@available(macOS 15.0, *)
extension TransparentProxyProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        Self.runtimeLog.verbose("stage=handleNewFlow transport=udp begin")
        // NetworkExtension hands us short-lived UDP flows. Everything between
        // this point and `open()` is latency the peer may not wait through, so
        // it has to be measurable rather than inferred.
        let admittedAt = DispatchTime.now().uptimeNanoseconds
        return runtimeController.withFlowAdmission { [self] in
            handleAdmittedUDPFlow(
                flow,
                initialRemoteEndpoint: remoteEndpoint,
                admittedAt: admittedAt
            )
        } ?? NetworkExtensionStoppedProviderFlow
            .claimAndCloseSynchronously(flow)
    }

    private func handleAdmittedUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint remoteEndpoint: Network.NWEndpoint,
        admittedAt: UInt64
    ) -> Bool {
        let evaluation = runtimeController.identityEvaluation(for: flow)
        switch evaluation.disposition {
        case .bypass:
            Self.aggregator.record(.flowBypassed)
            Self.runtimeLog.verbose(
                "stage=handleNewFlow transport=udp disposition=bypass"
            )
            return false
        case .reject:
            Self.runtimeLog.failure(
                "stage=handleNewFlow transport=udp disposition=reject"
            )
            return failClosed(flow)
        case .proxy:
            Self.runtimeLog.verbose(
                "stage=handleNewFlow transport=udp disposition=proxy"
            )
            return claimUDP(
                flow,
                initialRemoteEndpoint: remoteEndpoint,
                admittedAt: admittedAt,
                sourceApp: TransparentProxySourceAppResolver
                    .sourceApp(for: evaluation)
            )
        }
    }
}

private final class ProxyStartCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Error?) -> Void)?

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        let handler = lock.withLock { () -> ((Error?) -> Void)? in
            defer { self.handler = nil }
            return self.handler
        }
        handler?(error)
    }
}

private final class ProxyStopCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?

    init(_ handler: @escaping () -> Void) {
        self.handler = handler
    }

    func call() {
        let handler = lock.withLock { () -> (() -> Void)? in
            defer { self.handler = nil }
            return self.handler
        }
        handler?()
    }
}

private final class ProxySettingsCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (Bool) -> Void)?

    init(_ handler: @escaping @Sendable (Bool) -> Void) {
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

private final class ProxyMessageCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((Data?) -> Void)?

    init(_ handler: @escaping (Data?) -> Void) {
        self.handler = handler
    }

    func call(_ data: Data?) {
        let handler = lock.withLock { () -> ((Data?) -> Void)? in
            defer { self.handler = nil }
            return self.handler
        }
        handler?(data)
    }
}

private final class WatchdogState: @unchecked Sendable {
    private enum Phase {
        case pending
        case completed
        case timedOut
    }

    private let lock = NSLock()
    private var phase: Phase = .pending

    var hasTimedOut: Bool {
        lock.withLock { phase == .timedOut }
    }

    func markCompleted() -> Bool {
        lock.withLock {
            guard phase == .pending else { return false }
            phase = .completed
            return true
        }
    }

    func markTimedOut() -> Bool {
        lock.withLock {
            guard phase == .pending else { return false }
            phase = .timedOut
            return true
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

/// Hands a rebuild's outcome from the lifecycle callback queue to the
/// recovery queue, which waits for it with a bound.
private final class RebuildResult: @unchecked Sendable {
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private var swapped = false

    func finish(_ swapped: Bool) {
        lock.withLock { self.swapped = swapped }
        signal.signal()
    }

    func wait(seconds: TimeInterval) -> Bool {
        guard signal.wait(timeout: .now() + seconds) == .success else {
            return false
        }
        return lock.withLock { swapped }
    }
}

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
        qos: .userInitiated
    )
    /// Short enough that the whole schedule still fits inside the recovery
    /// window, long enough not to fail a link that has just come up.
    private static let healthProbeTimeoutMilliseconds: UInt32 = 3_000
    /// Built in `init`, not lazily. `wake`, `sleep` and the provider message
    /// queue can all reach it first, and a `lazy var` has no synchronisation on
    /// that first access.
    private var recovery: NetworkRecoveryCoordinator!
    // Accessed only on the recovery coordinator's serial queue.
    private var recoveryDownloadBaseline: UInt64?

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
                let profileYAML = DomesticRoutingOptimizer.isEnabled
                    ? DomesticRoutingOptimizer.optimizedProfile(for: rawYAML)
                    : rawYAML
                let engineProfile = Data(profileYAML.utf8)
                let engine = try FlowCoreEngine(
                    profile: engineProfile,
                    runtimeDirectory: input.runtimeDirectory
                )
                Self.runtimeLog.aggregate("stage=createFlowCore success")
                Self.runtimeLog.aggregate("stage=loadSelections begin")
                let profileSummary = ProfileConfigurationInspector.inspect(yaml: profileYAML)
                let rawSelections = try ProxySelectionStore.applicationGroup()
                    .selections(forProfileYAML: rawYAML)
                let savedSelections = InitialProxySelectionPolicy.selections(
                    persisted: rawSelections,
                    summary: profileSummary
                )
                Self.runtimeLog.aggregate(
                    "stage=loadSelections success count=\(savedSelections.count)"
                )
                for (group, member) in savedSelections.sorted(
                    by: { $0.key < $1.key }
                ) {
                    // A subscription can retain a group name while replacing its
                    // members. Ignore only that stale per-group override; corrupt
                    // encrypted storage still fails startup before reaching here.
                    _ = try? engine.selectProxy(group: group, member: member)
                }
                if savedSelections["GLOBAL"] == nil {
                    _ = try? engine.selectProxy(group: "GLOBAL", member: "DIRECT")
                }
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
                // Later attempts only probe. Repeated resets destroy flows
                // opened while the uplink is still becoming usable.
                if attempt == 0 {
                    self?.runtimeController.resetNetworkState()
                    Self.osLogger.info("stage=networkRecovery coreReset success")
                }
            },
            verify: { [weak self] in self?.dataPathIsHealthy() ?? false },
            observer: { [weak self] event in
                if case .started = event {
                    self?.recoveryDownloadBaseline = try? self?.runtimeController
                        .telemetrySnapshot(maximumConnections: 0).downloadTotal
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
        let completion = ProxyStartCompletion(completionHandler)
        let snapshot: ProviderLaunchSnapshot
        let bypassPlan: BypassNetworkSettingsPlan
        let upstreamExclusions: [TransparentProxyUpstreamExclusion]
        do {
            Self.runtimeLog.aggregate("stage=decodeLaunchSnapshot begin")
            snapshot = try ProviderLaunchSnapshotCodec.decode(options: options)
            Self.runtimeLog.aggregate(
                "stage=decodeLaunchSnapshot success mode=\(snapshot.routingMode.rawValue) selections=\(snapshot.proxySelections.count) resources=\(snapshot.routingResources.count)"
            )
            Self.runtimeLog.aggregate("stage=loadBypassPolicy begin source=launchSnapshot")
            bypassPlan = try BypassNetworkSettingsPlan(
                policy: snapshot.bypassPolicy
            )
            Self.runtimeLog.aggregate("stage=loadBypassPolicy success")
            Self.runtimeLog.aggregate("stage=resolveUpstreamEndpoints begin")
            upstreamExclusions = try TransparentProxyUpstreamEndpointResolver
                .resolve(profileYAML: snapshot.profileYAML)
            Self.runtimeLog.aggregate(
                "stage=resolveUpstreamEndpoints success count=\(upstreamExclusions.count)"
            )
        } catch {
            diagnostics.record(.startupFailure)
            Self.runtimeLog.failure(
                "stage=loadBypassPolicy failed error=\(String(reflecting: error))"
            )
            completion.call(error)
            return
        }
        runtimeController.start(
            runtimeFactory: { [identityGuard, diagnostics] in
                do {
                    Self.runtimeLog.aggregate("stage=loadLaunchProfile begin")
                    let input = try TransparentProxyRuntimeInputLoader.load(
                        snapshot: snapshot
                    )
                    Self.runtimeLog.aggregate("stage=loadLaunchProfile success")
                    Self.runtimeLog.aggregate("stage=createFlowCore begin")
                    let engine = try FlowCoreEngine(
                        profile: input.profile,
                        runtimeDirectory: input.runtimeDirectory,
                        configuration: FlowCoreEngineConfiguration(
                            routingMode: snapshot.routingMode
                        )
                    )
                    Self.runtimeLog.aggregate("stage=createFlowCore success")
                    Self.runtimeLog.aggregate("stage=restoreSelections begin")
                    for (group, member) in snapshot.proxySelections.sorted(
                        by: { $0.key < $1.key }
                    ) {
                        _ = try? engine.selectProxy(
                            group: group,
                            member: member
                        )
                    }
                    if snapshot.proxySelections["GLOBAL"] == nil {
                        _ = try? engine.selectProxy(group: "GLOBAL", member: "DIRECT")
                    }
                    Self.runtimeLog.aggregate(
                        "stage=restoreSelections success count=\(snapshot.proxySelections.count)"
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
                } catch {
                    Self.runtimeLog.failure(
                        "runtime preparation failed: \(String(reflecting: error))"
                    )
                    throw error
                }
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
                setTunnelNetworkSettings(settings) { error in
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
            completion: { [diagnostics] error in
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
                } else {
                    DiagnosticFlowOpenObserver.shared.attach(Self.aggregator)
                    Self.aggregator.start()
                    self.startPathMonitoring()
                    Self.runtimeLog.lifecycle("stage=startProxy success")
                }
                completion.call(error)
            }
        )
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Self.runtimeLog.lifecycle("stage=stopProxy requested")
        uplinkLock.withLock { providerStopping = true }
        stopPathMonitoring()
        recovery.cancel(reason: "stopProxy")
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

    /// Probes the live route end to end. The provider's own sockets do not pass
    /// through the flows it proxies, so asking the core to URL-test the current
    /// route is the only way to see whether traffic can leave the host.
    private func dataPathIsHealthy() -> Bool {
        if NetworkRecoveryHealthPolicy.hasReceivedTraffic(
            since: recoveryDownloadBaseline,
            total: try? runtimeController.telemetrySnapshot(maximumConnections: 0).downloadTotal
        ) { return true }
        return NetworkRecoveryHealthPolicy.isReachable { url in
            let state = try runtimeController.testActiveProxyLatency(
                group: ProxyConnectionReadinessPolicy.globalGroupName,
                url: url,
                timeoutMilliseconds: Self.healthProbeTimeoutMilliseconds
            )
            return state.results.contains { $0.delayMilliseconds != nil }
        }
    }

    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Self.osLogger.info(
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
        uplinkStore = SCDynamicStoreCreate(
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
        if let uplinkStore {
            SCDynamicStoreSetNotificationKeys(
                uplinkStore,
                nil,
                [
                    "State:/Network/Interface/en[0-9]+/(Link|IPv4|IPv6)",
                    "State:/Network/Interface/pdp_ip[0-9]+/(Link|IPv4|IPv6)",
                    "State:/Network/Global/IPv4",
                ] as CFArray
            )
            SCDynamicStoreSetDispatchQueue(uplinkStore, pathMonitorQueue)
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func stopPathMonitoring() {
        if let uplinkStore { SCDynamicStoreSetDispatchQueue(uplinkStore, nil) }
        uplinkStore = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func physicalPathDidChange(reason: String) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        guard let store = SCDynamicStoreCreate(nil, "AetherRoute transparent uplink identity" as CFString, nil, nil)
        else { return }
        let cached = uplinkLock.withLock { physicalInterfaces }
        let uplink = PhysicalUplinkDetector.currentPhysicalUplink(
            store: store,
            cachedPathInterfaces: cached
        )
        let signature = PhysicalUplinkDetector.pathSignature(store: store, uplink: uplink)
        let previous = lastPathSignature
        lastPathSignature = signature
        guard let previous, previous != signature else { return }
        Self.osLogger.info(
            "stage=physicalUplinkChanged scheduling recovery reason=\(reason, privacy: .public) signature=\(signature, privacy: .public) previous=\(previous, privacy: .public)"
        )
        recovery.trigger(reason: reason, supersedes: true)
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        Self.runtimeLog.verbose("stage=handleNewFlow transport=tcp begin")
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
        targetQueue.async { [self, runtimeController, diagnostics] in
            if case let .reloadProfile(payloadData) = request {
                self.handleReloadProfile(payloadData: payloadData) { response in
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
                    .snapshot(
                        try runtimeController.selectProxy(
                            group: group,
                            member: member
                        )
                    )
                case let .latency(group, url, timeoutMilliseconds):
                    .latency(
                        try runtimeController.testProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                    )
                case let .activeLatency(group, url, timeoutMilliseconds):
                    .latency(
                        try runtimeController.testActiveProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds
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
                case .reloadProfile:
                    fatalError("Handled above")
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
    }

    private func applyRoutingMode(
        _ mode: RoutingMode
    ) throws -> ProxySelectionProviderResponse {
        try runtimeController.setRoutingMode(mode)
        return .routingMode(mode)
    }

    private func handleResetNetwork() -> ProxySelectionProviderResponse {
        Self.runtimeLog.lifecycle("stage=appMessage resetNetwork requested")
        // `NEProvider.wake()` is not guaranteed to arrive, so the host's wake
        // request has to start the same converging run rather than a single
        // best-effort reset.
        recovery.trigger(reason: "appMessage", supersedes: true)
        return .networkReset
    }

    private func handleReloadProfile(
        payloadData: Data,
        completion: @escaping @Sendable (ProxySelectionProviderResponse) -> Void
    ) {
        Self.runtimeLog.lifecycle("stage=handleReloadProfile requested")
        guard !uplinkLock.withLock({ providerStopping }) else {
            completion(.failure(.unavailable))
            return
        }
        do {
            let store = try ActiveProfileStore.applicationGroup()
            let snapshot: ProviderLaunchSnapshot
            if !payloadData.isEmpty {
                let reloadPayload = try ReloadProfilePayloadCodec.decode(payloadData)
                let resourceStore = RoutingResourceStore(
                    applicationSupportDirectory: store.directoryURL
                )
                let resources = try resourceStore.launchResourceSnapshot(
                    for: reloadPayload.profileYAML
                )
                snapshot = try ProviderLaunchSnapshot(
                    profileYAML: reloadPayload.profileYAML,
                    routingMode: reloadPayload.routingMode,
                    bypassPolicy: reloadPayload.bypassPolicy,
                    dnsPolicy: reloadPayload.dnsPolicy,
                    proxySelections: reloadPayload.proxySelections,
                    routingResources: resources
                )
            } else {
                let activeProfile = try store.loadValidated()
                let routingMode: RoutingMode = .rule
                let resourceStore = RoutingResourceStore(applicationSupportDirectory: store.directoryURL)
                let resources = (try? resourceStore.launchResourceSnapshot(for: activeProfile.yaml)) ?? [:]
                snapshot = try ProviderLaunchSnapshot(
                    profileYAML: activeProfile.yaml,
                    routingMode: routingMode,
                    bypassPolicy: (try? BypassPolicyStore.applicationGroup().load()) ?? .empty,
                    dnsPolicy: .inherited,
                    proxySelections: [:],
                    routingResources: resources
                )
            }

            let bypassPlan = try BypassNetworkSettingsPlan(policy: snapshot.bypassPolicy)
            let upstreamExclusions = try TransparentProxyUpstreamEndpointResolver.resolve(profileYAML: snapshot.profileYAML)

            runtimeController.stop { [weak self, identityGuard, diagnostics] in
                guard let self else {
                    completion(.failure(.unavailable))
                    return
                }
                self.runtimeController.start(
                    runtimeFactory: {
                        let input = try TransparentProxyRuntimeInputLoader.load(snapshot: snapshot)
                        let engine = try FlowCoreEngine(
                            profile: input.profile,
                            runtimeDirectory: input.runtimeDirectory,
                            configuration: FlowCoreEngineConfiguration(routingMode: snapshot.routingMode)
                        )
                        for (group, member) in snapshot.proxySelections.sorted(by: { $0.key < $1.key }) {
                            _ = try? engine.selectProxy(group: group, member: member)
                        }
                        if snapshot.proxySelections["GLOBAL"] == nil {
                            _ = try? engine.selectProxy(group: "GLOBAL", member: "DIRECT")
                        }
                        return try TransparentProxyFlowRuntime(
                            engine: engine,
                            identityGuard: identityGuard,
                            failureObserver: { failure in
                                Self.runtimeLog.failure("stage=flowIngress failed point=\(String(describing: failure))")
                                Self.aggregator.record(.admissionRejected)
                                diagnostics.record(.flowAdmissionFailure)
                            }
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
                            settings = try Self.makeNetworkSettings(
                                bypassPlan: bypassPlan,
                                upstreamExclusions: upstreamExclusions
                            )
                        } catch {
                            once.call(false)
                            return
                        }
                        self.setTunnelNetworkSettings(settings) { error in
                            once.call(error == nil)
                        }
                    },
                    completion: { [weak self] error in
                        guard self != nil else {
                            completion(.failure(.unavailable))
                            return
                        }
                        if let error {
                            Self.runtimeLog.failure("stage=handleReloadProfile startFailed error=\(String(reflecting: error))")
                            completion(.failure(.internalFailure))
                            return
                        }
                        completion(.profileReloaded)
                    }
                )
            }
        } catch {
            Self.runtimeLog.failure("stage=handleReloadProfile failed error=\(String(reflecting: error))")
            completion(.failure(.internalFailure))
        }
    }

    private func handleAdmittedFlow(_ flow: NEAppProxyFlow) -> Bool {
        switch runtimeController.identityDisposition(for: flow) {
        case .bypass:
            Self.aggregator.record(.flowBypassed)
            Self.runtimeLog.verbose(
                "stage=handleNewFlow transport=tcp disposition=bypass"
            )
            // This is the only false return in the provider: code-identity-
            // verified egress from this extension must escape recursion.
            return false
        case .reject:
            Self.runtimeLog.failure(
                "stage=handleNewFlow transport=tcp disposition=reject"
            )
            return failClosed(flow)
        case .proxy:
            Self.runtimeLog.verbose(
                "stage=handleNewFlow transport=tcp disposition=proxy"
            )
            guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
                Self.runtimeLog.failure(
                    "stage=handleNewFlow transport=tcp error=unexpectedFlowType"
                )
                return failClosed(flow)
            }
            return claimTCP(tcpFlow)
        }
    }

    private func claimTCP(_ flow: NEAppProxyTCPFlow) -> Bool {
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
                destination: destination
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
        admittedAt: UInt64
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
                localSource: localSource
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
        var exclusions = bypassPlan.domainSuffixes.map { domain in
            NENetworkRule(
                destinationHostEndpoint: .hostPort(
                    host: .name(domain, nil),
                    port: .any
                ),
                protocol: .any
            )
        }
        let infrastructureIPv4Exclusions: [(String, Int)] = [
            ("127.0.0.0", 8),
            ("10.0.0.0", 8),
            ("172.16.0.0", 12),
            ("192.168.0.0", 16),
            ("169.254.0.0", 16),
        ]
        for (base, prefix) in infrastructureIPv4Exclusions {
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
        let infrastructureIPv6Exclusions: [(String, Int)] = [
            ("::1", 128),
            ("fe80::", 10),
            ("fc00::", 7),
        ]
        for (base, prefix) in infrastructureIPv6Exclusions {
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
            // exclusions. A proxy server on that port therefore receives a
            // host-only exclusion; all other servers remain exact IP+port.
            let port: NWEndpoint.Port
            if endpoint.port == 53 {
                port = .any
            } else {
                guard let resolvedPort = NWEndpoint.Port(
                    rawValue: endpoint.port
                ) else {
                    throw TransparentProxyUpstreamEndpointResolutionError
                        .invalidEndpoint(index: 0)
                }
                port = resolvedPort
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
        }
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
        switch runtimeController.identityDisposition(for: flow) {
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
                admittedAt: admittedAt
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

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

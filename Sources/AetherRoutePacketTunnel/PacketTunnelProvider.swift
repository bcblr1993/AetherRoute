import AetherRouteKit
import Network
@preconcurrency import NetworkExtension
import OSLog
import SystemConfiguration

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let runtimeLogger = AppLog.logger(category: AppLog.Category.tunnelRuntime)
    /// Short enough that ten attempts still fit inside the recovery window,
    /// long enough that a link which has just come up is not failed early.
    private static let healthProbeTimeoutMilliseconds: UInt32 = 3_000

    private let coreLock = NSLock()
    private lazy var core: any CoreBridge = RustCoreBridge(packetFlow: packetFlow)

    private func currentCore() -> any CoreBridge {
        coreLock.withLock { core }
    }

    private func swapCore(with replacement: any CoreBridge) -> any CoreBridge {
        coreLock.withLock {
            let previous = core
            core = replacement
            return previous
        }
    }
    private let diagnostics = ProviderDiagnosticAccumulator()
    private let providerMessageQueue = DispatchQueue(
        label: "com.aetherroute.packet-provider.messages",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    private let probeMessageQueue = DispatchQueue(
        label: "com.aetherroute.packet-provider.probes",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    private var pathMonitor: NWPathMonitor?
    private var uplinkStore: SCDynamicStore?
    private final class UplinkObserverContext {
        weak var provider: PacketTunnelProvider?
        init(_ provider: PacketTunnelProvider) { self.provider = provider }
    }
    private let pathMonitorQueue = DispatchQueue(
        label: "com.aetherroute.packet-provider.path",
        qos: .utility
    )
    private static let pathChangeDebounceMilliseconds: Int = 150
    // Accessed only on pathMonitorQueue.
    private var pendingPathChangeWorkItem: DispatchWorkItem?
    private var lastPathSignature: String?
    private let uplinkLock = NSLock()
    private var physicalInterfaces: [NWInterface] = []
    private var resetSucceeded = false
    // Accessed only on the recovery coordinator's serial queue.
    private var recoveryDownloadBaseline: UInt64?
    private var lastResetInterface: UInt32?
    private var lastResetSignature: String?
    private var providerStopping = false
    private var recoveryRoutingMode: RoutingMode = .rule
    /// Built in `init`, not lazily. `wake`, `sleep`, the path monitor and the
    /// provider message queue can all reach it first, and a `lazy var` has no
    /// synchronisation on that first access.
    private var recovery: NetworkRecoveryCoordinator!

    override init() {
        super.init()
        recovery = NetworkRecoveryCoordinator(
            perform: { [weak self] reason, attempt in
                self?.performNetworkRecovery(reason: reason, attempt: attempt)
            },
            verify: { [weak self] in self?.dataPathIsHealthy() ?? false },
            observer: { [weak self] event in
                Self.logRecovery(event)
                guard let self else { return }
                switch event {
                case .started:
                    self.recoveryDownloadBaseline = try? self.currentCore()
                        .telemetrySnapshot(maximumConnections: 0).downloadTotal
                    self.resetSucceeded = false
                    self.lastResetInterface = nil
                    self.lastResetSignature = nil
                    self.reasserting = true
                case .recovered:
                    self.reasserting = false
                case .exhausted:
                    // Probe exhaustion does not prove an engine failure. Keep
                    // routes, existing flows and physical-link monitoring alive.
                    // In rule mode GLOBAL may not even be the user's active route.
                    self.reasserting = self.currentPhysicalUplink() == nil
                    // With no uplink, remain reasserting until a physical-link
                    // event resumes recovery. Reporting connected here starts
                    // host readiness probes while the machine is still offline.
                case .cancelled:
                    self.reasserting = false
                default: break
                }
            }
        )
    }

    override func startTunnel(
        options: [String: NSObject]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        uplinkLock.withLock { providerStopping = false }
        Self.runtimeLogger.info("stage=startTunnel requested")
        let completion = TunnelStartCompletion(completionHandler)
        do {
            Self.runtimeLogger.info("stage=decodeLaunchSnapshot begin")
            let snapshot = try ProviderLaunchSnapshotCodec.decode(
                options: options
            )
            Self.runtimeLogger.info(
                "stage=decodeLaunchSnapshot success selections=\(snapshot.proxySelections.count, privacy: .public) resources=\(snapshot.routingResources.count, privacy: .public)"
            )
            Self.runtimeLogger.info("stage=decodeProviderConfiguration begin")
            let provider = protocolConfiguration as? NETunnelProviderProtocol
            let routingMode = try TunnelProviderConfigurationCodec.routingMode(
                from: provider?.providerConfiguration
            )
            uplinkLock.withLock { recoveryRoutingMode = routingMode }
            let localProxy = try TunnelProviderConfigurationCodec
                .localProxySettings(from: provider?.providerConfiguration)
            let enableIPv6 = try TunnelProviderConfigurationCodec
                .ipv6Enabled(from: provider?.providerConfiguration)
            let configuration = try TunnelConfiguration(
                mode: routingMode,
                enableIPv6: enableIPv6,
                localProxy: localProxy
            ).validated()
            Self.runtimeLogger.info(
                "stage=decodeProviderConfiguration success routing=\(routingMode.rawValue, privacy: .public) localProxyEnabled=\(localProxy.isEnabled, privacy: .public) ipv6Enabled=\(enableIPv6, privacy: .public)"
            )
            Self.runtimeLogger.info("stage=loadBypassPolicy begin source=launchSnapshot")
            let bypassPlan = try BypassNetworkSettingsPlan(
                policy: snapshot.bypassPolicy
            )
            Self.runtimeLogger.info("stage=loadBypassPolicy success")
            Self.runtimeLogger.info("stage=startCore begin")
            try currentCore().start(
                configuration: configuration,
                snapshot: snapshot
            ) { [weak self] coreError in
                guard let self else {
                    Self.runtimeLogger.error("stage=startCore failed reason=providerUnavailable")
                    completion.call(PacketTunnelError.coreUnavailable)
                    return
                }
                if let coreError {
                    Self.runtimeLogger.error(
                        "stage=startCore failed error=\(String(reflecting: coreError), privacy: .public)"
                    )
                    self.diagnostics.record(.startupFailure)
                    self.currentCore().stop { completion.call(coreError) }
                    return
                }

                Self.runtimeLogger.info("stage=startCore success")
                Self.runtimeLogger.info("stage=makeNetworkSettings begin")
                let settingsPlan = PacketTunnelNetworkSettingsPlan(
                    configuration: configuration,
                    bypassPlan: bypassPlan
                )
                let settings = self.makeNetworkSettings(settingsPlan)
                Self.runtimeLogger.info("stage=makeNetworkSettings success")
                Self.runtimeLogger.info("stage=installNetworkSettings begin")
                self.setTunnelNetworkSettings(settings) { [weak self] settingsError in
                    guard let self else {
                        completion.call(settingsError)
                        return
                    }
                    if let settingsError {
                        Self.runtimeLogger.error(
                            "stage=installNetworkSettings failed error=\(String(reflecting: settingsError), privacy: .public)"
                        )
                        self.diagnostics.record(.networkSettingsFailure)
                        self.currentCore().stop { completion.call(settingsError) }
                        return
                    }
                    Self.runtimeLogger.info("stage=installNetworkSettings success")
                    self.startPathMonitoring()
                    completion.call(nil)
                }
            }
            Self.runtimeLogger.info("stage=startCore submitted")
        } catch {
            Self.runtimeLogger.error(
                "stage=startTunnel failed error=\(String(reflecting: error), privacy: .public)"
            )
            diagnostics.record(.startupFailure)
            currentCore().stop { completion.call(error) }
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        Self.runtimeLogger.info(
            "stage=stopTunnel requested reason=\(reason.rawValue, privacy: .public)"
        )
        stopPathMonitoring()
        uplinkLock.withLock { providerStopping = true }
        recovery.cancel(reason: "stopTunnel")
        // macOS keeps the tunnel's interface, routes and DNS installed until
        // this completion handler returns, so it must not wait on the engine
        // unwinding. `core.stop` signals the engine and returns; the join
        // happens on a background queue afterwards.
        let completion = TunnelStopCompletion(completionHandler)
        currentCore().stop {
            Self.runtimeLogger.info("stage=stopTunnel complete")
            completion.call()
        }
    }

    override func sleep(completionHandler: @escaping () -> Void) {
        Self.runtimeLogger.info("stage=sleep requested")
        recovery.cancel(reason: "sleep")
        completionHandler()
    }

    override func wake() {
        Self.runtimeLogger.info("stage=wake requested")
        lastResetInterface = nil
        lastResetSignature = nil
        resetSucceeded = false
        recovery.trigger(reason: "wake", supersedes: true)
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        let completion = PacketProviderMessageCompletion(completionHandler)

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
        targetQueue.async { [self] in
            if case let .reloadProfile(payloadData) = request {
                self.handleReloadProfile(payloadData: payloadData) { response in
                    if case let .failure(failure) = response {
                        self.diagnostics.record(failure)
                    }
                    do {
                        completion.call(
                            try ProxySelectionProviderMessageCodec.encode(
                                response: response
                            )
                        )
                    } catch {
                        self.diagnostics.record(.oversizedControlResponse)
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
            let activeCore = currentCore()
            do {
                response = switch request {
                case let .snapshot(group):
                    .snapshot(try activeCore.selectorSnapshot(group: group))
                case let .select(group, member):
                    .snapshot(try activeCore.selectProxy(group: group, member: member))
                case let .latency(group, url, timeoutMilliseconds):
                    .latency(
                        try activeCore.testProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                    )
                case let .activeLatency(group, url, timeoutMilliseconds):
                    .latency(
                        try activeCore.testActiveProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                    )
                case let .telemetry(maximumConnections):
                    .telemetry(
                        try activeCore.telemetrySnapshot(
                            maximumConnections: maximumConnections
                        )
                    )
                case .diagnostics:
                    .diagnostics(diagnostics.snapshot().attachingDataPlane(
                        try? activeCore.dataPlaneDiagnosticsSnapshot()
                    ))
                case let .setRoutingMode(mode):
                    try applyRoutingMode(mode)
                case .resetNetwork:
                    try handleResetNetwork()
                case .reloadProfile:
                    fatalError("Handled above")
                }
            } catch is ProxySelectionProviderMessageError {
                response = .failure(.invalidRequest)
            } catch let error as PacketTunnelSelectorError {
                response = .failure(Self.failure(for: error))
            } catch {
                response = .failure(.internalFailure)
            }

            if case let .failure(failure) = response {
                diagnostics.record(failure)
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

    private func startPathMonitoring() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        pathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Self.runtimeLogger.debug(
                "stage=pathUpdate status=\(String(describing: path.status), privacy: .public) isExpensive=\(path.isExpensive, privacy: .public)"
            )
            self.uplinkLock.withLock { self.physicalInterfaces = path.availableInterfaces }
            self.physicalPathDidChange(reason: "pathChanged")
        }
        let observerContext = UplinkObserverContext(self)
        var context = SCDynamicStoreContext(version: 0,
            info: Unmanaged.passUnretained(observerContext).toOpaque(),
            retain: { pointer in
                _ = Unmanaged<UplinkObserverContext>.fromOpaque(pointer).retain()
                return pointer
            },
            release: { pointer in
                Unmanaged<UplinkObserverContext>.fromOpaque(pointer).release()
            }, copyDescription: nil)
        uplinkStore = SCDynamicStoreCreate(nil, "AetherRoute link changes" as CFString,
            { _, _, context in
                guard let context else { return }
                guard let provider = Unmanaged<UplinkObserverContext>.fromOpaque(context)
                    .takeUnretainedValue().provider else { return }
                guard !provider.uplinkLock.withLock({ provider.providerStopping }) else { return }
                provider.physicalPathDidChange(reason: "physicalLinkChanged")
            }, &context)
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
        pendingPathChangeWorkItem?.cancel()
        pendingPathChangeWorkItem = nil
        if let uplinkStore { SCDynamicStoreSetDispatchQueue(uplinkStore, nil) }
        uplinkStore = nil
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// Both notification sources run on pathMonitorQueue. A secondary link or
    /// duplicate DHCP notification must not destroy a healthy active transport.
    ///
    /// Coalesces rapid successive notifications within a 150ms window to prevent
    /// notification storms during network reconfiguration and avoid redundant
    /// dynamic store queries.
    private func physicalPathDidChange(reason: String) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        pendingPathChangeWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.uplinkLock.withLock({ self.providerStopping }) else { return }
            self.evaluatePhysicalPathChange(reason: reason)
        }
        pendingPathChangeWorkItem = workItem
        pathMonitorQueue.asyncAfter(
            deadline: .now() + .milliseconds(Self.pathChangeDebounceMilliseconds),
            execute: workItem
        )
    }

    private func evaluatePhysicalPathChange(reason: String) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        let store = uplinkStore ?? SCDynamicStoreCreate(nil, "AetherRoute uplink identity" as CFString, nil, nil)
        guard let store else { return }
        let cached = uplinkLock.withLock { physicalInterfaces }
        let uplink = PhysicalUplinkDetector.currentPhysicalUplink(
            store: store,
            cachedPathInterfaces: cached
        )
        let signature = PhysicalUplinkDetector.pathSignature(store: store, uplink: uplink)
        let previous = lastPathSignature
        lastPathSignature = signature
        guard let previous, previous != signature else { return }
        Self.runtimeLogger.info(
            "stage=physicalUplinkChanged scheduling recovery reason=\(reason, privacy: .public) signature=\(signature, privacy: .public) previous=\(previous, privacy: .public)"
        )
        recovery.trigger(reason: reason, supersedes: true)
    }

    /// Primary physical hardware uplink interface, resolved via SystemConfiguration
    /// and Darwin network interface enumeration to ensure hot-plugged devices (such as
    /// USB Ethernet adapters) and link changes are immediately detected even if
    /// the sandboxed NWPathMonitor is quiet.
    private func currentPhysicalUplink() -> PhysicalUplink? {
        guard let store = SCDynamicStoreCreate(nil, "AetherRoute uplink" as CFString, nil, nil)
        else { return nil }
        let cached = uplinkLock.withLock { physicalInterfaces }
        return PhysicalUplinkDetector.currentPhysicalUplink(
            store: store,
            cachedPathInterfaces: cached
        )
    }

    private func performNetworkRecovery(reason: String, attempt: Int) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        guard let interface = currentPhysicalUplink() else {
            resetSucceeded = false
            Self.runtimeLogger.info("stage=networkRecovery waitingForPhysicalUplink attempt=\(attempt, privacy: .public)")
            return
        }
        let index = UInt32(interface.index)
        let store = SCDynamicStoreCreate(nil, "AetherRoute recovery signature" as CFString, nil, nil)
        let signature = store.flatMap { PhysicalUplinkDetector.pathSignature(store: $0, uplink: interface) }
        // Once an interface and IP signature was reset, retry the probe without destroying the
        // connections/DNS transports that are only just becoming usable, unless the physical uplink
        // signature changed or reset has not yet succeeded.
        guard lastResetInterface != index || lastResetSignature != signature || !resetSucceeded else { return }
        resetSucceeded = false
        Self.runtimeLogger.info(
            "stage=networkRecovery begin reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public) interface=\(interface.name, privacy: .public) index=\(index, privacy: .public) signature=\(signature ?? "unknown", privacy: .public)"
        )
        do {
            try core.resetNetworkState(interfaceIndex: index)
            lastResetInterface = index
            lastResetSignature = signature
            resetSucceeded = true
            Self.runtimeLogger.info("stage=networkRecovery coreReset success")
        } catch {
            Self.runtimeLogger.error(
                "stage=networkRecovery coreReset failed reason=\(reason, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
        }
        // Physical egress changes do not change our utun addresses, routes or
        // DNS server. Keep installed settings intact throughout recovery.
    }

    /// Probes the currently selected route end to end.
    ///
    /// The provider's own sockets bypass the tunnel, so it cannot test the
    /// tunnel by making a request itself. Asking the core to URL-test the live
    /// route exercises the real outbound path — interface binding, DNS and the
    /// proxy connection — which is exactly the state a sleep invalidates.
    private func dataPathIsHealthy() -> Bool {
        guard resetSucceeded, !uplinkLock.withLock({ providerStopping }),
              let uplink = currentPhysicalUplink(),
              UInt32(uplink.index) == lastResetInterface else { return false }
        let store = SCDynamicStoreCreate(nil, "AetherRoute health signature" as CFString, nil, nil)
        let signature = store.flatMap { PhysicalUplinkDetector.pathSignature(store: $0, uplink: uplink) }
        guard lastResetSignature == signature else { return false }
        let activeCore = currentCore()
        if NetworkRecoveryHealthPolicy.hasReceivedTraffic(
            since: recoveryDownloadBaseline,
            total: try? activeCore.telemetrySnapshot(maximumConnections: 0).downloadTotal
        ) { return true }
        let healthy = NetworkRecoveryHealthPolicy.isReachable { url in
            let state = try activeCore.testActiveProxyLatency(
                group: uplinkLock.withLock { recoveryRoutingMode == .direct } ? "DIRECT"
                    : ProxyConnectionReadinessPolicy.globalGroupName,
                url: url,
                timeoutMilliseconds: Self.healthProbeTimeoutMilliseconds
            )
            return state.results.contains { $0.delayMilliseconds != nil }
        }
        Self.runtimeLogger.info("stage=recoveryHealthProbe healthy=\(healthy, privacy: .public)")
        return healthy
    }

    private static func logRecovery(_ event: NetworkRecoveryCoordinator.Event) {
        switch event {
        case let .started(reason):
            runtimeLogger.info(
                "stage=recoveryRun started reason=\(reason, privacy: .public)"
            )
        case let .coalesced(reason):
            runtimeLogger.info(
                "stage=recoveryRun coalesced reason=\(reason, privacy: .public)"
            )
        case let .attemptFailed(reason, attempt):
            runtimeLogger.info(
                "stage=recoveryRun attemptFailed reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        case let .recovered(reason, attempt):
            runtimeLogger.info(
                "stage=recoveryRun recovered reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public)"
            )
        case let .exhausted(reason, attempts):
            runtimeLogger.error(
                "stage=recoveryRun exhausted reason=\(reason, privacy: .public) attempts=\(attempts, privacy: .public)"
            )
        case let .cancelled(reason):
            runtimeLogger.info(
                "stage=recoveryRun cancelled reason=\(reason, privacy: .public)"
            )
        }
    }

    private func applyRoutingMode(
        _ mode: RoutingMode
    ) throws -> ProxySelectionProviderResponse {
        try currentCore().setRoutingMode(mode)
        uplinkLock.withLock { recoveryRoutingMode = mode }
        return .routingMode(mode)
    }

    private func handleResetNetwork() throws -> ProxySelectionProviderResponse {
        Self.runtimeLogger.info("stage=appMessage resetNetwork requested")
        // The host asks for this on wake or path change, and `NEProvider.wake()` is not
        // guaranteed to arrive — on a live host it never did across an entire
        // session. Route it through the coordinator so the app's single request
        // still gets the full converging retry loop instead of one attempt.
        lastResetInterface = nil
        lastResetSignature = nil
        resetSucceeded = false
        recovery.trigger(reason: "appMessage", supersedes: true)
        return .networkReset
    }

    private func handleReloadProfile(
        payloadData: Data,
        completion: @escaping @Sendable (ProxySelectionProviderResponse) -> Void
    ) {
        Self.runtimeLogger.info("stage=handleReloadProfile requested bytes=\(payloadData.count, privacy: .public)")
        guard !uplinkLock.withLock({ providerStopping }) else {
            Self.runtimeLogger.error("stage=handleReloadProfile rejected providerStopping")
            completion(.failure(.unavailable))
            return
        }

        do {
            let store = try ActiveProfileStore.applicationGroup()
            let snapshot: ProviderLaunchSnapshot
            if !payloadData.isEmpty {
                Self.runtimeLogger.info("stage=handleReloadProfile decoding payload from message")
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
                Self.runtimeLogger.info("stage=handleReloadProfile loading active profile from store")
                let activeProfile = try store.loadValidated()
                let provider = protocolConfiguration as? NETunnelProviderProtocol
                let routingMode = (try? TunnelProviderConfigurationCodec.routingMode(
                    from: provider?.providerConfiguration
                )) ?? recoveryRoutingMode
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

            let provider = protocolConfiguration as? NETunnelProviderProtocol
            let routingMode = snapshot.routingMode
            uplinkLock.withLock { recoveryRoutingMode = routingMode }
            let localProxy = (try? TunnelProviderConfigurationCodec.localProxySettings(
                from: provider?.providerConfiguration
            )) ?? LocalProxySettings()
            let enableIPv6 = (try? TunnelProviderConfigurationCodec.ipv6Enabled(
                from: provider?.providerConfiguration
            )) ?? false
            let configuration = try TunnelConfiguration(
                mode: routingMode,
                enableIPv6: enableIPv6,
                localProxy: localProxy
            ).validated()
            let bypassPlan = try BypassNetworkSettingsPlan(
                policy: snapshot.bypassPolicy
            )

            Self.runtimeLogger.info("stage=handleReloadProfile stopping current core")
            let oldCore = currentCore()
            oldCore.stop { [weak self] in
                guard let self else {
                    completion(.failure(.unavailable))
                    return
                }
                Self.runtimeLogger.info("stage=handleReloadProfile starting replacement core")
                let newCore = RustCoreBridge(packetFlow: self.packetFlow)
                _ = self.swapCore(with: newCore)
                do {
                    try newCore.start(
                        configuration: configuration,
                        snapshot: snapshot
                    ) { [weak self] coreError in
                        guard let self else {
                            completion(.failure(.unavailable))
                            return
                        }
                        if let coreError {
                            Self.runtimeLogger.error(
                                "stage=handleReloadProfile coreStartFailed error=\(String(reflecting: coreError), privacy: .public)"
                            )
                            self.diagnostics.record(.startupFailure)
                            completion(.failure(.internalFailure))
                            return
                        }

                        Self.runtimeLogger.info("stage=handleReloadProfile updating network settings")
                        let settingsPlan = PacketTunnelNetworkSettingsPlan(
                            configuration: configuration,
                            bypassPlan: bypassPlan
                        )
                        let settings = self.makeNetworkSettings(settingsPlan)
                        self.setTunnelNetworkSettings(settings) { [weak self] settingsError in
                            guard let self else {
                                completion(.failure(.unavailable))
                                return
                            }
                            if let settingsError {
                                Self.runtimeLogger.error(
                                    "stage=handleReloadProfile setSettingsFailed error=\(String(reflecting: settingsError), privacy: .public)"
                                )
                                self.diagnostics.record(.networkSettingsFailure)
                                completion(.failure(.internalFailure))
                                return
                            }
                            Self.runtimeLogger.info("stage=handleReloadProfile success")
                            completion(.profileReloaded)
                        }
                    }
                } catch {
                    Self.runtimeLogger.error(
                        "stage=handleReloadProfile newCoreStartException error=\(String(reflecting: error), privacy: .public)"
                    )
                    self.diagnostics.record(.startupFailure)
                    completion(.failure(.internalFailure))
                }
            }
        } catch {
            Self.runtimeLogger.error(
                "stage=handleReloadProfile failed error=\(String(reflecting: error), privacy: .public)"
            )
            diagnostics.record(.internalControlFailure)
            completion(.failure(.internalFailure))
        }
    }

    private func makeNetworkSettings(
        _ plan: PacketTunnelNetworkSettingsPlan
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(
            tunnelRemoteAddress: plan.tunnelRemoteAddress
        )
        settings.mtu = NSNumber(value: plan.mtu)

        let ipv4 = NEIPv4Settings(
            addresses: plan.ipv4.addresses,
            subnetMasks: plan.ipv4.subnetMasks
        )
        ipv4.includedRoutes = plan.ipv4.includedRoutes.map {
            NEIPv4Route(
                destinationAddress: $0.destinationAddress,
                subnetMask: $0.subnetMask
            )
        }
        ipv4.excludedRoutes = plan.ipv4.excludedRoutes
            .filter { !PacketTunnelNetworkSettingsPlan.isVirtualOverlayRoute(destinationAddress: $0.destinationAddress) }
            .map {
                NEIPv4Route(
                    destinationAddress: $0.destinationAddress,
                    subnetMask: $0.subnetMask
                )
            }
        settings.ipv4Settings = ipv4

        // Leaving `ipv6Settings` nil keeps the system's own IPv6 routing in
        // place. An IPv4-only profile that still claimed `::/0` would strand
        // every IPv6 flow the system prefers.
        if let plannedIPv6 = plan.ipv6 {
            let ipv6 = NEIPv6Settings(
                addresses: plannedIPv6.addresses,
                networkPrefixLengths: plannedIPv6.prefixLengths.map(NSNumber.init)
            )
            ipv6.includedRoutes = plannedIPv6.includedRoutes.map {
                NEIPv6Route(
                    destinationAddress: $0.destinationAddress,
                    networkPrefixLength: NSNumber(value: $0.prefixLength)
                )
            }
            ipv6.excludedRoutes = plannedIPv6.excludedRoutes
                .filter { !PacketTunnelNetworkSettingsPlan.isVirtualOverlayRoute(destinationAddress: $0.destinationAddress) }
                .map {
                    NEIPv6Route(
                        destinationAddress: $0.destinationAddress,
                        networkPrefixLength: NSNumber(value: $0.prefixLength)
                    )
                }
            settings.ipv6Settings = ipv6
        }

        let dns = NEDNSSettings(servers: plan.dns.servers)
        dns.matchDomains = plan.dns.matchDomains
        settings.dnsSettings = dns

        return settings
    }

    private static func failure(
        for error: PacketTunnelSelectorError
    ) -> ProxySelectionProviderFailure {
        switch error {
        case .invalidName:
            .invalidRequest
        // A timeout means the engine is still busy with the previous call, so
        // the answer the host wanted does not exist yet — the same thing, from
        // the host's side, as the engine not being ready.
        case .unavailable, .timedOut:
            .unavailable
        case .rejected, .selectionNotApplied:
            .rejected
        case .busy, .responseTooLarge, .invalidSnapshot, .invalidLatency:
            .responseTooLarge
        case .internalFailure:
            .internalFailure
        }
    }

    deinit {
        stopPathMonitoring()
        if !uplinkLock.withLock({ providerStopping }) {
            uplinkLock.withLock { providerStopping = true }
            currentCore().stop {}
        }
    }
}

private final class TunnelStartCompletion: @unchecked Sendable {
    private let handler: (Error?) -> Void

    init(_ handler: @escaping (Error?) -> Void) {
        self.handler = handler
    }

    func call(_ error: Error?) {
        handler(error)
    }
}

/// `stopTunnel`'s handler must fire exactly once: calling it twice traps inside
/// the framework, and never calling it leaves the tunnel's routes installed.
private final class TunnelStopCompletion: @unchecked Sendable {
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

private final class PacketProviderMessageCompletion: @unchecked Sendable {
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

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

    private lazy var core: any CoreBridge = RustCoreBridge(packetFlow: packetFlow)
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
    private var lastPathSignature: String?
    private let uplinkLock = NSLock()
    private var physicalInterfaces: [NWInterface] = []
    private var resetSucceeded = false
    // Accessed only on the recovery coordinator's serial queue.
    private var recoveryDownloadBaseline: UInt64?
    private var lastResetInterface: UInt32?
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
                    self.recoveryDownloadBaseline = try? self.core
                        .telemetrySnapshot(maximumConnections: 0).downloadTotal
                    self.resetSucceeded = false
                    self.lastResetInterface = nil
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
            try core.start(
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
                    self.core.stop { completion.call(coreError) }
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
                        self.core.stop { completion.call(settingsError) }
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
            core.stop { completion.call(error) }
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
        core.stop {
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
        recovery.trigger(reason: "wake")
    }

    override func handleAppMessage(
        _ messageData: Data,
        completionHandler: ((Data?) -> Void)? = nil
    ) {
        guard let completionHandler else { return }
        let completion = PacketProviderMessageCompletion(completionHandler)

        let request: ProxySelectionProviderRequest
        do {
            request = try ProxySelectionProviderMessageCodec.decodeRequest(messageData)
        } catch {
            let response = ProxySelectionProviderResponse.failure(.invalidRequest)
            do {
                completion.call(try ProxySelectionProviderMessageCodec.encode(response: response))
            } catch {
                completion.call(nil)
            }
            return
        }

        let isProbeRequest: Bool = switch request {
        case .latency, .activeLatency: true
        default: false
        }

        let targetQueue = isProbeRequest ? probeMessageQueue : providerMessageQueue
        targetQueue.async { [self] in
            let response: ProxySelectionProviderResponse
            do {
                response = switch request {
                case let .snapshot(group):
                    .snapshot(try core.selectorSnapshot(group: group))
                case let .select(group, member):
                    .snapshot(try core.selectProxy(group: group, member: member))
                case let .latency(group, url, timeoutMilliseconds):
                    .latency(
                        try core.testProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                    )
                case let .activeLatency(group, url, timeoutMilliseconds):
                    .latency(
                        try core.testActiveProxyLatency(
                            group: group,
                            url: url,
                            timeoutMilliseconds: timeoutMilliseconds
                        )
                    )
                case let .telemetry(maximumConnections):
                    .telemetry(
                        try core.telemetrySnapshot(
                            maximumConnections: maximumConnections
                        )
                    )
                case .diagnostics:
                    .diagnostics(diagnostics.snapshot())
                case let .setRoutingMode(mode):
                    try applyRoutingMode(mode)
                case .resetNetwork:
                    try handleResetNetwork()
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
            Self.runtimeLogger.info(
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
            SCDynamicStoreSetNotificationKeys(uplinkStore, nil,
                ["State:/Network/Interface/en[0-9]+/(Link|IPv4|IPv6)"] as CFArray)
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

    /// Both notification sources run on pathMonitorQueue. A secondary link or
    /// duplicate DHCP notification must not destroy a healthy active transport.
    private func physicalPathDidChange(reason: String) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        var signature = "offline"
        if let interface = currentPhysicalUplink(),
           let store = SCDynamicStoreCreate(nil, "AetherRoute uplink identity" as CFString, nil, nil) {
            signature = "\(interface.name):\(interface.index)|"
                + physicalAddresses(store: store, interface: interface).sorted().joined(separator: ",")
        }
        let previous = lastPathSignature
        lastPathSignature = signature
        guard let previous, previous != signature else { return }
        Self.runtimeLogger.info("stage=physicalUplinkChanged scheduling recovery")
        recovery.trigger(reason: reason, supersedes: true)
    }

    private func physicalAddresses(store: SCDynamicStore, interface: NWInterface) -> [String] {
        ["IPv4", "IPv6"].flatMap { family -> [String] in
            guard let state = SCDynamicStoreCopyValue(store,
                "State:/Network/Interface/\(interface.name)/\(family)" as CFString) as? [String: Any],
                  let addresses = state["Addresses"] as? [String] else { return [] }
            return addresses.filter { address in
                !address.hasPrefix("169.254.") && !address.lowercased().hasPrefix("fe80:")
                    && address != "0.0.0.0" && address != "::"
            }
        }
    }

    /// Path preference is supplied by Network.framework. Link state and
    /// assigned addresses come from SystemConfiguration, not the tunnel's
    /// satisfied default route or a sticky core interface cache.
    private func currentPhysicalUplink() -> NWInterface? {
        guard let store = SCDynamicStoreCreate(nil, "AetherRoute uplink" as CFString, nil, nil)
        else { return nil }
        let candidates = uplinkLock.withLock { physicalInterfaces }
        return candidates.first { interface in
            guard [.wifi, .wiredEthernet, .cellular].contains(interface.type),
                  let link = SCDynamicStoreCopyValue(store,
                    "State:/Network/Interface/\(interface.name)/Link" as CFString) as? [String: Any],
                  link["Active"] as? Bool == true else { return false }
            return !physicalAddresses(store: store, interface: interface).isEmpty
        }
    }

    private func performNetworkRecovery(reason: String, attempt: Int) {
        guard !uplinkLock.withLock({ providerStopping }) else { return }
        guard let interface = currentPhysicalUplink() else {
            resetSucceeded = false
            Self.runtimeLogger.info("stage=networkRecovery waitingForPhysicalUplink attempt=\(attempt, privacy: .public)")
            return
        }
        let index = UInt32(interface.index)
        // Once an interface was reset, retry the probe without destroying the
        // connections/DNS transports that are only just becoming usable.
        guard lastResetInterface != index || !resetSucceeded else { return }
        resetSucceeded = false
        Self.runtimeLogger.info(
            "stage=networkRecovery begin reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public) interface=\(interface.name, privacy: .public) index=\(index, privacy: .public)"
        )
        do {
            try core.resetNetworkState(interfaceIndex: index)
            lastResetInterface = index
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
        if NetworkRecoveryHealthPolicy.hasReceivedTraffic(
            since: recoveryDownloadBaseline,
            total: try? core.telemetrySnapshot(maximumConnections: 0).downloadTotal
        ) { return true }
        let healthy = NetworkRecoveryHealthPolicy.isReachable { url in
            let state = try core.testActiveProxyLatency(
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
        try core.setRoutingMode(mode)
        uplinkLock.withLock { recoveryRoutingMode = mode }
        return .routingMode(mode)
    }

    private func handleResetNetwork() throws -> ProxySelectionProviderResponse {
        Self.runtimeLogger.info("stage=appMessage resetNetwork requested")
        // The host asks for this on wake, and `NEProvider.wake()` is not
        // guaranteed to arrive — on a live host it never did across an entire
        // session. Route it through the coordinator so the app's single request
        // still gets the full converging retry loop instead of one attempt.
        recovery.trigger(reason: "appMessage")
        return .networkReset
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
        ipv4.excludedRoutes = plan.ipv4.excludedRoutes.map {
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
            ipv6.excludedRoutes = plannedIPv6.excludedRoutes.map {
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
            core.stop {}
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

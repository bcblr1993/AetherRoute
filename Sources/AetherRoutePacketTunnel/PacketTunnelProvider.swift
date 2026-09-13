import AetherRouteKit
import Network
@preconcurrency import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let runtimeLogger = AppLog.logger(category: AppLog.Category.tunnelRuntime)
    /// Short enough that ten attempts still fit inside the recovery window,
    /// long enough that a link which has just come up is not failed early.
    private static let healthProbeTimeoutMilliseconds: UInt32 = 3_000
    /// Upper bound on how long one attempt waits for macOS to reinstall the
    /// tunnel's settings before moving on to the health check.
    private static let reassertWaitSeconds: TimeInterval = 5

    private lazy var core: any CoreBridge = RustCoreBridge(packetFlow: packetFlow)
    private let diagnostics = ProviderDiagnosticAccumulator()
    private let providerMessageQueue = DispatchQueue(
        label: "com.aetherroute.packet-provider.messages",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    /// The plan, not the built settings object. A reassert has to hand the
    /// framework a freshly constructed `NEPacketTunnelNetworkSettings`;
    /// resubmitting the same instance is not a reliable way to make macOS
    /// reinstall routes and DNS.
    private var lastAppliedPlan: PacketTunnelNetworkSettingsPlan?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(
        label: "com.aetherroute.packet-provider.path",
        qos: .utility
    )
    private var lastPathSignature: String?
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
            observer: { event in Self.logRecovery(event) }
        )
    }

    override func startTunnel(
        options: [String: NSObject]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
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
                    self.core.stop()
                    completion.call(coreError)
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
                        self.core.stop()
                    } else {
                        Self.runtimeLogger.info("stage=installNetworkSettings success")
                        self.lastAppliedPlan = settingsPlan
                        self.startPathMonitoring()
                    }
                    completion.call(settingsError)
                }
            }
            Self.runtimeLogger.info("stage=startCore submitted")
        } catch {
            Self.runtimeLogger.error(
                "stage=startTunnel failed error=\(String(reflecting: error), privacy: .public)"
            )
            diagnostics.record(.startupFailure)
            core.stop()
            completion.call(error)
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
        recovery.cancel(reason: "stopTunnel")
        core.stop()
        Self.runtimeLogger.info("stage=stopTunnel complete")
        completionHandler()
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
        providerMessageQueue.async { [self] in
            let response: ProxySelectionProviderResponse
            do {
                let request = try ProxySelectionProviderMessageCodec
                    .decodeRequest(messageData)
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
            // React to the set of available interfaces changing, not only to a
            // status transition. With the tunnel holding the default route the
            // status is effectively pinned to `.satisfied`, so interface
            // identity is the only signal left that the uplink moved.
            //
            // Only physical uplinks count. Reinstalling the tunnel's settings
            // tears its own utun down and brings it back, and a signature that
            // included virtual interfaces therefore changed as a direct result
            // of recovery — measured on a VM, one genuine recovery triggered
            // three more rounds of resets and route reinstalls off its own echo.
            let signature = path.availableInterfaces
                .filter { interface in
                    switch interface.type {
                    case .wifi, .wiredEthernet, .cellular: true
                    default: false
                    }
                }
                .map { "\($0.name):\($0.index)" }
                .joined(separator: ",")
                + "|\(path.status)"
            let previous = self.lastPathSignature
            self.lastPathSignature = signature
            guard let previous, previous != signature else { return }
            Self.runtimeLogger.info("stage=pathChanged scheduling recovery")
            self.recovery.trigger(reason: "pathChanged")
        }
        monitor.start(queue: pathMonitorQueue)
    }

    private func stopPathMonitoring() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    private func performNetworkRecovery(reason: String, attempt: Int) {
        Self.runtimeLogger.info(
            "stage=networkRecovery begin reason=\(reason, privacy: .public) attempt=\(attempt, privacy: .public)"
        )
        do {
            try core.resetNetworkState()
            Self.runtimeLogger.info("stage=networkRecovery coreReset success")
        } catch {
            Self.runtimeLogger.error(
                "stage=networkRecovery coreReset failed reason=\(reason, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
        }
        // Wait for the reinstall before returning, so the coordinator's health
        // check measures the settings this attempt installed rather than
        // racing them. Bounded, because a reassert that never calls back must
        // not stall the remaining attempts. This runs on the coordinator's own
        // queue; the framework delivers the completion on another one.
        let installed = DispatchSemaphore(value: 0)
        reassertNetworkSettings(reason: reason) { installed.signal() }
        if installed.wait(timeout: .now() + Self.reassertWaitSeconds) == .timedOut {
            Self.runtimeLogger.error(
                "stage=reassertNetworkSettings timedOut reason=\(reason, privacy: .public)"
            )
        }
    }

    /// Probes the currently selected route end to end.
    ///
    /// The provider's own sockets bypass the tunnel, so it cannot test the
    /// tunnel by making a request itself. Asking the core to URL-test the live
    /// route exercises the real outbound path — interface binding, DNS and the
    /// proxy connection — which is exactly the state a sleep invalidates.
    private func dataPathIsHealthy() -> Bool {
        do {
            let state = try core.testActiveProxyLatency(
                group: ProxyConnectionReadinessPolicy.globalGroupName,
                url: ProxyConnectionReadinessPolicy
                    .requiredExternalProbeURLString,
                timeoutMilliseconds: Self.healthProbeTimeoutMilliseconds
            )
            let healthy = state.results.contains { $0.delayMilliseconds != nil }
            Self.runtimeLogger.info(
                "stage=recoveryHealthProbe healthy=\(healthy, privacy: .public)"
            )
            return healthy
        } catch {
            Self.runtimeLogger.info(
                "stage=recoveryHealthProbe unavailable error=\(String(reflecting: error), privacy: .public)"
            )
            return false
        }
    }

    private func reassertNetworkSettings(
        reason: String,
        completion: @escaping @Sendable () -> Void = {}
    ) {
        guard let plan = lastAppliedPlan else {
            completion()
            return
        }
        Self.runtimeLogger.info("stage=reassertNetworkSettings begin reason=\(reason, privacy: .public)")
        // Clear first, then install a freshly built object. macOS treats a
        // repeat submission of unchanged settings as a no-op, so the previous
        // "resubmit the cached instance" reassert could leave stale routes and
        // DNS in place. `reasserting` tells the framework the tunnel is being
        // re-established while this happens.
        reasserting = true
        setTunnelNetworkSettings(nil) { [weak self] clearError in
            guard let self else {
                completion()
                return
            }
            if let clearError {
                Self.runtimeLogger.error(
                    "stage=reassertNetworkSettings clearFailed reason=\(reason, privacy: .public) error=\(String(reflecting: clearError), privacy: .public)"
                )
            }
            self.setTunnelNetworkSettings(self.makeNetworkSettings(plan)) { error in
                if let error {
                    Self.runtimeLogger.error(
                        "stage=reassertNetworkSettings failed reason=\(reason, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
                    )
                } else {
                    Self.runtimeLogger.info(
                        "stage=reassertNetworkSettings success reason=\(reason, privacy: .public)"
                    )
                }
                self.reasserting = false
                completion()
            }
        }
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
        case .unavailable:
            .unavailable
        case .rejected, .selectionNotApplied:
            .rejected
        case .busy, .responseTooLarge, .invalidSnapshot, .invalidLatency:
            .responseTooLarge
        case .internalFailure:
            .internalFailure
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

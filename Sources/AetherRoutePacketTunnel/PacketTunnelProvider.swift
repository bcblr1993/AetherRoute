import AetherRouteKit
@preconcurrency import NetworkExtension
import OSLog

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
    private static let runtimeLogger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "packet-runtime"
    )

    private lazy var core: any CoreBridge = RustCoreBridge(packetFlow: packetFlow)
    private let diagnostics = ProviderDiagnosticAccumulator()
    private let providerMessageQueue = DispatchQueue(
        label: "com.aetherroute.packet-provider.messages",
        qos: .userInitiated
    )

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
            let configuration = try TunnelConfiguration(
                mode: routingMode,
                localProxy: localProxy
            ).validated()
            Self.runtimeLogger.info(
                "stage=decodeProviderConfiguration success routing=\(routingMode.rawValue, privacy: .public) localProxyEnabled=\(localProxy.isEnabled, privacy: .public)"
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
                self.setTunnelNetworkSettings(settings) { settingsError in
                    if let settingsError {
                        Self.runtimeLogger.error(
                            "stage=installNetworkSettings failed error=\(String(reflecting: settingsError), privacy: .public)"
                        )
                        self.diagnostics.record(.networkSettingsFailure)
                        self.core.stop()
                    } else {
                        Self.runtimeLogger.info("stage=installNetworkSettings success")
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
        core.stop()
        Self.runtimeLogger.info("stage=stopTunnel complete")
        completionHandler()
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
                case let .telemetry(maximumConnections):
                    .telemetry(
                        try core.telemetrySnapshot(
                            maximumConnections: maximumConnections
                        )
                    )
                case .diagnostics:
                    .diagnostics(diagnostics.snapshot())
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

        let ipv6 = NEIPv6Settings(
            addresses: plan.ipv6.addresses,
            networkPrefixLengths: plan.ipv6.prefixLengths.map(NSNumber.init)
        )
        ipv6.includedRoutes = plan.ipv6.includedRoutes.map {
            NEIPv6Route(
                destinationAddress: $0.destinationAddress,
                networkPrefixLength: NSNumber(value: $0.prefixLength)
            )
        }
        ipv6.excludedRoutes = plan.ipv6.excludedRoutes.map {
            NEIPv6Route(
                destinationAddress: $0.destinationAddress,
                networkPrefixLength: NSNumber(value: $0.prefixLength)
            )
        }
        settings.ipv6Settings = ipv6

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

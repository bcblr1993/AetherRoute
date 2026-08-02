import AetherRouteKit
@preconcurrency import NetworkExtension

final class PacketTunnelProvider: NEPacketTunnelProvider, @unchecked Sendable {
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
        let completion = TunnelStartCompletion(completionHandler)
        do {
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
            let bypassPlan = try BypassNetworkSettingsPlan(
                policy: BypassPolicyStore.applicationGroup().load()
            )
            try core.start(configuration: configuration) { [weak self] coreError in
                guard let self else {
                    completion.call(PacketTunnelError.coreUnavailable)
                    return
                }
                if let coreError {
                    self.diagnostics.record(.startupFailure)
                    self.core.stop()
                    completion.call(coreError)
                    return
                }

                let settings = self.makeNetworkSettings(
                    configuration,
                    bypassPlan: bypassPlan
                )
                self.setTunnelNetworkSettings(settings) { settingsError in
                    if settingsError != nil {
                        self.diagnostics.record(.networkSettingsFailure)
                        self.core.stop()
                    }
                    completion.call(settingsError)
                }
            }
        } catch {
            diagnostics.record(.startupFailure)
            core.stop()
            completion.call(error)
        }
    }

    override func stopTunnel(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        core.stop()
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
        _ configuration: TunnelConfiguration,
        bypassPlan: BypassNetworkSettingsPlan
    ) -> NEPacketTunnelNetworkSettings {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "127.0.0.1")
        settings.mtu = NSNumber(value: configuration.mtu)

        let ipv4 = NEIPv4Settings(
            addresses: [configuration.ipv4Address],
            subnetMasks: [configuration.ipv4SubnetMask]
        )
        ipv4.includedRoutes = [.default()]
        let customIPv4Routes = bypassPlan.ipv4Routes.map {
            NEIPv4Route(
                destinationAddress: $0.destinationAddress,
                subnetMask: $0.subnetMask
            )
        }
        ipv4.excludedRoutes = Self.uniqueIPv4Routes(
            (configuration.excludeLocalNetworks ? Self.localIPv4Routes : [])
                + customIPv4Routes
        )
        settings.ipv4Settings = ipv4

        let ipv6 = NEIPv6Settings(
            addresses: [configuration.ipv6Address],
            networkPrefixLengths: [NSNumber(value: configuration.ipv6PrefixLength)]
        )
        ipv6.includedRoutes = [.default()]
        let customIPv6Routes = bypassPlan.ipv6Routes.map {
            NEIPv6Route(
                destinationAddress: $0.destinationAddress,
                networkPrefixLength: NSNumber(value: $0.prefixLength)
            )
        }
        ipv6.excludedRoutes = Self.uniqueIPv6Routes(
            (configuration.excludeLocalNetworks ? Self.localIPv6Routes : [])
                + customIPv6Routes
        )
        settings.ipv6Settings = ipv6

        let dns = NEDNSSettings(servers: configuration.dnsServers)
        dns.matchDomains = [""]
        settings.dnsSettings = dns

        return settings
    }

    private static var localIPv4Routes: [NEIPv4Route] {
        [
            .init(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
            .init(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
            .init(destinationAddress: "169.254.0.0", subnetMask: "255.255.0.0"),
            .init(destinationAddress: "172.16.0.0", subnetMask: "255.240.0.0"),
            .init(destinationAddress: "192.168.0.0", subnetMask: "255.255.0.0")
        ]
    }

    private static var localIPv6Routes: [NEIPv6Route] {
        [
            .init(destinationAddress: "::1", networkPrefixLength: 128),
            .init(destinationAddress: "fc00::", networkPrefixLength: 7),
            .init(destinationAddress: "fe80::", networkPrefixLength: 10)
        ]
    }

    private static func uniqueIPv4Routes(
        _ routes: [NEIPv4Route]
    ) -> [NEIPv4Route] {
        var seen = Set<String>()
        return routes.filter {
            seen.insert(
                "\($0.destinationAddress)/\($0.destinationSubnetMask)"
            ).inserted
        }
    }

    private static func uniqueIPv6Routes(
        _ routes: [NEIPv6Route]
    ) -> [NEIPv6Route] {
        var seen = Set<String>()
        return routes.filter {
            seen.insert(
                "\($0.destinationAddress)/\($0.destinationNetworkPrefixLength)"
            ).inserted
        }
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

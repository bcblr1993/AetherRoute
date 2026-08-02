import AetherRouteFlowCoreBridge
import AetherRouteKit
import AetherRouteTransparentProxySupport
import Foundation
import Network
@preconcurrency import NetworkExtension

/// Native direct-flow provider embedded beside the Packet Tunnel extension.
/// Compile/link, synthetic lifecycle, and loopback flow gates exercise this
/// provider; organization-signed real NetworkExtension lifecycle tests remain
/// required before production promotion.
final class TransparentProxyProvider: NETransparentProxyProvider,
    @unchecked Sendable
{
    private let diagnostics: ProviderDiagnosticAccumulator
    private let runtimeController: TransparentProxyProviderLifecycleController
    private let providerMessageQueue = DispatchQueue(
        label: "com.example.aetherroute.transparent-provider.messages",
        qos: .userInitiated
    )

    override init() {
        let identityGuard = TransparentProxySelfIdentityGuard()
        let diagnostics = ProviderDiagnosticAccumulator()
        self.diagnostics = diagnostics
        runtimeController = TransparentProxyProviderLifecycleController(
            identityGuard: identityGuard
        ) {
            let input = try TransparentProxyRuntimeInputLoader
                .loadApplicationGroup()
            let engine = try FlowCoreEngine(
                profile: input.profile,
                runtimeDirectory: input.runtimeDirectory
            )
            let profileYAML = String(
                decoding: input.profile,
                as: UTF8.self
            )
            let savedSelections = try ProxySelectionStore.applicationGroup()
                .selections(forProfileYAML: profileYAML)
            for (group, member) in savedSelections.sorted(
                by: { $0.key < $1.key }
            ) {
                // A subscription can retain a group name while replacing its
                // members. Ignore only that stale per-group override; corrupt
                // encrypted storage still fails startup before reaching here.
                _ = try? engine.selectProxy(group: group, member: member)
            }
            return try TransparentProxyFlowRuntime(
                engine: engine,
                identityGuard: identityGuard,
                failureObserver: { _ in
                    diagnostics.record(.flowAdmissionFailure)
                }
            )
        }
        super.init()
    }

    override func startProxy(
        options: [String: Any]? = nil,
        completionHandler: @escaping (Error?) -> Void
    ) {
        let completion = ProxyStartCompletion(completionHandler)
        let bypassPlan: BypassNetworkSettingsPlan
        do {
            bypassPlan = try BypassNetworkSettingsPlan(
                policy: BypassPolicyStore.applicationGroup().load()
            )
        } catch {
            diagnostics.record(.startupFailure)
            completion.call(error)
            return
        }
        runtimeController.start(
            installNetworkSettings: { [weak self] installed in
                guard let self else {
                    installed(false)
                    return
                }
                let once = ProxySettingsCompletion(installed)
                let settings: NETransparentProxyNetworkSettings
                do {
                    settings = try Self.makeNetworkSettings(
                        bypassPlan: bypassPlan
                    )
                } catch {
                    once.call(false)
                    return
                }
                setTunnelNetworkSettings(settings) { error in
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
                completion.call(error)
            }
        )
    }

    override func stopProxy(
        with reason: NEProviderStopReason,
        completionHandler: @escaping () -> Void
    ) {
        let completion = ProxyStopCompletion(completionHandler)
        runtimeController.stop { [weak self] in
            guard let self else {
                completion.call()
                return
            }
            // Explicitly clear any settings that may have won a concurrent
            // start/stop race. Signed provider tests must still prove the OS
            // teardown callback semantics before production promotion.
            setTunnelNetworkSettings(nil) { _ in
                completion.call()
            }
        }
    }

    override func handleNewFlow(_ flow: NEAppProxyFlow) -> Bool {
        runtimeController.withFlowAdmission { [self] in
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
        providerMessageQueue.async { [runtimeController, diagnostics] in
            let response: ProxySelectionProviderResponse
            do {
                let request = try ProxySelectionProviderMessageCodec
                    .decodeRequest(messageData)
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
                case let .telemetry(maximumConnections):
                    .telemetry(
                        try runtimeController.telemetrySnapshot(
                            maximumConnections: maximumConnections
                        )
                    )
                case .diagnostics:
                    .diagnostics(diagnostics.snapshot())
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

    private func handleAdmittedFlow(_ flow: NEAppProxyFlow) -> Bool {
        switch runtimeController.identityDisposition(for: flow) {
        case .bypass:
            // This is the only false return in the provider: code-identity-
            // verified egress from this extension must escape recursion.
            return false
        case .reject:
            return failClosed(flow)
        case .proxy:
            guard let tcpFlow = flow as? NEAppProxyTCPFlow else {
                return failClosed(flow)
            }
            return claimTCP(tcpFlow)
        }
    }

    private func claimTCP(_ flow: NEAppProxyTCPFlow) -> Bool {
        do {
            let destination = try NetworkExtensionFlowLifecycle
                .tcpDestination(for: flow)
            let components = try NetworkExtensionTCPFlowComponents(flow: flow)
            guard runtimeController.claimTCP(
                components: components.ingress,
                // NEAppProxyTCPFlow does not expose the original local socket
                // endpoint. Source-IP/source-port rules are intentionally
                // outside this first honest transparent mode.
                source: nil,
                destination: destination
            ) else {
                return failClosed(flow)
            }
            return true
        } catch {
            return failClosed(flow)
        }
    }

    private func claimUDP(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        do {
            // The first target is validated even though subsequent datagrams
            // carry their own endpoint. This prevents malformed initial flow
            // metadata from reaching the data plane.
            _ = try NetworkFlowEndpointCodec.decode(
                initialRemoteEndpoint,
                transport: .udp
            )
            let localSource = try NetworkExtensionFlowLifecycle
                .udpLocalSource(for: flow)
            let components = try NetworkExtensionUDPFlowComponents(flow: flow)
            guard runtimeController.claimUDP(
                components: components.ingress,
                localSource: localSource
            ) else {
                return failClosed(flow)
            }
            return true
        } catch {
            return failClosed(flow)
        }
    }

    private func failClosed(_ flow: NEAppProxyFlow) -> Bool {
        diagnostics.record(.flowAdmissionFailure)
        guard runtimeController.claimAndCloseRawFlow(flow) else {
            return NetworkExtensionStoppedProviderFlow
                .claimAndCloseSynchronously(flow)
        }
        return true
    }

    private static func makeNetworkSettings(
        bypassPlan: BypassNetworkSettingsPlan
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
}

// Swift 6 exposes UDP delivery through this typed macOS 15 protocol.
@available(macOS 15.0, *)
extension TransparentProxyProvider: NEAppProxyUDPFlowHandling {
    func handleNewUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteFlowEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        runtimeController.withFlowAdmission { [self] in
            handleAdmittedUDPFlow(
                flow,
                initialRemoteEndpoint: remoteEndpoint
            )
        } ?? NetworkExtensionStoppedProviderFlow
            .claimAndCloseSynchronously(flow)
    }

    private func handleAdmittedUDPFlow(
        _ flow: NEAppProxyUDPFlow,
        initialRemoteEndpoint remoteEndpoint: Network.NWEndpoint
    ) -> Bool {
        switch runtimeController.identityDisposition(for: flow) {
        case .bypass:
            return false
        case .reject:
            return failClosed(flow)
        case .proxy:
            return claimUDP(flow, initialRemoteEndpoint: remoteEndpoint)
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

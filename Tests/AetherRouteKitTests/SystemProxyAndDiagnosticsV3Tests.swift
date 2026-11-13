import Foundation
import Testing
@testable import AetherRouteKit

@Suite(.serialized)
struct SystemProxyAndDiagnosticsV3Tests {

    // MARK: - P1-3: LocalProxySettings & SystemProxyConfigurator

    @Test
    func localProxySettingsDefaultsAndLegacyDecoding() throws {
        let defaults = LocalProxySettings()
        #expect(!defaults.setAsSystemProxy)
        #expect(defaults.systemProxyBypassDomains == LocalProxySettings.defaultSystemProxyBypassDomains)
        #expect(defaults.systemProxyBypassDomains.contains("localhost"))
        #expect(defaults.systemProxyBypassDomains.contains("127.0.0.1"))
        #expect(defaults.systemProxyBypassDomains.contains("*.local"))

        let legacyJSON = """
        {"version":1,"isEnabled":true,"httpPort":7890,"socksPort":7891,"allowLAN":false}
        """
        let decoded = try JSONDecoder().decode(LocalProxySettings.self, from: Data(legacyJSON.utf8))
        #expect(decoded.isEnabled)
        #expect(!decoded.setAsSystemProxy)
        #expect(decoded.systemProxyBypassDomains == LocalProxySettings.defaultSystemProxyBypassDomains)

        var invalid = LocalProxySettings(setAsSystemProxy: true, systemProxyBypassDomains: ["bad domain\n"])
        #expect(throws: LocalProxySettingsError.self) {
            try invalid.validated()
        }
        invalid.systemProxyBypassDomains = [" localhost ", "localhost", "10.0.0.0/8", ""]
        let normalized = try invalid.validated()
        #expect(normalized.systemProxyBypassDomains == ["localhost", "10.0.0.0/8"])
    }

    @Test
    func systemProxyConfiguratorSnapshotsAppliesAndRestoresCleanly() throws {
        final class MockExecutor: SystemProxyCommandExecuting, @unchecked Sendable {
            struct Call: Equatable {
                let executablePath: String
                let arguments: [String]
            }

            private let lock = NSLock()
            var calls: [Call] = []
            var servicesOutput = """
            An asterisk (*) denotes that a network service is disabled.
            Wi-Fi
            USB 10/100/1000 LAN
            *Bluetooth PAN
            """
            var webProxyByService: [String: (enabled: Bool, server: String, port: Int)] = [
                "Wi-Fi": (true, "10.0.0.2", 8080),
                "USB 10/100/1000 LAN": (false, "", 0),
            ]
            var secureProxyByService: [String: (enabled: Bool, server: String, port: Int)] = [
                "Wi-Fi": (true, "10.0.0.2", 8080),
                "USB 10/100/1000 LAN": (false, "", 0),
            ]
            var socksProxyByService: [String: (enabled: Bool, server: String, port: Int)] = [
                "Wi-Fi": (false, "", 0),
                "USB 10/100/1000 LAN": (false, "", 0),
            ]
            var bypassByService: [String: [String]] = [
                "Wi-Fi": ["corp.internal"],
                "USB 10/100/1000 LAN": [],
            ]

            func run(executablePath: String, arguments: [String]) throws -> SystemProxyCommandOutput {
                lock.lock()
                defer { lock.unlock() }
                calls.append(Call(executablePath: executablePath, arguments: arguments))
                guard let command = arguments.first else {
                    return SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "missing command")
                }
                let service = arguments.count > 1 ? arguments[1] : ""
                switch command {
                case "-listallnetworkservices":
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: servicesOutput, standardError: "")
                case "-getwebproxy":
                    let state = webProxyByService[service] ?? (false, "", 0)
                    return formatProxy(state)
                case "-getsecurewebproxy":
                    let state = secureProxyByService[service] ?? (false, "", 0)
                    return formatProxy(state)
                case "-getsocksfirewallproxy":
                    let state = socksProxyByService[service] ?? (false, "", 0)
                    return formatProxy(state)
                case "-getproxybypassdomains":
                    let domains = bypassByService[service] ?? []
                    if domains.isEmpty {
                        return SystemProxyCommandOutput(
                            exitCode: 0,
                            standardOutput: "There aren't any bypass domains set on \(service).\n",
                            standardError: ""
                        )
                    }
                    return SystemProxyCommandOutput(
                        exitCode: 0,
                        standardOutput: domains.joined(separator: "\n") + "\n",
                        standardError: ""
                    )
                case "-setwebproxy":
                    let current = webProxyByService[service] ?? (false, "", 0)
                    webProxyByService[service] = (current.enabled, arguments[2], Int(arguments[3]) ?? 0)
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                case "-setwebproxystate":
                    var current = webProxyByService[service] ?? (false, "", 0)
                    current.enabled = arguments[2].lowercased() == "on"
                    webProxyByService[service] = current
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                case "-setsecurewebproxy":
                    let current = secureProxyByService[service] ?? (false, "", 0)
                    secureProxyByService[service] = (current.enabled, arguments[2], Int(arguments[3]) ?? 0)
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                case "-setsecurewebproxystate":
                    var current = secureProxyByService[service] ?? (false, "", 0)
                    current.enabled = arguments[2].lowercased() == "on"
                    secureProxyByService[service] = current
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                case "-setsocksfirewallproxy":
                    let current = socksProxyByService[service] ?? (false, "", 0)
                    socksProxyByService[service] = (current.enabled, arguments[2], Int(arguments[3]) ?? 0)
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                case "-setsocksfirewallproxystate":
                    var current = socksProxyByService[service] ?? (false, "", 0)
                    current.enabled = arguments[2].lowercased() == "on"
                    socksProxyByService[service] = current
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                case "-setproxybypassdomains":
                    let domains = Array(arguments.dropFirst(2))
                    bypassByService[service] = domains == ["Empty"] ? [] : domains
                    return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
                default:
                    return SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "unknown command")
                }
            }

            private func formatProxy(_ state: (enabled: Bool, server: String, port: Int)) -> SystemProxyCommandOutput {
                let out = """
                Enabled: \(state.enabled ? "Yes" : "No")
                Server: \(state.server)
                Port: \(state.port)
                Authenticated Proxy Enabled: 0
                """
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: out, standardError: "")
            }
        }

        let suite = "SystemProxyConfiguratorTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let executor = MockExecutor()
        let configurator = SystemProxyConfigurator(executor: executor, defaults: defaults)
        let settings = LocalProxySettings(
            isEnabled: false,
            httpPort: 17890,
            socksPort: 17891,
            allowLAN: false,
            setAsSystemProxy: true,
            systemProxyBypassDomains: ["localhost", "127.0.0.1", "*.local"]
        )

        try configurator.apply(settings: settings)
        #expect(configurator.hasPendingBackup)
        #expect(executor.webProxyByService["Wi-Fi"]?.enabled == true)
        #expect(executor.webProxyByService["Wi-Fi"]?.server == "127.0.0.1")
        #expect(executor.webProxyByService["Wi-Fi"]?.port == 17890)
        #expect(executor.socksProxyByService["Wi-Fi"]?.port == 17891)
        #expect(executor.webProxyByService["USB 10/100/1000 LAN"]?.enabled == true)
        #expect(executor.bypassByService["Wi-Fi"] == ["localhost", "127.0.0.1", "*.local"])
        #expect(executor.webProxyByService["Bluetooth PAN"] == nil)

        // Simulate crash recovery using a fresh configurator reading persisted backup
        let recoveredConfigurator = SystemProxyConfigurator(executor: executor, defaults: defaults)
        #expect(recoveredConfigurator.hasPendingBackup)
        try recoveredConfigurator.restorePendingIfNeeded()
        #expect(!recoveredConfigurator.hasPendingBackup)
        #expect(executor.webProxyByService["Wi-Fi"]?.enabled == true)
        #expect(executor.webProxyByService["Wi-Fi"]?.server == "10.0.0.2")
        #expect(executor.webProxyByService["Wi-Fi"]?.port == 8080)
        #expect(executor.socksProxyByService["Wi-Fi"]?.enabled == false)
        #expect(executor.webProxyByService["USB 10/100/1000 LAN"]?.enabled == false)
        #expect(executor.bypassByService["Wi-Fi"] == ["corp.internal"])
        #expect(executor.bypassByService["USB 10/100/1000 LAN"] == [])
    }

    // MARK: - P1-4: NetworkAutomationAction & Control URL Schemes

    @Test
    func networkAutomationActionSupportsSwitchProfileAndSetEngineMode() throws {
        let profileID = UUID()
        let switchRule = NetworkAutomationRule(
            triggerKind: .wifiSSID,
            matchValue: "Office-WiFi",
            action: .switchProfile(profileID)
        )
        let engineRule = NetworkAutomationRule(
            triggerKind: .ethernet,
            matchValue: "",
            action: .setEngineMode(.tun)
        )
        let preferences = try NetworkAutomationPreferences(
            isEnabled: true,
            rules: [switchRule, engineRule]
        ).validated()

        let suite = "NetworkAutomationV3Tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkAutomationPreferenceStore(defaults: defaults)
        try store.save(preferences)
        let loaded = store.load()
        #expect(loaded == preferences)

        let wifiEnv = NetworkEnvironmentSnapshot(
            interfaceName: "en0",
            isEthernet: false,
            wifiSSID: "Office-WiFi",
            gatewayAddress: nil
        )
        #expect(loaded.matchedAction(for: wifiEnv) == .switchProfile(profileID))

        let ethEnv = NetworkEnvironmentSnapshot(
            interfaceName: "en7",
            isEthernet: true,
            wifiSSID: nil,
            gatewayAddress: nil
        )
        #expect(loaded.matchedAction(for: ethEnv) == .setEngineMode(.tun))
    }

    @Test
    func externalLinkParserSupportsControlURLsAndOptInGuard() throws {
        let connectURL = try #require(URL(string: "aetherroute://connect"))
        let disconnectURL = try #require(URL(string: "aetherroute://disconnect"))
        let modeURL = try #require(URL(string: "aetherroute://set-mode?mode=global"))
        let engineURL = try #require(URL(string: "aetherroute://set-mode?mode=tun"))
        let profileURL = try #require(URL(string: "aetherroute://switch-profile?name=Work%20Nodes"))
        let subURL = try #require(URL(string: "aetherroute://subscribe?url=https%3A%2F%2Fexample.com%2Fsub.yaml"))

        // Guarded when allowControlActions is false (default)
        #expect(throws: ExternalSubscriptionLinkError.controlActionsDisabled) {
            try ExternalSubscriptionLinkParser.parseAction(connectURL, allowControlActions: false)
        }
        // Subscription links remain allowed even when control URL actions are disabled
        let subAction = try ExternalSubscriptionLinkParser.parseAction(subURL, allowControlActions: false)
        if case let .importSubscription(req) = subAction {
            #expect(req.providerHost == "example.com")
        } else {
            Issue.record("Expected subscription import action")
        }

        // Allowed when opted-in
        #expect(try ExternalSubscriptionLinkParser.parseAction(connectURL, allowControlActions: true) == .control(.connect))
        #expect(try ExternalSubscriptionLinkParser.parseAction(disconnectURL, allowControlActions: true) == .control(.disconnect))
        #expect(try ExternalSubscriptionLinkParser.parseAction(modeURL, allowControlActions: true) == .control(.setRoutingMode(.global)))
        #expect(try ExternalSubscriptionLinkParser.parseAction(engineURL, allowControlActions: true) == .control(.setEngineMode(.tun)))
        #expect(try ExternalSubscriptionLinkParser.parseAction(profileURL, allowControlActions: true) == .control(.switchProfile(name: "Work Nodes", id: nil)))

        // Reject invalid parameters
        let badModeURL = try #require(URL(string: "aetherroute://set-mode?mode=invalid"))
        #expect(throws: ExternalSubscriptionLinkError.invalidParameters) {
            try ExternalSubscriptionLinkParser.parseAction(badModeURL, allowControlActions: true)
        }

        let suite = "ControlURLPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ControlURLSchemePreferenceStore(defaults: defaults)
        #expect(!store.load().allowControlURLScheme)
        try store.save(ControlURLSchemePreferences(allowControlURLScheme: true))
        #expect(store.load().allowControlURLScheme)
    }

    // MARK: - P1-1: Route & DNS Simulator + Provider IPC

    @Test
    func providerMessageCodecRoundTripsTraceRoute() throws {
        let request = RouteTraceRequest(
            host: "api.openai.com",
            ip: "104.18.7.192",
            port: 443,
            network: .tcp,
            processPath: "/Applications/Xcode.app/Contents/MacOS/Xcode"
        )
        let encodedRequest = try ProxySelectionProviderMessageCodec.encode(request: .traceRoute(request))
        let decodedRequest = try ProxySelectionProviderMessageCodec.decodeRequest(encodedRequest)
        #expect(decodedRequest == .traceRoute(request))
        #expect(ProviderMessageClass(decodedRequest) == .control)

        let result = RouteTraceResult(
            routingMode: .rule,
            matchedRuleKind: "DOMAIN-SUFFIX",
            matchedRuleCriteria: "openai.com",
            matchedRuleOrder: 3,
            targetOutbound: "PROXY",
            outboundChain: ["PROXY", "US-Auto", "US-01"],
            resolvedHostAlias: nil,
            dnsAddresses: ["198.18.0.12"],
            dnsLatencyMilliseconds: 4,
            isFakeIP: true,
            source: .liveProvider
        )
        let encodedResponse = try ProxySelectionProviderMessageCodec.encode(response: .traceRoute(result))
        let decodedResponse = try ProxySelectionProviderMessageCodec.decodeResponse(encodedResponse, for: .traceRoute(request))
        #expect(decodedResponse == .traceRoute(result))
    }

    @Test
    func routeSimulationInspectorEvaluatesAllV3RuleTypesAndOutboundChain() throws {
        let profileYAML = """
        proxies:
          - name: HK-01
            type: ss
            server: 1.1.1.1
            port: 443
            cipher: aes-128-gcm
            password: pass
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - Auto
              - HK-01
          - name: Auto
            type: url-test
            proxies:
              - HK-01
        rules:
          - PROCESS-PATH,/usr/bin/curl,DIRECT
          - AND,((DOMAIN-SUFFIX,googlevideo.com),(NETWORK,udp)),REJECT
          - DOMAIN-REGEX,^api-[0-9]+\\.example\\.com$,PROXY
          - DOMAIN-WILDCARD,*.dev.internal,DIRECT
          - IP-ASN,13335,PROXY,no-resolve
          - NETWORK,udp,DIRECT
          - MATCH,PROXY
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: profileYAML)
        let selections = ["PROXY": "Auto", "Auto": "HK-01"]

        // 1. PROCESS-PATH match
        let curlResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "example.org", port: 443, network: .tcp, processPath: "/usr/bin/curl"),
            routingMode: .rule,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: selections,
            source: .liveProvider
        )
        #expect(curlResult.matchedRuleKind == "PROCESS-PATH")
        #expect(curlResult.targetOutbound == "DIRECT")

        // 2. AND composite match (DOMAIN-SUFFIX + NETWORK udp)
        let quicResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "r1.googlevideo.com", port: 443, network: .udp),
            routingMode: .rule,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: selections,
            source: .liveProvider
        )
        #expect(quicResult.matchedRuleKind == "AND")
        #expect(quicResult.targetOutbound == "REJECT")

        // 3. DOMAIN-REGEX + Outbound Chain resolution
        let regexResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "api-42.example.com", port: 443, network: .tcp),
            routingMode: .rule,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: selections,
            source: .liveProvider
        )
        #expect(regexResult.matchedRuleKind == "DOMAIN-REGEX")
        #expect(regexResult.targetOutbound == "PROXY")
        #expect(regexResult.outboundChain == ["PROXY", "Auto", "HK-01"])

        // 4. DOMAIN-WILDCARD match
        let wildcardResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "app.dev.internal", port: 80, network: .tcp),
            routingMode: .rule,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: selections,
            source: .staticFallback
        )
        #expect(wildcardResult.matchedRuleKind == "DOMAIN-WILDCARD")
        #expect(wildcardResult.targetOutbound == "DIRECT")

        // 5. IP-ASN match via injectable ASN resolver
        let asnResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "1.1.1.1", ip: "1.1.1.1", port: 443, network: .tcp),
            routingMode: .rule,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: selections,
            asnLookup: { ip in ip == "1.1.1.1" ? "13335" : nil },
            source: .liveProvider
        )
        #expect(asnResult.matchedRuleKind == "IP-ASN")
        #expect(asnResult.targetOutbound == "PROXY")
        #expect(asnResult.outboundChain == ["PROXY", "Auto", "HK-01"])

        // 6. NETWORK udp match
        let udpResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "stun.l.google.com", port: 3478, network: .udp),
            routingMode: .rule,
            profileYAML: profileYAML,
            summary: summary,
            proxySelections: selections,
            source: .staticFallback
        )
        #expect(udpResult.matchedRuleKind == "NETWORK")
        #expect(udpResult.targetOutbound == "DIRECT")
    }
}

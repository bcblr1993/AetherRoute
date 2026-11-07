#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-recovery-sub-gate.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

echo "==> [Gate] Testing recovery state-machine & third-party subscription compatibility..."

cat << 'EOF' > "$TEMP_DIR/verifier.swift"
import Foundation

@main
struct RecoveryAndSubscriptionCompatVerifier {
    static func assertTrue(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() {
            fputs("FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func main() {
        // A healthy backup must keep its streams when the preferred node
        // recovers. Field logs showed a recovery closing 120 live sessions.
        // Manual node-switch preferences must not turn recovery into an outage.
        for closesOnManualSwitch in [true, false] {
            assertTrue(
                ProxyFailoverPolicy.closeRequest(
                    reason: .preferredRecovered,
                    group: "Proxy",
                    previousMember: "working-backup",
                    closesConnectionsOnSwitch: closesOnManualSwitch
                ) == nil,
                "Preferred-node recovery must preserve healthy connections regardless of manual-switch settings"
            )
            assertTrue(
                ProxyFailoverPolicy.closeRequest(
                    reason: .unresponsive,
                    group: "Proxy",
                    previousMember: "failed-node",
                    closesConnectionsOnSwitch: closesOnManualSwitch
                ) == .proxyChainMember("failed-node"),
                "A real failure must still reclaim only the failed node's connections"
            )
        }
        assertTrue(
            ProxySelectionHotSwitchPolicy.closeRequest(
                group: "Proxy",
                previousMember: "HK 01",
                newMember: "US 01",
                closesConnectionsOnSwitch: true
            ) == .proxyChainMember("HK 01"),
            "Hot-switch close must target the previous member instead of killing new connections on the whole group"
        )
        assertTrue(
            ProxySelectionHotSwitchPolicy.closeRequest(
                group: "Proxy",
                previousMember: "DIRECT",
                newMember: "US 01",
                closesConnectionsOnSwitch: true
            ) == .proxyChainMember("Proxy"),
            "Switching away from DIRECT inside a group must scope close to the group"
        )
        assertTrue(
            ProxySelectionHotSwitchPolicy.routingModeCloseRequest(
                previousMode: .rule,
                newMode: .global,
                closesConnectionsOnSwitch: true
            ) == .all,
            "Routing mode switch must close stale connections when closesConnectionsOnSwitch is enabled"
        )

        // 1. Recovery state-machine deadlock guards
        assertTrue(
            TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: true,
                providerPermitsStart: true,
                isAutomaticReconnect: true,
                hostIsRecovering: true
            ),
            "Automatic reconnect must be permitted while host is in .recovering and provider is inactive"
        )
        assertTrue(
            !TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: true,
                providerPermitsStart: false,
                isAutomaticReconnect: true,
                hostIsRecovering: true
            ),
            "Automatic reconnect must not start while provider is still active/disconnecting"
        )
        assertTrue(
            TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: true,
                providerPermitsStart: true
            ),
            "performAutomaticReconnect must proceed when host state is .recovering even though isEnabled is true"
        )
        assertTrue(
            !TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: false,
                providerPermitsStart: true
            ),
            "performAutomaticReconnect must abort when host is already connected or connecting"
        )
        assertTrue(
            !ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: true,
                hadEstablishedSession: false,
                attempt: 0
            ),
            "Initial startup failure before an established session must surface immediately instead of entering .recovering"
        )
        assertTrue(
            ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: true,
                hadEstablishedSession: true,
                attempt: 0
            ),
            "Unexpected termination after an established session must trigger auto-reconnect"
        )
        assertTrue(
            !ProviderTerminationPolicy.isUnexpectedTerminalState(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            ),
            "First-run configuration enablement (.invalid -> .disconnected) before provider becomes active must not be classified as unexpected termination"
        )
        assertTrue(
            ProviderTerminationPolicy.isUnexpectedTerminalState(
                currentIsTerminal: true,
                previousWasActive: true,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            ),
            "Provider returning to terminal state after entering .connecting must be classified as unexpected termination"
        )
        assertTrue(
            TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionRequestPending: true,
                connectionAttemptPending: false,
                disconnectionAttemptPending: false
            ),
            "Pre-activation terminal status during connection preparation must preserve .connecting state"
        )
        assertTrue(
            TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionRequestPending: false,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            ),
            "Pre-activation terminal status while awaiting provider .connecting must preserve .connecting state and watchdog"
        )
        assertTrue(
            !TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                connectionAttemptPending: true
            ),
            "Configuration change notification must not reload and replace NEVPNManager while a connection attempt is pending"
        )
        assertTrue(
            !TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                connectionRequestPending: true
            ),
            "Configuration change notification must not reload and replace NEVPNManager while a connection request is preparing"
        )

        // 1b. Menu bar real-time traffic polling schedule when windows are closed/backgrounded
        assertTrue(
            TelemetryCadence.resolve(
                realtimeSources: 0,
                backgroundSources: 0,
                isMenuBarTrafficEnabled: true,
                isTrafficStatisticsEnabled: false
            ) == .realtime,
            "Enabled menu bar traffic must keep 3s .realtime polling when all windows are closed"
        )
        assertTrue(
            TelemetryCadence.resolve(
                realtimeSources: 0,
                backgroundSources: 1,
                isMenuBarTrafficEnabled: true,
                isTrafficStatisticsEnabled: true
            ) == .realtime,
            "Enabled menu bar traffic must promote 10s .background window demand to 3s .realtime"
        )
        assertTrue(
            TelemetryCadence.resolve(
                realtimeSources: 0,
                backgroundSources: 0,
                isMenuBarTrafficEnabled: false,
                isTrafficStatisticsEnabled: true
            ) == .statistics,
            "Disabled menu bar traffic with statistics enabled must use .statistics cadence"
        )

        // 1c. NetworkRecoveryCoordinator: cancel during in-flight verify & appMessage wake coalescing
        final class Box<Value>: @unchecked Sendable {
            private let lock = NSLock()
            private var storage: Value
            init(_ initial: Value) { self.storage = initial }
            func withLock<R>(_ body: (inout Value) -> R) -> R {
                lock.lock()
                defer { lock.unlock() }
                return body(&storage)
            }
        }
        do {
            let verifyStarted = DispatchSemaphore(value: 0)
            let releaseVerify = DispatchSemaphore(value: 0)
            let events = Box<[NetworkRecoveryCoordinator.Event]>([])
            let coordinator = NetworkRecoveryCoordinator(
                delays: [0.01, 0.01],
                perform: { _, _ in },
                verify: {
                    verifyStarted.signal()
                    _ = releaseVerify.wait(timeout: .now() + 5)
                    return true
                },
                observer: { event in
                    events.withLock { $0.append(event) }
                }
            )
            coordinator.trigger(reason: "wake")
            assertTrue(verifyStarted.wait(timeout: .now() + 2) == .success, "verify() must start")
            coordinator.cancel(reason: "sleep")
            releaseVerify.signal()
            coordinator.waitForQuiescence()
            let recorded = events.withLock { $0 }
            assertTrue(
                recorded.contains { if case .cancelled(reason: "sleep") = $0 { return true }; return false },
                "Cancel during in-flight verify must emit .cancelled(reason: \"sleep\")"
            )
            assertTrue(
                !recorded.contains { if case .recovered = $0 { return true }; return false },
                "Cancelled in-flight verify must not emit stale .recovered"
            )
        }
        do {
            let starts = Box<Int>(0)
            let recovered = DispatchSemaphore(value: 0)
            let coordinator = NetworkRecoveryCoordinator(
                delays: [0.03, 60],
                debounce: 5,
                perform: { _, _ in },
                verify: { true },
                observer: { event in
                    if case .started = event { starts.withLock { $0 += 1 } }
                    if case .recovered(reason: "wake", attempt: 0) = event { recovered.signal() }
                }
            )
            coordinator.trigger(reason: "wake")
            coordinator.trigger(reason: "appMessage", supersedes: true)
            assertTrue(
                recovered.wait(timeout: .now() + 2) == .success,
                "appMessage must coalesce into active wake instead of superseding it"
            )
            coordinator.trigger(reason: "appMessage", supersedes: true)
            coordinator.waitForQuiescence()
            let totalStarts = starts.withLock { $0 }
            assertTrue(totalStarts == 1, "appMessage during/after wake must not restart recovery (starts=\(totalStarts))")
        }
        do {
            // Field logs showed NEProvider.wake() never arriving on wake; instead
            // SCDynamicStore fired physicalLinkChanged first, and 350ms later the
            // host app's systemDidWake handler sent appMessage (resetNetwork).
            // appMessage must coalesce into an in-flight or just-completed
            // physicalLinkChanged/pathChanged recovery run instead of aborting
            // its health probe and resetting all active connections a second time.
            let starts = Box<Int>(0)
            let recovered = DispatchSemaphore(value: 0)
            let coordinator = NetworkRecoveryCoordinator(
                delays: [0.03, 60],
                debounce: 5,
                perform: { _, _ in },
                verify: { true },
                observer: { event in
                    if case .started = event { starts.withLock { $0 += 1 } }
                    if case .recovered(reason: "physicalLinkChanged", attempt: 0) = event {
                        recovered.signal()
                    }
                }
            )
            coordinator.trigger(reason: "physicalLinkChanged", supersedes: true)
            coordinator.trigger(reason: "appMessage", supersedes: true)
            assertTrue(
                recovered.wait(timeout: .now() + 2) == .success,
                "appMessage must coalesce into active physicalLinkChanged instead of superseding it"
            )
            coordinator.trigger(reason: "appMessage", supersedes: true)
            coordinator.waitForQuiescence()
            let totalStarts = starts.withLock { $0 }
            assertTrue(
                totalStarts == 1,
                "appMessage during/within debounce of physicalLinkChanged must not restart recovery (starts=\(totalStarts))"
            )
        }

        // 1d. UplinkResetLedger: wake onto Wi-Fi, same Wi-Fi path, late USB Ethernet = 2 resets
        do {
            var ledger = UplinkResetLedger()
            func run(_ reason: String, _ index: UInt32, _ signature: String) -> Bool {
                ledger.runStarted(reason: reason)
                guard ledger.needsReset(interfaceIndex: index, signature: signature) else { return false }
                ledger.invalidate()
                ledger.resetCompleted(interfaceIndex: index, signature: signature)
                return true
            }
            _ = run("pathChanged", 36, "en11:36|10.8.5.253")
            let resets = [
                run("wake", 14, "en0:14|172.16.3.110"),
                run("pathChanged", 14, "en0:14|172.16.3.110"),
                run("pathChanged", 36, "en11:36|10.8.5.253"),
            ]
            assertTrue(resets == [true, false, true], "Path change onto the uplink the wake run just reset must not reset again (resets=\(resets))")
            assertTrue(run("wake", 36, "en11:36|10.8.5.253"), "Wake must reset even when the uplink is unchanged")
        }

        // 2. Domestic DIRECT recovery health probe ordering & uplink eligibility
        let directProbes = NetworkRecoveryHealthPolicy.probeURLs(forTargetGroup: "DIRECT")
        assertTrue(
            directProbes.first?.absoluteString == "https://www.apple.com/library/test/success.html",
            "DIRECT recovery probe must prioritize Apple's domestic-reachable endpoint first"
        )
        assertTrue(
            PhysicalUplinkDetector.isCandidateLinkEligible(
                explicitLinkActive: nil,
                hasRoutablePhysicalAddresses: true
            ),
            "Routable physical interface without SCDynamicStore Link dictionary must remain eligible"
        )
        assertTrue(
            !PhysicalUplinkDetector.isCandidateLinkEligible(
                explicitLinkActive: false,
                hasRoutablePhysicalAddresses: true
            ),
            "Explicitly inactive interface must be rejected"
        )

        // 3. Third-party Clash/Mihomo subscription normalization, DomesticRoutingOptimizer, & Inspector
        let rawSubscriptionYAML = """
        mixed-port: 7890
        allow-lan: false
        mode: rule
        log-level: info
        external-controller: 127.0.0.1:9090
        external-ui: ui
        external-ui-name: xd
        external-ui-url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          nameserver:
            - 223.5.5.5 # 阿里DNS
            - 119.29.29.29 # 腾讯DNS
          fallback:
            - 8.8.8.8 # Google DNS
          fake-ip-filter:
            - '*.lan' # 局域网
            - '+.msftconnecttest.com' # Windows 连通性
          nameserver-policy:
            '+.internal.corp': [223.5.5.5, 119.29.29.29]
            'geosite:cn': [223.5.5.5, 119.29.29.29]
        proxies:
          - name: "🇭🇰 香港 HY2-01"
            type: hysteria2
            server: 127.0.0.1
            port: "443"
            password: 12345678
            sni: hk.example.com
            alpn: h3
            obfs: ""
          - name: "🇭🇰 香港 VLESS-Reality"
            type: vless
            server: 127.0.0.1
            port: "443"
            uuid: 00000000-0000-0000-0000-000000000000
            tls: true
            servername: www.microsoft.com
            reality-opts:
              public-key: "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
              short-id: 12345678
          - name: "🇺🇸 美国 VMess-AEAD"
            type: vmess
            server: 127.0.0.1
            port: "8443"
            uuid: 00000000-0000-0000-0000-000000000000
            cipher: auto
          - name: "🇯🇵 日本 Trojan"
            type: trojan
            server: 127.0.0.1
            port: "443"
            password: 987654321
            sni: jp.example.com
            alpn: h2
          - name: "🇯🇵 日本 Trojan"
            type: trojan
            server: 127.0.0.1
            port: 444
            password: dup-password
            sni: jp2.example.com
          - name: "Legacy-SSR-Node"
            type: ssr
            server: 127.0.0.1
            port: 8388
            cipher: chacha20-ietf
            password: p
            obfs: plain
            protocol: origin
          - name: "Legacy-Snell-Node"
            type: snell
            server: 127.0.0.1
            port: 8389
            psk: p
            version: 4
            obfs-opts:
              mode: tls
              host: example.com
          - name: "Panel-Mieru-Node"
            type: mieru
            server: 127.0.0.1
            port: 8390
            username: u
            password: p
            transport: TCP
            multiplexing: MULTIPLEXING_HIGH
          - name: "Panel-Hy1-Node"
            type: hysteria
            server: 127.0.0.1
            port: 8391
            auth-str: hy1-secret
            up: 50
            down: 200
            sni: example.com
            skip-cert-verify: true
          - name: "Panel-VLESS-XHTTP"
            type: vless
            server: 127.0.0.1
            port: 8392
            uuid: 00000000-0000-0000-0000-000000000000
            tls: true
            servername: example.com
            skip-cert-verify: true
            network: xhttp
            xhttp-opts:
              path: /xhttp
              mode: packet-up
        proxy-groups:
          - name: "自动选择"
            type: url-test
            include-all: true
            filter: "香港|美国|日本"
            exclude-filter: "SSR|Snell"
          - name: "故障转移"
            type: fallback
            include-all-proxies: true
          - name: "节点选择"
            type: select
            proxies:
              - "自动选择"
              - "故障转移"
              - "🇭🇰 香港 HY2-01"
              - "Legacy-SSR-Node"
              - "NonExistent-Node"
              - DIRECT
        rules:
          - IN-TYPE,SOCKS/HTTP,节点选择
          - RULE-SET,missing-provider,节点选择
          - DOMAIN-SUFFIX,google.com,MissingGroup
          - DOMAIN-SUFFIX,github.com,节点选择 # GitHub
          - MATCH,节点选择
        """

        guard let rawData = rawSubscriptionYAML.data(using: .utf8) else {
            fatalError("Failed to encode rawSubscriptionYAML")
        }

        let normalizedResult: SubscriptionPayloadNormalization
        do {
            normalizedResult = try SubscriptionPayloadNormalizer.normalizeWithReport(rawData)
            try ProfileImportValidator.validate(data: normalizedResult.data)
        } catch {
            fputs("FAILED: SubscriptionPayloadNormalizer or ProfileImportValidator rejected third-party subscription: \(error)\n", stderr)
            exit(1)
        }

        guard let normalizedYAML = String(data: normalizedResult.data, encoding: .utf8) else {
            fatalError("Failed to decode normalizedYAML")
        }
        assertTrue(!normalizedYAML.contains("external-ui"), "external-ui directives must be stripped from subscription YAML")

        let optimizedYAML = DomesticRoutingOptimizer.optimizedProfile(for: normalizedYAML)
        assertTrue(!optimizedYAML.contains("# 阿里DNS"), "Inline comments in dns.nameserver must be stripped")
        assertTrue(!optimizedYAML.contains("''*.lan'"), "Inline comments in dns.fake-ip-filter must not corrupt quotes")
        assertTrue(optimizedYAML.contains("'+.internal.corp': ['223.5.5.5', '119.29.29.29']"), "Array nameserver-policy must keep every resolver in order")
        assertTrue(optimizedYAML.contains("'+.qq.com': 119.29.29.29"), "WeChat/QQ domains must be pinned to domestic resolver in nameserver-policy")
        assertTrue(optimizedYAML.contains("'+.weixin.com': 119.29.29.29"), "WeChat weixin.com domains must be pinned to domestic resolver in nameserver-policy")
        assertTrue(optimizedYAML.contains("'+.wechat.com': 119.29.29.29"), "WeChat wechat.com domains must be pinned to domestic resolver in nameserver-policy")
        assertTrue(optimizedYAML.contains("- DOMAIN-SUFFIX,servicewechat.com,DIRECT"), "WeChat servicewechat.com must bypass proxy at high priority")

        // Verify loopback protection rules precede custom AETHER-APP / PROCESS-NAME rules
        // and RFC 6761 +.localhost / +.local Fake-IP filters are injected.
        let appRule = CustomRule(
            kind: .application,
            value: "com.openai.chat;/Applications/ChatGPT.app",
            target: .proxy("节点选择")
        )
        let appRuleString = appRule.toClashRuleString()
        let optimizedWithAppRule = DomesticRoutingOptimizer.optimizedProfile(
            for: normalizedYAML,
            customRules: [appRule]
        )
        assertTrue(optimizedWithAppRule.contains("- '+.localhost'"), "Fake-IP filter must contain RFC 6761 '+.localhost'")
        assertTrue(optimizedWithAppRule.contains("- '+.local'"), "Fake-IP filter must contain mDNS '+.local'")
        guard let appRuleRange = optimizedWithAppRule.range(of: "- \(appRuleString)") else {
            fputs("FAILED: Custom application rule missing from optimizedYAML\n", stderr)
            exit(1)
        }
        for loopbackRule in [
            "- DOMAIN,localhost,DIRECT",
            "- DOMAIN-SUFFIX,localhost,DIRECT",
            "- IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "- IP-CIDR6,::1/128,DIRECT,no-resolve",
        ] {
            guard let loopbackRange = optimizedWithAppRule.range(of: loopbackRule) else {
                fputs("FAILED: Missing mandatory loopback rule \(loopbackRule)\n", stderr)
                exit(1)
            }
            assertTrue(
                loopbackRange.lowerBound < appRuleRange.lowerBound,
                "Loopback rule \(loopbackRule) must precede custom application rule \(appRuleString)"
            )
        }

        // Verify RouteMatchEngine always assesses loopback & RFC 6761 localhost as DIRECT
        let trapRules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "DOMAIN-SUFFIX", criteria: "localhost", target: "节点选择"),
            RuleConfigurationSummary(id: 1, order: 2, kind: "IP-CIDR", criteria: "127.0.0.0/8", target: "节点选择", noResolve: true),
            RuleConfigurationSummary(id: 2, order: 3, kind: "MATCH", criteria: nil, target: "节点选择"),
        ]
        for loopbackTarget in ["127.0.0.1:8080", "[::1]:5173", "localhost:3000", "https://api.localhost:8443/v1"] {
            assertTrue(
                RouteMatchEngine.evaluate(destination: loopbackTarget, against: trapRules)?.target == "DIRECT",
                "Loopback target \(loopbackTarget) must evaluate as DIRECT even when profile rules point to proxy"
            )
        }

        // Verify large subscription live-reload payload compression (>512 KiB raw YAML)
        var bulkRules: [String] = []
        bulkRules.reserveCapacity(10_000)
        for idx in 1...10_000 {
            bulkRules.append("DOMAIN-SUFFIX,bulk-rule-\(idx).example.net,节点选择")
        }
        let largeOptimizedYAML = DomesticRoutingOptimizer.optimizedProfile(
            for: normalizedYAML,
            remoteRules: bulkRules
        )
        assertTrue(
            largeOptimizedYAML.utf8.count > ReloadProfilePayloadCodec.maximumPayloadBytes,
            "Large optimized YAML must exceed 512 KiB raw payload threshold"
        )
        do {
            let reloadPayload = ReloadProfilePayload(
                profileYAML: largeOptimizedYAML,
                routingMode: .rule,
                bypassPolicy: .empty,
                dnsPolicy: .inherited,
                proxySelections: ["节点选择": "自动选择"]
            )
            let encodedReload = try ReloadProfilePayloadCodec.encode(reloadPayload)
            assertTrue(
                encodedReload.count <= ReloadProfilePayloadCodec.maximumPayloadBytes,
                "Compressed ReloadProfilePayload must fit within 512 KiB IPC limit"
            )
            let wireMsg = try ProxySelectionProviderMessageCodec.encode(request: .reloadProfile(encodedReload))
            guard case let .reloadProfile(decodedData) = try ProxySelectionProviderMessageCodec.decodeRequest(wireMsg) else {
                fputs("FAILED: Expected .reloadProfile wire request\n", stderr)
                exit(1)
            }
            let decodedReload = try ReloadProfilePayloadCodec.decode(decodedData)
            assertTrue(decodedReload == reloadPayload, "Decoded ReloadProfilePayload must match original")
        } catch {
            fputs("FAILED: ReloadProfilePayloadCodec failed on large subscription profile: \(error)\n", stderr)
            exit(1)
        }

        do {
            try ProfileImportValidator.validate(data: Data(optimizedYAML.utf8))
        } catch {
            fputs("FAILED: DomesticRoutingOptimizer produced invalid YAML: \(error)\n", stderr)
            exit(1)
        }

        let summary = ProfileConfigurationInspector.inspect(yaml: optimizedYAML)
        guard let autoGroup = summary.proxyGroups.first(where: { $0.name == "自动选择" }) else {
            fputs("FAILED: Missing 自动选择 proxy group in summary\n", stderr)
            exit(1)
        }
        assertTrue(
            autoGroup.memberCount >= 4,
            "include-all + filter in 自动选择 must expand matching nodes (got \(autoGroup.memberCount))"
        )

        // 3c. Verify ConnectionTrafficAggregator across host, outbound, and application dimensions
        let sampleConnections = [
            ConnectionTelemetry(
                transport: .tcp,
                destination: "API.ANTHROPIC.COM:443",
                destinationPort: 443,
                uploadTotal: 300_000,
                downloadTotal: 1_200_000,
                startedAtUnixMilliseconds: 1000,
                rule: "DOMAIN-SUFFIX",
                rulePayload: "anthropic.com",
                proxyChain: "AI → Tokyo 01",
                sourceAppIdentifier: "com.anthropic.claudefordesktop",
                sourceAppPath: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
            ConnectionTelemetry(
                transport: .tcp,
                destination: "api.anthropic.com",
                destinationPort: 443,
                uploadTotal: 100_000,
                downloadTotal: 400_000,
                startedAtUnixMilliseconds: 2000,
                rule: "DOMAIN-SUFFIX",
                rulePayload: "anthropic.com",
                proxyChain: "AI → Tokyo 01",
                sourceAppIdentifier: "com.anthropic.claudefordesktop",
                sourceAppPath: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
        ]
        let hostSummary = ConnectionTrafficAggregator.summarize(connections: sampleConnections, dimension: .host)
        assertTrue(
            hostSummary.entries.count == 1 && hostSummary.entries.first?.key == "api.anthropic.com" && hostSummary.entries.first?.totalBytes == 2_000_000,
            "ConnectionTrafficAggregator must merge normalized hosts and sum bytes"
        )
        let outboundSummary = ConnectionTrafficAggregator.summarize(connections: sampleConnections, dimension: .outbound)
        assertTrue(
            outboundSummary.entries.first?.key == "Tokyo 01" && outboundSummary.entries.first?.shareOfTotal == 1.0,
            "ConnectionTrafficAggregator must extract terminal outbound hop"
        )

        // 3c. Verify TerminalProxyEnvGenerator multi-shell commands and PAC script
        let fishCmd = TerminalProxyEnvGenerator.shellCommand(dialect: .fish, host: "127.0.0.1", httpPort: 7890, socksPort: 7891)
        assertTrue(
            fishCmd.contains("set -gx HTTP_PROXY http://127.0.0.1:7890") && fishCmd.contains("set -gx ALL_PROXY socks5h://127.0.0.1:7891"),
            "TerminalProxyEnvGenerator must generate Fish shell proxy export commands"
        )
        let nuCmd = TerminalProxyEnvGenerator.shellCommand(dialect: .nushell, host: "127.0.0.1", httpPort: 7890, socksPort: 7891)
        assertTrue(
            nuCmd.contains("$env.HTTP_PROXY = \"http://127.0.0.1:7890\""),
            "TerminalProxyEnvGenerator must generate Nushell proxy export commands"
        )
        let pac = TerminalProxyEnvGenerator.pacScript(host: "127.0.0.1", httpPort: 7890, socksPort: 7891)
        assertTrue(
            pac.contains("function FindProxyForURL(url, host)") && pac.contains("PROXY 127.0.0.1:7890; SOCKS5 127.0.0.1:7891; SOCKS 127.0.0.1:7891; DIRECT"),
            "TerminalProxyEnvGenerator must generate a valid FindProxyForURL PAC script"
        )

        let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/compat_profile.yaml"
        try! Data(optimizedYAML.utf8).write(to: URL(fileURLWithPath: outputPath))
        print("PASS: Swift recovery state-machine & subscription compatibility checks passed cleanly")
    }
}
EOF

swiftc -swift-version 6 -parse-as-library \
  "$ROOT"/Sources/AetherRouteKit/*.swift \
  "$TEMP_DIR/verifier.swift" \
  -o "$TEMP_DIR/compat_verifier"

COMPAT_PROFILE="$TEMP_DIR/compat_profile.yaml"
"$TEMP_DIR/compat_verifier" "$COMPAT_PROFILE"

# 3b. Verify PacketTunnelProvider UplinkResetLedger parity, failover recovery
# probe session refresh, sub-threshold automaticRouteHealth log level, and
# AppKitProgressView opacity-only transition in AetherActionButtonLabel.
if ! grep -Fq 'private var resetLedger = UplinkResetLedger()' "$ROOT/Sources/AetherRoutePacketTunnel/PacketTunnelProvider.swift"; then
  echo "FAIL: PacketTunnelProvider must use UplinkResetLedger to avoid duplicate core resets on unchanged uplinks" >&2
  exit 1
fi
if ! grep -Fq 'Self.refreshProbeSession()' "$ROOT/Sources/AetherRouteApp/TunnelManager+Failover.swift"; then
  echo "FAIL: checkFailoverRecovery must call Self.refreshProbeSession() before verifyCurrentRouteDataPlane()" >&2
  exit 1
fi
if ! awk '/struct AetherProgressButtonLabel/,/^}/' "$ROOT/Sources/AetherRouteApp/AetherRouteVisualSystem.swift" | grep -A3 'ProgressView()' | grep -Fq '.transition(.opacity)'; then
  echo "FAIL: ProgressView in AetherProgressButtonLabel must use .transition(.opacity) (avoiding AppKitProgressView min<=max layout constraint fault)" >&2
  exit 1
fi
if ! grep -Fq 'TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(' "$ROOT/Sources/AetherRouteApp/TunnelManager+ProviderManagement.swift"; then
  echo "FAIL: updateState in TunnelManager+ProviderManagement.swift must use TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation" >&2
  exit 1
fi
if ! grep -Fq 'TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(' "$ROOT/Sources/AetherRouteApp/TunnelManager+ProviderManagement.swift"; then
  echo "FAIL: TunnelManager+ProviderManagement.swift must guard configuration reloads with TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange" >&2
  exit 1
fi

# 4. Test both Flow Core (libclashrs.a) and Direct/Packet Core (libclashrs-direct.a) loading the normalized profile
COMMON_FLAGS="-std=c17 -Wall -Wextra -Werror -mmacosx-version-min=14.0"
clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_FLOW_ONLY \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/flow_compat_smoke"

clang $COMMON_FLAGS \
  -DAETHER_EXTERNAL_PACKET \
  -I "$ROOT/Core/Headers" \
  "$ROOT/Tests/CoreSmoke/external_profile_smoke.c" \
  "$ROOT/Core/Artifacts/macos-arm64/libclashrs-direct.a" \
  -framework Security \
  -framework SystemConfiguration \
  -framework CoreFoundation \
  -framework CoreServices \
  -lresolv \
  -o "$TEMP_DIR/packet_compat_smoke"

mkdir -m 700 "$TEMP_DIR/runtime-flow" "$TEMP_DIR/runtime-packet"
for ASSET in Country.mmdb GeoSite.dat; do
  cp "$ROOT/Config/RoutingResources/$ASSET" "$TEMP_DIR/runtime-flow/$ASSET"
  cp "$ROOT/Config/RoutingResources/$ASSET" "$TEMP_DIR/runtime-packet/$ASSET"
done
"$TEMP_DIR/flow_compat_smoke" "$COMPAT_PROFILE" "$TEMP_DIR/runtime-flow" >/dev/null
"$TEMP_DIR/packet_compat_smoke" "$COMPAT_PROFILE" "$TEMP_DIR/runtime-packet" >/dev/null

echo "PASS: Both Flow and Packet Rust cores initialized and validated mixed third-party subscription cleanly"

# 5. A node that parses but cannot load (a transport the engine does not
# implement) must not take the profile down. Until 1.10.0 one such node made
# both cores refuse the whole subscription ("proxy ... not found" / "outbound
# could not be initialized"), while Mihomo loads the rest.
UNSUPPORTED_PROFILE="$TEMP_DIR/unsupported_transport.yaml"
cat >"$UNSUPPORTED_PROFILE" <<'YAML'
mode: rule
proxies:
  - {name: live, type: ss, server: 127.0.0.1, port: 1080, cipher: aes-128-gcm, password: fixture}
  - {name: xhttp-node, type: vless, server: 127.0.0.1, port: 1081, uuid: 11111111-2222-3333-4444-555555555555, network: xhttp, tls: true}
  - {name: kcp-node, type: vmess, server: 127.0.0.1, port: 1083, uuid: 11111111-2222-3333-4444-555555555555, cipher: auto, alterId: 0, network: kcp}
  - {name: upgrade-node, type: vmess, server: 127.0.0.1, port: 1082, uuid: 11111111-2222-3333-4444-555555555555, cipher: auto, alterId: 0, network: httpupgrade}
proxy-groups:
  - {name: PROXY, type: select, proxies: [AUTO, live, xhttp-node, kcp-node, upgrade-node]}
  - {name: AUTO, type: url-test, proxies: [xhttp-node, kcp-node, upgrade-node], url: 'http://www.gstatic.com/generate_204', interval: 300}
rules:
  - DOMAIN-SUFFIX,example.com,AUTO
  - MATCH,PROXY
YAML
mkdir -m 700 "$TEMP_DIR/runtime-flow-unsupported" "$TEMP_DIR/runtime-packet-unsupported"
for ASSET in Country.mmdb GeoSite.dat; do
  cp "$ROOT/Config/RoutingResources/$ASSET" "$TEMP_DIR/runtime-flow-unsupported/$ASSET"
  cp "$ROOT/Config/RoutingResources/$ASSET" "$TEMP_DIR/runtime-packet-unsupported/$ASSET"
done
"$TEMP_DIR/flow_compat_smoke" "$UNSUPPORTED_PROFILE" "$TEMP_DIR/runtime-flow-unsupported" >/dev/null || {
  echo "FAIL: Flow core refused a subscription with one unsupported-transport node" >&2
  exit 1
}
"$TEMP_DIR/packet_compat_smoke" "$UNSUPPORTED_PROFILE" "$TEMP_DIR/runtime-packet-unsupported" >/dev/null || {
  echo "FAIL: Packet core refused a subscription with one unsupported-transport node" >&2
  exit 1
}
echo "PASS: Both Rust cores skip unsupported-transport nodes and keep the rest of the subscription"
echo "==> [Gate] Recovery state-machine & third-party subscription compatibility gate passed successfully."

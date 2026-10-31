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

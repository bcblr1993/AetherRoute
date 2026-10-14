#!/bin/sh
set -eu
umask 077

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/aetherroute-plugin-gate.XXXXXX")
chmod 700 "$TEMP_DIR"
cleanup() {
  find "$TEMP_DIR" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

echo "==> [Gate] Testing Shadowsocks plugin & obfuscation subscription compatibility..."

# 1. Compile Swift validator runner
cat << 'EOF' > "$TEMP_DIR/verifier.swift"
import Foundation

@main
struct PluginGateVerifier {
    static func main() {
        let safeYAML = """
        mode: rule
        proxies:
          - name: ss-obfs-http-block
            type: ss
            server: 127.0.0.1
            port: 8388
            cipher: aes-128-gcm
            password: test-password
            plugin: obfs
            plugin-opts:
              mode: http
              host: bing.com
          - { name: ss-obfs-http-inline, type: ss, server: 127.0.0.1, port: 8389, cipher: aes-128-gcm, password: test-password, plugin: obfs, plugin-opts: { mode: http, host: microsoft.com }, udp: true }
          - name: ss-v2ray-ws
            type: ss
            server: 127.0.0.1
            port: 8390
            cipher: aes-128-gcm
            password: test-password
            plugin: "v2ray-plugin"
            plugin-opts:
              mode: websocket
              host: example.com
          - name: ss-shadowtls
            type: ss
            server: 127.0.0.1
            port: 8391
            cipher: aes-128-gcm
            password: test-password
            plugin: 'shadow-tls'
            plugin-opts:
              host: apple.com
              password: tls-pwd
              version: 3
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - ss-obfs-http-block
              - ss-obfs-http-inline
              - ss-v2ray-ws
              - ss-shadowtls
        rules:
          - MATCH,PROXY
        """

        guard let safeData = safeYAML.data(using: .utf8) else {
            fatalError("Failed to encode safeYAML")
        }

        do {
            try ProfileImportValidator.validate(data: safeData)
            _ = try SubscriptionPayloadNormalizer.normalizeWithReport(safeData)
        } catch {
            print("FAILED: Safe built-in plugins should be accepted, but threw: \(error)")
            exit(1)
        }

        // Test rejecting unknown or executable plugins
        let dangerousProfiles = [
            "proxies: [{name: bad1, type: ss, server: 1.1.1.1, port: 80, cipher: aes-128-gcm, password: p, plugin: /bin/sh}]",
            "proxies: [{name: bad2, type: ss, server: 1.1.1.1, port: 80, cipher: aes-128-gcm, password: p, plugin: executable}]",
            "proxies: [{name: bad3, type: ss, server: 1.1.1.1, port: 80, cipher: aes-128-gcm, password: p, plugin: 'curl http://evil.com'}]",
            "proxies: [{name: bad4, type: ss, server: 1.1.1.1, port: 80, cipher: aes-128-gcm, password: p, plugin: custom-plugin}]",
            "proxies: [{name: bad5, type: ss, server: 1.1.1.1, port: 80, cipher: aes-128-gcm, password: p, plugin: obfs, command: whoami}]",
        ]

        for (idx, badYaml) in dangerousProfiles.enumerated() {
            guard let badData = badYaml.data(using: .utf8) else { continue }
            var rejected = false
            do {
                try ProfileImportValidator.validate(data: badData)
            } catch ProfileImportError.forbiddenExecutableKey {
                rejected = true
            } catch {
                rejected = true
            }
            if !rejected {
                print("FAILED: Dangerous profile #\(idx + 1) was not rejected: \(badYaml)")
                exit(1)
            }
        }

        // Test existing local Clash Verge configuration if present
        let vergePath = ("~/Library/Application Support/io.github.clash-verge-rev.clash-verge-rev/profiles/LPXmmk7mFXDi.yaml" as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: vergePath),
           let vergeData = try? Data(contentsOf: URL(fileURLWithPath: vergePath)) {
            do {
                try ProfileImportValidator.validate(data: vergeData)
                _ = try SubscriptionPayloadNormalizer.normalizeWithReport(vergeData)
                print("PASS: Verified active Clash Verge profile (\(vergeData.count) bytes) with 0 errors")
            } catch {
                print("FAILED: Active Clash Verge profile failed validation: \(error)")
                exit(1)
            }
        }

        // Write safe YAML out for core smoke engine test
        let outputPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/safe_plugin_profile.yaml"
        try! safeData.write(to: URL(fileURLWithPath: outputPath))
        print("PASS: Swift ProfileImportValidator and SubscriptionPayloadNormalizer checks passed cleanly")
    }
}
EOF

swiftc -parse-as-library \
  "$ROOT/Sources/AetherRouteKit/ProfileImportValidator.swift" \
  "$ROOT/Sources/AetherRouteKit/AetherNode.swift" \
  "$ROOT/Sources/AetherRouteKit/SubscriptionPayloadNormalizer.swift" \
  "$TEMP_DIR/verifier.swift" \
  -o "$TEMP_DIR/plugin_verifier"

SAFE_PROFILE="$TEMP_DIR/safe_profile.yaml"
"$TEMP_DIR/plugin_verifier" "$SAFE_PROFILE"

# 2. Test Core Engine loading this configuration natively
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
  -o "$TEMP_DIR/flow_profile_smoke"

mkdir -m 700 "$TEMP_DIR/runtime"
"$TEMP_DIR/flow_profile_smoke" "$SAFE_PROFILE" "$TEMP_DIR/runtime" >/dev/null

echo "PASS: Native Rust engine successfully initialized and parsed plugin: obfs / v2ray-plugin / shadow-tls configuration"
echo "==> [Gate] Shadowsocks plugin & obfuscation subscription gate passed successfully."

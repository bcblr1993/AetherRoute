import Foundation
import XCTest
@testable import AetherRouteKit

/// The engine drops nodes and rules it cannot load with only a log line, and
/// a dropped rule sends its traffic elsewhere. The summary must name them
/// before the user connects, using the engine's own capability list.
final class ProfileCompatibilityReportTests: XCTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"

    private var yaml: String {
        """
        proxies:
          - {name: ok-vmess, type: vmess, server: a.example, port: 443, uuid: \(uuid), network: tcp}
          - {name: future-1, type: future-protocol, server: b.example, port: 1, cipher: aes-128-cfb, password: x}
          - {name: future-2, type: future-protocol, server: b.example, port: 2, cipher: aes-128-cfb, password: x}
          - {name: vm-kcp, type: vmess, server: a.example, port: 1, uuid: \(uuid), network: kcp}
          - {name: ss-kcptun, type: ss, server: a.example, port: 1, cipher: aes-128-gcm, password: x, plugin: kcptun}
          - {name: vl-enc, type: vless, server: a.example, port: 1, uuid: \(uuid), encryption: mlkem768x25519plus.native.0rtt.abc}
          - {name: vl-enc-ok, type: vless, server: a.example, port: 1, uuid: \(uuid), encryption: mlkem768x25519plus.native.0rtt.6nZ2lmyau-KImiEm9nOtwdltnv2hX_gC2EFrAXDrjTk}
          - {name: vl-none, type: vless, server: a.example, port: 1, uuid: \(uuid), encryption: none}
          - {name: any-fp, type: anytls, server: a.example, port: 1, password: x, client-fingerprint: chrome}
          - name: block-smux
            type: ss
            server: a.example
            port: 1
            cipher: aes-128-gcm
            password: x
            smux:
              enabled: true
        proxy-groups:
          - {name: P, type: select, proxies: [ok-vmess, future-1]}
        rules:
          - DOMAIN-SUFFIX,example.com,DIRECT
          - IP-ASN,13335,P
          - DOMAIN-WILDCARD,*.a.com,P
          - FUTURE-RULE,13335,P
          - FUTURE-RULE,15169,P
          - UNKNOWN-RULE,*.a.com,P
          - MATCH,P
        """
    }

    private func recognition(_ summary: ProfileConfigurationSummary, _ name: String)
        -> ProxyConfigurationSummary.Recognition?
    {
        summary.proxies.first { $0.name == name }?.recognition
    }

    private func assertReport(_ summary: ProfileConfigurationSummary, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(recognition(summary, "ok-vmess"), .recognized, file: file, line: line)
        XCTAssertEqual(recognition(summary, "vl-enc-ok"), .recognized, file: file, line: line)
        XCTAssertEqual(recognition(summary, "vl-none"), .recognized, file: file, line: line)
        XCTAssertEqual(recognition(summary, "future-1"), .unsupported(.protocolType("future-protocol")), file: file, line: line)
        XCTAssertEqual(recognition(summary, "vm-kcp"), .unsupported(.network("kcp")), file: file, line: line)
        XCTAssertEqual(recognition(summary, "ss-kcptun"), .unsupported(.plugin("kcptun")), file: file, line: line)
        XCTAssertEqual(recognition(summary, "vl-enc"), .unsupported(.option("encryption")), file: file, line: line)
        // Limited options still connect, so the node stays usable.
        XCTAssertEqual(recognition(summary, "any-fp"), .recognized, file: file, line: line)
        XCTAssertEqual(recognition(summary, "block-smux"), .recognized, file: file, line: line)
        XCTAssertFalse(ProxyConfigurationSummary.Recognition.unsupported(.protocolType("future-protocol")).isUsable)

        let report = summary.compatibility
        XCTAssertFalse(report.isFullySupported, file: file, line: line)
        XCTAssertEqual(report.unsupportedProxyCount, 5, file: file, line: line)
        XCTAssertEqual(
            report.unsupportedProxies,
            [
                .init(reason: .protocolType("future-protocol"), count: 2, examples: ["future-1", "future-2"]),
                .init(reason: .network("kcp"), count: 1, examples: ["vm-kcp"]),
                .init(reason: .plugin("kcptun"), count: 1, examples: ["ss-kcptun"]),
                .init(reason: .option("encryption"), count: 1, examples: ["vl-enc"]),
            ],
            file: file, line: line
        )
        XCTAssertEqual(
            report.unsupportedRules,
            [.init(kind: "FUTURE-RULE", count: 2), .init(kind: "UNKNOWN-RULE", count: 1)],
            file: file, line: line
        )
        // The engine sends a browser-like ClientHello and multiplexes
        // `smux` nodes since 2.0, so neither is a limitation any more.
        XCTAssertEqual(report.limitedOptions, [], file: file, line: line)
    }

    func testYAMLProfileReportsWhatTheEngineCannotLoad() {
        assertReport(ProfileConfigurationInspector.inspect(yaml: yaml))
    }

    func testJSONProfileReportsTheSame() throws {
        let proxies: [[String: Any]] = [
            ["name": "ok-vmess", "type": "vmess", "server": "a.example", "port": 443, "uuid": uuid, "network": "tcp"],
            ["name": "future-1", "type": "future-protocol", "server": "b.example", "port": 1],
            ["name": "future-2", "type": "future-protocol", "server": "b.example", "port": 2],
            ["name": "vm-kcp", "type": "vmess", "server": "a.example", "port": 1, "uuid": uuid, "network": "kcp"],
            ["name": "ss-kcptun", "type": "ss", "server": "a.example", "port": 1, "cipher": "aes-128-gcm", "password": "x", "plugin": "kcptun"],
            ["name": "vl-enc", "type": "vless", "server": "a.example", "port": 1, "uuid": uuid, "encryption": "mlkem768x25519plus.native.0rtt.abc"],
            ["name": "vl-enc-ok", "type": "vless", "server": "a.example", "port": 1, "uuid": uuid, "encryption": "mlkem768x25519plus.native.0rtt.6nZ2lmyau-KImiEm9nOtwdltnv2hX_gC2EFrAXDrjTk"],
            ["name": "vl-none", "type": "vless", "server": "a.example", "port": 1, "uuid": uuid, "encryption": "none"],
            ["name": "any-fp", "type": "anytls", "server": "a.example", "port": 1, "password": "x", "client-fingerprint": "chrome"],
            ["name": "block-smux", "type": "ss", "server": "a.example", "port": 1, "cipher": "aes-128-gcm", "password": "x", "smux": ["enabled": true]],
        ]
        let object: [String: Any] = [
            "proxies": proxies,
            "proxy-groups": [["name": "P", "type": "select", "proxies": ["ok-vmess", "future-1"]]],
            "rules": [
                "DOMAIN-SUFFIX,example.com,DIRECT", "IP-ASN,13335,P", "DOMAIN-WILDCARD,*.a.com,P",
                "FUTURE-RULE,13335,P", "FUTURE-RULE,15169,P",
                "UNKNOWN-RULE,*.a.com,P", "MATCH,P",
            ],
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        assertReport(ProfileConfigurationInspector.inspect(yaml: String(decoding: data, as: UTF8.self)))
    }

    func testCleanProfileIsFullySupported() {
        let summary = ProfileConfigurationInspector.inspect(yaml: """
        proxies:
          - {name: a, type: ss, server: a.example, port: 1, cipher: aes-128-gcm, password: x, plugin: obfs}
          - {name: b, type: trojan, server: a.example, port: 443, password: x, network: grpc}
        rules:
          - GEOIP,CN,DIRECT
          - MATCH,a
        """)
        XCTAssertTrue(summary.compatibility.isFullySupported)
        XCTAssertEqual(summary.compatibility.unsupportedProxyCount, 0)
    }

    func testXboardV2BoardSSPanelSubscriptionCorpusIsFullySupported() {
        let corpusYAML = """
        mode: rule
        global-client-fingerprint: chrome
        sniffer:
          enable: true
          force-dns-mapping: true
          parse-pure-ip: true
          sniff:
            HTTP:
              ports: [80, 8080-8880]
              override-destination: true
            TLS:
              ports: [443, 8443]
            QUIC:
              ports: [443, 8443]
          force-domain:
            - '+.netflix.com'
          skip-domain:
            - 'Mijia Cloud'
        dns:
          enable: true
          enhanced-mode: fake-ip
          fake-ip-filter-mode: blacklist
          fake-ip-filter:
            - '*.lan'
          direct-nameserver:
            - 223.5.5.5
          direct-nameserver-follow-policy: true
          prefer-h3: true
          nameserver:
            - quic://dns.adguard-dns.com:853
            - h3://dns.alidns.com/dns-query
            - https://cloudflare-dns.com/dns-query
        proxies:
          - {name: Xboard-SS2022, type: ss, server: s.example, port: 8388, cipher: 2022-blake3-aes-128-gcm, password: p, udp: true, smux: {enabled: true, protocol: smux}}
          - {name: SSPanel-SSR, type: ssr, server: s.example, port: 8389, cipher: aes-256-cfb, password: p, protocol: auth_aes128_md5, obfs: tls1.2_ticket_auth}
          - {name: V2Board-VMess, type: vmess, server: s.example, port: 443, uuid: \(uuid), alterId: 0, cipher: auto, network: ws, tls: true}
          - {name: Xboard-VLESS-XHTTP, type: vless, server: s.example, port: 443, uuid: \(uuid), network: xhttp, tls: true, encryption: none}
          - {name: Xboard-VLESS-ENC, type: vless, server: s.example, port: 443, uuid: \(uuid), network: tcp, encryption: mlkem768x25519plus.native.0rtt.6nZ2lmyau-KImiEm9nOtwdltnv2hX_gC2EFrAXDrjTk}
          - {name: V2Board-Trojan, type: trojan, server: s.example, port: 443, password: p, network: tcp, client-fingerprint: chrome}
          - {name: Panel-Hy1, type: hysteria, server: s.example, port: 443, auth-str: p, up: 50, down: 200, protocol: udp}
          - {name: Panel-Hy2, type: hysteria2, server: s.example, port: 443, password: p, obfs: salamander, obfs-password: o}
          - {name: Panel-TUICv4, type: tuic, server: s.example, port: 443, token: t, version: 4}
          - {name: Panel-TUICv5, type: tuic, server: s.example, port: 443, uuid: \(uuid), password: p, version: 5}
          - {name: Xboard-AnyTLS, type: anytls, server: s.example, port: 443, password: p, client-fingerprint: chrome}
          - {name: Panel-Snell, type: snell, server: s.example, port: 8443, psk: p, version: 4, obfs-opts: {mode: tls, host: s.example}}
          - {name: Panel-Mieru, type: mieru, server: s.example, port: 8444, username: u, password: p, transport: TCP, multiplexing: MULTIPLEXING_HIGH}
          - {name: Panel-WireGuard, type: wireguard, server: s.example, port: 51820, ip: 10.0.0.2, private-key: k, public-key: k}
          - {name: Panel-AmneziaWG, type: wireguard, server: s.example, port: 51821, ip: 10.0.0.3, private-key: k, public-key: k, amnezia-wg-option: {jc: 4, jmin: 40, jmax: 70}}
          - {name: Panel-SSH, type: ssh, server: s.example, port: 22, username: u, password: p}
          - {name: Panel-ShadowQUIC, type: shadowquic, server: s.example, port: 443, username: u, password: p}
          - {name: Panel-SOCKS5, type: socks5, server: s.example, port: 1080, username: u, password: p}
          - {name: Panel-HTTP, type: http, server: s.example, port: 8080, username: u, password: p}
        proxy-groups:
          - {name: PROXY, type: select, include-all: true}
        rules:
          - DOMAIN-WILDCARD,*.google.com,PROXY
          - GEOSITE,cn,DIRECT
          - IP-ASN,13335,PROXY,no-resolve
          - IP-SUFFIX,8.8.8.8/24,PROXY,no-resolve
          - SRC-GEOIP,CN,DIRECT
          - SRC-IP-ASN,4134,DIRECT
          - SRC-IP-SUFFIX,192.168.1.1/24,DIRECT
          - IN-PORT,7890,PROXY
          - IN-TYPE,INNER,PROXY
          - IN-USER,user1,PROXY
          - IN-NAME,mixed-in,PROXY
          - DSCP,46,PROXY
          - PROCESS-NAME-REGEX,^Claude.*,PROXY
          - PROCESS-PATH-REGEX,.*/Applications/.*,PROXY
          - NETWORK,udp,PROXY
          - UID,501,DIRECT
          - SUB-RULE,(NETWORK,tcp),sub-group
          - AND,((DOMAIN,example.com),(NETWORK,tcp)),PROXY
          - OR,((GEOIP,CN),(GEOSITE,cn)),DIRECT
          - NOT,((GEOIP,CN)),PROXY
          - MATCH,PROXY
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: corpusYAML)
        XCTAssertEqual(summary.proxyCount, 19)
        XCTAssertTrue(summary.compatibility.isFullySupported, "\(summary.compatibility)")
        XCTAssertEqual(summary.compatibility.unsupportedProxyCount, 0)
        XCTAssertEqual(summary.compatibility.unsupportedRules, [])
        XCTAssertEqual(summary.compatibility.limitedOptions, [])
        let transports = Set(summary.dns.upstreamTransports)
        XCTAssertTrue(transports.contains(.dnsOverTLS))
        XCTAssertTrue(transports.contains(.dnsOverHTTPS))
        XCTAssertFalse(transports.contains(.unsupported))
    }

    func testSwiftCapabilitiesMatchTheEngineSnapshot() throws {
        // Config/EngineCapabilities.json is `clash-rs --capabilities` from the
        // shipped feature set; scripts/verify_engine_capabilities.sh keeps it
        // equal to the engine, and this keeps the Swift copy equal to it.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Config/EngineCapabilities.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["schema"] as? Int, EngineCapabilities.schema)
        XCTAssertEqual(Set(json["outboundTypes"] as? [String] ?? []), EngineCapabilities.outboundTypes)
        XCTAssertEqual(Set(json["ruleTypes"] as? [String] ?? []), EngineCapabilities.ruleTypes)
        XCTAssertEqual(Set(json["shadowsocksPlugins"] as? [String] ?? []), EngineCapabilities.shadowsocksPlugins)
        let networks = (json["networks"] as? [String: [String]] ?? [:]).mapValues(Set.init)
        XCTAssertEqual(networks, EngineCapabilities.networks)
    }
}

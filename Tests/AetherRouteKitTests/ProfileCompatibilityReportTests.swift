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
          - IP-ASN,15169,P
          - DOMAIN-WILDCARD,*.a.com,P
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
            [.init(kind: "IP-ASN", count: 2), .init(kind: "DOMAIN-WILDCARD", count: 1)],
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
                "DOMAIN-SUFFIX,example.com,DIRECT", "IP-ASN,13335,P", "IP-ASN,15169,P",
                "DOMAIN-WILDCARD,*.a.com,P", "MATCH,P",
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

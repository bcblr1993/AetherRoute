import Foundation
import XCTest
@testable import AetherRouteKit

/// V2Ray `httpupgrade` arrives as `type=httpupgrade` in share links and as
/// `"net": "httpupgrade"` in VMess links. The engine reads Mihomo's spelling:
/// `network: ws` with `ws-opts.v2ray-http-upgrade: true`.
final class HTTPUpgradeTransportTests: XCTestCase {
    private let uuid = "11111111-2222-3333-4444-555555555555"

    private func vmessLink(net: String) throws -> String {
        let payload = [
            "v": "2", "ps": "VMess-Upgrade", "add": "127.0.0.1", "port": "443",
            "id": uuid, "aid": "0", "scy": "auto", "net": net, "type": "none",
            "host": "cdn.example", "path": "/vmup", "tls": "tls", "sni": "cdn.example",
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return "vmess://\(data.base64EncodedString())"
    }

    func testSubscriptionShareLinksCompileToMihomoSpelling() throws {
        let links = [
            "vless://\(uuid)@127.0.0.1:443?security=tls&sni=cdn.example&type=httpupgrade&host=cdn.example&path=%2Fvlup#VLESS-Upgrade",
            "trojan://secret@127.0.0.1:443?sni=cdn.example&type=httpupgrade&path=%2Ftrup#Trojan-Upgrade",
            try vmessLink(net: "httpupgrade"),
        ]
        let encoded = Data(links.joined(separator: "\n").utf8).base64EncodedString()
        let output = try SubscriptionPayloadNormalizer.normalize(Data(encoded.utf8))
        let yaml = try XCTUnwrap(String(data: output, encoding: .utf8))
        try ProfileImportValidator.validate(data: output)

        for name in ["VLESS-Upgrade", "Trojan-Upgrade", "VMess-Upgrade"] {
            XCTAssertTrue(yaml.contains("name: '\(name)'"), "\(name) must not be skipped:\n\(yaml)")
        }
        XCTAssertEqual(yaml.components(separatedBy: "v2ray-http-upgrade: true").count - 1, 3, yaml)
        XCTAssertFalse(yaml.contains("network: 'httpupgrade'"), yaml)
        for path in ["/vlup", "/trup", "/vmup"] {
            XCTAssertTrue(yaml.contains("path: '\(path)'"), path)
        }
    }

    func testPastedLinkKeepsTheTransportAndRoundTrips() throws {
        let link = "vless://\(uuid)@cdn.example:443?security=tls&sni=cdn.example&type=httpupgrade&host=cdn.example&path=%2Fvlup#Upgrade"
        let node = try AetherNodeURIParser.parse(link)
        XCTAssertEqual(node.transport.kind, .webSocket)
        XCTAssertTrue(node.transport.httpUpgrade)
        XCTAssertEqual(node.transport.path, "/vlup")

        let yaml = try AetherNodeProfileCompiler.compile(node: node)
        XCTAssertTrue(yaml.contains("network: 'ws'"), yaml)
        XCTAssertTrue(yaml.contains("v2ray-http-upgrade: true"), yaml)
        try ProfileImportValidator.validate(data: Data(yaml.utf8))

        let exported = try AetherNodeURIParser.format(node)
        XCTAssertTrue(exported.contains("type=httpupgrade"), exported)
        XCTAssertEqual(try AetherNodeURIParser.parse(exported).transport, node.transport)

        let vmess = try AetherNodeURIParser.parse(try vmessLink(net: "httpupgrade"))
        XCTAssertTrue(vmess.transport.httpUpgrade)
        let vmessExport = try AetherNodeURIParser.format(vmess)
        XCTAssertTrue(try AetherNodeURIParser.parse(vmessExport).transport.httpUpgrade)
    }

    func testPastedLinkWithAnUnknownTransportIsRefusedInsteadOfBecomingTCP() {
        // `xhttp` used to be turned into a plain TCP node that could never
        // connect, with no message.
        let link = "vless://\(uuid)@cdn.example:443?security=tls&type=xhttp&path=%2Fx#X"
        XCTAssertThrowsError(try AetherNodeURIParser.parse(link)) { error in
            XCTAssertEqual(error as? AetherNodeURIError, .unsupportedTransport("xhttp"))
        }
    }

    func testNodesSavedBeforeTheFieldExistedStillDecode() throws {
        let stored = Data(#"{"kind":"ws","path":"/ws","host":"h","grpcServiceName":""}"#.utf8)
        let transport = try JSONDecoder().decode(AetherNodeTransportOptions.self, from: stored)
        XCTAssertEqual(transport.kind, .webSocket)
        XCTAssertFalse(transport.httpUpgrade)
    }
}

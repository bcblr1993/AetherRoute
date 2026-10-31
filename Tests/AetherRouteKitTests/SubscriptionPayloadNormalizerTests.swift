import Foundation
import XCTest
@testable import AetherRouteKit

final class SubscriptionPayloadNormalizerTests: XCTestCase {
    func testPreservesValidatedYAMLByteForByte() throws {
        let input = Data(
            "proxies:\n  - {name: Edge, type: direct}\nrules:\n  - MATCH,Edge\n".utf8
        )
        XCTAssertEqual(try SubscriptionPayloadNormalizer.normalize(input), input)
    }

    func testBase64ShareListCompilesAllCatalogProtocols() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let vmess = try vmessLink(uuid: uuid)
        let ssCredentials = Data("aes-128-gcm:ss-secret".utf8)
            .base64EncodedString()
        let privateKey = percentEncode(key)
        let publicKey = percentEncode(key)
        let ssrPayload = Data(
            "127.0.0.1:8389:auth_aes128_md5:aes-256-cfb:tls1.2_ticket_auth:\(Data("ssr-secret".utf8).base64EncodedString())/?remarks=\(Data("SSR".utf8).base64EncodedString())".utf8
        ).base64EncodedString()
        let links = [
            "http://user:pass@127.0.0.1:8080#HTTP",
            "socks5://user:pass@127.0.0.1:1080#SOCKS",
            "ss://\(ssCredentials)@127.0.0.1:8388#SS",
            "ssr://\(ssrPayload)",
            vmess,
            "vless://\(uuid)@127.0.0.1:443?security=reality&sni=edge.example&pbk=\(key.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))&sid=abcd&type=ws&path=%2Fws&host=edge.example#VLESS",
            "trojan://trojan-secret@127.0.0.1:443?sni=edge.example&type=grpc&serviceName=route#Trojan",
            "hysteria://127.0.0.1:8444?auth_str=hy1-secret&peer=edge.example&upmbps=30&downmbps=150#HY1",
            "hysteria2://hy-secret@127.0.0.1:8443?sni=edge.example&obfs=salamander&obfs-password=obfs#HY2",
            "tuic://\(uuid):tuic-secret@127.0.0.1:8443?sni=edge.example&congestion_control=bbr&udp_relay_mode=native#TUIC",
            "anytls://any-secret@127.0.0.1:443?sni=edge.example#AnyTLS",
            "wireguard://\(privateKey)@127.0.0.1:51820?public-key=\(publicKey)&address=10.0.0.2&allowed-ips=0.0.0.0%2F0&mtu=1280#WG",
            "ssh://ssh-user:ssh-secret@127.0.0.1:22#SSH",
            "shadowquic://sq-user:sq-secret@127.0.0.1:443?sni=edge.example&congestion_control=bbr&initial-mtu=1280#ShadowQUIC",
            "snell://snell-secret@127.0.0.1:8445?version=4&obfs=tls&obfs-host=edge.example#Snell",
            "mieru://mieru-user:mieru-secret@127.0.0.1:8446?transport=TCP&multiplexing=MULTIPLEXING_HIGH#Mieru",
        ]
        XCTAssertEqual(
            links.count,
            AetherNodeProtocol.allCases.count,
            "Every native protocol must keep a subscription share-link fixture."
        )
        let encoded = Data(links.joined(separator: "\n").utf8)
            .base64EncodedString()

        let output = try SubscriptionPayloadNormalizer.normalize(Data(encoded.utf8))
        let yaml = try XCTUnwrap(String(data: output, encoding: .utf8))
        try ProfileImportValidator.validate(data: output)
        for coreType in [
            "http", "socks5", "ss", "ssr", "vmess", "vless", "trojan",
            "hysteria", "hysteria2", "tuic", "anytls", "wireguard", "ssh",
            "shadowquic", "snell", "mieru",
        ] {
            XCTAssertTrue(yaml.contains("type: '\(coreType)'"), coreType)
        }
        XCTAssertTrue(yaml.contains("name: 'AetherRoute Subscription'"))
        XCTAssertTrue(yaml.contains("reality-opts:"))
        XCTAssertTrue(yaml.contains("private-key: '"))
    }

    func testPlainShareListDeduplicatesNamesWithoutDroppingNodes() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let text = """
        vless://\(uuid)@127.0.0.1:443?security=tls&sni=edge.example#Same
        trojan://secret@127.0.0.1:443?sni=edge.example#Same
        """
        let output = try SubscriptionPayloadNormalizer.normalize(Data(text.utf8))
        let yaml = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(yaml.contains("name: 'Same'"))
        XCTAssertTrue(yaml.contains("name: 'Same 2'"))
    }

    func testShadowsocksAcceptsEmptyTrailingQueryMarker() throws {
        let credentials = Data("aes-128-gcm:ss-secret".utf8)
            .base64EncodedString()
        let input = Data(
            "ss://\(credentials)@127.0.0.1:8388?#Edge".utf8
        )
        let result = try SubscriptionPayloadNormalizer.normalizeWithReport(
            input
        )
        let yaml = try XCTUnwrap(String(data: result.data, encoding: .utf8))
        XCTAssertTrue(yaml.contains("type: 'ss'"))
        XCTAssertTrue(yaml.contains("cipher: 'aes-128-gcm'"))
        XCTAssertEqual(result.report.usableNodeCount, 1)
        XCTAssertEqual(result.report.skippedNodeCount, 0)
    }

    func testIPv6ShareLinksRemoveURLAuthorityBrackets() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let input = """
        http://[::1]:8080#HTTP-v6
        vless://\(uuid)@[2001:db8::1]:443?security=tls&sni=edge.example#VLESS-v6
        """
        let result = try SubscriptionPayloadNormalizer.normalizeWithReport(
            Data(input.utf8)
        )
        let yaml = try XCTUnwrap(String(data: result.data, encoding: .utf8))
        XCTAssertTrue(yaml.contains("server: '::1'"))
        XCTAssertTrue(yaml.contains("server: '2001:db8::1'"))
        XCTAssertFalse(yaml.contains("server: '[::1]'"))
        XCTAssertFalse(yaml.contains("server: '[2001:db8::1]'"))
        XCTAssertEqual(result.report.usableNodeCount, 2)
        XCTAssertEqual(result.report.skippedNodeCount, 0)
    }

    func testMixedShareListSkipsInvalidNodesAndReportsCounts() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"
        let input = """
        vless://\(uuid)@127.0.0.1:443#Valid
        unknown://secret@127.0.0.1:443#Unknown
        tuic://not-a-uuid:secret@127.0.0.1:443#Broken
        """
        let result = try SubscriptionPayloadNormalizer.normalizeWithReport(
            Data(input.utf8)
        )
        let yaml = try XCTUnwrap(String(data: result.data, encoding: .utf8))
        XCTAssertTrue(yaml.contains("name: 'Valid'"))
        XCTAssertFalse(yaml.contains("Unknown"))
        XCTAssertFalse(yaml.contains("Broken"))
        XCTAssertEqual(result.report.usableNodeCount, 1)
        XCTAssertEqual(result.report.skippedNodeCount, 2)
    }

    func testAllInvalidShareLinksStillFail() throws {
        let uuid = "11111111-2222-3333-4444-555555555555"

        XCTAssertThrowsError(
            try SubscriptionPayloadNormalizer.normalize(
                Data("unknown://secret@127.0.0.1:443#Unknown".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? SubscriptionPayloadError,
                .unsupportedShareScheme("unknown")
            )
        }

        XCTAssertThrowsError(
            try SubscriptionPayloadNormalizer.normalize(
                Data(
                    "tuic://not-a-uuid:secret@127.0.0.1:443#Broken".utf8
                )
            )
        ) { error in
            XCTAssertEqual(
                error as? SubscriptionPayloadError,
                .invalidShareLink(1)
            )
        }

        let oversizedScheme = String(repeating: "x", count: 33)
            + "://secret@127.0.0.1:443#Oversized"
        XCTAssertThrowsError(
            try SubscriptionPayloadNormalizer.normalize(Data(oversizedScheme.utf8))
        ) { error in
            XCTAssertEqual(
                error as? SubscriptionPayloadError,
                .invalidShareLink(1)
            )
        }

        let oversizedQueryValue = "vless://\(uuid)@127.0.0.1:443?"
            + "ignored=\(String(repeating: "a", count: 4_097))#Oversized"
        XCTAssertThrowsError(
            try SubscriptionPayloadNormalizer.normalize(Data(oversizedQueryValue.utf8))
        ) { error in
            XCTAssertEqual(
                error as? SubscriptionPayloadError,
                .invalidShareLink(1)
            )
        }
    }

    func testBase64ExecutableYAMLRemainsRejected() throws {
        let malicious = """
        proxies:
          - {name: Edge, type: direct}
        script:
          code: unsafe
        """
        let encoded = Data(malicious.utf8).base64EncodedString()
        XCTAssertThrowsError(
            try SubscriptionPayloadNormalizer.normalize(Data(encoded.utf8))
        ) { error in
            XCTAssertEqual(
                error as? ProfileImportError,
                .forbiddenExecutableKey("script")
            )
        }
    }

    func testSubscriptionClientNormalizesShareListBeforeReturningUpdate() async throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/subscription"))
        let subscription = try ProfileSubscription(url: url)
        let uuid = "11111111-2222-3333-4444-555555555555"
        let body = Data(
            "vless://\(uuid)@127.0.0.1:443?security=tls&sni=edge.example#Edge".utf8
        ).base64EncodedString()
        let client = ProfileSubscriptionClient { _ in
            ProfileSubscriptionHTTPResponse(
                data: Data(body.utf8),
                statusCode: 200,
                finalURL: url
            )
        }

        guard case let .updated(data, _, report) = try await client.fetch(subscription) else {
            return XCTFail("Expected normalized subscription data")
        }
        let yaml = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(yaml.contains("type: 'vless'"))
        XCTAssertFalse(yaml.contains("vless://"))
        XCTAssertEqual(report.usableNodeCount, 1)
        XCTAssertEqual(report.skippedNodeCount, 0)
    }

    func testNormalizerStripsHarmlessExternalUIDirectivesFromSubscriptionYAML() throws {
        let input = """
        mixed-port: 7890
        external-controller: 127.0.0.1:9090
        external-ui: ui
        external-ui-name: xd
        external-ui-url: "https://github.com/MetaCubeX/metacubexd/archive/refs/heads/gh-pages.zip"
        proxies:
          - name: Edge
            type: trojan
            server: edge.example.com
            port: 443
            password: secret
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - Edge
        rules:
          - MATCH,PROXY
        """
        let result = try SubscriptionPayloadNormalizer.normalizeWithReport(Data(input.utf8))
        let normalizedYAML = try XCTUnwrap(String(data: result.data, encoding: .utf8))
        XCTAssertFalse(normalizedYAML.contains("external-ui"))
        XCTAssertTrue(normalizedYAML.contains("name: Edge"))
        try ProfileImportValidator.validate(data: result.data)
    }

    func testSIP008JSONAndSurgeProxySectionsNormalizeToValidatedYAML() throws {
        let sip008 = """
        {
          "version": 1,
          "servers": [
            {
              "server": "127.0.0.1",
              "server_port": 8388,
              "password": "ss-password",
              "method": "2022-blake3-aes-128-gcm",
              "remarks": "SIP008-HK",
              "plugin": "obfs-local",
              "plugin_opts": "obfs=tls;obfs-host=cloudflare.com"
            }
          ]
        }
        """
        let sip008Result = try SubscriptionPayloadNormalizer.normalizeWithReport(Data(sip008.utf8))
        let sip008YAML = try XCTUnwrap(String(data: sip008Result.data, encoding: .utf8))
        try ProfileImportValidator.validate(data: sip008Result.data)
        XCTAssertTrue(sip008YAML.contains("name: 'SIP008-HK'"))
        XCTAssertTrue(sip008YAML.contains("plugin: 'obfs'"))
        XCTAssertEqual(sip008Result.report.usableNodeCount, 1)

        let surgeConf = """
        [General]
        loglevel = notify

        [Proxy]
        Surge-Snell = snell, 127.0.0.1, 8443, psk=snell-psk, obfs=tls, obfs-host=cloudflare.com, version=4, reuse=true
        Surge-Trojan = trojan, 127.0.0.1, 443, password=trojan-pass, sni=edge.example, skip-cert-verify=true

        [Rule]
        FINAL,Surge-Snell
        """
        let surgeResult = try SubscriptionPayloadNormalizer.normalizeWithReport(Data(surgeConf.utf8))
        let surgeYAML = try XCTUnwrap(String(data: surgeResult.data, encoding: .utf8))
        try ProfileImportValidator.validate(data: surgeResult.data)
        XCTAssertTrue(surgeYAML.contains("name: 'Surge-Snell'"))
        XCTAssertTrue(surgeYAML.contains("type: 'snell'"))
        XCTAssertTrue(surgeYAML.contains("name: 'Surge-Trojan'"))
        XCTAssertTrue(surgeYAML.contains("type: 'trojan'"))
        XCTAssertEqual(surgeResult.report.usableNodeCount, 2)
    }

    private func vmessLink(uuid: String) throws -> String {
        let object: [String: Any] = [
            "v": "2",
            "ps": "VMess",
            "add": "127.0.0.1",
            "port": "443",
            "id": uuid,
            "aid": "0",
            "scy": "auto",
            "net": "ws",
            "host": "edge.example",
            "path": "/vmess",
            "tls": "tls",
            "sni": "edge.example",
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return "vmess://\(data.base64EncodedString())"
    }

    private func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? value
    }
}

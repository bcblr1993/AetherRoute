import XCTest
@testable import AetherRouteKit

final class AetherNodeTests: XCTestCase {
    private let openSSHPrivateKey = """
    -----BEGIN OPENSSH PRIVATE KEY-----
    ZGV0ZXJtaW5pc3RpYy10ZXN0LWtleQ==
    -----END OPENSSH PRIVATE KEY-----
    """

    func testEveryCatalogProtocolCompilesToAValidatedProfile() throws {
        let nodes = Self.makeNodes()
        XCTAssertEqual(
            Set(nodes.map(\.protocolID)),
            Set(AetherNodeProtocol.allCases)
        )
        XCTAssertEqual(
            Set(ProtocolCatalog.releaseTarget.map(\.id)),
            Set(AetherNodeProtocol.allCases.map(\.rawValue))
        )

        for node in nodes {
            let yaml = try AetherNodeProfileCompiler.compile(node: node)
            try ProfileImportValidator.validate(data: Data(yaml.utf8))
            let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
            XCTAssertEqual(summary.proxyCount, 1, node.protocolID.rawValue)
            XCTAssertEqual(summary.proxyGroupCount, 1, node.protocolID.rawValue)
            XCTAssertEqual(summary.ruleCount, 1, node.protocolID.rawValue)
            XCTAssertEqual(summary.proxies.first?.recognition, .recognized)
        }
    }

    func testModelRoundTripsWithoutLosingProtocolOptions() throws {
        let original = try XCTUnwrap(
            Self.makeNodes().first { $0.protocolID == .vless }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(AetherNode.self, from: encoded)
        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.formatVersion, AetherNode.currentFormatVersion)
    }

    func testCompilerQuotesYAMLMetacharactersInsteadOfCreatingNewKeys() throws {
        let node = AetherNode(
            name: "Edge: # user's choice",
            protocolID: .http,
            server: "proxy.example",
            port: 443,
            username: "name: admin",
            password: "p'ass#word",
            tls: AetherNodeTLS(enabled: true, serverName: "edge.example")
        )
        let yaml = try AetherNodeProfileCompiler.compile(node: node)
        XCTAssertTrue(yaml.contains("name: 'Edge: # user''s choice'"))
        XCTAssertTrue(yaml.contains("password: 'p''ass#word'"))
        XCTAssertEqual(
            ProfileConfigurationInspector.inspect(yaml: yaml).proxyCount,
            1
        )
    }

    func testValidationRejectsEndpointAndTransportInjection() {
        var invalidServer = AetherNode(
            name: "Bad",
            protocolID: .http,
            server: "proxy.example\nrules:",
            port: 443
        )
        XCTAssertThrowsError(try invalidServer.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .invalidField("Server")
            )
        }

        invalidServer.server = "https://proxy.example/path"
        XCTAssertThrowsError(try invalidServer.validated())

        let invalidTransport = AetherNode(
            name: "SSH",
            protocolID: .ssh,
            server: "ssh.example",
            port: 22,
            username: "user",
            password: "password",
            transport: AetherNodeTransportOptions(kind: .webSocket)
        )
        XCTAssertThrowsError(try invalidTransport.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .invalidTransport(.webSocket, .ssh)
            )
        }
    }

    func testValidationRequiresProtocolSpecificCredentials() {
        let missingUUID = AetherNode(
            name: "VLESS",
            protocolID: .vless,
            server: "vless.example",
            port: 443
        )
        XCTAssertThrowsError(try missingUUID.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .missingField("UUID")
            )
        }

        let missingWireGuardRoute = AetherNode(
            name: "WireGuard",
            protocolID: .wireGuard,
            server: "wg.example",
            port: 51820,
            privateKey: "CH7G4Uu+0hDnIVzcc0aN+iPwgKG/uGZbL9gJvZnSg3k=",
            publicKey: "xMjphMUyLIGExyJluSslD9tjaIcF9QS6ADyI8DOTzyg=",
            localAddress: "10.0.0.2/32"
        )
        XCTAssertThrowsError(try missingWireGuardRoute.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .missingField("Allowed IPs")
            )
        }
    }

    func testRealityValidationRequiresHandshakeIdentityAndCanonicalKeys() {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        let publicKey = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
        var node = AetherNode(
            name: "Reality",
            protocolID: .vless,
            server: "vless.example",
            port: 443,
            uuid: uuid,
            tls: AetherNodeTLS(
                enabled: true,
                realityPublicKey: publicKey,
                realityShortID: "1392897e"
            )
        )
        XCTAssertThrowsError(try node.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .missingField("Reality server name")
            )
        }

        node.tls.serverName = "edge.example"
        node.tls.realityPublicKey = "not-a-valid-x25519-key"
        XCTAssertThrowsError(try node.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .invalidField("Reality public key")
            )
        }

        node.tls.realityPublicKey = publicKey
        node.tls.realityShortID = "123xyz"
        XCTAssertThrowsError(try node.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .invalidField("Reality short ID")
            )
        }

        node.tls.realityShortID = ""
        XCTAssertNoThrow(try node.validated())
    }

    func testOpenSSHPrivateKeyDocumentIsBoundedAndNeverAcceptsAPath() throws {
        let decoded = try AetherSSHPrivateKeyDocument.decode(
            data: Data(openSSHPrivateKey.utf8)
        )
        XCTAssertEqual(decoded, openSSHPrivateKey + "\n")

        XCTAssertThrowsError(
            try AetherSSHPrivateKeyDocument.decode(
                data: Data("~/.ssh/id_ed25519".utf8)
            )
        ) { error in
            XCTAssertEqual(
                error as? AetherSSHPrivateKeyError,
                .unsupportedFormat
            )
        }
        XCTAssertThrowsError(
            try AetherSSHPrivateKeyDocument.decode(
                data: Data(
                    repeating: 0x41,
                    count: AetherSSHPrivateKeyDocument.maximumBytes + 1
                )
            )
        )
    }

    func testSSHPrivateKeyPassphraseCompilesInlineAndRoundTrips() throws {
        let node = AetherNode(
            name: "SSH Key",
            protocolID: .ssh,
            server: "ssh.example",
            port: 22,
            username: "user",
            privateKey: openSSHPrivateKey,
            privateKeyPassphrase: "test-passphrase"
        )

        let yaml = try AetherNodeProfileCompiler.compile(node: node)
        XCTAssertTrue(yaml.contains("private-key: |-"))
        XCTAssertTrue(
            yaml.contains("private-key-passphrase: 'test-passphrase'")
        )
        let data = try JSONEncoder().encode(node)
        XCTAssertEqual(try JSONDecoder().decode(AetherNode.self, from: data), node)
    }

    func testDialerProxyCompilesValidatesAndMaintainsBackwardCompatibility() throws {
        var chainedNode = AetherNode(
            name: "Landing-JP",
            protocolID: .socks5,
            server: "landing.example",
            port: 1080,
            username: "user",
            password: "password",
            dialerProxy: "Relay-HK-01"
        )
        let yaml = try AetherNodeProfileCompiler.compile(node: chainedNode)
        XCTAssertTrue(yaml.contains("dialer-proxy: 'Relay-HK-01'"))
        try ProfileImportValidator.validate(data: Data(yaml.utf8))

        // Self-reference must be rejected
        chainedNode.dialerProxy = "Landing-JP"
        XCTAssertThrowsError(try chainedNode.validated()) { error in
            XCTAssertEqual(
                error as? AetherNodeValidationError,
                .invalidField("Dialer proxy")
            )
        }

        // Reserved target names must be rejected
        for reserved in ["DIRECT", "direct", "REJECT", "GLOBAL"] {
            chainedNode.dialerProxy = reserved
            XCTAssertThrowsError(try chainedNode.validated()) { error in
                XCTAssertEqual(
                    error as? AetherNodeValidationError,
                    .invalidField("Dialer proxy")
                )
            }
        }

        // Legacy JSON without dialerProxy key must decode cleanly with dialerProxy == nil
        let legacyNode = AetherNode(
            name: "Legacy-SS",
            protocolID: .shadowsocks,
            server: "ss.example",
            port: 8388,
            password: "secret",
            cipher: "aes-128-gcm",
            dialerProxy: nil
        )
        var jsonObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacyNode)) as? [String: Any]
        )
        jsonObject.removeValue(forKey: "dialerProxy")
        let strippedData = try JSONSerialization.data(withJSONObject: jsonObject)
        let decodedLegacy = try JSONDecoder().decode(AetherNode.self, from: strippedData)
        XCTAssertNil(decodedLegacy.dialerProxy)
        XCTAssertEqual(decodedLegacy.name, "Legacy-SS")
    }

    func testNodeURIParserParsesAndFormatsMainstreamShareLinks() throws {
        let vlessURI = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@vless.example:443?security=reality&sni=www.cloudflare.com&pbk=BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc&sid=0123456789abcdef&fp=chrome&type=tcp&flow=xtls-rprx-vision#Tokyo-Reality"
        let vlessNode = try AetherNodeURIParser.parse(vlessURI)
        XCTAssertEqual(vlessNode.name, "Tokyo-Reality")
        XCTAssertEqual(vlessNode.protocolID, .vless)
        XCTAssertEqual(vlessNode.server, "vless.example")
        XCTAssertEqual(vlessNode.port, 443)
        XCTAssertEqual(vlessNode.uuid, "b831381d-6324-4d53-ad4f-8cda48b30811")
        XCTAssertEqual(vlessNode.flow, "xtls-rprx-vision")
        XCTAssertTrue(vlessNode.tls.enabled)
        XCTAssertEqual(vlessNode.tls.serverName, "www.cloudflare.com")
        XCTAssertEqual(vlessNode.tls.realityPublicKey, "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc")
        XCTAssertEqual(vlessNode.tls.realityShortID, "0123456789abcdef")
        XCTAssertEqual(vlessNode.tls.clientFingerprint, "chrome")
        try ProfileImportValidator.validate(data: Data(AetherNodeProfileCompiler.compile(node: vlessNode).utf8))

        let trojanURI = "trojan://my-secret-pass@trojan.example:8443?sni=cdn.trojan.example&type=ws&host=ws.trojan.example&path=%2Fws-path&allowInsecure=1#SG-Trojan-WS"
        let trojanNode = try AetherNodeURIParser.parse(trojanURI)
        XCTAssertEqual(trojanNode.name, "SG-Trojan-WS")
        XCTAssertEqual(trojanNode.protocolID, .trojan)
        XCTAssertEqual(trojanNode.password, "my-secret-pass")
        XCTAssertEqual(trojanNode.transport.kind, .webSocket)
        XCTAssertEqual(trojanNode.transport.host, "ws.trojan.example")
        XCTAssertEqual(trojanNode.transport.path, "/ws-path")
        XCTAssertTrue(trojanNode.tls.skipCertificateVerification)
        try ProfileImportValidator.validate(data: Data(AetherNodeProfileCompiler.compile(node: trojanNode).utf8))

        let ssCreds = Data("2022-blake3-aes-128-gcm:ss-secret-key".utf8).base64EncodedString()
        let ssURI = "ss://\(ssCreds)@ss.example:8388#HK-SS2022"
        let ssNode = try AetherNodeURIParser.parse(ssURI)
        XCTAssertEqual(ssNode.name, "HK-SS2022")
        XCTAssertEqual(ssNode.protocolID, .shadowsocks)
        XCTAssertEqual(ssNode.cipher, "2022-blake3-aes-128-gcm")
        XCTAssertEqual(ssNode.password, "ss-secret-key")
        try ProfileImportValidator.validate(data: Data(AetherNodeProfileCompiler.compile(node: ssNode).utf8))

        let hy2URI = "hy2://hy2-pass@hy2.example:443?sni=hy2.example&obfs=salamander&obfs-password=obfs-secret&upmbps=50&downmbps=300#US-Hy2"
        let hy2Node = try AetherNodeURIParser.parse(hy2URI)
        XCTAssertEqual(hy2Node.name, "US-Hy2")
        XCTAssertEqual(hy2Node.protocolID, .hysteria2)
        XCTAssertEqual(hy2Node.password, "hy2-pass")
        XCTAssertEqual(hy2Node.obfuscation, "salamander")
        XCTAssertEqual(hy2Node.obfuscationPassword, "obfs-secret")
        XCTAssertEqual(hy2Node.uploadMbps, 50)
        XCTAssertEqual(hy2Node.downloadMbps, 300)
        try ProfileImportValidator.validate(data: Data(AetherNodeProfileCompiler.compile(node: hy2Node).utf8))

        let tuicURI = "tuic://b831381d-6324-4d53-ad4f-8cda48b30811:tuic-pass@tuic.example:443?sni=tuic.example&congestion_control=bbr&udp_relay_mode=native#JP-TUIC"
        let tuicNode = try AetherNodeURIParser.parse(tuicURI)
        XCTAssertEqual(tuicNode.name, "JP-TUIC")
        XCTAssertEqual(tuicNode.protocolID, .tuic)
        XCTAssertEqual(tuicNode.uuid, "b831381d-6324-4d53-ad4f-8cda48b30811")
        XCTAssertEqual(tuicNode.password, "tuic-pass")
        XCTAssertEqual(tuicNode.congestionController, "bbr")
        XCTAssertEqual(tuicNode.udpRelayMode, "native")
        try ProfileImportValidator.validate(data: Data(AetherNodeProfileCompiler.compile(node: tuicNode).utf8))

        let vmessJSON = """
        {"v":"2","ps":"KR-VMess","add":"vmess.example","port":"443","id":"b831381d-6324-4d53-ad4f-8cda48b30811","aid":"0","scy":"auto","net":"ws","type":"none","host":"cdn.vmess.example","path":"/vmess","tls":"tls","sni":"vmess.example"}
        """
        let vmessURI = "vmess://\(Data(vmessJSON.utf8).base64EncodedString())"
        let vmessNode = try AetherNodeURIParser.parse(vmessURI)
        XCTAssertEqual(vmessNode.name, "KR-VMess")
        XCTAssertEqual(vmessNode.protocolID, .vmess)
        XCTAssertEqual(vmessNode.server, "vmess.example")
        XCTAssertEqual(vmessNode.port, 443)
        XCTAssertEqual(vmessNode.transport.kind, .webSocket)
        XCTAssertEqual(vmessNode.transport.host, "cdn.vmess.example")
        XCTAssertEqual(vmessNode.transport.path, "/vmess")
        XCTAssertTrue(vmessNode.tls.enabled)
        try ProfileImportValidator.validate(data: Data(AetherNodeProfileCompiler.compile(node: vmessNode).utf8))

        // Round-trip formatting and parsing
        for node in [vlessNode, trojanNode, ssNode, hy2Node, tuicNode, vmessNode] {
            let formatted = try AetherNodeURIParser.format(node)
            let reparsed = try AetherNodeURIParser.parse(formatted)
            XCTAssertEqual(reparsed.protocolID, node.protocolID)
            XCTAssertEqual(reparsed.server, node.server)
            XCTAssertEqual(reparsed.port, node.port)
            XCTAssertEqual(reparsed.name, node.name)
        }
    }

    func testNodeURIParserRejectsOversizedAndInjectedLinks() {
        let oversized = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443#" + String(repeating: "a", count: 5000)
        XCTAssertThrowsError(try AetherNodeURIParser.parse(oversized))
        XCTAssertThrowsError(try AetherNodeURIParser.parse("unknown://example.com:443"))
        XCTAssertThrowsError(try AetherNodeURIParser.parse("trojan://pass@bad.example\nrules::443#Injected"))
    }

    private static func makeNodes() -> [AetherNode] {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        return [
            AetherNode(
                name: "HTTP",
                protocolID: .http,
                server: "http.example",
                port: 443,
                username: "user",
                password: "password",
                tls: AetherNodeTLS(enabled: true, serverName: "http.example")
            ),
            AetherNode(
                name: "SOCKS5",
                protocolID: .socks5,
                server: "socks.example",
                port: 1080,
                username: "user",
                password: "password"
            ),
            AetherNode(
                name: "Shadowsocks",
                protocolID: .shadowsocks,
                server: "ss.example",
                port: 8388,
                password: "password",
                cipher: "aes-128-gcm"
            ),
            AetherNode(
                name: "VMess",
                protocolID: .vmess,
                server: "vmess.example",
                port: 443,
                uuid: uuid,
                tls: AetherNodeTLS(enabled: true, serverName: "vmess.example"),
                transport: AetherNodeTransportOptions(
                    kind: .webSocket,
                    path: "/ws",
                    host: "cdn.example"
                )
            ),
            AetherNode(
                name: "VLESS",
                protocolID: .vless,
                server: "vless.example",
                port: 443,
                uuid: uuid,
                tls: AetherNodeTLS(
                    enabled: true,
                    serverName: "vless.example",
                    realityPublicKey: "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc",
                    realityShortID: "0123456789abcdef"
                ),
                transport: AetherNodeTransportOptions(
                    kind: .grpc,
                    grpcServiceName: "route"
                ),
                flow: "xtls-rprx-vision"
            ),
            AetherNode(
                name: "Trojan",
                protocolID: .trojan,
                server: "trojan.example",
                port: 443,
                password: "password",
                tls: AetherNodeTLS(serverName: "trojan.example")
            ),
            AetherNode(
                name: "Hysteria2",
                protocolID: .hysteria2,
                server: "hy2.example",
                port: 443,
                password: "password",
                tls: AetherNodeTLS(serverName: "hy2.example"),
                obfuscation: "salamander",
                obfuscationPassword: "obfs-password",
                uploadMbps: 30,
                downloadMbps: 200
            ),
            AetherNode(
                name: "TUIC",
                protocolID: .tuic,
                server: "tuic.example",
                port: 443,
                password: "password",
                uuid: uuid,
                tls: AetherNodeTLS(serverName: "tuic.example"),
                congestionController: "bbr",
                udpRelayMode: "native"
            ),
            AetherNode(
                name: "AnyTLS",
                protocolID: .anyTLS,
                server: "anytls.example",
                port: 443,
                password: "password",
                tls: AetherNodeTLS(serverName: "anytls.example")
            ),
            AetherNode(
                name: "WireGuard",
                protocolID: .wireGuard,
                server: "wg.example",
                port: 51820,
                privateKey: "CH7G4Uu+0hDnIVzcc0aN+iPwgKG/uGZbL9gJvZnSg3k=",
                publicKey: "xMjphMUyLIGExyJluSslD9tjaIcF9QS6ADyI8DOTzyg=",
                localAddress: "10.0.0.2/32",
                localIPv6Address: "fd00::2/128",
                allowedIPs: ["0.0.0.0/0", "::/0"],
                mtu: 1280
            ),
            AetherNode(
                name: "SSH",
                protocolID: .ssh,
                server: "ssh.example",
                port: 22,
                username: "user",
                password: "password"
            ),
            AetherNode(
                name: "ShadowQUIC",
                protocolID: .shadowQUIC,
                server: "shadowquic.example",
                port: 443,
                username: "user",
                password: "password",
                tls: AetherNodeTLS(serverName: "shadowquic.example"),
                congestionController: "bbr",
                mtu: 1300
            ),
        ]
    }
}

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
        let relay = AetherNode(
            name: "Relay-HK-01",
            protocolID: .socks5,
            server: "relay.example",
            port: 1080
        )
        let yaml = try AetherNodeProfileCompiler.compile(nodes: [chainedNode, relay])
        XCTAssertTrue(yaml.contains("dialer-proxy: 'Relay-HK-01'"))
        try ProfileImportValidator.validate(data: Data(yaml.utf8))
        XCTAssertNoThrow(try AetherNodeProfileCompiler.validateDialerProxies(in: [chainedNode, relay]))

        // The core fails the whole profile ("connector … not found") when a
        // dialer names nothing in it, so saving such a node must be refused.
        XCTAssertThrowsError(try AetherNodeProfileCompiler.validateDialerProxies(in: [chainedNode])) { error in
            XCTAssertEqual(
                error as? AetherNodeProfileCompilerError,
                .unknownDialerProxy(node: "Landing-JP", dialer: "Relay-HK-01")
            )
        }
        var viaGroup = chainedNode
        viaGroup.dialerProxy = AetherNodeProfileCompiler.groupName
        XCTAssertThrowsError(try AetherNodeProfileCompiler.validateDialerProxies(in: [viaGroup, relay]))
        // Stored profiles still compile unchanged, so loading old data never fails.
        XCTAssertNoThrow(try AetherNodeProfileCompiler.compile(node: chainedNode))

        // Imported links keep their nodes; only dangling dialers are dropped.
        var foreign = relay
        foreign.dialerProxy = "Only-In-Another-Client"
        let imported = AetherNodeProfileCompiler.removingUnresolvedDialerProxies(
            from: [chainedNode, foreign]
        )
        XCTAssertEqual(imported.removed, 1)
        XCTAssertEqual(imported.nodes.map(\.dialerProxy), ["Relay-HK-01", nil])
        XCTAssertNoThrow(try AetherNodeProfileCompiler.validateDialerProxies(in: imported.nodes))

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

    func testNodeURIParserSupportsM4ShareLinksAndSurgeLines() throws {
        let ssrPass = Data("ssr-secret".utf8).base64EncodedString()
        let ssrObfsParam = Data("cloudflare.com".utf8).base64EncodedString()
        let ssrProtoParam = Data("32:user".utf8).base64EncodedString()
        let ssrRemarks = Data("SSR-HK".utf8).base64EncodedString()
        let ssrRaw = "ssr.example:8388:auth_aes128_md5:aes-256-cfb:tls1.2_ticket_auth:\(ssrPass)/?obfsparam=\(ssrObfsParam)&protoparam=\(ssrProtoParam)&remarks=\(ssrRemarks)"
        let ssrURI = "ssr://\(Data(ssrRaw.utf8).base64EncodedString())"
        let ssrNode = try AetherNodeURIParser.parse(ssrURI)
        XCTAssertEqual(ssrNode.protocolID, .shadowsocksR)
        XCTAssertEqual(ssrNode.name, "SSR-HK")
        XCTAssertEqual(ssrNode.cipher, "aes-256-cfb")
        XCTAssertEqual(ssrNode.ssrProtocol, "auth_aes128_md5")
        XCTAssertEqual(ssrNode.ssrObfs, "tls1.2_ticket_auth")
        XCTAssertEqual(ssrNode.ssrObfsParam, "cloudflare.com")
        XCTAssertEqual(ssrNode.ssrProtocolParam, "32:user")

        let hy1URI = "hysteria://hy1.example:443?protocol=wechat-video&auth=hy1-secret&peer=hy1.example&upmbps=40&downmbps=200&alpn=h3&obfs=xplus&obfsParam=xplus-key#Hy1-Node"
        let hy1Node = try AetherNodeURIParser.parse(hy1URI)
        XCTAssertEqual(hy1Node.protocolID, .hysteria)
        XCTAssertEqual(hy1Node.hysteriaProtocol, "wechat-video")
        XCTAssertEqual(hy1Node.password, "hy1-secret")
        XCTAssertEqual(hy1Node.obfuscation, "xplus")
        XCTAssertEqual(hy1Node.obfuscationPassword, "xplus-key")

        let tuicV4URI = "tuic://tuic-v4-token@tuic4.example:443?sni=tuic4.example&version=4&congestion_control=bbr&udp_relay_mode=quic#TUIC-v4"
        let tuicV4Node = try AetherNodeURIParser.parse(tuicV4URI)
        XCTAssertEqual(tuicV4Node.protocolID, .tuic)
        XCTAssertEqual(tuicV4Node.tuicToken, "tuic-v4-token")
        XCTAssertEqual(tuicV4Node.tuicVersion, 4)

        let vlessXhttpURI = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@vless.example:443?security=tls&sni=vless.example&type=xhttp&path=%2Fxhttp&host=cdn.vless.example&mode=stream-one&encryption=mlkem768x25519plus.native.0rtt#VLESS-XHTTP"
        let vlessXhttpNode = try AetherNodeURIParser.parse(vlessXhttpURI)
        XCTAssertEqual(vlessXhttpNode.protocolID, .vless)
        XCTAssertEqual(vlessXhttpNode.transport.kind, .xhttp)
        XCTAssertEqual(vlessXhttpNode.transport.path, "/xhttp")
        XCTAssertEqual(vlessXhttpNode.transport.xhttpMode, "stream-one")
        XCTAssertEqual(vlessXhttpNode.vlessEncryption, "mlkem768x25519plus.native.0rtt")

        let snellURI = "snell://snell-psk@snell.example:8443?version=4&obfs=tls&obfs-host=cdn.snell.example&reuse=true&tfo=1#Snell-v4"
        let snellNode = try AetherNodeURIParser.parse(snellURI)
        XCTAssertEqual(snellNode.protocolID, .snell)
        XCTAssertEqual(snellNode.snellVersion, 4)
        XCTAssertEqual(snellNode.obfuscation, "tls")
        XCTAssertEqual(snellNode.snellObfsHost, "cdn.snell.example")
        XCTAssertTrue(snellNode.snellReuse)
        XCTAssertTrue(snellNode.fastOpen)

        let mieruURI = "mieru://mieru-user:mieru-pass@mieru.example:8443?transport=TCP&port-range=8443-8445&multiplexing=MULTIPLEXING_HIGH&handshake-mode=HANDSHAKE_NO_WAIT#Mieru-TCP"
        let mieruNode = try AetherNodeURIParser.parse(mieruURI)
        XCTAssertEqual(mieruNode.protocolID, .mieru)
        XCTAssertEqual(mieruNode.mieruTransport, "TCP")
        XCTAssertEqual(mieruNode.mieruPortRange, "8443-8445")
        XCTAssertEqual(mieruNode.mieruMultiplexing, "MULTIPLEXING_HIGH")
        XCTAssertEqual(mieruNode.mieruHandshakeMode, "HANDSHAKE_NO_WAIT")

        for node in [ssrNode, hy1Node, tuicV4Node, vlessXhttpNode, snellNode, mieruNode] {
            let formatted = try AetherNodeURIParser.format(node)
            let reparsed = try AetherNodeURIParser.parse(formatted)
            XCTAssertEqual(reparsed.protocolID, node.protocolID)
            XCTAssertEqual(reparsed.server, node.server)
            XCTAssertEqual(reparsed.port, node.port)
            XCTAssertEqual(reparsed.name, node.name)
            let yaml = try AetherNodeProfileCompiler.compile(node: reparsed)
            try ProfileImportValidator.validate(data: Data(yaml.utf8))
        }

        let surgeSnell = try XCTUnwrap(
            AetherNodeURIParser.parseSurgeProxyLine(
                "HK-Snell = snell, snell.example, 8443, psk=snell-psk, obfs=tls, obfs-host=cdn.snell.example, version=4, reuse=true, tfo=true"
            )
        )
        XCTAssertEqual(surgeSnell.protocolID, .snell)
        XCTAssertEqual(surgeSnell.name, "HK-Snell")
        XCTAssertEqual(surgeSnell.snellVersion, 4)
        XCTAssertEqual(surgeSnell.obfuscation, "tls")
        XCTAssertTrue(surgeSnell.fastOpen)
    }

    func testLegacyV1NodeJSONDecodesCleanlyWithDefaultV2Fields() throws {
        let legacyJSON = """
        {
          "allowedIPs": ["0.0.0.0/0"],
          "alterID": 0,
          "cipher": "aes-128-gcm",
          "congestionController": "bbr",
          "downloadMbps": 100,
          "flow": "",
          "formatVersion": 1,
          "id": "11111111-2222-3333-4444-555555555555",
          "localAddress": "10.0.0.2/32",
          "localIPv6Address": "",
          "mtu": 1280,
          "name": "Legacy-1.x-Node",
          "obfuscation": "",
          "obfuscationPassword": "",
          "password": "secret",
          "port": 8388,
          "preSharedKey": "",
          "privateKey": "",
          "privateKeyPassphrase": "",
          "protocolID": "shadowsocks",
          "publicKey": "",
          "reservedBytes": [],
          "server": "ss.example",
          "tls": {
            "certificatePinSHA256": "",
            "clientFingerprint": "chrome",
            "enabled": false,
            "realityPublicKey": "",
            "realityShortID": "",
            "serverName": "",
            "skipCertificateVerification": false
          },
          "transport": {
            "grpcServiceName": "GunService",
            "host": "",
            "kind": "tcp",
            "path": "/"
          },
          "udp": true,
          "udpRelayMode": "native",
          "uploadMbps": 20,
          "username": "",
          "uuid": ""
        }
        """
        let decoded = try JSONDecoder().decode(AetherNode.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.name, "Legacy-1.x-Node")
        XCTAssertEqual(decoded.protocolID, .shadowsocks)
        XCTAssertEqual(decoded.transport.xhttpMode, "")
        XCTAssertFalse(decoded.fastOpen)
        XCTAssertTrue(decoded.amneziaWG.isEmpty)
        XCTAssertNoThrow(try decoded.validated())
    }

    func testNodeURIParserRejectsOversizedAndInjectedLinks() {
        let oversized = "vless://b831381d-6324-4d53-ad4f-8cda48b30811@example.com:443#" + String(repeating: "a", count: 5000)
        XCTAssertThrowsError(try AetherNodeURIParser.parse(oversized))
        XCTAssertThrowsError(try AetherNodeURIParser.parse("unknown://example.com:443"))
        XCTAssertThrowsError(try AetherNodeURIParser.parse("trojan://pass@bad.example\nrules::443#Injected"))
    }

    func testNodeURIParserStripsIPv6BracketsAndRoundTrips() throws {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        // URLComponents keeps the brackets in `host`; a bracketed server is
        // resolved as a hostname by the core and never connects.
        for uri in [
            "vless://\(uuid)@[2001:db8::1]:443?security=tls&sni=example.com#v6",
            "trojan://secret@[2001:db8::1]:443#v6",
            "ss://YWVzLTEyOC1nY206c2VjcmV0@[2001:db8::1]:8388#v6",
        ] {
            let node = try AetherNodeURIParser.parse(uri)
            XCTAssertEqual(node.server, "2001:db8::1", uri)
            let exported = try AetherNodeURIParser.format(node)
            XCTAssertTrue(exported.contains("@[2001:db8::1]:"), exported)
            XCTAssertEqual(try AetherNodeURIParser.parse(exported).server, "2001:db8::1")
        }
    }

    func testNodeURIParserDecodesNameOnce() throws {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        // URLComponents.fragment is already decoded; decoding again turned
        // "50% off" into nil and replaced the name with "VLESS-example.com".
        let node = try AetherNodeURIParser.parse(
            "vless://\(uuid)@example.com:443?security=tls#50%25%20off"
        )
        XCTAssertEqual(node.name, "50% off")
        let roundTripped = try AetherNodeURIParser.parse(AetherNodeURIParser.format(node))
        XCTAssertEqual(roundTripped.name, "50% off")
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
            AetherNode(
                name: "ShadowsocksR",
                protocolID: .shadowsocksR,
                server: "ssr.example",
                port: 8388,
                password: "password",
                cipher: "aes-256-cfb",
                ssrProtocol: "auth_aes128_md5",
                ssrProtocolParam: "32:user",
                ssrObfs: "tls1.2_ticket_auth",
                ssrObfsParam: "cloudflare.com"
            ),
            AetherNode(
                name: "Hysteria",
                protocolID: .hysteria,
                server: "hy1.example",
                port: 443,
                password: "hy1-password",
                tls: AetherNodeTLS(serverName: "hy1.example"),
                uploadMbps: 40,
                downloadMbps: 200,
                hysteriaProtocol: "udp"
            ),
            AetherNode(
                name: "Snell",
                protocolID: .snell,
                server: "snell.example",
                port: 8443,
                password: "snell-password",
                obfuscation: "tls",
                snellVersion: 4,
                snellObfsHost: "snell.example",
                snellReuse: true
            ),
            AetherNode(
                name: "Mieru",
                protocolID: .mieru,
                server: "mieru.example",
                port: 8443,
                username: "user",
                password: "password",
                mieruTransport: "TCP",
                mieruMultiplexing: "MULTIPLEXING_HIGH",
                mieruHandshakeMode: "HANDSHAKE_STANDARD"
            ),
        ]
    }
}

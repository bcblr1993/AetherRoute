import Foundation

private struct CompatibilityMatrix: Decodable {
    struct Case: Decodable {
        let id: String
        let `protocol`: String
        let variant: String
        let source: URL
    }

    let schemaVersion: Int
    let cases: [Case]
}

private struct Fixture {
    let shareLink: String
    let expectedYAMLFragments: [String]
}

@main
enum ProtocolInputCompatibilityVerifier {
    private static let uuid = "11111111-2222-3333-4444-555555555555"
    private static let key = Data(repeating: 7, count: 32).base64EncodedString()
    private static let urlKey = key
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")

    static func main() {
        do {
            try run()
        } catch {
            fputs("protocol input matrix failed: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count == 2 else {
            fputs("usage: protocol_input_verifier MATRIX_JSON OUTPUT_DIRECTORY\n", stderr)
            exit(64)
        }
        let matrixURL = URL(fileURLWithPath: arguments[0])
        let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
        let matrix = try JSONDecoder().decode(
            CompatibilityMatrix.self,
            from: Data(contentsOf: matrixURL, options: [.mappedIfSafe])
        )
        guard matrix.schemaVersion == 1, !matrix.cases.isEmpty else {
            throw VerificationError.invalidMatrix
        }
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        var identifiers = Set<String>()
        var protocols = Set<String>()
        for testCase in matrix.cases {
            guard identifiers.insert(testCase.id).inserted,
                  testCase.id.range(
                      of: "^[a-z0-9]+(?:-[a-z0-9]+)*$",
                      options: .regularExpression
                  ) != nil,
                  testCase.source.scheme == "https",
                  !testCase.variant.isEmpty else {
                throw VerificationError.invalidCase(testCase.id)
            }
            let fixture = try fixture(for: testCase.id)
            let result = try SubscriptionPayloadNormalizer.normalizeWithReport(
                Data(fixture.shareLink.utf8)
            )
            guard result.report == SubscriptionPayloadReport(
                usableNodeCount: 1,
                skippedNodeCount: 0
            ), let yaml = String(data: result.data, encoding: .utf8) else {
                throw VerificationError.normalization(testCase.id)
            }
            let expectedCoreType = testCase.protocol == "shadowsocks"
                ? "ss" : testCase.protocol
            for fragment in ["type: '\(expectedCoreType)'"]
                + fixture.expectedYAMLFragments {
                guard yaml.contains(fragment) else {
                    throw VerificationError.missingFragment(
                        testCase.id,
                        fragment
                    )
                }
            }
            let outputURL = outputDirectory
                .appendingPathComponent(testCase.id)
                .appendingPathExtension("yaml")
            try result.data.write(to: outputURL, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: outputURL.path
            )
            protocols.insert(testCase.protocol)
        }

        let knownFixtures = Set(try allFixtureIdentifiers())
        guard knownFixtures == identifiers else {
            throw VerificationError.fixtureCoverage(
                missing: identifiers.subtracting(knownFixtures).sorted(),
                extra: knownFixtures.subtracting(identifiers).sorted()
            )
        }
        guard protocols == Set(AetherNodeProtocol.allCases.map(\.rawValue)) else {
            throw VerificationError.protocolCoverage(protocols.sorted())
        }
        print(
            "Protocol inputs generated: cases=\(matrix.cases.count) "
                + "protocols=\(protocols.count) sources=https-only"
        )
    }

    private static func allFixtureIdentifiers() throws -> [String] {
        [
            "http-plain-anonymous", "http-plain-basic", "http-tls-basic",
            "http-ipv6", "socks5-anonymous", "socks5-userpass",
            "socks-alias-ipv6", "ss-sip002-aes128gcm",
            "ss-sip002-chacha20", "ss-sip002-2022-plain",
            "ss-legacy-whole-base64", "ss-empty-query-provider", "ss-ipv6",
            "vmess-tcp-aead", "vmess-tcp-tls", "vmess-ws-tls",
            "vmess-grpc-tls", "vmess-h2-tls", "vmess-cipher-aes128gcm",
            "vmess-cipher-chacha20", "vmess-url-safe-unpadded",
            "vless-tcp-private", "vless-tcp-tls", "vless-reality-vision",
            "vless-ws-tls", "vless-grpc-tls", "vless-h2-tls",
            "vless-query-aliases", "vless-ipv6", "trojan-tcp-tls",
            "trojan-ws-tls", "trojan-grpc-tls", "trojan-percent-password",
            "hy2-standard", "hy2-alias", "hy2-salamander", "hy2-bandwidth",
            "tuic-native-bbr", "tuic-quic-cubic", "tuic-newreno-aliases",
            "anytls-standard", "anytls-insecure-alias", "wireguard-ipv4",
            "wireguard-dualstack-psk", "ssh-password",
            "ssh-percent-credentials", "shadowquic-bbr", "shadowquic-cubic",
        ]
    }

    private static func fixture(for id: String) throws -> Fixture {
        switch id {
        case "http-plain-anonymous":
            return fixture("http://127.0.0.1:18080#HTTP", [])
        case "http-plain-basic":
            return fixture(
                "http://user:p%40ss@127.0.0.1:18080#HTTP-Basic",
                ["username: 'user'", "password: 'p@ss'"]
            )
        case "http-tls-basic":
            return fixture(
                "https://user:secret@127.0.0.1:18443#HTTPS",
                ["tls: true"]
            )
        case "http-ipv6":
            return fixture("http://[::1]:18080#HTTP-v6", ["server: '::1'"])
        case "socks5-anonymous":
            return fixture("socks5://127.0.0.1:11080#SOCKS5", [])
        case "socks5-userpass":
            return fixture(
                "socks5://user:p%40ss@127.0.0.1:11080#SOCKS5-Auth",
                ["username: 'user'", "password: 'p@ss'"]
            )
        case "socks-alias-ipv6":
            return fixture("socks://user:secret@[::1]:11080#SOCKS-v6", ["server: '::1'"])
        case "ss-sip002-aes128gcm":
            return shadowsocks(
                method: "aes-128-gcm",
                password: "secret",
                endpoint: "127.0.0.1:18388",
                name: "SS-AES"
            )
        case "ss-sip002-chacha20":
            return shadowsocks(
                method: "chacha20-ietf-poly1305",
                password: "secret",
                endpoint: "127.0.0.1:18388",
                name: "SS-ChaCha"
            )
        case "ss-sip002-2022-plain":
            let password = Data(repeating: 3, count: 16).base64EncodedString()
            return fixture(
                "ss://2022-blake3-aes-128-gcm:\(percent(password))@127.0.0.1:18388#SS2022",
                ["cipher: '2022-blake3-aes-128-gcm'", "password: '\(password)'"]
            )
        case "ss-legacy-whole-base64":
            let body = Data(
                "aes-256-gcm:secret@127.0.0.1:18388".utf8
            ).base64EncodedString()
            return fixture(
                "ss://\(body)#SS-Legacy",
                ["cipher: 'aes-256-gcm'"]
            )
        case "ss-empty-query-provider":
            let base = shadowsocks(
                method: "aes-128-gcm",
                password: "secret",
                endpoint: "127.0.0.1:18388",
                name: "SS-Provider"
            )
            return Fixture(
                shareLink: base.shareLink.replacingOccurrences(
                    of: "#SS-Provider",
                    with: "?#SS-Provider"
                ),
                expectedYAMLFragments: base.expectedYAMLFragments
            )
        case "ss-ipv6":
            return shadowsocks(
                method: "aes-128-gcm",
                password: "secret",
                endpoint: "[::1]:18388",
                name: "SS-v6",
                extra: ["server: '::1'"]
            )
        case "vmess-tcp-aead":
            return vmess(name: "VMess-TCP", network: "tcp", tls: false)
        case "vmess-tcp-tls":
            return vmess(name: "VMess-TLS", network: "tcp", tls: true)
        case "vmess-ws-tls":
            return vmess(name: "VMess-WS", network: "ws", tls: true)
        case "vmess-grpc-tls":
            return vmess(name: "VMess-gRPC", network: "grpc", tls: true)
        case "vmess-h2-tls":
            return vmess(name: "VMess-H2", network: "h2", tls: true)
        case "vmess-cipher-aes128gcm":
            return vmess(
                name: "VMess-AES",
                network: "tcp",
                tls: true,
                cipher: "aes-128-gcm"
            )
        case "vmess-cipher-chacha20":
            return vmess(
                name: "VMess-ChaCha",
                network: "tcp",
                tls: true,
                cipher: "chacha20-poly1305"
            )
        case "vmess-url-safe-unpadded":
            return vmess(
                name: "VMess-URLSafe",
                network: "ws",
                tls: true,
                urlSafeUnpadded: true
            )
        case "vless-tcp-private":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=none&type=tcp#VLESS-Private",
                ["tls: false"]
            )
        case "vless-tcp-tls":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=tls&sni=edge.example&type=tcp#VLESS-TLS",
                ["tls: true", "sni: 'edge.example'"]
            )
        case "vless-reality-vision":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=reality&sni=edge.example&pbk=\(urlKey)&sid=abcd&fp=chrome&flow=xtls-rprx-vision&type=tcp#VLESS-Reality",
                ["reality-opts:", "flow: 'xtls-rprx-vision'", "client-fingerprint: 'chrome'"]
            )
        case "vless-ws-tls":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=tls&sni=edge.example&type=ws&path=%2Fvless&host=edge.example#VLESS-WS",
                ["network: 'ws'", "path: '/vless'", "Host: 'edge.example'"]
            )
        case "vless-grpc-tls":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=tls&sni=edge.example&type=grpc&serviceName=route#VLESS-gRPC",
                ["network: 'grpc'", "grpc-service-name: 'route'"]
            )
        case "vless-h2-tls":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=tls&sni=edge.example&type=http&path=%2Fh2&host=edge.example#VLESS-H2",
                ["network: 'h2'", "path: '/h2'"]
            )
        case "vless-query-aliases":
            return fixture(
                "vless://\(uuid)@127.0.0.1:1443?security=reality&peer=edge.example&publickey=\(urlKey)&shortid=a0b1&fingerprint=safari#VLESS-Aliases",
                ["sni: 'edge.example'", "short-id: 'a0b1'", "client-fingerprint: 'safari'"]
            )
        case "vless-ipv6":
            return fixture(
                "vless://\(uuid)@[::1]:1443?security=tls&sni=edge.example#VLESS-v6",
                ["server: '::1'"]
            )
        case "trojan-tcp-tls":
            return fixture(
                "trojan://secret@127.0.0.1:1443?sni=edge.example#Trojan",
                ["sni: 'edge.example'"]
            )
        case "trojan-ws-tls":
            return fixture(
                "trojan://secret@127.0.0.1:1443?sni=edge.example&type=ws&path=%2Ftrojan&host=edge.example#Trojan-WS",
                ["network: 'ws'", "path: '/trojan'"]
            )
        case "trojan-grpc-tls":
            return fixture(
                "trojan://secret@127.0.0.1:1443?sni=edge.example&type=grpc&serviceName=route#Trojan-gRPC",
                ["network: 'grpc'", "grpc-service-name: 'route'"]
            )
        case "trojan-percent-password":
            return fixture(
                "trojan://p%40ss%3Aword@127.0.0.1:1443?sni=edge.example#Trojan-Encoded",
                ["password: 'p@ss:word'"]
            )
        case "hy2-standard":
            return fixture(
                "hysteria2://secret@127.0.0.1:18443?sni=edge.example#HY2",
                ["sni: 'edge.example'"]
            )
        case "hy2-alias":
            return fixture(
                "hy2://secret@127.0.0.1:18443?peer=edge.example#HY2-Alias",
                ["sni: 'edge.example'"]
            )
        case "hy2-salamander":
            return fixture(
                "hysteria2://secret@127.0.0.1:18443?sni=edge.example&obfs=salamander&obfs-password=cover#HY2-Salamander",
                ["obfs: 'salamander'", "obfs-password: 'cover'"]
            )
        case "hy2-bandwidth":
            return fixture(
                "hysteria2://secret@127.0.0.1:18443?sni=edge.example&up=50&down=100#HY2-Bandwidth",
                ["up: 50", "down: 100"]
            )
        case "tuic-native-bbr":
            return fixture(
                "tuic://\(uuid):secret@127.0.0.1:18443?sni=edge.example&congestion-control=bbr&udp-relay-mode=native#TUIC-BBR",
                ["congestion-controller: 'bbr'", "udp-relay-mode: 'native'"]
            )
        case "tuic-quic-cubic":
            return fixture(
                "tuic://\(uuid):secret@127.0.0.1:18443?sni=edge.example&congestion-controller=cubic&udp-relay-mode=quic#TUIC-Cubic",
                ["congestion-controller: 'cubic'", "udp-relay-mode: 'quic'"]
            )
        case "tuic-newreno-aliases":
            return fixture(
                "tuic://\(uuid):secret@127.0.0.1:18443?peer=edge.example&congestion_control=new_reno&udp_relay_mode=native#TUIC-NewReno",
                ["congestion-controller: 'new_reno'", "udp-relay-mode: 'native'"]
            )
        case "anytls-standard":
            return fixture(
                "anytls://secret@127.0.0.1:1443?sni=edge.example#AnyTLS",
                ["sni: 'edge.example'"]
            )
        case "anytls-insecure-alias":
            return fixture(
                "anytls://secret@127.0.0.1:1443?peer=edge.example&allowInsecure=1#AnyTLS-Alias",
                ["sni: 'edge.example'", "skip-cert-verify: true"]
            )
        case "wireguard-ipv4":
            return wireGuard(dualStack: false)
        case "wireguard-dualstack-psk":
            return wireGuard(dualStack: true)
        case "ssh-password":
            return fixture(
                "ssh://user:secret@127.0.0.1:10022#SSH",
                ["username: 'user'", "password: 'secret'"]
            )
        case "ssh-percent-credentials":
            return fixture(
                "ssh://user%2Bops:p%40ss@[::1]:10022#SSH-v6",
                ["server: '::1'", "username: 'user+ops'", "password: 'p@ss'"]
            )
        case "shadowquic-bbr":
            return fixture(
                "shadowquic://user:secret@127.0.0.1:1443?sni=edge.example&congestion-control=bbr#ShadowQUIC-BBR",
                ["server-name: 'edge.example'", "congestion-control: 'bbr'"]
            )
        case "shadowquic-cubic":
            return fixture(
                "shadowquic://user:secret@127.0.0.1:1443?server-name=edge.example&congestion_control=cubic&initial-mtu=1400#ShadowQUIC-Cubic",
                ["congestion-control: 'cubic'", "initial-mtu: 1400"]
            )
        default:
            throw VerificationError.unknownFixture(id)
        }
    }

    private static func fixture(
        _ link: String,
        _ expected: [String]
    ) -> Fixture {
        Fixture(shareLink: link, expectedYAMLFragments: expected)
    }

    private static func shadowsocks(
        method: String,
        password: String,
        endpoint: String,
        name: String,
        extra: [String] = []
    ) -> Fixture {
        let userInfo = base64URL(Data("\(method):\(password)".utf8))
        return fixture(
            "ss://\(userInfo)@\(endpoint)#\(name)",
            ["cipher: '\(method)'", "password: '\(password)'"] + extra
        )
    }

    private static func vmess(
        name: String,
        network: String,
        tls: Bool,
        cipher: String = "auto",
        urlSafeUnpadded: Bool = false
    ) -> Fixture {
        let object: [String: Any] = [
            "v": "2", "ps": name, "add": "127.0.0.1", "port": "1443",
            "id": uuid, "aid": "0", "scy": cipher, "net": network,
            "host": "edge.example", "path": "/route",
            "serviceName": "route", "tls": tls ? "tls" : "",
            "sni": tls ? "edge.example" : "", "allowInsecure": false,
        ]
        let data = try! JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        let encoded = urlSafeUnpadded
            ? base64URL(data)
            : data.base64EncodedString()
        var expected = ["cipher: '\(cipher)'", "tls: \(tls ? "true" : "false")"]
        switch network {
        case "ws": expected += ["network: 'ws'", "path: '/route'"]
        case "grpc": expected += ["network: 'grpc'", "grpc-service-name: 'route'"]
        case "h2": expected += ["network: 'h2'", "path: '/route'"]
        default: break
        }
        return fixture("vmess://\(encoded)", expected)
    }

    private static func wireGuard(dualStack: Bool) -> Fixture {
        let privateKey = percent(key)
        let publicKey = percent(key)
        var query = "public-key=\(publicKey)&address=10.0.0.2%2F32&mtu=1280"
        var expected = ["ip: '10.0.0.2/32'", "mtu: 1280"]
        if dualStack {
            query += "&ipv6=fd00%3A%3A2%2F128&pre-shared-key=\(percent(key))"
                + "&allowed-ips=0.0.0.0%2F0%2C%3A%3A%2F0"
            expected += ["ipv6: 'fd00::2/128'", "pre-shared-key: '\(key)'"]
        } else {
            query += "&allowed-ips=0.0.0.0%2F0"
        }
        return fixture(
            "wireguard://\(privateKey)@127.0.0.1:51820?\(query)#WireGuard",
            expected
        )
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func percent(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed)
            ?? value
    }
}

private enum VerificationError: Error, CustomStringConvertible {
    case invalidMatrix
    case invalidCase(String)
    case unknownFixture(String)
    case normalization(String)
    case missingFragment(String, String)
    case fixtureCoverage(missing: [String], extra: [String])
    case protocolCoverage([String])

    var description: String {
        switch self {
        case .invalidMatrix: "invalid matrix header"
        case let .invalidCase(id): "invalid matrix case: \(id)"
        case let .unknownFixture(id): "unknown fixture: \(id)"
        case let .normalization(id): "normalization report failed: \(id)"
        case let .missingFragment(id, fragment):
            "compiled YAML for \(id) is missing \(fragment)"
        case let .fixtureCoverage(missing, extra):
            "fixture coverage mismatch missing=\(missing) extra=\(extra)"
        case let .protocolCoverage(protocols):
            "protocol coverage mismatch: \(protocols)"
        }
    }
}

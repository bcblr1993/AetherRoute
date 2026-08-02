import Foundation

@main
enum ManualNodeFixtureGenerator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw GeneratorError.usage
        }
        let outputDirectory = URL(
            fileURLWithPath: CommandLine.arguments[1],
            isDirectory: true
        ).standardizedFileURL
        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        for node in fixtures() {
            let yaml = try AetherNodeProfileCompiler.compile(node: node)
            let destination = outputDirectory.appendingPathComponent(
                "\(node.protocolID.rawValue).yaml",
                isDirectory: false
            )
            try Data(yaml.utf8).write(to: destination, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destination.path
            )
        }
    }

    private static func fixtures() -> [AetherNode] {
        let uuid = "b831381d-6324-4d53-ad4f-8cda48b30811"
        return [
            AetherNode(
                name: "HTTP", protocolID: .http,
                server: "127.0.0.1", port: 59001,
                username: "user", password: "password",
                tls: .init(enabled: true, serverName: "example.com")
            ),
            AetherNode(
                name: "SOCKS5", protocolID: .socks5,
                server: "127.0.0.1", port: 59002,
                username: "user", password: "password"
            ),
            AetherNode(
                name: "Shadowsocks", protocolID: .shadowsocks,
                server: "127.0.0.1", port: 59003,
                password: "password", cipher: "aes-128-gcm"
            ),
            AetherNode(
                name: "VMess", protocolID: .vmess,
                server: "127.0.0.1", port: 59004, uuid: uuid,
                tls: .init(enabled: true, serverName: "example.com"),
                transport: .init(kind: .webSocket, path: "/ws", host: "example.com")
            ),
            AetherNode(
                name: "VLESS", protocolID: .vless,
                server: "127.0.0.1", port: 59005, uuid: uuid,
                tls: .init(
                    enabled: true,
                    serverName: "example.com",
                    realityPublicKey: "EvM1bB3Z5vYQx_kYtJCmc3OZfYGSAL5dbjEqvOzdq00",
                    realityShortID: "0123456789abcdef"
                ),
                transport: .init(kind: .grpc, grpcServiceName: "route"),
                flow: "xtls-rprx-vision"
            ),
            AetherNode(
                name: "Trojan", protocolID: .trojan,
                server: "127.0.0.1", port: 59006, password: "password",
                tls: .init(serverName: "example.com")
            ),
            AetherNode(
                name: "Hysteria2", protocolID: .hysteria2,
                server: "127.0.0.1", port: 59007, password: "password",
                tls: .init(serverName: "example.com"),
                obfuscation: "salamander",
                obfuscationPassword: "obfs-password",
                uploadMbps: 30, downloadMbps: 200
            ),
            AetherNode(
                name: "TUIC", protocolID: .tuic,
                server: "127.0.0.1", port: 59008,
                password: "password", uuid: uuid,
                tls: .init(serverName: "example.com"),
                congestionController: "bbr", udpRelayMode: "native"
            ),
            AetherNode(
                name: "AnyTLS", protocolID: .anyTLS,
                server: "127.0.0.1", port: 59009, password: "password",
                tls: .init(serverName: "example.com")
            ),
            AetherNode(
                name: "WireGuard", protocolID: .wireGuard,
                server: "127.0.0.1", port: 59010,
                privateKey: "CH7G4Uu+0hDnIVzcc0aN+iPwgKG/uGZbL9gJvZnSg3k=",
                publicKey: "xMjphMUyLIGExyJluSslD9tjaIcF9QS6ADyI8DOTzyg=",
                localAddress: "10.0.0.2/32", localIPv6Address: "fd00::2/128",
                allowedIPs: ["0.0.0.0/0", "::/0"], mtu: 1280
            ),
            AetherNode(
                name: "SSH", protocolID: .ssh,
                server: "127.0.0.1", port: 59011,
                username: "user", password: "password"
            ),
            AetherNode(
                name: "ShadowQUIC", protocolID: .shadowQUIC,
                server: "127.0.0.1", port: 59012,
                username: "user", password: "password",
                tls: .init(serverName: "example.com"),
                congestionController: "bbr", mtu: 1300
            ),
        ]
    }
}

private enum GeneratorError: LocalizedError {
    case usage

    var errorDescription: String? {
        "usage: manual_node_fixture_generator OUTPUT_DIRECTORY"
    }
}

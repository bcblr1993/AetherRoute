import Foundation

public struct ProtocolCapability: Identifiable, Equatable, Sendable {
    public enum Readiness: String, Sendable {
        case planned
        case integration
        case verified
    }

    public let id: String
    public let displayName: String
    public let transports: [String]
    public let readiness: Readiness

    public init(
        id: String,
        displayName: String,
        transports: [String],
        readiness: Readiness
    ) {
        self.id = id
        self.displayName = displayName
        self.transports = transports
        self.readiness = readiness
    }
}

public enum ProtocolCatalog {
    public static let releaseTarget: [ProtocolCapability] = [
        .init(id: "http", displayName: "HTTP/HTTPS", transports: ["CONNECT", "TLS", "Basic Auth"], readiness: .integration),
        .init(id: "socks5", displayName: "SOCKS5", transports: ["TCP", "UDP"], readiness: .integration),
        .init(id: "shadowsocks", displayName: "Shadowsocks", transports: ["TCP", "UDP", "ShadowTLS"], readiness: .integration),
        .init(id: "vmess", displayName: "VMess", transports: ["TCP", "TLS", "WebSocket", "HTTP/2", "gRPC"], readiness: .integration),
        .init(id: "vless", displayName: "VLESS", transports: ["TLS", "REALITY", "WebSocket", "HTTP/2", "gRPC"], readiness: .integration),
        .init(id: "trojan", displayName: "Trojan", transports: ["TLS", "WebSocket", "gRPC"], readiness: .integration),
        .init(id: "hysteria2", displayName: "Hysteria2", transports: ["QUIC", "Salamander"], readiness: .integration),
        .init(id: "tuic", displayName: "TUIC v5", transports: ["QUIC", "TCP", "UDP Datagram", "UDP Stream"], readiness: .integration),
        .init(id: "anytls", displayName: "AnyTLS", transports: ["TLS"], readiness: .integration),
        .init(id: "wireguard", displayName: "WireGuard", transports: ["UDP"], readiness: .integration),
        .init(id: "ssh", displayName: "SSH", transports: ["TCP"], readiness: .integration),
        .init(id: "shadowquic", displayName: "ShadowQUIC", transports: ["QUIC"], readiness: .integration)
    ]

}

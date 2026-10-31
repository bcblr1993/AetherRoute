import Foundation

public enum AetherNodeProtocol: String, CaseIterable, Codable, Sendable {
    case http
    case socks5
    case shadowsocks
    case shadowsocksR = "ssr"
    case vmess
    case vless
    case trojan
    case hysteria
    case hysteria2
    case tuic
    case snell
    case mieru
    case anyTLS = "anytls"
    case wireGuard = "wireguard"
    case ssh
    case shadowQUIC = "shadowquic"

    public var displayName: String {
        switch self {
        case .http: "HTTP / HTTPS"
        case .socks5: "SOCKS5"
        case .shadowsocks: "Shadowsocks"
        case .shadowsocksR: "ShadowsocksR"
        case .vmess: "VMess"
        case .vless: "VLESS"
        case .trojan: "Trojan"
        case .hysteria: "Hysteria"
        case .hysteria2: "Hysteria2"
        case .tuic: "TUIC v5"
        case .snell: "Snell"
        case .mieru: "Mieru"
        case .anyTLS: "AnyTLS"
        case .wireGuard: "WireGuard"
        case .ssh: "SSH"
        case .shadowQUIC: "ShadowQUIC"
        }
    }

    fileprivate var coreType: String {
        self == .shadowsocks ? "ss" : rawValue
    }
}

public enum AetherNodeTransport: String, CaseIterable, Codable, Sendable {
    case tcp
    case webSocket = "ws"
    case http2 = "h2"
    case grpc
    case xhttp
}

public struct AetherNodeTLS: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var serverName: String
    public var skipCertificateVerification: Bool
    public var realityPublicKey: String
    public var realityShortID: String
    public var clientFingerprint: String
    /// SHA-256 of the server certificate (Mihomo `fingerprint`). Pinning it
    /// lets a self-signed server be used without skipping verification.
    public var certificateFingerprint: String

    public init(
        enabled: Bool = false,
        serverName: String = "",
        skipCertificateVerification: Bool = false,
        realityPublicKey: String = "",
        realityShortID: String = "",
        clientFingerprint: String = "chrome",
        certificateFingerprint: String = ""
    ) {
        self.enabled = enabled
        self.serverName = serverName
        self.skipCertificateVerification = skipCertificateVerification
        self.realityPublicKey = realityPublicKey
        self.realityShortID = realityShortID
        self.clientFingerprint = clientFingerprint
        self.certificateFingerprint = certificateFingerprint
    }

    // Nodes saved before 1.2.0 have no certificate fingerprint.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        serverName = try container.decode(String.self, forKey: .serverName)
        skipCertificateVerification = try container.decode(
            Bool.self,
            forKey: .skipCertificateVerification
        )
        realityPublicKey = try container.decode(String.self, forKey: .realityPublicKey)
        realityShortID = try container.decode(String.self, forKey: .realityShortID)
        clientFingerprint = try container.decode(String.self, forKey: .clientFingerprint)
        certificateFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .certificateFingerprint
        ) ?? ""
    }

    /// The fingerprint as 64 lowercase hex digits, or nil when it is not a
    /// SHA-256 (colons and either case are accepted, as in Mihomo).
    public static func normalizedCertificateFingerprint(_ value: String) -> String? {
        let hex = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ":", with: "")
            .lowercased()
        guard hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }
}

public struct AetherNodeTransportOptions: Codable, Equatable, Sendable {
    public var kind: AetherNodeTransport
    public var path: String
    public var host: String
    public var grpcServiceName: String
    /// V2Ray `httpupgrade` on a WebSocket transport: one HTTP upgrade, then
    /// raw bytes. Compiled to Mihomo's `ws-opts.v2ray-http-upgrade`.
    public var httpUpgrade: Bool
    /// XHTTP mode (`auto`, `packet-up`, `stream-up`, `stream-one`).
    public var xhttpMode: String

    public init(
        kind: AetherNodeTransport = .tcp,
        path: String = "",
        host: String = "",
        grpcServiceName: String = "",
        httpUpgrade: Bool = false,
        xhttpMode: String = ""
    ) {
        self.kind = kind
        self.path = path
        self.host = host
        self.grpcServiceName = grpcServiceName
        self.httpUpgrade = httpUpgrade
        self.xhttpMode = xhttpMode
    }

    private enum CodingKeys: String, CodingKey {
        case kind, path, host, grpcServiceName, httpUpgrade, xhttpMode
    }

    /// Nodes saved before `httpUpgrade` / `xhttpMode` existed have no such key.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decode(AetherNodeTransport.self, forKey: .kind)
        path = try container.decode(String.self, forKey: .path)
        host = try container.decode(String.self, forKey: .host)
        grpcServiceName = try container.decode(String.self, forKey: .grpcServiceName)
        httpUpgrade = try container.decodeIfPresent(Bool.self, forKey: .httpUpgrade) ?? false
        xhttpMode = try container.decodeIfPresent(String.self, forKey: .xhttpMode) ?? ""
    }
}

public struct AetherAmneziaWGOptions: Codable, Equatable, Sendable {
    public var jc: Int?
    public var jmin: Int?
    public var jmax: Int?
    public var s1: Int?
    public var s2: Int?
    public var h1: UInt32?
    public var h2: UInt32?
    public var h3: UInt32?
    public var h4: UInt32?

    public init(
        jc: Int? = nil,
        jmin: Int? = nil,
        jmax: Int? = nil,
        s1: Int? = nil,
        s2: Int? = nil,
        h1: UInt32? = nil,
        h2: UInt32? = nil,
        h3: UInt32? = nil,
        h4: UInt32? = nil
    ) {
        self.jc = jc
        self.jmin = jmin
        self.jmax = jmax
        self.s1 = s1
        self.s2 = s2
        self.h1 = h1
        self.h2 = h2
        self.h3 = h3
        self.h4 = h4
    }

    public var isEmpty: Bool {
        jc == nil && jmin == nil && jmax == nil && s1 == nil && s2 == nil
            && h1 == nil && h2 == nil && h3 == nil && h4 == nil
    }
}

/// AetherRoute's native node document. Imported YAML remains a supported input
/// adapter, but nodes created by the app are persisted in this bounded,
/// versioned model and compiled to the Rust core's configuration surface.
public struct AetherNode: Codable, Equatable, Identifiable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public var id: UUID
    public var name: String
    public var protocolID: AetherNodeProtocol
    public var server: String
    public var port: UInt16
    public var username: String
    public var password: String
    public var uuid: String
    public var cipher: String
    public var alterID: UInt16
    public var udp: Bool
    public var tls: AetherNodeTLS
    public var transport: AetherNodeTransportOptions
    public var flow: String
    public var vlessEncryption: String
    public var obfuscation: String
    public var obfuscationPassword: String
    public var uploadMbps: UInt64?
    public var downloadMbps: UInt64?
    public var congestionController: String
    public var udpRelayMode: String
    public var privateKey: String
    public var publicKey: String
    public var preSharedKey: String
    public var localAddress: String
    public var localIPv6Address: String
    public var allowedIPs: [String]
    public var mtu: UInt16?
    public var privateKeyPassphrase: String?
    public var dialerProxy: String?
    public var ssrProtocol: String
    public var ssrProtocolParam: String
    public var ssrObfs: String
    public var ssrObfsParam: String
    public var hysteriaProtocol: String
    public var hysteriaAuthBase64: String
    public var alpn: [String]
    public var tuicToken: String
    public var tuicVersion: UInt8?
    public var tuicReduceRTT: Bool
    public var snellVersion: Int?
    public var snellObfsHost: String
    public var snellReuse: Bool
    public var mieruTransport: String
    public var mieruMultiplexing: String
    public var mieruHandshakeMode: String
    public var mieruPortRange: String
    public var plugin: String
    public var pluginMode: String
    public var pluginHost: String
    public var pluginPath: String
    public var pluginPassword: String
    public var pluginVersion: Int?
    public var fastOpen: Bool
    public var amneziaWG: AetherAmneziaWGOptions

    public init(
        id: UUID = UUID(),
        name: String,
        protocolID: AetherNodeProtocol,
        server: String,
        port: UInt16,
        username: String = "",
        password: String = "",
        uuid: String = "",
        cipher: String = "",
        alterID: UInt16 = 0,
        udp: Bool = true,
        tls: AetherNodeTLS = .init(),
        transport: AetherNodeTransportOptions = .init(),
        flow: String = "",
        vlessEncryption: String = "",
        obfuscation: String = "",
        obfuscationPassword: String = "",
        uploadMbps: UInt64? = nil,
        downloadMbps: UInt64? = nil,
        congestionController: String = "",
        udpRelayMode: String = "",
        privateKey: String = "",
        publicKey: String = "",
        preSharedKey: String = "",
        localAddress: String = "",
        localIPv6Address: String = "",
        allowedIPs: [String] = [],
        mtu: UInt16? = nil,
        privateKeyPassphrase: String? = nil,
        dialerProxy: String? = nil,
        ssrProtocol: String = "",
        ssrProtocolParam: String = "",
        ssrObfs: String = "",
        ssrObfsParam: String = "",
        hysteriaProtocol: String = "",
        hysteriaAuthBase64: String = "",
        alpn: [String] = [],
        tuicToken: String = "",
        tuicVersion: UInt8? = nil,
        tuicReduceRTT: Bool = false,
        snellVersion: Int? = nil,
        snellObfsHost: String = "",
        snellReuse: Bool = false,
        mieruTransport: String = "",
        mieruMultiplexing: String = "",
        mieruHandshakeMode: String = "",
        mieruPortRange: String = "",
        plugin: String = "",
        pluginMode: String = "",
        pluginHost: String = "",
        pluginPath: String = "",
        pluginPassword: String = "",
        pluginVersion: Int? = nil,
        fastOpen: Bool = false,
        amneziaWG: AetherAmneziaWGOptions = .init()
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.id = id
        self.name = name
        self.protocolID = protocolID
        self.server = server
        self.port = port
        self.username = username
        self.password = password
        self.uuid = uuid
        self.cipher = cipher
        self.alterID = alterID
        self.udp = udp
        self.tls = tls
        self.transport = transport
        self.flow = flow
        self.vlessEncryption = vlessEncryption
        self.obfuscation = obfuscation
        self.obfuscationPassword = obfuscationPassword
        self.uploadMbps = uploadMbps
        self.downloadMbps = downloadMbps
        self.congestionController = congestionController
        self.udpRelayMode = udpRelayMode
        self.privateKey = privateKey
        self.publicKey = publicKey
        self.preSharedKey = preSharedKey
        self.localAddress = localAddress
        self.localIPv6Address = localIPv6Address
        self.allowedIPs = allowedIPs
        self.mtu = mtu
        self.privateKeyPassphrase = privateKeyPassphrase
        self.dialerProxy = dialerProxy
        self.ssrProtocol = ssrProtocol
        self.ssrProtocolParam = ssrProtocolParam
        self.ssrObfs = ssrObfs
        self.ssrObfsParam = ssrObfsParam
        self.hysteriaProtocol = hysteriaProtocol
        self.hysteriaAuthBase64 = hysteriaAuthBase64
        self.alpn = alpn
        self.tuicToken = tuicToken
        self.tuicVersion = tuicVersion
        self.tuicReduceRTT = tuicReduceRTT
        self.snellVersion = snellVersion
        self.snellObfsHost = snellObfsHost
        self.snellReuse = snellReuse
        self.mieruTransport = mieruTransport
        self.mieruMultiplexing = mieruMultiplexing
        self.mieruHandshakeMode = mieruHandshakeMode
        self.mieruPortRange = mieruPortRange
        self.plugin = plugin
        self.pluginMode = pluginMode
        self.pluginHost = pluginHost
        self.pluginPath = pluginPath
        self.pluginPassword = pluginPassword
        self.pluginVersion = pluginVersion
        self.fastOpen = fastOpen
        self.amneziaWG = amneziaWG
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        protocolID = try container.decode(AetherNodeProtocol.self, forKey: .protocolID)
        server = try container.decode(String.self, forKey: .server)
        port = try container.decode(UInt16.self, forKey: .port)
        username = try container.decode(String.self, forKey: .username)
        password = try container.decode(String.self, forKey: .password)
        uuid = try container.decode(String.self, forKey: .uuid)
        cipher = try container.decode(String.self, forKey: .cipher)
        alterID = try container.decode(UInt16.self, forKey: .alterID)
        udp = try container.decode(Bool.self, forKey: .udp)
        tls = try container.decode(AetherNodeTLS.self, forKey: .tls)
        transport = try container.decode(AetherNodeTransportOptions.self, forKey: .transport)
        flow = try container.decode(String.self, forKey: .flow)
        vlessEncryption = try container.decodeIfPresent(String.self, forKey: .vlessEncryption) ?? ""
        obfuscation = try container.decode(String.self, forKey: .obfuscation)
        obfuscationPassword = try container.decode(String.self, forKey: .obfuscationPassword)
        uploadMbps = try container.decodeIfPresent(UInt64.self, forKey: .uploadMbps)
        downloadMbps = try container.decodeIfPresent(UInt64.self, forKey: .downloadMbps)
        congestionController = try container.decode(String.self, forKey: .congestionController)
        udpRelayMode = try container.decode(String.self, forKey: .udpRelayMode)
        privateKey = try container.decode(String.self, forKey: .privateKey)
        publicKey = try container.decode(String.self, forKey: .publicKey)
        preSharedKey = try container.decode(String.self, forKey: .preSharedKey)
        localAddress = try container.decode(String.self, forKey: .localAddress)
        localIPv6Address = try container.decode(String.self, forKey: .localIPv6Address)
        allowedIPs = try container.decode([String].self, forKey: .allowedIPs)
        mtu = try container.decodeIfPresent(UInt16.self, forKey: .mtu)
        privateKeyPassphrase = try container.decodeIfPresent(String.self, forKey: .privateKeyPassphrase)
        dialerProxy = try container.decodeIfPresent(String.self, forKey: .dialerProxy)
        ssrProtocol = try container.decodeIfPresent(String.self, forKey: .ssrProtocol) ?? ""
        ssrProtocolParam = try container.decodeIfPresent(String.self, forKey: .ssrProtocolParam) ?? ""
        ssrObfs = try container.decodeIfPresent(String.self, forKey: .ssrObfs) ?? ""
        ssrObfsParam = try container.decodeIfPresent(String.self, forKey: .ssrObfsParam) ?? ""
        hysteriaProtocol = try container.decodeIfPresent(String.self, forKey: .hysteriaProtocol) ?? ""
        hysteriaAuthBase64 = try container.decodeIfPresent(String.self, forKey: .hysteriaAuthBase64) ?? ""
        alpn = try container.decodeIfPresent([String].self, forKey: .alpn) ?? []
        tuicToken = try container.decodeIfPresent(String.self, forKey: .tuicToken) ?? ""
        tuicVersion = try container.decodeIfPresent(UInt8.self, forKey: .tuicVersion)
        tuicReduceRTT = try container.decodeIfPresent(Bool.self, forKey: .tuicReduceRTT) ?? false
        snellVersion = try container.decodeIfPresent(Int.self, forKey: .snellVersion)
        snellObfsHost = try container.decodeIfPresent(String.self, forKey: .snellObfsHost) ?? ""
        snellReuse = try container.decodeIfPresent(Bool.self, forKey: .snellReuse) ?? false
        mieruTransport = try container.decodeIfPresent(String.self, forKey: .mieruTransport) ?? ""
        mieruMultiplexing = try container.decodeIfPresent(String.self, forKey: .mieruMultiplexing) ?? ""
        mieruHandshakeMode = try container.decodeIfPresent(String.self, forKey: .mieruHandshakeMode) ?? ""
        mieruPortRange = try container.decodeIfPresent(String.self, forKey: .mieruPortRange) ?? ""
        plugin = try container.decodeIfPresent(String.self, forKey: .plugin) ?? ""
        pluginMode = try container.decodeIfPresent(String.self, forKey: .pluginMode) ?? ""
        pluginHost = try container.decodeIfPresent(String.self, forKey: .pluginHost) ?? ""
        pluginPath = try container.decodeIfPresent(String.self, forKey: .pluginPath) ?? ""
        pluginPassword = try container.decodeIfPresent(String.self, forKey: .pluginPassword) ?? ""
        pluginVersion = try container.decodeIfPresent(Int.self, forKey: .pluginVersion)
        fastOpen = try container.decodeIfPresent(Bool.self, forKey: .fastOpen) ?? false
        amneziaWG = try container.decodeIfPresent(AetherAmneziaWGOptions.self, forKey: .amneziaWG) ?? .init()
    }
}

public enum AetherNodeValidationError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(Int)
    case missingField(String)
    case invalidField(String)
    case invalidTransport(AetherNodeTransport, AetherNodeProtocol)
    case valueTooLong(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(version):
            "Unsupported node format version \(version)."
        case let .missingField(field):
            "\(field) is required."
        case let .invalidField(field):
            "\(field) is invalid."
        case let .invalidTransport(transport, protocolID):
            "\(transport.rawValue) is not supported by \(protocolID.displayName)."
        case let .valueTooLong(field):
            "\(field) is too long."
        }
    }
}

public extension AetherNode {
    func validated() throws -> Self {
        guard formatVersion == Self.currentFormatVersion else {
            throw AetherNodeValidationError.unsupportedFormat(formatVersion)
        }
        try Self.require(name, field: "Name", maximumBytes: 256)
        try Self.require(server, field: "Server", maximumBytes: 1_024)
        guard !server.contains("://"),
              !server.contains("/"),
              !server.contains("@"),
              !server.contains(where: \.isWhitespace)
        else { throw AetherNodeValidationError.invalidField("Server") }
        guard port > 0 else {
            throw AetherNodeValidationError.invalidField("Port")
        }

        for (field, value) in [
            ("Username", username),
            ("Password", password),
            ("UUID", uuid),
            ("Cipher", cipher),
            ("Flow", flow),
            ("VLESS encryption", vlessEncryption),
            ("SNI", tls.serverName),
            ("Reality public key", tls.realityPublicKey),
            ("Reality short ID", tls.realityShortID),
            ("Client fingerprint", tls.clientFingerprint),
            ("Certificate fingerprint", tls.certificateFingerprint),
            ("Transport path", transport.path),
            ("Transport host", transport.host),
            ("gRPC service name", transport.grpcServiceName),
            ("XHTTP mode", transport.xhttpMode),
            ("Obfuscation", obfuscation),
            ("Obfuscation password", obfuscationPassword),
            ("Congestion controller", congestionController),
            ("UDP relay mode", udpRelayMode),
            ("Public key", publicKey),
            ("Pre-shared key", preSharedKey),
            ("Local address", localAddress),
            ("Local IPv6 address", localIPv6Address),
            ("Private key passphrase", privateKeyPassphrase ?? ""),
            ("Dialer proxy", dialerProxy ?? ""),
            ("SSR protocol", ssrProtocol),
            ("SSR protocol param", ssrProtocolParam),
            ("SSR obfs", ssrObfs),
            ("SSR obfs param", ssrObfsParam),
            ("Hysteria protocol", hysteriaProtocol),
            ("Hysteria auth", hysteriaAuthBase64),
            ("TUIC token", tuicToken),
            ("Snell obfs host", snellObfsHost),
            ("Mieru transport", mieruTransport),
            ("Mieru multiplexing", mieruMultiplexing),
            ("Mieru handshake mode", mieruHandshakeMode),
            ("Mieru port range", mieruPortRange),
            ("Plugin", plugin),
            ("Plugin mode", pluginMode),
            ("Plugin host", pluginHost),
            ("Plugin path", pluginPath),
            ("Plugin password", pluginPassword),
        ] {
            try Self.validateScalar(value, field: field, maximumBytes: 4_096)
        }
        for value in alpn {
            try Self.require(value, field: "ALPN", maximumBytes: 128)
        }
        if let rawDialer = dialerProxy {
            let trimmedDialer = rawDialer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedDialer.isEmpty {
                guard trimmedDialer.utf8.count <= 256 else {
                    throw AetherNodeValidationError.valueTooLong("Dialer proxy")
                }
                let reservedDialers: Set<String> = ["DIRECT", "REJECT", "GLOBAL"]
                guard trimmedDialer != name.trimmingCharacters(in: .whitespacesAndNewlines),
                      !reservedDialers.contains(trimmedDialer.uppercased())
                else {
                    throw AetherNodeValidationError.invalidField("Dialer proxy")
                }
            }
        }
        try Self.validatePrivateKey(privateKey)
        for value in allowedIPs {
            try Self.require(value, field: "Allowed IP", maximumBytes: 256)
        }

        try validateProtocolRequirements()
        try validateTransport()
        return self
    }

    private func validateProtocolRequirements() throws {
        switch protocolID {
        case .http, .socks5:
            break
        case .shadowsocks:
            try Self.require(cipher, field: "Cipher")
            try Self.require(password, field: "Password")
            if !plugin.isEmpty {
                guard ProfileImportValidator.safeBuiltinPlugins.contains(plugin.lowercased()) else {
                    throw AetherNodeValidationError.invalidField("Plugin")
                }
            }
        case .shadowsocksR:
            try Self.require(cipher, field: "Cipher")
            try Self.require(password, field: "Password")
            let proto = ssrProtocol.isEmpty ? "origin" : ssrProtocol
            let obfsVal = ssrObfs.isEmpty ? "plain" : ssrObfs
            try Self.require(proto, field: "SSR protocol")
            try Self.require(obfsVal, field: "SSR obfs")
        case .vmess, .vless:
            try Self.requireUUID(uuid)
            if protocolID == .vless,
               !vlessEncryption.isEmpty,
               vlessEncryption.lowercased() != "none" {
                guard vlessEncryption.hasPrefix("mlkem768x25519plus.") else {
                    throw AetherNodeValidationError.invalidField("VLESS encryption")
                }
            }
        case .trojan, .hysteria2, .anyTLS:
            try Self.require(password, field: "Password")
        case .hysteria:
            let hasAuthStr = !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hasAuthB64 = !hysteriaAuthBase64.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard hasAuthStr || hasAuthB64 else {
                throw AetherNodeValidationError.missingField("Password")
            }
            if !hysteriaProtocol.isEmpty {
                guard ["udp", "wechat-video"].contains(hysteriaProtocol.lowercased()) else {
                    throw AetherNodeValidationError.invalidField("Hysteria protocol")
                }
            }
        case .tuic:
            let isV4 = (tuicVersion == 4) || !tuicToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isV4 {
                try Self.require(tuicToken, field: "Token")
                guard uuid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw AetherNodeValidationError.invalidField("UUID")
                }
            } else {
                try Self.requireUUID(uuid)
                try Self.require(password, field: "Password")
            }
        case .snell:
            try Self.require(password, field: "PSK")
            if let v = snellVersion {
                guard (1...5).contains(v) else {
                    throw AetherNodeValidationError.invalidField("Snell version")
                }
            }
            if !obfuscation.isEmpty {
                guard ["http", "tls"].contains(obfuscation.lowercased()) else {
                    throw AetherNodeValidationError.invalidField("Obfuscation")
                }
            }
        case .mieru:
            try Self.require(username, field: "Username")
            try Self.require(password, field: "Password")
            let tr = mieruTransport.isEmpty ? "TCP" : mieruTransport.uppercased()
            guard tr == "TCP" || tr == "UDP" else {
                throw AetherNodeValidationError.invalidField("Mieru transport")
            }
            if !mieruPortRange.isEmpty {
                let parts = mieruPortRange.split(separator: "-", omittingEmptySubsequences: false)
                guard parts.count == 2,
                      let start = UInt16(parts[0].trimmingCharacters(in: .whitespaces)),
                      let end = UInt16(parts[1].trimmingCharacters(in: .whitespaces)),
                      start > 0, start <= end
                else {
                    throw AetherNodeValidationError.invalidField("Port range")
                }
            }
        case .wireGuard:
            try Self.require(privateKey, field: "Private key", maximumBytes: 65_536)
            try Self.require(publicKey, field: "Public key")
            try Self.validateWireGuardKey(privateKey, field: "Private key")
            try Self.validateWireGuardKey(publicKey, field: "Public key")
            if !preSharedKey.isEmpty {
                try Self.validateWireGuardKey(
                    preSharedKey,
                    field: "Pre-shared key"
                )
            }
            try Self.require(localAddress, field: "Local address")
            guard !allowedIPs.isEmpty else {
                throw AetherNodeValidationError.missingField("Allowed IPs")
            }
        case .ssh:
            try Self.require(username, field: "Username")
            guard !password.isEmpty || !privateKey.isEmpty else {
                throw AetherNodeValidationError.missingField(
                    "Password or private key"
                )
            }
            if !privateKey.isEmpty {
                try AetherSSHPrivateKeyDocument.validate(privateKey)
            }
            if !(privateKeyPassphrase ?? "").isEmpty, privateKey.isEmpty {
                throw AetherNodeValidationError.missingField("Private key")
            }
        case .shadowQUIC:
            try Self.require(username, field: "Username")
            try Self.require(password, field: "Password")
            try Self.require(tls.serverName, field: "Server name")
        }

        if protocolID == .hysteria2, !obfuscation.isEmpty {
            guard obfuscation == "salamander" else {
                throw AetherNodeValidationError.invalidField("Obfuscation")
            }
            try Self.require(obfuscationPassword, field: "Obfuscation password")
        }
        if protocolID == .vless,
           !tls.realityPublicKey.isEmpty || !tls.realityShortID.isEmpty {
            try validateRealityConfiguration()
        }
        try validateCertificateFingerprint()
    }

    /// Protocols whose TLS client honours a pinned certificate.
    static let certificateFingerprintProtocols: Set<AetherNodeProtocol> = [
        .http, .socks5, .vmess, .vless, .trojan, .hysteria, .hysteria2, .tuic, .anyTLS,
    ]

    var supportsCertificateFingerprint: Bool {
        Self.certificateFingerprintProtocols.contains(protocolID)
            && (tls.enabled || [.trojan, .hysteria, .hysteria2, .tuic, .anyTLS].contains(protocolID))
            && tls.realityPublicKey.isEmpty
            && tls.realityShortID.isEmpty
    }

    func validateCertificateFingerprint() throws {
        let value = tls.certificateFingerprint
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard supportsCertificateFingerprint,
              AetherNodeTLS.normalizedCertificateFingerprint(value) != nil else {
            throw AetherNodeValidationError.invalidField("Certificate fingerprint")
        }
    }

    func validateRealityConfiguration() throws {
        guard protocolID == .vless,
              !tls.realityPublicKey.isEmpty || !tls.realityShortID.isEmpty
        else { return }
        guard tls.enabled else {
            throw AetherNodeValidationError.invalidField("REALITY TLS")
        }
        try Self.require(tls.serverName, field: "Reality server name")
        guard !tls.serverName.contains("://"),
              !tls.serverName.contains("/"),
              !tls.serverName.contains("@"),
              !tls.serverName.contains(where: \.isWhitespace) else {
            throw AetherNodeValidationError.invalidField(
                "Reality server name"
            )
        }
        try Self.require(tls.realityPublicKey, field: "Reality public key")
        try Self.validateRealityPublicKey(tls.realityPublicKey)
        try Self.validateRealityShortID(tls.realityShortID)
        try Self.require(
            tls.clientFingerprint,
            field: "Client fingerprint"
        )
    }

    private func validateTransport() throws {
        guard transport.kind != .tcp else { return }
        let supported: Set<AetherNodeProtocol>
        switch transport.kind {
        case .tcp:
            return
        case .webSocket, .grpc:
            supported = [.vmess, .vless, .trojan]
        case .http2:
            supported = [.vmess, .vless]
        case .xhttp:
            supported = [.vless]
        }
        guard supported.contains(protocolID) else {
            throw AetherNodeValidationError.invalidTransport(
                transport.kind,
                protocolID
            )
        }
    }

    private static func requireUUID(_ value: String) throws {
        try require(value, field: "UUID")
        guard UUID(uuidString: value) != nil else {
            throw AetherNodeValidationError.invalidField("UUID")
        }
    }

    private static func require(
        _ value: String,
        field: String,
        maximumBytes: Int = 4_096
    ) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AetherNodeValidationError.missingField(field)
        }
        try validateScalar(value, field: field, maximumBytes: maximumBytes)
    }

    private static func validateScalar(
        _ value: String,
        field: String,
        maximumBytes: Int
    ) throws {
        guard value.utf8.count <= maximumBytes else {
            throw AetherNodeValidationError.valueTooLong(field)
        }
        guard !value.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw AetherNodeValidationError.invalidField(field)
        }
    }

    private static func validatePrivateKey(_ value: String) throws {
        guard value.utf8.count <= 65_536 else {
            throw AetherNodeValidationError.valueTooLong("Private key")
        }
        guard !value.unicodeScalars.contains(where: {
            $0.value == 0 || $0.value == 0x7f
        }) else {
            throw AetherNodeValidationError.invalidField("Private key")
        }
    }

    private static func validateWireGuardKey(
        _ value: String,
        field: String
    ) throws {
        guard let decoded = Data(base64Encoded: value), decoded.count == 32 else {
            throw AetherNodeValidationError.invalidField(field)
        }
    }

    private static func validateRealityPublicKey(_ value: String) throws {
        let unpadded: Substring
        if value.hasSuffix("=") {
            unpadded = value.dropLast()
        } else {
            unpadded = value[...]
        }
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-_")
        )
        guard unpadded.utf8.count == 43,
              unpadded.unicodeScalars.allSatisfy(allowed.contains)
        else {
            throw AetherNodeValidationError.invalidField(
                "Reality public key"
            )
        }
        let base64 = String(unpadded)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + "="
        guard Data(base64Encoded: base64)?.count == 32 else {
            throw AetherNodeValidationError.invalidField(
                "Reality public key"
            )
        }
    }

    private static func validateRealityShortID(_ value: String) throws {
        guard value.utf8.count <= 16,
              value.utf8.count.isMultiple(of: 2),
              value.unicodeScalars.allSatisfy({ scalar in
                  switch scalar.value {
                  case 48...57, 65...70, 97...102: true
                  default: false
                  }
              }) else {
            throw AetherNodeValidationError.invalidField(
                "Reality short ID"
            )
        }
    }

    var transportDisplayName: String {
        switch protocolID {
        case .vmess, .vless, .trojan:
            switch transport.kind {
            case .tcp: return "TCP"
            case .webSocket: return transport.httpUpgrade ? "HTTPUpgrade" : "WS"
            case .http2: return "H2"
            case .grpc: return "gRPC"
            case .xhttp: return "XHTTP"
            }
        case .mieru:
            let t = mieruTransport.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return t.isEmpty ? "TCP" : t
        case .hysteria, .hysteria2, .tuic, .shadowQUIC:
            return "QUIC"
        case .wireGuard:
            return "UDP"
        case .shadowsocks:
            if !plugin.isEmpty { return plugin }
            return "TCP"
        default:
            return "TCP"
        }
    }
}

public enum AetherNodeProfileCompiler {
    public static let groupName = "AetherRoute Manual"
    public static let maximumNodes = 256

    public static func compile(node: AetherNode) throws -> String {
        try compile(nodes: [node])
    }

    public static func compile(nodes: [AetherNode]) throws -> String {
        try compile(nodes: nodes, groupName: groupName)
    }

    /// Every dialer must name another node of the same profile. The core
    /// fails the whole profile ("connector … not found") otherwise, and the
    /// group would route a node through itself.
    ///
    /// Checked when a native profile is saved, not in `compile`: stored
    /// profiles are recompiled on every catalog load, and refusing one there
    /// would hide all of a user's profiles.
    public static func validateDialerProxies(
        in nodes: [AetherNode],
        groupName: String = groupName
    ) throws {
        for node in nodes {
            if let dialer = unresolvedDialer(of: node, in: nodes, groupName: groupName) {
                throw AetherNodeProfileCompilerError.unknownDialerProxy(
                    node: node.name.trimmingCharacters(in: .whitespacesAndNewlines),
                    dialer: dialer
                )
            }
        }
    }

    /// Share links from other clients may name a dialer that exists only
    /// there. Importing keeps such nodes and drops the dangling dialer, so
    /// one foreign reference cannot refuse the whole import.
    public static func removingUnresolvedDialerProxies(
        from nodes: [AetherNode]
    ) -> (nodes: [AetherNode], removed: Int) {
        var removed = 0
        let resolved = nodes.map { node -> AetherNode in
            guard unresolvedDialer(of: node, in: nodes, groupName: groupName) != nil else {
                return node
            }
            var copy = node
            copy.dialerProxy = nil
            removed += 1
            return copy
        }
        return (resolved, removed)
    }

    /// The node's dialer when it is set but does not name another node.
    private static func unresolvedDialer(
        of node: AetherNode,
        in nodes: [AetherNode],
        groupName: String
    ) -> String? {
        guard let dialer = node.dialerProxy?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dialer.isEmpty else { return nil }
        let name = node.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let names = Set(nodes.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard dialer != name, dialer != groupName, names.contains(dialer) else {
            return dialer
        }
        return nil
    }

    public static func compile(
        nodes: [AetherNode],
        groupName: String
    ) throws -> String {
        guard !nodes.isEmpty else {
            throw AetherNodeProfileCompilerError.emptyProfile
        }
        guard nodes.count <= maximumNodes else {
            throw AetherNodeProfileCompilerError.tooManyNodes(maximumNodes)
        }
        let nodes = try nodes.map { try $0.validated() }
        guard !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              groupName.utf8.count <= 256,
              !groupName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              }) else {
            throw AetherNodeProfileCompilerError.reservedName
        }
        let names = nodes.map(\.name)
        guard Set(names).count == names.count else {
            throw AetherNodeProfileCompilerError.duplicateName
        }
        let reservedNames = Set(["DIRECT", "REJECT", "GLOBAL", groupName])
        guard names.allSatisfy({ !reservedNames.contains($0) }) else {
            throw AetherNodeProfileCompilerError.reservedName
        }

        var lines = [
            "mode: rule",
            "log-level: silent",
            "proxies:",
        ]

        for node in nodes {
            lines.append(contentsOf: [
                "  - name: \(scalar(node.name))",
                "    type: \(scalar(node.protocolID.coreType))",
                "    server: \(scalar(node.server))",
            ])
            if node.protocolID == .mieru,
               !node.mieruPortRange.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                field("port-range", node.mieruPortRange.trimmingCharacters(in: .whitespacesAndNewlines), to: &lines)
            } else {
                lines.append("    port: \(node.port)")
            }
            appendProtocolFields(node, to: &lines)
            appendTransport(node, to: &lines)
            if node.fastOpen && node.protocolID != .tuic {
                field("tfo", true, to: &lines)
            }
            if let dialer = node.dialerProxy?.trimmingCharacters(in: .whitespacesAndNewlines),
               !dialer.isEmpty {
                field("dialer-proxy", dialer, to: &lines)
            }
        }
        lines.append(contentsOf: [
            "proxy-groups:",
            "  - name: \(scalar(groupName))",
            "    type: select",
            "    proxies:",
        ])
        lines.append(contentsOf: names.map { "      - \(scalar($0))" })
        lines.append(contentsOf: [
            "      - DIRECT",
            "rules:",
            "  - \(scalar("MATCH,\(groupName)"))",
            "",
        ])
        let yaml = lines.joined(separator: "\n")
        try ProfileImportValidator.validate(data: Data(yaml.utf8))
        return yaml
    }

    private static func appendProtocolFields(
        _ node: AetherNode,
        to lines: inout [String]
    ) {
        switch node.protocolID {
        case .http:
            appendCredentials(node, to: &lines)
            appendTLS(node, enabledField: true, to: &lines)
        case .socks5:
            appendCredentials(node, to: &lines)
            appendTLS(node, enabledField: true, to: &lines)
            field("udp", node.udp, to: &lines)
        case .shadowsocks:
            field("cipher", node.cipher, to: &lines)
            field("password", node.password, to: &lines)
            field("udp", node.udp, to: &lines)
            if !node.plugin.isEmpty {
                let normalizedPlugin: String
                switch node.plugin.lowercased() {
                case "simple-obfs", "obfs-local": normalizedPlugin = "obfs"
                case "shadowtls": normalizedPlugin = "shadow-tls"
                default: normalizedPlugin = node.plugin.lowercased()
                }
                field("plugin", normalizedPlugin, to: &lines)
                lines.append("    plugin-opts:")
                nestedFieldIfPresent("mode", node.pluginMode, to: &lines)
                nestedFieldIfPresent("host", node.pluginHost, to: &lines)
                nestedFieldIfPresent("path", node.pluginPath, to: &lines)
                nestedFieldIfPresent("password", node.pluginPassword, to: &lines)
                if let version = node.pluginVersion {
                    lines.append("      version: \(version)")
                }
                if node.tls.enabled && normalizedPlugin == "v2ray-plugin" {
                    lines.append("      tls: true")
                }
            }
        case .shadowsocksR:
            field("cipher", node.cipher, to: &lines)
            field("password", node.password, to: &lines)
            field("protocol", node.ssrProtocol.isEmpty ? "origin" : node.ssrProtocol, to: &lines)
            fieldIfPresent("protocol-param", node.ssrProtocolParam, to: &lines)
            field("obfs", node.ssrObfs.isEmpty ? "plain" : node.ssrObfs, to: &lines)
            fieldIfPresent("obfs-param", node.ssrObfsParam, to: &lines)
            field("udp", node.udp, to: &lines)
        case .vmess:
            field("uuid", node.uuid.lowercased(), to: &lines)
            field("alter-id", node.alterID, to: &lines)
            field("cipher", node.cipher.isEmpty ? "auto" : node.cipher, to: &lines)
            field("udp", node.udp, to: &lines)
            appendTLS(node, enabledField: true, to: &lines)
        case .vless:
            field("uuid", node.uuid.lowercased(), to: &lines)
            field("udp", node.udp, to: &lines)
            appendTLS(node, enabledField: true, to: &lines)
            fieldIfPresent("flow", node.flow, to: &lines)
            if !node.vlessEncryption.isEmpty, node.vlessEncryption.lowercased() != "none" {
                field("encryption", node.vlessEncryption, to: &lines)
            }
            if !node.tls.realityPublicKey.isEmpty {
                lines.append("    reality-opts:")
                nestedField("public-key", node.tls.realityPublicKey, to: &lines)
                nestedField("short-id", node.tls.realityShortID, to: &lines)
                fieldIfPresent(
                    "client-fingerprint",
                    node.tls.clientFingerprint,
                    to: &lines
                )
            }
        case .trojan:
            field("password", node.password, to: &lines)
            field("udp", node.udp, to: &lines)
            appendTLS(node, enabledField: false, to: &lines)
        case .hysteria:
            if !node.hysteriaAuthBase64.isEmpty {
                field("auth", node.hysteriaAuthBase64, to: &lines)
            } else {
                field("auth-str", node.password, to: &lines)
            }
            fieldIfPresent("protocol", node.hysteriaProtocol, to: &lines)
            let obfsVal = !node.obfuscationPassword.isEmpty
                ? node.obfuscationPassword
                : (node.obfuscation.lowercased() == "xplus" ? "" : node.obfuscation)
            fieldIfPresent("obfs", obfsVal, to: &lines)
            integerFieldIfPresent("up", node.uploadMbps, to: &lines)
            integerFieldIfPresent("down", node.downloadMbps, to: &lines)
            if !node.alpn.isEmpty {
                listField("alpn", node.alpn, to: &lines)
            }
            appendTLS(node, enabledField: false, to: &lines)
        case .hysteria2:
            field("password", node.password, to: &lines)
            fieldIfPresent("obfs", node.obfuscation, to: &lines)
            fieldIfPresent("obfs-password", node.obfuscationPassword, to: &lines)
            integerFieldIfPresent("up", node.uploadMbps, to: &lines)
            integerFieldIfPresent("down", node.downloadMbps, to: &lines)
            if !node.alpn.isEmpty {
                listField("alpn", node.alpn, to: &lines)
            }
            appendTLS(node, enabledField: false, to: &lines)
        case .tuic:
            let isV4 = (node.tuicVersion == 4) || !node.tuicToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isV4 {
                field("version", 4, to: &lines)
                field("token", node.tuicToken, to: &lines)
            } else {
                field("uuid", node.uuid.lowercased(), to: &lines)
                field("password", node.password, to: &lines)
            }
            fieldIfPresent(
                "congestion-controller",
                node.congestionController,
                to: &lines
            )
            fieldIfPresent("udp-relay-mode", node.udpRelayMode, to: &lines)
            if node.tuicReduceRTT {
                field("reduce-rtt", true, to: &lines)
            }
            if node.fastOpen {
                field("fast-open", true, to: &lines)
            }
            if !node.alpn.isEmpty {
                listField("alpn", node.alpn, to: &lines)
            }
            appendTLS(node, enabledField: false, to: &lines)
        case .snell:
            field("psk", node.password, to: &lines)
            let version = node.snellVersion ?? 4
            field("version", version, to: &lines)
            field("udp", version >= 3 ? node.udp : false, to: &lines)
            if node.snellReuse {
                field("reuse", true, to: &lines)
            }
            if !node.obfuscation.isEmpty {
                lines.append("    obfs-opts:")
                nestedField("mode", node.obfuscation.lowercased(), to: &lines)
                nestedFieldIfPresent("host", node.snellObfsHost, to: &lines)
            }
        case .mieru:
            field("username", node.username, to: &lines)
            field("password", node.password, to: &lines)
            field("transport", node.mieruTransport.isEmpty ? "TCP" : node.mieruTransport.uppercased(), to: &lines)
            fieldIfPresent("multiplexing", node.mieruMultiplexing, to: &lines)
            fieldIfPresent("handshake-mode", node.mieruHandshakeMode, to: &lines)
            field("udp", node.udp, to: &lines)
        case .anyTLS:
            field("password", node.password, to: &lines)
            field("udp", node.udp, to: &lines)
            appendTLS(node, enabledField: false, to: &lines)
        case .wireGuard:
            field("private-key", node.privateKey, to: &lines)
            field("public-key", node.publicKey, to: &lines)
            fieldIfPresent("pre-shared-key", node.preSharedKey, to: &lines)
            field("ip", node.localAddress, to: &lines)
            fieldIfPresent("ipv6", node.localIPv6Address, to: &lines)
            field("udp", node.udp, to: &lines)
            if let mtu = node.mtu { field("mtu", mtu, to: &lines) }
            listField("allowed-ips", node.allowedIPs, to: &lines)
            if !node.amneziaWG.isEmpty {
                lines.append("    amnezia-wg-option:")
                if let jc = node.amneziaWG.jc { lines.append("      jc: \(jc)") }
                if let jmin = node.amneziaWG.jmin { lines.append("      jmin: \(jmin)") }
                if let jmax = node.amneziaWG.jmax { lines.append("      jmax: \(jmax)") }
                if let s1 = node.amneziaWG.s1 { lines.append("      s1: \(s1)") }
                if let s2 = node.amneziaWG.s2 { lines.append("      s2: \(s2)") }
                if let h1 = node.amneziaWG.h1 { lines.append("      h1: \(h1)") }
                if let h2 = node.amneziaWG.h2 { lines.append("      h2: \(h2)") }
                if let h3 = node.amneziaWG.h3 { lines.append("      h3: \(h3)") }
                if let h4 = node.amneziaWG.h4 { lines.append("      h4: \(h4)") }
            }
        case .ssh:
            field("username", node.username, to: &lines)
            fieldIfPresent("password", node.password, to: &lines)
            if !node.privateKey.isEmpty {
                blockField("private-key", node.privateKey, to: &lines)
                fieldIfPresent(
                    "private-key-passphrase",
                    node.privateKeyPassphrase ?? "",
                    to: &lines
                )
            }
        case .shadowQUIC:
            field("username", node.username, to: &lines)
            field("password", node.password, to: &lines)
            field("server-name", node.tls.serverName, to: &lines)
            fieldIfPresent(
                "congestion-control",
                node.congestionController,
                to: &lines
            )
            if let mtu = node.mtu { field("initial-mtu", mtu, to: &lines) }
        }
    }

    private static func appendCredentials(
        _ node: AetherNode,
        to lines: inout [String]
    ) {
        fieldIfPresent("username", node.username, to: &lines)
        fieldIfPresent("password", node.password, to: &lines)
    }

    private static func appendTLS(
        _ node: AetherNode,
        enabledField: Bool,
        to lines: inout [String]
    ) {
        if enabledField { field("tls", node.tls.enabled, to: &lines) }
        fieldIfPresent("sni", node.tls.serverName, to: &lines)
        field(
            "skip-cert-verify",
            node.tls.skipCertificateVerification,
            to: &lines
        )
        if let fingerprint = AetherNodeTLS.normalizedCertificateFingerprint(
            node.tls.certificateFingerprint
        ) {
            field("fingerprint", fingerprint, to: &lines)
        }
    }

    private static func appendTransport(
        _ node: AetherNode,
        to lines: inout [String]
    ) {
        guard node.transport.kind != .tcp else { return }
        field("network", node.transport.kind.rawValue, to: &lines)
        switch node.transport.kind {
        case .tcp:
            break
        case .webSocket:
            lines.append("    ws-opts:")
            nestedFieldIfPresent("path", node.transport.path, to: &lines)
            if !node.transport.host.isEmpty {
                lines.append("      headers:")
                lines.append("        Host: \(scalar(node.transport.host))")
            }
            if node.transport.httpUpgrade {
                lines.append("      v2ray-http-upgrade: true")
            }
        case .http2:
            lines.append("    h2-opts:")
            nestedFieldIfPresent("path", node.transport.path, to: &lines)
            if !node.transport.host.isEmpty {
                lines.append("      host:")
                lines.append("        - \(scalar(node.transport.host))")
            }
        case .grpc:
            lines.append("    grpc-opts:")
            nestedFieldIfPresent(
                "grpc-service-name",
                node.transport.grpcServiceName,
                to: &lines
            )
        case .xhttp:
            if !node.transport.path.isEmpty || !node.transport.host.isEmpty || !node.transport.xhttpMode.isEmpty {
                lines.append("    xhttp-opts:")
                nestedFieldIfPresent("path", node.transport.path, to: &lines)
                nestedFieldIfPresent("host", node.transport.host, to: &lines)
                nestedFieldIfPresent("mode", node.transport.xhttpMode, to: &lines)
            }
        }
    }

    private static func field(
        _ key: String,
        _ value: String,
        to lines: inout [String]
    ) {
        lines.append("    \(key): \(scalar(value))")
    }

    private static func field(
        _ key: String,
        _ value: Bool,
        to lines: inout [String]
    ) {
        lines.append("    \(key): \(value ? "true" : "false")")
    }

    private static func field<T: BinaryInteger>(
        _ key: String,
        _ value: T,
        to lines: inout [String]
    ) {
        lines.append("    \(key): \(value)")
    }

    private static func fieldIfPresent(
        _ key: String,
        _ value: String,
        to lines: inout [String]
    ) {
        guard !value.isEmpty else { return }
        field(key, value, to: &lines)
    }

    private static func integerFieldIfPresent(
        _ key: String,
        _ value: UInt64?,
        to lines: inout [String]
    ) {
        guard let value else { return }
        field(key, value, to: &lines)
    }

    private static func nestedField(
        _ key: String,
        _ value: String,
        to lines: inout [String]
    ) {
        lines.append("      \(key): \(scalar(value))")
    }

    private static func nestedFieldIfPresent(
        _ key: String,
        _ value: String,
        to lines: inout [String]
    ) {
        guard !value.isEmpty else { return }
        nestedField(key, value, to: &lines)
    }

    private static func listField(
        _ key: String,
        _ values: [String],
        to lines: inout [String]
    ) {
        lines.append("    \(key):")
        lines.append(contentsOf: values.map { "      - \(scalar($0))" })
    }

    private static func blockField(
        _ key: String,
        _ value: String,
        to lines: inout [String]
    ) {
        lines.append("    \(key): |-")
        lines.append(contentsOf: value.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map { "      \($0)" })
    }

    private static func scalar(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "''"))'"
    }
}

public enum AetherSSHPrivateKeyDocument {
    public static let maximumBytes = 64 * 1_024
    private static let beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
    private static let endMarker = "-----END OPENSSH PRIVATE KEY-----"

    public static func decode(data: Data) throws -> String {
        guard !data.isEmpty else {
            throw AetherSSHPrivateKeyError.empty
        }
        guard data.count <= maximumBytes else {
            throw AetherSSHPrivateKeyError.tooLarge(maximumBytes)
        }
        guard let value = String(data: data, encoding: .utf8) else {
            throw AetherSSHPrivateKeyError.notUTF8
        }
        try validate(value)
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized + "\n"
    }

    public static func validate(_ value: String) throws {
        guard !value.isEmpty else {
            throw AetherSSHPrivateKeyError.empty
        }
        guard value.utf8.count <= maximumBytes else {
            throw AetherSSHPrivateKeyError.tooLarge(maximumBytes)
        }
        guard !value.unicodeScalars.contains(where: {
            $0.value == 0 || $0.value == 0x7f
        }) else {
            throw AetherSSHPrivateKeyError.invalidText
        }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.hasPrefix(beginMarker + "\n"),
              normalized.hasSuffix("\n" + endMarker) else {
            throw AetherSSHPrivateKeyError.unsupportedFormat
        }
    }
}

public enum AetherSSHPrivateKeyError: LocalizedError, Equatable, Sendable {
    case empty
    case invalidText
    case notUTF8
    case tooLarge(Int)
    case unsupportedFormat

    public var errorDescription: String? {
        switch self {
        case .empty:
            "The OpenSSH private key is empty."
        case .invalidText:
            "The OpenSSH private key contains invalid control characters."
        case .notUTF8:
            "The OpenSSH private key must be UTF-8 text."
        case let .tooLarge(limit):
            "The OpenSSH private key exceeds the \(limit)-byte limit."
        case .unsupportedFormat:
            "Choose an OpenSSH private key with an OPENSSH PRIVATE KEY envelope."
        }
    }
}

public enum AetherNodeProfileCompilerError: LocalizedError, Equatable,
    Sendable
{
    case emptyProfile
    case tooManyNodes(Int)
    case duplicateName
    case reservedName
    case unknownDialerProxy(node: String, dialer: String)

    public var errorDescription: String? {
        switch self {
        case let .unknownDialerProxy(node, dialer):
            "\(node) dials through \(dialer), which is not another node of this profile."
        case .emptyProfile:
            "Add at least one node."
        case let .tooManyNodes(limit):
            "A native profile supports at most \(limit) nodes."
        case .duplicateName:
            "Node names must be unique."
        case .reservedName:
            "A node name conflicts with a reserved routing name."
        }
    }
}

public enum AetherNodeURIError: LocalizedError, Equatable, Sendable {
    case emptyLink
    case linkTooLong
    case malformedLink
    case unsupportedScheme(String)
    case unsupportedProtocolForURI(AetherNodeProtocol)
    case unsupportedTransport(String)

    public var errorDescription: String? {
        switch self {
        case .emptyLink:
            "The proxy share link is empty."
        case .linkTooLong:
            "The proxy share link exceeds the 4096-byte safety limit."
        case .malformedLink:
            "The proxy share link is malformed or missing required fields."
        case let .unsupportedScheme(scheme):
            "Unsupported proxy link scheme: \(scheme)."
        case let .unsupportedProtocolForURI(proto):
            "\(proto.displayName) nodes cannot be exported as a single share URI."
        case let .unsupportedTransport(transport):
            "Unsupported proxy transport: \(transport)."
        }
    }
}

/// Parses and formats standard proxy node share URIs (`vless://`, `trojan://`,
/// `ss://`, `vmess://`, `hysteria2://` / `hy2://`, `tuic://`, `anytls://`,
/// `socks5://`, `http://`, `https://`) with strict length and validation guards.
public enum AetherNodeURIParser {
    public static let maximumURIBytes = 4_096

    public static func parse(_ rawURI: String) throws -> AetherNode {
        let trimmed = rawURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AetherNodeURIError.emptyLink
        }
        guard trimmed.utf8.count <= maximumURIBytes else {
            throw AetherNodeURIError.linkTooLong
        }
        guard !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw AetherNodeURIError.malformedLink
        }

        if trimmed.lowercased().hasPrefix("vmess://") {
            return try parseVMess(trimmed)
        }
        if trimmed.lowercased().hasPrefix("ss://") {
            return try parseShadowsocks(trimmed)
        }
        if trimmed.lowercased().hasPrefix("ssr://") {
            return try parseShadowsocksR(trimmed)
        }
        if !trimmed.contains("://"), let surgeNode = try parseSurgeProxyLine(trimmed) {
            return surgeNode
        }

        guard let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased()
        else {
            throw AetherNodeURIError.malformedLink
        }

        guard let host = components.host.map(unbracketedHost), !host.isEmpty else {
            throw AetherNodeURIError.malformedLink
        }
        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let val = item.value else { return nil }
                return (item.name.lowercased(), val)
            },
            uniquingKeysWith: { _, last in last }
        )
        let port: UInt16
        if let portInt = components.port, let exactPort = UInt16(exactly: portInt), exactPort > 0 {
            port = exactPort
        } else if rawScheme == "mieru",
                  let range = query["port-range"] ?? query["port_range"],
                  let firstPort = range.split(separator: "-").first.flatMap({ UInt16($0.trimmingCharacters(in: .whitespaces)) }),
                  firstPort > 0 {
            port = firstPort
        } else {
            throw AetherNodeURIError.malformedLink
        }

        // `fragment` is already percent-decoded; decoding it again turns a
        // literal "%" into nil and loses the name.
        let fragmentName = components.fragment?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let remarksName = query["remarks"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName: String
        if let fragmentName, !fragmentName.isEmpty {
            defaultName = fragmentName
        } else if let remarksName, !remarksName.isEmpty {
            defaultName = remarksName
        } else {
            defaultName = "\(rawScheme.uppercased())-\(host)"
        }

        let user = components.user ?? ""
        let password = components.password ?? ""
        let dialerProxy = query["dialer-proxy"] ?? query["detour"]
        let fastOpen = flagValue(query["tfo"] ?? query["fast-open"] ?? query["fast_open"])
        let udpEnabled = query["udp"].map(flagValue) ?? query["uot"].map(flagValue) ?? true

        switch rawScheme {
        case "vless":
            let encryption = query["encryption"] ?? ""
            let node = AetherNode(
                name: defaultName,
                protocolID: .vless,
                server: host,
                port: port,
                uuid: user,
                udp: udpEnabled,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                transport: try parseTransport(from: query),
                flow: query["flow"] ?? "",
                vlessEncryption: encryption.lowercased() == "none" ? "" : encryption,
                dialerProxy: dialerProxy,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "trojan":
            let secret = password.isEmpty ? user : "\(user):\(password)"
            let node = AetherNode(
                name: defaultName,
                protocolID: .trojan,
                server: host,
                port: port,
                password: secret,
                udp: udpEnabled,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                transport: try parseTransport(from: query),
                dialerProxy: dialerProxy,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "hysteria", "hy1":
            let authFromUser = password.isEmpty ? user : "\(user):\(password)"
            let authStr = query["auth"] ?? query["auth_str"] ?? query["auth-str"] ?? authFromUser
            let authB64 = query["auth-base64"] ?? query["auth_base64"] ?? ""
            let rawObfs = query["obfs"] ?? ""
            let obfsParam = query["obfsparam"] ?? query["obfs-param"] ?? query["obfs_param"] ?? query["obfs-password"] ?? ""
            let obfs: String
            let obfsPassword: String
            if rawObfs.lowercased() == "xplus" {
                obfs = "xplus"
                obfsPassword = obfsParam
            } else if !obfsParam.isEmpty {
                obfs = "xplus"
                obfsPassword = obfsParam
            } else {
                obfs = rawObfs
                obfsPassword = ""
            }
            let upMbps = (query["upmbps"] ?? query["up"]).flatMap(UInt64.init)
            let downMbps = (query["downmbps"] ?? query["down"]).flatMap(UInt64.init)
            let alpnList = (query["alpn"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let proto = query["protocol"] ?? ""
            let node = AetherNode(
                name: defaultName,
                protocolID: .hysteria,
                server: host,
                port: port,
                password: authStr,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                obfuscation: obfs,
                obfuscationPassword: obfsPassword,
                uploadMbps: upMbps,
                downloadMbps: downMbps,
                dialerProxy: dialerProxy,
                hysteriaProtocol: proto,
                hysteriaAuthBase64: authB64,
                alpn: alpnList,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "hysteria2", "hy2":
            let secret = password.isEmpty ? user : "\(user):\(password)"
            let obfs = (query["obfs"]?.lowercased() == "salamander") ? "salamander" : ""
            let obfsPassword = obfs.isEmpty ? "" : (query["obfs-password"] ?? query["obfspassword"] ?? query["obfsparam"] ?? "")
            let upMbps = (query["upmbps"] ?? query["up"]).flatMap(UInt64.init)
            let downMbps = (query["downmbps"] ?? query["down"]).flatMap(UInt64.init)
            let alpnList = (query["alpn"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let node = AetherNode(
                name: defaultName,
                protocolID: .hysteria2,
                server: host,
                port: port,
                password: secret,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                obfuscation: obfs,
                obfuscationPassword: obfsPassword,
                uploadMbps: upMbps,
                downloadMbps: downMbps,
                dialerProxy: dialerProxy,
                alpn: alpnList,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "tuic":
            let explicitVersion = query["version"].flatMap(UInt8.init)
            let queryToken = query["token"] ?? ""
            let hasColonInUser = user.contains(":")
            let isV4 = (explicitVersion == 4)
                || !queryToken.isEmpty
                || (explicitVersion == nil && password.isEmpty && !hasColonInUser && query["password"] == nil && UUID(uuidString: user) == nil && !user.isEmpty)
            let parsedUUID: String
            let parsedPass: String
            let parsedToken: String
            if isV4 {
                parsedUUID = ""
                parsedPass = ""
                parsedToken = queryToken.isEmpty ? user : queryToken
            } else if !password.isEmpty {
                parsedUUID = user
                parsedPass = password
                parsedToken = ""
            } else if let colon = user.firstIndex(of: ":") {
                parsedUUID = String(user[..<colon])
                parsedPass = String(user[user.index(after: colon)...])
                parsedToken = ""
            } else {
                parsedUUID = user
                parsedPass = query["password"] ?? ""
                parsedToken = ""
            }
            let alpnList = (query["alpn"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            let reduceRTT = flagValue(query["reduce-rtt"] ?? query["reduce_rtt"] ?? query["zero-rtt"])
            let node = AetherNode(
                name: defaultName,
                protocolID: .tuic,
                server: host,
                port: port,
                password: parsedPass,
                uuid: parsedUUID,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                congestionController: query["congestion_control"] ?? query["congestion-control"] ?? query["congestion-controller"] ?? query["cc"] ?? "bbr",
                udpRelayMode: query["udp_relay_mode"] ?? query["udp-relay-mode"] ?? "native",
                dialerProxy: dialerProxy,
                alpn: alpnList,
                tuicToken: parsedToken,
                tuicVersion: isV4 ? 4 : explicitVersion,
                tuicReduceRTT: reduceRTT,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "snell":
            let psk = password.isEmpty ? (user.isEmpty ? (query["psk"] ?? "") : user) : "\(user):\(password)"
            let version = (query["version"] ?? query["v"]).flatMap(Int.init) ?? 4
            let obfs = (query["obfs"] ?? query["obfs-mode"] ?? "").lowercased()
            let obfsHost = query["obfs-host"] ?? query["obfsparam"] ?? query["obfs_host"] ?? query["peer"] ?? ""
            let reuse = flagValue(query["reuse"])
            let udp = query["udp"].map(flagValue) ?? (version >= 3)
            let node = AetherNode(
                name: defaultName,
                protocolID: .snell,
                server: host,
                port: port,
                password: psk,
                udp: udp,
                obfuscation: (obfs == "http" || obfs == "tls") ? obfs : "",
                dialerProxy: dialerProxy,
                snellVersion: version,
                snellObfsHost: obfsHost,
                snellReuse: reuse,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "mieru":
            let parsedUser: String
            let parsedPass: String
            if !password.isEmpty {
                parsedUser = user
                parsedPass = password
            } else if let colon = user.firstIndex(of: ":") {
                parsedUser = String(user[..<colon])
                parsedPass = String(user[user.index(after: colon)...])
            } else {
                parsedUser = user.isEmpty ? (query["username"] ?? "") : user
                parsedPass = query["password"] ?? ""
            }
            let transport = (query["transport"] ?? query["network"] ?? "TCP").uppercased()
            let multiplexing = query["multiplexing"] ?? ""
            let handshakeMode = query["handshake-mode"] ?? query["handshake_mode"] ?? ""
            let portRange = query["port-range"] ?? query["port_range"] ?? ""
            let node = AetherNode(
                name: defaultName,
                protocolID: .mieru,
                server: host,
                port: port,
                username: parsedUser,
                password: parsedPass,
                udp: udpEnabled,
                dialerProxy: dialerProxy,
                mieruTransport: transport,
                mieruMultiplexing: multiplexing,
                mieruHandshakeMode: handshakeMode,
                mieruPortRange: portRange
            )
            return try node.validated()

        case "anytls":
            let secret = password.isEmpty ? user : "\(user):\(password)"
            let node = AetherNode(
                name: defaultName,
                protocolID: .anyTLS,
                server: host,
                port: port,
                password: secret,
                udp: udpEnabled,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                dialerProxy: dialerProxy,
                fastOpen: fastOpen
            )
            return try node.validated()

        case "socks5", "socks":
            let node = AetherNode(
                name: defaultName,
                protocolID: .socks5,
                server: host,
                port: port,
                username: user,
                password: password,
                udp: udpEnabled,
                tls: parseTLS(from: query, defaultEnabled: false, fallbackSNI: host),
                dialerProxy: dialerProxy
            )
            return try node.validated()

        case "http", "https":
            let node = AetherNode(
                name: defaultName,
                protocolID: .http,
                server: host,
                port: port,
                username: user,
                password: password,
                tls: parseTLS(from: query, defaultEnabled: rawScheme == "https", fallbackSNI: host),
                dialerProxy: dialerProxy
            )
            return try node.validated()

        case "wireguard", "wg", "amneziawg":
            let privateKey = user.isEmpty ? (query["private-key"] ?? query["privatekey"] ?? "") : user
            let publicKey = query["public-key"] ?? query["publickey"] ?? ""
            let psk = query["pre-shared-key"] ?? query["presharedkey"] ?? ""
            let address = query["address"] ?? query["ip"] ?? "10.0.0.2/32"
            let ipv6 = query["ipv6"] ?? query["address6"] ?? ""
            let allowedRaw = query["allowed-ips"] ?? query["allowedips"] ?? "0.0.0.0/0"
            let allowed = allowedRaw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let mtu = query["mtu"].flatMap(UInt16.init)
            let awg = AetherAmneziaWGOptions(
                jc: query["jc"].flatMap(Int.init),
                jmin: query["jmin"].flatMap(Int.init),
                jmax: query["jmax"].flatMap(Int.init),
                s1: query["s1"].flatMap(Int.init),
                s2: query["s2"].flatMap(Int.init),
                h1: query["h1"].flatMap(UInt32.init),
                h2: query["h2"].flatMap(UInt32.init),
                h3: query["h3"].flatMap(UInt32.init),
                h4: query["h4"].flatMap(UInt32.init)
            )
            let node = AetherNode(
                name: defaultName,
                protocolID: .wireGuard,
                server: host,
                port: port,
                privateKey: privateKey,
                publicKey: publicKey,
                preSharedKey: psk,
                localAddress: address,
                localIPv6Address: ipv6,
                allowedIPs: allowed,
                mtu: mtu,
                dialerProxy: dialerProxy,
                amneziaWG: awg
            )
            return try node.validated()

        case "ssh":
            let node = AetherNode(
                name: defaultName,
                protocolID: .ssh,
                server: host,
                port: port,
                username: user,
                password: password,
                dialerProxy: dialerProxy
            )
            return try node.validated()

        case "shadowquic":
            let sni = query["sni"] ?? query["server-name"] ?? query["servername"] ?? host
            let cc = query["congestion-control"] ?? query["congestion_control"] ?? ""
            let mtu = (query["initial-mtu"] ?? query["mtu"]).flatMap(UInt16.init)
            let node = AetherNode(
                name: defaultName,
                protocolID: .shadowQUIC,
                server: host,
                port: port,
                username: user,
                password: password,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: sni),
                congestionController: cc,
                mtu: mtu,
                dialerProxy: dialerProxy
            )
            return try node.validated()

        default:
            throw AetherNodeURIError.unsupportedScheme(rawScheme)
        }
    }

    public static func format(_ rawNode: AetherNode) throws -> String {
        let node = try rawNode.validated()
        let encodedName = node.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? node.name
        let hostPart = node.server.contains(":") && !node.server.hasPrefix("[") ? "[\(node.server)]" : node.server

        switch node.protocolID {
        case .vless:
            var items: [URLQueryItem] = []
            if !node.tls.realityPublicKey.isEmpty {
                items.append(URLQueryItem(name: "security", value: "reality"))
                items.append(URLQueryItem(name: "sni", value: node.tls.serverName))
                items.append(URLQueryItem(name: "pbk", value: node.tls.realityPublicKey))
                if !node.tls.realityShortID.isEmpty {
                    items.append(URLQueryItem(name: "sid", value: node.tls.realityShortID))
                }
                items.append(URLQueryItem(name: "fp", value: node.tls.clientFingerprint))
            } else if node.tls.enabled {
                items.append(URLQueryItem(name: "security", value: "tls"))
                if !node.tls.serverName.isEmpty {
                    items.append(URLQueryItem(name: "sni", value: node.tls.serverName))
                }
            } else {
                items.append(URLQueryItem(name: "security", value: "none"))
            }
            appendTransportQueryItems(node.transport, to: &items)
            if !node.flow.isEmpty {
                items.append(URLQueryItem(name: "flow", value: node.flow))
            }
            if !node.vlessEncryption.isEmpty, node.vlessEncryption.lowercased() != "none" {
                items.append(URLQueryItem(name: "encryption", value: node.vlessEncryption))
            }
            appendCommonQueryItems(node: node, to: &items)
            return buildURI(scheme: "vless", userinfo: node.uuid, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .trojan:
            var items: [URLQueryItem] = []
            if !node.tls.serverName.isEmpty {
                items.append(URLQueryItem(name: "sni", value: node.tls.serverName))
            }
            appendTransportQueryItems(node.transport, to: &items)
            appendCommonQueryItems(node: node, to: &items)
            let userinfo = node.password.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.password
            return buildURI(scheme: "trojan", userinfo: userinfo, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .shadowsocks:
            let rawCreds = "\(node.cipher):\(node.password)"
            let b64Creds = encodeBase64URLUnpadded(rawCreds)
            var items: [URLQueryItem] = []
            if !node.plugin.isEmpty {
                var pluginParts = [node.plugin == "obfs" ? "obfs-local" : node.plugin]
                if node.plugin == "obfs" || node.plugin == "simple-obfs" {
                    if !node.pluginMode.isEmpty { pluginParts.append("obfs=\(node.pluginMode)") }
                    if !node.pluginHost.isEmpty { pluginParts.append("obfs-host=\(node.pluginHost)") }
                } else {
                    if !node.pluginMode.isEmpty { pluginParts.append("mode=\(node.pluginMode)") }
                    if !node.pluginHost.isEmpty { pluginParts.append("host=\(node.pluginHost)") }
                    if !node.pluginPath.isEmpty { pluginParts.append("path=\(node.pluginPath)") }
                    if !node.pluginPassword.isEmpty { pluginParts.append("password=\(node.pluginPassword)") }
                    if let v = node.pluginVersion { pluginParts.append("version=\(v)") }
                    if node.tls.enabled { pluginParts.append("tls") }
                }
                items.append(URLQueryItem(name: "plugin", value: pluginParts.joined(separator: ";")))
            }
            if let dialer = node.dialerProxy {
                items.append(URLQueryItem(name: "dialer-proxy", value: dialer))
            }
            return buildURI(scheme: "ss", userinfo: b64Creds, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .shadowsocksR:
            let proto = node.ssrProtocol.isEmpty ? "origin" : node.ssrProtocol
            let obfs = node.ssrObfs.isEmpty ? "plain" : node.ssrObfs
            let passB64 = encodeBase64URLUnpadded(node.password)
            let obfsParamB64 = encodeBase64URLUnpadded(node.ssrObfsParam)
            let protoParamB64 = encodeBase64URLUnpadded(node.ssrProtocolParam)
            let remarksB64 = encodeBase64URLUnpadded(node.name)
            let rawSSR = "\(node.server):\(node.port):\(proto):\(node.cipher):\(obfs):\(passB64)/?obfsparam=\(obfsParamB64)&protoparam=\(protoParamB64)&remarks=\(remarksB64)"
            return "ssr://\(encodeBase64URLUnpadded(rawSSR))"

        case .hysteria:
            var items: [URLQueryItem] = []
            items.append(URLQueryItem(name: "protocol", value: node.hysteriaProtocol.isEmpty ? "udp" : node.hysteriaProtocol))
            if !node.password.isEmpty {
                items.append(URLQueryItem(name: "auth", value: node.password))
            }
            if !node.hysteriaAuthBase64.isEmpty {
                items.append(URLQueryItem(name: "auth-base64", value: node.hysteriaAuthBase64))
            }
            if !node.tls.serverName.isEmpty {
                items.append(URLQueryItem(name: "peer", value: node.tls.serverName))
            }
            if !node.obfuscationPassword.isEmpty {
                items.append(URLQueryItem(name: "obfs", value: "xplus"))
                items.append(URLQueryItem(name: "obfsParam", value: node.obfuscationPassword))
            } else if !node.obfuscation.isEmpty {
                items.append(URLQueryItem(name: "obfs", value: "xplus"))
                items.append(URLQueryItem(name: "obfsParam", value: node.obfuscation))
            }
            if let up = node.uploadMbps {
                items.append(URLQueryItem(name: "upmbps", value: String(up)))
            }
            if let down = node.downloadMbps {
                items.append(URLQueryItem(name: "downmbps", value: String(down)))
            }
            if !node.alpn.isEmpty {
                items.append(URLQueryItem(name: "alpn", value: node.alpn.joined(separator: ",")))
            }
            appendCommonQueryItems(node: node, to: &items)
            return buildURI(scheme: "hysteria", userinfo: "", host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .hysteria2:
            var items: [URLQueryItem] = []
            if !node.tls.serverName.isEmpty {
                items.append(URLQueryItem(name: "sni", value: node.tls.serverName))
            }
            if node.obfuscation == "salamander" {
                items.append(URLQueryItem(name: "obfs", value: "salamander"))
                items.append(URLQueryItem(name: "obfs-password", value: node.obfuscationPassword))
            }
            if let up = node.uploadMbps {
                items.append(URLQueryItem(name: "upmbps", value: String(up)))
            }
            if let down = node.downloadMbps {
                items.append(URLQueryItem(name: "downmbps", value: String(down)))
            }
            if !node.alpn.isEmpty {
                items.append(URLQueryItem(name: "alpn", value: node.alpn.joined(separator: ",")))
            }
            appendCommonQueryItems(node: node, to: &items)
            let userinfo = node.password.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.password
            return buildURI(scheme: "hysteria2", userinfo: userinfo, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .tuic:
            var items: [URLQueryItem] = []
            if !node.tls.serverName.isEmpty {
                items.append(URLQueryItem(name: "sni", value: node.tls.serverName))
            }
            if !node.congestionController.isEmpty {
                items.append(URLQueryItem(name: "congestion_control", value: node.congestionController))
            }
            if !node.udpRelayMode.isEmpty {
                items.append(URLQueryItem(name: "udp_relay_mode", value: node.udpRelayMode))
            }
            if !node.alpn.isEmpty {
                items.append(URLQueryItem(name: "alpn", value: node.alpn.joined(separator: ",")))
            }
            if node.tuicReduceRTT {
                items.append(URLQueryItem(name: "reduce-rtt", value: "1"))
            }
            let isV4 = (node.tuicVersion == 4) || !node.tuicToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if isV4 {
                items.append(URLQueryItem(name: "version", value: "4"))
                appendCommonQueryItems(node: node, to: &items)
                let tokenEncoded = node.tuicToken.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.tuicToken
                return buildURI(scheme: "tuic", userinfo: tokenEncoded, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)
            } else {
                appendCommonQueryItems(node: node, to: &items)
                let passEncoded = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
                return buildURI(scheme: "tuic", userinfo: "\(node.uuid):\(passEncoded)", host: hostPart, port: node.port, queryItems: items, fragment: encodedName)
            }

        case .snell:
            var items: [URLQueryItem] = []
            let version = node.snellVersion ?? 4
            items.append(URLQueryItem(name: "version", value: String(version)))
            if !node.obfuscation.isEmpty {
                items.append(URLQueryItem(name: "obfs", value: node.obfuscation))
                if !node.snellObfsHost.isEmpty {
                    items.append(URLQueryItem(name: "obfs-host", value: node.snellObfsHost))
                }
            }
            if node.snellReuse {
                items.append(URLQueryItem(name: "reuse", value: "1"))
            }
            appendCommonQueryItems(node: node, to: &items)
            let pskEncoded = node.password.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.password
            return buildURI(scheme: "snell", userinfo: pskEncoded, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .mieru:
            var items: [URLQueryItem] = []
            items.append(URLQueryItem(name: "transport", value: node.mieruTransport.isEmpty ? "TCP" : node.mieruTransport.uppercased()))
            if !node.mieruMultiplexing.isEmpty {
                items.append(URLQueryItem(name: "multiplexing", value: node.mieruMultiplexing))
            }
            if !node.mieruHandshakeMode.isEmpty {
                items.append(URLQueryItem(name: "handshake-mode", value: node.mieruHandshakeMode))
            }
            if !node.mieruPortRange.isEmpty {
                items.append(URLQueryItem(name: "port-range", value: node.mieruPortRange))
            }
            appendCommonQueryItems(node: node, to: &items)
            let u = node.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.username
            let p = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
            return buildURI(scheme: "mieru", userinfo: "\(u):\(p)", host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .vmess:
            let netValue: String
            switch node.transport.kind {
            case .tcp: netValue = "tcp"
            case .webSocket: netValue = node.transport.httpUpgrade ? "httpupgrade" : "ws"
            case .http2: netValue = "h2"
            case .grpc: netValue = "grpc"
            case .xhttp: netValue = "xhttp"
            }
            let payload: [String: String] = [
                "v": "2",
                "ps": node.name,
                "add": node.server,
                "port": String(node.port),
                "id": node.uuid,
                "aid": "0",
                "scy": node.cipher.isEmpty ? "auto" : node.cipher,
                "net": netValue,
                "type": "none",
                "host": node.transport.host,
                "path": node.transport.kind == .grpc ? node.transport.grpcServiceName : node.transport.path,
                "tls": node.tls.enabled ? "tls" : "",
                "sni": node.tls.serverName,
            ]
            let jsonData = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return "vmess://\(jsonData.base64EncodedString())"

        case .anyTLS:
            var items: [URLQueryItem] = []
            if !node.tls.serverName.isEmpty {
                items.append(URLQueryItem(name: "sni", value: node.tls.serverName))
            }
            appendCommonQueryItems(node: node, to: &items)
            let userinfo = node.password.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.password
            return buildURI(scheme: "anytls", userinfo: userinfo, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .socks5:
            var userinfo = ""
            if !node.username.isEmpty {
                let u = node.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.username
                let p = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
                userinfo = node.password.isEmpty ? u : "\(u):\(p)"
            }
            var items: [URLQueryItem] = []
            appendCommonQueryItems(node: node, to: &items)
            return buildURI(scheme: "socks5", userinfo: userinfo, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .http:
            var userinfo = ""
            if !node.username.isEmpty {
                let u = node.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.username
                let p = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
                userinfo = node.password.isEmpty ? u : "\(u):\(p)"
            }
            var items: [URLQueryItem] = []
            appendCommonQueryItems(node: node, to: &items)
            return buildURI(scheme: node.tls.enabled ? "https" : "http", userinfo: userinfo, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .wireGuard:
            var items: [URLQueryItem] = [
                URLQueryItem(name: "public-key", value: node.publicKey),
                URLQueryItem(name: "address", value: node.localAddress),
                URLQueryItem(name: "allowed-ips", value: node.allowedIPs.joined(separator: ",")),
            ]
            if !node.localIPv6Address.isEmpty {
                items.append(URLQueryItem(name: "ipv6", value: node.localIPv6Address))
            }
            if !node.preSharedKey.isEmpty {
                items.append(URLQueryItem(name: "pre-shared-key", value: node.preSharedKey))
            }
            if let mtu = node.mtu {
                items.append(URLQueryItem(name: "mtu", value: String(mtu)))
            }
            if let jc = node.amneziaWG.jc { items.append(URLQueryItem(name: "jc", value: String(jc))) }
            if let jmin = node.amneziaWG.jmin { items.append(URLQueryItem(name: "jmin", value: String(jmin))) }
            if let jmax = node.amneziaWG.jmax { items.append(URLQueryItem(name: "jmax", value: String(jmax))) }
            if let s1 = node.amneziaWG.s1 { items.append(URLQueryItem(name: "s1", value: String(s1))) }
            if let s2 = node.amneziaWG.s2 { items.append(URLQueryItem(name: "s2", value: String(s2))) }
            if let h1 = node.amneziaWG.h1 { items.append(URLQueryItem(name: "h1", value: String(h1))) }
            if let h2 = node.amneziaWG.h2 { items.append(URLQueryItem(name: "h2", value: String(h2))) }
            if let h3 = node.amneziaWG.h3 { items.append(URLQueryItem(name: "h3", value: String(h3))) }
            if let h4 = node.amneziaWG.h4 { items.append(URLQueryItem(name: "h4", value: String(h4))) }
            appendCommonQueryItems(node: node, to: &items)
            let privEncoded = node.privateKey.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.privateKey
            return buildURI(scheme: "wireguard", userinfo: privEncoded, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .ssh:
            guard node.privateKey.isEmpty else {
                throw AetherNodeURIError.unsupportedProtocolForURI(.ssh)
            }
            let u = node.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.username
            let p = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
            let userinfo = node.password.isEmpty ? u : "\(u):\(p)"
            var items: [URLQueryItem] = []
            appendCommonQueryItems(node: node, to: &items)
            return buildURI(scheme: "ssh", userinfo: userinfo, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .shadowQUIC:
            let u = node.username.addingPercentEncoding(withAllowedCharacters: .urlUserAllowed) ?? node.username
            let p = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
            var items: [URLQueryItem] = [
                URLQueryItem(name: "sni", value: node.tls.serverName),
            ]
            if !node.congestionController.isEmpty {
                items.append(URLQueryItem(name: "congestion-control", value: node.congestionController))
            }
            if let mtu = node.mtu {
                items.append(URLQueryItem(name: "initial-mtu", value: String(mtu)))
            }
            appendCommonQueryItems(node: node, to: &items)
            return buildURI(scheme: "shadowquic", userinfo: "\(u):\(p)", host: hostPart, port: node.port, queryItems: items, fragment: encodedName)
        }
    }

    /// `URLComponents.host` keeps the brackets of an IPv6 literal; the core
    /// expects the bare address in `server`.
    private static func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    public static func parseShadowsocksPlugin(
        from query: [String: String]
    ) throws -> (plugin: String, mode: String, host: String, path: String, password: String, version: Int?, tls: Bool) {
        if let rawPlugin = query["plugin"], !rawPlugin.isEmpty {
            let parts = rawPlugin.split(separator: ";").map(String.init)
            guard let firstPart = parts.first else {
                throw AetherNodeURIError.malformedLink
            }
            let pluginName: String
            switch firstPart.lowercased() {
            case "obfs", "obfs-local", "simple-obfs":
                pluginName = "obfs"
            case "v2ray-plugin":
                pluginName = "v2ray-plugin"
            case "shadow-tls", "shadowtls":
                pluginName = "shadow-tls"
            default:
                throw AetherNodeURIError.malformedLink
            }
            var mode = ""
            var host = ""
            var path = ""
            var password = ""
            var version: Int?
            var tls = false
            for kv in parts.dropFirst() {
                if let eq = kv.firstIndex(of: "=") {
                    let k = kv[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                    let v = String(kv[kv.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                    switch k {
                    case "obfs", "mode": mode = v
                    case "obfs-host", "host": host = v
                    case "obfs-uri", "path": path = v
                    case "password": password = v
                    case "version": version = Int(v)
                    case "tls": tls = flagValue(v)
                    default: break
                    }
                } else if kv.trimmingCharacters(in: .whitespaces).lowercased() == "tls" {
                    tls = true
                }
            }
            if pluginName == "v2ray-plugin" && mode.isEmpty {
                mode = "websocket"
            }
            return (pluginName, mode, host, path, password, version, tls)
        }
        if let srObfs = query["obfs"]?.lowercased(), !srObfs.isEmpty, srObfs != "none" && srObfs != "plain" {
            let host = query["obfsparam"] ?? query["obfs-host"] ?? query["host"] ?? query["peer"] ?? ""
            let path = query["path"] ?? ""
            let tls = flagValue(query["tls"])
            switch srObfs {
            case "http", "tls", "simple_obfs_http", "simple_obfs_tls":
                let mode = srObfs.hasSuffix("tls") ? "tls" : "http"
                return ("obfs", mode, host, "", "", nil, false)
            case "websocket", "ws":
                return ("v2ray-plugin", "websocket", host, path, "", nil, tls)
            default:
                throw AetherNodeURIError.malformedLink
            }
        }
        return ("", "", "", "", "", nil, false)
    }

    private static func parseShadowsocks(_ uri: String) throws -> AetherNode {
        let body = String(uri.dropFirst(5))
        let parts = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let mainAndQuery = String(parts[0])
        let fragmentName = parts.count > 1
            ? String(parts[1]).removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        let queryParts = mainAndQuery.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let mainPart = String(queryParts[0]).replacingOccurrences(of: "/$", with: "", options: .regularExpression)
        let rawQuery = queryParts.count > 1 ? String(queryParts[1]) : ""

        var query: [String: String] = [:]
        if !rawQuery.isEmpty, let qComp = URLComponents(string: "http://stub?\(rawQuery)") {
            for item in qComp.queryItems ?? [] {
                if let val = item.value {
                    query[item.name.lowercased()] = val
                }
            }
        }

        let resolvedHost: String
        let resolvedPort: UInt16
        let resolvedCipher: String
        let resolvedPassword: String

        if mainPart.contains("@"),
           let components = URLComponents(string: "ss://\(mainPart)"),
           let host = components.host.map(unbracketedHost), !host.isEmpty,
           let portInt = components.port, let port = UInt16(exactly: portInt), port > 0
        {
            let userPart = components.user ?? ""
            let passPart = components.password ?? ""
            if !passPart.isEmpty {
                resolvedCipher = userPart
                resolvedPassword = passPart
            } else if let decoded = decodeBase64Flexible(userPart),
                      let colon = decoded.firstIndex(of: ":")
            {
                resolvedCipher = String(decoded[..<colon])
                resolvedPassword = String(decoded[decoded.index(after: colon)...])
            } else {
                throw AetherNodeURIError.malformedLink
            }
            resolvedHost = host
            resolvedPort = port
        } else if let decoded = decodeBase64Flexible(mainPart),
                  let at = decoded.lastIndex(of: "@"),
                  let colon = decoded[..<at].firstIndex(of: ":")
        {
            resolvedCipher = String(decoded[..<colon])
            resolvedPassword = String(decoded[decoded.index(after: colon)..<at])
            let endpointStr = String(decoded[decoded.index(after: at)...])
            guard let epComp = URLComponents(string: "ss://\(endpointStr)"),
                  let host = epComp.host.map(unbracketedHost), !host.isEmpty,
                  let portInt = epComp.port, let port = UInt16(exactly: portInt), port > 0
            else {
                throw AetherNodeURIError.malformedLink
            }
            resolvedHost = host
            resolvedPort = port
        } else {
            throw AetherNodeURIError.malformedLink
        }

        let pluginInfo = try parseShadowsocksPlugin(from: query)
        let remarks = query["remarks"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let fragmentName, !fragmentName.isEmpty {
            name = fragmentName
        } else if let remarks, !remarks.isEmpty {
            name = remarks
        } else {
            name = "SS-\(resolvedHost)"
        }
        let udpEnabled = query["udp"].map(flagValue) ?? query["uot"].map(flagValue) ?? true
        let fastOpen = flagValue(query["tfo"] ?? query["fast-open"])
        let node = AetherNode(
            name: name,
            protocolID: .shadowsocks,
            server: resolvedHost,
            port: resolvedPort,
            password: resolvedPassword,
            cipher: resolvedCipher,
            udp: udpEnabled,
            tls: AetherNodeTLS(enabled: pluginInfo.tls, serverName: query["peer"] ?? query["sni"] ?? ""),
            dialerProxy: query["dialer-proxy"] ?? query["detour"],
            plugin: pluginInfo.plugin,
            pluginMode: pluginInfo.mode,
            pluginHost: pluginInfo.host,
            pluginPath: pluginInfo.path,
            pluginPassword: pluginInfo.password,
            pluginVersion: pluginInfo.version,
            fastOpen: fastOpen
        )
        return try node.validated()
    }

    public static func parseShadowsocksR(_ uri: String) throws -> AetherNode {
        var encoded = String(uri.dropFirst(6)).trimmingCharacters(in: .whitespacesAndNewlines)
        var outerFragment: String?
        if let hashIdx = encoded.firstIndex(of: "#") {
            outerFragment = String(encoded[encoded.index(after: hashIdx)...])
                .removingPercentEncoding?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            encoded = String(encoded[..<hashIdx])
        }
        guard let decoded = decodeBase64Flexible(encoded) else {
            throw AetherNodeURIError.malformedLink
        }
        let splitQuery: [Substring]
        if let slashQ = decoded.range(of: "/?") {
            splitQuery = [decoded[..<slashQ.lowerBound], decoded[slashQ.upperBound...]]
        } else if let qIdx = decoded.firstIndex(of: "?") {
            splitQuery = [decoded[..<qIdx], decoded[decoded.index(after: qIdx)...]]
        } else {
            splitQuery = [decoded[...]]
        }
        let mainPart = String(splitQuery[0])
        let queryPart = splitQuery.count > 1 ? String(splitQuery[1]) : ""

        // Format is server:port:protocol:method:obfs:base64pass (server may be IPv6 with colons).
        var remaining = mainPart[...]
        var trailingFields: [String] = []
        for _ in 0..<5 {
            guard let lastColon = remaining.lastIndex(of: ":") else {
                throw AetherNodeURIError.malformedLink
            }
            trailingFields.append(String(remaining[remaining.index(after: lastColon)...]))
            remaining = remaining[..<lastColon]
        }
        trailingFields.reverse()
        let host = unbracketedHost(String(remaining))
        guard !host.isEmpty,
              let port = UInt16(trailingFields[0]), port > 0
        else {
            throw AetherNodeURIError.malformedLink
        }
        let ssrProtocol = trailingFields[1]
        let cipher = trailingFields[2]
        let ssrObfs = trailingFields[3]
        guard let password = decodeBase64Flexible(trailingFields[4]), !password.isEmpty else {
            throw AetherNodeURIError.malformedLink
        }

        var query: [String: String] = [:]
        if !queryPart.isEmpty, let comp = URLComponents(string: "http://stub?\(queryPart)") {
            for item in comp.queryItems ?? [] {
                if let val = item.value {
                    query[item.name.lowercased()] = val
                }
            }
        }
        let obfsParam = query["obfsparam"].flatMap { decodeBase64Flexible($0) ?? $0 } ?? ""
        let protoParam = query["protoparam"].flatMap { decodeBase64Flexible($0) ?? $0 } ?? ""
        let remarks = query["remarks"].flatMap { decodeBase64Flexible($0) ?? $0 }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String
        if let remarks, !remarks.isEmpty {
            name = remarks
        } else if let outerFragment, !outerFragment.isEmpty {
            name = outerFragment
        } else {
            name = "SSR-\(host)"
        }
        let udp = query["uot"].map(flagValue) ?? query["udp"].map(flagValue) ?? true
        let node = AetherNode(
            name: name,
            protocolID: .shadowsocksR,
            server: host,
            port: port,
            password: password,
            cipher: cipher,
            udp: udp,
            dialerProxy: query["dialer-proxy"] ?? query["detour"],
            ssrProtocol: ssrProtocol,
            ssrProtocolParam: protoParam,
            ssrObfs: ssrObfs,
            ssrObfsParam: obfsParam
        )
        return try node.validated()
    }

    /// Parses a single Surge `[Proxy]` line (`Name = protocol, server, port, ...`).
    /// Returns `nil` when the line is not in Surge proxy format.
    public static func parseSurgeProxyLine(_ rawLine: String) throws -> AetherNode? {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("//"),
              !trimmed.hasPrefix(";"),
              !trimmed.hasPrefix("["),
              !trimmed.contains("://"),
              let eqIdx = trimmed.firstIndex(of: "=")
        else { return nil }

        let name = String(trimmed[..<eqIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
        let rhs = String(trimmed[trimmed.index(after: eqIdx)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !rhs.isEmpty else { return nil }

        let tokens = splitCommaRespectingQuotes(rhs)
        guard let rawProto = tokens.first?.lowercased() else { return nil }
        if ["direct", "reject", "reject-tinygif", "reject-drop"].contains(rawProto) {
            return nil
        }
        guard tokens.count >= 3 else {
            throw AetherNodeURIError.malformedLink
        }
        let host = unbracketedHost(tokens[1].trimmingCharacters(in: .whitespacesAndNewlines))
        guard !host.isEmpty,
              let port = UInt16(tokens[2].trimmingCharacters(in: .whitespacesAndNewlines)),
              port > 0
        else {
            throw AetherNodeURIError.malformedLink
        }

        var params: [String: String] = [:]
        var positional: [String] = []
        for token in tokens.dropFirst(3) {
            if let paramEq = token.firstIndex(of: "=") {
                let k = String(token[..<paramEq]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let v = unquoteScalar(String(token[token.index(after: paramEq)...]).trimmingCharacters(in: .whitespacesAndNewlines))
                params[k] = v
            } else {
                positional.append(unquoteScalar(token))
            }
        }

        let udp = params["udp-relay"].map(flagValue) ?? true
        let fastOpen = flagValue(params["tfo"] ?? params["fast-open"])
        let skipVerify = flagValue(params["skip-cert-verify"])
        let sni = params["sni"] ?? params["server-name-indication"] ?? ""
        let certFingerprint = params["server-cert-fingerprint-sha256"] ?? ""
        let dialer = params["underlying-proxy"] ?? params["dialer-proxy"]
        let wsEnabled = flagValue(params["ws"] ?? params["websocket"])
        let wsPath = params["ws-path"] ?? ""
        var wsHost = ""
        if let headers = params["ws-headers"] {
            for part in headers.split(separator: "|") {
                let kv = part.split(separator: ":", maxSplits: 1)
                if kv.count == 2, kv[0].trimmingCharacters(in: .whitespaces).lowercased() == "host" {
                    wsHost = kv[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
        let transport = wsEnabled
            ? AetherNodeTransportOptions(kind: .webSocket, path: wsPath, host: wsHost)
            : AetherNodeTransportOptions(kind: .tcp)

        switch rawProto {
        case "ss", "custom":
            let cipher = params["encrypt-method"] ?? (positional.first ?? "")
            let password = params["password"] ?? (positional.count > 1 ? positional[1] : "")
            let obfs = (params["obfs"] ?? "").lowercased()
            let obfsHost = params["obfs-host"] ?? ""
            let plugin = (obfs == "http" || obfs == "tls") ? "obfs" : ""
            return try AetherNode(
                name: name,
                protocolID: .shadowsocks,
                server: host,
                port: port,
                password: password,
                cipher: cipher,
                udp: udp,
                dialerProxy: dialer,
                plugin: plugin,
                pluginMode: plugin.isEmpty ? "" : obfs,
                pluginHost: plugin.isEmpty ? "" : obfsHost,
                fastOpen: fastOpen
            ).validated()

        case "vmess":
            let uuid = params["username"] ?? params["uuid"] ?? (positional.first ?? "")
            let tlsEnabled = flagValue(params["tls"])
            return try AetherNode(
                name: name,
                protocolID: .vmess,
                server: host,
                port: port,
                uuid: uuid,
                cipher: params["encrypt-method"] ?? "auto",
                udp: udp,
                tls: AetherNodeTLS(
                    enabled: tlsEnabled,
                    serverName: sni.isEmpty ? (tlsEnabled ? host : "") : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                transport: transport,
                dialerProxy: dialer,
                fastOpen: fastOpen
            ).validated()

        case "trojan":
            let password = params["password"] ?? (positional.first ?? "")
            return try AetherNode(
                name: name,
                protocolID: .trojan,
                server: host,
                port: port,
                password: password,
                udp: udp,
                tls: AetherNodeTLS(
                    enabled: true,
                    serverName: sni.isEmpty ? host : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                transport: transport,
                dialerProxy: dialer,
                fastOpen: fastOpen
            ).validated()

        case "snell":
            let psk = params["psk"] ?? params["password"] ?? ""
            let version = params["version"].flatMap(Int.init) ?? 4
            let obfs = (params["obfs"] ?? "").lowercased()
            let obfsHost = params["obfs-host"] ?? ""
            let reuse = flagValue(params["reuse"])
            return try AetherNode(
                name: name,
                protocolID: .snell,
                server: host,
                port: port,
                password: psk,
                udp: version >= 3 ? udp : false,
                obfuscation: (obfs == "http" || obfs == "tls") ? obfs : "",
                dialerProxy: dialer,
                snellVersion: version,
                snellObfsHost: obfsHost,
                snellReuse: reuse,
                fastOpen: fastOpen
            ).validated()

        case "tuic", "tuic-v5":
            let token = params["token"] ?? ""
            let uuid = params["uuid"] ?? ""
            let password = params["password"] ?? ""
            let isV4 = (rawProto == "tuic" && !token.isEmpty && uuid.isEmpty)
            let alpnList = (params["alpn"] ?? "")
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return try AetherNode(
                name: name,
                protocolID: .tuic,
                server: host,
                port: port,
                password: password,
                uuid: uuid,
                tls: AetherNodeTLS(
                    enabled: true,
                    serverName: sni.isEmpty ? host : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                congestionController: params["congestion-controller"] ?? "bbr",
                udpRelayMode: params["udp-relay-mode"] ?? "native",
                dialerProxy: dialer,
                alpn: alpnList,
                tuicToken: token,
                tuicVersion: isV4 ? 4 : 5,
                fastOpen: fastOpen
            ).validated()

        case "hysteria2", "hy2":
            let password = params["password"] ?? (positional.first ?? "")
            let downMbps = (params["download-bandwidth"] ?? params["down"]).flatMap(UInt64.init)
            let upMbps = (params["upload-bandwidth"] ?? params["up"]).flatMap(UInt64.init)
            return try AetherNode(
                name: name,
                protocolID: .hysteria2,
                server: host,
                port: port,
                password: password,
                tls: AetherNodeTLS(
                    enabled: true,
                    serverName: sni.isEmpty ? host : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                uploadMbps: upMbps,
                downloadMbps: downMbps,
                dialerProxy: dialer,
                fastOpen: fastOpen
            ).validated()

        case "anytls":
            let password = params["password"] ?? (positional.first ?? "")
            return try AetherNode(
                name: name,
                protocolID: .anyTLS,
                server: host,
                port: port,
                password: password,
                udp: udp,
                tls: AetherNodeTLS(
                    enabled: true,
                    serverName: sni.isEmpty ? host : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                dialerProxy: dialer,
                fastOpen: fastOpen
            ).validated()

        case "http", "https":
            let user = params["username"] ?? (positional.first ?? "")
            let pass = params["password"] ?? (positional.count > 1 ? positional[1] : "")
            let tlsEnabled = (rawProto == "https") || flagValue(params["tls"])
            return try AetherNode(
                name: name,
                protocolID: .http,
                server: host,
                port: port,
                username: user,
                password: pass,
                tls: AetherNodeTLS(
                    enabled: tlsEnabled,
                    serverName: sni.isEmpty ? (tlsEnabled ? host : "") : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                dialerProxy: dialer
            ).validated()

        case "socks5", "socks5-tls":
            let user = params["username"] ?? (positional.first ?? "")
            let pass = params["password"] ?? (positional.count > 1 ? positional[1] : "")
            let tlsEnabled = (rawProto == "socks5-tls") || flagValue(params["tls"])
            return try AetherNode(
                name: name,
                protocolID: .socks5,
                server: host,
                port: port,
                username: user,
                password: pass,
                udp: udp,
                tls: AetherNodeTLS(
                    enabled: tlsEnabled,
                    serverName: sni.isEmpty ? (tlsEnabled ? host : "") : sni,
                    skipCertificateVerification: skipVerify,
                    certificateFingerprint: certFingerprint
                ),
                dialerProxy: dialer
            ).validated()

        default:
            throw AetherNodeURIError.unsupportedScheme(rawProto)
        }
    }

    private static func splitCommaRespectingQuotes(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for ch in text {
            if let q = quote {
                if ch == q { quote = nil }
                current.append(ch)
            } else if ch == "\"" || ch == "'" {
                quote = ch
                current.append(ch)
            } else if ch == "," {
                result.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
            } else {
                current.append(ch)
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func unquoteScalar(_ value: String) -> String {
        guard value.count >= 2,
              (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'"))
        else { return value }
        return String(value.dropFirst().dropLast())
    }

    private static func parseVMess(_ uri: String) throws -> AetherNode {
        let encoded = String(uri.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decoded = decodeBase64Flexible(encoded),
              let jsonData = decoded.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any]
        else {
            throw AetherNodeURIError.malformedLink
        }

        func str(_ key: String) -> String {
            if let s = dict[key] as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
            if let n = dict[key] as? NSNumber { return n.stringValue }
            return ""
        }

        let host = str("add")
        let portStr = str("port")
        let uuid = str("id")
        guard !host.isEmpty, let port = UInt16(portStr), port > 0, !uuid.isEmpty else {
            throw AetherNodeURIError.malformedLink
        }

        let name = str("ps").isEmpty ? "VMess-\(host)" : str("ps")
        let scy = str("scy")
        let cipher = (scy.isEmpty || scy == "none") ? "auto" : scy
        let net = str("net").lowercased()
        let wsHost = str("host")
        let wsPath = str("path")
        let transport: AetherNodeTransportOptions
        switch net {
        case "", "tcp", "raw", "none":
            transport = AetherNodeTransportOptions(kind: .tcp)
        case "ws", "websocket":
            transport = AetherNodeTransportOptions(kind: .webSocket, path: wsPath, host: wsHost)
        case "httpupgrade":
            transport = AetherNodeTransportOptions(
                kind: .webSocket, path: wsPath, host: wsHost, httpUpgrade: true
            )
        case "h2", "http":
            transport = AetherNodeTransportOptions(kind: .http2, path: wsPath, host: wsHost)
        case "grpc":
            transport = AetherNodeTransportOptions(kind: .grpc, grpcServiceName: wsPath)
        default:
            throw AetherNodeURIError.unsupportedTransport(net)
        }

        let tlsField = str("tls").lowercased()
        let tlsEnabled = (tlsField == "tls" || tlsField == "true" || tlsField == "1")
        let sni = str("sni").isEmpty ? (wsHost.isEmpty ? host : wsHost) : str("sni")
        let tls = AetherNodeTLS(
            enabled: tlsEnabled,
            serverName: tlsEnabled ? sni : ""
        )

        let node = AetherNode(
            name: name,
            protocolID: .vmess,
            server: host,
            port: port,
            uuid: uuid,
            cipher: cipher,
            tls: tls,
            transport: transport
        )
        return try node.validated()
    }

    private static func parseTLS(
        from query: [String: String],
        defaultEnabled: Bool,
        fallbackSNI: String
    ) -> AetherNodeTLS {
        let security = query["security"]?.lowercased()
        let enabled: Bool
        if let security {
            enabled = (security == "tls" || security == "reality" || security == "xtls")
        } else if let tlsParam = query["tls"]?.lowercased() {
            enabled = (tlsParam == "1" || tlsParam == "true" || tlsParam == "tls")
        } else {
            enabled = defaultEnabled
        }
        let sni = query["sni"] ?? query["servername"] ?? query["server-name"] ?? query["peer"] ?? (enabled ? fallbackSNI : "")
        let insecureRaw = (query["allowinsecure"] ?? query["insecure"] ?? "0").lowercased()
        let skipVerify = (insecureRaw == "1" || insecureRaw == "true")
        let fingerprint = query["pinsha256"] ?? query["cert-sha256"] ?? ""
        let pbk = query["pbk"] ?? query["publickey"] ?? query["public-key"] ?? ""
        let sid = query["sid"] ?? query["shortid"] ?? query["short-id"] ?? ""
        let fp = query["fp"] ?? query["fingerprint"] ?? "chrome"
        return AetherNodeTLS(
            enabled: enabled,
            serverName: sni,
            skipCertificateVerification: skipVerify,
            realityPublicKey: pbk,
            realityShortID: sid,
            clientFingerprint: fp,
            certificateFingerprint: fingerprint
        )
    }

    private static func parseTransport(from query: [String: String]) throws -> AetherNodeTransportOptions {
        let srObfs = query["obfs"]?.lowercased()
        let fallbackType: String
        if let srObfs, ["websocket", "ws", "grpc", "http", "h2", "xhttp"].contains(srObfs) {
            fallbackType = srObfs
        } else {
            fallbackType = "tcp"
        }
        let rawType = (query["type"] ?? query["network"] ?? fallbackType).lowercased()
        let host = query["host"] ?? query["authority"] ?? query["obfsparam"] ?? ""
        let path = query["path"] ?? ""
        let serviceName = query["servicename"] ?? query["service-name"] ?? query["grpc-service-name"] ?? path
        let xhttpMode = query["mode"] ?? ""
        switch rawType {
        case "", "tcp", "raw", "none":
            return AetherNodeTransportOptions(kind: .tcp)
        case "ws", "websocket":
            return AetherNodeTransportOptions(kind: .webSocket, path: path, host: host)
        case "httpupgrade":
            return AetherNodeTransportOptions(kind: .webSocket, path: path, host: host, httpUpgrade: true)
        case "h2", "http":
            return AetherNodeTransportOptions(kind: .http2, path: path, host: host)
        case "grpc":
            return AetherNodeTransportOptions(kind: .grpc, grpcServiceName: serviceName)
        case "xhttp", "splithttp":
            return AetherNodeTransportOptions(kind: .xhttp, path: path, host: host, xhttpMode: xhttpMode)
        default:
            // A node silently turned into TCP could never connect.
            throw AetherNodeURIError.unsupportedTransport(rawType)
        }
    }

    private static func appendTransportQueryItems(
        _ transport: AetherNodeTransportOptions,
        to items: inout [URLQueryItem]
    ) {
        switch transport.kind {
        case .tcp:
            items.append(URLQueryItem(name: "type", value: "tcp"))
        case .webSocket:
            items.append(URLQueryItem(
                name: "type",
                value: transport.httpUpgrade ? "httpupgrade" : "ws"
            ))
            if !transport.host.isEmpty {
                items.append(URLQueryItem(name: "host", value: transport.host))
            }
            if !transport.path.isEmpty {
                items.append(URLQueryItem(name: "path", value: transport.path))
            }
        case .http2:
            items.append(URLQueryItem(name: "type", value: "h2"))
            if !transport.host.isEmpty {
                items.append(URLQueryItem(name: "host", value: transport.host))
            }
            if !transport.path.isEmpty {
                items.append(URLQueryItem(name: "path", value: transport.path))
            }
        case .grpc:
            items.append(URLQueryItem(name: "type", value: "grpc"))
            if !transport.grpcServiceName.isEmpty {
                items.append(URLQueryItem(name: "serviceName", value: transport.grpcServiceName))
            }
        case .xhttp:
            items.append(URLQueryItem(name: "type", value: "xhttp"))
            if !transport.host.isEmpty {
                items.append(URLQueryItem(name: "host", value: transport.host))
            }
            if !transport.path.isEmpty {
                items.append(URLQueryItem(name: "path", value: transport.path))
            }
            if !transport.xhttpMode.isEmpty {
                items.append(URLQueryItem(name: "mode", value: transport.xhttpMode))
            }
        }
    }

    private static func appendCommonQueryItems(node: AetherNode, to items: inout [URLQueryItem]) {
        if node.tls.skipCertificateVerification {
            items.append(URLQueryItem(name: "allowInsecure", value: "1"))
        }
        if !node.tls.certificateFingerprint.isEmpty {
            items.append(URLQueryItem(name: "pinSHA256", value: node.tls.certificateFingerprint))
        }
        if node.fastOpen {
            items.append(URLQueryItem(name: "tfo", value: "1"))
        }
        if let dialer = node.dialerProxy {
            items.append(URLQueryItem(name: "dialer-proxy", value: dialer))
        }
    }

    private static func flagValue(_ raw: String?) -> Bool {
        guard let v = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return v == "1" || v == "true" || v == "yes"
    }

    private static func encodeBase64URLUnpadded(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func buildURI(
        scheme: String,
        userinfo: String,
        host: String,
        port: UInt16,
        queryItems: [URLQueryItem],
        fragment: String
    ) -> String {
        let auth = userinfo.isEmpty ? "" : "\(userinfo)@"
        var queryPart = ""
        if !queryItems.isEmpty {
            var comp = URLComponents()
            comp.queryItems = queryItems
            if let q = comp.percentEncodedQuery, !q.isEmpty {
                queryPart = "?\(q)"
            }
        }
        let fragPart = fragment.isEmpty ? "" : "#\(fragment)"
        return "\(scheme)://\(auth)\(host):\(port)\(queryPart)\(fragPart)"
    }

    private static func decodeBase64Flexible(_ input: String) -> String? {
        var normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder > 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        guard let data = Data(base64Encoded: normalized) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

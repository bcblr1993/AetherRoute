import Foundation

public enum AetherNodeProtocol: String, CaseIterable, Codable, Sendable {
    case http
    case socks5
    case shadowsocks
    case vmess
    case vless
    case trojan
    case hysteria2
    case tuic
    case anyTLS = "anytls"
    case wireGuard = "wireguard"
    case ssh
    case shadowQUIC = "shadowquic"

    public var displayName: String {
        switch self {
        case .http: "HTTP / HTTPS"
        case .socks5: "SOCKS5"
        case .shadowsocks: "Shadowsocks"
        case .vmess: "VMess"
        case .vless: "VLESS"
        case .trojan: "Trojan"
        case .hysteria2: "Hysteria2"
        case .tuic: "TUIC v5"
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

    public init(
        kind: AetherNodeTransport = .tcp,
        path: String = "",
        host: String = "",
        grpcServiceName: String = ""
    ) {
        self.kind = kind
        self.path = path
        self.host = host
        self.grpcServiceName = grpcServiceName
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
        dialerProxy: String? = nil
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
            ("SNI", tls.serverName),
            ("Reality public key", tls.realityPublicKey),
            ("Reality short ID", tls.realityShortID),
            ("Client fingerprint", tls.clientFingerprint),
            ("Certificate fingerprint", tls.certificateFingerprint),
            ("Transport path", transport.path),
            ("Transport host", transport.host),
            ("gRPC service name", transport.grpcServiceName),
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
        ] {
            try Self.validateScalar(value, field: field, maximumBytes: 4_096)
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
        case .vmess, .vless:
            try Self.requireUUID(uuid)
        case .trojan, .hysteria2, .anyTLS:
            try Self.require(password, field: "Password")
        case .tuic:
            try Self.requireUUID(uuid)
            try Self.require(password, field: "Password")
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
        .http, .socks5, .vmess, .vless, .trojan, .hysteria2, .tuic, .anyTLS,
    ]

    var supportsCertificateFingerprint: Bool {
        Self.certificateFingerprintProtocols.contains(protocolID)
            && (tls.enabled || [.trojan, .hysteria2, .tuic, .anyTLS].contains(protocolID))
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
                "    port: \(node.port)",
            ])
            appendProtocolFields(node, to: &lines)
            appendTransport(node, to: &lines)
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
        case .hysteria2:
            field("password", node.password, to: &lines)
            fieldIfPresent("obfs", node.obfuscation, to: &lines)
            fieldIfPresent("obfs-password", node.obfuscationPassword, to: &lines)
            integerFieldIfPresent("up", node.uploadMbps, to: &lines)
            integerFieldIfPresent("down", node.downloadMbps, to: &lines)
            appendTLS(node, enabledField: false, to: &lines)
        case .tuic:
            field("uuid", node.uuid.lowercased(), to: &lines)
            field("password", node.password, to: &lines)
            fieldIfPresent(
                "congestion-controller",
                node.congestionController,
                to: &lines
            )
            fieldIfPresent("udp-relay-mode", node.udpRelayMode, to: &lines)
            appendTLS(node, enabledField: false, to: &lines)
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

        guard let components = URLComponents(string: trimmed),
              let rawScheme = components.scheme?.lowercased()
        else {
            throw AetherNodeURIError.malformedLink
        }

        guard let host = components.host.map(unbracketedHost), !host.isEmpty,
              let portInt = components.port,
              let port = UInt16(exactly: portInt), port > 0
        else {
            throw AetherNodeURIError.malformedLink
        }

        let query = Dictionary(
            (components.queryItems ?? []).compactMap { item -> (String, String)? in
                guard let val = item.value else { return nil }
                return (item.name.lowercased(), val)
            },
            uniquingKeysWith: { _, last in last }
        )
        // `fragment` is already percent-decoded; decoding it again turns a
        // literal "%" into nil and loses the name.
        let fragmentName = components.fragment?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let defaultName = (fragmentName?.isEmpty == false) ? fragmentName! : "\(rawScheme.uppercased())-\(host)"

        let user = components.user ?? ""
        let password = components.password ?? ""
        let dialerProxy = query["dialer-proxy"] ?? query["detour"]

        switch rawScheme {
        case "vless":
            let node = AetherNode(
                name: defaultName,
                protocolID: .vless,
                server: host,
                port: port,
                uuid: user,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                transport: parseTransport(from: query),
                flow: query["flow"] ?? "",
                dialerProxy: dialerProxy
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
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                transport: parseTransport(from: query),
                dialerProxy: dialerProxy
            )
            return try node.validated()

        case "hysteria2", "hy2":
            let secret = password.isEmpty ? user : "\(user):\(password)"
            let obfs = (query["obfs"]?.lowercased() == "salamander") ? "salamander" : ""
            let obfsPassword = obfs.isEmpty ? "" : (query["obfs-password"] ?? "")
            let upMbps = query["upmbps"].flatMap(UInt64.init)
            let downMbps = query["downmbps"].flatMap(UInt64.init)
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
                dialerProxy: dialerProxy
            )
            return try node.validated()

        case "tuic":
            let parsedUUID: String
            let parsedPass: String
            if !password.isEmpty {
                parsedUUID = user
                parsedPass = password
            } else if let colon = user.firstIndex(of: ":") {
                parsedUUID = String(user[..<colon])
                parsedPass = String(user[user.index(after: colon)...])
            } else {
                parsedUUID = user
                parsedPass = query["password"] ?? ""
            }
            let node = AetherNode(
                name: defaultName,
                protocolID: .tuic,
                server: host,
                port: port,
                password: parsedPass,
                uuid: parsedUUID,
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                congestionController: query["congestion_control"] ?? query["cc"] ?? "bbr",
                udpRelayMode: query["udp_relay_mode"] ?? "native",
                dialerProxy: dialerProxy
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
                tls: parseTLS(from: query, defaultEnabled: true, fallbackSNI: host),
                dialerProxy: dialerProxy
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
            let b64Creds = Data(rawCreds.utf8).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            var items: [URLQueryItem] = []
            if let dialer = node.dialerProxy {
                items.append(URLQueryItem(name: "dialer-proxy", value: dialer))
            }
            return buildURI(scheme: "ss", userinfo: b64Creds, host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

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
            appendCommonQueryItems(node: node, to: &items)
            let passEncoded = node.password.addingPercentEncoding(withAllowedCharacters: .urlPasswordAllowed) ?? node.password
            return buildURI(scheme: "tuic", userinfo: "\(node.uuid):\(passEncoded)", host: hostPart, port: node.port, queryItems: items, fragment: encodedName)

        case .vmess:
            let netValue: String
            switch node.transport.kind {
            case .tcp: netValue = "tcp"
            case .webSocket: netValue = "ws"
            case .http2: netValue = "h2"
            case .grpc: netValue = "grpc"
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

        case .wireGuard, .ssh, .shadowQUIC:
            throw AetherNodeURIError.unsupportedProtocolForURI(node.protocolID)
        }
    }

    /// `URLComponents.host` keeps the brackets of an IPv6 literal; the core
    /// expects the bare address in `server`.
    private static func unbracketedHost(_ host: String) -> String {
        guard host.hasPrefix("["), host.hasSuffix("]") else { return host }
        return String(host.dropFirst().dropLast())
    }

    private static func parseShadowsocks(_ uri: String) throws -> AetherNode {
        let body = String(uri.dropFirst(5))
        let parts = body.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let mainPart = String(parts[0])
        let fragmentName = parts.count > 1
            ? String(parts[1]).removingPercentEncoding?.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        if mainPart.contains("@"), let components = URLComponents(string: uri),
           let host = components.host.map(unbracketedHost), !host.isEmpty,
           let portInt = components.port, let port = UInt16(exactly: portInt), port > 0
        {
            let userPart = components.user ?? ""
            let passPart = components.password ?? ""
            let cipher: String
            let password: String
            if !passPart.isEmpty {
                cipher = userPart
                password = passPart
            } else if let decoded = decodeBase64Flexible(userPart),
                      let colon = decoded.firstIndex(of: ":")
            {
                cipher = String(decoded[..<colon])
                password = String(decoded[decoded.index(after: colon)...])
            } else {
                throw AetherNodeURIError.malformedLink
            }
            let query = Dictionary(
                (components.queryItems ?? []).compactMap { item -> (String, String)? in
                    guard let val = item.value else { return nil }
                    return (item.name.lowercased(), val)
                },
                uniquingKeysWith: { _, last in last }
            )
            let name = (fragmentName?.isEmpty == false) ? fragmentName! : "SS-\(host)"
            let node = AetherNode(
                name: name,
                protocolID: .shadowsocks,
                server: host,
                port: port,
                password: password,
                cipher: cipher,
                dialerProxy: query["dialer-proxy"] ?? query["detour"]
            )
            return try node.validated()
        } else if let decoded = decodeBase64Flexible(mainPart),
                  let components = URLComponents(string: "ss://\(decoded)"),
                  let host = components.host.map(unbracketedHost), !host.isEmpty,
                  let portInt = components.port, let port = UInt16(exactly: portInt), port > 0,
                  let cipher = components.user, !cipher.isEmpty,
                  let password = components.password
        {
            let name = (fragmentName?.isEmpty == false) ? fragmentName! : "SS-\(host)"
            let node = AetherNode(
                name: name,
                protocolID: .shadowsocks,
                server: host,
                port: port,
                password: password,
                cipher: cipher
            )
            return try node.validated()
        }
        throw AetherNodeURIError.malformedLink
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
        case "ws", "websocket":
            transport = AetherNodeTransportOptions(kind: .webSocket, path: wsPath, host: wsHost)
        case "h2", "http":
            transport = AetherNodeTransportOptions(kind: .http2, path: wsPath, host: wsHost)
        case "grpc":
            transport = AetherNodeTransportOptions(kind: .grpc, grpcServiceName: wsPath)
        default:
            transport = AetherNodeTransportOptions(kind: .tcp)
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
        let sni = query["sni"] ?? query["peer"] ?? (enabled ? fallbackSNI : "")
        let insecureRaw = (query["allowinsecure"] ?? query["insecure"] ?? "0").lowercased()
        let skipVerify = (insecureRaw == "1" || insecureRaw == "true")
        let fingerprint = query["pinsha256"] ?? query["cert-sha256"] ?? ""
        let pbk = query["pbk"] ?? ""
        let sid = query["sid"] ?? ""
        let fp = query["fp"] ?? "chrome"
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

    private static func parseTransport(from query: [String: String]) -> AetherNodeTransportOptions {
        let rawType = (query["type"] ?? query["network"] ?? "tcp").lowercased()
        let host = query["host"] ?? ""
        let path = query["path"] ?? ""
        let serviceName = query["servicename"] ?? path
        switch rawType {
        case "ws", "websocket":
            return AetherNodeTransportOptions(kind: .webSocket, path: path, host: host)
        case "h2", "http":
            return AetherNodeTransportOptions(kind: .http2, path: path, host: host)
        case "grpc":
            return AetherNodeTransportOptions(kind: .grpc, grpcServiceName: serviceName)
        default:
            return AetherNodeTransportOptions(kind: .tcp)
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
            items.append(URLQueryItem(name: "type", value: "ws"))
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
        }
    }

    private static func appendCommonQueryItems(node: AetherNode, to items: inout [URLQueryItem]) {
        if node.tls.skipCertificateVerification {
            items.append(URLQueryItem(name: "allowInsecure", value: "1"))
        }
        if !node.tls.certificateFingerprint.isEmpty {
            items.append(URLQueryItem(name: "pinSHA256", value: node.tls.certificateFingerprint))
        }
        if let dialer = node.dialerProxy {
            items.append(URLQueryItem(name: "dialer-proxy", value: dialer))
        }
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

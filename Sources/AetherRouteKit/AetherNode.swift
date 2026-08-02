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

    public init(
        enabled: Bool = false,
        serverName: String = "",
        skipCertificateVerification: Bool = false,
        realityPublicKey: String = "",
        realityShortID: String = "",
        clientFingerprint: String = "chrome"
    ) {
        self.enabled = enabled
        self.serverName = serverName
        self.skipCertificateVerification = skipCertificateVerification
        self.realityPublicKey = realityPublicKey
        self.realityShortID = realityShortID
        self.clientFingerprint = clientFingerprint
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
        privateKeyPassphrase: String? = nil
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
        ] {
            try Self.validateScalar(value, field: field, maximumBytes: 4_096)
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

    public var errorDescription: String? {
        switch self {
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

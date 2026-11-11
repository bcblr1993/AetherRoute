import Foundation

public enum DNSRuntimeResolutionMode: Int32, CaseIterable, Codable, Sendable {
    case inherit = -1
    case normal = 0
    case fakeIP = 1
    case redirHost = 2
}

public enum DNSRuntimeBoolean: Int32, CaseIterable, Codable, Sendable {
    case inherit = -1
    case disabled = 0
    case enabled = 1
}

/// Profile-bound DNS behavior that the Direct Packet Tunnel applies after the
/// core has parsed and validated the imported YAML. It contains no resolver
/// endpoints, domain names, credentials, or browsing data.
public struct DNSRuntimePolicy: Codable, Equatable, Sendable {
    public static let inherited = DNSRuntimePolicy()

    public var resolutionMode: DNSRuntimeResolutionMode
    public var ipv6: DNSRuntimeBoolean
    public var respectsRules: DNSRuntimeBoolean

    public init(
        resolutionMode: DNSRuntimeResolutionMode = .inherit,
        ipv6: DNSRuntimeBoolean = .inherit,
        respectsRules: DNSRuntimeBoolean = .inherit
    ) {
        self.resolutionMode = resolutionMode
        self.ipv6 = ipv6
        self.respectsRules = respectsRules
    }

    public var isInherited: Bool {
        self == .inherited
    }

    /// Conservative first-run behavior for Packet Tunnel profiles, including
    /// missing or disabled DNS sections that the core enables as Normal DNS.
    /// Normal DNS
    /// exposes macOS to poisoned or split-horizon upstream answers before the
    /// rule engine can preserve the original hostname. Fake-IP keeps the name
    /// bound to the packet so the selected proxy can resolve it on the intended
    /// route. IPv6 stays disabled by default because many otherwise healthy
    /// nodes do not provide a usable IPv6 egress path. An explicit saved choice
    /// always takes precedence over this compatibility default.
    public static func packetTunnelCompatibilityDefault(
        for dns: DNSConfigurationSummary
    ) -> DNSRuntimePolicy {
        guard dns.isEnabled else {
            return DNSRuntimePolicy(
                resolutionMode: .fakeIP,
                ipv6: .disabled
            )
        }
        switch dns.mode {
        case .normal:
            return DNSRuntimePolicy(
                resolutionMode: .fakeIP,
                ipv6: .disabled
            )
        case .fakeIP where dns.allowsIPv6:
            return DNSRuntimePolicy(ipv6: .disabled)
        case .fakeIP, .redirHost, .unsupported:
            return .inherited
        }
    }

    /// Mirrors the core's Packet Tunnel resolver setup before runtime overrides.
    /// Missing or disabled DNS starts as Normal, even if a disabled section
    /// names another mode. Explicitly inheriting the profile keeps that choice.
    public func effectivePacketTunnelResolutionMode(
        for dns: DNSConfigurationSummary
    ) -> DNSResolutionMode {
        switch resolutionMode {
        case .inherit: dns.isEnabled ? dns.mode : .normal
        case .normal: .normal
        case .fakeIP: .fakeIP
        case .redirHost: .redirHost
        }
    }

    public func effectivePacketTunnelAllowsIPv6(
        for dns: DNSConfigurationSummary,
        profileAllowsIPv6: Bool
    ) -> Bool {
        switch ipv6 {
        case .inherit: profileAllowsIPv6 && dns.allowsIPv6
        case .disabled: false
        case .enabled: true
        }
    }
}

public struct DNSRuntimePolicyStore: Sendable {
    public static let maximumFileBytes = 64 * 1_024
    public static let maximumProfileCount = 128

    public let directoryURL: URL

    private var policyURL: URL {
        directoryURL.appendingPathComponent(
            "dns-runtime-policy.v1.json",
            isDirectory: false
        )
    }

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw DNSRuntimePolicyError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    public func load(
        forProfileYAML yaml: String,
        fileManager: FileManager = .default
    ) throws -> DNSRuntimePolicy {
        try loadIfPresent(forProfileYAML: yaml, fileManager: fileManager)
            ?? .inherited
    }

    /// Returns nil when no choice has been saved for this exact profile. This
    /// lets the host distinguish a first-run compatibility default from an
    /// explicit saved `.inherited` choice.
    public func loadIfPresent(
        forProfileYAML yaml: String,
        fileManager: FileManager = .default
    ) throws -> DNSRuntimePolicy? {
        guard let payload = try loadPayload(fileManager: fileManager) else {
            return nil
        }
        return payload.policies[Self.profileDigest(yaml)]
    }

    public func save(
        _ policy: DNSRuntimePolicy,
        forProfileYAML yaml: String,
        fileManager: FileManager = .default
    ) throws {
        let digest = Self.profileDigest(yaml)
        let existing = try? loadPayload(fileManager: fileManager)
        var policies = existing?.policies ?? [:]
        var profileOrder = existing?.profileOrder ?? []
        profileOrder.removeAll { $0 == digest }
        while policies[digest] == nil,
              policies.count >= Self.maximumProfileCount,
              let oldest = profileOrder.first {
            policies.removeValue(forKey: oldest)
            profileOrder.removeFirst()
        }
        policies[digest] = policy
        profileOrder.append(digest)

        let payload = DNSRuntimePolicyPayload(
            policies: policies,
            profileOrder: profileOrder
        )
        let data: Data
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            data = try encoder.encode(payload)
        } catch {
            throw DNSRuntimePolicyError.encodingFailed
        }
        guard data.count <= Self.maximumFileBytes else {
            throw DNSRuntimePolicyError.fileTooLarge(data.count)
        }

        let directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try fileManager.setAttributes(
            directoryAttributes,
            ofItemAtPath: directoryURL.path
        )
        try excludeFromBackup(directoryURL)
        do {
            try data.write(to: policyURL, options: [.atomic])
            try fileManager.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: policyURL.path
            )
            try excludeFromBackup(policyURL)
        } catch {
            throw DNSRuntimePolicyError.writeFailed
        }
    }

    private func loadPayload(
        fileManager: FileManager
    ) throws -> DNSRuntimePolicyPayload? {
        let data: Data
        do {
            data = try Data(contentsOf: policyURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard data.count <= Self.maximumFileBytes else {
            throw DNSRuntimePolicyError.fileTooLarge(data.count)
        }
        let payload: DNSRuntimePolicyPayload
        do {
            payload = try JSONDecoder().decode(
                DNSRuntimePolicyPayload.self,
                from: data
            )
        } catch let error as DNSRuntimePolicyError {
            throw error
        } catch {
            throw DNSRuntimePolicyError.decodingFailed
        }
        for digest in payload.policies.keys {
            guard Self.isValidDigest(digest) else {
                throw DNSRuntimePolicyError.invalidProfileDigest
            }
        }
        guard payload.profileOrder.count == payload.policies.count,
              Set(payload.profileOrder) == Set(payload.policies.keys) else {
            throw DNSRuntimePolicyError.decodingFailed
        }
        return payload
    }

    private static func profileDigest(_ yaml: String) -> String {
        ProxySelectionStore.profileDigest(yaml: yaml)
    }

    private static func isValidDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { byte in
            (48...57).contains(byte) || (97...102).contains(byte)
        }
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

private struct DNSRuntimePolicyPayload: Codable, Sendable {
    static let legacyVersion = 1
    static let currentVersion = 2

    let formatVersion: Int
    let policies: [String: DNSRuntimePolicy]
    let profileOrder: [String]

    init(
        policies: [String: DNSRuntimePolicy],
        profileOrder: [String]
    ) {
        self.formatVersion = Self.currentVersion
        self.policies = policies
        self.profileOrder = profileOrder
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case profileDigest
        case policy
        case policies
        case profileOrder
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .formatVersion)
        switch version {
        case Self.legacyVersion:
            let digest = try container.decode(String.self, forKey: .profileDigest)
            let single = try container.decode(DNSRuntimePolicy.self, forKey: .policy)
            self.formatVersion = Self.currentVersion
            self.policies = [digest: single]
            self.profileOrder = [digest]
        case Self.currentVersion:
            let decodedPolicies = try container.decode(
                [String: DNSRuntimePolicy].self,
                forKey: .policies
            )
            let decodedOrder = try container.decodeIfPresent(
                [String].self,
                forKey: .profileOrder
            ) ?? decodedPolicies.keys.sorted()
            self.formatVersion = Self.currentVersion
            self.policies = decodedPolicies
            self.profileOrder = decodedOrder
        default:
            throw DNSRuntimePolicyError.unsupportedFormat(version)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentVersion, forKey: .formatVersion)
        try container.encode(policies, forKey: .policies)
        try container.encode(profileOrder, forKey: .profileOrder)
    }
}

public enum DNSRuntimePolicyError: LocalizedError, Equatable, Sendable {
    case appGroupUnavailable
    case decodingFailed
    case encodingFailed
    case fileTooLarge(Int)
    case invalidProfileDigest
    case unsupportedFormat(Int)
    case writeFailed

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable."
        case .decodingFailed, .invalidProfileDigest:
            "The saved DNS runtime policy is malformed."
        case .encodingFailed, .writeFailed:
            "The DNS runtime policy could not be saved."
        case let .fileTooLarge(size):
            "The DNS runtime policy file is too large (\(size) bytes)."
        case let .unsupportedFormat(version):
            "The DNS runtime policy format version \(version) is unsupported."
        }
    }
}

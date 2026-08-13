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

    /// Conservative first-run behavior for Packet Tunnel profiles. Normal DNS
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
            return .inherited
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
}

public struct DNSRuntimePolicyStore: Sendable {
    public static let maximumFileBytes = 16 * 1_024

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
        } catch {
            throw DNSRuntimePolicyError.decodingFailed
        }
        guard payload.formatVersion == DNSRuntimePolicyPayload.currentVersion
        else {
            throw DNSRuntimePolicyError.unsupportedFormat(payload.formatVersion)
        }
        guard Self.isValidDigest(payload.profileDigest) else {
            throw DNSRuntimePolicyError.invalidProfileDigest
        }
        guard payload.profileDigest == Self.profileDigest(yaml) else {
            return nil
        }
        return payload.policy
    }

    public func save(
        _ policy: DNSRuntimePolicy,
        forProfileYAML yaml: String,
        fileManager: FileManager = .default
    ) throws {
        let payload = DNSRuntimePolicyPayload(
            formatVersion: DNSRuntimePolicyPayload.currentVersion,
            profileDigest: Self.profileDigest(yaml),
            policy: policy
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
    static let currentVersion = 1

    let formatVersion: Int
    let profileDigest: String
    let policy: DNSRuntimePolicy
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

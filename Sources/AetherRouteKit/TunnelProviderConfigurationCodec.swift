import Foundation

/// Complete, validated input for one Network System Extension start.
///
/// A Developer ID Network System Extension runs as root, so its App Group
/// container and data-protection Keychain are intentionally different from
/// those of the signed GUI app. The host therefore sends this snapshot through
/// NetworkExtension's start-options IPC instead of asking the provider to read
/// user-scoped files or secrets. The snapshot is never persisted in the VPN
/// configuration.
public struct ProviderLaunchSnapshot: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 2

    public let formatVersion: Int
    public let profileYAML: String
    public let routingMode: RoutingMode
    public let bypassPolicy: BypassPolicy
    public let dnsPolicy: DNSRuntimePolicy
    public let proxySelections: [String: String]
    public let routingResources: [RoutingResourceKind: Data]
    /// The host owns the user Keychain; a Developer ID system extension does
    /// not share its data-protection Keychain context. Transport this key only
    /// in the ephemeral start options, alongside the profile credentials.
    public let fakeIPCacheKey: Data?

    public init(
        profileYAML: String,
        routingMode: RoutingMode,
        bypassPolicy: BypassPolicy,
        dnsPolicy: DNSRuntimePolicy,
        proxySelections: [String: String],
        routingResources: [RoutingResourceKind: Data],
        fakeIPCacheKey: Data? = nil
    ) throws {
        formatVersion = Self.currentFormatVersion
        self.profileYAML = profileYAML
        self.routingMode = routingMode
        self.bypassPolicy = bypassPolicy
        self.dnsPolicy = dnsPolicy
        self.proxySelections = proxySelections
        self.routingResources = routingResources
        self.fakeIPCacheKey = fakeIPCacheKey
        try validate()
    }

    public func validate() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw ProviderLaunchSnapshotError.unsupportedFormat(formatVersion)
        }
        guard let profileData = profileYAML.data(using: .utf8) else {
            throw ProviderLaunchSnapshotError.profileEncodingFailed
        }
        do {
            try ProfileImportValidator.validate(data: profileData)
        } catch {
            throw ProviderLaunchSnapshotError.invalidProfile
        }
        guard proxySelections.count <= ProxySelectionStore.maximumSelectionCount
        else {
            throw ProviderLaunchSnapshotError.tooManySelections
        }
        for (group, member) in proxySelections {
            guard Self.isValidSelectionName(group),
                  Self.isValidSelectionName(member) else {
                throw ProviderLaunchSnapshotError.invalidSelection
            }
        }
        let required = ProfileConfigurationInspector.inspect(
            yaml: profileYAML
        ).requiredRoutingResources
        guard Set(routingResources.keys) == required else {
            throw ProviderLaunchSnapshotError.routingResourceSetMismatch
        }
        for (kind, data) in routingResources {
            guard !data.isEmpty, data.count <= kind.maximumBytes else {
                throw ProviderLaunchSnapshotError.invalidRoutingResource(kind)
            }
        }
        if let fakeIPCacheKey,
           fakeIPCacheKey.count != DataProtectionProfileKeyStore.keySizeBytes {
            throw ProfileKeyStoreError.invalidKeyLength(fakeIPCacheKey.count)
        }
    }

    private static func isValidSelectionName(_ value: String) -> Bool {
        let bytes = value.data(using: .utf8)?.count ?? 0
        return (1...ProxySelectionProviderMessageCodec.maximumNameBytes)
            .contains(bytes)
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.contains("\0")
    }
}

public enum ProviderLaunchSnapshotCodec {
    public static let startOptionsKey = "aetherRouteLaunchSnapshotV1"
    public static let maximumCompressedBytes = 96 * 1_024 * 1_024
    public static let maximumDecodedBytes = 160 * 1_024 * 1_024

    public static func startOptions(
        for snapshot: ProviderLaunchSnapshot
    ) throws -> [String: NSObject] {
        [startOptionsKey: try encodedPayload(for: snapshot) as NSData]
    }

    /// Encode and compress away from the main actor, then wrap the Sendable
    /// payload in NetworkExtension's options dictionary immediately before use.
    public static func encodedPayload(
        for snapshot: ProviderLaunchSnapshot
    ) throws -> Data {
        try snapshot.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let encoded = try encoder.encode(snapshot)
        guard encoded.count <= maximumDecodedBytes else {
            throw ProviderLaunchSnapshotError.payloadTooLarge(encoded.count)
        }
        let compressed = try (encoded as NSData).compressed(using: .zlib)
            as Data
        guard compressed.count <= maximumCompressedBytes else {
            throw ProviderLaunchSnapshotError.payloadTooLarge(compressed.count)
        }
        return compressed
    }

    public static func decode(
        data compressed: Data
    ) throws -> ProviderLaunchSnapshot {
        guard compressed.count <= maximumCompressedBytes else {
            throw ProviderLaunchSnapshotError.payloadTooLarge(compressed.count)
        }
        let decoded = try (compressed as NSData).decompressed(using: .zlib)
            as Data
        guard decoded.count <= maximumDecodedBytes else {
            throw ProviderLaunchSnapshotError.payloadTooLarge(decoded.count)
        }
        let snapshot: ProviderLaunchSnapshot
        do {
            snapshot = try PropertyListDecoder().decode(
                ProviderLaunchSnapshot.self,
                from: decoded
            )
        } catch {
            throw ProviderLaunchSnapshotError.decodingFailed
        }
        try snapshot.validate()
        return snapshot
    }

    public static func decode(
        options: [String: Any]?
    ) throws -> ProviderLaunchSnapshot {
        guard let compressed = options?[startOptionsKey] as? Data else {
            throw ProviderLaunchSnapshotError.missingPayload
        }
        return try decode(data: compressed)
    }
}

public enum ProviderLaunchSnapshotError: LocalizedError, Equatable, Sendable {
    case missingPayload
    case payloadTooLarge(Int)
    case decodingFailed
    case unsupportedFormat(Int)
    case profileEncodingFailed
    case invalidProfile
    case tooManySelections
    case invalidSelection
    case routingResourceSetMismatch
    case invalidRoutingResource(RoutingResourceKind)

    public var errorDescription: String? {
        switch self {
        case .missingPayload:
            "The Network Extension launch snapshot is missing."
        case .payloadTooLarge:
            "The Network Extension launch snapshot is too large."
        case .decodingFailed:
            "The Network Extension launch snapshot could not be decoded."
        case .unsupportedFormat:
            "The Network Extension launch snapshot version is unsupported."
        case .profileEncodingFailed, .invalidProfile:
            "The Network Extension launch profile is invalid."
        case .tooManySelections, .invalidSelection:
            "The Network Extension proxy selections are invalid."
        case .routingResourceSetMismatch, .invalidRoutingResource:
            "The Network Extension routing resources are invalid."
        }
    }
}

public enum TunnelProviderConfigurationCodec {
    public static let schemaVersionKey = "schemaVersion"
    public static let currentSchemaVersion = 2
    public static let configurationIdentifierKey = "configurationIdentifier"
    public static let primaryConfigurationIdentifier = "primary"
    public static let routingModeKey = "routingMode"
    public static let localProxyEnabledKey = "localProxyEnabled"
    public static let localProxyHTTPPortKey = "localProxyHTTPPort"
    public static let localProxySOCKSPortKey = "localProxySOCKSPort"
    public static let ipv6EnabledKey = "ipv6Enabled"

    public static func setting(
        routingMode: RoutingMode,
        localProxy: LocalProxySettings = LocalProxySettings(),
        enableIPv6: Bool = false,
        in configuration: [String: Any]? = nil
    ) -> [String: Any] {
        var configuration = configuration ?? [:]
        configuration[schemaVersionKey] = currentSchemaVersion
        configuration[configurationIdentifierKey] = primaryConfigurationIdentifier
        configuration[routingModeKey] = routingMode.rawValue
        configuration[localProxyEnabledKey] = localProxy.isEnabled
        configuration[localProxyHTTPPortKey] = localProxy.httpPort
        configuration[localProxySOCKSPortKey] = localProxy.socksPort
        configuration[ipv6EnabledKey] = enableIPv6
        return configuration
    }

    /// Absent means IPv4-only. Older stored configurations predate the key and
    /// must not be read as an IPv6 opt-in.
    public static func ipv6Enabled(
        from configuration: [String: Any]?
    ) throws -> Bool {
        try validateSchemaVersion(in: configuration)
        guard let storedValue = configuration?[ipv6EnabledKey] else {
            return false
        }
        guard let enabled = storedValue as? Bool else {
            throw TunnelProviderConfigurationError.invalidIPv6Setting
        }
        return enabled
    }

    public static func routingMode(
        from configuration: [String: Any]?
    ) throws -> RoutingMode {
        try validateSchemaVersion(in: configuration)
        guard let storedValue = configuration?[routingModeKey] else {
            return .rule
        }
        guard let rawValue = storedValue as? String,
              let routingMode = RoutingMode(rawValue: rawValue) else {
            throw TunnelProviderConfigurationError.invalidRoutingMode
        }
        return routingMode
    }

    public static func localProxySettings(
        from configuration: [String: Any]?
    ) throws -> LocalProxySettings {
        try validateSchemaVersion(in: configuration)
        guard let configuration else { return LocalProxySettings() }
        let keysArePresent = [
            localProxyEnabledKey,
            localProxyHTTPPortKey,
            localProxySOCKSPortKey,
        ].map { configuration[$0] != nil }
        if keysArePresent.allSatisfy({ !$0 }) {
            return LocalProxySettings()
        }
        guard keysArePresent.allSatisfy({ $0 }),
              let isEnabled = configuration[localProxyEnabledKey] as? Bool,
              let httpPort = exactInteger(
                  configuration[localProxyHTTPPortKey]
              ),
              let socksPort = exactInteger(
                  configuration[localProxySOCKSPortKey]
              ) else {
            throw TunnelProviderConfigurationError.invalidLocalProxy
        }
        do {
            return try LocalProxySettings(
                isEnabled: isEnabled,
                httpPort: httpPort,
                socksPort: socksPort
            ).validated()
        } catch {
            throw TunnelProviderConfigurationError.invalidLocalProxy
        }
    }

    public static func isPrimaryConfiguration(
        _ configuration: [String: Any]?
    ) -> Bool {
        configuration?[configurationIdentifierKey] as? String
            == primaryConfigurationIdentifier
    }

    public static func requiresPersistence(
        routingMode: RoutingMode,
        localProxy: LocalProxySettings = LocalProxySettings(),
        enableIPv6: Bool = false,
        configuration: [String: Any]?,
        isEnabled: Bool
    ) -> Bool {
        configuration?[schemaVersionKey] as? Int != currentSchemaVersion
            || configuration?[routingModeKey] as? String != routingMode.rawValue
            || (try? localProxySettings(from: configuration)) != localProxy
            || (try? ipv6Enabled(from: configuration)) != enableIPv6
            || !isPrimaryConfiguration(configuration)
            || !isEnabled
    }

    private static func validateSchemaVersion(
        in configuration: [String: Any]?
    ) throws {
        guard let rawVersion = configuration?[schemaVersionKey] else { return }
        guard let version = exactInteger(rawVersion),
              version == 1 || version == currentSchemaVersion else {
            throw TunnelProviderConfigurationError.unsupportedSchema
        }
    }

    private static func exactInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else {
            return nil
        }
        let value = number.int64Value
        guard NSNumber(value: value) == number,
              let exact = Int(exactly: value) else {
            return nil
        }
        return exact
    }
}

public enum TunnelProviderConfigurationError: LocalizedError, Equatable {
    case invalidRoutingMode
    case invalidLocalProxy
    case invalidIPv6Setting
    case unsupportedSchema

    public var errorDescription: String? {
        switch self {
        case .invalidRoutingMode:
            "The saved packet tunnel routing mode is invalid."
        case .invalidLocalProxy:
            "The saved local proxy settings are invalid."
        case .invalidIPv6Setting:
            "The saved IPv6 tunnel setting is invalid."
        case .unsupportedSchema:
            "The saved network extension configuration version is not supported."
        }
    }
}

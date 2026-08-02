import Darwin
import Foundation

private final class AetherRouteIdentityBundleMarker: NSObject {}

public enum AppConstants {
    public static let appGroupInfoKey = "AetherRouteAppGroup"
    public static let keychainAccessGroupInfoKey =
        "AetherRouteKeychainAccessGroup"
    public static let keychainAccessGroupSuffixInfoKey =
        "AetherRouteKeychainAccessGroupSuffix"
    public static let tunnelBundleIdentifierInfoKey =
        "AetherRouteTunnelBundleIdentifier"
    public static let transparentProxyBundleIdentifierInfoKey =
        "AetherRouteTransparentProxyBundleIdentifier"
    public static let profileArchiveTypeIdentifierInfoKey =
        "AetherRouteProfileArchiveTypeIdentifier"

    public static let appGroup = requiredIdentityValue(appGroupInfoKey)
    public static let keychainAccessGroupSuffix = requiredIdentityValue(
        keychainAccessGroupSuffixInfoKey
    )
    public static let tunnelBundleIdentifier = requiredIdentityValue(
        tunnelBundleIdentifierInfoKey
    )
    public static let transparentProxyBundleIdentifier = requiredIdentityValue(
        transparentProxyBundleIdentifierInfoKey
    )
    public static let profileArchiveTypeIdentifier = requiredIdentityValue(
        profileArchiveTypeIdentifierInfoKey
    )
    public static let localizedDescription = "AetherRoute"

    private static func requiredIdentityValue(
        _ key: String,
        bundle: Bundle = Bundle(for: AetherRouteIdentityBundleMarker.self)
    ) -> String {
        guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
              !value.isEmpty,
              value == value.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ),
              !value.contains("$("),
              !value.contains("${") else {
            preconditionFailure(
                "Required build identity value \(key) is missing or unresolved."
            )
        }
        return value
    }

    /// Returns the fully qualified Keychain access group produced by Xcode's
    /// `$(AppIdentifierPrefix)` expansion in the current host or extension.
    ///
    /// `Bundle.main` is intentional: AetherRouteKit is shared by the app and
    /// both Network Extension processes, and each executable carries the same
    /// Info.plist key with its own build-time expansion.
    public static func keychainAccessGroup(
        bundle: Bundle = .main
    ) throws -> String {
        try keychainAccessGroup(
            infoDictionary: bundle.infoDictionary ?? [:]
        )
    }

    static func keychainAccessGroup(
        infoDictionary: [String: Any]
    ) throws -> String {
        guard let value = infoDictionary[keychainAccessGroupInfoKey] as? String
        else {
            throw KeychainAccessGroupResolutionError.missingInfoValue
        }
        return try validateKeychainAccessGroup(value)
    }

    static func validateKeychainAccessGroup(_ value: String) throws -> String {
        guard !value.isEmpty else {
            throw KeychainAccessGroupResolutionError.emptyValue
        }
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            throw KeychainAccessGroupResolutionError.invalidValue(value)
        }
        guard !value.contains("$("), !value.contains("${") else {
            throw KeychainAccessGroupResolutionError.unresolvedBuildSetting(
                value
            )
        }

        let qualifiedSuffix = ".\(keychainAccessGroupSuffix)"
        guard value.hasSuffix(qualifiedSuffix) else {
            throw KeychainAccessGroupResolutionError.unexpectedSuffix(value)
        }

        let prefix = value.dropLast(qualifiedSuffix.count)
        let validPrefixCharacters = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789"
        )
        guard !prefix.isEmpty,
              prefix.unicodeScalars.allSatisfy({ scalar in
                  validPrefixCharacters.contains(scalar)
              }) else {
            throw KeychainAccessGroupResolutionError.invalidValue(value)
        }
        return value
    }
}

public enum KeychainAccessGroupResolutionError: LocalizedError, Equatable,
    Sendable
{
    case missingInfoValue
    case emptyValue
    case unresolvedBuildSetting(String)
    case unexpectedSuffix(String)
    case invalidValue(String)

    public var errorDescription: String? {
        switch self {
        case .missingInfoValue:
            "The shared Keychain access group is missing from this executable's Info.plist."
        case .emptyValue:
            "The shared Keychain access group is empty. A signed build with an App Identifier Prefix is required."
        case let .unresolvedBuildSetting(value):
            "The shared Keychain access group contains an unresolved build setting: \(value)"
        case let .unexpectedSuffix(value):
            "The shared Keychain access group has an unexpected suffix: \(value)"
        case let .invalidValue(value):
            "The shared Keychain access group is invalid: \(value)"
        }
    }
}

public enum RoutingMode: String, CaseIterable, Codable, Sendable {
    case rule
    case global
    case direct

    public var title: String {
        switch self {
        case .rule: "Rule"
        case .global: "Global"
        case .direct: "Direct"
        }
    }

    public var packetFlowABIValue: Int32 {
        switch self {
        case .rule: 0
        case .global: 1
        case .direct: 2
        }
    }
}

public struct TunnelConfiguration: Codable, Equatable, Sendable {
    public var mode: RoutingMode
    public var mtu: Int
    public var ipv4Address: String
    public var ipv4SubnetMask: String
    public var ipv6Address: String
    public var ipv6PrefixLength: Int
    public var dnsServers: [String]
    public var excludeLocalNetworks: Bool
    public var localProxy: LocalProxySettings

    public init(
        mode: RoutingMode = .rule,
        mtu: Int = 1_500,
        ipv4Address: String = "198.18.0.1",
        ipv4SubnetMask: String = "255.255.0.0",
        ipv6Address: String = "fd00:a37e:0:1::1",
        ipv6PrefixLength: Int = 64,
        dnsServers: [String] = ["1.1.1.1", "8.8.8.8"],
        excludeLocalNetworks: Bool = true,
        localProxy: LocalProxySettings = LocalProxySettings()
    ) {
        self.mode = mode
        self.mtu = mtu
        self.ipv4Address = ipv4Address
        self.ipv4SubnetMask = ipv4SubnetMask
        self.ipv6Address = ipv6Address
        self.ipv6PrefixLength = ipv6PrefixLength
        self.dnsServers = dnsServers
        self.excludeLocalNetworks = excludeLocalNetworks
        self.localProxy = localProxy
    }

    public func validated() throws -> Self {
        guard (1_280...9_000).contains(mtu) else {
            throw TunnelConfigurationError.invalidMTU(mtu)
        }
        guard IPv4Address(ipv4Address) != nil else {
            throw TunnelConfigurationError.invalidIPv4Address(ipv4Address)
        }
        guard IPv4Address(ipv4SubnetMask) != nil else {
            throw TunnelConfigurationError.invalidSubnetMask(ipv4SubnetMask)
        }
        guard IPv6Address(ipv6Address) != nil else {
            throw TunnelConfigurationError.invalidIPv6Address(ipv6Address)
        }
        guard (1...128).contains(ipv6PrefixLength) else {
            throw TunnelConfigurationError.invalidIPv6PrefixLength(
                ipv6PrefixLength
            )
        }
        guard !dnsServers.isEmpty,
              dnsServers.allSatisfy({
                  IPv4Address($0) != nil || IPv6Address($0) != nil
              }) else {
            throw TunnelConfigurationError.invalidDNSServers
        }
        do {
            _ = try localProxy.validated()
        } catch {
            throw TunnelConfigurationError.invalidLocalProxy
        }
        return self
    }
}

public enum TunnelConfigurationError: LocalizedError, Equatable {
    case invalidMTU(Int)
    case invalidIPv4Address(String)
    case invalidSubnetMask(String)
    case invalidIPv6Address(String)
    case invalidIPv6PrefixLength(Int)
    case invalidDNSServers
    case invalidLocalProxy

    public var errorDescription: String? {
        switch self {
        case let .invalidMTU(value): "MTU \(value) is outside the supported range."
        case let .invalidIPv4Address(value): "\(value) is not a valid IPv4 address."
        case let .invalidSubnetMask(value): "\(value) is not a valid IPv4 subnet mask."
        case let .invalidIPv6Address(value): "\(value) is not a valid IPv6 address."
        case let .invalidIPv6PrefixLength(value):
            "IPv6 prefix length \(value) is outside the supported range."
        case .invalidDNSServers:
            "At least one valid IPv4 or IPv6 DNS server is required."
        case .invalidLocalProxy:
            "The local proxy settings are invalid."
        }
    }
}

private struct IPv6Address {
    init?(_ value: String) {
        var address = in6_addr()
        guard value.withCString({ pointer in
            inet_pton(AF_INET6, pointer, &address)
        }) == 1 else {
            return nil
        }
    }
}

private struct IPv4Address {
    init?(_ value: String) {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == 4,
              components.allSatisfy({ part in
                  guard let octet = UInt8(part), String(octet) == part else { return false }
                  return true
              }) else {
            return nil
        }
    }
}

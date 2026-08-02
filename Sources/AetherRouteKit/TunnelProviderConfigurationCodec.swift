import Foundation

public enum TunnelProviderConfigurationCodec {
    public static let schemaVersionKey = "schemaVersion"
    public static let currentSchemaVersion = 2
    public static let configurationIdentifierKey = "configurationIdentifier"
    public static let primaryConfigurationIdentifier = "primary"
    public static let routingModeKey = "routingMode"
    public static let localProxyEnabledKey = "localProxyEnabled"
    public static let localProxyHTTPPortKey = "localProxyHTTPPort"
    public static let localProxySOCKSPortKey = "localProxySOCKSPort"

    public static func setting(
        routingMode: RoutingMode,
        localProxy: LocalProxySettings = LocalProxySettings(),
        in configuration: [String: Any]? = nil
    ) -> [String: Any] {
        var configuration = configuration ?? [:]
        configuration[schemaVersionKey] = currentSchemaVersion
        configuration[configurationIdentifierKey] = primaryConfigurationIdentifier
        configuration[routingModeKey] = routingMode.rawValue
        configuration[localProxyEnabledKey] = localProxy.isEnabled
        configuration[localProxyHTTPPortKey] = localProxy.httpPort
        configuration[localProxySOCKSPortKey] = localProxy.socksPort
        return configuration
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
        configuration: [String: Any]?,
        isEnabled: Bool
    ) -> Bool {
        configuration?[schemaVersionKey] as? Int != currentSchemaVersion
            || configuration?[routingModeKey] as? String != routingMode.rawValue
            || (try? localProxySettings(from: configuration)) != localProxy
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
    case unsupportedSchema

    public var errorDescription: String? {
        switch self {
        case .invalidRoutingMode:
            "The saved packet tunnel routing mode is invalid."
        case .invalidLocalProxy:
            "The saved local proxy settings are invalid."
        case .unsupportedSchema:
            "The saved network extension configuration version is not supported."
        }
    }
}

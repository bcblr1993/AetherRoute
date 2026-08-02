import Foundation

public struct LocalProxySettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let permittedPorts = 1_024...65_535

    public var version: Int
    public var isEnabled: Bool
    public var httpPort: Int
    public var socksPort: Int

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        httpPort: Int = 7_890,
        socksPort: Int = 7_891
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.httpPort = httpPort
        self.socksPort = socksPort
    }

    public func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw LocalProxySettingsError.unsupportedVersion
        }
        guard Self.permittedPorts.contains(httpPort) else {
            throw LocalProxySettingsError.invalidHTTPPort(httpPort)
        }
        guard Self.permittedPorts.contains(socksPort) else {
            throw LocalProxySettingsError.invalidSOCKSPort(socksPort)
        }
        guard httpPort != socksPort else {
            throw LocalProxySettingsError.duplicatePorts(httpPort)
        }
        return self
    }

    /// A copy-only command for the user's current shell. The fixed loopback
    /// host and validated integer ports make shell escaping unnecessary.
    public func shellEnvironmentCommand() throws -> String {
        let settings = try validated()
        guard settings.isEnabled else {
            throw LocalProxySettingsError.disabled
        }
        return [
            "export HTTP_PROXY=http://127.0.0.1:\(settings.httpPort)",
            "export HTTPS_PROXY=http://127.0.0.1:\(settings.httpPort)",
            "export ALL_PROXY=socks5h://127.0.0.1:\(settings.socksPort)",
            "export http_proxy=\"$HTTP_PROXY\"",
            "export https_proxy=\"$HTTPS_PROXY\"",
            "export all_proxy=\"$ALL_PROXY\"",
            "export NO_PROXY=localhost,127.0.0.1,::1",
            "export no_proxy=\"$NO_PROXY\"",
        ].joined(separator: "; ")
    }

    public static let clearShellEnvironmentCommand =
        "unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"
}

public enum LocalProxySettingsError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion
    case invalidHTTPPort(Int)
    case invalidSOCKSPort(Int)
    case duplicatePorts(Int)
    case disabled

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            "The local proxy settings version is not supported."
        case let .invalidHTTPPort(port):
            "HTTP proxy port \(port) is outside the supported range."
        case let .invalidSOCKSPort(port):
            "SOCKS5 proxy port \(port) is outside the supported range."
        case let .duplicatePorts(port):
            "HTTP and SOCKS5 proxy ports cannot both use \(port)."
        case .disabled:
            "Enable the local proxy before copying its shell environment."
        }
    }
}

public struct LocalProxySettingsStore {
    public static let storageKey = "AetherRoute.LocalProxySettings"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Corrupt, future, or invalid values fail closed to the disabled default.
    public func load() -> LocalProxySettings {
        guard let data = defaults.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode(
                  LocalProxySettings.self,
                  from: data
              ),
              let validated = try? decoded.validated() else {
            return LocalProxySettings()
        }
        return validated
    }

    public func save(_ settings: LocalProxySettings) throws {
        let validated = try settings.validated()
        defaults.set(
            try JSONEncoder().encode(validated),
            forKey: Self.storageKey
        )
    }
}

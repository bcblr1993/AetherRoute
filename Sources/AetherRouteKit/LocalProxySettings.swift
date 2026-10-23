import Foundation

public struct LocalProxySettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let permittedPorts = 1_024...65_535

    public var version: Int
    public var isEnabled: Bool
    public var httpPort: Int
    public var socksPort: Int
    public var allowLAN: Bool

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        httpPort: Int = 7_890,
        socksPort: Int = 7_891,
        allowLAN: Bool = false
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.allowLAN = allowLAN
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case httpPort
        case socksPort
        case allowLAN
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 7_890
        self.socksPort = try container.decodeIfPresent(Int.self, forKey: .socksPort) ?? 7_891
        self.allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(httpPort, forKey: .httpPort)
        try container.encode(socksPort, forKey: .socksPort)
        try container.encode(allowLAN, forKey: .allowLAN)
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
        guard settings.isEnabled || settings.allowLAN else {
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

    /// A copy-friendly configuration guide for devices in the same local network.
    public func lanConfigurationGuide(lanIP: String) -> String {
        """
        【AetherRoute 局域网共享代理】
        请在同一 Wi-Fi 下将设备的代理设置为：
        • 代理类型：HTTP / 网页代理（手动）
        • 服务器/主机名：\(lanIP)
        • 端口：\(httpPort)
        （SOCKS5 专用端口：\(socksPort)）
        """
    }

    /// Export shell environment for another machine on the same LAN.
    public func lanShellEnvironmentCommand(lanIP: String) throws -> String {
        let settings = try validated()
        guard settings.allowLAN else {
            throw LocalProxySettingsError.disabled
        }
        return [
            "export HTTP_PROXY=http://\(lanIP):\(settings.httpPort)",
            "export HTTPS_PROXY=http://\(lanIP):\(settings.httpPort)",
            "export ALL_PROXY=socks5h://\(lanIP):\(settings.socksPort)",
            "export http_proxy=\"$HTTP_PROXY\"",
            "export https_proxy=\"$HTTPS_PROXY\"",
            "export all_proxy=\"$ALL_PROXY\"",
            "export NO_PROXY=localhost,127.0.0.1,::1,\(lanIP)",
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

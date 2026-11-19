import Foundation

public struct LocalProxySettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let permittedPorts = 1_024...65_535
    public static let defaultSystemProxyBypassDomains: [String] = [
        "localhost",
        "127.0.0.1",
        "::1",
        "*.local",
        "169.254/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "192.168.0.0/16",
    ]

    public var version: Int
    public var isEnabled: Bool
    public var httpPort: Int
    public var socksPort: Int
    public var allowLAN: Bool
    public var setAsSystemProxy: Bool
    public var systemProxyBypassDomains: [String]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        httpPort: Int = 7_890,
        socksPort: Int = 7_891,
        allowLAN: Bool = false,
        setAsSystemProxy: Bool = false,
        systemProxyBypassDomains: [String] = Self.defaultSystemProxyBypassDomains
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.allowLAN = allowLAN
        self.setAsSystemProxy = setAsSystemProxy
        self.systemProxyBypassDomains = systemProxyBypassDomains
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case httpPort
        case socksPort
        case allowLAN
        case setAsSystemProxy
        case systemProxyBypassDomains
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.httpPort = try container.decodeIfPresent(Int.self, forKey: .httpPort) ?? 7_890
        self.socksPort = try container.decodeIfPresent(Int.self, forKey: .socksPort) ?? 7_891
        self.allowLAN = try container.decodeIfPresent(Bool.self, forKey: .allowLAN) ?? false
        self.setAsSystemProxy = try container.decodeIfPresent(Bool.self, forKey: .setAsSystemProxy) ?? false
        self.systemProxyBypassDomains = try container.decodeIfPresent(
            [String].self,
            forKey: .systemProxyBypassDomains
        ) ?? Self.defaultSystemProxyBypassDomains
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(httpPort, forKey: .httpPort)
        try container.encode(socksPort, forKey: .socksPort)
        try container.encode(allowLAN, forKey: .allowLAN)
        try container.encode(setAsSystemProxy, forKey: .setAsSystemProxy)
        try container.encode(systemProxyBypassDomains, forKey: .systemProxyBypassDomains)
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
        var normalizedBypass: [String] = []
        var seenBypass = Set<String>()
        for rawDomain in systemProxyBypassDomains {
            let trimmed = rawDomain.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                continue
            }
            if trimmed.hasPrefix("-")
                || trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil
                || trimmed.contains("\0") {
                throw LocalProxySettingsError.invalidBypassDomain(rawDomain)
            }
            let lower = trimmed.lowercased()
            if seenBypass.insert(lower).inserted {
                normalizedBypass.append(trimmed)
            }
        }
        var copy = self
        copy.systemProxyBypassDomains = normalizedBypass
        return copy
    }

    /// A copy-only command for the user's current shell. The fixed loopback
    /// host and validated integer ports make shell escaping unnecessary.
    public func shellEnvironmentCommand() throws -> String {
        let settings = try validated()
        guard settings.isEnabled || settings.allowLAN || settings.setAsSystemProxy else {
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
    case invalidBypassDomain(String)
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
        case let .invalidBypassDomain(domain):
            "Invalid system proxy bypass domain: \(domain)"
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

public struct SystemProxyCommandOutput: Equatable, Sendable {
    public let exitCode: Int32
    public let standardOutput: String
    public let standardError: String

    public init(exitCode: Int32, standardOutput: String, standardError: String) {
        self.exitCode = exitCode
        self.standardOutput = standardOutput
        self.standardError = standardError
    }
}

public protocol SystemProxyCommandExecuting: Sendable {
    func run(executablePath: String, arguments: [String]) throws -> SystemProxyCommandOutput
}

public struct ProcessSystemProxyCommandExecutor: SystemProxyCommandExecuting {
    public init() {}

    public func run(executablePath: String, arguments: [String]) throws -> SystemProxyCommandOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        return SystemProxyCommandOutput(
            exitCode: process.terminationStatus,
            standardOutput: String(data: stdoutData, encoding: .utf8) ?? "",
            standardError: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

public enum SystemProxyConfiguratorError: LocalizedError, Equatable, Sendable {
    case commandFailed(command: String, exitCode: Int32, stderr: String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, exitCode, stderr):
            let trimmedError = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedError.isEmpty {
                return "networksetup \(command) exited with status \(exitCode)."
            }
            return "networksetup \(command) failed (\(exitCode)): \(trimmedError)"
        }
    }
}

public final class SystemProxyConfigurator: @unchecked Sendable {
    public static let defaultBackupKey = "AetherRoute.SystemProxyBackupState"
    public static let networksetupPath = "/usr/sbin/networksetup"

    private struct ProxyEndpointSnapshot: Codable, Equatable {
        let enabled: Bool
        let server: String
        let port: Int
    }

    private struct ServiceBackup: Codable, Equatable {
        let web: ProxyEndpointSnapshot
        let secure: ProxyEndpointSnapshot
        let socks: ProxyEndpointSnapshot
        let bypassDomains: [String]
    }

    private struct BackupState: Codable, Equatable {
        var services: [String: ServiceBackup]
    }

    private let executor: any SystemProxyCommandExecuting
    private let defaults: UserDefaults
    private let backupKey: String
    private let lock = NSLock()

    public init(
        executor: any SystemProxyCommandExecuting = ProcessSystemProxyCommandExecutor(),
        defaults: UserDefaults = .standard,
        backupKey: String = SystemProxyConfigurator.defaultBackupKey
    ) {
        self.executor = executor
        self.defaults = defaults
        self.backupKey = backupKey
    }

    public var hasPendingBackup: Bool {
        lock.lock()
        defer { lock.unlock() }
        return defaults.data(forKey: backupKey) != nil
    }

    public func apply(settings: LocalProxySettings) throws {
        let validated = try settings.validated()
        guard validated.setAsSystemProxy else {
            try restorePendingIfNeeded()
            return
        }

        lock.lock()
        defer { lock.unlock() }

        let services = try listNetworkServices(includeDisabled: false)
        let hadPriorBackup = defaults.data(forKey: backupKey) != nil
        var backup = loadBackupLocked() ?? BackupState(services: [:])
        var didUpdateBackup = false

        for service in services where backup.services[service] == nil {
            backup.services[service] = try snapshotService(service)
            didUpdateBackup = true
        }
        if didUpdateBackup || !hadPriorBackup {
            try saveBackupLocked(backup)
        }

        let httpPortString = String(validated.httpPort)
        let socksPortString = String(validated.socksPort)
        let bypassArgs = validated.systemProxyBypassDomains.isEmpty
            ? ["Empty"]
            : validated.systemProxyBypassDomains

        var touchedServices: [String] = []
        do {
            for service in services {
                touchedServices.append(service)
                _ = try runChecked(["-setwebproxy", service, "127.0.0.1", httpPortString])
                _ = try runChecked(["-setwebproxystate", service, "on"])
                _ = try runChecked(["-setsecurewebproxy", service, "127.0.0.1", httpPortString])
                _ = try runChecked(["-setsecurewebproxystate", service, "on"])
                _ = try runChecked(["-setsocksfirewallproxy", service, "127.0.0.1", socksPortString])
                _ = try runChecked(["-setsocksfirewallproxystate", service, "on"])
                _ = try runChecked(["-setproxybypassdomains", service] + bypassArgs)
            }
        } catch {
            var allRolledBack = true
            for service in touchedServices {
                guard let snapshot = backup.services[service] else { continue }
                do {
                    try restoreServiceSnapshot(snapshot, service: service)
                } catch {
                    allRolledBack = false
                }
            }
            if allRolledBack && !hadPriorBackup {
                defaults.removeObject(forKey: backupKey)
            }
            throw error
        }
    }

    public func restore() throws {
        try restorePendingIfNeeded()
    }

    public func restorePendingIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }

        guard var backup = loadBackupLocked() else {
            return
        }

        // Disabled network services (prefixed with `*` in `networksetup -listallnetworkservices`)
        // still exist in macOS preferences and accept proxy restore commands; only truly removed
        // interfaces absent from the service list are skipped.
        let knownServices: Set<String>? = (try? listNetworkServices(includeDisabled: true)).map(Set.init)
        var firstError: Error?
        var remainingServices: [String: ServiceBackup] = [:]

        for service in backup.services.keys.sorted() {
            guard let snapshot = backup.services[service] else { continue }
            if let knownServices, !knownServices.contains(service) {
                continue
            }
            do {
                try restoreServiceSnapshot(snapshot, service: service)
            } catch {
                if firstError == nil {
                    firstError = error
                }
                remainingServices[service] = snapshot
            }
        }

        if remainingServices.isEmpty {
            defaults.removeObject(forKey: backupKey)
        } else {
            backup.services = remainingServices
            try? saveBackupLocked(backup)
        }
        if let firstError {
            throw firstError
        }
    }

    private func restoreServiceSnapshot(_ snapshot: ServiceBackup, service: String) throws {
        try restoreEndpoint(
            snapshot.web,
            service: service,
            setCommand: "-setwebproxy",
            stateCommand: "-setwebproxystate"
        )
        try restoreEndpoint(
            snapshot.secure,
            service: service,
            setCommand: "-setsecurewebproxy",
            stateCommand: "-setsecurewebproxystate"
        )
        try restoreEndpoint(
            snapshot.socks,
            service: service,
            setCommand: "-setsocksfirewallproxy",
            stateCommand: "-setsocksfirewallproxystate"
        )
        let bypassArgs = snapshot.bypassDomains.isEmpty ? ["Empty"] : snapshot.bypassDomains
        _ = try runChecked(["-setproxybypassdomains", service] + bypassArgs)
    }

    private func restoreEndpoint(
        _ snapshot: ProxyEndpointSnapshot,
        service: String,
        setCommand: String,
        stateCommand: String
    ) throws {
        if !snapshot.server.isEmpty, snapshot.port > 0 {
            _ = try runChecked([setCommand, service, snapshot.server, String(snapshot.port)])
        }
        _ = try runChecked([stateCommand, service, snapshot.enabled ? "on" : "off"])
    }

    private func listNetworkServices(includeDisabled: Bool) throws -> [String] {
        let output = try runChecked(["-listallnetworkservices"])
        return output.standardOutput
            .components(separatedBy: .newlines)
            .compactMap { rawLine in
                let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("An asterisk") else {
                    return nil
                }
                if trimmed.hasPrefix("*") {
                    guard includeDisabled else { return nil }
                    let name = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    return name.isEmpty ? nil : name
                }
                return trimmed
            }
    }

    private func snapshotService(_ service: String) throws -> ServiceBackup {
        let webOut = try runChecked(["-getwebproxy", service])
        let secureOut = try runChecked(["-getsecurewebproxy", service])
        let socksOut = try runChecked(["-getsocksfirewallproxy", service])
        let bypassOut = try runChecked(["-getproxybypassdomains", service])
        return ServiceBackup(
            web: parseProxyOutput(webOut.standardOutput),
            secure: parseProxyOutput(secureOut.standardOutput),
            socks: parseProxyOutput(socksOut.standardOutput),
            bypassDomains: parseBypassOutput(bypassOut.standardOutput)
        )
    }

    private func parseProxyOutput(_ output: String) -> ProxyEndpointSnapshot {
        var enabled = false
        var server = ""
        var port = 0
        for line in output.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let value = trimmed.splitOnceAfter(prefix: "Enabled:") {
                enabled = value.lowercased() == "yes"
            } else if let value = trimmed.splitOnceAfter(prefix: "Server:") {
                server = value
            } else if let value = trimmed.splitOnceAfter(prefix: "Port:"), let parsedPort = Int(value) {
                port = parsedPort
            }
        }
        return ProxyEndpointSnapshot(enabled: enabled, server: server, port: port)
    }

    private func parseBypassOutput(_ output: String) -> [String] {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.localizedCaseInsensitiveContains("aren't any bypass domains") {
            return []
        }
        return output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func runChecked(_ arguments: [String]) throws -> SystemProxyCommandOutput {
        let output = try executor.run(executablePath: Self.networksetupPath, arguments: arguments)
        guard output.exitCode == 0 else {
            throw SystemProxyConfiguratorError.commandFailed(
                command: arguments.first ?? "networksetup",
                exitCode: output.exitCode,
                stderr: output.standardError
            )
        }
        return output
    }

    private func loadBackupLocked() -> BackupState? {
        guard let data = defaults.data(forKey: backupKey) else {
            return nil
        }
        return try? JSONDecoder().decode(BackupState.self, from: data)
    }

    private func saveBackupLocked(_ state: BackupState) throws {
        let data = try JSONEncoder().encode(state)
        defaults.set(data, forKey: backupKey)
    }
}

private extension String {
    func splitOnceAfter(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        return String(dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

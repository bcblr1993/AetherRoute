import Foundation

/// Supported terminal shell dialects for copying proxy environment commands,
/// benchmarked against Surge 5 (`Copy Shell Export Command`) and Clash Verge Rev (`Copy Env`).
public enum TerminalShellDialect: String, CaseIterable, Sendable, Equatable, Identifiable {
    case zshBash = "zsh_bash"
    case fish = "fish"
    case nushell = "nushell"
    case powershell = "powershell"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .zshBash:
            "Zsh / Bash"
        case .fish:
            "Fish"
        case .nushell:
            "Nushell"
        case .powershell:
            "PowerShell"
        }
    }
}

/// Pure, zero-allocation generator for multi-shell proxy environment commands and
/// RFC-compliant Proxy Auto-Configuration (`FindProxyForURL`) PAC scripts.
public struct TerminalProxyEnvGenerator: Sendable {
    public static let defaultBypassHosts: [String] = [
        "localhost",
        "127.0.0.1",
        "::1",
    ]

    public static func shellCommand(
        dialect: TerminalShellDialect = .zshBash,
        host: String = "127.0.0.1",
        httpPort: Int = 7_890,
        socksPort: Int = 7_891,
        bypassHosts: [String] = defaultBypassHosts
    ) -> String {
        let sanitizedHost = sanitizeHostLiteral(host)
        let clampedHTTPPort = min(max(httpPort, 1), 65_535)
        let clampedSOCKSPort = min(max(socksPort, 1), 65_535)
        let httpURL = "http://\(sanitizedHost):\(clampedHTTPPort)"
        let socksURL = "socks5h://\(sanitizedHost):\(clampedSOCKSPort)"

        var effectiveBypass = bypassHosts
        let rawHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if !rawHost.isEmpty,
           rawHost != "127.0.0.1",
           rawHost != "::1",
           rawHost.lowercased() != "localhost",
           !effectiveBypass.contains(rawHost) {
            effectiveBypass.append(rawHost)
        }
        let noProxyValue = effectiveBypass.joined(separator: ",")

        switch dialect {
        case .zshBash:
            return [
                "export HTTP_PROXY=\(httpURL)",
                "export HTTPS_PROXY=\(httpURL)",
                "export ALL_PROXY=\(socksURL)",
                "export http_proxy=\"$HTTP_PROXY\"",
                "export https_proxy=\"$HTTPS_PROXY\"",
                "export all_proxy=\"$ALL_PROXY\"",
                "export NO_PROXY=\(noProxyValue)",
                "export no_proxy=\"$NO_PROXY\"",
            ].joined(separator: "; ")

        case .fish:
            return [
                "set -gx HTTP_PROXY \(httpURL)",
                "set -gx HTTPS_PROXY \(httpURL)",
                "set -gx ALL_PROXY \(socksURL)",
                "set -gx http_proxy $HTTP_PROXY",
                "set -gx https_proxy $HTTPS_PROXY",
                "set -gx all_proxy $ALL_PROXY",
                "set -gx NO_PROXY \(noProxyValue)",
                "set -gx no_proxy $NO_PROXY",
            ].joined(separator: "; ")

        case .nushell:
            return [
                "$env.HTTP_PROXY = \"\(httpURL)\"",
                "$env.HTTPS_PROXY = \"\(httpURL)\"",
                "$env.ALL_PROXY = \"\(socksURL)\"",
                "$env.http_proxy = \"\(httpURL)\"",
                "$env.https_proxy = \"\(httpURL)\"",
                "$env.all_proxy = \"\(socksURL)\"",
                "$env.NO_PROXY = \"\(noProxyValue)\"",
                "$env.no_proxy = \"\(noProxyValue)\"",
            ].joined(separator: "; ")

        case .powershell:
            return [
                "$env:HTTP_PROXY=\"\(httpURL)\"",
                "$env:HTTPS_PROXY=\"\(httpURL)\"",
                "$env:ALL_PROXY=\"\(socksURL)\"",
                "$env:http_proxy=\"\(httpURL)\"",
                "$env:https_proxy=\"\(httpURL)\"",
                "$env:all_proxy=\"\(socksURL)\"",
                "$env:NO_PROXY=\"\(noProxyValue)\"",
                "$env:no_proxy=\"\(noProxyValue)\"",
            ].joined(separator: "; ")
        }
    }

    public static func unsetCommand(dialect: TerminalShellDialect = .zshBash) -> String {
        switch dialect {
        case .zshBash:
            "unset HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"
        case .fish:
            "set -e HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"
        case .nushell:
            "hide-env -i HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY http_proxy https_proxy all_proxy no_proxy"
        case .powershell:
            "Remove-Item Env:HTTP_PROXY,Env:HTTPS_PROXY,Env:ALL_PROXY,Env:NO_PROXY,Env:http_proxy,Env:https_proxy,Env:all_proxy,Env:no_proxy -ErrorAction SilentlyContinue"
        }
    }

    public static func pacScript(
        host: String = "127.0.0.1",
        httpPort: Int = 7_890,
        socksPort: Int = 7_891
    ) -> String {
        let sanitizedHost = sanitizeHostLiteral(host)
        let clampedHTTPPort = min(max(httpPort, 1), 65_535)
        let clampedSOCKSPort = min(max(socksPort, 1), 65_535)
        return """
        function FindProxyForURL(url, host) {
          if (isPlainHostName(host) ||
              host === "localhost" ||
              shExpMatch(host, "*.localhost") ||
              shExpMatch(host, "*.local") ||
              shExpMatch(host, "*.lan") ||
              isInNet(dnsResolve(host), "127.0.0.0", "255.0.0.0") ||
              isInNet(dnsResolve(host), "10.0.0.0", "255.0.0.0") ||
              isInNet(dnsResolve(host), "172.16.0.0", "255.240.0.0") ||
              isInNet(dnsResolve(host), "192.168.0.0", "255.255.0.0") ||
              isInNet(dnsResolve(host), "169.254.0.0", "255.255.0.0")) {
            return "DIRECT";
          }
          return "PROXY \(sanitizedHost):\(clampedHTTPPort); SOCKS5 \(sanitizedHost):\(clampedSOCKSPort); SOCKS \(sanitizedHost):\(clampedSOCKSPort); DIRECT";
        }
        """
    }

    private static func sanitizeHostLiteral(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "127.0.0.1" }
        if trimmed.contains(":"), !trimmed.hasPrefix("[") {
            return "[\(trimmed)]"
        }
        return trimmed
    }
}

extension LocalProxySettings {
    public func shellEnvironmentCommand(dialect: TerminalShellDialect) throws -> String {
        let settings = try validated()
        guard settings.isEnabled || settings.allowLAN else {
            throw LocalProxySettingsError.disabled
        }
        return TerminalProxyEnvGenerator.shellCommand(
            dialect: dialect,
            host: "127.0.0.1",
            httpPort: settings.httpPort,
            socksPort: settings.socksPort
        )
    }

    public func lanShellEnvironmentCommand(
        lanIP: String,
        dialect: TerminalShellDialect
    ) throws -> String {
        let settings = try validated()
        guard settings.allowLAN else {
            throw LocalProxySettingsError.disabled
        }
        return TerminalProxyEnvGenerator.shellCommand(
            dialect: dialect,
            host: lanIP,
            httpPort: settings.httpPort,
            socksPort: settings.socksPort
        )
    }

    public func pacScript(host: String = "127.0.0.1") throws -> String {
        let settings = try validated()
        guard settings.isEnabled || settings.allowLAN else {
            throw LocalProxySettingsError.disabled
        }
        return TerminalProxyEnvGenerator.pacScript(
            host: host,
            httpPort: settings.httpPort,
            socksPort: settings.socksPort
        )
    }
}

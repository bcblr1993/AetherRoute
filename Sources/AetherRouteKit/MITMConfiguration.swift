import Foundation

public enum MITMURLRewriteMode: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case redirect302
    case reject
    case reject200
    case rejectDict
}

public struct MITMURLRewriteRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var pattern: String
    public var replacement: String
    public var mode: MITMURLRewriteMode
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        pattern: String,
        replacement: String = "",
        mode: MITMURLRewriteMode = .redirect302,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.replacement = replacement
        self.mode = mode
        self.isEnabled = isEnabled
    }
}

public enum MITMRewriteScope: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case requestHeader
    case responseHeader
    case requestBody
    case responseBody
}

public struct MITMHeaderBodyRewriteRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var scope: MITMRewriteScope
    public var urlPattern: String
    public var headerName: String?
    public var pattern: String
    public var replacement: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        scope: MITMRewriteScope,
        urlPattern: String,
        headerName: String? = nil,
        pattern: String,
        replacement: String = "",
        isEnabled: Bool = true
    ) {
        self.id = id
        self.scope = scope
        self.urlPattern = urlPattern
        self.headerName = headerName
        self.pattern = pattern
        self.replacement = replacement
        self.isEnabled = isEnabled
    }
}

public enum MITMScriptHook: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case httpRequest
    case httpResponse
}

public struct MITMJSScriptRule: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var hook: MITMScriptHook
    public var urlPattern: String
    public var scriptBody: String
    public var timeoutMs: Int
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        hook: MITMScriptHook = .httpRequest,
        urlPattern: String,
        scriptBody: String,
        timeoutMs: Int = 500,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.name = name
        self.hook = hook
        self.urlPattern = urlPattern
        self.scriptBody = scriptBody
        self.timeoutMs = timeoutMs
        self.isEnabled = isEnabled
    }
}

public enum MITMConfigurationError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion
    case invalidRegex(String)
    case invalidTimeout(Int)
    case invalidScriptName
    case tooManyRules

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "MITM configuration version is unsupported."
        case let .invalidRegex(pattern):
            return "Invalid regular expression pattern: \(pattern)"
        case let .invalidTimeout(timeout):
            return "Script timeout \(timeout) ms must be between 1 and 2000 ms."
        case .invalidScriptName:
            return "Script name must not be empty."
        case .tooManyRules:
            return "Too many MITM rules configured."
        }
    }
}

public struct MITMConfiguration: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let defaultBypassHosts: [String] = [
        "*.apple.com",
        "*.icloud.com",
        "*.mzstatic.com",
        "localhost",
        "127.0.0.1",
    ]
    public static let maximumRewriteRules = 256
    public static let maximumScripts = 64

    public var version: Int
    public var isEnabled: Bool
    public var hostPatterns: [String]
    public var bypassHosts: [String]
    public var urlRewrites: [MITMURLRewriteRule]
    public var headerBodyRewrites: [MITMHeaderBodyRewriteRule]
    public var scripts: [MITMJSScriptRule]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        hostPatterns: [String] = [],
        bypassHosts: [String] = Self.defaultBypassHosts,
        urlRewrites: [MITMURLRewriteRule] = [],
        headerBodyRewrites: [MITMHeaderBodyRewriteRule] = [],
        scripts: [MITMJSScriptRule] = []
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.hostPatterns = hostPatterns
        self.bypassHosts = bypassHosts
        self.urlRewrites = urlRewrites
        self.headerBodyRewrites = headerBodyRewrites
        self.scripts = scripts
    }

    public func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw MITMConfigurationError.unsupportedVersion
        }
        guard urlRewrites.count <= Self.maximumRewriteRules,
              headerBodyRewrites.count <= Self.maximumRewriteRules,
              scripts.count <= Self.maximumScripts else {
            throw MITMConfigurationError.tooManyRules
        }

        for rule in urlRewrites {
            try validateRegex(rule.pattern)
        }
        for rule in headerBodyRewrites {
            try validateRegex(rule.urlPattern)
            try validateRegex(rule.pattern)
        }
        for script in scripts {
            guard !script.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MITMConfigurationError.invalidScriptName
            }
            guard (1...2_000).contains(script.timeoutMs) else {
                throw MITMConfigurationError.invalidTimeout(script.timeoutMs)
            }
            try validateRegex(script.urlPattern)
        }

        return self
    }

    /// Serializes configuration together with transient Keychain CA PEMs for in-memory
    /// core activation (`caCertPEM` & `caKeyPEM` are never written to disk by the core).
    public func corePayloadData(caCertPEM: String, caKeyPEM: String) throws -> Data {
        struct CorePayload: Encodable {
            let enabled: Bool
            let hostPatterns: [String]
            let bypassHosts: [String]
            let caCertPEM: String
            let caKeyPEM: String
            let urlRewrites: [MITMURLRewriteRule]
            let headerBodyRewrites: [MITMHeaderBodyRewriteRule]
            let scripts: [MITMJSScriptRule]
        }
        let validated = try self.validated()
        let cleanedHosts = validated.hostPatterns
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let cleanedBypass = validated.bypassHosts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let payload = CorePayload(
            enabled: validated.isEnabled && !cleanedHosts.isEmpty && !caCertPEM.isEmpty && !caKeyPEM.isEmpty,
            hostPatterns: cleanedHosts,
            bypassHosts: cleanedBypass,
            caCertPEM: caCertPEM,
            caKeyPEM: caKeyPEM,
            urlRewrites: validated.urlRewrites,
            headerBodyRewrites: validated.headerBodyRewrites,
            scripts: validated.scripts
        )
        return try JSONEncoder().encode(payload)
    }

    private func validateRegex(_ pattern: String) throws {
        guard !pattern.isEmpty else {
            throw MITMConfigurationError.invalidRegex(pattern)
        }
        do {
            _ = try NSRegularExpression(pattern: pattern)
        } catch {
            throw MITMConfigurationError.invalidRegex(pattern)
        }
    }
}

public final class MITMConfigurationStore: @unchecked Sendable {
    public static let defaultKey = "AetherRoute.MITMConfiguration"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = MITMConfigurationStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> MITMConfiguration {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(MITMConfiguration.self, from: data),
              let validated = try? decoded.validated() else {
            return MITMConfiguration()
        }
        return validated
    }

    public func save(_ config: MITMConfiguration) throws {
        let validated = try config.validated()
        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: key)
    }
}

public struct MITMHTTPCaptureEntry: Identifiable, Codable, Equatable, Sendable {
    public let id: UInt64
    public let timestampUnixMs: UInt64
    public let method: String
    public let url: String
    public let host: String
    public let statusCode: UInt16
    public let durationMs: UInt32
    public let requestHeaders: [String: String]
    public let responseHeaders: [String: String]
    public let requestBodyPreview: String
    public let responseBodyPreview: String
    public let appliedRules: [String]

    public init(
        id: UInt64,
        timestampUnixMs: UInt64,
        method: String,
        url: String,
        host: String,
        statusCode: UInt16,
        durationMs: UInt32,
        requestHeaders: [String: String],
        responseHeaders: [String: String],
        requestBodyPreview: String,
        responseBodyPreview: String,
        appliedRules: [String] = []
    ) {
        self.id = id
        self.timestampUnixMs = timestampUnixMs
        self.method = method
        self.url = url
        self.host = host
        self.statusCode = statusCode
        self.durationMs = durationMs
        self.requestHeaders = requestHeaders
        self.responseHeaders = responseHeaders
        self.requestBodyPreview = requestBodyPreview
        self.responseBodyPreview = responseBodyPreview
        self.appliedRules = appliedRules
    }

    public func cURLCommand() -> String {
        var parts: [String] = ["curl -X \(Self.sanitizeToken(method))", Self.shellSingleQuote(url)]
        for key in requestHeaders.keys.sorted() {
            guard let value = requestHeaders[key] else { continue }
            let lower = key.lowercased()
            if lower == "content-length" || lower == "host" { continue }
            parts.append("-H \(Self.shellSingleQuote("\(key): \(value)"))")
        }
        if !requestBodyPreview.isEmpty {
            parts.append("--data-raw \(Self.shellSingleQuote(requestBodyPreview))")
        }
        return parts.joined(separator: " ")
    }

    private static func sanitizeToken(_ raw: String) -> String {
        let filtered = raw.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F && $0 != "'" }
        let s = String(String.UnicodeScalarView(filtered))
        return s.isEmpty ? "GET" : s
    }

    private static func shellSingleQuote(_ value: String) -> String {
        let stripped = value.unicodeScalars.filter { $0 != "\0" }
        let s = String(String.UnicodeScalarView(stripped))
        let escaped = s.replacingOccurrences(of: "'", with: "'\"'\"'")
        return "'\(escaped)'"
    }
}

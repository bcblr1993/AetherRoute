import Foundation

public enum CustomRuleKind: String, Codable, CaseIterable, Sendable {
    case domainSuffix = "DOMAIN-SUFFIX"
    case domain = "DOMAIN"
    case domainKeyword = "DOMAIN-KEYWORD"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case geoIP = "GEOIP"
    /// An application rule (1.3.0). Created only from an app the user picks,
    /// never parsed from rule text or accepted from a profile; see
    /// `CustomRule.application(...)`.
    case application = "AETHER-APP"

    public var displayName: String {
        rawValue
    }

    /// The kinds a user can type in the rule editor.
    public static let editableKinds: [Self] = allCases.filter { $0 != .application }
}

public enum CustomRuleTarget: Codable, Equatable, Hashable, Sendable {
    case direct
    case reject
    case proxy(String)

    public var rawString: String {
        switch self {
        case .direct: return "DIRECT"
        case .reject: return "REJECT"
        case let .proxy(name): return name
        }
    }

    public var isDirect: Bool {
        if case .direct = self { return true }
        return false
    }

    public var isReject: Bool {
        if case .reject = self { return true }
        return false
    }

    public init(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let upper = trimmed.uppercased()
        if upper == "DIRECT" {
            self = .direct
        } else if upper == "REJECT" {
            self = .reject
        } else {
            self = .proxy(trimmed)
        }
    }
}

public struct CustomRule: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public var kind: CustomRuleKind
    public var value: String
    public var target: CustomRuleTarget
    public var noResolve: Bool
    public var isEnabled: Bool
    public var comment: String?

    public init(
        id: UUID = UUID(),
        kind: CustomRuleKind,
        value: String,
        target: CustomRuleTarget,
        noResolve: Bool = false,
        isEnabled: Bool = true,
        comment: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        self.target = target
        self.noResolve = noResolve
        self.isEnabled = isEnabled
        self.comment = comment?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A rule for one app: its connections go to `target` before any other
    /// rule is considered. The payload is `<bundleIdentifier>;<bundlePath>`
    /// with the path percent-encoded, so a comma or semicolon in a folder
    /// name cannot split the rule. The display name is kept in `comment`.
    public static func application(
        id: UUID = UUID(),
        bundleIdentifier: String?,
        bundlePath: String?,
        displayName: String,
        target: CustomRuleTarget,
        isEnabled: Bool = true
    ) -> CustomRule? {
        let identifier = (bundleIdentifier ?? "").trimmingCharacters(in: .whitespaces)
        let path = (bundlePath ?? "").trimmingCharacters(in: .whitespaces)
        guard
            let encodedPath = path.addingPercentEncoding(
                withAllowedCharacters: ApplicationRuleMatch.pathAllowed
            )
        else { return nil }
        let rule = CustomRule(
            id: id,
            kind: .application,
            value: "\(identifier);\(encodedPath)",
            target: target,
            isEnabled: isEnabled,
            comment: displayName
        )
        return CustomRuleValidator.validate(rule).isValid ? rule : nil
    }

    /// The app an `.application` rule names; nil for every other kind.
    public var applicationMatch: ApplicationRuleMatch? {
        guard kind == .application else { return nil }
        return ApplicationRuleMatch(payload: value)
    }

    public func toClashRuleString() -> String {
        var parts: [String] = [kind.rawValue, value, target.rawString]
        if noResolve && (kind == .ipCIDR || kind == .ipCIDR6 || kind == .geoIP) {
            parts.append("no-resolve")
        }
        return parts.joined(separator: ",")
    }

    /// Parses a standard Clash rule string such as:
    /// `DOMAIN-SUFFIX,google.com,DIRECT`
    /// `IP-CIDR,100.64.0.0/10,DIRECT,no-resolve`
    public static func parse(_ rawInput: String, id: UUID = UUID(), comment: String? = nil) throws -> CustomRule {
        var input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.hasPrefix("-") {
            input = input.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Remove surrounding quotes if present
        if (input.hasPrefix("'") && input.hasSuffix("'")) || (input.hasPrefix("\"") && input.hasSuffix("\"")) {
            input = String(input.dropFirst().dropLast())
        }

        let tokens = input.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        guard tokens.count >= 3 else {
            throw CustomRuleParseError.insufficientComponents
        }

        let kindRaw = tokens[0].uppercased()
        guard let kind = CustomRuleKind(rawValue: kindRaw), kind != .application else {
            throw CustomRuleParseError.unsupportedKind(tokens[0])
        }

        let value = tokens[1]
        guard !value.isEmpty else {
            throw CustomRuleParseError.emptyValue
        }

        let target = CustomRuleTarget(rawValue: tokens[2])

        var noResolve = false
        if tokens.count >= 4 {
            let fourth = tokens[3].lowercased()
            if fourth == "no-resolve" {
                noResolve = true
            }
        }

        let rule = CustomRule(
            id: id,
            kind: kind,
            value: value,
            target: target,
            noResolve: noResolve,
            isEnabled: true,
            comment: comment
        )

        let validation = CustomRuleValidator.validate(rule)
        if case let .invalid(reason) = validation {
            throw CustomRuleParseError.validationFailed(reason)
        }

        return rule
    }
}

public enum CustomRuleParseError: LocalizedError, Equatable {
    case insufficientComponents
    case unsupportedKind(String)
    case emptyValue
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientComponents:
            return "Rule requires at least 3 parts (e.g. DOMAIN-SUFFIX,example.com,DIRECT)"
        case let .unsupportedKind(kind):
            return "Unsupported rule kind: \(kind). Supported: DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR, IP-CIDR6, GEOIP"
        case .emptyValue:
            return "Rule criteria / destination cannot be empty"
        case let .validationFailed(reason):
            return reason
        }
    }
}

public enum RuleValidationResult: Equatable {
    case valid
    case invalid(reason: String)

    public var isValid: Bool {
        if case .valid = self { return true }
        return false
    }

    public var reason: String? {
        if case let .invalid(reason) = self { return reason }
        return nil
    }
}

public enum CustomRuleValidator {

    public static func validate(kind: CustomRuleKind, value: String, target: CustomRuleTarget) -> RuleValidationResult {
        let trimmedVal = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVal.isEmpty else {
            return .invalid(reason: "匹配条件不能为空")
        }

        switch kind {
        case .domain, .domainSuffix:
            return validateDomain(trimmedVal)
        case .domainKeyword:
            return validateKeyword(trimmedVal)
        case .ipCIDR:
            return validateIPv4CIDR(trimmedVal)
        case .ipCIDR6:
            return validateIPv6CIDR(trimmedVal)
        case .geoIP:
            return validateGeoIP(trimmedVal)
        case .application:
            return ApplicationRuleMatch(payload: trimmedVal) == nil
                ? .invalid(reason: "应用规则需要合法的签名标识或 .app 路径")
                : .valid
        }
    }

    public static func validate(_ rule: CustomRule) -> RuleValidationResult {
        validate(kind: rule.kind, value: rule.value, target: rule.target)
    }

    private static func validateDomain(_ input: String) -> RuleValidationResult {
        var domain = input.lowercased()
        if domain.hasPrefix("*.") {
            domain = String(domain.dropFirst(2))
        }
        if domain.hasPrefix(".") {
            domain = String(domain.dropFirst())
        }
        if domain.hasSuffix(".") {
            domain = String(domain.dropLast())
        }

        guard !domain.isEmpty, domain.count <= 253 else {
            return .invalid(reason: "域名长度必须在 1 到 253 个字符之间")
        }
        if domain.contains("/") || domain.contains(":") || domain.contains(" ") {
            return .invalid(reason: "域名不能包含空格、斜杠或冒号")
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            return .invalid(reason: "域名格式不合法")
        }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else {
                return .invalid(reason: "域名标签长度必须在 1 到 63 个字符之间")
            }
            guard !label.hasPrefix("-") && !label.hasSuffix("-") else {
                return .invalid(reason: "域名标签不能以连字符 '-' 开头或结尾")
            }
            for char in label {
                guard char.isASCII && (char.isLetter || char.isNumber || char == "-") else {
                    return .invalid(reason: "域名仅允许英文字母、数字和连字符 '-'")
                }
            }
        }
        return .valid
    }

    private static func validateKeyword(_ input: String) -> RuleValidationResult {
        if input.contains("/") || input.contains(" ") || input.contains(",") {
            return .invalid(reason: "关键字不能包含空格、斜杠或逗号")
        }
        return .valid
    }

    private static func validateIPv4CIDR(_ input: String) -> RuleValidationResult {
        let parts = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .invalid(reason: "IPv4 CIDR 必须包含斜杠前缀，例如 100.64.0.0/10")
        }
        guard let prefix = Int(parts[1]), (1...32).contains(prefix) else {
            return .invalid(reason: "IPv4 CIDR 前缀必须为 1 到 32 之间的整数 (不支持 /0 全网劫持)")
        }

        var addr = in_addr()
        let ipString = String(parts[0])
        guard ipString.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
            return .invalid(reason: "无效的 IPv4 地址: \(ipString)")
        }

        let hostOrderIP = UInt32(bigEndian: addr.s_addr)
        let mask: UInt32 = prefix == 32 ? 0xFFFF_FFFF : ~((1 << (32 - prefix)) - 1)
        if (hostOrderIP & ~mask) != 0 {
            var canonicalIP = in_addr(s_addr: (hostOrderIP & mask).bigEndian)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let canonicalStr = inet_ntop(AF_INET, &canonicalIP, &buffer, socklen_t(INET_ADDRSTRLEN))
                .map { String(cString: $0) } ?? ipString
            return .invalid(reason: "CIDR 主机位必须为 0，建议使用规范网络前缀: \(canonicalStr)/\(prefix)")
        }
        return .valid
    }

    private static func validateIPv6CIDR(_ input: String) -> RuleValidationResult {
        let parts = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .invalid(reason: "IPv6 CIDR 必须包含斜杠前缀，例如 fd7a:115c:a1e0::/48")
        }
        guard let prefix = Int(parts[1]), (1...128).contains(prefix) else {
            return .invalid(reason: "IPv6 CIDR 前缀必须为 1 到 128 之间的整数 (不支持 /0 全网劫持)")
        }

        var addr = in6_addr()
        let ipString = String(parts[0])
        guard ipString.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
            return .invalid(reason: "无效的 IPv6 地址: \(ipString)")
        }
        return .valid
    }


    private static func validateGeoIP(_ input: String) -> RuleValidationResult {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return .invalid(reason: "GEOIP 必须是 2 位国家代码，例如 CN, US, HK")
        }
        return .valid
    }
}

/// The bundle an application rule matches, decoded from its payload.
/// Matches the engine's `AETHER-APP` rule: the connection's signing
/// identifier equals `bundleIdentifier` or starts with it plus "." (helpers),
/// or its executable lies inside `bundlePath`.
public struct ApplicationRuleMatch: Equatable, Sendable {
    /// Path characters left as-is; everything else, including `,` `;` `%`
    /// and spaces, is percent-encoded in the payload.
    static let pathAllowed: CharacterSet = {
        var set = CharacterSet.alphanumerics
        set.insert(charactersIn: "/._-+~@()")
        return set
    }()

    public static let maximumFieldBytes = 512

    public let bundleIdentifier: String?
    public let bundlePath: String?

    public init?(payload: String) {
        guard let separator = payload.firstIndex(of: ";") else { return nil }
        let identifier = String(payload[..<separator])
        let encodedPath = String(payload[payload.index(after: separator)...])
        guard let path = encodedPath.removingPercentEncoding else { return nil }
        let identifierCharacters = CharacterSet.alphanumerics
            .union(CharacterSet(charactersIn: ".-_"))
        guard
            identifier.utf8.count <= Self.maximumFieldBytes,
            path.utf8.count <= Self.maximumFieldBytes,
            identifier.unicodeScalars.allSatisfy(identifierCharacters.contains),
            !identifier.hasPrefix("."), !identifier.hasSuffix("."),
            path.isEmpty || (path.hasPrefix("/") && path.count > 1 && !path.hasSuffix("/")),
            !path.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
            !identifier.isEmpty || !path.isEmpty,
            encodedPath.unicodeScalars.allSatisfy({
                Self.pathAllowed.contains($0) || $0 == "%"
            })
        else { return nil }
        self.bundleIdentifier = identifier.isEmpty ? nil : identifier
        self.bundlePath = path.isEmpty ? nil : path
    }
}

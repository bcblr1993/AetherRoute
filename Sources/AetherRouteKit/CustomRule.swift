import Foundation

public enum CustomRuleKind: String, Codable, CaseIterable, Sendable {
    case domainSuffix = "DOMAIN-SUFFIX"
    case domain = "DOMAIN"
    case domainKeyword = "DOMAIN-KEYWORD"
    case domainWildcard = "DOMAIN-WILDCARD"
    case domainRegex = "DOMAIN-REGEX"
    case ipCIDR = "IP-CIDR"
    case ipCIDR6 = "IP-CIDR6"
    case geoIP = "GEOIP"
    case geoSite = "GEOSITE"
    case ipASN = "IP-ASN"
    case dstPort = "DST-PORT"
    case network = "NETWORK"
    case processName = "PROCESS-NAME"
    case processPath = "PROCESS-PATH"
    case and = "AND"
    /// An application rule (1.3.0). Created only from an app the user picks,
    /// never parsed from rule text or accepted from a profile; see
    /// `CustomRule.application(...)`.
    case application = "AETHER-APP"

    public var displayName: String {
        rawValue
    }

    /// The kinds a user can create or edit in the rule editor.
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

    /// One-click preset blocking QUIC (`UDP/443`) via a composite Clash `AND`
    /// rule so HTTP/3 falls back cleanly to TCP/TLS without breaking UDP DNS.
    public static func blockQUICPreset(
        id: UUID = UUID(),
        target: CustomRuleTarget = .reject,
        isEnabled: Bool = true,
        comment: String? = "Block QUIC (UDP 443)"
    ) -> CustomRule {
        CustomRule(
            id: id,
            kind: .and,
            value: "((NETWORK,UDP),(DST-PORT,443))",
            target: target,
            noResolve: false,
            isEnabled: isEnabled,
            comment: comment
        )
    }

    public func toClashRuleString() -> String {
        let emittedValue = kind == .network ? value.uppercased() : value
        var parts: [String] = [kind.rawValue, emittedValue, target.rawString]
        if noResolve && (kind == .ipCIDR || kind == .ipCIDR6 || kind == .geoIP || kind == .ipASN) {
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

        // Split on first comma (kind) and trailing commas (target / optional no-resolve)
        // so payloads like DOMAIN-REGEX (`\d{1,3}`) or AND (`((NETWORK,UDP),(DST-PORT,443))`)
        // preserve their internal commas intact.
        guard let firstComma = input.firstIndex(of: ",") else {
            throw CustomRuleParseError.insufficientComponents
        }
        let kindToken = String(input[..<firstComma]).trimmingCharacters(in: .whitespacesAndNewlines)
        var remainder = String(input[input.index(after: firstComma)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var noResolve = false
        if let lastComma = remainder.lastIndex(of: ",") {
            let tail = String(remainder[remainder.index(after: lastComma)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            if tail == "no-resolve" {
                noResolve = true
                remainder = String(remainder[..<lastComma])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        guard let targetComma = remainder.lastIndex(of: ",") else {
            throw CustomRuleParseError.insufficientComponents
        }
        let rawValue = String(remainder[..<targetComma]).trimmingCharacters(in: .whitespacesAndNewlines)
        let targetToken = String(remainder[remainder.index(after: targetComma)...])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !kindToken.isEmpty, !targetToken.isEmpty else {
            throw CustomRuleParseError.insufficientComponents
        }

        let kindRaw = kindToken.uppercased()
        guard let kind = CustomRuleKind(rawValue: kindRaw), kind != .application else {
            throw CustomRuleParseError.unsupportedKind(kindToken)
        }

        let value = kind == .network ? rawValue.uppercased() : rawValue
        guard !value.isEmpty else {
            throw CustomRuleParseError.emptyValue
        }

        let target = CustomRuleTarget(rawValue: targetToken)

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

public enum CustomRuleValidationIssue: Equatable, Sendable {
    case emptyCriteria
    case applicationRuleInvalid
    case domainLength
    case domainForbiddenCharacters
    case domainInvalidFormat
    case domainLabelLength
    case domainLabelHyphenBoundary
    case domainLabelInvalidCharacters
    case keywordForbiddenCharacters
    case ipv4CIDRMissingPrefix
    case ipv4CIDRInvalidPrefix
    case ipv4InvalidAddress(String)
    case ipv4CIDRHostBitsNonZero(String, Int)
    case ipv6CIDRMissingPrefix
    case ipv6CIDRInvalidPrefix
    case ipv6InvalidAddress(String)
    case geoIPInvalid
    case geoSiteLength
    case geoSiteInvalidStart
    case geoSiteInvalidCharacters
    case dstPortInvalid
    case domainWildcardLength
    case domainWildcardForbiddenCharacters
    case domainWildcardInvalidCharacters
    case domainRegexLength
    case domainRegexNewline
    case domainRegexInvalidSyntax(String)
    case ipASNInvalid
    case networkInvalid
    case processNameLength
    case processNameForbiddenCharacters
    case processPathFormat
    case processPathForbiddenCharacters
    case processPathMissingExecutable
    case compositeANDFormat
    case compositeANDUnbalancedParentheses

    public var localizedDescription: String {
        let locale = AppLocalizationLocaleBridge.currentLocale
        switch self {
        case .emptyCriteria:
            return String(localized: "Criteria cannot be empty", locale: locale)
        case .applicationRuleInvalid:
            return String(localized: "Application rules require a valid signing identifier or .app bundle path", locale: locale)
        case .domainLength:
            return String(localized: "Domain length must be between 1 and 253 characters", locale: locale)
        case .domainForbiddenCharacters:
            return String(localized: "Domain cannot contain spaces, slashes, or colons", locale: locale)
        case .domainInvalidFormat:
            return String(localized: "Invalid domain format", locale: locale)
        case .domainLabelLength:
            return String(localized: "Each domain label must be 1 to 63 characters long", locale: locale)
        case .domainLabelHyphenBoundary:
            return String(localized: "Domain labels cannot begin or end with '-'", locale: locale)
        case .domainLabelInvalidCharacters:
            return String(localized: "Domain labels may only contain ASCII letters, digits, and '-'", locale: locale)
        case .keywordForbiddenCharacters:
            return String(localized: "Keyword cannot contain spaces, slashes, or commas", locale: locale)
        case .ipv4CIDRMissingPrefix:
            return String(localized: "IPv4 CIDR must include a slash prefix, e.g. 100.64.0.0/10", locale: locale)
        case .ipv4CIDRInvalidPrefix:
            return String(localized: "IPv4 CIDR prefix must be between 1 and 32", locale: locale)
        case let .ipv4InvalidAddress(ip):
            let format = String(localized: "Invalid IPv4 address: %@", locale: locale)
            return String(format: format, locale: locale, ip)
        case let .ipv4CIDRHostBitsNonZero(canonical, prefix):
            let format = String(localized: "CIDR host bits must be zero; use %@/%lld", locale: locale)
            return String(format: format, locale: locale, canonical, Int64(prefix))
        case .ipv6CIDRMissingPrefix:
            return String(localized: "IPv6 CIDR must include a slash prefix, e.g. fd7a:115c:a1e0::/48", locale: locale)
        case .ipv6CIDRInvalidPrefix:
            return String(localized: "IPv6 CIDR prefix must be between 1 and 128", locale: locale)
        case let .ipv6InvalidAddress(ip):
            let format = String(localized: "Invalid IPv6 address: %@", locale: locale)
            return String(format: format, locale: locale, ip)
        case .geoIPInvalid:
            return String(localized: "GEOIP must be a 2-letter country code, e.g. CN, US, HK", locale: locale)
        case .geoSiteLength:
            return String(localized: "GEOSITE category length must be 1 to 64 characters, e.g. cn, apple, openai", locale: locale)
        case .geoSiteInvalidStart:
            return String(localized: "GEOSITE category must start with an ASCII letter or digit", locale: locale)
        case .geoSiteInvalidCharacters:
            return String(localized: "GEOSITE category may only contain ASCII letters, digits, '-', '_', '!', '@', and '.'", locale: locale)
        case .dstPortInvalid:
            return String(localized: "DST-PORT must be a port number between 1 and 65535, e.g. 443 or 80", locale: locale)
        case .domainWildcardLength:
            return String(localized: "DOMAIN-WILDCARD length must be between 1 and 253 characters", locale: locale)
        case .domainWildcardForbiddenCharacters:
            return String(localized: "DOMAIN-WILDCARD cannot contain spaces, slashes, colons, or commas", locale: locale)
        case .domainWildcardInvalidCharacters:
            return String(localized: "DOMAIN-WILDCARD may only contain ASCII domain characters and '*', '?', '+' wildcards", locale: locale)
        case .domainRegexLength:
            return String(localized: "DOMAIN-REGEX length must be between 1 and 512 characters", locale: locale)
        case .domainRegexNewline:
            return String(localized: "DOMAIN-REGEX cannot contain newlines", locale: locale)
        case let .domainRegexInvalidSyntax(detail):
            let format = String(localized: "Invalid DOMAIN-REGEX syntax: %@", locale: locale)
            return String(format: format, locale: locale, detail)
        case .ipASNInvalid:
            return String(localized: "IP-ASN must be a non-zero ASN such as 13335 or AS13335", locale: locale)
        case .networkInvalid:
            return String(localized: "NETWORK supports only TCP or UDP", locale: locale)
        case .processNameLength:
            return String(localized: "PROCESS-NAME length must be between 1 and 256 bytes", locale: locale)
        case .processNameForbiddenCharacters:
            return String(localized: "PROCESS-NAME cannot contain '/', commas, or newlines", locale: locale)
        case .processPathFormat:
            return String(localized: "PROCESS-PATH must be an absolute path starting with '/', e.g. /usr/bin/curl", locale: locale)
        case .processPathForbiddenCharacters:
            return String(localized: "PROCESS-PATH cannot contain commas, NUL characters, or newlines", locale: locale)
        case .processPathMissingExecutable:
            return String(localized: "PROCESS-PATH must include an executable filename", locale: locale)
        case .compositeANDFormat:
            return String(localized: "AND composite rules must follow ((NETWORK,UDP),(DST-PORT,443))", locale: locale)
        case .compositeANDUnbalancedParentheses:
            return String(localized: "AND composite rule has unbalanced parentheses", locale: locale)
        }
    }
}

public enum CustomRuleParseError: LocalizedError, Equatable {
    case insufficientComponents
    case unsupportedKind(String)
    case emptyValue
    case validationFailed(String)

    public var errorDescription: String? {
        let locale = AppLocalizationLocaleBridge.currentLocale
        switch self {
        case .insufficientComponents:
            return String(
                localized: "Rule requires at least 3 parts (e.g. DOMAIN-SUFFIX,example.com,DIRECT)",
                locale: locale
            )
        case let .unsupportedKind(kind):
            let format = String(
                localized: "Unsupported rule kind: %@. Supported: DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, DOMAIN-WILDCARD, DOMAIN-REGEX, IP-CIDR, IP-CIDR6, GEOIP, GEOSITE, IP-ASN, DST-PORT, NETWORK, PROCESS-NAME, PROCESS-PATH, AND",
                locale: locale
            )
            return String(format: format, locale: locale, kind)
        case .emptyValue:
            return String(
                localized: "Rule criteria / destination cannot be empty",
                locale: locale
            )
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
        if let issue = validateIssue(kind: kind, value: value, target: target) {
            return .invalid(reason: issue.localizedDescription)
        }
        return .valid
    }

    public static func validate(_ rule: CustomRule) -> RuleValidationResult {
        validate(kind: rule.kind, value: rule.value, target: rule.target)
    }

    public static func validateIssue(
        kind: CustomRuleKind,
        value: String,
        target: CustomRuleTarget
    ) -> CustomRuleValidationIssue? {
        let trimmedVal = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVal.isEmpty else {
            return .emptyCriteria
        }

        switch kind {
        case .domain, .domainSuffix:
            return validateDomainIssue(trimmedVal)
        case .domainKeyword:
            return validateKeywordIssue(trimmedVal)
        case .domainWildcard:
            return validateDomainWildcardIssue(trimmedVal)
        case .domainRegex:
            return validateDomainRegexIssue(trimmedVal)
        case .ipCIDR:
            return validateIPv4CIDRIssue(trimmedVal)
        case .ipCIDR6:
            return validateIPv6CIDRIssue(trimmedVal)
        case .geoIP:
            return validateGeoIPIssue(trimmedVal)
        case .geoSite:
            return validateGeoSiteIssue(trimmedVal)
        case .ipASN:
            return validateIPASNIssue(trimmedVal)
        case .dstPort:
            return validateDstPortIssue(trimmedVal)
        case .network:
            return validateNetworkIssue(trimmedVal)
        case .processName:
            return validateProcessNameIssue(trimmedVal)
        case .processPath:
            return validateProcessPathIssue(trimmedVal)
        case .and:
            return validateCompositeANDIssue(trimmedVal)
        case .application:
            return ApplicationRuleMatch(payload: trimmedVal) == nil
                ? .applicationRuleInvalid
                : nil
        }
    }

    public static func validateIssue(_ rule: CustomRule) -> CustomRuleValidationIssue? {
        validateIssue(kind: rule.kind, value: rule.value, target: rule.target)
    }

    private static func validateDomainIssue(_ input: String) -> CustomRuleValidationIssue? {
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
            return .domainLength
        }
        if domain.contains("/") || domain.contains(":") || domain.contains(" ") {
            return .domainForbiddenCharacters
        }

        let labels = domain.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else {
            return .domainInvalidFormat
        }

        for label in labels {
            guard !label.isEmpty, label.count <= 63 else {
                return .domainLabelLength
            }
            guard !label.hasPrefix("-") && !label.hasSuffix("-") else {
                return .domainLabelHyphenBoundary
            }
            for char in label {
                guard char.isASCII && (char.isLetter || char.isNumber || char == "-") else {
                    return .domainLabelInvalidCharacters
                }
            }
        }
        return nil
    }

    private static func validateKeywordIssue(_ input: String) -> CustomRuleValidationIssue? {
        if input.contains("/") || input.contains(" ") || input.contains(",") {
            return .keywordForbiddenCharacters
        }
        return nil
    }

    private static func validateIPv4CIDRIssue(_ input: String) -> CustomRuleValidationIssue? {
        let parts = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .ipv4CIDRMissingPrefix
        }
        guard let prefix = Int(parts[1]), (1...32).contains(prefix) else {
            return .ipv4CIDRInvalidPrefix
        }

        var addr = in_addr()
        let ipString = String(parts[0])
        guard ipString.withCString({ inet_pton(AF_INET, $0, &addr) }) == 1 else {
            return .ipv4InvalidAddress(ipString)
        }

        let hostOrderIP = UInt32(bigEndian: addr.s_addr)
        let mask: UInt32 = prefix == 32 ? 0xFFFF_FFFF : ~((1 << (32 - prefix)) - 1)
        if (hostOrderIP & ~mask) != 0 {
            var canonicalIP = in_addr(s_addr: (hostOrderIP & mask).bigEndian)
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let canonicalStr = inet_ntop(AF_INET, &canonicalIP, &buffer, socklen_t(INET_ADDRSTRLEN))
                .map { String(cString: $0) } ?? ipString
            return .ipv4CIDRHostBitsNonZero(canonicalStr, prefix)
        }
        return nil
    }

    private static func validateIPv6CIDRIssue(_ input: String) -> CustomRuleValidationIssue? {
        let parts = input.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return .ipv6CIDRMissingPrefix
        }
        guard let prefix = Int(parts[1]), (1...128).contains(prefix) else {
            return .ipv6CIDRInvalidPrefix
        }

        var addr = in6_addr()
        let ipString = String(parts[0])
        guard ipString.withCString({ inet_pton(AF_INET6, $0, &addr) }) == 1 else {
            return .ipv6InvalidAddress(ipString)
        }
        return nil
    }

    private static func validateGeoIPIssue(_ input: String) -> CustomRuleValidationIssue? {
        let code = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
            return .geoIPInvalid
        }
        return nil
    }

    private static func validateGeoSiteIssue(_ input: String) -> CustomRuleValidationIssue? {
        let category = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !category.isEmpty, category.count <= 64 else {
            return .geoSiteLength
        }
        guard let first = category.first, first.isASCII && (first.isLetter || first.isNumber) else {
            return .geoSiteInvalidStart
        }
        let allowedPunctuation: Set<Character> = ["-", "_", "!", "@", "."]
        let isValidChars = category.allSatisfy { char in
            char.isASCII && (char.isLetter || char.isNumber || allowedPunctuation.contains(char))
        }
        guard isValidChars else {
            return .geoSiteInvalidCharacters
        }
        return nil
    }

    private static func validateDstPortIssue(_ input: String) -> CustomRuleValidationIssue? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(trimmed),
              (1...65_535).contains(port),
              String(port) == trimmed
        else {
            return .dstPortInvalid
        }
        return nil
    }

    private static func validateDomainWildcardIssue(_ input: String) -> CustomRuleValidationIssue? {
        let pattern = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, pattern.count <= 253 else {
            return .domainWildcardLength
        }
        if pattern.contains("/") || pattern.contains(":") || pattern.contains(",")
            || pattern.contains(where: \.isWhitespace) {
            return .domainWildcardForbiddenCharacters
        }
        let allowed: Set<Character> = ["*", "?", "+", ".", "-", "_"]
        guard pattern.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || allowed.contains($0)) }),
              pattern.contains(where: { $0.isLetter || $0.isNumber || $0 == "*" || $0 == "?" }) else {
            return .domainWildcardInvalidCharacters
        }
        return nil
    }

    private static func validateDomainRegexIssue(_ input: String) -> CustomRuleValidationIssue? {
        let pattern = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty, pattern.count <= 512 else {
            return .domainRegexLength
        }
        guard !pattern.contains(where: \.isNewline) else {
            return .domainRegexNewline
        }
        do {
            _ = try NSRegularExpression(pattern: pattern)
            return nil
        } catch {
            return .domainRegexInvalidSyntax(error.localizedDescription)
        }
    }

    private static func validateIPASNIssue(_ input: String) -> CustomRuleValidationIssue? {
        var raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.uppercased().hasPrefix("AS") {
            raw = String(raw.dropFirst(2))
        }
        guard !raw.isEmpty,
              raw.allSatisfy({ $0.isASCII && $0.isNumber }),
              let asn = UInt32(raw),
              asn > 0 else {
            return .ipASNInvalid
        }
        return nil
    }

    private static func validateNetworkIssue(_ input: String) -> CustomRuleValidationIssue? {
        let upper = input.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard upper == "TCP" || upper == "UDP" else {
            return .networkInvalid
        }
        return nil
    }

    private static func validateProcessNameIssue(_ input: String) -> CustomRuleValidationIssue? {
        let name = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.utf8.count <= 256 else {
            return .processNameLength
        }
        if name.contains("/") || name.contains(",") || name.contains("\0")
            || name.contains(where: \.isNewline) {
            return .processNameForbiddenCharacters
        }
        return nil
    }

    private static func validateProcessPathIssue(_ input: String) -> CustomRuleValidationIssue? {
        let path = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard path.hasPrefix("/"), path.count > 1, path.utf8.count <= 1_024 else {
            return .processPathFormat
        }
        if path.contains(",") || path.contains("\0") || path.contains(where: \.isNewline) {
            return .processPathForbiddenCharacters
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else {
            return .processPathMissingExecutable
        }
        return nil
    }

    private static func validateCompositeANDIssue(_ input: String) -> CustomRuleValidationIssue? {
        let expr = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard expr.hasPrefix("("), expr.hasSuffix(")"),
              expr.contains(","),
              !expr.contains(where: \.isNewline) else {
            return .compositeANDFormat
        }
        var depth = 0
        for ch in expr {
            if ch == "(" { depth += 1 }
            else if ch == ")" {
                depth -= 1
                if depth < 0 {
                    return .compositeANDUnbalancedParentheses
                }
            }
        }
        guard depth == 0 else {
            return .compositeANDUnbalancedParentheses
        }
        return nil
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

    /// Candidate process executable basenames derived from an optional
    /// `CFBundleExecutable` name and the `.app` bundle stem in `bundlePath`.
    public func expectedProcessNames(bundleExecutableName: String? = nil) -> [String] {
        var names: [String] = []
        var seen = Set<String>()
        func append(_ raw: String?) {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty else { return }
            let basename = URL(fileURLWithPath: trimmed).lastPathComponent
            guard !basename.isEmpty, seen.insert(basename).inserted else { return }
            names.append(basename)
        }
        append(bundleExecutableName)
        if let bundlePath {
            let last = URL(fileURLWithPath: bundlePath).lastPathComponent
            if last.lowercased().hasSuffix(".app"), last.count > 4 {
                append(String(last.dropLast(4)))
            } else {
                append(last)
            }
        }
        return names
    }

    /// Evaluates whether a connection's process metadata matches this application rule,
    /// supporting signing identifier prefix matching, firmlink / AppTranslocation `.app`
    /// bundle paths, and NE-sandbox process basename matching when `proc_pidpath` is unavailable.
    public func matches(
        signingIdentifier: String? = nil,
        executablePath: String? = nil,
        processName: String? = nil,
        bundleExecutableName: String? = nil
    ) -> Bool {
        if let bundleIdentifier {
            let sig = signingIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !sig.isEmpty, sig == bundleIdentifier || sig.hasPrefix(bundleIdentifier + ".") {
                return true
            }
        }

        let exec = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let bundlePath, !exec.isEmpty {
            let normalizedBundle = bundlePath.hasSuffix("/") && bundlePath.count > 1
                ? String(bundlePath.dropLast())
                : bundlePath
            if exec == normalizedBundle || exec.hasPrefix(normalizedBundle + "/") {
                return true
            }
            let bundleComponent = URL(fileURLWithPath: normalizedBundle).lastPathComponent
            if bundleComponent.lowercased().hasSuffix(".app"),
               exec.contains("/\(bundleComponent)/") || exec.hasSuffix("/\(bundleComponent)") {
                return true
            }
        }

        let sig = signingIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sigConflict = bundleIdentifier != nil && !sig.isEmpty
        if exec.isEmpty && !sigConflict {
            let rawProc = processName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let procBasename = URL(fileURLWithPath: rawProc).lastPathComponent
            if !procBasename.isEmpty {
                return expectedProcessNames(bundleExecutableName: bundleExecutableName)
                    .contains(procBasename)
            }
        }

        return false
    }
}

public extension CustomRule {
    /// Evaluates whether runtime process metadata matches this custom rule
    /// (`.application`, `.processName`, or `.processPath`).
    func matchesApplication(
        signingIdentifier: String? = nil,
        executablePath: String? = nil,
        processName: String? = nil,
        bundleExecutableName: String? = nil
    ) -> Bool {
        guard isEnabled else { return false }
        switch kind {
        case .application:
            return applicationMatch?.matches(
                signingIdentifier: signingIdentifier,
                executablePath: executablePath,
                processName: processName,
                bundleExecutableName: bundleExecutableName
            ) ?? false
        case .processName:
            let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty else { return false }
            let candidate = (processName ?? executablePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return !candidate.isEmpty && URL(fileURLWithPath: candidate).lastPathComponent == target
        case .processPath:
            let target = value.trimmingCharacters(in: .whitespacesAndNewlines)
            let exec = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !target.isEmpty, !exec.isEmpty else { return false }
            return exec == target
        default:
            return false
        }
    }
}

/// The outcome of parsing a pasted block of Clash rules: every rule that
/// could be imported, and every line that could not, with its reason.
public struct CustomRuleBatchReport: Equatable, Sendable {
    public struct SkippedLine: Equatable, Sendable {
        /// 1-based line number in the pasted text.
        public let lineNumber: Int
        public let line: String
        public let reason: String
    }

    public var rules: [CustomRule]
    public var skipped: [SkippedLine]
    /// More than `CustomRule.maximumBatchRules` rules were pasted; the rest
    /// were not read.
    public var wasTruncated: Bool
}

public extension CustomRule {
    static let maximumBatchRules = 500

    /// Parses a multi-line Clash rule text block (such as `payload:` lists or
    /// newline-separated rules). When `defaultTarget` is supplied, classical
    /// two-token lines (`DOMAIN-SUFFIX,example.com`) use `defaultTarget`.
    ///
    /// Rule lists copied from other clients routinely contain kinds this
    /// app does not import (`MATCH`, `RULE-SET`, `PROCESS-NAME`). Such lines
    /// are reported and skipped so one of them cannot discard the rest.
    /// - Parameter rejection: An extra check that returns the reason a parsed
    ///   rule cannot be imported (for example an unknown GEOSITE category).
    static func parseBatchReport(
        _ rawText: String,
        defaultTarget: CustomRuleTarget? = nil,
        rejection: ((CustomRule) -> String?)? = nil
    ) -> CustomRuleBatchReport {
        var report = CustomRuleBatchReport(rules: [], skipped: [], wasTruncated: false)
        let lines = rawText.components(separatedBy: .newlines)
        for (offset, rawLine) in lines.enumerated() {
            var line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") {
                continue
            }
            let lower = line.lowercased()
            if lower == "payload:" || lower == "rules:" {
                continue
            }
            if line.hasPrefix("-") {
                line = line.dropFirst().trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if (line.hasPrefix("'") && line.hasSuffix("'")) || (line.hasPrefix("\"") && line.hasSuffix("\"")) {
                line = String(line.dropFirst().dropLast())
            }
            guard report.rules.count < Self.maximumBatchRules else {
                report.wasTruncated = true
                break
            }
            let tokens = line.split(separator: ",", omittingEmptySubsequences: true)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            var candidate = line
            if tokens.count == 2, let fallback = defaultTarget {
                candidate = "\(tokens[0]),\(tokens[1]),\(fallback.rawString)"
                let upperKind = tokens[0].uppercased()
                if upperKind == "IP-CIDR" || upperKind == "IP-CIDR6"
                    || upperKind == "GEOIP" || upperKind == "IP-ASN" {
                    candidate += ",no-resolve"
                }
            }
            do {
                let rule = try CustomRule.parse(candidate)
                if let reason = rejection?(rule) {
                    report.skipped.append(.init(lineNumber: offset + 1, line: line, reason: reason))
                } else {
                    report.rules.append(rule)
                }
            } catch {
                report.skipped.append(.init(
                    lineNumber: offset + 1,
                    line: line,
                    reason: error.localizedDescription
                ))
            }
        }
        return report
    }
}

public struct ConnectionDestinationRuleCandidate: Equatable, Hashable, Sendable {
    public let kind: CustomRuleKind
    public let value: String
    public let noResolve: Bool

    public init(kind: CustomRuleKind, value: String, noResolve: Bool) {
        self.kind = kind
        self.value = value
        self.noResolve = noResolve
    }
}

/// Derives safe, non-Fake-IP custom rule candidates from a live connection destination.
public enum ConnectionDestinationRulePlanner {
    private static let multiPartPublicSuffixes: Set<String> = [
        "co.uk", "org.uk", "ac.uk", "gov.uk",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn",
        "com.hk", "edu.hk", "org.hk", "gov.hk",
        "com.tw", "org.tw", "edu.tw", "gov.tw",
        "co.jp", "ne.jp", "or.jp", "ac.jp", "go.jp",
        "co.kr", "or.kr", "ne.kr",
        "com.au", "net.au", "org.au", "edu.au",
        "com.sg", "edu.sg", "org.sg",
        "com.br", "com.mx", "co.in", "co.nz", "co.za"
    ]

    public static func candidates(for rawDestination: String) -> [ConnectionDestinationRuleCandidate] {
        let host = extractHost(from: rawDestination).lowercased()
        guard !host.isEmpty else { return [] }

        // Check IPv4
        var addr4 = in_addr()
        if inet_pton(AF_INET, host, &addr4) == 1 {
            guard isRoutablePublicIPv4(addr4) else { return [] }
            return [ConnectionDestinationRuleCandidate(kind: .ipCIDR, value: "\(host)/32", noResolve: true)]
        }

        // Check IPv6
        var addr6 = in6_addr()
        if inet_pton(AF_INET6, host, &addr6) == 1 {
            guard isRoutablePublicIPv6(host) else { return [] }
            return [ConnectionDestinationRuleCandidate(kind: .ipCIDR6, value: "\(host)/128", noResolve: true)]
        }

        // Domain validation & local/mDNS exclusion
        guard host != "localhost",
              !host.hasSuffix(".local"),
              !host.hasSuffix(".internal"),
              !host.hasSuffix(".invalid"),
              !host.hasSuffix(".arpa"),
              host.contains("."),
              CustomRuleValidator.validate(kind: .domain, value: host, target: .direct).isValid
        else {
            return []
        }

        let root = registrableDomain(for: host)
        if root == host {
            return [
                ConnectionDestinationRuleCandidate(kind: .domainSuffix, value: root, noResolve: false),
            ]
        } else {
            return [
                ConnectionDestinationRuleCandidate(kind: .domainSuffix, value: root, noResolve: false),
                ConnectionDestinationRuleCandidate(kind: .domain, value: host, noResolve: false),
            ]
        }
    }

    private static func extractHost(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        if trimmed.hasPrefix("[") {
            if let closeBracket = trimmed.firstIndex(of: "]") {
                return String(trimmed[trimmed.index(after: trimmed.startIndex)..<closeBracket])
            }
            return trimmed
        }
        let colons = trimmed.filter { $0 == ":" }.count
        if colons == 1, let colonIdx = trimmed.lastIndex(of: ":") {
            let portPart = trimmed[trimmed.index(after: colonIdx)...]
            if !portPart.isEmpty && portPart.allSatisfy({ $0.isASCII && $0.isNumber }) {
                return String(trimmed[..<colonIdx])
            }
        }
        return trimmed
    }

    private static func registrableDomain(for host: String) -> String {
        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }
        let lastTwo = "\(labels[labels.count - 2]).\(labels[labels.count - 1])"
        if labels.count >= 3 && multiPartPublicSuffixes.contains(lastTwo) {
            return "\(labels[labels.count - 3]).\(lastTwo)"
        }
        return lastTwo
    }

    private static func isRoutablePublicIPv4(_ addr: in_addr) -> Bool {
        let hostOrder = UInt32(bigEndian: addr.s_addr)
        let a = UInt8((hostOrder >> 24) & 0xFF)
        let b = UInt8((hostOrder >> 16) & 0xFF)
        let c = UInt8((hostOrder >> 8) & 0xFF)

        if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
        if a == 169 && b == 254 { return false }
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        // CGNAT / Tailscale 100.64.0.0/10
        if a == 100 && (64...127).contains(b) { return false }
        // Synthetic Fake-IP benchmark range 198.18.0.0/15
        if a == 198 && (b == 18 || b == 19) { return false }
        // TEST-NET ranges
        if a == 192 && b == 0 && c == 2 { return false }
        if a == 198 && b == 51 && c == 100 { return false }
        if a == 203 && b == 0 && c == 113 { return false }
        return true
    }

    private static func isRoutablePublicIPv6(_ normalizedHost: String) -> Bool {
        if normalizedHost == "::" || normalizedHost == "::1" { return false }
        if normalizedHost.hasPrefix("fe80:") || normalizedHost.hasPrefix("fc") || normalizedHost.hasPrefix("fd") {
            return false
        }
        if normalizedHost.hasPrefix("2001:db8:") { return false }
        return true
    }
}

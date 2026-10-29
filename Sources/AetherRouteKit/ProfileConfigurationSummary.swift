import CoreFoundation
import Darwin
import Foundation

public struct ProfileConfigurationSummary: Equatable, Sendable {
    public let dns: DNSConfigurationSummary
    public let proxies: [ProxyConfigurationSummary]
    public let proxyGroups: [ProxyGroupConfigurationSummary]
    public let proxyProviders: [ProviderConfigurationSummary]
    public let rules: [RuleConfigurationSummary]
    public let allRules: [RuleConfigurationSummary]
    public let ruleProviders: [ProviderConfigurationSummary]
    public let proxyCount: Int
    public let proxyGroupCount: Int
    public let proxyProviderCount: Int
    public let ruleCount: Int
    public let ruleProviderCount: Int
    public let directRuleCount: Int
    public let proxyRuleCount: Int
    public let rejectRuleCount: Int
    public let requiresCountryMMDB: Bool
    public let requiresGeoSiteDatabase: Bool
    /// Mirrors the profile's top-level `ipv6` switch, which defaults to `false`
    /// exactly as the protocol core does. The tunnel must not claim the IPv6
    /// default route unless the profile states that its outbounds can carry
    /// IPv6; otherwise every IPv6 flow the system prefers is black-holed.
    public let allowsIPv6: Bool
    /// Nodes, rules and options the engine cannot use, counted over the
    /// whole profile (not only the displayed items).
    public let compatibility: ProfileCompatibilityReport

    public init(
        dns: DNSConfigurationSummary,
        proxies: [ProxyConfigurationSummary],
        proxyGroups: [ProxyGroupConfigurationSummary],
        proxyProviders: [ProviderConfigurationSummary],
        rules: [RuleConfigurationSummary],
        allRules: [RuleConfigurationSummary]? = nil,
        ruleProviders: [ProviderConfigurationSummary],
        proxyCount: Int,
        proxyGroupCount: Int,
        proxyProviderCount: Int,
        ruleCount: Int,
        ruleProviderCount: Int,
        directRuleCount: Int? = nil,
        proxyRuleCount: Int? = nil,
        rejectRuleCount: Int? = nil,
        requiresCountryMMDB: Bool = false,
        requiresGeoSiteDatabase: Bool = false,
        allowsIPv6: Bool = false,
        compatibility: ProfileCompatibilityReport = .fullySupported
    ) {
        self.dns = dns
        self.proxies = proxies
        self.proxyGroups = proxyGroups
        self.proxyProviders = proxyProviders
        self.rules = rules
        let fullRules = allRules ?? rules
        self.allRules = fullRules
        self.ruleProviders = ruleProviders
        self.proxyCount = proxyCount
        self.proxyGroupCount = proxyGroupCount
        self.proxyProviderCount = proxyProviderCount
        self.ruleCount = ruleCount
        self.ruleProviderCount = ruleProviderCount
        self.directRuleCount = directRuleCount ?? fullRules.filter { $0.target.uppercased() == "DIRECT" }.count
        self.rejectRuleCount = rejectRuleCount ?? fullRules.filter {
            let upper = $0.target.uppercased()
            return upper == "REJECT" || upper == "REJECT-DROP"
        }.count
        self.proxyRuleCount = proxyRuleCount ?? fullRules.filter {
            let upper = $0.target.uppercased()
            return upper != "DIRECT" && upper != "REJECT" && upper != "REJECT-DROP"
        }.count
        self.requiresCountryMMDB = requiresCountryMMDB
        self.requiresGeoSiteDatabase = requiresGeoSiteDatabase
        self.allowsIPv6 = allowsIPv6
        self.compatibility = compatibility
    }
}

/// Why the engine cannot use a node. Each comes from the engine's own
/// capability list (`EngineCapabilities`).
public enum ProxyUnsupportedReason: Hashable, Sendable {
    case protocolType(String)
    case network(String)
    case plugin(String)
    /// A node option the engine does not implement and cannot connect without.
    case option(String)
}

/// What the engine would drop or ignore when loading a profile.
public struct ProfileCompatibilityReport: Equatable, Sendable {
    public struct UnsupportedProxies: Equatable, Sendable {
        public let reason: ProxyUnsupportedReason
        public let count: Int
        /// The first few node names, for display.
        public let examples: [String]

        public init(reason: ProxyUnsupportedReason, count: Int, examples: [String]) {
            self.reason = reason
            self.count = count
            self.examples = examples
        }
    }

    public struct UnsupportedRules: Equatable, Sendable {
        public let kind: String
        public let count: Int

        public init(kind: String, count: Int) {
            self.kind = kind
            self.count = count
        }
    }

    /// An option the engine ignores; the node still connects without it.
    public struct LimitedOption: Equatable, Sendable {
        public let option: String
        public let count: Int

        public init(option: String, count: Int) {
            self.option = option
            self.count = count
        }
    }

    public static let maximumExamples = 3
    public static let fullySupported = ProfileCompatibilityReport(
        unsupportedProxies: [], unsupportedRules: [], limitedOptions: []
    )

    /// In order of first appearance.
    public let unsupportedProxies: [UnsupportedProxies]
    public let unsupportedRules: [UnsupportedRules]
    public let limitedOptions: [LimitedOption]

    public init(
        unsupportedProxies: [UnsupportedProxies],
        unsupportedRules: [UnsupportedRules],
        limitedOptions: [LimitedOption]
    ) {
        self.unsupportedProxies = unsupportedProxies
        self.unsupportedRules = unsupportedRules
        self.limitedOptions = limitedOptions
    }

    public var unsupportedProxyCount: Int { unsupportedProxies.reduce(0) { $0 + $1.count } }
    public var unsupportedRuleCount: Int { unsupportedRules.reduce(0) { $0 + $1.count } }
    public var isFullySupported: Bool { unsupportedProxies.isEmpty && unsupportedRules.isEmpty }
}

public enum DNSResolutionMode: String, Equatable, Sendable {
    case normal
    case fakeIP
    case redirHost
    case unsupported
}

public enum DNSUpstreamTransport: String, CaseIterable, Equatable, Hashable,
    Sendable
{
    case udp
    case tcp
    case dnsOverTLS
    case dnsOverHTTPS
    case dhcp
    case unsupported
}

/// A bounded projection of the active profile's DNS behavior. It deliberately
/// retains no server address, hostname, path, query, interface, policy domain,
/// or Fake-IP filter value so diagnostics and accessibility descriptions cannot
/// disclose profile credentials or browsing policy.
public struct DNSConfigurationSummary: Equatable, Sendable {
    public let isPresent: Bool
    public let isEnabled: Bool
    public let allowsIPv6: Bool
    public let usesHosts: Bool
    public let respectsRules: Bool
    public let mode: DNSResolutionMode
    public let nameserverCount: Int
    public let fallbackCount: Int
    public let defaultNameserverCount: Int
    public let proxyNameserverCount: Int
    public let nameserverPolicyCount: Int
    public let fakeIPFilterCount: Int
    public let upstreamTransports: [DNSUpstreamTransport]
    public let hasExplicitFakeIPRange: Bool
    public let hasListener: Bool
    public let hasFallbackFilter: Bool
    public let hasEDNSClientSubnet: Bool

    public init(
        isPresent: Bool = false,
        isEnabled: Bool = false,
        allowsIPv6: Bool = false,
        usesHosts: Bool = true,
        respectsRules: Bool = false,
        mode: DNSResolutionMode = .normal,
        nameserverCount: Int = 0,
        fallbackCount: Int = 0,
        defaultNameserverCount: Int = 0,
        proxyNameserverCount: Int = 0,
        nameserverPolicyCount: Int = 0,
        fakeIPFilterCount: Int = 0,
        upstreamTransports: [DNSUpstreamTransport] = [],
        hasExplicitFakeIPRange: Bool = false,
        hasListener: Bool = false,
        hasFallbackFilter: Bool = false,
        hasEDNSClientSubnet: Bool = false
    ) {
        self.isPresent = isPresent
        self.isEnabled = isEnabled
        self.allowsIPv6 = allowsIPv6
        self.usesHosts = usesHosts
        self.respectsRules = respectsRules
        self.mode = mode
        self.nameserverCount = nameserverCount
        self.fallbackCount = fallbackCount
        self.defaultNameserverCount = defaultNameserverCount
        self.proxyNameserverCount = proxyNameserverCount
        self.nameserverPolicyCount = nameserverPolicyCount
        self.fakeIPFilterCount = fakeIPFilterCount
        self.upstreamTransports = upstreamTransports
        self.hasExplicitFakeIPRange = hasExplicitFakeIPRange
        self.hasListener = hasListener
        self.hasFallbackFilter = hasFallbackFilter
        self.hasEDNSClientSubnet = hasEDNSClientSubnet
    }
}

public struct ProxyConfigurationSummary: Identifiable, Equatable, Sendable {
    public enum Recognition: Equatable, Sendable {
        case recognized
        case requiresCoreValidation
        case incomplete
        /// The engine cannot load or connect this node.
        case unsupported(ProxyUnsupportedReason)

        /// Whether selecting the node can work at all.
        public var isUsable: Bool {
            switch self {
            case .recognized, .requiresCoreValidation: true
            case .incomplete, .unsupported: false
            }
        }
    }

    public let id: Int
    public let name: String
    public let protocolName: String
    public let recognition: Recognition

    public init(
        id: Int,
        name: String,
        protocolName: String,
        recognition: Recognition
    ) {
        self.id = id
        self.name = name
        self.protocolName = protocolName
        self.recognition = recognition
    }
}

/// One proxy-server socket from an already validated profile. This projection
/// is used only inside the Network Extension while constructing narrowly
/// scoped recursion exclusions. Callers must not log or persist these values.
public struct ProfileUpstreamEndpoint: Equatable, Hashable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16) {
        self.host = host
        self.port = port
    }
}

public enum ProfileUpstreamEndpointInspector {
    public static let maximumEndpoints =
        ProfileConfigurationInspector.maximumDisplayedItemsPerSection

    public static func inspect(yaml: String) -> [ProfileUpstreamEndpoint] {
        var parser = Parser(yaml: yaml)
        return parser.parseUpstreamEndpoints()
    }
}

public enum ProfileNamedEndpointInspector {
    public static func inspect(yaml: String) -> [String: ProfileUpstreamEndpoint] {
        var parser = Parser(yaml: yaml)
        return parser.parseNamedEndpoints()
    }
}

public enum ProfileHostsInspector {
    public static func inspect(yaml: String) -> [String: String] {
        var parser = Parser(yaml: yaml)
        return parser.parseHosts()
    }

    public static func resolveAlias(_ host: String, in hosts: [String: String]) -> String {
        var current = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var hops = 0
        while hops < 8 {
            if let direct = hosts[current] {
                current = direct.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                hops += 1
                continue
            }
            if let dotIndex = current.firstIndex(of: ".") {
                let wildcard = "*" + current[dotIndex...]
                if let target = hosts[wildcard] {
                    current = target.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    hops += 1
                    continue
                }
            }
            break
        }
        return current
    }
}

public struct ProxyGroupConfigurationSummary: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let strategy: String
    public let memberCount: Int
    /// Bounded inline members are a disconnected-state hint only. The live
    /// Network Extension selector snapshot remains authoritative because
    /// provider-backed groups can expand to a different runtime membership.
    public let members: [String]

    public init(
        id: Int,
        name: String,
        strategy: String,
        memberCount: Int,
        members: [String] = []
    ) {
        self.id = id
        self.name = name
        self.strategy = strategy
        self.memberCount = memberCount
        self.members = members
    }
}

public struct ProviderConfigurationSummary: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let sourceType: String

    public init(id: Int, name: String, sourceType: String) {
        self.id = id
        self.name = name
        self.sourceType = sourceType
    }
}

public struct RuleConfigurationSummary: Identifiable, Equatable, Sendable {
    public let id: Int
    public let order: Int
    public let kind: String
    public let criteria: String?
    public let target: String
    public let isCustom: Bool
    public let noResolve: Bool

    public init(
        id: Int,
        order: Int,
        kind: String,
        criteria: String?,
        target: String,
        isCustom: Bool = false,
        noResolve: Bool = false
    ) {
        self.id = id
        self.order = order
        self.kind = kind
        self.criteria = criteria
        self.target = target
        self.isCustom = isCustom
        self.noResolve = noResolve
    }

    public var overrideCustomRuleKind: CustomRuleKind? {
        guard let criteria, !criteria.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        switch kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DOMAIN": return .domain
        case "DOMAIN-SUFFIX": return .domainSuffix
        case "DOMAIN-KEYWORD": return .domainKeyword
        case "IP-CIDR": return .ipCIDR
        case "IP-CIDR6": return .ipCIDR6
        case "GEOIP": return .geoIP
        case "GEOSITE": return .geoSite
        case "DST-PORT": return .dstPort
        default: return nil
        }
    }

    public func makeCustomRuleOverride(target: CustomRuleTarget) -> CustomRule? {
        guard let customKind = overrideCustomRuleKind,
              let criteria = criteria?.trimmingCharacters(in: .whitespacesAndNewlines),
              !criteria.isEmpty else {
            return nil
        }
        return CustomRule(
            kind: customKind,
            value: criteria,
            target: target,
            noResolve: noResolve,
            isEnabled: true
        )
    }
}

public struct RouteMatchResult: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let matchedRule: RuleConfigurationSummary
    public let reason: String
    public let order: Int
    public let target: String

    public var isCustomRule: Bool {
        matchedRule.isCustom
    }

    public init(
        id: UUID = UUID(),
        matchedRule: RuleConfigurationSummary,
        reason: String,
        order: Int,
        target: String
    ) {
        self.id = id
        self.matchedRule = matchedRule
        self.reason = reason
        self.order = order
        self.target = target
    }
}

/// A destination-only preview cannot resolve runtime DNS, Geo databases,
/// providers, source metadata, or the member selected by an outbound group.
public enum RouteMatchAssessment: Equatable, Sendable {
    case matched(RouteMatchResult)
    case indeterminate(ruleOrder: Int?)
    case noMatch
    case invalidDestination
}

public enum RouteMatchEngine {
    public static func evaluate(
        destination: String,
        against rules: [RuleConfigurationSummary],
        totalRuleCount: Int? = nil,
        geoSiteData: Data? = nil
    ) -> RouteMatchResult? {
        if case let .matched(result) = assess(
            destination: destination,
            against: rules,
            totalRuleCount: totalRuleCount,
            geoSiteData: geoSiteData
        ) {
            return result
        }
        return nil
    }

    public static func assess(
        destination: String,
        against rules: [RuleConfigurationSummary],
        totalRuleCount: Int? = nil,
        geoSiteData: Data? = nil
    ) -> RouteMatchAssessment {
        guard let parsed = destinationHostAndPort(destination) else { return .invalidDestination }
        let host = parsed.host
        let port = parsed.port
        let address = addressBytes(host)
        for rule in rules {
            let kind = rule.kind.uppercased()
            let criteria = rule.criteria?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let matches: Bool
            switch kind {
            case "MATCH", "FINAL":
                matches = true
            case "AETHER-APP":
                // Depends on the app making the request; the tester asks
                // about a destination alone, as for an app without a rule.
                matches = false
            case "DOMAIN", "DOMAIN-SUFFIX", "DOMAIN-KEYWORD":
                guard let criteria, !criteria.isEmpty else {
                    return .indeterminate(ruleOrder: rule.order)
                }
                if address != nil { matches = false }
                else if kind == "DOMAIN" { matches = host == criteria }
                else if kind == "DOMAIN-SUFFIX" {
                    matches = host == criteria || host.hasSuffix("." + criteria)
                } else { matches = host.contains(criteria) }
            case "IP-CIDR", "IP-CIDR6":
                guard let criteria, isValidCIDR(criteria) else {
                    return .indeterminate(ruleOrder: rule.order)
                }
                if let address {
                    guard let result = matchesCIDR(address: address, cidr: criteria) else {
                        return .indeterminate(ruleOrder: rule.order)
                    }
                    matches = result
                } else if rule.noResolve {
                    // A `no-resolve` IP rule never triggers DNS resolution in
                    // the core and therefore never matches a domain name.
                    matches = false
                } else {
                    // Without `no-resolve`, a hostname may resolve into this
                    // subnet at runtime.
                    return .indeterminate(ruleOrder: rule.order)
                }
            case "GEOIP":
                guard let criteria, !criteria.isEmpty else {
                    return .indeterminate(ruleOrder: rule.order)
                }
                if let address {
                    if criteria == "private" || criteria == "lan" {
                        matches = isPrivateAddress(address)
                    } else {
                        return .indeterminate(ruleOrder: rule.order)
                    }
                } else if rule.noResolve {
                    matches = false
                } else {
                    return .indeterminate(ruleOrder: rule.order)
                }
            case "DST-PORT":
                guard let criteria, let rulePort = UInt16(criteria), rulePort > 0,
                      let destinationPort = port else {
                    return .indeterminate(ruleOrder: rule.order)
                }
                matches = destinationPort == rulePort
            case "GEOSITE":
                guard let criteria, !criteria.isEmpty else {
                    return .indeterminate(ruleOrder: rule.order)
                }
                if address != nil {
                    matches = false
                } else if let geoSiteData,
                          let result = GeoSiteCategoryIndex.matches(
                            domain: host,
                            ruleValue: criteria,
                            in: geoSiteData
                          ) {
                    matches = result
                } else {
                    return .indeterminate(ruleOrder: rule.order)
                }
            default:
                // An earlier unsupported rule could win in the real core.
                return .indeterminate(ruleOrder: rule.order)
            }
            if matches {
                let reason = rule.isCustom
                    ? "命中用户自定义规则 (优先级最高)"
                    : "Matched destination preview rule"
                return .matched(RouteMatchResult(
                    matchedRule: rule,
                    reason: reason,
                    order: rule.order,
                    target: rule.target
                ))
            }
        }
        if let totalRuleCount, totalRuleCount > rules.count {
            return .indeterminate(ruleOrder: nil)
        }
        return .noMatch
    }

    private static func destinationHostAndPort(_ destination: String) -> (host: String, port: UInt16?)? {
        let raw = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        if addressBytes(raw) != nil { return (raw, nil) }
        let hasExplicitScheme = raw.contains("://")
        let value = hasExplicitScheme ? raw : "https://" + raw
        guard let url = URLComponents(string: value),
              url.user == nil, url.password == nil,
              var host = url.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
            guard addressBytes(host) != nil else { return nil }
        }
        if host.hasSuffix(".") { host.removeLast() }
        guard !host.isEmpty, !host.contains(":") || addressBytes(host) != nil else { return nil }

        let port: UInt16?
        if let explicitPort = url.port {
            guard (1...65_535).contains(explicitPort) else { return nil }
            port = UInt16(explicitPort)
        } else if hasExplicitScheme {
            switch url.scheme?.lowercased() {
            case "https", "wss": port = 443
            case "http", "ws": port = 80
            default: port = nil
            }
        } else {
            port = nil
        }
        return (host, port)
    }

    private static func addressBytes(_ text: String) -> [UInt8]? {
        var ipv4 = in_addr()
        if text.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return withUnsafeBytes(of: ipv4) { Array($0) }
        }
        var ipv6 = in6_addr()
        if text.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return withUnsafeBytes(of: ipv6) { Array($0) }
        }
        return nil
    }

    private static func isValidCIDR(_ cidr: String) -> Bool {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let network = addressBytes(String(parts[0])),
              let prefix = Int(parts[1]), (0...network.count * 8).contains(prefix) else { return false }
        return true
    }

    private static func matchesCIDR(address: [UInt8], cidr: String) -> Bool? {
        let parts = cidr.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, let network = addressBytes(String(parts[0])),
              let prefix = Int(parts[1]), (0...network.count * 8).contains(prefix) else { return nil }
        guard address.count == network.count else { return false }
        for index in 0..<network.count {
            let bits = min(8, max(0, prefix - index * 8))
            let mask: UInt8 = bits == 0 ? 0 : UInt8.max << (8 - bits)
            if address[index] & mask != network[index] & mask { return false }
        }
        return true
    }

    private static func isPrivateAddress(_ address: [UInt8]) -> Bool {
        if address.count == 4 {
            return address[0] == 10
                || address[0] == 127
                || address[0] == 0
                || (address[0] == 169 && address[1] == 254)
                || (address[0] == 172 && (16...31).contains(address[1]))
                || (address[0] == 192 && address[1] == 168)
        }
        if address.count == 16 {
            let isLoopbackOrUnspecified = address.dropLast().allSatisfy({ $0 == 0 })
                && (address[15] == 0 || address[15] == 1)
            let isUniqueLocal = (address[0] & 0xfe) == 0xfc
            let isLinkLocal = address[0] == 0xfe && (address[1] & 0xc0) == 0x80
            return isLoopbackOrUnspecified || isUniqueLocal || isLinkLocal
        }
        return false
    }
}

/// Produces a bounded, non-secret UI projection of an already imported profile.
/// The protocol core remains authoritative for semantic validation.
public enum ProfileConfigurationInspector {
    public static let maximumDisplayedItemsPerSection = 500
    public static let maximumEvaluatedRules = 16_384

    public static func inspect(yaml: String, customRules: [CustomRule] = []) -> ProfileConfigurationSummary {
        var parser = Parser(yaml: yaml, customRules: customRules)
        return parser.parse()
    }
}

/// Accumulates the compatibility report over every node and rule.
private struct CompatibilityBuilder {
    private var proxies: [ProxyUnsupportedReason: (order: Int, count: Int, examples: [String])] = [:]
    private var rules: [String: (order: Int, count: Int)] = [:]
    private var options: [String: (order: Int, count: Int)] = [:]
    private var order = 0

    mutating func record(item: Parser.CompatibilityItem, recognition: ProxyConfigurationSummary.Recognition) {
        order += 1
        if case let .unsupported(reason) = recognition {
            var entry = proxies[reason] ?? (order, 0, [])
            entry.count += 1
            if entry.examples.count < ProfileCompatibilityReport.maximumExamples, !item.name.isEmpty {
                entry.examples.append(item.name)
            }
            proxies[reason] = entry
            return
        }
        guard recognition.isUsable else { return }
        // client-fingerprint is applied by the engine (Chrome ClientHello).
        if item.smux { count(option: "smux") }
    }

    mutating func record(ruleKind: String) {
        let kind = ruleKind.uppercased()
        guard !EngineCapabilities.ruleTypes.contains(kind) else { return }
        order += 1
        var entry = rules[kind] ?? (order, 0)
        entry.count += 1
        rules[kind] = entry
    }

    private mutating func count(option: String) {
        order += 1
        var entry = options[option] ?? (order, 0)
        entry.count += 1
        options[option] = entry
    }

    var report: ProfileCompatibilityReport {
        ProfileCompatibilityReport(
            unsupportedProxies: proxies.sorted { $0.value.order < $1.value.order }.map {
                .init(reason: $0.key, count: $0.value.count, examples: $0.value.examples)
            },
            unsupportedRules: rules.sorted { $0.value.order < $1.value.order }.map {
                .init(kind: $0.key, count: $0.value.count)
            },
            limitedOptions: options.sorted { $0.value.order < $1.value.order }.map {
                .init(option: $0.key, count: $0.value.count)
            }
        )
    }
}

private struct Parser {
    /// The fields of a node the compatibility report reads.
    fileprivate typealias CompatibilityItem = Item

    private enum Section: String {
        case dns
        case proxies
        case proxyGroups = "proxy-groups"
        case proxyProviders = "proxy-providers"
        case rules
        case ruleProviders = "rule-providers"
        case hosts
    }

    fileprivate struct Item {
        var name = ""
        var type = ""
        var server = ""
        var port = ""
        var network = ""
        var plugin = ""
        var encryption = ""
        var smux = false
        var members: [String] = []
        var includeAll = false
        var filterPattern: String?
        var excludeFilterPattern: String?
    }

    private struct GroupFilterSpec {
        let groupIndex: Int
        let includeAll: Bool
        let filterPattern: String?
        let excludeFilterPattern: String?
        let explicitMembers: [String]
    }

    private struct PendingRule {
        let indent: Int
        var value: String
        var quote: Character?
        var emptyLines = 0
    }

    private struct DNSBuilder {
        var isPresent = false
        var isEnabled = false
        var allowsIPv6 = false
        var usesHosts = true
        var respectsRules = false
        var mode = DNSResolutionMode.normal
        var nameserverCount = 0
        var fallbackCount = 0
        var defaultNameserverCount = 0
        var proxyNameserverCount = 0
        var nameserverPolicyCount = 0
        var fakeIPFilterCount = 0
        var upstreamTransports: Set<DNSUpstreamTransport> = []
        var hasExplicitFakeIPRange = false
        var hasListener = false
        var hasFallbackFilter = false
        var hasEDNSClientSubnet = false

        var summary: DNSConfigurationSummary {
            DNSConfigurationSummary(
                isPresent: isPresent,
                isEnabled: isEnabled,
                allowsIPv6: allowsIPv6,
                usesHosts: usesHosts,
                respectsRules: respectsRules,
                mode: mode,
                nameserverCount: nameserverCount,
                fallbackCount: fallbackCount,
                defaultNameserverCount: defaultNameserverCount,
                proxyNameserverCount: proxyNameserverCount,
                nameserverPolicyCount: nameserverPolicyCount,
                fakeIPFilterCount: fakeIPFilterCount,
                upstreamTransports: DNSUpstreamTransport.allCases.filter {
                    upstreamTransports.contains($0)
                },
                hasExplicitFakeIPRange: hasExplicitFakeIPRange,
                hasListener: hasListener,
                hasFallbackFilter: hasFallbackFilter,
                hasEDNSClientSubnet: hasEDNSClientSubnet
            )
        }
    }

    private let lines: [String]
    private let jsonObject: [String: Any]?
    private var section: Section?
    private var itemIndent: Int?
    private var itemFieldIndent: Int?
    private var item: Item?
    private var providerIndent: Int?
    private var providerFieldIndent: Int?
    private var provider: Item?
    private var readingMembers = false
    private var dns = DNSBuilder()
    private var dnsFieldIndent: Int?
    private var dnsNestedField: String?
    private var pendingRule: PendingRule?

    private var proxies: [ProxyConfigurationSummary] = []
    private var allProxyNames: [String] = []
    private var deferredGroupFilters: [GroupFilterSpec] = []
    private var upstreamEndpoints: [ProfileUpstreamEndpoint] = []
    private var namedEndpoints: [String: ProfileUpstreamEndpoint] = [:]
    private var hosts: [String: String] = [:]
    private var groups: [ProxyGroupConfigurationSummary] = []
    private var proxyProviders: [ProviderConfigurationSummary] = []
    private var rules: [RuleConfigurationSummary] = []
    private var allRules: [RuleConfigurationSummary] = []
    private var ruleProviders: [ProviderConfigurationSummary] = []
    private var proxyCount = 0
    private var proxyGroupCount = 0
    private var proxyProviderCount = 0
    private var ruleCount = 0
    private var ruleProviderCount = 0
    private var directRuleCount = 0
    private var proxyRuleCount = 0
    private var rejectRuleCount = 0
    private var requiresCountryMMDB = false
    private var requiresGeoSiteDatabase = false
    private var allowsIPv6 = false
    private var compatibility = CompatibilityBuilder()
    private let customRuleSignatures: Set<String>

    init(yaml: String, customRules: [CustomRule] = []) {
        var sigs = Set<String>()
        for rule in customRules where rule.isEnabled {
            sigs.insert(rule.toClashRuleString().filter { !$0.isWhitespace }.uppercased())
        }
        self.customRuleSignatures = sigs

        // A complete JSON mapping is also a valid profile. Decode it before
        // the line-oriented YAML projection so compact and pretty JSON have
        // the same summary and recursion exclusions. Import validation still
        // owns the size/cancellation checks; the core owns semantic validation.
        if yaml.first(where: { !$0.isWhitespace }) == "{",
           let object = try? JSONSerialization.jsonObject(with: Data(yaml.utf8))
                as? [String: Any] {
            jsonObject = object
            lines = []
        } else {
            jsonObject = nil
            // CRLF is one YAML line break, not an empty paragraph between
            // content lines in a folded scalar.
            lines = yaml.replacingOccurrences(of: "\r\n", with: "\n")
                .components(separatedBy: .newlines)
        }
    }

    mutating func parse() -> ProfileConfigurationSummary {
        parseDocument()
        return summary
    }

    mutating func parseUpstreamEndpoints() -> [ProfileUpstreamEndpoint] {
        parseDocument()
        return upstreamEndpoints
    }

    mutating func parseNamedEndpoints() -> [String: ProfileUpstreamEndpoint] {
        parseDocument()
        return namedEndpoints
    }

    mutating func parseHosts() -> [String: String] {
        parseDocument()
        return hosts
    }

    private mutating func parseDocument() {
        if let jsonObject {
            parseJSONDocument(jsonObject)
            return
        }
        for rawLine in lines {
            let indent = Self.leadingSpaceCount(in: rawLine)
            if var pending = pendingRule {
                // Release the stored value before appending, so a long
                // wrapped scalar does not copy its entire prefix per line.
                pendingRule = nil
                if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                    pending.emptyLines += 1
                    pendingRule = pending
                    continue
                }
                if indent > pending.indent {
                    let continuation = Self.removingComment(
                        from: rawLine,
                        quote: &pending.quote
                    ).trimmingCharacters(in: .whitespaces)
                    guard !continuation.isEmpty else {
                        pendingRule = pending
                        continue
                    }
                    // YAML flow scalars fold adjacent content lines to a
                    // space; empty lines retain paragraph line feeds. Keep
                    // quote state so a quoted continuation can contain '#'.
                    pending.value += pending.emptyLines == 0
                        ? " " : String(repeating: "\n", count: pending.emptyLines)
                    pending.value += continuation
                    pending.emptyLines = 0
                    pendingRule = pending
                    continue
                }
                appendRule(pending.value)
            }
            let line = Self.removingComment(from: rawLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if indent == 0,
               !trimmed.hasPrefix("-"),
               let (key, value) = Self.keyValue(in: trimmed) {
                finishPendingItem()
                finishPendingProvider()
                if key.lowercased() == "ipv6", let flag = Self.boolean(value) {
                    allowsIPv6 = flag
                }
                section = Section(rawValue: key.lowercased())
                itemIndent = nil
                itemFieldIndent = nil
                providerIndent = nil
                providerFieldIndent = nil
                readingMembers = false
                dnsFieldIndent = nil
                dnsNestedField = nil
                if section == .dns {
                    dns.isPresent = true
                }
                if let section, !value.isEmpty {
                    parseInlineSection(section, value: value)
                }
                continue
            }

            switch section {
            case .dns:
                parseDNS(line: trimmed, indent: indent)
            case .proxies, .proxyGroups:
                parseListItem(line: trimmed, indent: indent)
            case .proxyProviders, .ruleProviders:
                parseProvider(line: trimmed, indent: indent)
            case .rules:
                parseRule(line: trimmed, indent: indent)
            case .hosts:
                parseHostsLine(line: trimmed, indent: indent)
            case nil:
                continue
            }
        }

        finishPendingRule()
        finishPendingItem()
        finishPendingProvider()
        resolveDeferredGroupFilters()
    }

    private mutating func parseJSONDocument(_ object: [String: Any]) {
        if let value = Self.jsonScalar(object["ipv6"]) {
            allowsIPv6 = Self.boolean(value) ?? false
        }
        if let fields = object["dns"] as? [String: Any] {
            dns.isPresent = true
            for (key, value) in fields {
                // A policy may name one resolver or a list. Only transport
                // categories and entry counts survive this projection.
                if key == "nameserver-policy",
                   let policies = value as? [String: Any] {
                    dns.nameserverPolicyCount = policies.count
                    for resolvers in policies.values {
                        for resolver in Self.jsonStrings(resolvers) {
                            recordDNSTransport(resolver)
                        }
                    }
                } else if !(value is NSNull),
                          let data = try? JSONSerialization.data(
                            withJSONObject: value,
                            options: [.fragmentsAllowed, .withoutEscapingSlashes]
                          ),
                          let field = String(data: data, encoding: .utf8) {
                    parseDNSRootField(key: key, value: field)
                }
            }
        }
        if let jsonHosts = object["hosts"] as? [String: Any] {
            for (host, target) in jsonHosts {
                if let targetStr = target as? String {
                    hosts[host] = targetStr
                }
            }
        }
        for destination in [Section.proxies, .proxyGroups] {
            section = destination
            for fields in object[destination.rawValue] as? [[String: Any]] ?? [] {
                item = Item(
                    name: Self.jsonString(fields["name"]),
                    type: Self.jsonString(fields["type"])
                )
                if destination == .proxies {
                    item?.server = Self.jsonString(fields["server"])
                    item?.port = Self.jsonPort(fields["port"])
                    for key in Self.compatibilityKeys {
                        guard let value = fields[key] else { continue }
                        if let options = value as? [String: Any] {
                            let enabled = Self.jsonScalar(options["enabled"]).flatMap(Self.boolean)
                            recordCompatibilityField(key, value: enabled == false ? "false" : "true")
                        } else if let scalar = Self.jsonScalar(value) {
                            recordCompatibilityField(key, value: scalar)
                        }
                    }
                } else {
                    item?.members = Self.jsonStrings(fields["proxies"])
                        + Self.jsonStrings(fields["use"])
                    if let inc = Self.jsonScalar(fields["include-all"]).flatMap(Self.boolean), inc {
                        item?.includeAll = true
                    }
                    if let incProxies = Self.jsonScalar(fields["include-all-proxies"]).flatMap(Self.boolean), incProxies {
                        item?.includeAll = true
                    }
                    let filterStr = Self.jsonString(fields["filter"])
                    if !filterStr.isEmpty {
                        item?.filterPattern = filterStr
                    }
                    let excludeStr = Self.jsonString(fields["exclude-filter"])
                    if !excludeStr.isEmpty {
                        item?.excludeFilterPattern = excludeStr
                    }
                }
                finishPendingItem()
            }
        }
        resolveDeferredGroupFilters()
        for destination in [Section.proxyProviders, .ruleProviders] {
            section = destination
            let fields = object[destination.rawValue] as? [String: Any] ?? [:]
            // JSON object member order is not semantic. Keep provider IDs
            // deterministic without changing ordered proxy/group/rule arrays.
            for name in fields.keys.sorted() {
                guard let values = fields[name] as? [String: Any] else { continue }
                provider = Item(
                    name: String(name.prefix(160)),
                    type: Self.jsonString(values["type"])
                )
                finishPendingProvider()
            }
        }
        for rule in object["rules"] as? [String] ?? [] {
            appendRule(rule)
        }
        if let jsonHosts = object["hosts"] as? [String: Any] {
            for (key, val) in jsonHosts {
                let k = key.trimmingCharacters(in: .whitespaces).lowercased()
                if let stringVal = Self.jsonScalar(val)?.trimmingCharacters(in: .whitespaces), !stringVal.isEmpty {
                    hosts[k] = Self.scalar(stringVal)
                }
            }
        }
    }

    private static func jsonString(_ value: Any?) -> String {
        guard let string = value as? String else { return "" }
        return String(string.prefix(160))
    }

    private static func jsonStrings(_ value: Any?) -> [String] {
        let strings = value as? [String] ?? (value as? String).map { [$0] } ?? []
        return strings.filter { !$0.isEmpty }.map { String($0.prefix(160)) }
    }

    private static func jsonScalar(_ value: Any?) -> String? {
        guard let value, value is String || value is NSNumber,
              let data = try? JSONSerialization.data(
                withJSONObject: value,
                options: [.fragmentsAllowed, .withoutEscapingSlashes]
              ) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func jsonPort(_ value: Any?) -> String {
        if let string = value as? String { return scalar(string) }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType))
        else { return "" }
        // NSNumber.stringValue erases the decimal part of 443.0. Reject its
        // floating representation first, just as UInt16 does for YAML text.
        return number.stringValue
    }

    private var summary: ProfileConfigurationSummary {
        ProfileConfigurationSummary(
            dns: dns.summary,
            proxies: proxies,
            proxyGroups: groups,
            proxyProviders: proxyProviders,
            rules: rules,
            allRules: allRules,
            ruleProviders: ruleProviders,
            proxyCount: proxyCount,
            proxyGroupCount: proxyGroupCount,
            proxyProviderCount: proxyProviderCount,
            ruleCount: ruleCount,
            ruleProviderCount: ruleProviderCount,
            directRuleCount: directRuleCount,
            proxyRuleCount: proxyRuleCount,
            rejectRuleCount: rejectRuleCount,
            requiresCountryMMDB: requiresCountryMMDB,
            requiresGeoSiteDatabase: requiresGeoSiteDatabase,
            allowsIPv6: allowsIPv6,
            compatibility: compatibility.report
        )
    }

    private mutating func parseInlineSection(_ section: Section, value: String) {
        guard value != "[]", value != "{}" else { return }
        if section == .dns,
           value.hasPrefix("{"),
           value.hasSuffix("}") {
            for field in Self.splitTopLevel(
                String(value.dropFirst().dropLast()),
                separator: ","
            ) {
                guard let (key, fieldValue) = Self.keyValue(in: field) else {
                    continue
                }
                parseDNSRootField(key: key, value: fieldValue)
            }
        } else if section == .rules,
           value.hasPrefix("["),
           value.hasSuffix("]") {
            for scalar in Self.splitFlowSequence(value) {
                appendRule(scalar)
            }
        } else if section == .hosts,
           value.hasPrefix("{"),
           value.hasSuffix("}") {
            for field in Self.splitTopLevel(
                String(value.dropFirst().dropLast()),
                separator: ","
            ) {
                guard let (key, fieldValue) = Self.keyValue(in: field) else {
                    continue
                }
                let k = key.trimmingCharacters(in: .whitespaces).lowercased()
                let rawVal = Self.scalar(fieldValue).trimmingCharacters(in: .whitespaces)
                let v: String
                if rawVal.hasPrefix("["), rawVal.hasSuffix("]") {
                    v = Self.splitFlowSequence(rawVal).first ?? ""
                } else {
                    v = rawVal
                }
                if !k.isEmpty, !v.isEmpty {
                    hosts[k] = v
                }
            }
        }
    }

    private mutating func parseDNS(line: String, indent: Int) {
        if dnsFieldIndent == nil { dnsFieldIndent = indent }
        guard let rootIndent = dnsFieldIndent else { return }

        if indent == rootIndent,
           !line.hasPrefix("-"),
           let (key, value) = Self.keyValue(in: line) {
            dnsNestedField = value.isEmpty ? key.lowercased() : nil
            parseDNSRootField(key: key, value: value)
            return
        }

        guard let nestedField = dnsNestedField else { return }
        // A YAML block sequence may align its '-' with the mapping key.
        // Sibling keys above already replace the pending field, so these
        // entries cannot leak into the preceding DNS list.
        if indent >= rootIndent, line.hasPrefix("-") {
            let value = String(line.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            appendDNSListValue(value, field: nestedField)
            return
        }
        guard indent > rootIndent else { return }
        guard let (_, value) = Self.keyValue(in: line) else { return }
        switch nestedField {
        case "nameserver-policy":
            dns.nameserverPolicyCount += 1
            recordDNSTransport(value)
        case "listen":
            dns.hasListener = true
        case "fallback-filter":
            dns.hasFallbackFilter = true
        case "edns-client-subnet":
            dns.hasEDNSClientSubnet = true
        default:
            break
        }
    }

    private mutating func parseDNSRootField(key: String, value: String) {
        let key = key.lowercased()
        switch key {
        case "enable":
            dns.isEnabled = Self.boolean(value) ?? dns.isEnabled
        case "ipv6":
            dns.allowsIPv6 = Self.boolean(value) ?? dns.allowsIPv6
        case "use-hosts":
            dns.usesHosts = Self.boolean(value) ?? dns.usesHosts
        case "respect-rules":
            dns.respectsRules = Self.boolean(value) ?? dns.respectsRules
        case "enhanced-mode":
            dns.mode = switch Self.scalar(value).lowercased() {
            case "normal": .normal
            case "fake-ip", "fakeip": .fakeIP
            case "redir-host", "redirhost": .redirHost
            default: .unsupported
            }
        case "fake-ip-range":
            dns.hasExplicitFakeIPRange = !Self.scalar(value).isEmpty
        case "listen":
            dns.hasListener = !value.isEmpty && value != "{}"
        case "fallback-filter":
            dns.hasFallbackFilter = !value.isEmpty && value != "{}"
        case "edns-client-subnet":
            dns.hasEDNSClientSubnet = !value.isEmpty && value != "{}"
        case "nameserver", "fallback", "default-nameserver",
             "proxy-server-nameserver", "fake-ip-filter":
            guard !value.isEmpty else { return }
            for item in Self.splitFlowSequence(value) {
                appendDNSListValue(item, field: key)
            }
        case "nameserver-policy":
            guard value.hasPrefix("{"), value.hasSuffix("}") else { return }
            for item in Self.splitTopLevel(
                String(value.dropFirst().dropLast()),
                separator: ","
            ) {
                guard let (_, server) = Self.keyValue(in: item) else { continue }
                dns.nameserverPolicyCount += 1
                recordDNSTransport(server)
            }
        default:
            break
        }
    }

    private mutating func appendDNSListValue(_ value: String, field: String) {
        guard !Self.scalar(value).isEmpty else { return }
        switch field {
        case "nameserver":
            dns.nameserverCount += 1
            recordDNSTransport(value)
        case "fallback":
            dns.fallbackCount += 1
            recordDNSTransport(value)
        case "default-nameserver":
            dns.defaultNameserverCount += 1
            recordDNSTransport(value)
        case "proxy-server-nameserver":
            dns.proxyNameserverCount += 1
            recordDNSTransport(value)
        case "fake-ip-filter":
            dns.fakeIPFilterCount += 1
        default:
            break
        }
    }

    private mutating func recordDNSTransport(_ rawValue: String) {
        let value = Self.scalar(rawValue).lowercased()
        guard !value.isEmpty else { return }
        let transport: DNSUpstreamTransport
        if !value.contains("://") {
            transport = .udp
        } else if value.hasPrefix("udp://") {
            transport = .udp
        } else if value.hasPrefix("tcp://") {
            transport = .tcp
        } else if value.hasPrefix("tls://") {
            transport = .dnsOverTLS
        } else if value.hasPrefix("https://") {
            transport = .dnsOverHTTPS
        } else if value.hasPrefix("dhcp://") {
            transport = .dhcp
        } else {
            transport = .unsupported
        }
        dns.upstreamTransports.insert(transport)
    }

    private mutating func parseListItem(line: String, indent: Int) {
        guard let section else { return }

        if line.hasPrefix("-") {
            if itemIndent == nil { itemIndent = indent }
            if indent == itemIndent {
                finishPendingItem()
                item = Item()
                itemFieldIndent = nil
                readingMembers = false
                parseItemFields(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                return
            }

            if section == .proxyGroups, readingMembers, indent > (itemIndent ?? 0) {
                let member = Self.scalar(
                    String(line.dropFirst()).trimmingCharacters(in: .whitespaces)
                )
                if !member.isEmpty { item?.members.append(member) }
            }
            return
        }

        guard item != nil, indent > (itemIndent ?? -1),
              let (key, value) = Self.keyValue(in: line)
        else { return }
        if itemFieldIndent == nil { itemFieldIndent = indent }
        guard indent == itemFieldIndent else { return }
        switch key.lowercased() {
        case "name":
            item?.name = Self.scalar(value)
            readingMembers = false
        case "type":
            item?.type = Self.scalar(value)
            readingMembers = false
        case "server" where section == .proxies:
            item?.server = Self.scalar(value)
            readingMembers = false
        case "port" where section == .proxies:
            item?.port = Self.scalar(value)
            readingMembers = false
        case let key where section == .proxies && Self.compatibilityKeys.contains(key):
            recordCompatibilityField(key, value: value)
            readingMembers = false
        case let key where section == .proxyGroups
            && (key == "proxies" || key == "use"):
            readingMembers = value.isEmpty
            if !value.isEmpty {
                item?.members.append(contentsOf: Self.splitFlowSequence(value))
            }
        case let key where section == .proxyGroups
            && (key == "include-all" || key == "include-all-proxies"):
            readingMembers = false
            if Self.boolean(value) == true {
                item?.includeAll = true
            }
        case "filter" where section == .proxyGroups:
            readingMembers = false
            let pattern = Self.scalar(value)
            if !pattern.isEmpty {
                item?.filterPattern = pattern
            }
        case "exclude-filter" where section == .proxyGroups:
            readingMembers = false
            let pattern = Self.scalar(value)
            if !pattern.isEmpty {
                item?.excludeFilterPattern = pattern
            }
        default:
            readingMembers = false
        }
    }

    private mutating func parseItemFields(_ value: String) {
        guard !value.isEmpty else { return }
        let fields = value.hasPrefix("{") && value.hasSuffix("}")
            ? Self.splitTopLevel(String(value.dropFirst().dropLast()), separator: ",")
            : [value]
        for field in fields {
            guard let (key, value) = Self.keyValue(in: field) else { continue }
            switch key.lowercased() {
            case "name": item?.name = Self.scalar(value)
            case "type": item?.type = Self.scalar(value)
            case "server" where section == .proxies:
                item?.server = Self.scalar(value)
            case "port" where section == .proxies:
                item?.port = Self.scalar(value)
            case let key where section == .proxies && Self.compatibilityKeys.contains(key):
                recordCompatibilityField(key, value: value)
            case let key where section == .proxyGroups
                && (key == "proxies" || key == "use"):
                item?.members.append(contentsOf: Self.splitFlowSequence(value))
            case let key where section == .proxyGroups
                && (key == "include-all" || key == "include-all-proxies"):
                if Self.boolean(value) == true {
                    item?.includeAll = true
                }
            case "filter" where section == .proxyGroups:
                let pattern = Self.scalar(value)
                if !pattern.isEmpty {
                    item?.filterPattern = pattern
                }
            case "exclude-filter" where section == .proxyGroups:
                let pattern = Self.scalar(value)
                if !pattern.isEmpty {
                    item?.excludeFilterPattern = pattern
                }
            default: continue
            }
        }
    }

    private mutating func finishPendingItem() {
        guard let item, let section else {
            self.item = nil
            return
        }
        defer { self.item = nil }

        switch section {
        case .proxies:
            proxyCount += 1
            if !item.name.isEmpty {
                allProxyNames.append(item.name)
            }
            let recognition = Self.recognition(of: item)
            compatibility.record(item: item, recognition: recognition)
            if !item.server.isEmpty,
               let port = UInt16(item.port),
               port > 0 {
                let endpoint = ProfileUpstreamEndpoint(host: item.server, port: port)
                if upstreamEndpoints.count < ProfileUpstreamEndpointInspector.maximumEndpoints {
                    upstreamEndpoints.append(endpoint)
                }
                if !item.name.isEmpty, namedEndpoints.count < ProfileUpstreamEndpointInspector.maximumEndpoints {
                    namedEndpoints[item.name] = endpoint
                }
            }
            guard proxies.count < ProfileConfigurationInspector.maximumDisplayedItemsPerSection else {
                return
            }
            let name = item.name.isEmpty ? "Unnamed proxy" : item.name
            let type = item.type.isEmpty ? "Unknown" : item.type
            proxies.append(
                ProxyConfigurationSummary(
                    id: proxies.count,
                    name: name,
                    protocolName: type,
                    recognition: recognition
                )
            )
        case .proxyGroups:
            proxyGroupCount += 1
            guard groups.count < ProfileConfigurationInspector.maximumDisplayedItemsPerSection else {
                return
            }
            let groupIndex = groups.count
            if item.includeAll || item.filterPattern != nil || item.excludeFilterPattern != nil {
                deferredGroupFilters.append(
                    GroupFilterSpec(
                        groupIndex: groupIndex,
                        includeAll: item.includeAll,
                        filterPattern: item.filterPattern,
                        excludeFilterPattern: item.excludeFilterPattern,
                        explicitMembers: item.members
                    )
                )
            }
            groups.append(
                ProxyGroupConfigurationSummary(
                    id: groupIndex,
                    name: item.name.isEmpty ? "Unnamed group" : item.name,
                    strategy: item.type.isEmpty ? "Unknown" : item.type,
                    memberCount: item.members.count,
                    members: Array(
                        item.members.prefix(
                            ProfileConfigurationInspector
                                .maximumDisplayedItemsPerSection
                        )
                    )
                )
            )
        default:
            break
        }
    }

    private mutating func resolveDeferredGroupFilters() {
        guard !deferredGroupFilters.isEmpty else { return }
        for spec in deferredGroupFilters {
            guard spec.groupIndex < groups.count else { continue }
            var candidates: [String] = spec.explicitMembers
            if spec.includeAll || candidates.isEmpty {
                for proxyName in allProxyNames where !candidates.contains(proxyName) {
                    candidates.append(proxyName)
                }
            }
            if let pattern = spec.filterPattern,
               let regex = try? NSRegularExpression(pattern: pattern, options: []) {
                let explicitSet = Set(spec.explicitMembers)
                candidates = candidates.filter { name in
                    if explicitSet.contains(name) && spec.includeAll {
                        return true
                    }
                    let range = NSRange(name.startIndex..<name.endIndex, in: name)
                    return regex.firstMatch(in: name, options: [], range: range) != nil
                }
            }
            if let excludePattern = spec.excludeFilterPattern,
               let excludeRegex = try? NSRegularExpression(pattern: excludePattern, options: []) {
                let explicitSet = Set(spec.explicitMembers)
                candidates = candidates.filter { name in
                    if explicitSet.contains(name) && spec.includeAll {
                        return true
                    }
                    let range = NSRange(name.startIndex..<name.endIndex, in: name)
                    return excludeRegex.firstMatch(in: name, options: [], range: range) == nil
                }
            }
            let existing = groups[spec.groupIndex]
            groups[spec.groupIndex] = ProxyGroupConfigurationSummary(
                id: existing.id,
                name: existing.name,
                strategy: existing.strategy,
                memberCount: candidates.count,
                members: Array(
                    candidates.prefix(
                        ProfileConfigurationInspector.maximumDisplayedItemsPerSection
                    )
                )
            )
        }
        deferredGroupFilters.removeAll()
    }

    private mutating func parseProvider(line: String, indent: Int) {
        guard !line.hasPrefix("-"), let (key, value) = Self.keyValue(in: line) else {
            return
        }
        if providerIndent == nil { providerIndent = indent }
        if indent == providerIndent {
            finishPendingProvider()
            provider = Item(name: Self.scalar(key))
            providerFieldIndent = nil
            if value.hasPrefix("{") && value.hasSuffix("}") {
                for field in Self.splitTopLevel(
                    String(value.dropFirst().dropLast()),
                    separator: ","
                ) {
                    if let (fieldKey, fieldValue) = Self.keyValue(in: field),
                       fieldKey.lowercased() == "type" {
                        provider?.type = Self.scalar(fieldValue)
                    }
                }
            }
        } else if indent > (providerIndent ?? -1) {
            if providerFieldIndent == nil { providerFieldIndent = indent }
            if indent == providerFieldIndent, key.lowercased() == "type" {
                provider?.type = Self.scalar(value)
            }
        }
    }

    private mutating func finishPendingProvider() {
        guard let provider, let section else {
            self.provider = nil
            return
        }
        defer { self.provider = nil }

        let destination: WritableKeyPath<Parser, [ProviderConfigurationSummary]>
        switch section {
        case .proxyProviders:
            proxyProviderCount += 1
            destination = \.proxyProviders
        case .ruleProviders:
            ruleProviderCount += 1
            destination = \.ruleProviders
        default: return
        }
        guard self[keyPath: destination].count
                < ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        else { return }
        let index = self[keyPath: destination].count
        self[keyPath: destination].append(
            ProviderConfigurationSummary(
                id: index,
                name: provider.name.isEmpty ? "Unnamed provider" : provider.name,
                sourceType: provider.type.isEmpty ? "Unknown" : provider.type
            )
        )
    }

    private mutating func parseRule(line: String, indent: Int) {
        guard line.hasPrefix("-") else { return }
        var quote: Character?
        let value = Self.removingComment(
            from: String(line.dropFirst()), quote: &quote
        ).trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else { return }
        pendingRule = PendingRule(indent: indent, value: value, quote: quote)
    }

    private mutating func finishPendingRule() {
        guard let pending = pendingRule else { return }
        pendingRule = nil
        appendRule(pending.value)
    }

    private mutating func parseHostsLine(line: String, indent: Int) {
        guard !line.hasPrefix("-"), let (key, rawTarget) = Self.keyValue(in: line) else { return }
        let k = key.trimmingCharacters(in: .whitespaces).lowercased()
        let rawVal = Self.scalar(rawTarget).trimmingCharacters(in: .whitespaces)
        let v: String
        if rawVal.hasPrefix("["), rawVal.hasSuffix("]") {
            v = Self.splitFlowSequence(rawVal).first ?? ""
        } else {
            v = rawVal
        }
        guard !k.isEmpty, !v.isEmpty else { return }
        hosts[k] = v
    }

    /// "Claude" for `com.anthropic.claudefordesktop;/Applications/Claude.app`.
    static func applicationName(_ payload: String) -> String {
        guard let separator = payload.firstIndex(of: ";") else { return payload }
        let identifier = String(payload[..<separator])
        let path = String(payload[payload.index(after: separator)...])
            .removingPercentEncoding ?? ""
        if !path.isEmpty {
            let name = (path as NSString).lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        }
        return identifier.isEmpty ? payload : identifier
    }

    private mutating func appendRule(_ rawValue: String) {
        let value = Self.scalar(rawValue)
        let fields = Self.splitTopLevel(value, separator: ",").map(Self.scalar)
        guard let kind = fields.first, !kind.isEmpty else { return }
        recordResourceRequirements(kind: kind, rawValue: rawValue)
        ruleCount += 1
        compatibility.record(ruleKind: kind)
        let hasNoResolve = fields.count >= 3
            && fields.last?.lowercased() == "no-resolve"
        let targetIndex = fields.count > 1
            ? fields.count - (hasNoResolve ? 2 : 1)
            : nil
        let target = targetIndex.map { fields[$0] } ?? "Unknown"
        switch target.uppercased() {
        case "DIRECT":
            directRuleCount += 1
        case "REJECT", "REJECT-DROP":
            rejectRuleCount += 1
        default:
            proxyRuleCount += 1
        }
        guard allRules.count < ProfileConfigurationInspector.maximumEvaluatedRules else {
            return
        }
        let criteriaFields = targetIndex.map { fields[1..<$0] } ?? []
        let criteria = criteriaFields.isEmpty ? nil : criteriaFields.joined(separator: ", ")
        let order = allRules.count + 1
        let compactValue = value.filter { !$0.isWhitespace }.uppercased()
        let synthesizedKey = [kind, criteria ?? "", target].filter { !$0.isEmpty }.joined(separator: ",").filter { !$0.isWhitespace }.uppercased()
        let isCustom = customRuleSignatures.contains(compactValue) || customRuleSignatures.contains(synthesizedKey)
        let ruleSummary = RuleConfigurationSummary(
            id: allRules.count,
            order: order,
            kind: kind,
            criteria: kind.uppercased() == "AETHER-APP"
                ? criteria.map(Self.applicationName) : criteria,
            target: target,
            isCustom: isCustom,
            noResolve: hasNoResolve
        )
        allRules.append(ruleSummary)
        if rules.count < ProfileConfigurationInspector.maximumDisplayedItemsPerSection {
            rules.append(ruleSummary)
        }
    }

    private mutating func recordResourceRequirements(
        kind: String,
        rawValue: String
    ) {
        let normalizedKind = kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let compactRule = rawValue
            .filter { !$0.isWhitespace }
            .uppercased()
        if normalizedKind == "GEOIP" || compactRule.contains("(GEOIP,") {
            requiresCountryMMDB = true
        }
        if normalizedKind == "GEOSITE" || compactRule.contains("(GEOSITE,") {
            requiresGeoSiteDatabase = true
        }
    }

    /// Node keys that decide whether the engine can use a node.
    static let compatibilityKeys: Set<String> = [
        "network", "plugin", "encryption", "smux",
    ]

    private mutating func recordCompatibilityField(_ key: String, value: String) {
        let scalar = Self.scalar(value)
        switch key {
        case "network": item?.network = scalar.lowercased()
        case "plugin": item?.plugin = scalar.lowercased()
        case "encryption": item?.encryption = Self.unquoted(value)
        case "smux":
            // A block mapping arrives empty here; nodes carry `smux` only to
            // turn it on, so treat that as enabled.
            let compact = value.lowercased().filter { !$0.isWhitespace }
            item?.smux = !compact.contains("enabled:false")
        default: break
        }
    }

    /// The type names match the engine exactly: it has no aliases such as
    /// `hy2` or `shadowsocks` for `type`.
    private static func recognition(of item: Item) -> ProxyConfigurationSummary.Recognition {
        guard !item.name.isEmpty, !item.type.isEmpty else { return .incomplete }
        let type = item.type.lowercased()
        guard EngineCapabilities.outboundTypes.contains(type) else {
            return .unsupported(.protocolType(type))
        }
        if let networks = EngineCapabilities.networks[type],
           !item.network.isEmpty,
           !networks.contains(item.network) {
            return .unsupported(.network(item.network))
        }
        if type == "ss", !item.plugin.isEmpty,
           !EngineCapabilities.shadowsocksPlugins.contains(item.plugin) {
            return .unsupported(.plugin(item.plugin))
        }
        if type == "vless", !Self.isSupportedVlessEncryption(item.encryption) {
            return .unsupported(.option("encryption"))
        }
        return .recognized
    }

    private static func isSupportedVlessEncryption(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.lowercased() == "none" {
            return true
        }
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 4,
              parts[0] == "mlkem768x25519plus",
              ["native", "xorpub", "random"].contains(parts[1]),
              ["1rtt", "0rtt"].contains(parts[2])
        else {
            return false
        }
        var keyTokens: [String] = []
        var paddingIndex = 0
        var maxPaddingLen = 0
        for token in parts.dropFirst(3) {
            let dashParts = token.split(separator: "-", omittingEmptySubsequences: false)
            if keyTokens.isEmpty,
               dashParts.count == 3,
               let prob = Int(dashParts[0]),
               let minVal = Int(dashParts[1]),
               let maxVal = Int(dashParts[2]),
               prob >= 0, minVal >= 0, maxVal >= minVal
            {
                if paddingIndex == 0 && (prob < 100 || minVal < 35 || maxVal < 35) {
                    return false
                }
                if paddingIndex.isMultiple(of: 2) {
                    maxPaddingLen += max(minVal, maxVal)
                }
                paddingIndex += 1
                continue
            }
            keyTokens.append(token)
        }
        guard !keyTokens.isEmpty, maxPaddingLen <= 18 + 65535 else {
            return false
        }
        for token in keyTokens {
            guard let decoded = decodeBase64URL(token),
                  decoded.count == 32 || decoded.count == 1184
            else {
                return false
            }
        }
        return true
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        guard !value.isEmpty, !value.contains("="),
              !value.contains("+"), !value.contains("/")
        else {
            return nil
        }
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder == 1 {
            return nil
        } else if remainder > 1 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func leadingSpaceCount(in line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    private static func keyValue(in value: String) -> (String, String)? {
        let characters = Array(value)
        var quote: Character?
        var escaped = false
        var squareDepth = 0
        var braceDepth = 0
        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "[" { squareDepth += 1 }
            if character == "]" { squareDepth = max(0, squareDepth - 1) }
            if character == "{" { braceDepth += 1 }
            if character == "}" { braceDepth = max(0, braceDepth - 1) }
            if character == ":", squareDepth == 0, braceDepth == 0 {
                let key = String(characters[..<index])
                    .trimmingCharacters(in: .whitespaces)
                let next = characters.index(after: index)
                let content = String(characters[next...])
                    .trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (scalar(key), content)
            }
        }
        return nil
    }

    private static func splitFlowSequence(_ value: String) -> [String] {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            let scalar = scalar(trimmed)
            return scalar.isEmpty ? [] : [scalar]
        }
        return splitTopLevel(String(trimmed.dropFirst().dropLast()), separator: ",")
            .map(scalar)
            .filter { !$0.isEmpty }
    }

    private static func splitTopLevel(_ value: String, separator: Character) -> [String] {
        let characters = Array(value)
        var values: [String] = []
        var start = characters.startIndex
        var quote: Character?
        var escaped = false
        var squareDepth = 0
        var braceDepth = 0

        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "[" { squareDepth += 1 }
            if character == "]" { squareDepth = max(0, squareDepth - 1) }
            if character == "{" { braceDepth += 1 }
            if character == "}" { braceDepth = max(0, braceDepth - 1) }
            if character == separator, squareDepth == 0, braceDepth == 0 {
                values.append(String(characters[start..<index]))
                start = characters.index(after: index)
            }
        }
        values.append(String(characters[start...]))
        return values
    }

    private static func unquoted(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    private static func scalar(_ value: String) -> String {
        String(unquoted(value).prefix(160))
    }

    private static func boolean(_ value: String) -> Bool? {
        switch scalar(value).lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func removingComment(from line: String) -> String {
        var quote: Character?
        return removingComment(from: line, quote: &quote)
    }

    private static func removingComment(
        from line: String,
        quote: inout Character?
    ) -> String {
        let characters = Array(line)
        var escaped = false
        for index in characters.indices {
            let character = characters[index]
            if escaped {
                escaped = false
                continue
            }
            if character == "\\", quote == "\"" {
                escaped = true
                continue
            }
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
                continue
            }
            if character == "\"" || character == "'" {
                quote = character
                continue
            }
            if character == "#" {
                return String(characters[..<index])
            }
        }
        return line
    }
}

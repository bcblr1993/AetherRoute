import Foundation

public struct ProfileConfigurationSummary: Equatable, Sendable {
    public let dns: DNSConfigurationSummary
    public let proxies: [ProxyConfigurationSummary]
    public let proxyGroups: [ProxyGroupConfigurationSummary]
    public let proxyProviders: [ProviderConfigurationSummary]
    public let rules: [RuleConfigurationSummary]
    public let ruleProviders: [ProviderConfigurationSummary]
    public let proxyCount: Int
    public let proxyGroupCount: Int
    public let proxyProviderCount: Int
    public let ruleCount: Int
    public let ruleProviderCount: Int
    public let requiresCountryMMDB: Bool
    public let requiresGeoSiteDatabase: Bool

    public init(
        dns: DNSConfigurationSummary,
        proxies: [ProxyConfigurationSummary],
        proxyGroups: [ProxyGroupConfigurationSummary],
        proxyProviders: [ProviderConfigurationSummary],
        rules: [RuleConfigurationSummary],
        ruleProviders: [ProviderConfigurationSummary],
        proxyCount: Int,
        proxyGroupCount: Int,
        proxyProviderCount: Int,
        ruleCount: Int,
        ruleProviderCount: Int,
        requiresCountryMMDB: Bool = false,
        requiresGeoSiteDatabase: Bool = false
    ) {
        self.dns = dns
        self.proxies = proxies
        self.proxyGroups = proxyGroups
        self.proxyProviders = proxyProviders
        self.rules = rules
        self.ruleProviders = ruleProviders
        self.proxyCount = proxyCount
        self.proxyGroupCount = proxyGroupCount
        self.proxyProviderCount = proxyProviderCount
        self.ruleCount = ruleCount
        self.ruleProviderCount = ruleProviderCount
        self.requiresCountryMMDB = requiresCountryMMDB
        self.requiresGeoSiteDatabase = requiresGeoSiteDatabase
    }
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

    public init(
        id: Int,
        order: Int,
        kind: String,
        criteria: String?,
        target: String
    ) {
        self.id = id
        self.order = order
        self.kind = kind
        self.criteria = criteria
        self.target = target
    }
}

/// Produces a bounded, non-secret UI projection of an already imported profile.
/// The protocol core remains authoritative for semantic validation.
public enum ProfileConfigurationInspector {
    public static let maximumDisplayedItemsPerSection = 500

    public static func inspect(yaml: String) -> ProfileConfigurationSummary {
        var parser = Parser(yaml: yaml)
        return parser.parse()
    }
}

private struct Parser {
    private enum Section: String {
        case dns
        case proxies
        case proxyGroups = "proxy-groups"
        case proxyProviders = "proxy-providers"
        case rules
        case ruleProviders = "rule-providers"
    }

    private struct Item {
        var name = ""
        var type = ""
        var members: [String] = []
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

    private var proxies: [ProxyConfigurationSummary] = []
    private var groups: [ProxyGroupConfigurationSummary] = []
    private var proxyProviders: [ProviderConfigurationSummary] = []
    private var rules: [RuleConfigurationSummary] = []
    private var ruleProviders: [ProviderConfigurationSummary] = []
    private var proxyCount = 0
    private var proxyGroupCount = 0
    private var proxyProviderCount = 0
    private var ruleCount = 0
    private var ruleProviderCount = 0
    private var requiresCountryMMDB = false
    private var requiresGeoSiteDatabase = false

    init(yaml: String) {
        lines = yaml.components(separatedBy: .newlines)
    }

    mutating func parse() -> ProfileConfigurationSummary {
        for rawLine in lines {
            let line = Self.removingComment(from: rawLine)
            guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                continue
            }

            let indent = Self.leadingSpaceCount(in: line)
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if indent == 0,
               !trimmed.hasPrefix("-"),
               let (key, value) = Self.keyValue(in: trimmed) {
                finishPendingItem()
                finishPendingProvider()
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
                parseRule(line: trimmed)
            case nil:
                continue
            }
        }

        finishPendingItem()
        finishPendingProvider()
        return ProfileConfigurationSummary(
            dns: dns.summary,
            proxies: proxies,
            proxyGroups: groups,
            proxyProviders: proxyProviders,
            rules: rules,
            ruleProviders: ruleProviders,
            proxyCount: proxyCount,
            proxyGroupCount: proxyGroupCount,
            proxyProviderCount: proxyProviderCount,
            ruleCount: ruleCount,
            ruleProviderCount: ruleProviderCount,
            requiresCountryMMDB: requiresCountryMMDB,
            requiresGeoSiteDatabase: requiresGeoSiteDatabase
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

        guard indent > rootIndent, let nestedField = dnsNestedField else {
            return
        }
        if line.hasPrefix("-") {
            let value = String(line.dropFirst())
                .trimmingCharacters(in: .whitespaces)
            appendDNSListValue(value, field: nestedField)
            return
        }
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
        case let key where section == .proxyGroups
            && (key == "proxies" || key == "use"):
            readingMembers = value.isEmpty
            if !value.isEmpty {
                item?.members.append(contentsOf: Self.splitFlowSequence(value))
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
            case let key where section == .proxyGroups
                && (key == "proxies" || key == "use"):
                item?.members.append(contentsOf: Self.splitFlowSequence(value))
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
                    recognition: Self.recognition(name: item.name, type: item.type)
                )
            )
        case .proxyGroups:
            proxyGroupCount += 1
            guard groups.count < ProfileConfigurationInspector.maximumDisplayedItemsPerSection else {
                return
            }
            groups.append(
                ProxyGroupConfigurationSummary(
                    id: groups.count,
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

    private mutating func parseRule(line: String) {
        guard line.hasPrefix("-") else { return }
        appendRule(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
    }

    private mutating func appendRule(_ rawValue: String) {
        let value = Self.scalar(rawValue)
        let fields = Self.splitTopLevel(value, separator: ",").map(Self.scalar)
        guard let kind = fields.first, !kind.isEmpty else { return }
        recordResourceRequirements(kind: kind, rawValue: rawValue)
        ruleCount += 1
        guard rules.count < ProfileConfigurationInspector.maximumDisplayedItemsPerSection else {
            return
        }
        let hasNoResolve = fields.count >= 3
            && fields.last?.lowercased() == "no-resolve"
        let targetIndex = fields.count > 1
            ? fields.count - (hasNoResolve ? 2 : 1)
            : nil
        let target = targetIndex.map { fields[$0] } ?? "Unknown"
        let criteriaFields = targetIndex.map { fields[1..<$0] } ?? []
        let criteria = criteriaFields.isEmpty ? nil : criteriaFields.joined(separator: ", ")
        let order = rules.count + 1
        rules.append(
            RuleConfigurationSummary(
                id: rules.count,
                order: order,
                kind: kind,
                criteria: criteria,
                target: target
            )
        )
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

    private static func recognition(
        name: String,
        type: String
    ) -> ProxyConfigurationSummary.Recognition {
        guard !name.isEmpty, !type.isEmpty else { return .incomplete }
        let normalized = type.lowercased().replacingOccurrences(of: "_", with: "-")
        let aliases: Set<String> = [
            "anytls", "direct", "http", "hysteria2", "hy2", "reject",
            "shadowquic", "shadowsocks", "ss", "ssh", "socks", "socks5",
            "trojan", "tuic", "vless", "vmess", "wireguard",
        ]
        return aliases.contains(normalized) ? .recognized : .requiresCoreValidation
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

    private static func scalar(_ value: String) -> String {
        var value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2,
           (value.first == "\"" && value.last == "\"")
            || (value.first == "'" && value.last == "'") {
            value.removeFirst()
            value.removeLast()
        }
        return String(value.prefix(160))
    }

    private static func boolean(_ value: String) -> Bool? {
        switch scalar(value).lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    private static func removingComment(from line: String) -> String {
        let characters = Array(line)
        var quote: Character?
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

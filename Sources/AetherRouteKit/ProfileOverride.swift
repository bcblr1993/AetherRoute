import Darwin
import Foundation

/// Changes the person made to a profile without touching the profile itself
/// (1.7.0). They live with the profile in the encrypted catalog, so they
/// survive subscription updates, travel with exports and iCloud sync, and an
/// older version simply ignores them.
///
/// Deliberately declarative: no scripts and no free-form YAML, the same rule
/// that keeps executable profiles out.
public struct ProfileOverride: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1
    public static let maximumGroupCount = 32
    public static let maximumChainedProxyCount = 32
    public static let maximumCustomHostCount = 64
    public static let maximumKeywordCount = 32
    public static let maximumKeywordLength = 64
    public static let maximumNameLength = 64
    public static let maximumManualNodeCount = 512
    public static let standaloneChainedProxyGroupCandidates = [
        "链式代理",
        "🔗 链式代理",
        "Chained Proxies",
    ]

    public var formatVersion: Int
    /// Groups added to the profile, in the order they appear.
    public var groups: [CustomProxyGroup]
    /// Nodes whose name contains any of these (case-insensitive) are taken
    /// out of every group. The node definitions themselves stay.
    public var hiddenNodeKeywords: [String]
    /// Chained proxies added to the profile, routing through a first-hop
    /// dialer proxy into an exit node.
    public var chainedProxies: [ChainedProxyOverride]
    /// Local host overrides merged into the profile's `hosts` map without
    /// mutating the original subscription text.
    public var customHosts: [CustomHostMapping]
    /// Scenario rule presets (v3.1) prepended to the profile's rules without
    /// mutating the original subscription text.
    public var scenarioPresets: [ScenarioRulePresetState]

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case groups
        case hiddenNodeKeywords
        case chainedProxies
        case customHosts
        case scenarioPresets
    }

    public init(
        groups: [CustomProxyGroup] = [],
        hiddenNodeKeywords: [String] = [],
        chainedProxies: [ChainedProxyOverride] = [],
        customHosts: [CustomHostMapping] = [],
        scenarioPresets: [ScenarioRulePresetState] = []
    ) {
        formatVersion = Self.currentFormatVersion
        self.groups = groups
        self.hiddenNodeKeywords = hiddenNodeKeywords
        self.chainedProxies = chainedProxies
        self.customHosts = customHosts
        self.scenarioPresets = scenarioPresets
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        groups = try container.decode([CustomProxyGroup].self, forKey: .groups)
        hiddenNodeKeywords = try container.decode([String].self, forKey: .hiddenNodeKeywords)
        chainedProxies = try container.decodeIfPresent([ChainedProxyOverride].self, forKey: .chainedProxies) ?? []
        customHosts = try container.decodeIfPresent([CustomHostMapping].self, forKey: .customHosts) ?? []
        scenarioPresets = try container.decodeIfPresent([ScenarioRulePresetState].self, forKey: .scenarioPresets) ?? []
    }

    public var isEmpty: Bool {
        groups.isEmpty
            && hiddenNodeKeywords.isEmpty
            && chainedProxies.isEmpty
            && customHosts.isEmpty
            && scenarioPresets.isEmpty
    }

    public var hasStructuralOverrides: Bool {
        !groups.isEmpty
            || !hiddenNodeKeywords.isEmpty
            || !chainedProxies.isEmpty
            || !customHosts.isEmpty
    }

    /// Trims and bounds every field; throws on what cannot be fixed.
    public func validated() throws -> ProfileOverride {
        guard formatVersion == Self.currentFormatVersion else {
            throw ProfileOverrideError.unsupportedFormat(formatVersion)
        }
        guard groups.count <= Self.maximumGroupCount else {
            throw ProfileOverrideError.tooManyGroups
        }
        guard chainedProxies.count <= Self.maximumChainedProxyCount else {
            throw ProfileOverrideError.tooManyChainedProxies
        }
        guard customHosts.count <= Self.maximumCustomHostCount else {
            throw ProfileOverrideError.tooManyCustomHosts
        }
        var copy = self
        copy.hiddenNodeKeywords = try Self.keywords(hiddenNodeKeywords)
        copy.groups = try groups.map { try $0.validated() }
        copy.chainedProxies = try chainedProxies.map { try $0.validated() }
        copy.customHosts = try customHosts.map { try $0.validated() }
        var seenHostDomains = Set<String>()
        for entry in copy.customHosts {
            guard seenHostDomains.insert(entry.domain).inserted else {
                throw ProfileOverrideError.duplicateCustomHost(entry.domain)
            }
        }
        var seen = Set<String>()
        for group in copy.groups {
            guard seen.insert(group.name).inserted else {
                throw ProfileOverrideError.duplicateGroupName(group.name)
            }
        }
        for chain in copy.chainedProxies {
            guard seen.insert(chain.name).inserted else {
                throw ProfileOverrideError.duplicateGroupName(chain.name)
            }
        }
        let dialerByName = Dictionary(
            uniqueKeysWithValues: copy.chainedProxies.map { ($0.name, $0.dialerProxy) }
        )
        let customParentByName = Dictionary(
            uniqueKeysWithValues: copy.groups.compactMap { group in
                group.parentGroup.map { (group.name, $0) }
            }
        )
        for chain in copy.chainedProxies {
            var forbidden: Set<String> = [chain.name]
            if let parent = chain.parentGroup {
                forbidden.insert(parent)
                if let grandParent = customParentByName[parent] {
                    forbidden.insert(grandParent)
                }
            }
            var visited: Set<String> = [chain.name]
            var cursor: String? = chain.dialerProxy
            while let current = cursor {
                if forbidden.contains(current) || !visited.insert(current).inserted {
                    throw ProfileOverrideError.chainedProxyCycle
                }
                cursor = dialerByName[current]
            }
        }
        return copy
    }

    static func keywords(_ values: [String]) throws -> [String] {
        var result: [String] = []
        for value in values {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !result.contains(trimmed) else { continue }
            guard trimmed.count <= maximumKeywordLength,
                  !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
            else {
                throw ProfileOverrideError.invalidKeyword
            }
            result.append(trimmed)
        }
        guard result.count <= maximumKeywordCount else {
            throw ProfileOverrideError.tooManyKeywords
        }
        return result
    }
}

/// A group whose members are chosen by rules, so they follow the
public enum LoadBalanceStrategy: String, Codable, Equatable, Sendable, CaseIterable {
    case roundRobin = "round-robin"
    case consistentHashing = "consistent-hashing"
    case stickySession = "sticky-session"
}

public enum CustomProxyGroupKind: Codable, Equatable, Sendable, Hashable {
    case select
    case urlTest(interval: Int, tolerance: Int)
    case fallback(interval: Int)
    case loadBalance(strategy: LoadBalanceStrategy)
    case smart

    public static let defaultProbeURL = "https://www.gstatic.com/generate_204"
    public static let defaultIntervalSeconds = 300
    public static let defaultToleranceMilliseconds = 50

    public var clashType: String {
        switch self {
        case .select: "select"
        case .urlTest: "url-test"
        case .fallback: "fallback"
        case .loadBalance: "load-balance"
        case .smart: "smart"
        }
    }

    public func normalized() -> CustomProxyGroupKind {
        switch self {
        case .select, .smart, .loadBalance:
            return self
        case let .urlTest(interval, tolerance):
            return .urlTest(
                interval: min(max(interval, 30), 86_400),
                tolerance: min(max(tolerance, 0), 5_000)
            )
        case let .fallback(interval):
            return .fallback(interval: min(max(interval, 30), 86_400))
        }
    }
}

/// subscription: a new Hong Kong node joins "Hong Kong", a removed one
/// leaves.
public struct CustomProxyGroup: Codable, Equatable, Sendable, Identifiable {
    public enum Position: String, Codable, Sendable {
        case top
        case bottom
    }

    public var id: UUID
    public var name: String
    /// Region codes as `NodeRegion` reports them (`HK`, `JP`, …).
    public var regions: [String]
    /// A node whose name contains any of these joins.
    public var includeKeywords: [String]
    /// A node whose name contains any of these never joins.
    public var excludeKeywords: [String]
    /// Nodes picked by hand; they join while the profile still has them.
    public var manualNodes: [String]
    /// How the group picks its node; legacy field retained for backward compatibility.
    public var mode: ProxySelectionMode
    /// Engine-native Clash proxy group type and strategy parameters.
    public var groupKind: CustomProxyGroupKind
    /// An existing group that lists this one, so it can be chosen there.
    public var parentGroup: String?
    public var position: Position

    enum CodingKeys: String, CodingKey {
        case id, name, regions, includeKeywords, excludeKeywords, manualNodes, mode, groupKind, parentGroup, position
    }

    public init(
        id: UUID = UUID(),
        name: String,
        regions: [String] = [],
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        manualNodes: [String] = [],
        mode: ProxySelectionMode = .fastest,
        groupKind: CustomProxyGroupKind = .select,
        parentGroup: String? = nil,
        position: Position = .top
    ) {
        self.id = id
        self.name = name
        self.regions = regions
        self.includeKeywords = includeKeywords
        self.excludeKeywords = excludeKeywords
        self.manualNodes = manualNodes
        self.mode = mode
        self.groupKind = groupKind
        self.parentGroup = parentGroup
        self.position = position
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.regions = try container.decodeIfPresent([String].self, forKey: .regions) ?? []
        self.includeKeywords = try container.decodeIfPresent([String].self, forKey: .includeKeywords) ?? []
        self.excludeKeywords = try container.decodeIfPresent([String].self, forKey: .excludeKeywords) ?? []
        self.manualNodes = try container.decodeIfPresent([String].self, forKey: .manualNodes) ?? []
        self.mode = try container.decodeIfPresent(ProxySelectionMode.self, forKey: .mode) ?? .fastest
        self.groupKind = try container.decodeIfPresent(CustomProxyGroupKind.self, forKey: .groupKind) ?? .select
        self.parentGroup = try container.decodeIfPresent(String.self, forKey: .parentGroup)
        self.position = try container.decodeIfPresent(Position.self, forKey: .position) ?? .top
    }

    /// Whether anything can select a node at all.
    public var hasSource: Bool {
        !regions.isEmpty || !includeKeywords.isEmpty || !manualNodes.isEmpty
    }

    public func validated() throws -> CustomProxyGroup {
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty,
              copy.name.count <= ProfileOverride.maximumNameLength,
              !copy.name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              // Quotes and backslashes would need escapes that the app's own
              // profile reader does not decode; keep names plain.
              !copy.name.contains(where: { "\"'\\".contains($0) }),
              !["DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL"]
                .contains(copy.name.uppercased())
        else {
            throw ProfileOverrideError.invalidGroupName
        }
        copy.regions = Array(Set(regions.map { $0.uppercased() }.filter {
            $0.count == 2 && $0.allSatisfy(\.isLetter)
        })).sorted()
        copy.includeKeywords = try ProfileOverride.keywords(includeKeywords)
        copy.excludeKeywords = try ProfileOverride.keywords(excludeKeywords)
        var manual: [String] = []
        for node in manualNodes where !node.isEmpty && !manual.contains(node) {
            manual.append(node)
        }
        guard manual.count <= ProfileOverride.maximumManualNodeCount else {
            throw ProfileOverrideError.tooManyNodes
        }
        copy.manualNodes = manual
        guard copy.hasSource else { throw ProfileOverrideError.groupHasNoSource }
        copy.groupKind = copy.groupKind.normalized()
        copy.parentGroup = parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.parentGroup?.isEmpty == true { copy.parentGroup = nil }
        return copy
    }

    /// Whether a node with this name belongs, by the group's rules. Names
    /// are matched case-insensitively; a region must be named clearly
    /// (`NodeRegion`), never guessed.
    public func matches(_ node: String) -> Bool {
        let lowered = node.lowercased()
        if excludeKeywords.contains(where: { lowered.contains($0.lowercased()) }) {
            return false
        }
        if manualNodes.contains(node) { return true }
        if includeKeywords.contains(where: { lowered.contains($0.lowercased()) }) {
            return true
        }
        if !regions.isEmpty, let region = NodeRegion.resolve(from: node) {
            return regions.contains(region.code)
        }
        return false
    }
}

/// A chained proxy that routes traffic through `dialerProxy` (first-hop entry
/// node or proxy group) into `target` (second-hop landing node).
public struct ChainedProxyOverride: Codable, Equatable, Sendable, Identifiable {
    public enum Target: Codable, Equatable, Sendable {
        case customNode(AetherNode)
        case existingNode(name: String)
    }

    public var id: UUID
    public var name: String
    public var dialerProxy: String
    public var target: Target
    public var parentGroup: String?
    public var position: CustomProxyGroup.Position

    public init(
        id: UUID = UUID(),
        name: String,
        dialerProxy: String,
        target: Target,
        parentGroup: String? = nil,
        position: CustomProxyGroup.Position = .top
    ) {
        self.id = id
        self.name = name
        self.dialerProxy = dialerProxy
        self.target = target
        self.parentGroup = parentGroup
        self.position = position
    }

    public func validated() throws -> ChainedProxyOverride {
        let reserved: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "PASS", "GLOBAL"]
        var copy = self
        copy.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.name.isEmpty,
              copy.name.count <= ProfileOverride.maximumNameLength,
              !copy.name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !copy.name.contains(where: { "\"'\\".contains($0) }),
              !reserved.contains(copy.name.uppercased())
        else {
            throw ProfileOverrideError.invalidGroupName
        }

        copy.dialerProxy = dialerProxy.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.dialerProxy.isEmpty,
              copy.dialerProxy.count <= ProfileOverride.maximumNameLength,
              !copy.dialerProxy.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !copy.dialerProxy.contains(where: { "\"'\\".contains($0) }),
              copy.dialerProxy != copy.name,
              !reserved.contains(copy.dialerProxy.uppercased())
        else {
            throw ProfileOverrideError.invalidChainedProxy
        }

        copy.parentGroup = parentGroup?.trimmingCharacters(in: .whitespacesAndNewlines)
        if copy.parentGroup?.isEmpty == true { copy.parentGroup = nil }
        if let parent = copy.parentGroup, parent == copy.dialerProxy {
            throw ProfileOverrideError.chainedProxyCycle
        }

        switch target {
        case var .customNode(node):
            node.name = copy.name
            node.dialerProxy = copy.dialerProxy
            do {
                node = try node.validated()
            } catch {
                throw ProfileOverrideError.invalidChainedProxy
            }
            copy.target = .customNode(node)
        case let .existingNode(rawTarget):
            let trimmedTarget = rawTarget.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedTarget.isEmpty,
                  trimmedTarget.utf8.count <= 256,
                  !trimmedTarget.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
                  trimmedTarget != copy.name,
                  trimmedTarget != copy.dialerProxy,
                  !reserved.contains(trimmedTarget.uppercased())
            else {
                throw ProfileOverrideError.invalidChainedProxy
            }
            copy.target = .existingNode(name: trimmedTarget)
        }
        return copy
    }
}

/// A local host mapping (`domain` → `ip`) merged into the profile's top-level
/// `hosts` table when enabled. Supports exact domains (`nas.home.lan`),
/// single-label wildcards (`*.dev.internal`), and domain-suffix wildcards
/// (`+.corp.example`).
public struct CustomHostMapping: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var domain: String
    public var ip: String
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        domain: String,
        ip: String,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.domain = domain
        self.ip = ip
        self.isEnabled = isEnabled
    }

    public func validated() throws -> CustomHostMapping {
        var copy = self
        copy.domain = domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        copy.ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidDomainPattern(copy.domain),
              Self.isValidIPAddressLiteral(copy.ip)
        else {
            throw ProfileOverrideError.invalidCustomHost
        }
        return copy
    }

    private static func isValidDomainPattern(_ pattern: String) -> Bool {
        guard !pattern.isEmpty,
              pattern.count <= 253,
              !pattern.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }),
              !pattern.contains(where: { $0.isWhitespace || "\"'\\:#[]{}".contains($0) })
        else {
            return false
        }
        let body: Substring
        if pattern.hasPrefix("*.") || pattern.hasPrefix("+.") {
            body = pattern.dropFirst(2)
        } else {
            body = pattern[...]
        }
        guard !body.isEmpty, !body.hasPrefix("."), !body.hasSuffix(".") else {
            return false
        }
        let labels = body.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty,
                  label.count <= 63,
                  !label.hasPrefix("-"),
                  !label.hasSuffix("-"),
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
            else {
                return false
            }
        }
        return true
    }

    private static func isValidIPAddressLiteral(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 64 else { return false }
        var addr4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            return true
        }
        var addr6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            return true
        }
        return false
    }
}

public enum ProfileOverrideError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(Int)
    case tooManyGroups
    case tooManyChainedProxies
    case tooManyCustomHosts
    case tooManyKeywords
    case tooManyNodes
    case invalidKeyword
    case invalidGroupName
    case invalidChainedProxy
    case invalidCustomHost
    case chainedProxyCycle
    case duplicateGroupName(String)
    case duplicateCustomHost(String)
    case groupHasNoSource

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(version):
            "The profile customization format \(version) is not supported."
        case .tooManyGroups:
            "A profile can have at most \(ProfileOverride.maximumGroupCount) custom groups."
        case .tooManyChainedProxies:
            "A profile can have at most \(ProfileOverride.maximumChainedProxyCount) chained proxies."
        case .tooManyCustomHosts:
            "A profile can have at most \(ProfileOverride.maximumCustomHostCount) custom host mappings."
        case .tooManyKeywords:
            "Use at most \(ProfileOverride.maximumKeywordCount) keywords."
        case .tooManyNodes:
            "Pick at most \(ProfileOverride.maximumManualNodeCount) nodes."
        case .invalidKeyword:
            "A keyword is too long or contains control characters."
        case .invalidGroupName:
            "Enter a group name of up to \(ProfileOverride.maximumNameLength) characters that is not a built-in outlet."
        case .invalidChainedProxy:
            "Choose a valid first-hop dialer proxy and landing node."
        case .invalidCustomHost:
            "Enter a valid domain pattern (e.g. nas.local, *.dev.internal, +.corp.example) and IPv4/IPv6 address."
        case .chainedProxyCycle:
            "A chained proxy cannot route through itself or through the group that lists it."
        case let .duplicateGroupName(name):
            "Two custom groups are named \(name)."
        case let .duplicateCustomHost(domain):
            "Two custom host mappings use \(domain)."
        case .groupHasNoSource:
            "Choose regions, keywords or nodes for the group."
        }
    }
}

/// Persists global override templates applied across profiles before per-profile overrides.
public final class ProfileOverrideStore: @unchecked Sendable {
    private struct StoragePayload: Codable {
        static let currentVersion = 1
        var version: Int = StoragePayload.currentVersion
        var globalOverride: ProfileOverride
    }

    public static func applicationGroup(fileManager: FileManager = .default) -> ProfileOverrideStore {
        let baseURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)?
            .appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent("AetherRoute", isDirectory: true)
        return ProfileOverrideStore(fileManager: fileManager, directoryURL: baseURL)
    }

    public let directoryURL: URL
    private let fileManager: FileManager

    public init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        if let directoryURL {
            self.directoryURL = directoryURL
        } else if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup) {
            self.directoryURL = container.appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true)
        } else {
            self.directoryURL = fileManager.temporaryDirectory.appendingPathComponent("AetherRoute", isDirectory: true)
        }
    }

    public var fileURL: URL {
        directoryURL.appendingPathComponent("overrides.json", isDirectory: false)
    }

    public var globalOverride: ProfileOverride {
        loadGlobalOverride()
    }

    public func loadGlobalOverride() -> ProfileOverride {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoragePayload.self, from: data) else {
            return ProfileOverride()
        }
        return decoded.globalOverride
    }

    public func saveGlobalOverride(_ override: ProfileOverride) throws {
        let validated = try override.validated()
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let payload = StoragePayload(globalOverride: validated)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(payload)
        try data.write(to: fileURL, options: [.atomic])
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var mutableURL = fileURL
        try? mutableURL.setResourceValues(resourceValues)
    }
}

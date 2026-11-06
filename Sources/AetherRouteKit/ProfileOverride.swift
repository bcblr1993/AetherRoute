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

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case groups
        case hiddenNodeKeywords
        case chainedProxies
    }

    public init(
        groups: [CustomProxyGroup] = [],
        hiddenNodeKeywords: [String] = [],
        chainedProxies: [ChainedProxyOverride] = []
    ) {
        formatVersion = Self.currentFormatVersion
        self.groups = groups
        self.hiddenNodeKeywords = hiddenNodeKeywords
        self.chainedProxies = chainedProxies
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = try container.decode(Int.self, forKey: .formatVersion)
        groups = try container.decode([CustomProxyGroup].self, forKey: .groups)
        hiddenNodeKeywords = try container.decode([String].self, forKey: .hiddenNodeKeywords)
        chainedProxies = try container.decodeIfPresent([ChainedProxyOverride].self, forKey: .chainedProxies) ?? []
    }

    public var isEmpty: Bool {
        groups.isEmpty && hiddenNodeKeywords.isEmpty && chainedProxies.isEmpty
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
        var copy = self
        copy.hiddenNodeKeywords = try Self.keywords(hiddenNodeKeywords)
        copy.groups = try groups.map { try $0.validated() }
        copy.chainedProxies = try chainedProxies.map { try $0.validated() }
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
    /// How the group picks its node; a custom group is a `select` group.
    public var mode: ProxySelectionMode
    /// An existing group that lists this one, so it can be chosen there.
    public var parentGroup: String?
    public var position: Position

    public init(
        id: UUID = UUID(),
        name: String,
        regions: [String] = [],
        includeKeywords: [String] = [],
        excludeKeywords: [String] = [],
        manualNodes: [String] = [],
        mode: ProxySelectionMode = .fastest,
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
        self.parentGroup = parentGroup
        self.position = position
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

public enum ProfileOverrideError: LocalizedError, Equatable, Sendable {
    case unsupportedFormat(Int)
    case tooManyGroups
    case tooManyChainedProxies
    case tooManyKeywords
    case tooManyNodes
    case invalidKeyword
    case invalidGroupName
    case invalidChainedProxy
    case chainedProxyCycle
    case duplicateGroupName(String)
    case groupHasNoSource

    public var errorDescription: String? {
        switch self {
        case let .unsupportedFormat(version):
            "The profile customization format \(version) is not supported."
        case .tooManyGroups:
            "A profile can have at most \(ProfileOverride.maximumGroupCount) custom groups."
        case .tooManyChainedProxies:
            "A profile can have at most \(ProfileOverride.maximumChainedProxyCount) chained proxies."
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
        case .chainedProxyCycle:
            "A chained proxy cannot route through itself or through the group that lists it."
        case let .duplicateGroupName(name):
            "Two custom groups are named \(name)."
        case .groupHasNoSource:
            "Choose regions, keywords or nodes for the group."
        }
    }
}

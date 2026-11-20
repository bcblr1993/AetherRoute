import Foundation

/// Built-in offline scenario rule preset identifiers (v3.1).
///
/// Every preset references only bundled `GeoSite.dat` categories, built-in
/// `GEOIP` matchers, and static `DOMAIN-SUFFIX` entries—zero remote downloads.
public enum ScenarioRulePresetID: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case aiDeveloperSuite
    case developerAccelerator
    case adAndTrackerBlock
    case domesticAndLANBoost

    public var id: String { rawValue }

    public var defaultTarget: ScenarioRulePresetTarget {
        switch self {
        case .aiDeveloperSuite, .developerAccelerator:
            .primaryProxy
        case .adAndTrackerBlock:
            .reject
        case .domesticAndLANBoost:
            .direct
        }
    }

    public var definition: ScenarioRulePresetDefinition {
        ScenarioRulePresetDefinition.definition(for: self)
    }
}

/// Target policy for a scenario rule preset.
public enum ScenarioRulePresetTarget: Equatable, Hashable, Codable, Sendable {
    /// Dynamically binds to the active profile's primary proxy group (falling
    /// back to the first proxy node or `DIRECT` if the profile defines none).
    case primaryProxy
    case direct
    case reject
    /// Explicit policy group or proxy name from the active profile.
    case group(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case groupName
    }

    private enum StorageKind: String, Codable {
        case primaryProxy
        case direct
        case reject
        case group
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(StorageKind.self, forKey: .kind)
        switch kind {
        case .primaryProxy:
            self = .primaryProxy
        case .direct:
            self = .direct
        case .reject:
            self = .reject
        case .group:
            let name = try container.decode(String.self, forKey: .groupName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if name.isEmpty {
                self = .primaryProxy
            } else {
                self = .group(name)
            }
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .primaryProxy:
            try container.encode(StorageKind.primaryProxy, forKey: .kind)
        case .direct:
            try container.encode(StorageKind.direct, forKey: .kind)
        case .reject:
            try container.encode(StorageKind.reject, forKey: .kind)
        case let .group(name):
            try container.encode(StorageKind.group, forKey: .kind)
            try container.encode(name.trimmingCharacters(in: .whitespacesAndNewlines), forKey: .groupName)
        }
    }

    /// Resolves this target against the active profile's proxy groups and nodes.
    /// When a chosen group no longer exists in the active profile, falls back
    /// gracefully to `fallbackDefault`.
    public func resolvedTarget(
        availableGroups: [String],
        availableProxies: [String] = [],
        fallbackDefault: ScenarioRulePresetTarget
    ) -> String {
        let primaryProxy = Self.primaryProxyName(
            availableGroups: availableGroups,
            availableProxies: availableProxies
        )
        switch self {
        case .primaryProxy:
            return primaryProxy
        case .direct:
            return "DIRECT"
        case .reject:
            return "REJECT"
        case let .group(rawName):
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let upper = trimmed.uppercased()
            if upper == "DIRECT" { return "DIRECT" }
            if upper == "REJECT" || upper == "REJECT-DROP" { return upper }
            if !trimmed.isEmpty,
               availableGroups.contains(trimmed) || availableProxies.contains(trimmed) {
                return trimmed
            }
            switch fallbackDefault {
            case .primaryProxy, .group:
                return primaryProxy
            case .direct:
                return "DIRECT"
            case .reject:
                return "REJECT"
            }
        }
    }

    /// The active profile's primary proxy group (first non-DIRECT/REJECT group),
    /// or first proxy node, or `"DIRECT"` if none exist.
    public static func primaryProxyName(
        availableGroups: [String],
        availableProxies: [String] = []
    ) -> String {
        if let firstGroup = availableGroups.first(where: { group in
            let upper = group.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return !upper.isEmpty && upper != "DIRECT" && upper != "REJECT" && upper != "REJECT-DROP"
        }) {
            return firstGroup
        }
        if let firstProxy = availableProxies.first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
            return firstProxy
        }
        return "DIRECT"
    }
}

/// Single rule template inside a built-in scenario preset.
public struct ScenarioRuleTemplate: Equatable, Hashable, Sendable {
    public let kind: String
    public let value: String
    public let noResolve: Bool

    public init(kind: String, value: String, noResolve: Bool = false) {
        self.kind = kind
        self.value = value
        self.noResolve = noResolve
    }

    public func clashRule(target: String) -> String {
        if noResolve {
            return "\(kind),\(value),\(target),no-resolve"
        }
        return "\(kind),\(value),\(target)"
    }
}

/// Static definition of a built-in scenario rule preset.
public struct ScenarioRulePresetDefinition: Identifiable, Equatable, Sendable {
    public let id: ScenarioRulePresetID
    public let defaultTarget: ScenarioRulePresetTarget
    public let templates: [ScenarioRuleTemplate]

    public init(
        id: ScenarioRulePresetID,
        defaultTarget: ScenarioRulePresetTarget,
        templates: [ScenarioRuleTemplate]
    ) {
        self.id = id
        self.defaultTarget = defaultTarget
        self.templates = templates
    }

    /// All `GEOSITE` category codes referenced by this preset.
    public var geoSiteCategories: [String] {
        templates
            .filter { $0.kind.uppercased() == "GEOSITE" }
            .map { GeoSiteCategoryIndex.categoryCode(of: $0.value) }
    }

    public static let all: [ScenarioRulePresetDefinition] = [
        ScenarioRulePresetDefinition(
            id: .aiDeveloperSuite,
            defaultTarget: .primaryProxy,
            templates: [
                ScenarioRuleTemplate(kind: "GEOSITE", value: "openai"),
                ScenarioRuleTemplate(kind: "GEOSITE", value: "anthropic"),
                ScenarioRuleTemplate(kind: "GEOSITE", value: "google-gemini"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "cursor.sh"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "cursor.com"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "perplexity.ai"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "claude.ai"),
            ]
        ),
        ScenarioRulePresetDefinition(
            id: .developerAccelerator,
            defaultTarget: .primaryProxy,
            templates: [
                ScenarioRuleTemplate(kind: "GEOSITE", value: "github"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "docker.io"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "ghcr.io"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "npmjs.org"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "pypi.org"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "crates.io"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "brew.sh"),
            ]
        ),
        ScenarioRulePresetDefinition(
            id: .adAndTrackerBlock,
            defaultTarget: .reject,
            templates: [
                ScenarioRuleTemplate(kind: "GEOSITE", value: "category-ads-all"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "doubleclick.net"),
                ScenarioRuleTemplate(kind: "DOMAIN-SUFFIX", value: "googlesyndication.com"),
            ]
        ),
        ScenarioRulePresetDefinition(
            id: .domesticAndLANBoost,
            defaultTarget: .direct,
            templates: [
                ScenarioRuleTemplate(kind: "GEOSITE", value: "cn"),
                ScenarioRuleTemplate(kind: "GEOIP", value: "private", noResolve: true),
                ScenarioRuleTemplate(kind: "GEOIP", value: "cn", noResolve: true),
            ]
        ),
    ]

    public static func definition(for id: ScenarioRulePresetID) -> ScenarioRulePresetDefinition {
        all.first { $0.id == id }!
    }
}

/// Persisted user state for one scenario rule preset.
public struct ScenarioRulePresetState: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: ScenarioRulePresetID
    public var isEnabled: Bool
    public var target: ScenarioRulePresetTarget

    public init(
        id: ScenarioRulePresetID,
        isEnabled: Bool = false,
        target: ScenarioRulePresetTarget? = nil
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.target = target ?? id.defaultTarget
    }

    /// Fresh-install defaults: all 4 presets OFF with their recommended target.
    public static func defaultStates() -> [ScenarioRulePresetState] {
        ScenarioRulePresetID.allCases.map { id in
            ScenarioRulePresetState(id: id, isEnabled: false, target: id.defaultTarget)
        }
    }

    /// Normalizes a partial or unsorted array into canonical `ScenarioRulePresetID.allCases` order.
    public static func normalized(_ states: [ScenarioRulePresetState]) -> [ScenarioRulePresetState] {
        var byID: [ScenarioRulePresetID: ScenarioRulePresetState] = [:]
        for state in states {
            byID[state.id] = state
        }
        return ScenarioRulePresetID.allCases.map { id in
            byID[id] ?? ScenarioRulePresetState(id: id, isEnabled: false, target: id.defaultTarget)
        }
    }
}

/// Compiles enabled scenario rule presets into deterministic, deduplicated Clash rule lines.
public enum ScenarioRulePresetCompiler {
    /// Emits Clash rule lines for all enabled presets in canonical order.
    public static func compileRules(
        states: [ScenarioRulePresetState],
        availableGroups: [String],
        availableProxies: [String] = []
    ) -> [String] {
        let stateByID = Dictionary(
            states.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var emitted: [String] = []
        var seen = Set<String>()

        for definition in ScenarioRulePresetDefinition.all {
            guard let state = stateByID[definition.id], state.isEnabled else {
                continue
            }
            let resolvedTarget = state.target.resolvedTarget(
                availableGroups: availableGroups,
                availableProxies: availableProxies,
                fallbackDefault: definition.defaultTarget
            )
            for template in definition.templates {
                let line = template.clashRule(target: resolvedTarget)
                let key = line.filter { !$0.isWhitespace }.uppercased()
                if seen.insert(key).inserted {
                    emitted.append(line)
                }
            }
        }
        return emitted
    }

    /// Merges layered preset states (e.g., global < per-profile < explicit).
    public static func mergeStates(
        _ layers: [[ScenarioRulePresetState]]
    ) -> [ScenarioRulePresetState] {
        var merged: [ScenarioRulePresetID: ScenarioRulePresetState] = [:]
        for layer in layers {
            for state in layer {
                merged[state.id] = state
            }
        }
        guard !merged.isEmpty else { return [] }
        return ScenarioRulePresetID.allCases.compactMap { merged[$0] }
    }

    /// Returns any `GEOSITE` category codes referenced by built-in presets that
    /// are missing from `index` (empty when all categories exist in `GeoSite.dat`).
    public static func validateGeoSiteCategories(against index: GeoSiteCategoryIndex) -> [String] {
        var missing: [String] = []
        var seen = Set<String>()
        for definition in ScenarioRulePresetDefinition.all {
            for category in definition.geoSiteCategories {
                if !index.contains(ruleValue: category), seen.insert(category).inserted {
                    missing.append(category)
                }
            }
        }
        return missing
    }
}

/// Thread-safe JSON persistence for scenario rule preset states.
public final class ScenarioRulePresetStore: @unchecked Sendable {
    private struct StoragePayload: Codable {
        static let currentVersion = 1
        var version: Int = StoragePayload.currentVersion
        var presets: [ScenarioRulePresetState]
    }

    public static func applicationGroup(fileManager: FileManager = .default) -> ScenarioRulePresetStore {
        let baseURL = fileManager
            .containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup)?
            .appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true)
            ?? fileManager.temporaryDirectory.appendingPathComponent("AetherRoute", isDirectory: true)
        return ScenarioRulePresetStore(fileManager: fileManager, directoryURL: baseURL)
    }

    public let directoryURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()

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
        directoryURL.appendingPathComponent("scenario-rule-presets.json", isDirectory: false)
    }

    public func load() -> [ScenarioRulePresetState] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    public func save(_ states: [ScenarioRulePresetState]) throws {
        lock.lock()
        defer { lock.unlock() }
        try saveLocked(states)
    }

    @discardableResult
    public func setEnabled(_ isEnabled: Bool, for id: ScenarioRulePresetID) throws -> [ScenarioRulePresetState] {
        lock.lock()
        defer { lock.unlock() }
        var states = loadLocked()
        if let index = states.firstIndex(where: { $0.id == id }) {
            states[index].isEnabled = isEnabled
        } else {
            states.append(ScenarioRulePresetState(id: id, isEnabled: isEnabled))
        }
        let normalized = ScenarioRulePresetState.normalized(states)
        try saveLocked(normalized)
        return normalized
    }

    @discardableResult
    public func setTarget(_ target: ScenarioRulePresetTarget, for id: ScenarioRulePresetID) throws -> [ScenarioRulePresetState] {
        lock.lock()
        defer { lock.unlock() }
        var states = loadLocked()
        if let index = states.firstIndex(where: { $0.id == id }) {
            states[index].target = target
        } else {
            states.append(ScenarioRulePresetState(id: id, isEnabled: false, target: target))
        }
        let normalized = ScenarioRulePresetState.normalized(states)
        try saveLocked(normalized)
        return normalized
    }

    private func loadLocked() -> [ScenarioRulePresetState] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode(StoragePayload.self, from: data) else {
            return ScenarioRulePresetState.defaultStates()
        }
        return ScenarioRulePresetState.normalized(decoded.presets)
    }

    private func saveLocked(_ states: [ScenarioRulePresetState]) throws {
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let payload = StoragePayload(presets: ScenarioRulePresetState.normalized(states))
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

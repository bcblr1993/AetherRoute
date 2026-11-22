import CryptoKit
import Foundation

public struct MergedProfileSpec: Codable, Equatable, Sendable {
    public var sourceProfileIDs: [UUID]
    public var prefixSourceName: Bool
    public var deduplicateByServerPort: Bool

    public init(
        sourceProfileIDs: [UUID],
        prefixSourceName: Bool = true,
        deduplicateByServerPort: Bool = true
    ) {
        self.sourceProfileIDs = sourceProfileIDs
        self.prefixSourceName = prefixSourceName
        self.deduplicateByServerPort = deduplicateByServerPort
    }
}

public struct ManagedProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let profile: ActiveProfile
    public let updatedAt: Date
    public let mergedSpec: MergedProfileSpec?

    public init(
        id: UUID = UUID(),
        profile: ActiveProfile,
        updatedAt: Date? = nil,
        mergedSpec: MergedProfileSpec? = nil
    ) {
        self.id = id
        self.profile = profile
        self.updatedAt = updatedAt ?? profile.subscription?.lastUpdatedAt ?? profile.importedAt
        self.mergedSpec = mergedSpec
    }

    enum CodingKeys: String, CodingKey {
        case id, profile, updatedAt, mergedSpec
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let profile = try container.decode(ActiveProfile.self, forKey: .profile)
        let updatedAt = try container.decodeIfPresent(Date.self, forKey: .updatedAt)
            ?? profile.subscription?.lastUpdatedAt
            ?? profile.importedAt
        let mergedSpec = try container.decodeIfPresent(MergedProfileSpec.self, forKey: .mergedSpec)
        self.id = id
        self.profile = profile
        self.updatedAt = updatedAt
        self.mergedSpec = mergedSpec
    }
}

public struct ProfileCatalog: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let activeProfileID: UUID?
    public let profiles: [ManagedProfile]

    public init(
        activeProfileID: UUID? = nil,
        profiles: [ManagedProfile] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    public var activeProfile: ManagedProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }
}

/// Encrypted, host-app-owned profile collection. Network extensions deliberately
/// continue to consume only ``ActiveProfileStore``. This keeps their startup
/// input small and gives activation an explicit, validated mirror boundary.
private final class ProfileCatalogDirectoryLockTable: @unchecked Sendable {
    static let shared = ProfileCatalogDirectoryLockTable()
    private let registryLock = NSLock()
    private var locks: [String: NSRecursiveLock] = [:]

    func lock(for directoryURL: URL) -> NSRecursiveLock {
        let key = directoryURL.standardizedFileURL.path
        registryLock.lock()
        defer { registryLock.unlock() }
        if let existing = locks[key] {
            return existing
        }
        let lock = NSRecursiveLock()
        locks[key] = lock
        return lock
    }
}

public struct ProfileCatalogStore: Sendable {
    public static let maximumProfiles = 64
    public static let maximumTombstones = 1_024
    static let encryptedFilename = "profile-catalog.v1.json"
    static let tombstonesFilename = "profile-sync-tombstones.v1.json"
    static let maximumEncryptedBytes = 64 * 1_024 * 1_024

    public let directoryURL: URL
    private let keyStore: any ProfileKeyStoring
    private let activeProfileStore: ActiveProfileStore
    private let codec = EncryptedProfileCatalogCodec()

    private var catalogURL: URL {
        directoryURL.appendingPathComponent(Self.encryptedFilename)
    }

    private var tombstonesURL: URL {
        directoryURL.appendingPathComponent(Self.tombstonesFilename)
    }

    public init(
        directoryURL: URL,
        keyStore: any ProfileKeyStoring = DataProtectionProfileKeyStore()
    ) {
        self.directoryURL = directoryURL
        self.keyStore = keyStore
        self.activeProfileStore = ActiveProfileStore(
            directoryURL: directoryURL,
            keyStore: keyStore
        )
    }

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw ActiveProfileStoreError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    private func withDirectoryLock<T>(_ operation: () throws -> T) rethrows -> T {
        let lock = ProfileCatalogDirectoryLockTable.shared.lock(for: directoryURL)
        lock.lock()
        defer { lock.unlock() }
        return try operation()
    }

    /// Loads the encrypted collection and repairs its extension-facing active
    /// mirror when needed. A pre-catalog encrypted active profile is migrated
    /// without changing its identifier-visible contents.
    public func loadOrMigrate(
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            if fileManager.fileExists(atPath: catalogURL.path) {
                let catalog = try load(fileManager: fileManager)
                try repairActiveMirror(for: catalog, fileManager: fileManager)
                return catalog
            }

            do {
                let profile = try activeProfileStore.loadValidated(
                    fileManager: fileManager
                )
                let managed = ManagedProfile(profile: profile)
                let catalog = ProfileCatalog(
                    activeProfileID: managed.id,
                    profiles: [managed]
                )
                try save(catalog, fileManager: fileManager)
                return catalog
            } catch ActiveProfileStoreError.noActiveProfile {
                return ProfileCatalog()
            }
        }
    }

    @discardableResult
    public func addValidated(
        data: Data,
        suggestedName: String,
        importedAt: Date = .now,
        subscription: ProfileSubscription? = nil,
        makeActive: Bool = true,
        cancellationCheck: () throws -> Void = {},
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try ProfileImportValidator.validate(
            data: data,
            cancellationCheck: cancellationCheck
        )
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try cancellationCheck()

        let cleanName = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ActiveProfile(
            name: cleanName.isEmpty ? "Imported profile" : cleanName,
            yaml: yaml,
            importedAt: importedAt,
            subscription: subscription
        )
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard current.profiles.count < Self.maximumProfiles else {
                throw ProfileCatalogStoreError.profileLimitReached(
                    Self.maximumProfiles
                )
            }

            let managed = ManagedProfile(profile: profile)
            var profiles = current.profiles
            profiles.append(managed)
            let shouldActivate = makeActive || current.activeProfileID == nil
            let catalog = ProfileCatalog(
                activeProfileID: shouldActivate
                    ? managed.id
                    : current.activeProfileID,
                profiles: profiles
            )
            try cancellationCheck()
            try commit(
                catalog,
                previous: current,
                mirrorProfile: shouldActivate ? profile : nil,
                fileManager: fileManager
            )
            return catalog
        }
    }

    /// Adds an AetherRoute-authored profile while keeping the native node
    /// document and its deterministic core configuration bound together in the
    /// same encrypted catalog transaction.
    @discardableResult
    public func addNative(
        nodes: [AetherNode],
        suggestedName: String,
        importedAt: Date = .now,
        makeActive: Bool = true,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try AetherNodeProfileCompiler.validateDialerProxies(in: nodes)
        let yaml = try AetherNodeProfileCompiler.compile(nodes: nodes)
        let cleanName = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ActiveProfile(
            name: cleanName.isEmpty ? "Manual profile" : cleanName,
            yaml: yaml,
            importedAt: importedAt,
            nativeNodes: nodes
        )
        try profile.validateForStorage()

        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard current.profiles.count < Self.maximumProfiles else {
                throw ProfileCatalogStoreError.profileLimitReached(
                    Self.maximumProfiles
                )
            }
            let managed = ManagedProfile(profile: profile)
            var profiles = current.profiles
            profiles.append(managed)
            let shouldActivate = makeActive || current.activeProfileID == nil
            let catalog = ProfileCatalog(
                activeProfileID: shouldActivate
                    ? managed.id
                    : current.activeProfileID,
                profiles: profiles
            )
            try commit(
                catalog,
                previous: current,
                mirrorProfile: shouldActivate ? profile : nil,
                fileManager: fileManager
            )
            return catalog
        }
    }

    @discardableResult
    public func activate(
        id: UUID,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let selected = current.profiles.first(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            guard current.activeProfileID != id else { return current }

            let updated = ProfileCatalog(
                activeProfileID: id,
                profiles: current.profiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: selected.profile,
                fileManager: fileManager
            )
            return updated
        }
    }

    @discardableResult
    public func replace(
        id: UUID,
        with profile: ActiveProfile,
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try profile.validateForStorage()
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let index = current.profiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }

            // Every caller rebuilds the profile from its parts (a subscription
            // update, a rename, a node edit); overrides it does not mention are
            // kept. `setOverrides` is the one way to change or clear them.
            let profile = profile.overrides == nil
                ? profile.withOverrides(current.profiles[index].profile.overrides)
                : profile
            var profiles = current.profiles
            profiles[index] = ManagedProfile(
                id: id,
                profile: profile,
                updatedAt: updatedAt,
                mergedSpec: current.profiles[index].mergedSpec
            )
            let updated = ProfileCatalog(
                activeProfileID: current.activeProfileID,
                profiles: profiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: current.activeProfileID == id ? profile : nil,
                fileManager: fileManager
            )
            return updated
        }
    }

    /// Replaces or clears a profile's overrides (1.7.0).
    @discardableResult
    public func setOverrides(
        id: UUID,
        overrides: ProfileOverride?,
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let validated = try overrides?.validated()
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let index = current.profiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            let profile = current.profiles[index].profile.withOverrides(validated)
            try profile.validateForStorage()
            var profiles = current.profiles
            profiles[index] = ManagedProfile(
                id: id,
                profile: profile,
                updatedAt: updatedAt,
                mergedSpec: current.profiles[index].mergedSpec
            )
            let updated = ProfileCatalog(
                activeProfileID: current.activeProfileID,
                profiles: profiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: current.activeProfileID == id ? profile : nil,
                fileManager: fileManager
            )
            return updated
        }
    }

    // MARK: - Merged Profiles (Multi-Subscription Combination)

    @discardableResult
    public func createMergedProfile(
        name: String,
        spec: MergedProfileSpec,
        overrides: ProfileOverride? = nil,
        importedAt: Date = .now,
        makeActive: Bool = true,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let validatedOverrides = try overrides?.validated()
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard current.profiles.count < Self.maximumProfiles else {
                throw ProfileCatalogStoreError.profileLimitReached(Self.maximumProfiles)
            }
            let sources = resolveMergeSources(spec: spec, in: current.profiles)
            guard sources.count >= 2 else {
                throw ProfileCatalogStoreError.invalidMergeSpec
            }
            let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedName = cleanName.isEmpty
                ? sources.map(\.profile.name).joined(separator: " + ")
                : cleanName
            let yaml = try Self.compileMergedYAML(sources: sources, spec: spec)
            let profile = ActiveProfile(
                name: resolvedName,
                yaml: yaml,
                importedAt: importedAt,
                overrides: validatedOverrides
            )
            try profile.validateForStorage()

            let managed = ManagedProfile(
                profile: profile,
                updatedAt: importedAt,
                mergedSpec: spec
            )
            var profiles = current.profiles
            profiles.append(managed)
            let shouldActivate = makeActive || current.activeProfileID == nil
            let updated = ProfileCatalog(
                activeProfileID: shouldActivate ? managed.id : current.activeProfileID,
                profiles: profiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: shouldActivate ? profile : nil,
                fileManager: fileManager
            )
            return updated
        }
    }

    @discardableResult
    public func rebuildMergedProfile(
        id: UUID,
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let index = current.profiles.firstIndex(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            let existing = current.profiles[index]
            guard let spec = existing.mergedSpec else {
                throw ProfileCatalogStoreError.notMergedProfile
            }
            let sources = resolveMergeSources(spec: spec, in: current.profiles)
            guard !sources.isEmpty else {
                throw ProfileCatalogStoreError.invalidMergeSpec
            }
            let yaml = try Self.compileMergedYAML(sources: sources, spec: spec)
            let rebuilt = ActiveProfile(
                name: existing.profile.name,
                yaml: yaml,
                importedAt: updatedAt,
                overrides: existing.profile.overrides
            )
            try rebuilt.validateForStorage()

            var profiles = current.profiles
            profiles[index] = ManagedProfile(
                id: id,
                profile: rebuilt,
                updatedAt: updatedAt,
                mergedSpec: spec
            )
            let updated = ProfileCatalog(
                activeProfileID: current.activeProfileID,
                profiles: profiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: current.activeProfileID == id ? rebuilt : nil,
                fileManager: fileManager
            )
            return updated
        }
    }

    @discardableResult
    public func rebuildDependentMergedProfiles(
        referencing sourceProfileID: UUID,
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            var catalog = try loadOrMigrate(fileManager: fileManager)
            let dependentIDs = catalog.profiles
                .filter { $0.mergedSpec?.sourceProfileIDs.contains(sourceProfileID) == true }
                .map(\.id)
            for mergedID in dependentIDs {
                catalog = try rebuildMergedProfile(id: mergedID, updatedAt: updatedAt, fileManager: fileManager)
            }
            return catalog
        }
    }

    private func resolveMergeSources(
        spec: MergedProfileSpec,
        in profiles: [ManagedProfile]
    ) -> [ManagedProfile] {
        var seen = Set<UUID>()
        var sources: [ManagedProfile] = []
        for id in spec.sourceProfileIDs where seen.insert(id).inserted {
            if let match = profiles.first(where: { $0.id == id && $0.mergedSpec == nil }) {
                sources.append(match)
            }
        }
        return sources
    }

    static func compileMergedYAML(
        sources: [ManagedProfile],
        spec: MergedProfileSpec
    ) throws -> String {
        var seenServerPorts = Set<String>()
        var seenNames = Set<String>()
        var mergedProxyBlocks: [[String]] = []
        var mergedNodeNames: [String] = []

        for source in sources {
            let canonical = ProfileRuntimeYAML.canonicalize(source.profile.yaml)
            let extracted = extractProxyEntries(fromYAML: canonical)
            var keptEntries: [(entry: ExtractedProxyEntry, finalName: String)] = []
            var sourceNameMap: [String: String] = [:]
            for entry in extracted {
                if spec.deduplicateByServerPort,
                   !entry.server.isEmpty,
                   !entry.port.isEmpty {
                    let dedupKey = "\(entry.server.lowercased()):\(entry.port)"
                    if !seenServerPorts.insert(dedupKey).inserted {
                        continue
                    }
                }
                let baseName = spec.prefixSourceName
                    ? "[\(source.profile.name)] \(entry.name)"
                    : entry.name
                let finalName = uniqueNodeName(
                    baseName,
                    sourceName: source.profile.name,
                    seen: &seenNames
                )
                sourceNameMap[entry.name] = finalName
                keptEntries.append((entry, finalName))
            }
            for (entry, finalName) in keptEntries {
                let rewritten = rewriteProxyEntryName(
                    entry.lines,
                    newName: finalName,
                    renamedDialers: sourceNameMap
                )
                mergedProxyBlocks.append(rewritten)
                mergedNodeNames.append(finalName)
            }
        }

        guard !mergedProxyBlocks.isEmpty else {
            throw ProfileCatalogStoreError.invalidMergeSpec
        }

        var lines: [String] = [
            "mixed-port: 7890",
            "allow-lan: false",
            "mode: rule",
            "log-level: info",
            "proxies:",
        ]
        for block in mergedProxyBlocks {
            lines.append(contentsOf: block)
        }
        let quotedNodes = mergedNodeNames.map(yamlSingleQuoted)
        let proxyGroupMembers = ([yamlSingleQuoted("Auto")] + quotedNodes + ["DIRECT"]).joined(separator: ", ")
        let autoGroupMembers = quotedNodes.joined(separator: ", ")
        lines.append("proxy-groups:")
        lines.append("  - {name: PROXY, type: select, proxies: [\(proxyGroupMembers)]}")
        lines.append("  - {name: Auto, type: url-test, url: 'https://www.gstatic.com/generate_204', interval: 300, tolerance: 50, proxies: [\(autoGroupMembers)]}")
        lines.append("rules:")
        lines.append("  - GEOIP,LAN,DIRECT")
        lines.append("  - GEOSITE,cn,DIRECT")
        lines.append("  - GEOIP,CN,DIRECT")
        lines.append("  - MATCH,PROXY")
        return lines.joined(separator: "\n") + "\n"
    }

    private struct ExtractedProxyEntry {
        let name: String
        let server: String
        let port: String
        let lines: [String]
    }

    private static func extractProxyEntries(fromYAML yaml: String) -> [ExtractedProxyEntry] {
        let lines = yaml.components(separatedBy: .newlines)
        var inProxies = false
        var itemIndent: Int?
        var blocks: [[String]] = []
        var current: [String] = []

        func flushCurrent() {
            if !current.isEmpty {
                blocks.append(current)
                current.removeAll(keepingCapacity: true)
            }
        }

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let indent = line.prefix(while: { $0 == " " }).count
            if indent == 0 && !trimmed.isEmpty && !trimmed.hasPrefix("#") {
                if trimmed == "proxies:" || trimmed.hasPrefix("proxies:") {
                    inProxies = true
                    let remainder = String(trimmed.dropFirst("proxies:".count)).trimmingCharacters(in: .whitespaces)
                    if remainder == "[]" {
                        inProxies = false
                    }
                    continue
                }
                if inProxies {
                    flushCurrent()
                    inProxies = false
                    break
                }
                continue
            }
            guard inProxies else { continue }
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }

            let isDash = trimmed.hasPrefix("- ") || trimmed == "-"
            if isDash && (itemIndent == nil || indent <= itemIndent!) {
                itemIndent = indent
                flushCurrent()
                current = [line]
            } else if !current.isEmpty {
                current.append(line)
            }
        }
        flushCurrent()

        return blocks.compactMap { block -> ExtractedProxyEntry? in
            guard let first = block.first else { return nil }
            let firstTrimmed = first.trimmingCharacters(in: .whitespaces)
            guard firstTrimmed.hasPrefix("-") else { return nil }
            let afterDash = String(firstTrimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            var name = ""
            var server = ""
            var port = ""
            if afterDash.hasPrefix("{") {
                let flowText = block.map { YAMLDocument.stripComment($0).trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
                if let open = flowText.firstIndex(of: "{"), let close = flowText.lastIndex(of: "}") {
                    let body = String(flowText[flowText.index(after: open)..<close])
                    for field in splitTopLevelFlow(body) {
                        guard let (k, v) = splitKeyValue(field) else { continue }
                        switch k.lowercased() {
                        case "name": name = unquoteYAML(v)
                        case "server": server = unquoteYAML(v)
                        case "port": port = unquoteYAML(v)
                        default: break
                        }
                    }
                }
            } else {
                if let (k, v) = splitKeyValue(YAMLDocument.stripComment(afterDash)) {
                    switch k.lowercased() {
                    case "name": name = unquoteYAML(v)
                    case "server": server = unquoteYAML(v)
                    case "port": port = unquoteYAML(v)
                    default: break
                    }
                }
                let baseIndent = first.prefix(while: { $0 == " " }).count
                for line in block.dropFirst() {
                    let indent = line.prefix(while: { $0 == " " }).count
                    let trimmed = YAMLDocument.stripComment(line.trimmingCharacters(in: .whitespaces))
                    guard indent <= baseIndent + 4, let (k, v) = splitKeyValue(trimmed) else { continue }
                    switch k.lowercased() {
                    case "name": name = unquoteYAML(v)
                    case "server": server = unquoteYAML(v)
                    case "port": port = unquoteYAML(v)
                    default: break
                    }
                }
            }
            guard !name.isEmpty else { return nil }
            return ExtractedProxyEntry(name: name, server: server, port: port, lines: block)
        }
    }

    private static func rewriteProxyEntryName(
        _ block: [String],
        newName: String,
        renamedDialers: [String: String] = [:]
    ) -> [String] {
        guard let first = block.first else { return block }
        let baseIndent = first.prefix(while: { $0 == " " }).count
        let leadingPad = String(repeating: " ", count: baseIndent)
        let firstTrimmed = first.trimmingCharacters(in: .whitespaces)
        let afterDash = String(firstTrimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
        let quotedName = yamlSingleQuoted(newName)

        if afterDash.hasPrefix("{") {
            let flowText = block.map { YAMLDocument.stripComment($0).trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            if let open = flowText.firstIndex(of: "{"), let close = flowText.lastIndex(of: "}") {
                let body = String(flowText[flowText.index(after: open)..<close])
                var fields = splitTopLevelFlow(body)
                var replaced = false
                for idx in fields.indices {
                    if let (k, v) = splitKeyValue(fields[idx]) {
                        let lowerK = k.lowercased()
                        if lowerK == "name" {
                            fields[idx] = "name: \(quotedName)"
                            replaced = true
                        } else if lowerK == "dialer-proxy" || lowerK == "connect-via" {
                            let rawTarget = unquoteYAML(v)
                            if let mapped = renamedDialers[rawTarget] {
                                fields[idx] = "\(k): \(yamlSingleQuoted(mapped))"
                            }
                        }
                    }
                }
                if !replaced {
                    fields.insert("name: \(quotedName)", at: 0)
                }
                return ["\(leadingPad)- {\(fields.joined(separator: ", "))}"]
            }
        }

        var updated = block
        var replacedName = false
        if let (k, v) = splitKeyValue(YAMLDocument.stripComment(afterDash)) {
            let lowerK = k.lowercased()
            if lowerK == "name" {
                updated[0] = "\(leadingPad)- name: \(quotedName)"
                replacedName = true
            } else if lowerK == "dialer-proxy" || lowerK == "connect-via" {
                let rawTarget = unquoteYAML(v)
                if let mapped = renamedDialers[rawTarget] {
                    updated[0] = "\(leadingPad)- \(k): \(yamlSingleQuoted(mapped))"
                }
            }
        }
        for idx in updated.indices.dropFirst() {
            let line = updated[idx]
            let indent = line.prefix(while: { $0 == " " }).count
            let trimmed = YAMLDocument.stripComment(line.trimmingCharacters(in: .whitespaces))
            guard indent <= baseIndent + 4, let (k, v) = splitKeyValue(trimmed) else { continue }
            let lowerK = k.lowercased()
            let pad = String(repeating: " ", count: indent)
            if lowerK == "name" && !replacedName {
                updated[idx] = "\(pad)name: \(quotedName)"
                replacedName = true
            } else if lowerK == "dialer-proxy" || lowerK == "connect-via" {
                let rawTarget = unquoteYAML(v)
                if let mapped = renamedDialers[rawTarget] {
                    updated[idx] = "\(pad)\(k): \(yamlSingleQuoted(mapped))"
                }
            }
        }
        return updated
    }

    private static func uniqueNodeName(
        _ base: String,
        sourceName: String,
        seen: inout Set<String>
    ) -> String {
        if seen.insert(base).inserted {
            return base
        }
        let withSource = "\(base) (\(sourceName))"
        if seen.insert(withSource).inserted {
            return withSource
        }
        var suffix = 2
        while true {
            let candidate = "\(base) #\(suffix)"
            if seen.insert(candidate).inserted {
                return candidate
            }
            suffix += 1
        }
    }

    private static func yamlSingleQuoted(_ text: String) -> String {
        let escaped = text.replacingOccurrences(of: "'", with: "''")
        return "'\(escaped)'"
    }

    private static func splitKeyValue(_ text: String) -> (String, String)? {
        guard let colon = text.firstIndex(of: ":") else { return nil }
        let after = text.index(after: colon)
        if after < text.endIndex && text[after] != " " {
            return nil
        }
        let key = String(text[..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(text[after...]).trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : (key, value)
    }

    private static func unquoteYAML(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count >= 2, trimmed.hasPrefix("'"), trimmed.hasSuffix("'") {
            return String(trimmed.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
            return String(trimmed.dropFirst().dropLast())
        }
        return trimmed
    }

    private static func splitTopLevelFlow(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inSingle = false
        var inDouble = false
        var escaped = false
        for ch in text {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            if ch == "\\" && inDouble {
                current.append(ch)
                escaped = true
                continue
            }
            if ch == "'" && !inDouble {
                inSingle.toggle()
            } else if ch == "\"" && !inSingle {
                inDouble.toggle()
            } else if !inSingle && !inDouble {
                if ch == "{" || ch == "[" { depth += 1 }
                else if ch == "}" || ch == "]" { depth = max(0, depth - 1) }
                else if ch == "," && depth == 0 {
                    let trimmed = current.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { result.append(trimmed) }
                    current = ""
                    continue
                }
            }
            current.append(ch)
        }
        let trimmed = current.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { result.append(trimmed) }
        return result
    }

    /// Recompiles an AetherRoute-authored profile after a bounded native-node
    /// edit. Imported YAML and subscription profiles cannot silently cross this
    /// boundary because they do not carry a native node document.
    @discardableResult
    public func updateNative(
        id: UUID,
        nodes: [AetherNode],
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let existing = current.profiles.first(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            guard existing.profile.nativeNodes != nil,
                  existing.profile.subscription == nil else {
                throw ProfileCatalogStoreError.notNativeProfile
            }
            try AetherNodeProfileCompiler.validateDialerProxies(in: nodes)
            let yaml = try AetherNodeProfileCompiler.compile(nodes: nodes)
            let profile = ActiveProfile(
                name: existing.profile.name,
                yaml: yaml,
                importedAt: updatedAt,
                nativeNodes: nodes
            )
            return try replace(
                id: id,
                with: profile,
                updatedAt: updatedAt,
                fileManager: fileManager
            )
        }
    }

    @discardableResult
    public func rename(
        id: UUID,
        to name: String,
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProfileCatalogStoreError.emptyName
        }
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let existing = current.profiles.first(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            let profile = ActiveProfile(
                name: cleanName,
                yaml: existing.profile.yaml,
                importedAt: existing.profile.importedAt,
                subscription: existing.profile.subscription,
                nativeNodes: existing.profile.nativeNodes
            )
            return try replace(
                id: id,
                with: profile,
                updatedAt: updatedAt,
                fileManager: fileManager
            )
        }
    }

    @discardableResult
    public func duplicate(
        id: UUID,
        suggestedName: String? = nil,
        importedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard let existing = current.profiles.first(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            guard current.profiles.count < Self.maximumProfiles else {
                throw ProfileCatalogStoreError.profileLimitReached(
                    Self.maximumProfiles
                )
            }
            let defaultName = "\(existing.profile.name) Copy"
            let cleanName = (suggestedName ?? defaultName)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let clonedProfile = ActiveProfile(
                name: cleanName.isEmpty ? defaultName : cleanName,
                yaml: existing.profile.yaml,
                importedAt: importedAt,
                subscription: nil,
                nativeNodes: existing.profile.nativeNodes,
                overrides: existing.profile.overrides
            )
            try clonedProfile.validateForStorage()
            var profiles = current.profiles
            profiles.append(ManagedProfile(profile: clonedProfile))
            let updated = ProfileCatalog(
                activeProfileID: current.activeProfileID,
                profiles: profiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: nil,
                fileManager: fileManager
            )
            return updated
        }
    }

    @discardableResult
    public func remove(
        id: UUID,
        deletedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            guard current.profiles.contains(where: { $0.id == id }) else {
                throw ProfileCatalogStoreError.profileNotFound
            }
            guard current.activeProfileID != id else {
                throw ProfileCatalogStoreError.cannotRemoveActiveProfile
            }

            var remainingProfiles: [ManagedProfile] = []
            remainingProfiles.reserveCapacity(current.profiles.count)
            for item in current.profiles where item.id != id {
                if var spec = item.mergedSpec, spec.sourceProfileIDs.contains(id) {
                    spec.sourceProfileIDs.removeAll { $0 == id }
                    let updatedSpec: MergedProfileSpec? = spec.sourceProfileIDs.isEmpty ? nil : spec
                    remainingProfiles.append(
                        ManagedProfile(
                            id: item.id,
                            profile: item.profile,
                            updatedAt: deletedAt,
                            mergedSpec: updatedSpec
                        )
                    )
                } else {
                    remainingProfiles.append(item)
                }
            }

            var updated = ProfileCatalog(
                activeProfileID: current.activeProfileID,
                profiles: remainingProfiles
            )
            try commit(
                updated,
                previous: current,
                mirrorProfile: nil,
                fileManager: fileManager
            )
            var tombstones = loadDeletedProfiles(fileManager: fileManager)
            tombstones[id] = max(deletedAt, tombstones[id] ?? .distantPast)
            try? saveDeletedProfiles(tombstones, fileManager: fileManager)
            // Rebuild any merged profiles whose remaining sources are still non-empty
            for item in updated.profiles where item.mergedSpec != nil {
                if let rebuilt = try? rebuildMergedProfile(id: item.id, updatedAt: deletedAt, fileManager: fileManager) {
                    updated = rebuilt
                }
            }
            return updated
        }
    }

    /// Merges a decrypted portable catalog while preserving the profile that
    /// is active on this Mac. Identical profiles are skipped and identifier
    /// collisions are assigned fresh identifiers. An empty local library uses
    /// the archived active profile only after this explicit import call.
    @discardableResult
    public func mergeValidated(
        _ imported: ProfileCatalog,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try imported.validateForStorage()
        guard !imported.profiles.isEmpty else {
            throw PortableProfileArchiveError.emptyCatalog
        }
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            var profiles = current.profiles
            var identifiers = Set(profiles.map(\.id))
            var importedIdentifierMap: [UUID: UUID] = [:]

            for managed in imported.profiles {
                if let existing = profiles.first(where: {
                    $0.profile.isEquivalentForPortableMerge(to: managed.profile)
                }) {
                    importedIdentifierMap[managed.id] = existing.id
                    continue
                }
                guard profiles.count < Self.maximumProfiles else {
                    throw ProfileCatalogStoreError.profileLimitReached(
                        Self.maximumProfiles
                    )
                }
                var identifier = managed.id
                while identifiers.contains(identifier) {
                    identifier = UUID()
                }
                identifiers.insert(identifier)
                importedIdentifierMap[managed.id] = identifier
                profiles.append(
                    ManagedProfile(id: identifier, profile: managed.profile)
                )
            }

            let activeProfileID: UUID?
            if let currentActive = current.activeProfileID {
                activeProfileID = currentActive
            } else if let importedActive = imported.activeProfileID {
                activeProfileID = importedIdentifierMap[importedActive]
            } else {
                activeProfileID = nil
            }
            let merged = ProfileCatalog(
                activeProfileID: activeProfileID,
                profiles: profiles
            )
            guard merged != current else { return current }
            let mirror = current.activeProfileID == nil
                ? merged.activeProfile?.profile
                : nil
            try commit(
                merged,
                previous: current,
                mirrorProfile: mirror,
                fileManager: fileManager
            )
            return merged
        }
    }

    /// Reconciles an incoming iCloud catalog and deletion tombstones with the
    /// local library using last-writer-wins semantics. Matching profiles (by
    /// `id` or canonical `subscription.url`) are updated in place with the same
    /// local UUID instead of creating duplicates, and deleted profiles remain
    /// deleted unless a newer update supersedes the tombstone.
    @discardableResult
    public func reconcileCloudSync(
        _ remoteCatalog: ProfileCatalog,
        tombstones remoteTombstones: [UUID: Date] = [:],
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try remoteCatalog.validateForStorage()
        return try withDirectoryLock {
            let current = try loadOrMigrate(fileManager: fileManager)
            let localTombstones = loadDeletedProfiles(fileManager: fileManager)

            var mergedTombstones = localTombstones
            for (id, deletedAt) in remoteTombstones {
                if deletedAt > (mergedTombstones[id] ?? .distantPast) {
                    mergedTombstones[id] = deletedAt
                }
            }

            var mergedProfiles: [ManagedProfile] = []
            for local in current.profiles {
                if let deletedAt = mergedTombstones[local.id], deletedAt >= local.updatedAt {
                    continue
                }
                if mergedTombstones[local.id] != nil {
                    mergedTombstones.removeValue(forKey: local.id)
                }
                mergedProfiles.append(local)
            }

            for remote in remoteCatalog.profiles {
                if let deletedAt = mergedTombstones[remote.id], deletedAt >= remote.updatedAt {
                    continue
                }

                if let matchIndex = mergedProfiles.firstIndex(where: { $0.id == remote.id }) {
                    let existing = mergedProfiles[matchIndex]
                    if remote.updatedAt > existing.updatedAt {
                        mergedProfiles[matchIndex] = ManagedProfile(
                            id: existing.id,
                            profile: remote.profile,
                            updatedAt: remote.updatedAt,
                            mergedSpec: remote.mergedSpec
                        )
                        if let deletedAt = mergedTombstones[existing.id], remote.updatedAt > deletedAt {
                            mergedTombstones.removeValue(forKey: existing.id)
                        }
                    }
                    continue
                }

                if let remoteSubURL = remote.profile.subscription?.url {
                    let canonicalRemoteURL = Self.canonicalSubscriptionURL(remoteSubURL)
                    if let matchIndex = mergedProfiles.firstIndex(where: {
                        $0.profile.subscription.map {
                            Self.canonicalSubscriptionURL($0.url) == canonicalRemoteURL
                        } ?? false
                    }) {
                        let existing = mergedProfiles[matchIndex]
                        if let deletedAt = mergedTombstones[existing.id], deletedAt >= max(existing.updatedAt, remote.updatedAt) {
                            continue
                        }
                        if remote.updatedAt > existing.updatedAt {
                            mergedProfiles[matchIndex] = ManagedProfile(
                                id: existing.id,
                                profile: remote.profile,
                                updatedAt: remote.updatedAt,
                                mergedSpec: remote.mergedSpec
                            )
                            if let deletedAt = mergedTombstones[existing.id], remote.updatedAt > deletedAt {
                                mergedTombstones.removeValue(forKey: existing.id)
                            }
                        }
                        continue
                    }
                }

                guard mergedProfiles.count < Self.maximumProfiles else {
                    throw ProfileCatalogStoreError.profileLimitReached(
                        Self.maximumProfiles
                    )
                }
                if let deletedAt = mergedTombstones[remote.id], remote.updatedAt > deletedAt {
                    mergedTombstones.removeValue(forKey: remote.id)
                }
                mergedProfiles.append(remote)
            }

            let mergedIDs = Set(mergedProfiles.map(\.id))
            let activeProfileID: UUID?
            if mergedProfiles.isEmpty {
                activeProfileID = nil
            } else if let currentActive = current.activeProfileID, mergedIDs.contains(currentActive) {
                activeProfileID = currentActive
            } else if let remoteActive = remoteCatalog.activeProfileID, mergedIDs.contains(remoteActive) {
                activeProfileID = remoteActive
            } else {
                activeProfileID = mergedProfiles.first?.id
            }

            let reconciled = ProfileCatalog(
                activeProfileID: activeProfileID,
                profiles: mergedProfiles
            )
            let prunedTombstones = Self.prunedTombstones(mergedTombstones)
            if prunedTombstones != localTombstones {
                try saveDeletedProfiles(prunedTombstones, fileManager: fileManager)
            }
            guard reconciled != current else { return current }

            if let mirror = reconciled.activeProfile?.profile {
                let shouldUpdateMirror = reconciled.activeProfile != current.activeProfile
                try commit(
                    reconciled,
                    previous: current,
                    mirrorProfile: shouldUpdateMirror ? mirror : nil,
                    fileManager: fileManager
                )
            } else {
                try save(reconciled, fileManager: fileManager)
                if current.activeProfile != nil {
                    try? activeProfileStore.removeEncryptedProfile(fileManager: fileManager)
                }
            }
            return reconciled
        }
    }

    public func loadDeletedProfiles(fileManager: FileManager = .default) -> [UUID: Date] {
        withDirectoryLock {
            guard fileManager.fileExists(atPath: tombstonesURL.path),
                  let data = try? Data(contentsOf: tombstonesURL, options: [.mappedIfSafe]),
                  let raw = try? Self.tombstoneDecoder.decode([String: Date].self, from: data) else {
                return [:]
            }
            var result: [UUID: Date] = [:]
            for (key, date) in raw {
                if let uuid = UUID(uuidString: key) {
                    result[uuid] = date
                }
            }
            return result
        }
    }

    static func canonicalSubscriptionURL(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        if (components.scheme == "https" && components.port == 443)
            || (components.scheme == "http" && components.port == 80) {
            components.port = nil
        }
        components.fragment = nil
        if components.path == "/" {
            components.path = ""
        } else if components.path.count > 1, components.path.hasSuffix("/") {
            components.path = String(components.path.dropLast())
        }
        return (components.string ?? url.absoluteString).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func saveDeletedProfiles(
        _ tombstones: [UUID: Date],
        fileManager: FileManager
    ) throws {
        let pruned = Self.prunedTombstones(tombstones)
        let encodedMap = Dictionary(
            uniqueKeysWithValues: pruned.map { ($0.key.uuidString, $0.value) }
        )
        let data = try Self.tombstoneEncoder.encode(encodedMap)
        try ensureDirectory(fileManager: fileManager)
        try data.write(to: tombstonesURL, options: [.atomic])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: tombstonesURL.path
        )
        try excludeFromBackup(tombstonesURL)
    }

    private static func prunedTombstones(_ tombstones: [UUID: Date]) -> [UUID: Date] {
        guard tombstones.count > maximumTombstones else { return tombstones }
        let kept = tombstones.sorted { $0.value > $1.value }.prefix(maximumTombstones)
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
    }

    private static var tombstoneEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var tombstoneDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public func replaceCatalog(
        _ catalog: ProfileCatalog,
        fileManager: FileManager = .default
    ) throws {
        try catalog.validateForStorage()
        try withDirectoryLock {
            let current = try? load(fileManager: fileManager)
            let mirror = catalog.activeProfile?.profile
            try commit(
                catalog,
                previous: current,
                mirrorProfile: mirror,
                fileManager: fileManager
            )
        }
    }

    private func load(fileManager: FileManager) throws -> ProfileCatalog {
        // Reading attributes can block indefinitely on macOS 26 when the
        // encrypted catalog carries provenance and backup-exclusion xattrs.
        // Mapping the file keeps the pre-decode size gate without forcing
        // Foundation to enumerate those extended attributes.
        let data = try Data(contentsOf: catalogURL, options: [.mappedIfSafe])
        let size = data.count
        guard size <= Self.maximumEncryptedBytes else {
            throw ProfileCatalogStoreError.encryptedCatalogTooLarge(size)
        }
        let metadata = try codec.decodeEnvelope(data)
        let key = try keyStore.loadKey(keyID: metadata.keyID)
        let catalog = try codec.open(data, keyData: key)
        try catalog.validateForStorage()
        return catalog
    }

    private func commit(
        _ catalog: ProfileCatalog,
        previous: ProfileCatalog?,
        mirrorProfile: ActiveProfile?,
        fileManager: FileManager
    ) throws {
        try save(catalog, fileManager: fileManager)
        guard let mirrorProfile else { return }
        do {
            try saveActiveMirror(mirrorProfile, fileManager: fileManager)
        } catch {
            guard let previous else {
                throw ProfileCatalogStoreError.activeMirrorWriteFailed
            }
            do {
                try save(previous, fileManager: fileManager)
                if let oldMirror = previous.activeProfile?.profile {
                    try saveActiveMirror(oldMirror, fileManager: fileManager)
                } else {
                    try activeProfileStore.removeEncryptedProfile(
                        fileManager: fileManager
                    )
                }
            } catch {
                throw ProfileCatalogStoreError.transactionRecoveryFailed
            }
            throw ProfileCatalogStoreError.activeMirrorWriteFailed
        }
    }

    private func save(
        _ catalog: ProfileCatalog,
        fileManager: FileManager
    ) throws {
        try catalog.validateForStorage()
        let key: Data
        if fileManager.fileExists(atPath: catalogURL.path) {
            let current = try Data(
                contentsOf: catalogURL,
                options: [.mappedIfSafe]
            )
            let metadata = try codec.decodeEnvelope(current)
            key = try keyStore.loadKey(keyID: metadata.keyID)
        } else {
            key = try keyStore.loadOrCreateKey(keyID: codec.keyID)
        }
        let encrypted = try codec.seal(catalog, keyData: key)
        guard encrypted.count <= Self.maximumEncryptedBytes else {
            throw ProfileCatalogStoreError.encryptedCatalogTooLarge(
                encrypted.count
            )
        }
        try writeAtomically(encrypted, fileManager: fileManager)
    }

    private func repairActiveMirror(
        for catalog: ProfileCatalog,
        fileManager: FileManager
    ) throws {
        guard let active = catalog.activeProfile else { return }
        do {
            let mirror = try activeProfileStore.loadValidated(
                fileManager: fileManager
            )
            guard !mirror.isEquivalentForActiveMirror(to: active.profile) else {
                return
            }
        } catch ActiveProfileStoreError.noActiveProfile {
            // The authoritative catalog can recreate a missing mirror.
        }
        try saveActiveMirror(active.profile, fileManager: fileManager)
    }

    private func saveActiveMirror(
        _ profile: ActiveProfile,
        fileManager: FileManager
    ) throws {
        guard let data = profile.yaml.data(using: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try activeProfileStore.saveValidated(
            data: data,
            suggestedName: profile.name,
            importedAt: profile.importedAt,
            subscription: profile.subscription,
            // A network extension that restarts on its own reads this mirror
            // and must build the same groups the app would (1.7.0).
            overrides: profile.overrides,
            fileManager: fileManager
        )
    }

}

extension ProfileCatalog {
    func validateForStorage() throws {
        guard formatVersion == ProfileCatalog.currentFormatVersion else {
            throw ProfileCatalogStoreError.unsupportedFormat(
                formatVersion
            )
        }
        guard profiles.count <= ProfileCatalogStore.maximumProfiles else {
            throw ProfileCatalogStoreError.profileLimitReached(
                ProfileCatalogStore.maximumProfiles
            )
        }
        let identifiers = Set(profiles.map(\.id))
        guard identifiers.count == profiles.count else {
            throw ProfileCatalogStoreError.duplicateIdentifier
        }
        if let activeProfileID,
           !identifiers.contains(activeProfileID) {
            throw ProfileCatalogStoreError.activeProfileNotFound
        }
        if !profiles.isEmpty, activeProfileID == nil {
            throw ProfileCatalogStoreError.activeProfileNotFound
        }
        for managed in profiles {
            try managed.profile.validateForStorage()
        }
    }
}

extension ActiveProfile {
    func validateForStorage() throws {
        guard formatVersion == ActiveProfile.currentFormatVersion else {
            throw ActiveProfileStoreError.unsupportedFormat(
                formatVersion
            )
        }
        guard let data = yaml.data(using: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try ProfileImportValidator.validate(data: data)
        if let nativeNodes {
            _ = try AetherNodeProfileCompiler.compile(nodes: nativeNodes)
            let yamlNodeNames = ProfileOverrideCompiler.nodeNames(in: yaml)
            let nativeNodeNames = nativeNodes.map {
                $0.name.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard yamlNodeNames == nativeNodeNames else {
                throw ProfileCatalogStoreError.nativeProfileMismatch
            }
        }
        if let overrides {
            _ = try overrides.validated()
        }
    }

    fileprivate func isEquivalentForPortableMerge(
        to other: ActiveProfile
    ) -> Bool {
        name == other.name
            && yaml == other.yaml
            && subscription?.url == other.subscription?.url
            && nativeNodes == other.nativeNodes
            && overrides == other.overrides
    }

    fileprivate func isEquivalentForActiveMirror(
        to other: ActiveProfile
    ) -> Bool {
        name == other.name
            && yaml == other.yaml
            && importedAt == other.importedAt
            && subscription == other.subscription
            && overrides == other.overrides
    }

}

extension ProfileCatalogStore {
    private func ensureDirectory(fileManager: FileManager) throws {
        let directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try fileManager.setAttributes(
            directoryAttributes,
            ofItemAtPath: directoryURL.path
        )
        try excludeFromBackup(directoryURL)
    }

    private func writeAtomically(
        _ data: Data,
        fileManager: FileManager
    ) throws {
        try ensureDirectory(fileManager: fileManager)

        try data.write(to: catalogURL, options: [.atomic])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: catalogURL.path
        )
        try excludeFromBackup(catalogURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

public enum ProfileCatalogStoreError: LocalizedError, Equatable {
    case activeMirrorWriteFailed
    case activeProfileNotFound
    case cannotRemoveActiveProfile
    case duplicateIdentifier
    case emptyName
    case encryptedCatalogTooLarge(Int)
    case invalidMergeSpec
    case nativeProfileMismatch
    case notMergedProfile
    case notNativeProfile
    case profileLimitReached(Int)
    case profileNotFound
    case transactionRecoveryFailed
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .activeMirrorWriteFailed:
            "The active profile could not be synchronized with the network extension. No profile switch was completed."
        case .activeProfileNotFound:
            "The encrypted profile catalog does not contain its active profile."
        case .cannotRemoveActiveProfile:
            "Activate another profile before removing this one."
        case .duplicateIdentifier:
            "The encrypted profile catalog contains duplicate identifiers."
        case .emptyName:
            "Enter a profile name."
        case let .encryptedCatalogTooLarge(bytes):
            "The encrypted profile catalog is too large (\(bytes) bytes)."
        case .invalidMergeSpec:
            "Select at least two source profiles with valid nodes to create a merged profile."
        case .nativeProfileMismatch:
            "The native node document does not match its compiled core profile."
        case .notMergedProfile:
            "Only merged profiles can be rebuilt from source subscriptions."
        case .notNativeProfile:
            "Only AetherRoute-native profiles can be edited as nodes."
        case let .profileLimitReached(limit):
            "The profile limit (\(limit)) has been reached."
        case .profileNotFound:
            "The selected profile no longer exists."
        case .transactionRecoveryFailed:
            "The profile switch could not be rolled back. Restart AetherRoute to repair the active profile mirror before connecting."
        case let .unsupportedFormat(version):
            "The profile catalog format version \(version) is not supported."
        }
    }
}

private struct EncryptedProfileCatalogCodec: Sendable {
    static let purpose = "AetherRoute.ProfileCatalog"
    let keyID = EncryptedProfileCodec.defaultKeyID

    func seal(_ catalog: ProfileCatalog, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        let plaintext: Data
        do {
            plaintext = try Self.payloadEncoder.encode(catalog)
        } catch {
            throw EncryptedProfileCodecError.profileEncodingFailed
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: authenticatedData(keyID: keyID)
            )
        } catch {
            throw EncryptedProfileCodecError.encryptionFailed
        }
        guard let combined = box.combined else {
            throw EncryptedProfileCodecError.encryptionFailed
        }
        let envelope = EncryptedProfileEnvelope(
            formatVersion: EncryptedProfileCodec.currentFormatVersion,
            algorithm: EncryptedProfileCodec.algorithm,
            keyID: keyID,
            sealedBox: combined
        )
        do {
            return try Self.envelopeEncoder.encode(envelope)
        } catch {
            throw EncryptedProfileCodecError.envelopeEncodingFailed
        }
    }

    func open(_ data: Data, keyData: Data) throws -> ProfileCatalog {
        let envelope = try decodeEnvelope(data)
        let key = try symmetricKey(from: keyData)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        } catch {
            throw EncryptedProfileCodecError.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(keyID: envelope.keyID)
            )
        } catch {
            throw EncryptedProfileCodecError.authenticationFailed
        }
        do {
            return try Self.payloadDecoder.decode(
                ProfileCatalog.self,
                from: plaintext
            )
        } catch {
            throw EncryptedProfileCodecError.profileDecodingFailed
        }
    }

    func decodeEnvelope(_ data: Data) throws -> EncryptedProfileEnvelope {
        let envelope: EncryptedProfileEnvelope
        do {
            envelope = try JSONDecoder().decode(
                EncryptedProfileEnvelope.self,
                from: data
            )
        } catch {
            throw EncryptedProfileCodecError.malformedEnvelope
        }
        guard envelope.formatVersion == EncryptedProfileCodec.currentFormatVersion else {
            throw EncryptedProfileCodecError.unsupportedFormat(
                envelope.formatVersion
            )
        }
        guard envelope.algorithm == EncryptedProfileCodec.algorithm else {
            throw EncryptedProfileCodecError.unsupportedAlgorithm(
                envelope.algorithm
            )
        }
        guard envelope.keyID == keyID else {
            throw EncryptedProfileCodecError.unsupportedKeyID(
                envelope.keyID
            )
        }
        return envelope
    }

    private func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw EncryptedProfileCodecError.invalidKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func authenticatedData(keyID: String) -> Data {
        Data(
            "\(Self.purpose)|\(EncryptedProfileCodec.currentFormatVersion)|\(keyID)".utf8
        )
    }

    private static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var payloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var envelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

import CryptoKit
import Darwin
import Foundation
import OSLog

public enum RuleProviderBehavior: String, Codable, Sendable, CaseIterable {
    case domain
    case ipcidr
    case classical
}

public enum RuleProviderFormat: String, Codable, Sendable, CaseIterable {
    case yaml
    case text
    case mrs

    public var fileExtension: String {
        switch self {
        case .yaml: "yaml"
        case .text: "txt"
        case .mrs: "mrs"
        }
    }
}

public struct RemoteRuleItem: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let type: String
    public let payload: String
    public let target: String
    public let noResolve: Bool

    public init(
        id: String = UUID().uuidString,
        type: String,
        payload: String,
        target: String = "",
        noResolve: Bool = false
    ) {
        self.id = id
        self.type = type
        self.payload = payload
        self.target = target
        self.noResolve = noResolve
    }
}

public struct RuleProviderMetadata: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var behavior: RuleProviderBehavior
    public var format: RuleProviderFormat
    public var defaultTarget: String
    public var isEnabled: Bool
    public var intervalSeconds: UInt32
    public var lastUpdatedAt: Date?
    public var ruleCount: Int
    public var etag: String?
    public var sha256: String?

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        behavior: RuleProviderBehavior = .domain,
        format: RuleProviderFormat = .text,
        defaultTarget: String = "PROXY",
        isEnabled: Bool = true,
        intervalSeconds: UInt32 = 86_400,
        lastUpdatedAt: Date? = nil,
        ruleCount: Int = 0,
        etag: String? = nil,
        sha256: String? = nil
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.behavior = behavior
        self.format = format
        self.defaultTarget = defaultTarget
        self.isEnabled = isEnabled
        self.intervalSeconds = intervalSeconds
        self.lastUpdatedAt = lastUpdatedAt
        self.ruleCount = ruleCount
        self.etag = etag
        self.sha256 = sha256
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, behavior, format, defaultTarget, isEnabled
        case intervalSeconds, lastUpdatedAt, ruleCount, etag, sha256
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(URL.self, forKey: .url)
        self.behavior = try container.decode(RuleProviderBehavior.self, forKey: .behavior)
        self.format = try container.decode(RuleProviderFormat.self, forKey: .format)
        self.defaultTarget = try container.decodeIfPresent(String.self, forKey: .defaultTarget) ?? "PROXY"
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        self.intervalSeconds = try container.decode(UInt32.self, forKey: .intervalSeconds)
        self.lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        self.ruleCount = try container.decode(Int.self, forKey: .ruleCount)
        self.etag = try container.decodeIfPresent(String.self, forKey: .etag)
        self.sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
    }
}

public enum RuleProviderError: LocalizedError, Equatable {
    case invalidURL
    case insecureScheme
    case downloadFailed(String)
    case oversizedPayload(Int)
    case parsingFailed
    case providerNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "规则集 URL 无效 / Invalid rule provider URL"
        case .insecureScheme:
            "规则集必须使用 HTTPS 协议 / Rule provider must use HTTPS"
        case let .downloadFailed(reason):
            "规则集下载失败: \(reason) / Download failed: \(reason)"
        case let .oversizedPayload(bytes):
            "规则集超出大小限制 (\(bytes) 字节) / Rule provider exceeded size limit (\(bytes) bytes)"
        case .parsingFailed:
            "规则集解析失败 / Failed to parse rule provider"
        case .providerNotFound:
            "未找到指定的规则集 / Rule provider not found"
        }
    }
}

/// Actor-based remote rule provider manager respecting memory and security bounds.
public actor RuleProviderEngine {
    public typealias HTTPFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    public static let shared = RuleProviderEngine()

    public static let maximumPayloadBytes = 5 * 1_024 * 1_024 // 5MB max bound for text/yaml
    public static let maximumBinaryPayloadBytes = 32 * 1_024 * 1_024 // 32MB max bound for binary .mrs
    static let customProviderIDsFilename = "custom-provider-ids.json"
    static let migratedLegacyProviderIDsFilename = "migrated-legacy-provider-ids.json"
    private static let logger = AppLog.logger(category: "kit.rule-providers")

    private let fileManager: FileManager
    private let directoryURL: URL
    private let stagingBaseURL: URL
    private let httpFetcher: HTTPFetcher?
    private var providers: [UUID: RuleProviderMetadata] = [:]
    private var providerRevisions: [UUID: UInt64] = [:]
    private var stagedProfileProviders: [UUID: RuleProviderMetadata] = [:]
    private var stagedProviderRevisions: [UUID: UInt64] = [:]
    private var userConfirmedCustomIDs: Set<UUID> = []
    private var migratedLegacyProviderIDs: Set<UUID> = []

    private enum ProviderStoreKind {
        case custom
        case stagedProfile
    }

    public init(
        fileManager: FileManager = .default,
        directoryURL: URL? = nil,
        stagingBaseURL: URL? = nil,
        httpFetcher: HTTPFetcher? = nil
    ) {
        self.fileManager = fileManager
        let dir: URL
        if let customDir = directoryURL {
            dir = customDir
        } else if let appGroup = AppConstants.optionalIdentityValue(AppConstants.appGroupInfoKey),
                  let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            dir = container.appendingPathComponent("Library/Application Support/AetherRoute/RuleProviders", isDirectory: true)
        } else {
            dir = fileManager.temporaryDirectory.appendingPathComponent("RuleProviders", isDirectory: true)
        }
        self.directoryURL = dir
        if let stagingBaseURL {
            self.stagingBaseURL = stagingBaseURL
        } else if directoryURL != nil {
            self.stagingBaseURL = dir.deletingLastPathComponent()
        } else if let appGroup = AppConstants.optionalIdentityValue(AppConstants.appGroupInfoKey),
                  let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            self.stagingBaseURL = container.appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true)
        } else {
            self.stagingBaseURL = dir.deletingLastPathComponent()
        }
        self.httpFetcher = httpFetcher

        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let resolvedStagingBaseURL = self.stagingBaseURL
        let metaURL = dir.appendingPathComponent("providers.json")
        var loadedProviders = Self.loadProvidersMetadata(fileManager: fileManager, metadataURL: metaURL)
        var initialRevisions: [UUID: UInt64] = [:]
        let stagedMetaURL = dir.appendingPathComponent("staged-profile-providers.json")
        var loadedStaged = Self.loadProvidersMetadata(fileManager: fileManager, metadataURL: stagedMetaURL)
        let loadedCustomIDs = Self.loadUUIDSet(
            fileManager: fileManager,
            url: dir.appendingPathComponent(Self.customProviderIDsFilename)
        )
        var loadedMigratedIDs = Self.loadUUIDSet(
            fileManager: fileManager,
            url: dir.appendingPathComponent(Self.migratedLegacyProviderIDsFilename)
        )

        let discoveredYAMLs: [String]
        let hasCandidateUnconfirmedProxy = loadedProviders.values.contains { entry in
            !loadedCustomIDs.contains(entry.id)
                && entry.isEnabled
                && entry.defaultTarget.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PROXY"
                && entry.format != .mrs
        }
        if hasCandidateUnconfirmedProxy {
            discoveredYAMLs = Self.discoverProfileYAMLs(in: resolvedStagingBaseURL, fileManager: fileManager)
        } else {
            discoveredYAMLs = []
        }
        Self.migrateLegacyState(
            inProfileYAMLs: discoveredYAMLs,
            providers: &loadedProviders,
            providerRevisions: &initialRevisions,
            stagedProfileProviders: &loadedStaged,
            userConfirmedCustomIDs: loadedCustomIDs,
            migratedLegacyProviderIDs: &loadedMigratedIDs,
            directoryURL: dir,
            stagingBaseURL: resolvedStagingBaseURL,
            fileManager: fileManager
        )
        self.providers = loadedProviders
        self.providerRevisions = initialRevisions
        self.stagedProfileProviders = loadedStaged
        self.userConfirmedCustomIDs = loadedCustomIDs
        self.migratedLegacyProviderIDs = loadedMigratedIDs
    }

    nonisolated static func sanitizedHashedFileName(
        name: String,
        defaultStem: String,
        fileExtension: String,
        strippedExtensions: [String]
    ) -> String {
        var stemSource = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let loweredSource = stemSource.lowercased()
        for ext in strippedExtensions where loweredSource.hasSuffix(ext) && stemSource.count > ext.count {
            stemSource = String(stemSource.dropLast(ext.count))
            break
        }

        var mapped = ""
        mapped.reserveCapacity(min(stemSource.count, 48))
        var previousWasDash = false
        for scalar in stemSource.unicodeScalars {
            let isASCIIAlnum = (scalar.value >= 48 && scalar.value <= 57)
                || (scalar.value >= 65 && scalar.value <= 90)
                || (scalar.value >= 97 && scalar.value <= 122)
            let isUnderscore = scalar.value == 95
            if isASCIIAlnum || isUnderscore {
                mapped.append(contentsOf: String(scalar).lowercased())
                previousWasDash = false
            } else if !previousWasDash, !mapped.isEmpty {
                mapped.append("-")
                previousWasDash = true
            }
            if mapped.count >= 48 {
                break
            }
        }
        while mapped.hasPrefix("-") || mapped.hasPrefix(".") {
            mapped.removeFirst()
        }
        while mapped.hasSuffix("-") || mapped.hasSuffix(".") {
            mapped.removeLast()
        }
        let stem = mapped.isEmpty ? defaultStem : mapped
        let digest = SHA256.hash(data: Data(name.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        return "\(stem)-\(digest).\(fileExtension)"
    }

    nonisolated public static func sanitizedProviderFileName(name: String, format: RuleProviderFormat) -> String {
        sanitizedHashedFileName(
            name: name,
            defaultStem: "provider",
            fileExtension: format.fileExtension,
            strippedExtensions: [".yaml", ".yml", ".txt", ".mrs"]
        )
    }

    nonisolated static func legacySanitizedFileName(
        name: String,
        defaultStem: String,
        fileExtension: String,
        acceptedSuffixes: [String]
    ) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        if scalars.isEmpty {
            scalars = Array(defaultStem)
        }
        var base = String(scalars)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        if base.isEmpty {
            base = defaultStem
        }
        let lowered = base.lowercased()
        if acceptedSuffixes.contains(where: { lowered.hasSuffix($0) }) {
            return base
        }
        return "\(base).\(fileExtension)"
    }

    nonisolated static func legacySanitizedProviderFileName(name: String, format: RuleProviderFormat) -> String {
        let ext = format.fileExtension
        return legacySanitizedFileName(
            name: name,
            defaultStem: "provider",
            fileExtension: ext,
            acceptedSuffixes: [".\(ext)"]
        )
    }

    nonisolated static func inferFormat(specFormat: String, url: String, path: String) -> RuleProviderFormat {
        if specFormat == "mrs" || url.lowercased().hasSuffix(".mrs") || path.lowercased().hasSuffix(".mrs") {
            return .mrs
        }
        if specFormat == "text" || url.lowercased().hasSuffix(".txt") || path.lowercased().hasSuffix(".txt") {
            return .text
        }
        return .yaml
    }

    nonisolated static func isLegacySubscriptionPollutedEntry(
        _ entry: RuleProviderMetadata,
        userConfirmedCustomIDs: Set<UUID>,
        remoteSpecs: [DomesticRoutingOptimizer.RemoteRuleProviderSpec]
    ) -> Bool {
        guard !userConfirmedCustomIDs.contains(entry.id) else {
            return false
        }
        let normalizedTarget = entry.defaultTarget.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard entry.isEnabled, normalizedTarget == "PROXY" else {
            return false
        }
        if entry.format == .mrs {
            return true
        }
        return remoteSpecs.contains { spec in
            guard spec.type == "http", let specURL = URL(string: spec.url) else {
                return false
            }
            let specBehavior = RuleProviderBehavior(rawValue: spec.behavior) ?? .domain
            let specFormat = inferFormat(specFormat: spec.format, url: spec.url, path: spec.path)
            let specInterval = sanitizedIntervalSeconds(spec.interval)
            return spec.name == entry.name
                && specURL == entry.url
                && specBehavior == entry.behavior
                && specFormat == entry.format
                && specInterval == entry.intervalSeconds
        }
    }

    nonisolated public static func optionalDefaultDirectoryURL(fileManager: FileManager = .default) -> URL? {
        guard let appGroup = AppConstants.optionalIdentityValue(AppConstants.appGroupInfoKey),
              let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            return nil
        }
        return container.appendingPathComponent(
            "Library/Application Support/AetherRoute/RuleProviders",
            isDirectory: true
        )
    }

    nonisolated public static func sanitizedIntervalSeconds(
        _ raw: Int?,
        defaultValue: UInt32 = 86_400
    ) -> UInt32 {
        guard let raw, raw > 0, let exact = UInt32(exactly: raw) else {
            return defaultValue
        }
        return exact
    }

    public func stagedRuleFileURL(name: String, format: RuleProviderFormat) -> URL {
        stagingBaseURL
            .appendingPathComponent("providers/rules", isDirectory: true)
            .appendingPathComponent(Self.sanitizedProviderFileName(name: name, format: format), isDirectory: false)
    }

    // MARK: - URL Validation

    /// Validates that a provider URL uses `https`, or `http` strictly for loopback
    /// and private network hosts, rejecting public plaintext HTTP and non-HTTP schemes.
    nonisolated public static func validateURL(_ url: URL) throws {
        try ProviderURLValidator.validate(
            url,
            invalidURL: RuleProviderError.invalidURL,
            insecureScheme: RuleProviderError.insecureScheme
        )
    }

    nonisolated public static func defaultDirectoryURL(fileManager: FileManager = .default) -> URL {
        if let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) {
            return container.appendingPathComponent(
                "Library/Application Support/AetherRoute/RuleProviders",
                isDirectory: true
            )
        }
        return fileManager.temporaryDirectory.appendingPathComponent("RuleProviders", isDirectory: true)
    }

    // MARK: - Provider Registration
    public func registerProvider(_ provider: RuleProviderMetadata) throws {
        try Self.validateURL(provider.url)
        if let existing = providers[provider.id],
           existing.url != provider.url || existing.behavior != provider.behavior || existing.format != provider.format {
            providerRevisions[provider.id, default: 0] &+= 1
        }
        providers[provider.id] = provider
        if userConfirmedCustomIDs.insert(provider.id).inserted {
            saveUUIDSet(userConfirmedCustomIDs, to: customProviderIDsURL)
        }
        if migratedLegacyProviderIDs.remove(provider.id) != nil {
            saveUUIDSet(migratedLegacyProviderIDs, to: migratedLegacyProviderIDsURL)
        }
        saveProvidersMetadata()
    }

    public func removeProvider(id: UUID) {
        let removed = providers.removeValue(forKey: id)
        providerRevisions[id, default: 0] &+= 1
        saveProvidersMetadata()
        if userConfirmedCustomIDs.remove(id) != nil {
            saveUUIDSet(userConfirmedCustomIDs, to: customProviderIDsURL)
        }
        let cacheFile = cacheFileURL(for: id)
        try? fileManager.removeItem(at: cacheFile)
        if let removed {
            let stillReferenced = providers.values.contains { $0.name == removed.name && $0.format == removed.format }
                || stagedProfileProviders.values.contains { $0.name == removed.name && $0.format == removed.format }
            if !stillReferenced {
                Self.removeStagedFile(
                    relativeSubdirectory: "providers/rules",
                    fileName: Self.sanitizedProviderFileName(name: removed.name, format: removed.format),
                    stagingBaseURL: stagingBaseURL,
                    fileManager: fileManager
                )
            }
        }
    }

    public func allProviders() -> [RuleProviderMetadata] {
        Array(providers.values).sorted { $0.name < $1.name }
    }

    public func provider(id: UUID) -> RuleProviderMetadata? {
        providers[id]
    }

    @discardableResult
    public func toggleProvider(id: UUID) -> Bool {
        guard var p = providers[id] else { return false }
        p.isEnabled.toggle()
        providers[id] = p
        if userConfirmedCustomIDs.insert(id).inserted {
            saveUUIDSet(userConfirmedCustomIDs, to: customProviderIDsURL)
        }
        saveProvidersMetadata()
        return p.isEnabled
    }

    public func updateProviderMetadata(_ provider: RuleProviderMetadata) {
        if let existing = providers[provider.id],
           existing.url != provider.url || existing.behavior != provider.behavior || existing.format != provider.format {
            providerRevisions[provider.id, default: 0] &+= 1
        }
        providers[provider.id] = provider
        if userConfirmedCustomIDs.insert(provider.id).inserted {
            saveUUIDSet(userConfirmedCustomIDs, to: customProviderIDsURL)
        }
        saveProvidersMetadata()
    }

    // MARK: - Safety-Budgeted Rule Compilation
    nonisolated public static func cacheFileURL(for id: UUID, in directoryURL: URL) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).dat")
    }

    /// Reads cached `.dat` payloads for enabled rule providers synchronously so
    /// `ProfileOverrideCompiler` can inject active external rules into runtime YAML.
    nonisolated public static func compileCachedRules(
        for providers: [RuleProviderMetadata],
        cacheDirectoryURL: URL? = nil,
        maxRulesPerProvider: Int = 2_500,
        maxTotalRules: Int = 8_000,
        fileManager: FileManager = .default
    ) -> [String] {
        let directory = cacheDirectoryURL ?? defaultDirectoryURL(fileManager: fileManager)
        var compiledRules: [String] = []
        var seen = Set<String>()

        let activeProviders = providers
            .filter { $0.isEnabled && $0.format != .mrs }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for provider in activeProviders {
            let cacheFile = cacheFileURL(for: provider.id, in: directory)
            guard fileManager.fileExists(atPath: cacheFile.path),
                  let data = try? Data(contentsOf: cacheFile),
                  let content = String(data: data, encoding: .utf8) else {
                continue
            }

            let rules = parseRawRuleContent(content, behavior: provider.behavior, format: provider.format)
            guard !rules.isEmpty else { continue }

            let providerBudget = min(rules.count, maxRulesPerProvider)
            let defaultTarget = provider.defaultTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "PROXY"
                : provider.defaultTarget.trimmingCharacters(in: .whitespacesAndNewlines)

            for i in 0..<providerBudget {
                let item = rules[i]
                let target = item.target.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? defaultTarget
                    : item.target.trimmingCharacters(in: .whitespacesAndNewlines)

                var ruleString = "\(item.type),\(item.payload),\(target)"
                if item.noResolve && (
                    item.type == "IP-CIDR"
                    || item.type == "IP-CIDR6"
                    || item.type == "GEOIP"
                    || item.type == "IP-ASN"
                    || item.type == "SRC-IP-ASN"
                ) {
                    ruleString += ",no-resolve"
                }

                let norm = ruleString.filter { !$0.isWhitespace }.uppercased()
                if !seen.contains(norm) {
                    seen.insert(norm)
                    compiledRules.append(ruleString)
                    if compiledRules.count >= maxTotalRules {
                        logger.warning("Active rules reached safety ceiling of \(maxTotalRules) rules, truncating.")
                        return compiledRules
                    }
                }
            }
        }

        return compiledRules
    }

    /// Compiles all enabled rule providers into Clash rule strings, enforcing strict
    /// per-provider and global budgets to guarantee safe memory footprint.
    public func compileActiveRules(
        maxRulesPerProvider: Int = 2_500,
        maxTotalRules: Int = 8_000
    ) -> [String] {
        Self.compileCachedRules(
            for: Array(providers.values),
            cacheDirectoryURL: directoryURL,
            maxRulesPerProvider: maxRulesPerProvider,
            maxTotalRules: maxTotalRules,
            fileManager: fileManager
        )
    }

    // MARK: - Update Logic
    public func forceRefresh(id: UUID) async throws -> Int {
        guard providers[id] != nil else {
            throw RuleProviderError.providerNotFound
        }
        return try await fetchAndParse(providerID: id, kind: .custom, force: true)
    }

    public func updateIfNeeded(id: UUID) async throws -> Bool {
        guard let provider = providers[id] else {
            throw RuleProviderError.providerNotFound
        }

        if let lastUpdated = provider.lastUpdatedAt {
            let elapsed = Date().timeIntervalSince(lastUpdated)
            if elapsed < Double(provider.intervalSeconds) {
                return false
            }
        }

        _ = try await fetchAndParse(providerID: id, kind: .custom, force: false)
        return true
    }

    public func updateAllExpired() async -> [UUID: Result<Int, Error>] {
        var results = [UUID: Result<Int, Error>]()
        for (id, provider) in providers {
            let needsUpdate: Bool
            if let last = provider.lastUpdatedAt {
                needsUpdate = Date().timeIntervalSince(last) >= Double(provider.intervalSeconds)
            } else {
                needsUpdate = true
            }

            if needsUpdate {
                do {
                    let count = try await fetchAndParse(providerID: id, kind: .custom, force: false)
                    results[id] = .success(count)
                } catch {
                    results[id] = .failure(error)
                }
            }
        }
        return results
    }

    // MARK: - Rule Reading
    public func loadRawData(for id: UUID) -> Data? {
        let cacheFile = cacheFileURL(for: id)
        guard fileManager.fileExists(atPath: cacheFile.path) else {
            return nil
        }
        return try? Data(contentsOf: cacheFile)
    }

    public func loadRules(for id: UUID) throws -> [RemoteRuleItem] {
        if providers[id]?.format == .mrs {
            return []
        }
        let cacheFile = cacheFileURL(for: id)
        guard fileManager.fileExists(atPath: cacheFile.path) else {
            return []
        }
        let data = try Data(contentsOf: cacheFile)
        guard let content = String(data: data, encoding: .utf8) else {
            throw RuleProviderError.parsingFailed
        }
        guard let provider = providers[id] else {
            return parseRawRuleContent(content, behavior: .domain, format: .text)
        }
        return parseRawRuleContent(content, behavior: provider.behavior, format: provider.format)
    }

    public func searchRules(
        for id: UUID,
        query: String = "",
        limit: Int = 200
    ) throws -> [RemoteRuleItem] {
        let all = try loadRules(for: id)
        let cappedLimit = max(0, limit)
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return Array(all.prefix(cappedLimit))
        }
        var results: [RemoteRuleItem] = []
        results.reserveCapacity(min(all.count, cappedLimit))
        for item in all {
            if item.payload.localizedCaseInsensitiveContains(trimmed)
                || item.type.localizedCaseInsensitiveContains(trimmed)
                || item.target.localizedCaseInsensitiveContains(trimmed) {
                results.append(item)
                if results.count >= cappedLimit {
                    break
                }
            }
        }
        return results
    }

    // MARK: - Internal Download & Parse
    private func providerRecord(for id: UUID, kind: ProviderStoreKind) -> RuleProviderMetadata? {
        switch kind {
        case .custom: providers[id]
        case .stagedProfile: stagedProfileProviders[id]
        }
    }

    private func setProviderRecord(_ record: RuleProviderMetadata, for id: UUID, kind: ProviderStoreKind) {
        switch kind {
        case .custom:
            providers[id] = record
            saveProvidersMetadata()
        case .stagedProfile:
            stagedProfileProviders[id] = record
            saveStagedProvidersMetadata()
        }
    }

    private func revision(for id: UUID, kind: ProviderStoreKind) -> UInt64 {
        switch kind {
        case .custom: providerRevisions[id, default: 0]
        case .stagedProfile: stagedProviderRevisions[id, default: 0]
        }
    }

    private func activeSnapshot(
        id: UUID,
        kind: ProviderStoreKind,
        expectedRevision: UInt64,
        expectedSnapshot: RuleProviderMetadata
    ) throws -> RuleProviderMetadata {
        guard let current = providerRecord(for: id, kind: kind) else {
            throw RuleProviderError.providerNotFound
        }
        guard revision(for: id, kind: kind) == expectedRevision,
              current.url == expectedSnapshot.url,
              current.behavior == expectedSnapshot.behavior,
              current.format == expectedSnapshot.format else {
            throw CancellationError()
        }
        return current
    }

    private func fetchAndParse(providerID: UUID, kind: ProviderStoreKind, force: Bool) async throws -> Int {
        guard let snapshot = providerRecord(for: providerID, kind: kind) else {
            throw RuleProviderError.providerNotFound
        }
        let expectedRevision = revision(for: providerID, kind: kind)
        switch kind {
        case .custom:
            try Self.validateURL(snapshot.url)
        case .stagedProfile:
            try Self.validateUntrustedRemoteURL(snapshot.url)
        }
        var request = URLRequest(url: snapshot.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("AetherRoute/1.0", forHTTPHeaderField: "User-Agent")

        if !force, let etag = snapshot.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let maxBytes = snapshot.format == .mrs ? Self.maximumBinaryPayloadBytes : Self.maximumPayloadBytes
        let (data, response): (Data, URLResponse)
        do {
            if let httpFetcher {
                (data, response) = try await httpFetcher(snapshot.url)
            } else {
                (data, response) = try await ProviderSafeHTTPClient.fetch(
                    request: request,
                    maximumBytes: maxBytes,
                    allowInitialLocalTarget: kind == .custom,
                    invalidURLError: { RuleProviderError.invalidURL },
                    oversizedError: { RuleProviderError.oversizedPayload($0) }
                )
            }
        } catch let error as RuleProviderError {
            _ = try activeSnapshot(
                id: providerID,
                kind: kind,
                expectedRevision: expectedRevision,
                expectedSnapshot: snapshot
            )
            throw error
        } catch {
            _ = try activeSnapshot(
                id: providerID,
                kind: kind,
                expectedRevision: expectedRevision,
                expectedSnapshot: snapshot
            )
            throw RuleProviderError.downloadFailed(error.localizedDescription)
        }

        var current = try activeSnapshot(
            id: providerID,
            kind: kind,
            expectedRevision: expectedRevision,
            expectedSnapshot: snapshot
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuleProviderError.downloadFailed("Invalid HTTP response")
        }

        if httpResponse.statusCode == 304 {
            current.lastUpdatedAt = Date()
            setProviderRecord(current, for: providerID, kind: kind)
            return current.ruleCount
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw RuleProviderError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }

        let effectiveMaxBytes = current.format == .mrs ? Self.maximumBinaryPayloadBytes : Self.maximumPayloadBytes
        guard data.count <= effectiveMaxBytes else {
            throw RuleProviderError.oversizedPayload(data.count)
        }

        let ruleCount: Int
        if current.format == .mrs {
            guard !data.isEmpty else {
                throw RuleProviderError.parsingFailed
            }
            ruleCount = 0
        } else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw RuleProviderError.parsingFailed
            }
            let parsedRules = parseRawRuleContent(text, behavior: current.behavior, format: current.format)
            guard !parsedRules.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuleProviderError.parsingFailed
            }
            ruleCount = parsedRules.count
        }

        // Re-check actor state before committing any disk or metadata writes.
        current = try activeSnapshot(
            id: providerID,
            kind: kind,
            expectedRevision: expectedRevision,
            expectedSnapshot: snapshot
        )

        let cacheFile: URL = switch kind {
        case .custom: cacheFileURL(for: current.id)
        case .stagedProfile: stagedCacheFileURL(for: current.id)
        }
        try data.write(to: cacheFile, options: [.atomic])

        // Stage full snapshot (raw binary .mrs or un-truncated .yaml/.txt) for TUN & Transparent Proxy
        let stagedName = Self.sanitizedProviderFileName(name: current.name, format: current.format)
        try Self.stageFileData(
            data,
            relativeSubdirectory: "providers/rules",
            fileName: stagedName,
            stagingBaseURL: stagingBaseURL,
            fileManager: fileManager
        )

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        current.lastUpdatedAt = Date()
        current.ruleCount = ruleCount
        current.etag = httpResponse.value(forHTTPHeaderField: "ETag")
        current.sha256 = hash
        setProviderRecord(current, for: providerID, kind: kind)

        return ruleCount
    }

    nonisolated static func stagedFileURLs(
        relativeSubdirectory: String,
        fileName: String,
        stagingBaseURL: URL
    ) -> [URL] {
        [
            stagingBaseURL.appendingPathComponent(relativeSubdirectory, isDirectory: true),
            stagingBaseURL
                .appendingPathComponent("Runtime", isDirectory: true)
                .appendingPathComponent(relativeSubdirectory, isDirectory: true),
            stagingBaseURL
                .appendingPathComponent("Runtime/FlowCore", isDirectory: true)
                .appendingPathComponent(relativeSubdirectory, isDirectory: true),
        ].map { $0.appendingPathComponent(fileName, isDirectory: false) }
    }

    /// Stages a snapshot file into `<base>/<subdir>/<file>` and mirrors regular files
    /// (without symlinks) into `Runtime/` (TUN) and `Runtime/FlowCore/` (Transparent Proxy).
    @discardableResult
    public static func stageFileData(
        _ data: Data,
        relativeSubdirectory: String,
        fileName: String,
        stagingBaseURL: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let fileURLs = stagedFileURLs(
            relativeSubdirectory: relativeSubdirectory,
            fileName: fileName,
            stagingBaseURL: stagingBaseURL
        )
        for fileURL in fileURLs {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let existing = try? Data(contentsOf: fileURL), existing == data {
                continue
            }
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return fileURLs[0]
    }

    public static func removeStagedFile(
        relativeSubdirectory: String,
        fileName: String,
        stagingBaseURL: URL,
        fileManager: FileManager = .default
    ) {
        for fileURL in stagedFileURLs(
            relativeSubdirectory: relativeSubdirectory,
            fileName: fileName,
            stagingBaseURL: stagingBaseURL
        ) {
            try? fileManager.removeItem(at: fileURL)
        }
    }

    /// Reconciles legacy `providers.json` entries that originated from profile-level
    /// `rule-providers:` sections against the provided profile YAMLs without performing
    /// network fetches or touching user-confirmed custom global rule sets.
    public func reconcileLegacyProfileProviders(inProfileYAMLs yamls: [String]) {
        performLegacyMigration(inProfileYAMLs: yamls)
    }

    nonisolated public static func validateUntrustedRemoteURL(_ url: URL) throws {
        try ProviderURLValidator.validateUntrustedRemoteURL(
            url,
            invalidURL: RuleProviderError.invalidURL,
            insecureScheme: RuleProviderError.insecureScheme
        )
    }

    /// Returns previously staged remote `http` rule-providers declared inside a profile's YAML
    /// without mixing them into the user's global custom rule-providers list.
    public func stagedProviders(inProfileYAML yaml: String) -> [RuleProviderMetadata] {
        performLegacyMigration(inProfileYAMLs: [yaml])
        let specs = DomesticRoutingOptimizer.extractRemoteRuleProviders(from: yaml)
        var results: [RuleProviderMetadata] = []
        var seenIDs = Set<UUID>()
        for spec in specs {
            guard spec.type == "http",
                  let url = URL(string: spec.url),
                  (try? Self.validateUntrustedRemoteURL(url)) != nil else {
                continue
            }
            let match = stagedProfileProviders.values.first { $0.name == spec.name && $0.url == url }
            if let match, seenIDs.insert(match.id).inserted {
                results.append(match)
            }
        }
        return results
    }

    /// Stages all remote `http` rule-providers declared inside a profile's YAML into an isolated
    /// profile-provider store so subscription rules keep their original targets and ordering.
    @discardableResult
    public func stageProviders(inProfileYAML yaml: String, force: Bool = false) async -> [RuleProviderMetadata] {
        performLegacyMigration(inProfileYAMLs: [yaml])
        let specs = DomesticRoutingOptimizer.extractRemoteRuleProviders(from: yaml)
        var staged: [RuleProviderMetadata] = []
        for spec in specs {
            guard spec.type == "http",
                  let url = URL(string: spec.url),
                  (try? Self.validateUntrustedRemoteURL(url)) != nil else {
                continue
            }
            let format = Self.inferFormat(specFormat: spec.format, url: spec.url, path: spec.path)
            let behavior = RuleProviderBehavior(rawValue: spec.behavior) ?? .domain
            let existing = stagedProfileProviders.values.first { $0.name == spec.name && $0.url == url }
            var metadata = existing ?? RuleProviderMetadata(
                name: spec.name,
                url: url,
                behavior: behavior,
                format: format,
                intervalSeconds: Self.sanitizedIntervalSeconds(spec.interval)
            )
            let specChanged = metadata.url != url || metadata.behavior != behavior || metadata.format != format
            metadata.url = url
            metadata.behavior = behavior
            metadata.format = format
            if let interval = spec.interval, interval > 0, let valid = UInt32(exactly: interval) {
                metadata.intervalSeconds = valid
            }
            stagedProfileProviders[metadata.id] = metadata
            if specChanged {
                stagedProviderRevisions[metadata.id, default: 0] &+= 1
            }
            saveStagedProvidersMetadata()

            do {
                _ = try await fetchAndParse(providerID: metadata.id, kind: .stagedProfile, force: force)
                if let updated = stagedProfileProviders[metadata.id] {
                    staged.append(updated)
                }
            } catch {
                Self.logger.warning("Failed staging rule provider \(spec.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let current = stagedProfileProviders[metadata.id] {
                    staged.append(current)
                }
            }
        }
        return staged
    }

    public func parseRawRuleContent(
        _ content: String,
        behavior: RuleProviderBehavior,
        format: RuleProviderFormat
    ) -> [RemoteRuleItem] {
        Self.parseRawRuleContent(content, behavior: behavior, format: format)
    }

    nonisolated public static func parseRawRuleContent(
        _ content: String,
        behavior: RuleProviderBehavior,
        format: RuleProviderFormat
    ) -> [RemoteRuleItem] {
        var items: [RemoteRuleItem] = []
        let lines = content.components(separatedBy: .newlines)

        let hasExplicitPayload = (format == .yaml) && lines.contains {
            Self.stripInlineComment($0.trimmingCharacters(in: .whitespaces)).hasPrefix("payload:")
        }
        var inPayloadSection = !hasExplicitPayload

        for rawLine in lines {
            let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("//") {
                continue
            }

            let line = Self.stripInlineComment(trimmed)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("//") {
                continue
            }

            if format == .yaml, hasExplicitPayload {
                if line.hasPrefix("payload:") {
                    inPayloadSection = true
                    continue
                }
                guard inPayloadSection else { continue }
            }

            var clean = line
            if clean.hasPrefix("-") {
                clean = String(clean.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if clean.hasPrefix("'") && clean.hasSuffix("'") && clean.count >= 2 {
                clean = String(clean.dropFirst().dropLast())
            } else if clean.hasPrefix("\"") && clean.hasSuffix("\"") && clean.count >= 2 {
                clean = String(clean.dropFirst().dropLast())
            }
            clean = clean.trimmingCharacters(in: .whitespacesAndNewlines)

            guard !clean.isEmpty else { continue }

            let parts = Self.splitRuleTopLevelCommas(clean)
            if parts.isEmpty { continue }

            if behavior == .domain {
                if parts.count == 1 {
                    let token = parts[0]
                    if token.hasPrefix("+.") || token.hasPrefix("*.") || token.hasPrefix(".") {
                        let domain = Self.normalizeDomainSuffixPayload(token)
                        guard !domain.isEmpty else { continue }
                        items.append(RemoteRuleItem(type: "DOMAIN-SUFFIX", payload: domain))
                    } else {
                        items.append(RemoteRuleItem(type: "DOMAIN", payload: token))
                    }
                } else if parts.count >= 2 {
                    let type = parts[0].uppercased()
                    let payload = type == "DOMAIN-SUFFIX"
                        ? Self.normalizeDomainSuffixPayload(parts[1])
                        : parts[1]
                    guard !payload.isEmpty else { continue }
                    let target = parts.count >= 3 ? parts[2] : ""
                    items.append(RemoteRuleItem(type: type, payload: payload, target: target))
                }
            } else if behavior == .ipcidr {
                var remainingParts = parts
                if remainingParts.count >= 2,
                   let prefix = remainingParts.first?.uppercased(),
                   prefix == "IP-CIDR" || prefix == "IP-CIDR6" {
                    remainingParts.removeFirst()
                }
                guard let payload = remainingParts.first, !payload.isEmpty else { continue }
                let ruleType = payload.contains(":") ? "IP-CIDR6" : "IP-CIDR"
                let target = remainingParts.dropFirst().first(where: { $0.lowercased() != "no-resolve" }) ?? ""
                items.append(RemoteRuleItem(type: ruleType, payload: payload, target: target, noResolve: true))
            } else {
                let type = parts[0].uppercased()
                let payload = parts.count >= 2 ? parts[1] : ""
                let noResolve = parts.contains(where: { $0.lowercased() == "no-resolve" })
                let target = parts.count >= 3 && parts[2].lowercased() != "no-resolve" ? parts[2] : ""
                items.append(RemoteRuleItem(type: type, payload: payload, target: target, noResolve: noResolve))
            }
        }

        return items
    }

    private static func splitRuleTopLevelCommas(_ line: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var parenDepth = 0
        var quote: Character?
        for ch in line {
            if let active = quote {
                if ch == active { quote = nil }
                current.append(ch)
                continue
            }
            if ch == "'" || ch == "\"" {
                quote = ch
                current.append(ch)
                continue
            }
            if ch == "(" {
                parenDepth += 1
                current.append(ch)
                continue
            }
            if ch == ")" {
                parenDepth = max(0, parenDepth - 1)
                current.append(ch)
                continue
            }
            if ch == "," && parenDepth == 0 {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    parts.append(trimmed)
                }
                current.removeAll(keepingCapacity: true)
                continue
            }
            current.append(ch)
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            parts.append(tail)
        }
        return parts
    }

    private static func normalizeDomainSuffixPayload(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("+.") || value.hasPrefix("*.") {
            value = String(value.dropFirst(2))
        } else if value.hasPrefix(".") {
            value = String(value.dropFirst(1))
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stripInlineComment(_ line: String) -> String {
        var inSingleQuote = false
        var inDoubleQuote = false
        var previousWasWhitespace = true
        for idx in line.indices {
            let ch = line[idx]
            if ch == "'" && !inDoubleQuote {
                inSingleQuote.toggle()
            } else if ch == "\"" && !inSingleQuote {
                inDoubleQuote.toggle()
            } else if ch == "#" && !inSingleQuote && !inDoubleQuote && previousWasWhitespace {
                return String(line[..<idx]).trimmingCharacters(in: .whitespaces)
            }
            previousWasWhitespace = ch.isWhitespace
        }
        return line.trimmingCharacters(in: .whitespaces)
    }

    private func cacheFileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).dat")
    }

    private func stagedCacheFileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).staged.dat")
    }

    private var metadataURL: URL {
        directoryURL.appendingPathComponent("providers.json")
    }

    private var stagedMetadataURL: URL {
        directoryURL.appendingPathComponent("staged-profile-providers.json")
    }

    private var customProviderIDsURL: URL {
        directoryURL.appendingPathComponent(Self.customProviderIDsFilename)
    }

    private var migratedLegacyProviderIDsURL: URL {
        directoryURL.appendingPathComponent(Self.migratedLegacyProviderIDsFilename)
    }

    nonisolated static func loadUUIDSet(fileManager: FileManager, url: URL) -> Set<UUID> {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([UUID].self, from: data) else {
            return []
        }
        return Set(decoded)
    }

    private func saveUUIDSet(_ set: Set<UUID>, to url: URL) {
        let sorted = set.map(\.uuidString).sorted()
        if let encoded = try? JSONEncoder().encode(sorted) {
            try? encoded.write(to: url, options: [.atomic])
        }
    }

    private nonisolated static func discoverProfileYAMLs(in stagingBaseURL: URL, fileManager: FileManager) -> [String] {
        var yamls: [String] = []
        let debugRawURL = stagingBaseURL.appendingPathComponent("debug_profile_raw.yaml", isDirectory: false)
        if fileManager.fileExists(atPath: debugRawURL.path),
           let raw = try? String(contentsOf: debugRawURL, encoding: .utf8),
           !raw.isEmpty {
            yamls.append(raw)
        }
        return yamls
    }

    private func performLegacyMigration(inProfileYAMLs yamls: [String]) {
        Self.migrateLegacyState(
            inProfileYAMLs: yamls,
            providers: &providers,
            providerRevisions: &providerRevisions,
            stagedProfileProviders: &stagedProfileProviders,
            userConfirmedCustomIDs: userConfirmedCustomIDs,
            migratedLegacyProviderIDs: &migratedLegacyProviderIDs,
            directoryURL: directoryURL,
            stagingBaseURL: stagingBaseURL,
            fileManager: fileManager
        )
    }

    private nonisolated static func migrateLegacyState(
        inProfileYAMLs yamls: [String],
        providers: inout [UUID: RuleProviderMetadata],
        providerRevisions: inout [UUID: UInt64],
        stagedProfileProviders: inout [UUID: RuleProviderMetadata],
        userConfirmedCustomIDs: Set<UUID>,
        migratedLegacyProviderIDs: inout Set<UUID>,
        directoryURL: URL,
        stagingBaseURL: URL,
        fileManager: FileManager
    ) {
        var remoteSpecs: [DomesticRoutingOptimizer.RemoteRuleProviderSpec] = []
        for yaml in yamls where !yaml.isEmpty {
            remoteSpecs.append(contentsOf: DomesticRoutingOptimizer.extractRemoteRuleProviders(from: yaml))
        }

        var providersChanged = false
        var stagedChanged = false
        var migratedIDsChanged = false

        let legacyEntries = providers.values.filter {
            isLegacySubscriptionPollutedEntry(
                $0,
                userConfirmedCustomIDs: userConfirmedCustomIDs,
                remoteSpecs: remoteSpecs
            )
        }

        for entry in legacyEntries {
            providers.removeValue(forKey: entry.id)
            providerRevisions[entry.id, default: 0] &+= 1
            providersChanged = true

            if migratedLegacyProviderIDs.insert(entry.id).inserted {
                migratedIDsChanged = true
            }

            let legacyCacheFile = cacheFileURL(for: entry.id, in: directoryURL)
            let legacyData = try? Data(contentsOf: legacyCacheFile)

            let existingStaged = stagedProfileProviders.values.first { $0.name == entry.name && $0.url == entry.url }
            let targetID = existingStaged?.id ?? entry.id
            if var currentStaged = existingStaged {
                let entryDate = entry.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                let stagedDate = currentStaged.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                if stagedDate == 0 || entryDate > stagedDate {
                    currentStaged.behavior = entry.behavior
                    currentStaged.format = entry.format
                    currentStaged.intervalSeconds = entry.intervalSeconds
                    currentStaged.lastUpdatedAt = entry.lastUpdatedAt ?? currentStaged.lastUpdatedAt
                    currentStaged.ruleCount = max(currentStaged.ruleCount, entry.ruleCount)
                    currentStaged.etag = entry.etag ?? currentStaged.etag
                    currentStaged.sha256 = entry.sha256 ?? currentStaged.sha256
                    stagedProfileProviders[targetID] = currentStaged
                    stagedChanged = true
                }
            } else {
                stagedProfileProviders[targetID] = entry
                stagedChanged = true
            }

            let targetStagedCache = directoryURL.appendingPathComponent("\(targetID.uuidString).staged.dat")
            if let legacyData, !fileManager.fileExists(atPath: targetStagedCache.path) {
                try? legacyData.write(to: targetStagedCache, options: [.atomic])
            }
            if fileManager.fileExists(atPath: legacyCacheFile.path) {
                try? fileManager.removeItem(at: legacyCacheFile)
            }
        }

        if providersChanged {
            if let encoded = try? JSONEncoder().encode(Array(providers.values)) {
                try? encoded.write(to: directoryURL.appendingPathComponent("providers.json"), options: [.atomic])
            }
        }
        if stagedChanged {
            if let encoded = try? JSONEncoder().encode(Array(stagedProfileProviders.values)) {
                try? encoded.write(to: directoryURL.appendingPathComponent("staged-profile-providers.json"), options: [.atomic])
            }
        }
        if migratedIDsChanged {
            let sorted = migratedLegacyProviderIDs.map(\.uuidString).sorted()
            if let encoded = try? JSONEncoder().encode(sorted) {
                try? encoded.write(to: directoryURL.appendingPathComponent(migratedLegacyProviderIDsFilename), options: [.atomic])
            }
        }

        let rulesStagingDir = stagingBaseURL.appendingPathComponent("providers/rules", isDirectory: true)

        // Re-stage cached snapshots under hashed filenames and remove legacy unhashed copies.
        for stagedEntry in stagedProfileProviders.values {
            let stagedName = sanitizedProviderFileName(name: stagedEntry.name, format: stagedEntry.format)
            let stagedURL = rulesStagingDir.appendingPathComponent(stagedName, isDirectory: false)
            let cacheURL = directoryURL.appendingPathComponent("\(stagedEntry.id.uuidString).staged.dat")
            if !fileManager.fileExists(atPath: stagedURL.path),
               let data = try? Data(contentsOf: cacheURL),
               !data.isEmpty {
                _ = try? stageFileData(
                    data,
                    relativeSubdirectory: "providers/rules",
                    fileName: stagedName,
                    stagingBaseURL: stagingBaseURL,
                    fileManager: fileManager
                )
            }
            let legacyFileName = legacySanitizedProviderFileName(name: stagedEntry.name, format: stagedEntry.format)
            if legacyFileName != stagedName {
                removeStagedFile(
                    relativeSubdirectory: "providers/rules",
                    fileName: legacyFileName,
                    stagingBaseURL: stagingBaseURL,
                    fileManager: fileManager
                )
            }
        }

        for entry in providers.values {
            let hashedName = sanitizedProviderFileName(name: entry.name, format: entry.format)
            let legacyName = legacySanitizedProviderFileName(name: entry.name, format: entry.format)
            guard legacyName != hashedName else { continue }
            let existingLegacy = stagedFileURLs(
                relativeSubdirectory: "providers/rules",
                fileName: legacyName,
                stagingBaseURL: stagingBaseURL
            ).contains { fileManager.fileExists(atPath: $0.path) }
            guard existingLegacy else { continue }
            let hashedURL = rulesStagingDir.appendingPathComponent(hashedName, isDirectory: false)
            if !fileManager.fileExists(atPath: hashedURL.path),
               let data = try? Data(contentsOf: cacheFileURL(for: entry.id, in: directoryURL)),
               !data.isEmpty {
                _ = try? stageFileData(
                    data,
                    relativeSubdirectory: "providers/rules",
                    fileName: hashedName,
                    stagingBaseURL: stagingBaseURL,
                    fileManager: fileManager
                )
            }
            removeStagedFile(
                relativeSubdirectory: "providers/rules",
                fileName: legacyName,
                stagingBaseURL: stagingBaseURL,
                fileManager: fileManager
            )
        }
    }

    private static func loadProvidersMetadata(fileManager: FileManager, metadataURL: URL) -> [UUID: RuleProviderMetadata] {
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([RuleProviderMetadata].self, from: data) else {
            return [:]
        }
        var map = [UUID: RuleProviderMetadata]()
        for item in decoded {
            map[item.id] = item
        }
        return map
    }

    private func saveProvidersMetadata() {
        let list = Array(providers.values)
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: metadataURL, options: [.atomic])
        }
    }

    private func saveStagedProvidersMetadata() {
        let list = Array(stagedProfileProviders.values)
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: stagedMetadataURL, options: [.atomic])
        }
    }

    // MARK: - Cloud Sync
    /// Exports current providers metadata for iCloud synchronization. When a 32-byte
    /// `encryptionKey` is supplied, the payload is sealed inside an AES-256-GCM
    /// `CloudSyncPayload` envelope so provider URLs and names are never stored in plaintext in KVS.
    public func exportCloudSyncPayload(
        deviceIdentifier: String,
        encryptionKey: Data? = nil
    ) -> Data? {
        let list = allProviders()
        let payload = RuleProviderSyncPayload(deviceIdentifier: deviceIdentifier, providers: list)
        guard let plaintext = try? JSONEncoder().encode(payload) else {
            return nil
        }
        guard let encryptionKey, encryptionKey.count == 32 else {
            return plaintext
        }
        let symmetricKey = SymmetricKey(data: encryptionKey)
        guard let sealed = try? AES.GCM.seal(plaintext, using: symmetricKey),
              let combined = sealed.combined else {
            return nil
        }
        let sha256 = SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
        let envelope = CloudSyncPayload(
            deviceIdentifier: deviceIdentifier,
            encryptedData: combined,
            sha256: sha256
        )
        return try? JSONEncoder().encode(envelope)
    }

    /// Merges remote providers from iCloud sync into local storage,
    /// reconciling duplicates by ID or URL based on update timestamps.
    @discardableResult
    public func mergeCloudSyncPayload(
        _ data: Data,
        encryptionKey: Data? = nil,
        fallbackKey: Data? = nil
    ) -> [RuleProviderMetadata] {
        mergeCloudSyncPayloadOutcome(
            data,
            encryptionKey: encryptionKey,
            fallbackKey: fallbackKey
        ).providers
    }

    public struct CloudSyncMergeOutcome: Sendable, Equatable {
        public let providers: [RuleProviderMetadata]
        public let didChangeLocal: Bool
        public let matchesRemote: Bool
        public let wasEncrypted: Bool

        public init(
            providers: [RuleProviderMetadata],
            didChangeLocal: Bool,
            matchesRemote: Bool,
            wasEncrypted: Bool = true
        ) {
            self.providers = providers
            self.didChangeLocal = didChangeLocal
            self.matchesRemote = matchesRemote
            self.wasEncrypted = wasEncrypted
        }
    }

    private func isMigratedLegacyRemoteProvider(_ remote: RuleProviderMetadata) -> Bool {
        if migratedLegacyProviderIDs.contains(remote.id) {
            return true
        }
        guard !userConfirmedCustomIDs.contains(remote.id),
              remote.isEnabled,
              remote.defaultTarget.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PROXY" else {
            return false
        }
        return stagedProfileProviders.values.contains { $0.name == remote.name && $0.url == remote.url }
    }

    private static func decodeCloudSyncRuleProviders(
        _ data: Data,
        encryptionKey: Data?,
        fallbackKey: Data?
    ) -> (payload: RuleProviderSyncPayload, wasEncrypted: Bool)? {
        if let envelope = try? JSONDecoder().decode(CloudSyncPayload.self, from: data) {
            let actualSHA = SHA256.hash(data: envelope.encryptedData).map { String(format: "%02x", $0) }.joined()
            guard actualSHA.caseInsensitiveCompare(envelope.sha256) == .orderedSame,
                  let box = try? AES.GCM.SealedBox(combined: envelope.encryptedData) else {
                return nil
            }
            for candidateKey in [encryptionKey, fallbackKey].compactMap({ $0 }) where candidateKey.count == 32 {
                if let opened = try? AES.GCM.open(box, using: SymmetricKey(data: candidateKey)),
                   let decoded = try? JSONDecoder().decode(RuleProviderSyncPayload.self, from: opened) {
                    return (decoded, true)
                }
            }
            return nil
        }
        // Backward-compatible read fallback for legacy unencrypted KVS payloads.
        if let legacy = try? JSONDecoder().decode(RuleProviderSyncPayload.self, from: data) {
            return (legacy, false)
        }
        return nil
    }

    public func mergeCloudSyncPayloadOutcome(
        _ data: Data,
        encryptionKey: Data? = nil,
        fallbackKey: Data? = nil
    ) -> CloudSyncMergeOutcome {
        guard let (payload, wasEncrypted) = Self.decodeCloudSyncRuleProviders(
            data,
            encryptionKey: encryptionKey,
            fallbackKey: fallbackKey
        ) else {
            let current = allProviders()
            return CloudSyncMergeOutcome(
                providers: current,
                didChangeLocal: false,
                matchesRemote: true,
                wasEncrypted: true
            )
        }

        var changed = false
        for remote in payload.providers {
            guard (try? Self.validateURL(remote.url)) != nil else {
                continue
            }
            if isMigratedLegacyRemoteProvider(remote) {
                continue
            }
            if let existing = providers[remote.id] {
                let existingTime = existing.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                let remoteTime = remote.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                if remoteTime >= existingTime && remote != existing {
                    if existing.url != remote.url || existing.behavior != remote.behavior || existing.format != remote.format {
                        providerRevisions[remote.id, default: 0] &+= 1
                    }
                    providers[remote.id] = remote
                    changed = true
                }
            } else if let matchByURL = providers.values.first(where: { $0.url == remote.url }) {
                let existingTime = matchByURL.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                let remoteTime = remote.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                // Deterministic UUID tie-breaker when both devices registered the same URL
                // with identical (or nil) timestamps, preventing infinite KVS ping-pong.
                let remoteWins = remoteTime != existingTime
                    ? (remoteTime > existingTime)
                    : (remote.id.uuidString < matchByURL.id.uuidString)
                if remoteWins {
                    providers.removeValue(forKey: matchByURL.id)
                    providerRevisions[matchByURL.id, default: 0] &+= 1
                    providerRevisions[remote.id, default: 0] &+= 1
                    providers[remote.id] = remote
                    changed = true
                }
            } else {
                providers[remote.id] = remote
                changed = true
            }
        }

        if changed {
            saveProvidersMetadata()
        }
        let merged = allProviders()
        let remoteByID = Dictionary(payload.providers.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let localByID = Dictionary(merged.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        return CloudSyncMergeOutcome(
            providers: merged,
            didChangeLocal: changed,
            matchesRemote: wasEncrypted && (localByID == remoteByID),
            wasEncrypted: wasEncrypted
        )
    }
}

public struct RuleProviderSyncPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let storageKey = "aetherroute.rule_providers.sync.v1"

    public let version: Int
    public let updatedAtUnixMilliseconds: UInt64
    public let deviceIdentifier: String
    public let providers: [RuleProviderMetadata]

    public init(
        version: Int = Self.currentVersion,
        updatedAtUnixMilliseconds: UInt64 = UInt64(max(0, Int64(Date().timeIntervalSince1970 * 1000))),
        deviceIdentifier: String = UUID().uuidString,
        providers: [RuleProviderMetadata]
    ) {
        self.version = version
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
        self.deviceIdentifier = deviceIdentifier
        self.providers = providers
    }
}

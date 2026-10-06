import CryptoKit
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
    public static let shared = RuleProviderEngine()

    public static let maximumPayloadBytes = 5 * 1_024 * 1_024 // 5MB max bound
    private static let logger = AppLog.logger(category: "kit.rule-providers")

    private let fileManager: FileManager
    private let directoryURL: URL
    private var providers: [UUID: RuleProviderMetadata] = [:]

    public init(fileManager: FileManager = .default, directoryURL: URL? = nil) {
        self.fileManager = fileManager
        let dir: URL
        if let customDir = directoryURL {
            dir = customDir
        } else if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup) {
            dir = container.appendingPathComponent("Library/Application Support/AetherRoute/RuleProviders", isDirectory: true)
        } else {
            dir = fileManager.temporaryDirectory.appendingPathComponent("RuleProviders", isDirectory: true)
        }
        self.directoryURL = dir

        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let metaURL = dir.appendingPathComponent("providers.json")
        self.providers = Self.loadProvidersMetadata(fileManager: fileManager, metadataURL: metaURL)
    }

    // MARK: - Provider Registration
    public func registerProvider(_ provider: RuleProviderMetadata) throws {
        guard provider.url.scheme?.lowercased() == "https" else {
            throw RuleProviderError.insecureScheme
        }
        providers[provider.id] = provider
        saveProvidersMetadata()
    }

    public func removeProvider(id: UUID) {
        providers.removeValue(forKey: id)
        saveProvidersMetadata()
        let cacheFile = cacheFileURL(for: id)
        try? fileManager.removeItem(at: cacheFile)
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
        saveProvidersMetadata()
        return p.isEnabled
    }

    public func updateProviderMetadata(_ provider: RuleProviderMetadata) {
        providers[provider.id] = provider
        saveProvidersMetadata()
    }

    // MARK: - Safety-Budgeted Rule Compilation
    /// Compiles all enabled rule providers into Clash rule strings, enforcing strict
    /// per-provider and global budgets to guarantee safe memory footprint.
    public func compileActiveRules(
        maxRulesPerProvider: Int = 2_500,
        maxTotalRules: Int = 8_000
    ) -> [String] {
        var compiledRules: [String] = []
        var seen = Set<String>()

        let activeProviders = providers.values
            .filter { $0.isEnabled }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for provider in activeProviders {
            guard let rules = try? loadRules(for: provider.id), !rules.isEmpty else {
                continue
            }

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
                if item.noResolve && (item.type == "IP-CIDR" || item.type == "IP-CIDR6" || item.type == "GEOIP") {
                    ruleString += ",no-resolve"
                }

                let norm = ruleString.filter { !$0.isWhitespace }.uppercased()
                if !seen.contains(norm) {
                    seen.insert(norm)
                    compiledRules.append(ruleString)
                    if compiledRules.count >= maxTotalRules {
                        Self.logger.warning("Active rules reached safety ceiling of \(maxTotalRules) rules, truncating.")
                        return compiledRules
                    }
                }
            }
        }

        return compiledRules
    }

    // MARK: - Update Logic
    public func forceRefresh(id: UUID) async throws -> Int {
        guard let provider = providers[id] else {
            throw RuleProviderError.providerNotFound
        }
        return try await fetchAndParse(provider: provider, force: true)
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

        _ = try await fetchAndParse(provider: provider, force: false)
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
                    let count = try await fetchAndParse(provider: provider, force: false)
                    results[id] = .success(count)
                } catch {
                    results[id] = .failure(error)
                }
            }
        }
        return results
    }

    // MARK: - Rule Reading
    public func loadRules(for id: UUID) throws -> [RemoteRuleItem] {
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

    // MARK: - Internal Download & Parse
    private func fetchAndParse(provider: RuleProviderMetadata, force: Bool) async throws -> Int {
        var request = URLRequest(url: provider.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("AetherRoute/1.0", forHTTPHeaderField: "User-Agent")

        if !force, let etag = provider.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RuleProviderError.downloadFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw RuleProviderError.downloadFailed("Invalid HTTP response")
        }

        if httpResponse.statusCode == 304 {
            var updated = provider
            updated.lastUpdatedAt = Date()
            providers[provider.id] = updated
            saveProvidersMetadata()
            return provider.ruleCount
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            throw RuleProviderError.downloadFailed("HTTP \(httpResponse.statusCode)")
        }

        guard data.count <= Self.maximumPayloadBytes else {
            throw RuleProviderError.oversizedPayload(data.count)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw RuleProviderError.parsingFailed
        }

        let parsedRules = parseRawRuleContent(text, behavior: provider.behavior, format: provider.format)
        guard !parsedRules.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RuleProviderError.parsingFailed
        }

        // Save cache to disk
        let cacheFile = cacheFileURL(for: provider.id)
        try data.write(to: cacheFile, options: [.atomic])

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var updated = provider
        updated.lastUpdatedAt = Date()
        updated.ruleCount = parsedRules.count
        updated.etag = httpResponse.value(forHTTPHeaderField: "ETag")
        updated.sha256 = hash
        providers[provider.id] = updated
        saveProvidersMetadata()

        return parsedRules.count
    }

    public func parseRawRuleContent(
        _ content: String,
        behavior: RuleProviderBehavior,
        format: RuleProviderFormat
    ) -> [RemoteRuleItem] {
        var items: [RemoteRuleItem] = []
        let lines = content.components(separatedBy: .newlines)

        let hasExplicitPayload = (format == .yaml) && lines.contains { $0.trimmingCharacters(in: .whitespaces).hasPrefix("payload:") }
        var inPayloadSection = !hasExplicitPayload

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
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

            guard !clean.isEmpty else { continue }

            let parts = clean.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.isEmpty { continue }

            if behavior == .domain {
                if parts.count == 1 {
                    items.append(RemoteRuleItem(type: "DOMAIN-SUFFIX", payload: parts[0]))
                } else if parts.count >= 2 {
                    let type = parts[0].uppercased()
                    let payload = parts[1]
                    let target = parts.count >= 3 ? parts[2] : ""
                    items.append(RemoteRuleItem(type: type, payload: payload, target: target))
                }
            } else if behavior == .ipcidr {
                let payload = parts[0]
                let noResolve = parts.contains(where: { $0.lowercased() == "no-resolve" })
                let target = parts.count >= 2 && parts[1].lowercased() != "no-resolve" ? parts[1] : ""
                items.append(RemoteRuleItem(type: "IP-CIDR", payload: payload, target: target, noResolve: noResolve))
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

    private func cacheFileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).dat")
    }

    private var metadataURL: URL {
        directoryURL.appendingPathComponent("providers.json")
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

    // MARK: - Cloud Sync
    /// Exports current providers metadata for lightweight iCloud synchronization.
    public func exportCloudSyncPayload(deviceIdentifier: String) -> Data? {
        let list = allProviders()
        let payload = RuleProviderSyncPayload(deviceIdentifier: deviceIdentifier, providers: list)
        return try? JSONEncoder().encode(payload)
    }

    /// Merges remote providers from iCloud sync into local storage,
    /// reconciling duplicates by ID or URL based on update timestamps.
    @discardableResult
    public func mergeCloudSyncPayload(_ data: Data) -> [RuleProviderMetadata] {
        guard let payload = try? JSONDecoder().decode(RuleProviderSyncPayload.self, from: data) else {
            return allProviders()
        }

        var changed = false
        for remote in payload.providers {
            if let existing = providers[remote.id] {
                let existingTime = existing.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                let remoteTime = remote.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                if remoteTime >= existingTime && remote != existing {
                    providers[remote.id] = remote
                    changed = true
                }
            } else if let matchByURL = providers.values.first(where: { $0.url == remote.url }) {
                let existingTime = matchByURL.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                let remoteTime = remote.lastUpdatedAt?.timeIntervalSince1970 ?? 0
                if remoteTime > existingTime {
                    providers.removeValue(forKey: matchByURL.id)
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
        return allProviders()
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

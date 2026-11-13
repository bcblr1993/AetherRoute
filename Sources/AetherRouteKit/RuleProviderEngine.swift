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
    private static let logger = AppLog.logger(category: "kit.rule-providers")

    private let fileManager: FileManager
    private let directoryURL: URL
    private let stagingBaseURL: URL
    private let httpFetcher: HTTPFetcher?
    private var providers: [UUID: RuleProviderMetadata] = [:]

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
        } else if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup) {
            dir = container.appendingPathComponent("Library/Application Support/AetherRoute/RuleProviders", isDirectory: true)
        } else {
            dir = fileManager.temporaryDirectory.appendingPathComponent("RuleProviders", isDirectory: true)
        }
        self.directoryURL = dir
        if let stagingBaseURL {
            self.stagingBaseURL = stagingBaseURL
        } else if directoryURL != nil {
            self.stagingBaseURL = dir.deletingLastPathComponent()
        } else if let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: AppConstants.appGroup) {
            self.stagingBaseURL = container.appendingPathComponent("Library/Application Support/AetherRoute", isDirectory: true)
        } else {
            self.stagingBaseURL = dir.deletingLastPathComponent()
        }
        self.httpFetcher = httpFetcher

        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let metaURL = dir.appendingPathComponent("providers.json")
        self.providers = Self.loadProvidersMetadata(fileManager: fileManager, metadataURL: metaURL)
    }

    public static func sanitizedProviderFileName(name: String, format: RuleProviderFormat) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        if scalars.isEmpty {
            scalars = Array("provider")
        }
        var base = String(scalars)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        if base.isEmpty {
            base = "provider"
        }
        let ext = format.fileExtension
        if base.lowercased().hasSuffix(".\(ext)") {
            return base
        }
        return "\(base).\(ext)"
    }

    public func stagedRuleFileURL(name: String, format: RuleProviderFormat) -> URL {
        stagingBaseURL
            .appendingPathComponent("providers/rules", isDirectory: true)
            .appendingPathComponent(Self.sanitizedProviderFileName(name: name, format: format), isDirectory: false)
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
            if let httpFetcher {
                (data, response) = try await httpFetcher(provider.url)
            } else {
                (data, response) = try await URLSession.shared.data(for: request)
            }
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

        let maxBytes = provider.format == .mrs ? Self.maximumBinaryPayloadBytes : Self.maximumPayloadBytes
        guard data.count <= maxBytes else {
            throw RuleProviderError.oversizedPayload(data.count)
        }

        let ruleCount: Int
        if provider.format == .mrs {
            guard !data.isEmpty else {
                throw RuleProviderError.parsingFailed
            }
            ruleCount = 0
        } else {
            guard let text = String(data: data, encoding: .utf8) else {
                throw RuleProviderError.parsingFailed
            }
            let parsedRules = parseRawRuleContent(text, behavior: provider.behavior, format: provider.format)
            guard !parsedRules.isEmpty || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RuleProviderError.parsingFailed
            }
            ruleCount = parsedRules.count
        }

        // Save cache to disk
        let cacheFile = cacheFileURL(for: provider.id)
        try data.write(to: cacheFile, options: [.atomic])

        // Stage full snapshot (raw binary .mrs or un-truncated .yaml/.txt) for TUN & Transparent Proxy
        let stagedName = Self.sanitizedProviderFileName(name: provider.name, format: provider.format)
        try Self.stageFileData(
            data,
            relativeSubdirectory: "providers/rules",
            fileName: stagedName,
            stagingBaseURL: stagingBaseURL,
            fileManager: fileManager
        )

        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        var updated = provider
        updated.lastUpdatedAt = Date()
        updated.ruleCount = ruleCount
        updated.etag = httpResponse.value(forHTTPHeaderField: "ETag")
        updated.sha256 = hash
        providers[provider.id] = updated
        saveProvidersMetadata()

        return ruleCount
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
        let primaryDir = stagingBaseURL.appendingPathComponent(relativeSubdirectory, isDirectory: true)
        let tunDir = stagingBaseURL
            .appendingPathComponent("Runtime", isDirectory: true)
            .appendingPathComponent(relativeSubdirectory, isDirectory: true)
        let flowDir = stagingBaseURL
            .appendingPathComponent("Runtime/FlowCore", isDirectory: true)
            .appendingPathComponent(relativeSubdirectory, isDirectory: true)

        let destinations = [primaryDir, tunDir, flowDir]
        for dir in destinations {
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
            let fileURL = dir.appendingPathComponent(fileName, isDirectory: false)
            if let existing = try? Data(contentsOf: fileURL), existing == data {
                continue
            }
            try data.write(to: fileURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        }
        return primaryDir.appendingPathComponent(fileName, isDirectory: false)
    }

    /// Stages all remote `http` rule-providers declared inside a profile's YAML.
    @discardableResult
    public func stageProviders(inProfileYAML yaml: String, force: Bool = false) async -> [RuleProviderMetadata] {
        let specs = DomesticRoutingOptimizer.extractRemoteRuleProviders(from: yaml)
        var staged: [RuleProviderMetadata] = []
        for spec in specs {
            guard spec.type == "http",
                  let url = URL(string: spec.url),
                  url.scheme?.lowercased() == "https" else {
                continue
            }
            let format: RuleProviderFormat
            if spec.format == "mrs" || spec.url.lowercased().hasSuffix(".mrs") || spec.path.lowercased().hasSuffix(".mrs") {
                format = .mrs
            } else if spec.format == "text" || spec.url.lowercased().hasSuffix(".txt") || spec.path.lowercased().hasSuffix(".txt") {
                format = .text
            } else {
                format = .yaml
            }
            let behavior = RuleProviderBehavior(rawValue: spec.behavior) ?? .domain
            let existing = providers.values.first { $0.name == spec.name && $0.url == url }
                ?? providers.values.first { $0.name == spec.name }
            var metadata = existing ?? RuleProviderMetadata(
                name: spec.name,
                url: url,
                behavior: behavior,
                format: format,
                intervalSeconds: UInt32(spec.interval ?? 86_400)
            )
            metadata.url = url
            metadata.behavior = behavior
            metadata.format = format
            if let interval = spec.interval, interval > 0 {
                metadata.intervalSeconds = UInt32(interval)
            }
            providers[metadata.id] = metadata
            saveProvidersMetadata()

            do {
                _ = try await fetchAndParse(provider: metadata, force: force)
                if let updated = providers[metadata.id] {
                    staged.append(updated)
                }
            } catch {
                Self.logger.warning("Failed staging rule provider \(spec.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let current = providers[metadata.id] {
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

            let parts = clean.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
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

import CryptoKit
import Foundation
import OSLog

public struct ProxyProviderMetadata: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var intervalSeconds: Int
    public var lastUpdatedAt: Date?
    public var proxyCount: Int
    public var usage: SubscriptionUsage?
    public var etag: String?
    public var sha256: String?
    public var lastError: String?
    public var stagedRelativePath: String?
    public var isStagedFromProfile: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        url: URL,
        intervalSeconds: Int = 3_600,
        lastUpdatedAt: Date? = nil,
        proxyCount: Int = 0,
        usage: SubscriptionUsage? = nil,
        etag: String? = nil,
        sha256: String? = nil,
        lastError: String? = nil,
        stagedRelativePath: String? = nil,
        isStagedFromProfile: Bool = false
    ) {
        self.id = id
        self.name = name
        self.url = url
        self.intervalSeconds = intervalSeconds
        self.lastUpdatedAt = lastUpdatedAt
        self.proxyCount = proxyCount
        self.usage = usage
        self.etag = etag
        self.sha256 = sha256
        self.lastError = lastError
        self.stagedRelativePath = stagedRelativePath
        self.isStagedFromProfile = isStagedFromProfile
    }

    enum CodingKeys: String, CodingKey {
        case id, name, url, intervalSeconds, lastUpdatedAt, proxyCount
        case usage, etag, sha256, lastError, stagedRelativePath, isStagedFromProfile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.name = try container.decode(String.self, forKey: .name)
        self.url = try container.decode(URL.self, forKey: .url)
        self.intervalSeconds = try container.decode(Int.self, forKey: .intervalSeconds)
        self.lastUpdatedAt = try container.decodeIfPresent(Date.self, forKey: .lastUpdatedAt)
        self.proxyCount = try container.decode(Int.self, forKey: .proxyCount)
        self.usage = try container.decodeIfPresent(SubscriptionUsage.self, forKey: .usage)
        self.etag = try container.decodeIfPresent(String.self, forKey: .etag)
        self.sha256 = try container.decodeIfPresent(String.self, forKey: .sha256)
        self.lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
        self.stagedRelativePath = try container.decodeIfPresent(String.self, forKey: .stagedRelativePath)
        self.isStagedFromProfile = try container.decodeIfPresent(Bool.self, forKey: .isStagedFromProfile) ?? false
    }
}

public enum ProxyProviderError: LocalizedError, Equatable {
    case invalidURL
    case insecureScheme
    case downloadFailed(String)
    case oversizedPayload(Int)
    case parsingFailed
    case providerNotFound

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "代理集合 URL 无效 / Invalid proxy provider URL"
        case .insecureScheme:
            "代理集合必须使用 HTTPS 协议 / Proxy provider must use HTTPS"
        case let .downloadFailed(reason):
            "代理集合下载失败: \(reason) / Download failed: \(reason)"
        case let .oversizedPayload(bytes):
            "代理集合超出大小限制 (\(bytes) 字节) / Proxy provider exceeded size limit (\(bytes) bytes)"
        case .parsingFailed:
            "代理集合解析失败 / Failed to parse proxy provider"
        case .providerNotFound:
            "未找到指定的代理集合 / Proxy provider not found"
        }
    }
}

/// Actor-based remote proxy provider manager that fetches, tracks quota headers,
/// and stages local `file` snapshots for both TUN and Transparent Proxy runtimes.
public actor ProxyProviderEngine {
    public typealias HTTPFetcher = @Sendable (URL) async throws -> (Data, URLResponse)

    public static let shared = ProxyProviderEngine()
    public static let maximumPayloadBytes = 16 * 1_024 * 1_024
    private static let logger = AppLog.logger(category: "kit.proxy-providers")

    private let fileManager: FileManager
    private let directoryURL: URL
    private let stagingBaseURL: URL
    private let httpFetcher: HTTPFetcher?
    private var providers: [UUID: ProxyProviderMetadata] = [:]
    private var providerRevisions: [UUID: UInt64] = [:]

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
            dir = container.appendingPathComponent("Library/Application Support/AetherRoute/ProxyProviders", isDirectory: true)
        } else {
            dir = fileManager.temporaryDirectory.appendingPathComponent("ProxyProviders", isDirectory: true)
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
        let loadedProviders = Self.loadMetadata(fileManager: fileManager, metadataURL: dir.appendingPathComponent("providers.json"))
        Self.migrateLegacyStagedProxyFiles(
            providers: loadedProviders,
            directoryURL: dir,
            stagingBaseURL: self.stagingBaseURL,
            fileManager: fileManager
        )
        self.providers = loadedProviders
    }

    private nonisolated static func migrateLegacyStagedProxyFiles(
        providers: [UUID: ProxyProviderMetadata],
        directoryURL: URL,
        stagingBaseURL: URL,
        fileManager: FileManager
    ) {
        let stagedDir = stagingBaseURL.appendingPathComponent("providers/proxies", isDirectory: true)
        for entry in providers.values {
            let hashedName = sanitizedProviderFileName(name: entry.name)
            let legacyName = RuleProviderEngine.legacySanitizedFileName(
                name: entry.name,
                defaultStem: "proxy-provider",
                fileExtension: "yaml",
                acceptedSuffixes: [".yaml", ".yml"]
            )
            let hashedURL = stagedDir.appendingPathComponent(hashedName, isDirectory: false)
            let cacheURL = directoryURL.appendingPathComponent("\(entry.id.uuidString).yaml", isDirectory: false)
            if !fileManager.fileExists(atPath: hashedURL.path),
               let data = try? Data(contentsOf: cacheURL),
               !data.isEmpty {
                _ = try? RuleProviderEngine.stageFileData(
                    data,
                    relativeSubdirectory: "providers/proxies",
                    fileName: hashedName,
                    stagingBaseURL: stagingBaseURL,
                    fileManager: fileManager
                )
            }
            if legacyName != hashedName {
                RuleProviderEngine.removeStagedFile(
                    relativeSubdirectory: "providers/proxies",
                    fileName: legacyName,
                    stagingBaseURL: stagingBaseURL,
                    fileManager: fileManager
                )
            }
        }
    }

    nonisolated public static func sanitizedProviderFileName(name: String) -> String {
        RuleProviderEngine.sanitizedHashedFileName(
            name: name,
            defaultStem: "proxy-provider",
            fileExtension: "yaml",
            strippedExtensions: [".yaml", ".yml"]
        )
    }

    nonisolated public static func sanitizedIntervalSeconds(
        _ raw: Int?,
        defaultValue: Int = 3_600
    ) -> Int {
        guard let raw, raw > 0, raw <= Int(UInt32.max) else {
            return defaultValue
        }
        return raw
    }

    public func stagedProxyFileURL(name: String) -> URL {
        stagingBaseURL
            .appendingPathComponent("providers/proxies", isDirectory: true)
            .appendingPathComponent(Self.sanitizedProviderFileName(name: name), isDirectory: false)
    }

    /// Validates that a proxy provider URL uses `https`, or `http` strictly for
    /// loopback and private network hosts.
    nonisolated public static func validateURL(_ url: URL) throws {
        try ProviderURLValidator.validate(
            url,
            invalidURL: ProxyProviderError.invalidURL,
            insecureScheme: ProxyProviderError.insecureScheme
        )
    }

    /// Strictly validates proxy-provider URLs extracted from untrusted subscriptions:
    /// requires HTTPS and blocks loopback, RFC1918, link-local, ULA, and `.local` hosts.
    nonisolated public static func validateUntrustedRemoteURL(_ url: URL) throws {
        try ProviderURLValidator.validateUntrustedRemoteURL(
            url,
            invalidURL: ProxyProviderError.invalidURL,
            insecureScheme: ProxyProviderError.insecureScheme
        )
    }

    public func addProvider(_ provider: ProxyProviderMetadata) throws {
        try Self.validateURL(provider.url)
        if let existing = providers[provider.id], existing.url != provider.url {
            providerRevisions[provider.id, default: 0] &+= 1
        }
        providers[provider.id] = provider
        saveMetadata()
    }

    public func removeProvider(id: UUID) {
        let removed = providers.removeValue(forKey: id)
        providerRevisions[id, default: 0] &+= 1
        saveMetadata()
        try? fileManager.removeItem(at: cacheFileURL(for: id))
        if let removed, !providers.values.contains(where: { $0.name == removed.name }) {
            RuleProviderEngine.removeStagedFile(
                relativeSubdirectory: "providers/proxies",
                fileName: Self.sanitizedProviderFileName(name: removed.name),
                stagingBaseURL: stagingBaseURL,
                fileManager: fileManager
            )
        }
    }

    public func allProviders() -> [ProxyProviderMetadata] {
        Array(providers.values).sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func provider(id: UUID) -> ProxyProviderMetadata? {
        providers[id]
    }

    public func loadRawData(for id: UUID) -> Data? {
        let url = cacheFileURL(for: id)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private func ensureActiveSnapshot(
        id: UUID,
        expectedRevision: UInt64,
        expectedURL: URL
    ) throws -> ProxyProviderMetadata {
        guard let current = providers[id] else {
            throw ProxyProviderError.providerNotFound
        }
        guard providerRevisions[id, default: 0] == expectedRevision,
              current.url == expectedURL else {
            throw CancellationError()
        }
        return current
    }

    private func recordFailureIfCurrent(
        id: UUID,
        expectedRevision: UInt64,
        expectedURL: URL,
        message: String,
        failure: Error
    ) throws -> Never {
        var current = try ensureActiveSnapshot(
            id: id,
            expectedRevision: expectedRevision,
            expectedURL: expectedURL
        )
        current.lastError = message
        providers[id] = current
        saveMetadata()
        throw failure
    }

    @discardableResult
    public func fetchAndStage(id: UUID, force: Bool = true) async throws -> ProxyProviderMetadata {
        guard let initial = providers[id] else {
            throw ProxyProviderError.providerNotFound
        }
        let expectedRevision = providerRevisions[id, default: 0]
        if initial.isStagedFromProfile {
            try Self.validateUntrustedRemoteURL(initial.url)
        } else {
            try Self.validateURL(initial.url)
        }

        var request = URLRequest(url: initial.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("clash-verge/v2.0.0", forHTTPHeaderField: "User-Agent")
        if !force, let etag = initial.etag {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }

        let (data, response): (Data, URLResponse)
        do {
            if let httpFetcher {
                (data, response) = try await httpFetcher(initial.url)
            } else {
                (data, response) = try await ProviderSafeHTTPClient.fetch(
                    request: request,
                    maximumBytes: Self.maximumPayloadBytes,
                    allowInitialLocalTarget: !initial.isStagedFromProfile,
                    invalidURLError: { ProxyProviderError.invalidURL },
                    oversizedError: { ProxyProviderError.oversizedPayload($0) }
                )
            }
        } catch let error as ProxyProviderError {
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: error.localizedDescription,
                failure: error
            )
        } catch {
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: error.localizedDescription,
                failure: ProxyProviderError.downloadFailed(error.localizedDescription)
            )
        }

        var current = try ensureActiveSnapshot(
            id: id,
            expectedRevision: expectedRevision,
            expectedURL: initial.url
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            let reason = "Invalid HTTP response"
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: reason,
                failure: ProxyProviderError.downloadFailed(reason)
            )
        }

        let usageHeader = httpResponse.value(forHTTPHeaderField: "Subscription-Userinfo")
        let parsedUsage = usageHeader.flatMap { SubscriptionUsage.parse(header: $0, reportedAt: Date()) }

        if httpResponse.statusCode == 304 {
            current.lastUpdatedAt = Date()
            if let parsedUsage {
                current.usage = parsedUsage
            }
            current.lastError = nil
            providers[id] = current
            saveMetadata()
            return current
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = "HTTP \(httpResponse.statusCode)"
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: reason,
                failure: ProxyProviderError.downloadFailed(reason)
            )
        }

        guard data.count <= Self.maximumPayloadBytes else {
            let err = ProxyProviderError.oversizedPayload(data.count)
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: err.localizedDescription,
                failure: err
            )
        }

        guard let text = String(data: data, encoding: .utf8),
              !Self.looksLikeHTML(text) else {
            let err = ProxyProviderError.parsingFailed
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: err.localizedDescription,
                failure: err
            )
        }

        do {
            try ProfileImportValidator.validate(
                data: data,
                allowsApplicationRules: false,
                maximumBytes: Self.maximumPayloadBytes
            )
        } catch {
            let err = ProxyProviderError.parsingFailed
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: error.localizedDescription,
                failure: err
            )
        }

        let summary = ProfileConfigurationInspector.inspect(yaml: text)
        let proxyCount = summary.proxyCount
        guard proxyCount > 0 || Self.containsProxiesKey(text) else {
            let err = ProxyProviderError.parsingFailed
            try recordFailureIfCurrent(
                id: id,
                expectedRevision: expectedRevision,
                expectedURL: initial.url,
                message: err.localizedDescription,
                failure: err
            )
        }

        current = try ensureActiveSnapshot(
            id: id,
            expectedRevision: expectedRevision,
            expectedURL: initial.url
        )

        try data.write(to: cacheFileURL(for: id), options: [.atomic])

        let fileName = Self.sanitizedProviderFileName(name: current.name)
        _ = try RuleProviderEngine.stageFileData(
            data,
            relativeSubdirectory: "providers/proxies",
            fileName: fileName,
            stagingBaseURL: stagingBaseURL,
            fileManager: fileManager
        )

        current.lastUpdatedAt = Date()
        current.proxyCount = proxyCount
        if let parsedUsage {
            current.usage = parsedUsage
        }
        current.etag = httpResponse.value(forHTTPHeaderField: "ETag")
        current.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        current.lastError = nil
        current.stagedRelativePath = "./providers/proxies/\(fileName)"
        providers[id] = current
        saveMetadata()
        return current
    }

    public func stagedProviders(inProfileYAML yaml: String) -> [ProxyProviderMetadata] {
        let specs = DomesticRoutingOptimizer.extractRemoteProxyProviders(from: yaml)
        var results: [ProxyProviderMetadata] = []
        var seenIDs = Set<UUID>()
        for spec in specs {
            guard spec.type == "http",
                  let url = URL(string: spec.url),
                  (try? Self.validateUntrustedRemoteURL(url)) != nil else {
                continue
            }
            let match = providers.values.first { $0.name == spec.name && $0.url == url }
            if let match, seenIDs.insert(match.id).inserted {
                results.append(match)
            }
        }
        return results
    }

    @discardableResult
    public func stageProviders(inProfileYAML yaml: String, force: Bool = false) async -> [ProxyProviderMetadata] {
        let specs = DomesticRoutingOptimizer.extractRemoteProxyProviders(from: yaml)
        var results: [ProxyProviderMetadata] = []
        for spec in specs {
            guard spec.type == "http",
                  let url = URL(string: spec.url),
                  (try? Self.validateUntrustedRemoteURL(url)) != nil else {
                continue
            }
            let existing = providers.values.first { $0.name == spec.name && $0.url == url }
            var metadata = existing ?? ProxyProviderMetadata(
                name: spec.name,
                url: url,
                intervalSeconds: Self.sanitizedIntervalSeconds(spec.interval),
                isStagedFromProfile: true
            )
            metadata.isStagedFromProfile = true
            if metadata.url != url {
                providerRevisions[metadata.id, default: 0] &+= 1
            }
            metadata.url = url
            if let interval = spec.interval, interval > 0, interval <= Int(UInt32.max) {
                metadata.intervalSeconds = interval
            }
            providers[metadata.id] = metadata
            saveMetadata()

            do {
                let updated = try await fetchAndStage(id: metadata.id, force: force)
                results.append(updated)
            } catch {
                Self.logger.warning("Failed staging proxy provider \(spec.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                if let current = providers[metadata.id] {
                    results.append(current)
                }
            }
        }
        return results
    }

    @discardableResult
    public func refreshAll(force: Bool = true) async -> [ProxyProviderMetadata] {
        var results: [ProxyProviderMetadata] = []
        for item in allProviders() {
            if let updated = try? await fetchAndStage(id: item.id, force: force) {
                results.append(updated)
            } else if let current = providers[item.id] {
                results.append(current)
            }
        }
        return results
    }

    // MARK: - Helpers

    private static func looksLikeHTML(_ text: String) -> Bool {
        let sample = text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(512).lowercased()
        return sample.hasPrefix("<!doctype html") || sample.hasPrefix("<html") || sample.contains("<body")
    }

    private static func containsProxiesKey(_ text: String) -> Bool {
        text.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed == "proxies:" || trimmed.hasPrefix("proxies:")
        }
    }

    private func cacheFileURL(for id: UUID) -> URL {
        directoryURL.appendingPathComponent("\(id.uuidString).yaml", isDirectory: false)
    }

    private var metadataURL: URL {
        directoryURL.appendingPathComponent("providers.json", isDirectory: false)
    }

    private static func loadMetadata(fileManager: FileManager, metadataURL: URL) -> [UUID: ProxyProviderMetadata] {
        guard fileManager.fileExists(atPath: metadataURL.path),
              let data = try? Data(contentsOf: metadataURL),
              let decoded = try? JSONDecoder().decode([ProxyProviderMetadata].self, from: data) else {
            return [:]
        }
        var map: [UUID: ProxyProviderMetadata] = [:]
        for item in decoded {
            map[item.id] = item
        }
        return map
    }

    private func saveMetadata() {
        let list = allProviders()
        if let encoded = try? JSONEncoder().encode(list) {
            try? encoded.write(to: metadataURL, options: [.atomic])
        }
    }
}

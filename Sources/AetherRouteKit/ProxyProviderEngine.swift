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
        stagedRelativePath: String? = nil
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
        self.providers = Self.loadMetadata(fileManager: fileManager, metadataURL: dir.appendingPathComponent("providers.json"))
    }

    public static func sanitizedProviderFileName(name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var scalars = trimmed.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        if scalars.isEmpty {
            scalars = Array("proxy-provider")
        }
        var base = String(scalars)
        while base.hasPrefix(".") {
            base.removeFirst()
        }
        if base.isEmpty {
            base = "proxy-provider"
        }
        let lowered = base.lowercased()
        if lowered.hasSuffix(".yaml") || lowered.hasSuffix(".yml") {
            return base
        }
        return "\(base).yaml"
    }

    public func stagedProxyFileURL(name: String) -> URL {
        stagingBaseURL
            .appendingPathComponent("providers/proxies", isDirectory: true)
            .appendingPathComponent(Self.sanitizedProviderFileName(name: name), isDirectory: false)
    }

    public func addProvider(_ provider: ProxyProviderMetadata) throws {
        guard provider.url.scheme?.lowercased() == "https" else {
            throw ProxyProviderError.insecureScheme
        }
        providers[provider.id] = provider
        saveMetadata()
    }

    public func removeProvider(id: UUID) {
        if let existing = providers.removeValue(forKey: id) {
            try? fileManager.removeItem(at: cacheFileURL(for: id))
            try? fileManager.removeItem(at: stagedProxyFileURL(name: existing.name))
        }
        saveMetadata()
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

    @discardableResult
    public func fetchAndStage(id: UUID, force: Bool = true) async throws -> ProxyProviderMetadata {
        guard var provider = providers[id] else {
            throw ProxyProviderError.providerNotFound
        }

        var request = URLRequest(url: provider.url)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("clash-verge/v2.0.0", forHTTPHeaderField: "User-Agent")
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
            provider.lastError = error.localizedDescription
            providers[id] = provider
            saveMetadata()
            throw ProxyProviderError.downloadFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            let reason = "Invalid HTTP response"
            provider.lastError = reason
            providers[id] = provider
            saveMetadata()
            throw ProxyProviderError.downloadFailed(reason)
        }

        let usageHeader = httpResponse.value(forHTTPHeaderField: "Subscription-Userinfo")
        let parsedUsage = usageHeader.flatMap { SubscriptionUsage.parse(header: $0, reportedAt: Date()) }

        if httpResponse.statusCode == 304 {
            provider.lastUpdatedAt = Date()
            if let parsedUsage {
                provider.usage = parsedUsage
            }
            provider.lastError = nil
            providers[id] = provider
            saveMetadata()
            return provider
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let reason = "HTTP \(httpResponse.statusCode)"
            provider.lastError = reason
            providers[id] = provider
            saveMetadata()
            throw ProxyProviderError.downloadFailed(reason)
        }

        guard data.count <= Self.maximumPayloadBytes else {
            provider.lastError = ProxyProviderError.oversizedPayload(data.count).localizedDescription
            providers[id] = provider
            saveMetadata()
            throw ProxyProviderError.oversizedPayload(data.count)
        }

        guard let text = String(data: data, encoding: .utf8),
              !Self.looksLikeHTML(text) else {
            provider.lastError = ProxyProviderError.parsingFailed.localizedDescription
            providers[id] = provider
            saveMetadata()
            throw ProxyProviderError.parsingFailed
        }

        let summary = ProfileConfigurationInspector.inspect(yaml: text)
        let proxyCount = summary.proxyCount
        guard proxyCount > 0 || Self.containsProxiesKey(text) else {
            provider.lastError = ProxyProviderError.parsingFailed.localizedDescription
            providers[id] = provider
            saveMetadata()
            throw ProxyProviderError.parsingFailed
        }

        try data.write(to: cacheFileURL(for: id), options: [.atomic])

        let fileName = Self.sanitizedProviderFileName(name: provider.name)
        _ = try RuleProviderEngine.stageFileData(
            data,
            relativeSubdirectory: "providers/proxies",
            fileName: fileName,
            stagingBaseURL: stagingBaseURL,
            fileManager: fileManager
        )

        provider.lastUpdatedAt = Date()
        provider.proxyCount = proxyCount
        if let parsedUsage {
            provider.usage = parsedUsage
        }
        provider.etag = httpResponse.value(forHTTPHeaderField: "ETag")
        provider.sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        provider.lastError = nil
        provider.stagedRelativePath = "./providers/proxies/\(fileName)"
        providers[id] = provider
        saveMetadata()
        return provider
    }

    @discardableResult
    public func stageProviders(inProfileYAML yaml: String, force: Bool = false) async -> [ProxyProviderMetadata] {
        let specs = DomesticRoutingOptimizer.extractRemoteProxyProviders(from: yaml)
        var results: [ProxyProviderMetadata] = []
        for spec in specs {
            guard spec.type == "http",
                  let url = URL(string: spec.url),
                  url.scheme?.lowercased() == "https" else {
                continue
            }
            let existing = providers.values.first { $0.name == spec.name && $0.url == url }
                ?? providers.values.first { $0.name == spec.name }
            var metadata = existing ?? ProxyProviderMetadata(
                name: spec.name,
                url: url,
                intervalSeconds: spec.interval ?? 3_600
            )
            metadata.url = url
            if let interval = spec.interval, interval > 0 {
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

@preconcurrency import Foundation

public struct ProfileSubscription: Codable, Equatable, Sendable {
    public static let defaultAutoUpdateInterval: TimeInterval = 6 * 60 * 60

    public let url: URL
    public let etag: String?
    public let lastModified: String?
    public let lastCheckedAt: Date?
    public let lastUpdatedAt: Date?
    public let autoUpdateInterval: TimeInterval?

    public init(
        url: URL,
        etag: String? = nil,
        lastModified: String? = nil,
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        autoUpdateInterval: TimeInterval? = defaultAutoUpdateInterval
    ) throws {
        try ProfileSubscriptionClient.validateSubscriptionURL(url)
        self.url = url
        self.etag = Self.nonEmpty(etag)
        self.lastModified = Self.nonEmpty(lastModified)
        self.lastCheckedAt = lastCheckedAt
        self.lastUpdatedAt = lastUpdatedAt
        if let autoUpdateInterval {
            guard autoUpdateInterval >= 15 * 60,
                  autoUpdateInterval <= 7 * 24 * 60 * 60 else {
                throw ProfileSubscriptionError.invalidAutoUpdateInterval
            }
        }
        self.autoUpdateInterval = autoUpdateInterval
    }

    public func isDue(at date: Date = .now) -> Bool {
        guard let autoUpdateInterval else { return false }
        guard let lastCheckedAt else { return true }
        return date.timeIntervalSince(lastCheckedAt) >= autoUpdateInterval
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

public struct ProfileSubscriptionHTTPRequest: Equatable, Sendable {
    public let url: URL
    public let headers: [String: String]

    public init(url: URL, headers: [String: String]) {
        self.url = url
        self.headers = headers
    }
}

public struct ProfileSubscriptionHTTPResponse: Equatable, Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL
    public let headers: [String: String]

    public init(
        data: Data,
        statusCode: Int,
        finalURL: URL,
        headers: [String: String] = [:]
    ) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.headers = headers.reduce(into: [:]) { result, pair in
            result[pair.key.lowercased()] = pair.value
        }
    }
}

public enum ProfileSubscriptionUpdate: Equatable, Sendable {
    case updated(
        data: Data,
        metadata: ProfileSubscription,
        report: SubscriptionPayloadReport
    )
    case notModified(metadata: ProfileSubscription)
}

public struct ProfileSubscriptionClient: Sendable {
    /// Keeps AetherRoute identifiable while ensuring modern subscription
    /// services (such as Xboard, V2board, SSPanel) route to ClashMeta handlers
    /// rather than legacy Clash handlers that filter out VLESS/Reality nodes.
    public static let userAgent =
        "clash-verge/v2.5.2 (ClashMeta; AetherRoute/1.0)"

    public typealias Transport = @Sendable (
        ProfileSubscriptionHTTPRequest
    ) async throws -> ProfileSubscriptionHTTPResponse

    private let transport: Transport
    private let now: @Sendable () -> Date

    public init(
        transport: @escaping Transport,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.now = now
    }

    private static func performTransportSession(
        request: ProfileSubscriptionHTTPRequest,
        bypassProxy: Bool
    ) async throws -> ProfileSubscriptionHTTPResponse {
        let delegate = HTTPSOnlyRedirectDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = bypassProxy ? 20 : 30
        configuration.timeoutIntervalForResource = bypassProxy ? 30 : 60
        configuration.waitsForConnectivity = false
        if bypassProxy {
            configuration.connectionProxyDictionary = [:]
        }

        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = "GET"
        urlRequest.timeoutInterval = bypassProxy ? 20 : 30
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let result: (Data, URLResponse)
        do {
            result = try await session.data(for: urlRequest)
        } catch {
            if let redirectError = delegate.redirectError {
                throw redirectError
            }
            throw error
        }
        if let redirectError = delegate.redirectError {
            throw redirectError
        }
        let (data, response) = result
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url else {
            throw ProfileSubscriptionError.invalidResponse
        }
        let headers = response.allHeaderFields.reduce(
            into: [String: String]()
        ) { result, pair in
            guard let name = pair.key as? String else { return }
            result[name] = String(describing: pair.value)
        }
        return ProfileSubscriptionHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            finalURL: finalURL,
            headers: headers
        )
    }

    public static func live() -> Self {
        Self { request in
            // Mainstream clients (like Clash Verge) explicitly bypass system proxies (e.g. 127.0.0.1:7890)
            // for subscription requests by default because airport panels detect proxy source IPs and
            // degrade the response to a single fallback node.
            // We first attempt a direct connection. If direct connection encounters a network connectivity
            // failure (or an HTTP error status indicating geo-blocking), we seamlessly fall back to the
            // system proxy.
            do {
                let directResponse = try await performTransportSession(request: request, bypassProxy: true)
                if directResponse.statusCode < 400 {
                    return directResponse
                }
                if let proxyResponse = try? await performTransportSession(request: request, bypassProxy: false),
                   proxyResponse.statusCode < 400 {
                    return proxyResponse
                }
                return directResponse
            } catch {
                if Task.isCancelled { throw error }
                return try await performTransportSession(request: request, bypassProxy: false)
            }
        }
    }

    private func performRequest(
        for url: URL,
        subscription: ProfileSubscription
    ) async throws -> ProfileSubscriptionHTTPResponse {
        var headers = [
            "Accept": "application/yaml, application/x-yaml, text/yaml, text/plain, application/octet-stream;q=0.8, */*;q=0.5",
            "Cache-Control": "no-cache",
            "User-Agent": Self.userAgent,
        ]
        if let etag = subscription.etag {
            headers["If-None-Match"] = etag
        }
        if let lastModified = subscription.lastModified {
            headers["If-Modified-Since"] = lastModified
        }

        let response = try await transport(
            ProfileSubscriptionHTTPRequest(
                url: url,
                headers: headers
            )
        )
        try Self.validateSubscriptionURL(response.finalURL)
        return response
    }

    public func fetch(
        _ subscription: ProfileSubscription
    ) async throws -> ProfileSubscriptionUpdate {
        try Self.validateSubscriptionURL(subscription.url)
        var response = try await performRequest(
            for: subscription.url,
            subscription: subscription
        )
        let checkedAt = now()

        switch response.statusCode {
        case 304:
            return .notModified(
                metadata: try refreshedMetadata(
                    subscription,
                    response: response,
                    checkedAt: checkedAt,
                    updatedAt: subscription.lastUpdatedAt
                )
            )
        case 200:
            if let length = response.headers["content-length"],
               let bytes = Int(length),
               bytes > ProfileImportValidator.maximumProfileBytes {
                throw ProfileSubscriptionError.responseTooLarge(bytes)
            }
            guard response.data.count <= ProfileImportValidator.maximumProfileBytes else {
                throw ProfileSubscriptionError.responseTooLarge(response.data.count)
            }
            var normalized = try SubscriptionPayloadNormalizer
                .normalizeWithReport(
                    response.data
                )

            // When an airport panel (such as Xboard or V2board) falls back to a single
            // legacy node because of reverse proxy header stripping, attempt smart
            // query negotiation with flag=meta to retrieve the full ClashMeta profile.
            if let usable = normalized.report.usableNodeCount, usable <= 1,
               let metaURL = Self.urlWithMetaFlag(subscription.url) {
                if let fallbackResponse = try? await performRequest(
                    for: metaURL,
                    subscription: subscription
                ),
                fallbackResponse.statusCode == 200,
                fallbackResponse.data.count <= ProfileImportValidator.maximumProfileBytes,
                let fallbackNormalized = try? SubscriptionPayloadNormalizer.normalizeWithReport(
                    fallbackResponse.data
                ) {
                    let fallbackUsable = fallbackNormalized.report.usableNodeCount
                    if fallbackUsable == nil || (fallbackUsable ?? 0) > usable {
                        response = fallbackResponse
                        normalized = fallbackNormalized
                    }
                }
            }

            return .updated(
                data: normalized.data,
                metadata: try refreshedMetadata(
                    subscription,
                    response: response,
                    checkedAt: checkedAt,
                    updatedAt: checkedAt
                ),
                report: normalized.report
            )
        default:
            throw ProfileSubscriptionError.httpStatus(response.statusCode)
        }
    }

    public static func urlWithMetaFlag(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var items = components.queryItems ?? []
        if items.contains(where: { $0.name.lowercased() == "flag" }) {
            return nil
        }
        items.append(URLQueryItem(name: "flag", value: "meta"))
        components.queryItems = items
        guard let result = components.url,
              (try? validateSubscriptionURL(result)) != nil else {
            return nil
        }
        return result
    }

    public static func validateSubscriptionURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw ProfileSubscriptionError.invalidURL
        }
    }

    private func refreshedMetadata(
        _ subscription: ProfileSubscription,
        response: ProfileSubscriptionHTTPResponse,
        checkedAt: Date,
        updatedAt: Date?
    ) throws -> ProfileSubscription {
        try ProfileSubscription(
            url: subscription.url,
            etag: response.headers["etag"] ?? subscription.etag,
            lastModified: response.headers["last-modified"]
                ?? subscription.lastModified,
            lastCheckedAt: checkedAt,
            lastUpdatedAt: updatedAt,
            autoUpdateInterval: subscription.autoUpdateInterval
        )
    }
}

public enum ProfileSubscriptionError: LocalizedError, Equatable {
    case invalidURL
    case invalidAutoUpdateInterval
    case invalidResponse
    case insecureRedirect
    case tooManyRedirects
    case responseTooLarge(Int)
    case httpStatus(Int)
    case notModifiedWithoutActiveProfile

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Subscription URLs must use HTTPS, include a host, and contain no embedded credentials or fragment."
        case .invalidAutoUpdateInterval:
            "Automatic update intervals must be between 15 minutes and 7 days."
        case .invalidResponse:
            "The subscription server returned an invalid response."
        case .insecureRedirect:
            "The subscription server attempted to redirect to a non-HTTPS URL."
        case .tooManyRedirects:
            "The subscription server redirected too many times."
        case let .responseTooLarge(bytes):
            "The subscription response is too large (\(bytes) bytes)."
        case let .httpStatus(status):
            "The subscription server returned HTTP \(status)."
        case .notModifiedWithoutActiveProfile:
            "The subscription reported no changes before an active profile existed."
        }
    }
}

final class HTTPSOnlyRedirectDelegate: NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCount = 0
    private var storedRedirectError: ProfileSubscriptionError?

    var redirectError: ProfileSubscriptionError? {
        lock.withLock { storedRedirectError }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let isAllowed = lock.withLock { () -> Bool in
            redirectCount += 1
            guard redirectCount <= 5 else {
                storedRedirectError = .tooManyRedirects
                return false
            }
            guard let url = request.url,
                  (try? ProfileSubscriptionClient.validateSubscriptionURL(url))
                    != nil else {
                storedRedirectError = .insecureRedirect
                return false
            }
            return true
        }
        guard isAllowed else {
            completionHandler(nil)
            return
        }

        // URLSession may remove custom representation headers during a
        // cross-origin redirect. Reapply only this fixed allowlist; cookies,
        // authorization, and any provider credential headers are never copied.
        var redirectedRequest = request
        for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
            redirectedRequest.setValue(nil, forHTTPHeaderField: header)
        }
        for header in [
            "Accept",
            "Cache-Control",
            "User-Agent",
            "If-None-Match",
            "If-Modified-Since",
        ] {
            if let value = task.originalRequest?.value(
                forHTTPHeaderField: header
            ) {
                redirectedRequest.setValue(value, forHTTPHeaderField: header)
            }
        }
        completionHandler(redirectedRequest)
    }
}

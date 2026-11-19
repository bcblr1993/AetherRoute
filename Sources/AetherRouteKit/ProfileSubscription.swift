import Darwin
@preconcurrency import Foundation

public struct ProfileSubscription: Codable, Equatable, Sendable {
    public static let defaultAutoUpdateInterval: TimeInterval = 6 * 60 * 60

    public let url: URL
    public let etag: String?
    public let lastModified: String?
    public let lastCheckedAt: Date?
    public let lastUpdatedAt: Date?
    public let autoUpdateInterval: TimeInterval?
    // Added in 1.2.1; profiles saved earlier decode these as nil.
    /// Traffic and expiry from the provider's `subscription-userinfo`.
    public let usage: SubscriptionUsage?
    /// The provider's `profile-update-interval`, followed until the user
    /// picks an interval of their own.
    public let providerUpdateInterval: TimeInterval?
    /// Whether the user chose `autoUpdateInterval` (nil: not yet).
    public let isAutoUpdateIntervalCustomized: Bool?
    /// The profile name from `content-disposition`.
    public let providerProfileName: String?
    /// True once `?flag=meta` negotiation retrieved a fuller profile than the
    /// bare subscription URL, ensuring subsequent conditional refreshes query
    /// the same endpoint and ETag namespace.
    public let negotiatedMetaFlag: Bool?

    public init(
        url: URL,
        etag: String? = nil,
        lastModified: String? = nil,
        lastCheckedAt: Date? = nil,
        lastUpdatedAt: Date? = nil,
        autoUpdateInterval: TimeInterval? = defaultAutoUpdateInterval,
        usage: SubscriptionUsage? = nil,
        providerUpdateInterval: TimeInterval? = nil,
        isAutoUpdateIntervalCustomized: Bool? = nil,
        providerProfileName: String? = nil,
        negotiatedMetaFlag: Bool? = nil
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
        self.usage = usage
        self.providerUpdateInterval = providerUpdateInterval
        self.isAutoUpdateIntervalCustomized = isAutoUpdateIntervalCustomized
        self.providerProfileName = Self.nonEmpty(providerProfileName)
        self.negotiatedMetaFlag = negotiatedMetaFlag
    }

    /// The interval automatic updates use: the provider's suggestion while
    /// the user has not chosen one, otherwise the user's choice. Turning
    /// automatic updates off (nil) always wins.
    public var effectiveAutoUpdateInterval: TimeInterval? {
        guard let autoUpdateInterval else { return nil }
        if isAutoUpdateIntervalCustomized != true, let providerUpdateInterval {
            return max(15 * 60, providerUpdateInterval)
        }
        return autoUpdateInterval
    }

    public func isDue(at date: Date = .now) -> Bool {
        guard let interval = effectiveAutoUpdateInterval else { return false }
        guard let lastCheckedAt else { return true }
        return date.timeIntervalSince(lastCheckedAt) >= interval
    }

    /// This subscription with the user's automatic-update choice. `nil`
    /// turns updates off; `followProvider` returns to the provider's schedule.
    public func withAutoUpdate(
        interval: TimeInterval?,
        followProvider: Bool = false
    ) throws -> Self {
        try Self(
            url: url,
            etag: etag,
            lastModified: lastModified,
            lastCheckedAt: lastCheckedAt,
            lastUpdatedAt: lastUpdatedAt,
            autoUpdateInterval: followProvider
                ? (autoUpdateInterval ?? Self.defaultAutoUpdateInterval)
                : interval,
            usage: usage,
            providerUpdateInterval: providerUpdateInterval,
            isAutoUpdateIntervalCustomized: !followProvider,
            providerProfileName: providerProfileName,
            negotiatedMetaFlag: negotiatedMetaFlag
        )
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

    public static let directBypassRequestTimeout: TimeInterval = 6
    public static let directBypassResourceTimeout: TimeInterval = 10

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
        let requestTimeout = bypassProxy ? directBypassRequestTimeout : 30
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = bypassProxy ? directBypassResourceTimeout : 60
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
        urlRequest.timeoutInterval = requestTimeout
        if bypassProxy {
            urlRequest.assumesHTTP3Capable = false
        }
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await ProviderSafeHTTPClient.readBoundedBytes(
                from: session,
                for: urlRequest,
                maximumBytes: ProfileImportValidator.maximumProfileBytes,
                oversizedError: { ProfileSubscriptionError.responseTooLarge($0) }
            )
        } catch {
            if let redirectError = delegate.redirectError {
                throw redirectError
            }
            throw error
        }
        if let redirectError = delegate.redirectError {
            throw redirectError
        }
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
        let preferredMetaURL = subscription.negotiatedMetaFlag == true
            ? Self.urlWithMetaFlag(subscription.url)
            : nil
        let initialURL = preferredMetaURL ?? subscription.url
        var usedMetaEndpoint = preferredMetaURL != nil
        var response = try await performRequest(
            for: initialURL,
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
                    updatedAt: subscription.lastUpdatedAt,
                    negotiatedMetaFlag: usedMetaEndpoint
                        ? true
                        : subscription.negotiatedMetaFlag
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
            // legacy node or a "please use Clash Meta" YAML notice stub because of reverse
            // proxy header stripping, attempt smart query negotiation with flag=meta.
            let degradedUsableCount: Int? = {
                if let usable = normalized.report.usableNodeCount {
                    return usable <= 1 ? usable : nil
                }
                guard let yaml = String(data: normalized.data, encoding: .utf8) else {
                    return nil
                }
                let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
                if summary.proxyProviderCount == 0
                    && !summary.subscriptionNoticeNames.isEmpty
                    && summary.proxyCount <= 1 {
                    return summary.proxyCount
                }
                return nil
            }()
            if !usedMetaEndpoint,
               let usable = degradedUsableCount,
               let metaURL = Self.urlWithMetaFlag(subscription.url) {
                if let fallbackResponse = try? await performRequest(
                    for: metaURL,
                    subscription: subscription
                ) {
                    if fallbackResponse.statusCode == 304,
                       subscription.etag != nil || subscription.lastModified != nil {
                        return .notModified(
                            metadata: try refreshedMetadata(
                                subscription,
                                response: fallbackResponse,
                                checkedAt: checkedAt,
                                updatedAt: subscription.lastUpdatedAt,
                                negotiatedMetaFlag: true
                            )
                        )
                    }
                    if fallbackResponse.statusCode == 200,
                       fallbackResponse.data.count <= ProfileImportValidator.maximumProfileBytes,
                       let fallbackNormalized = try? SubscriptionPayloadNormalizer.normalizeWithReport(
                           fallbackResponse.data
                       ) {
                        let fallbackReportCount = fallbackNormalized.report.usableNodeCount
                        let primaryWasURIBase64 = normalized.report.usableNodeCount != nil
                        let fallbackYAMLCount: Int = {
                            if let count = fallbackReportCount {
                                return count
                            }
                            if let yaml = String(data: fallbackNormalized.data, encoding: .utf8) {
                                let s = ProfileConfigurationInspector.inspect(yaml: yaml)
                                return s.proxyCount + (s.proxyProviderCount > 0 ? 2 : 0)
                            }
                            return 0
                        }()
                        if (primaryWasURIBase64 && fallbackReportCount == nil) || fallbackYAMLCount > usable {
                            response = fallbackResponse
                            normalized = fallbackNormalized
                            usedMetaEndpoint = true
                        }
                    }
                }
            }

            let fallbackUsage = String(data: normalized.data, encoding: .utf8).flatMap { yaml in
                SubscriptionUsage.fallback(
                    from: ProfileConfigurationInspector.inspect(yaml: yaml),
                    reportedAt: checkedAt
                )
            }
            return .updated(
                data: normalized.data,
                metadata: try refreshedMetadata(
                    subscription,
                    response: response,
                    checkedAt: checkedAt,
                    updatedAt: checkedAt,
                    fallbackUsage: fallbackUsage,
                    negotiatedMetaFlag: usedMetaEndpoint
                        ? true
                        : subscription.negotiatedMetaFlag
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
              url.fragment == nil,
              !ProviderURLValidator.isLoopbackOrPrivateHost(host) else {
            throw ProfileSubscriptionError.invalidURL
        }
    }

    private func refreshedMetadata(
        _ subscription: ProfileSubscription,
        response: ProfileSubscriptionHTTPResponse,
        checkedAt: Date,
        updatedAt: Date?,
        fallbackUsage: SubscriptionUsage? = nil,
        negotiatedMetaFlag: Bool? = nil
    ) throws -> ProfileSubscription {
        try ProfileSubscription(
            url: subscription.url,
            etag: response.headers["etag"] ?? subscription.etag,
            lastModified: response.headers["last-modified"]
                ?? subscription.lastModified,
            lastCheckedAt: checkedAt,
            lastUpdatedAt: updatedAt,
            autoUpdateInterval: subscription.autoUpdateInterval,
            // A response without the header falls back to notice pseudo-nodes
            // in the payload, or keeps what was last reported.
            usage: SubscriptionUsage.parse(
                header: response.headers["subscription-userinfo"],
                reportedAt: checkedAt
            ) ?? fallbackUsage ?? subscription.usage,
            providerUpdateInterval: SubscriptionResponseHints.updateInterval(
                header: response.headers["profile-update-interval"]
            ) ?? subscription.providerUpdateInterval,
            isAutoUpdateIntervalCustomized: subscription.isAutoUpdateIntervalCustomized,
            providerProfileName: SubscriptionResponseHints.profileName(
                contentDisposition: response.headers["content-disposition"]
            ) ?? subscription.providerProfileName,
            negotiatedMetaFlag: negotiatedMetaFlag ?? subscription.negotiatedMetaFlag
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

enum ProviderURLValidator {
    static func validate(
        _ url: URL,
        invalidURL: @autoclosure () -> Error,
        insecureScheme: @autoclosure () -> Error
    ) throws {
        guard let scheme = url.scheme?.lowercased(), !scheme.isEmpty else {
            throw insecureScheme()
        }
        guard scheme == "https" || scheme == "http" else {
            throw insecureScheme()
        }
        guard let rawHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw invalidURL()
        }
        if scheme == "https" {
            return
        }
        guard isLoopbackOrPrivateHost(rawHost) else {
            throw insecureScheme()
        }
    }

    static func validateUntrustedRemoteURL(
        _ url: URL,
        invalidURL: @autoclosure () -> Error,
        insecureScheme: @autoclosure () -> Error
    ) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" else {
            throw insecureScheme()
        }
        guard let rawHost = url.host?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawHost.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil,
              !isLoopbackOrPrivateHost(rawHost) else {
            throw invalidURL()
        }
    }

    static func isLoopbackOrPrivateHost(_ rawHost: String) -> Bool {
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while host.hasSuffix(".") {
            host.removeLast()
        }
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        guard !host.isEmpty else { return true }

        if host == "localhost"
            || host.hasSuffix(".localhost")
            || host == "local"
            || host.hasSuffix(".local")
            || host.hasSuffix(".localdomain")
            || host.hasSuffix(".internal")
            || host.hasSuffix(".home.arpa") {
            return true
        }

        var addr4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &addr4) }) == 1 {
            return isLoopbackOrPrivateIPv4(UInt32(bigEndian: addr4.s_addr))
        }
        if host.utf8.allSatisfy({
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) || $0 == 46 || $0 == 120
        }) {
            var shorthandAddr = in_addr()
            if host.withCString({ inet_aton($0, &shorthandAddr) }) == 1 {
                return isLoopbackOrPrivateIPv4(UInt32(bigEndian: shorthandAddr.s_addr))
            }
        }

        let ipv6Host = host.split(separator: "%", maxSplits: 1).first.map(String.init) ?? host
        var addr6 = in6_addr()
        if ipv6Host.withCString({ inet_pton(AF_INET6, $0, &addr6) }) == 1 {
            return isLoopbackOrPrivateIPv6(addr6)
        }
        return false
    }

    static func isLoopbackOrPrivateIPv6(_ addr6: in6_addr) -> Bool {
        withUnsafeBytes(of: addr6) { bytes in
            guard bytes.count == 16 else { return true }
            let isLoopback = bytes[0..<15].allSatisfy { $0 == 0 } && bytes[15] == 1
            let isUnspecified = bytes.allSatisfy { $0 == 0 }
            let isULA = (bytes[0] & 0xFE) == 0xFC
            let isLinkLocal = bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80
            let isMulticast = bytes[0] == 0xFF
            if isLoopback || isUnspecified || isULA || isLinkLocal || isMulticast {
                return true
            }
            let isIPv4Mapped = bytes[0..<10].allSatisfy { $0 == 0 }
                && bytes[10] == 0xFF
                && bytes[11] == 0xFF
            let isNAT64WellKnown = bytes[0] == 0x00 && bytes[1] == 0x64
                && bytes[2] == 0xFF && bytes[3] == 0x9B
                && bytes[4..<12].allSatisfy { $0 == 0 }
            if isIPv4Mapped || isNAT64WellKnown {
                let v4 = (UInt32(bytes[12]) << 24)
                    | (UInt32(bytes[13]) << 16)
                    | (UInt32(bytes[14]) << 8)
                    | UInt32(bytes[15])
                return isLoopbackOrPrivateIPv4(v4)
            }
            return false
        }
    }

    static func isLoopbackOrPrivateIPv4(_ ip: UInt32) -> Bool {
        let firstOctet = (ip >> 24) & 0xFF
        if firstOctet == 0 || firstOctet == 127 || firstOctet == 10 {
            return true
        }
        if (ip & 0xFFC0_0000) == 0x6440_0000 { // 100.64.0.0/10 CGNAT
            return true
        }
        if (ip & 0xFFF0_0000) == 0xAC10_0000 { // 172.16.0.0/12
            return true
        }
        if (ip & 0xFFFF_0000) == 0xC0A8_0000 { // 192.168.0.0/16
            return true
        }
        if (ip & 0xFFFF_0000) == 0xA9FE_0000 { // 169.254.0.0/16
            return true
        }
        if firstOctet >= 224 {
            return true
        }
        return false
    }

    static func verifyHostResolvesToPublicAddresses(_ rawHost: String) async throws -> Bool {
        if isLoopbackOrPrivateHost(rawHost) {
            return false
        }
        var host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("[") && host.hasSuffix("]") && host.count >= 2 {
            host = String(host.dropFirst().dropLast())
        }
        var v4 = in_addr()
        if host.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 {
            return !isLoopbackOrPrivateIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if host.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 {
            return !isLoopbackOrPrivateIPv6(v6)
        }
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var result: UnsafeMutablePointer<addrinfo>?
            let status = host.withCString { cHost in
                getaddrinfo(cHost, nil, &hints, &result)
            }
            guard status == 0, let head = result else {
                throw URLError(.cannotFindHost)
            }
            defer { freeaddrinfo(head) }

            var foundAny = false
            var cursor: UnsafeMutablePointer<addrinfo>? = head
            while let info = cursor {
                defer { cursor = info.pointee.ai_next }
                guard let sa = info.pointee.ai_addr else { continue }
                if Int32(sa.pointee.sa_family) == AF_INET {
                    let sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    foundAny = true
                    if isLoopbackOrPrivateIPv4(UInt32(bigEndian: sin.sin_addr.s_addr)) {
                        return false
                    }
                } else if Int32(sa.pointee.sa_family) == AF_INET6 {
                    let sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    foundAny = true
                    if isLoopbackOrPrivateIPv6(sin6.sin6_addr) {
                        return false
                    }
                }
            }
            return foundAny
        }.value
    }
}

enum ProviderSafeHTTPClient {
    static func readBoundedBytes(
        from session: URLSession,
        for request: URLRequest,
        maximumBytes: Int,
        oversizedError: (Int) -> Error
    ) async throws -> (Data, URLResponse) {
        let (asyncBytes, response) = try await session.bytes(for: request)
        if let httpResponse = response as? HTTPURLResponse,
           let lengthHeader = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let declaredLength = Int(lengthHeader.trimmingCharacters(in: .whitespacesAndNewlines)),
           declaredLength > maximumBytes {
            asyncBytes.task.cancel()
            throw oversizedError(declaredLength)
        }

        let initialCapacity: Int
        if let httpResponse = response as? HTTPURLResponse,
           let lengthHeader = httpResponse.value(forHTTPHeaderField: "Content-Length"),
           let declaredLength = Int(lengthHeader.trimmingCharacters(in: .whitespacesAndNewlines)),
           declaredLength > 0 {
            initialCapacity = min(declaredLength, min(maximumBytes, 256 * 1_024))
        } else {
            initialCapacity = 16 * 1_024
        }

        var buffer = Data()
        buffer.reserveCapacity(initialCapacity)
        do {
            for try await byte in asyncBytes {
                if buffer.count >= maximumBytes {
                    asyncBytes.task.cancel()
                    throw oversizedError(maximumBytes + 1)
                }
                buffer.append(byte)
            }
        } catch {
            asyncBytes.task.cancel()
            throw error
        }
        return (buffer, response)
    }

    static func fetch(
        request: URLRequest,
        maximumBytes: Int,
        allowInitialLocalTarget: Bool,
        invalidURLError: @Sendable () -> Error,
        oversizedError: @Sendable (Int) -> Error
    ) async throws -> (Data, URLResponse) {
        guard let initialURL = request.url, let host = initialURL.host else {
            throw invalidURLError()
        }
        if !allowInitialLocalTarget {
            let isPublic = try await ProviderURLValidator.verifyHostResolvesToPublicAddresses(host)
            guard isPublic else {
                throw invalidURLError()
            }
        }

        let delegate = ProviderRedirectGuardDelegate()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.waitsForConnectivity = false

        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await readBoundedBytes(
                from: session,
                for: request,
                maximumBytes: maximumBytes,
                oversizedError: oversizedError
            )
        } catch {
            if delegate.rejectedRedirect {
                throw invalidURLError()
            }
            throw error
        }
        if delegate.rejectedRedirect {
            throw invalidURLError()
        }
        if let finalURL = response.url, finalURL != initialURL {
            guard (try? ProviderURLValidator.validateUntrustedRemoteURL(
                finalURL,
                invalidURL: URLError(.badURL),
                insecureScheme: URLError(.appTransportSecurityRequiresSecureConnection)
            )) != nil else {
                throw invalidURLError()
            }
        }
        return (data, response)
    }
}

private final class RedirectCompletionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: ((URLRequest?) -> Void)?

    init(_ handler: @escaping (URLRequest?) -> Void) {
        self.handler = handler
    }

    func complete(_ request: URLRequest?) {
        let cb = lock.withLock { () -> ((URLRequest?) -> Void)? in
            defer { handler = nil }
            return handler
        }
        cb?(request)
    }
}

private final class ProviderRedirectGuardDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hops = 0
    private var rejected = false

    var rejectedRedirect: Bool {
        lock.withLock { rejected }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let completionBox = RedirectCompletionBox(completionHandler)
        let targetURL = request.url
        let allowedSyntax = lock.withLock { () -> Bool in
            hops += 1
            guard hops <= 5,
                  let targetURL,
                  (try? ProviderURLValidator.validateUntrustedRemoteURL(
                      targetURL,
                      invalidURL: URLError(.badURL),
                      insecureScheme: URLError(.appTransportSecurityRequiresSecureConnection)
                  )) != nil else {
                rejected = true
                return false
            }
            return true
        }
        guard allowedSyntax, let targetHost = targetURL?.host else {
            completionBox.complete(nil)
            return
        }
        var sanitized = request
        for header in ["Authorization", "Cookie", "Proxy-Authorization"] {
            sanitized.setValue(nil, forHTTPHeaderField: header)
        }
        let preparedRequest = sanitized
        Task.detached(priority: .utility) { [self, completionBox, targetHost, preparedRequest] in
            let resolvesPublic = (try? await ProviderURLValidator.verifyHostResolvesToPublicAddresses(targetHost)) ?? false
            guard resolvesPublic else {
                self.lock.withLock { self.rejected = true }
                completionBox.complete(nil)
                return
            }
            completionBox.complete(preparedRequest)
        }
    }
}

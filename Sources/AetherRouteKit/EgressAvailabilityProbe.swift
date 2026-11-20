import Foundation

// MARK: - Egress Identity & Purity Models

public enum EgressIPType: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case residential
    case isp
    case datacenter
    case unknown
}

public enum EgressPurityLevel: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case clean
    case moderate
    case elevated
}

public struct EgressPurityAssessment: Codable, Equatable, Hashable, Sendable {
    public let level: EgressPurityLevel
    public let score: Int
    public let reasons: [String]

    public init(level: EgressPurityLevel, score: Int, reasons: [String] = []) {
        self.level = level
        self.score = min(max(score, 0), 100)
        self.reasons = reasons
    }
}

public struct EgressIdentity: Codable, Equatable, Hashable, Sendable {
    public let ip: String
    public let countryCode: String?
    public let countryName: String?
    public let city: String?
    public let asn: String?
    public let organization: String?
    public let ipType: EgressIPType
    public let purity: EgressPurityAssessment

    public init(
        ip: String,
        countryCode: String?,
        countryName: String?,
        city: String?,
        asn: String?,
        organization: String?,
        ipType: EgressIPType,
        purity: EgressPurityAssessment
    ) {
        self.ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedCode = countryCode?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        self.countryCode = (normalizedCode?.count == 2) ? normalizedCode : nil
        self.countryName = countryName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.city = city?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.asn = asn?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.organization = organization?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.ipType = ipType
        self.purity = purity
    }

    public var flag: String {
        Self.flag(forCountryCode: countryCode)
    }

    public var maskedIP: String {
        guard !ip.isEmpty else { return "***" }
        let v4Parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        if v4Parts.count == 4 {
            return "\(v4Parts[0]).\(v4Parts[1]).***.**"
        }
        if ip.contains(":") {
            let v6Parts = ip.split(separator: ":", omittingEmptySubsequences: true)
            if v6Parts.count >= 2 {
                return "\(v6Parts[0]):\(v6Parts[1]):****:****"
            }
            if let first = v6Parts.first {
                return "\(first):****:****"
            }
        }
        return "***"
    }

    public static func flag(forCountryCode code: String?) -> String {
        guard let raw = code?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
              raw.count == 2 else {
            return "🌐"
        }
        let base: UInt32 = 127_397
        var scalars = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            guard scalar.value >= 65 && scalar.value <= 90,
                  let indicator = UnicodeScalar(base + scalar.value) else {
                return "🌐"
            }
            scalars.append(indicator)
        }
        return String(scalars)
    }
}

// MARK: - Classifier & Identity Parser

public enum EgressClassifier {
    private static let datacenterKeywords: [String] = [
        "amazon", "aws", "google cloud", "google llc", "microsoft", "azure",
        "cloudflare", "digitalocean", "vultr", "linode", "akamai", "hetzner",
        "ovh", "oracle", "alibaba", "aliyun", "tencent", "m247", "leaseweb",
        "contabo", "choopa", "datacamp", "rackspace", "softlayer", "ibm cloud",
        "scaleway", "upcloud", "kamatera", "zenlayer", "dmit", "bandwagon",
        "it7", "cogent", "hosting", "datacenter", "data center", "cloud",
        "server", "vps", "colocation", "cdn77", "fastly"
    ]

    private static let residentialKeywords: [String] = [
        "comcast", "xfinity", "verizon", "at&t", "charter", "spectrum",
        "cox communications", "residential", "broadband", "home", "cable",
        "fiber", "fibre", "wireless", "mobile", "cellular"
    ]

    private static let ispKeywords: [String] = [
        "ntt", "kddi", "softbank", "iij", "internet initiative", "docomo",
        "pccw", "hkt", "hkbn", "singtel", "starhub", "m1 ", "cht", "chunghwa",
        "hinet", "kt corp", "sk broadband", "lg uplus", "bt ", "virgin media",
        "deutsche telekom", "orange", "telefonica", "telstra", "rogers",
        "bell canada", "telus", "telecom", "communications", "isp", "networks"
    ]

    public static func classifyIPType(
        asn: String?,
        organization: String?,
        isHosting: Bool
    ) -> EgressIPType {
        let combined = [asn, organization]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        if isHosting {
            return .datacenter
        }
        guard !combined.isEmpty else {
            return .unknown
        }
        if datacenterKeywords.contains(where: { combined.contains($0) }) {
            return .datacenter
        }
        if residentialKeywords.contains(where: { combined.contains($0) }) {
            return .residential
        }
        if ispKeywords.contains(where: { combined.contains($0) }) {
            return .isp
        }
        return .isp
    }

    public static func assessPurity(
        ipType: EgressIPType,
        isProxy: Bool,
        isHosting: Bool,
        isVPN: Bool,
        isTor: Bool = false
    ) -> EgressPurityAssessment {
        var score: Int
        var reasons: [String] = []

        switch ipType {
        case .residential:
            score = 94
        case .isp:
            score = 88
        case .datacenter:
            score = 68
            reasons.append("datacenter")
        case .unknown:
            score = 72
        }

        if isHosting && ipType != .datacenter {
            score -= 14
            reasons.append("hosting")
        }
        if isProxy {
            score -= 22
            reasons.append("proxy")
        }
        if isVPN {
            score -= 16
            reasons.append("vpn")
        }
        if isTor {
            score -= 35
            reasons.append("tor")
        }

        let clamped = min(max(score, 0), 100)
        let level: EgressPurityLevel
        if clamped >= 80 {
            level = .clean
        } else if clamped >= 50 {
            level = .moderate
        } else {
            level = .elevated
        }
        return EgressPurityAssessment(level: level, score: clamped, reasons: reasons)
    }
}

public enum EgressIdentityParser {
    public static func parse(data: Data) -> EgressIdentity? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let success = object["success"] as? Bool, !success {
            return nil
        }
        guard let ip = firstNonEmptyString(in: object, keys: ["ip", "query"]) else {
            return nil
        }

        let countryCode = firstNonEmptyString(in: object, keys: ["country_code", "countryCode", "country_iso"])
            ?? (object["country"] as? String).flatMap { $0.count == 2 ? $0 : nil }
        let countryName = firstNonEmptyString(in: object, keys: ["country_name", "country"])
        let city = firstNonEmptyString(in: object, keys: ["city"])

        let connection = object["connection"] as? [String: Any]
        let security = object["security"] as? [String: Any]

        var asn = firstNonEmptyString(in: object, keys: ["asn"])
            ?? connection.flatMap { stringValue(forKey: "asn", in: $0) }
        var org = firstNonEmptyString(in: object, keys: ["org", "organization", "isp"])
            ?? connection.flatMap { firstNonEmptyString(in: $0, keys: ["org", "isp"]) }

        // Handle ipinfo.io combined "AS13335 Cloudflare, Inc." org format.
        if asn == nil, let rawOrg = org, rawOrg.uppercased().hasPrefix("AS") {
            let parts = rawOrg.split(separator: " ", maxSplits: 1)
            if parts.count == 2 {
                asn = String(parts[0])
                org = String(parts[1])
            }
        }
        if let rawASN = asn, !rawASN.uppercased().hasPrefix("AS"), rawASN.allSatisfy(\.isNumber) {
            asn = "AS\(rawASN)"
        }

        let isHosting = boolValue(in: object, keys: ["hosting"])
            || (security.map { boolValue(in: $0, keys: ["hosting"]) } ?? false)
            || (firstNonEmptyString(in: object, keys: ["type"])?.lowercased() == "hosting")
        let isProxy = boolValue(in: object, keys: ["proxy"])
            || (security.map { boolValue(in: $0, keys: ["proxy"]) } ?? false)
        let isVPN = boolValue(in: object, keys: ["vpn"])
            || (security.map { boolValue(in: $0, keys: ["vpn"]) } ?? false)
        let isTor = boolValue(in: object, keys: ["tor"])
            || (security.map { boolValue(in: $0, keys: ["tor"]) } ?? false)

        let ipType = EgressClassifier.classifyIPType(
            asn: asn,
            organization: org,
            isHosting: isHosting
        )
        let purity = EgressClassifier.assessPurity(
            ipType: ipType,
            isProxy: isProxy,
            isHosting: isHosting,
            isVPN: isVPN,
            isTor: isTor
        )

        return EgressIdentity(
            ip: ip,
            countryCode: countryCode,
            countryName: countryName,
            city: city,
            asn: asn,
            organization: org,
            ipType: ipType,
            purity: purity
        )
    }

    private static func firstNonEmptyString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(forKey: key, in: dict) {
                return value
            }
        }
        return nil
    }

    private static func stringValue(forKey key: String, in dict: [String: Any]) -> String? {
        if let str = dict[key] as? String {
            return str.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        if let num = dict[key] as? NSNumber {
            // Avoid interpreting booleans as numeric strings.
            if CFGetTypeID(num) == CFBooleanGetTypeID() {
                return nil
            }
            return num.stringValue
        }
        return nil
    }

    private static func boolValue(in dict: [String: Any], keys: [String]) -> Bool {
        for key in keys {
            if let value = dict[key] as? Bool, value {
                return true
            }
        }
        return false
    }
}

// MARK: - Service Availability Models

public enum EgressServiceCategory: String, CaseIterable, Codable, Equatable, Hashable, Sendable {
    case ai
    case streaming
}

public enum EgressServiceKind: String, CaseIterable, Codable, Equatable, Hashable, Identifiable, Sendable {
    case chatGPT
    case claude
    case gemini
    case githubCopilot
    case netflix
    case disneyPlus
    case youtube
    case tiktok

    public var id: String { rawValue }

    public var category: EgressServiceCategory {
        switch self {
        case .chatGPT, .claude, .gemini, .githubCopilot:
            return .ai
        case .netflix, .disneyPlus, .youtube, .tiktok:
            return .streaming
        }
    }

    public var displayName: String {
        switch self {
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .githubCopilot: return "GitHub Copilot"
        case .netflix: return "Netflix"
        case .disneyPlus: return "Disney+"
        case .youtube: return "YouTube"
        case .tiktok: return "TikTok"
        }
    }

    public var probeURL: URL {
        switch self {
        case .chatGPT:
            return URL(string: "https://api.openai.com/v1/models")!
        case .claude:
            return URL(string: "https://claude.ai/login")!
        case .gemini:
            return URL(string: "https://gemini.google.com/")!
        case .githubCopilot:
            return URL(string: "https://api.github.com/copilot_internal/v2/token")!
        case .netflix:
            return URL(string: "https://www.netflix.com/title/81280792")!
        case .disneyPlus:
            return URL(string: "https://www.disneyplus.com/")!
        case .youtube:
            return URL(string: "https://www.youtube.com/premium")!
        case .tiktok:
            return URL(string: "https://www.tiktok.com/")!
        }
    }

    public static var aiServices: [EgressServiceKind] {
        [.chatGPT, .claude, .gemini, .githubCopilot]
    }

    public static var streamingServices: [EgressServiceKind] {
        [.netflix, .disneyPlus, .youtube, .tiktok]
    }
}

public enum EgressServiceAvailability: Codable, Equatable, Hashable, Sendable {
    case available(detail: String?)
    case limited(detail: String?)
    case unavailable(detail: String?)
    case unknown

    public var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }

    public var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    public var detail: String? {
        switch self {
        case .available(let detail), .limited(let detail), .unavailable(let detail):
            return detail
        case .unknown:
            return nil
        }
    }
}

public struct EgressServiceProbeResult: Identifiable, Codable, Equatable, Hashable, Sendable {
    public let service: EgressServiceKind
    public let status: EgressServiceAvailability
    public let latencyMilliseconds: Int?

    public var id: EgressServiceKind { service }

    public init(
        service: EgressServiceKind,
        status: EgressServiceAvailability,
        latencyMilliseconds: Int?
    ) {
        self.service = service
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
    }
}

public enum EgressServiceProbeClassifier {
    public static func classify(
        service: EgressServiceKind,
        statusCode: Int,
        headers: [String: String],
        body: String
    ) -> EgressServiceAvailability {
        let lowerHeaders = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value.lowercased()) },
            uniquingKeysWith: { first, _ in first }
        )
        let lowerBody = body.lowercased()
        let isCFChallenge = (lowerHeaders["cf-mitigated"]?.contains("challenge") ?? false)
            || lowerBody.contains("cf-browser-verification")
            || lowerBody.contains("just a moment...")

        switch service {
        case .chatGPT:
            if lowerBody.contains("unsupported_country_region_territory")
                || lowerBody.contains("not available in your country")
                || statusCode == 451 {
                return .unavailable(detail: "Region blocked")
            }
            if isCFChallenge {
                return .limited(detail: "Challenge")
            }
            if statusCode == 200 || statusCode == 401 {
                return .available(detail: nil)
            }
            if statusCode == 403 {
                if lowerBody.contains("invalid_api_key") || lowerBody.contains("missing_authorization") {
                    return .available(detail: nil)
                }
                return .unavailable(detail: "Blocked")
            }
            if statusCode == 429 {
                return .limited(detail: "Rate limited")
            }
            return .unknown

        case .claude:
            if lowerBody.contains("app-unavailable-in-region")
                || lowerBody.contains("unavailable-in-region")
                || lowerBody.contains("not available in your country")
                || statusCode == 451 {
                return .unavailable(detail: "Region blocked")
            }
            if isCFChallenge {
                return .limited(detail: "Challenge")
            }
            if (200...399).contains(statusCode) {
                return .available(detail: nil)
            }
            if statusCode == 403 {
                return .unavailable(detail: "Blocked")
            }
            if statusCode == 429 {
                return .limited(detail: "Rate limited")
            }
            return .unknown

        case .gemini:
            if lowerBody.contains("isn't currently supported in your country")
                || lowerBody.contains("not available in your country")
                || lowerBody.contains("faq#region")
                || statusCode == 451 {
                return .unavailable(detail: "Region blocked")
            }
            if (200...399).contains(statusCode) {
                return .available(detail: nil)
            }
            if statusCode == 403 || statusCode == 429 {
                return .limited(detail: "Rate limited")
            }
            return .unknown

        case .githubCopilot:
            if statusCode == 451
                || lowerBody.contains("not available in your region")
                || lowerBody.contains("trade controls") {
                return .unavailable(detail: "Region blocked")
            }
            if statusCode == 200 || statusCode == 401 {
                return .available(detail: nil)
            }
            if statusCode == 403 {
                if lowerBody.contains("rate limit") {
                    return .limited(detail: "Rate limited")
                }
                return .unavailable(detail: "Blocked")
            }
            if statusCode == 429 {
                return .limited(detail: "Rate limited")
            }
            return .unknown

        case .netflix:
            if statusCode == 200 {
                return .available(detail: "Full")
            }
            if statusCode == 404 {
                return .limited(detail: "Originals only")
            }
            if statusCode == 403 || statusCode == 451 {
                return .unavailable(detail: "Blocked")
            }
            return .unknown

        case .disneyPlus:
            if statusCode == 403 || statusCode == 451
                || lowerBody.contains("not available in your region")
                || lowerBody.contains("service is unavailable in your location") {
                return .unavailable(detail: "Region blocked")
            }
            if (200...399).contains(statusCode) {
                return .available(detail: nil)
            }
            return .unknown

        case .youtube:
            if statusCode == 403 || statusCode == 451 {
                return .unavailable(detail: "Blocked")
            }
            if lowerBody.contains("youtube premium is not available in your country")
                || lowerBody.contains("not available in your country") {
                return .limited(detail: "No Premium")
            }
            if (200...399).contains(statusCode) {
                return .available(detail: nil)
            }
            return .unknown

        case .tiktok:
            if statusCode == 403 || statusCode == 451
                || lowerBody.contains("not available in your country")
                || lowerBody.contains("not available in your region") {
                return .unavailable(detail: "Region blocked")
            }
            if statusCode == 429 {
                return .limited(detail: "Rate limited")
            }
            if (200...399).contains(statusCode) {
                return .available(detail: nil)
            }
            return .unknown
        }
    }
}

// MARK: - Probe Report & Bounded Cache

public struct EgressProbeReport: Codable, Equatable, Hashable, Sendable {
    public static let aiRestrictedCountryCodes: Set<String> = [
        "HK", "CN", "MO", "RU", "BY", "KP", "IR", "SY", "CU"
    ]

    public let nodeName: String?
    public let checkedAt: Date
    public let identity: EgressIdentity?
    public let services: [EgressServiceProbeResult]

    public init(
        nodeName: String?,
        checkedAt: Date,
        identity: EgressIdentity?,
        services: [EgressServiceProbeResult]
    ) {
        self.nodeName = nodeName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        self.checkedAt = checkedAt
        self.identity = identity
        self.services = services
    }

    public var aiServices: [EgressServiceProbeResult] {
        services.filter { $0.service.category == .ai }
    }

    public var streamingServices: [EgressServiceProbeResult] {
        services.filter { $0.service.category == .streaming }
    }

    public var availableAICount: Int {
        aiServices.filter { $0.status.isAvailable }.count
    }

    public var unavailableAICount: Int {
        aiServices.filter { $0.status.isUnavailable }.count
    }

    public var availableStreamingCount: Int {
        streamingServices.filter { $0.status.isAvailable }.count
    }

    public var isAIRestricted: Bool {
        if let code = identity?.countryCode, Self.aiRestrictedCountryCodes.contains(code) {
            return true
        }
        return unavailableAICount >= 2
    }

    public var isAIAvailable: Bool {
        !isAIRestricted && availableAICount >= 2
    }
}

public struct EgressProbeCache: Equatable, Sendable {
    public static let defaultCapacity = 64

    public let capacity: Int
    private var entries: [String: EgressProbeReport] = [:]
    private var order: [String] = []

    public init(capacity: Int = EgressProbeCache.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    public var count: Int { entries.count }

    public var allReports: [String: EgressProbeReport] { entries }

    public var aiAvailableNodeNames: Set<String> {
        Set(entries.compactMap { key, report in
            report.isAIAvailable ? key : nil
        })
    }

    public func report(forNode nodeName: String) -> EgressProbeReport? {
        entries[nodeName]
    }

    public mutating func store(_ report: EgressProbeReport, forNode nodeName: String) {
        let key = nodeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        entries[key] = report
        order.removeAll { $0 == key }
        order.append(key)
        while order.count > capacity {
            let evicted = order.removeFirst()
            entries.removeValue(forKey: evicted)
        }
    }

    public mutating func removeAll() {
        entries.removeAll(keepingCapacity: false)
        order.removeAll(keepingCapacity: false)
    }
}

// MARK: - Proxy Session Configuration & Probe Runner

public struct EgressProxyConfiguration: Equatable, Hashable, Sendable {
    public let httpHost: String
    public let httpPort: Int

    public init(httpHost: String, httpPort: Int) {
        self.httpHost = httpHost
        self.httpPort = httpPort
    }

    public var connectionProxyDictionary: [AnyHashable: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: 1,
            kCFNetworkProxiesHTTPProxy as String: httpHost,
            kCFNetworkProxiesHTTPPort as String: httpPort,
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: httpHost,
            kCFNetworkProxiesHTTPSPort as String: httpPort,
        ]
    }
}

public struct EgressAvailabilityProbe: Sendable {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    public static let maxTimeoutSeconds: TimeInterval = 6.0
    public static let defaultTimeoutSeconds: TimeInterval = 5.5

    public static let identityEndpoints: [URL] = [
        URL(string: "https://ipwho.is/")!,
        URL(string: "https://ipapi.co/json/")!,
        URL(string: "https://ipinfo.io/json")!,
    ]

    public let timeoutSeconds: TimeInterval
    private let transport: Transport

    public init(
        timeoutSeconds: TimeInterval = EgressAvailabilityProbe.defaultTimeoutSeconds,
        proxy: EgressProxyConfiguration? = nil
    ) {
        let bounded = min(max(timeoutSeconds, 1.0), Self.maxTimeoutSeconds)
        self.timeoutSeconds = bounded
        let session = Self.makeSession(timeoutSeconds: bounded, proxy: proxy)
        self.transport = { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            return (data, http)
        }
    }

    public init(
        timeoutSeconds: TimeInterval = EgressAvailabilityProbe.defaultTimeoutSeconds,
        transport: @escaping Transport
    ) {
        self.timeoutSeconds = min(max(timeoutSeconds, 1.0), Self.maxTimeoutSeconds)
        self.transport = transport
    }

    /// Runs an on-demand egress identity & service availability probe.
    /// Never persists credentials, cookies, or analytics.
    public func run(nodeName: String?) async -> EgressProbeReport {
        async let identityTask = fetchIdentity()
        async let servicesTask = probeAllServices()

        let identity = await identityTask
        let services = await servicesTask
        return EgressProbeReport(
            nodeName: nodeName,
            checkedAt: Date(),
            identity: identity,
            services: services
        )
    }

    private func fetchIdentity() async -> EgressIdentity? {
        for url in Self.identityEndpoints {
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = timeoutSeconds
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(
                "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko)",
                forHTTPHeaderField: "User-Agent"
            )
            if let (data, response) = try? await transport(request),
               (200...299).contains(response.statusCode),
               let parsed = EgressIdentityParser.parse(data: data) {
                return parsed
            }
        }
        return nil
    }

    private func probeAllServices() async -> [EgressServiceProbeResult] {
        let allServices = EgressServiceKind.allCases
        let resultsByService = await withTaskGroup(
            of: (EgressServiceKind, EgressServiceProbeResult).self,
            returning: [EgressServiceKind: EgressServiceProbeResult].self
        ) { group in
            for service in allServices {
                group.addTask {
                    let result = await probeService(service)
                    return (service, result)
                }
            }
            var collected: [EgressServiceKind: EgressServiceProbeResult] = [:]
            for await (service, result) in group {
                collected[service] = result
            }
            return collected
        }
        return allServices.map { service in
            resultsByService[service]
                ?? EgressServiceProbeResult(service: service, status: .unknown, latencyMilliseconds: nil)
        }
    }

    private func probeService(_ service: EgressServiceKind) async -> EgressServiceProbeResult {
        var request = URLRequest(url: service.probeURL)
        request.httpMethod = "GET"
        request.timeoutInterval = timeoutSeconds
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")

        let started = ContinuousClock.now
        do {
            let (data, response) = try await transport(request)
            let elapsed = ContinuousClock.now - started
            let latencyMs = max(
                1,
                Int(elapsed.components.seconds * 1_000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
            )
            let headers: [String: String] = response.allHeaderFields.reduce(into: [:]) { acc, pair in
                if let key = pair.key as? String, let value = pair.value as? String {
                    acc[key] = value
                }
            }
            // Limit body decoding to first 32 KiB to stay fast and memory-light.
            let prefix = data.prefix(32_768)
            let body = String(decoding: prefix, as: UTF8.self)
            let status = EgressServiceProbeClassifier.classify(
                service: service,
                statusCode: response.statusCode,
                headers: headers,
                body: body
            )
            return EgressServiceProbeResult(
                service: service,
                status: status,
                latencyMilliseconds: latencyMs
            )
        } catch {
            return EgressServiceProbeResult(
                service: service,
                status: .unknown,
                latencyMilliseconds: nil
            )
        }
    }

    private static func makeSession(
        timeoutSeconds: TimeInterval,
        proxy: EgressProxyConfiguration?
    ) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeoutSeconds
        configuration.timeoutIntervalForResource = timeoutSeconds
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        if let proxy {
            configuration.connectionProxyDictionary = proxy.connectionProxyDictionary
        }
        return URLSession(configuration: configuration)
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

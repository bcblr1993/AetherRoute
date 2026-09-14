import Foundation
import OSLog

public enum DiagnosticEventCode: String, Codable, CaseIterable, Sendable {
    case privacyRequired
    case preparing
    case disconnected
    case connectRequested
    case providerReady
    case disconnectRequested
    case providerFailed
    case networkExtensionConflict
    case profileImported
    case profileOperationFailed
    case subscriptionRefreshed
    case diagnosticExportRequested
    case systemSleep
    case systemWake
    case networkPathChanged
}

public struct DiagnosticEvent: Codable, Equatable, Sendable {
    public let timestampUnixMilliseconds: UInt64
    public let code: DiagnosticEventCode

    public init(
        timestampUnixMilliseconds: UInt64,
        code: DiagnosticEventCode
    ) {
        self.timestampUnixMilliseconds = timestampUnixMilliseconds
        self.code = code
    }
}

/// A process-local, fixed-code event ring. It cannot accept arbitrary messages,
/// which prevents profile contents, URLs, credentials, or traffic metadata from
/// accidentally entering a support report.
public final class DiagnosticEventBuffer: @unchecked Sendable {
    public static let maximumEvents = 128
    private static let logger = AppLog.logger(category: AppLog.Category.diagnostics)

    private let lock = NSLock()
    private let capacity: Int
    private var events: [DiagnosticEvent] = []

    public init(capacity: Int = maximumEvents) {
        self.capacity = min(max(capacity, 1), Self.maximumEvents)
    }

    public func record(
        _ code: DiagnosticEventCode,
        at date: Date = .now
    ) {
        let milliseconds = max(0, date.timeIntervalSince1970 * 1_000)
        let event = DiagnosticEvent(
            timestampUnixMilliseconds: UInt64(milliseconds),
            code: code
        )
        Self.logger.info("event=\(code.rawValue, privacy: .public)")
        lock.withLock {
            if events.count == capacity {
                events.removeFirst()
            }
            events.append(event)
        }
    }

    public func snapshot() -> [DiagnosticEvent] {
        lock.withLock { events }
    }
}

public struct DiagnosticReport: Codable, Equatable, Sendable {
    public static let schemaVersion = "AR1"

    public enum Distribution: String, Codable, Sendable {
        case independent
    }

    public enum Engine: String, Codable, Sendable {
        case transparentProxy
        case packetTunnel
    }

    public enum SessionState: String, Codable, Sendable {
        case privacyRequired
        case loading
        case disconnected
        case connecting
        case connected
        case disconnecting
        case failed
    }

    public struct Build: Codable, Equatable, Sendable {
        public let applicationVersion: String
        public let buildNumber: String
        public let operatingSystemVersion: String
        public let architecture: String
        public let distribution: Distribution

        public init(
            applicationVersion: String,
            buildNumber: String,
            operatingSystemVersion: String,
            architecture: String,
            distribution: Distribution
        ) {
            self.applicationVersion = Self.bounded(applicationVersion)
            self.buildNumber = Self.bounded(buildNumber)
            self.operatingSystemVersion = Self.bounded(
                operatingSystemVersion
            )
            self.architecture = Self.bounded(architecture)
            self.distribution = distribution
        }

        private static func bounded(_ value: String) -> String {
            let clean = value
                .replacingOccurrences(of: "\0", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return "unknown" }
            return String(clean.prefix(128))
        }
    }

    public struct Session: Codable, Equatable, Sendable {
        public let state: SessionState
        public let engine: Engine
        public let routingMode: RoutingMode

        public init(
            state: SessionState,
            engine: Engine,
            routingMode: RoutingMode
        ) {
            self.state = state
            self.engine = engine
            self.routingMode = routingMode
        }
    }

    public struct Profile: Codable, Equatable, Sendable {
        public let isLoaded: Bool
        public let usesSubscription: Bool
        public let proxyCount: Int
        public let proxyGroupCount: Int
        public let proxyProviderCount: Int
        public let ruleCount: Int
        public let ruleProviderCount: Int

        public init(
            isLoaded: Bool,
            usesSubscription: Bool,
            proxyCount: Int,
            proxyGroupCount: Int,
            proxyProviderCount: Int,
            ruleCount: Int,
            ruleProviderCount: Int
        ) {
            self.isLoaded = isLoaded
            self.usesSubscription = usesSubscription
            self.proxyCount = max(0, proxyCount)
            self.proxyGroupCount = max(0, proxyGroupCount)
            self.proxyProviderCount = max(0, proxyProviderCount)
            self.ruleCount = max(0, ruleCount)
            self.ruleProviderCount = max(0, ruleProviderCount)
        }
    }

    public struct Telemetry: Codable, Equatable, Sendable {
        public let uploadBytesPerSecond: UInt64
        public let downloadBytesPerSecond: UInt64
        public let uploadTotal: UInt64
        public let downloadTotal: UInt64
        public let memoryBytes: UInt64
        public let activeConnectionCount: Int
        /// True when the host asked for fewer connections than were open, so
        /// `activeConnectionCount` is a floor rather than a total.
        ///
        /// The snapshot truncates to the requested limit, which made a
        /// saturated tunnel report exactly "50" — a number that reads as a
        /// measurement and is really "at least 50". During an outage that is
        /// the difference between "some connections" and "connections are
        /// piling up unanswered".
        public let activeConnectionCountIsTruncated: Bool

        public init(
            uploadBytesPerSecond: UInt64,
            downloadBytesPerSecond: UInt64,
            uploadTotal: UInt64,
            downloadTotal: UInt64,
            memoryBytes: UInt64,
            activeConnectionCount: Int,
            requestedConnectionLimit: Int? = nil
        ) {
            self.uploadBytesPerSecond = uploadBytesPerSecond
            self.downloadBytesPerSecond = downloadBytesPerSecond
            self.uploadTotal = uploadTotal
            self.downloadTotal = downloadTotal
            self.memoryBytes = memoryBytes
            let bounded = min(
                max(0, activeConnectionCount),
                NetworkTelemetryCodec.maximumConnections
            )
            self.activeConnectionCount = bounded
            if let requestedConnectionLimit, requestedConnectionLimit > 0 {
                activeConnectionCountIsTruncated = bounded >= requestedConnectionLimit
            } else {
                activeConnectionCountIsTruncated = false
            }
        }

        /// How the count should be read aloud: `50+` when it is a floor.
        public var activeConnectionCountDescription: String {
            activeConnectionCountIsTruncated
                ? "\(activeConnectionCount)+"
                : "\(activeConnectionCount)"
        }
    }

    public struct Provider: Codable, Equatable, Sendable {
        public let isAvailable: Bool
        public let counters: ProviderDiagnosticSnapshot

        public init(
            isAvailable: Bool,
            counters: ProviderDiagnosticSnapshot
        ) {
            self.isAvailable = isAvailable
            self.counters = counters
        }

        public static let unavailable = Provider(
            isAvailable: false,
            counters: .empty
        )
    }

    public struct Privacy: Codable, Equatable, Sendable {
        public let omittedFields: [String]

        public init() {
            omittedFields = [
                "profile_names",
                "profile_yaml",
                "subscription_urls",
                "credentials",
                "source_addresses",
                "destination_addresses",
                "rule_payloads",
                "proxy_chains",
                "provider_error_messages",
            ]
        }
    }

    public let schema: String
    public let generatedAtUnixMilliseconds: UInt64
    public let build: Build
    public let session: Session
    public let profile: Profile
    public let telemetry: Telemetry
    public let provider: Provider
    /// Which resolver the system actually consults. Addresses only; no queried
    /// names, which is why this can ship in every build.
    public let resolver: SystemResolverPrecedence
    public let events: [DiagnosticEvent]
    public let privacy: Privacy

    public init(
        generatedAtUnixMilliseconds: UInt64,
        build: Build,
        session: Session,
        profile: Profile,
        telemetry: Telemetry,
        provider: Provider = .unavailable,
        resolver: SystemResolverPrecedence = .unavailable,
        events: [DiagnosticEvent]
    ) {
        schema = Self.schemaVersion
        self.generatedAtUnixMilliseconds = generatedAtUnixMilliseconds
        self.build = build
        self.session = session
        self.profile = profile
        self.telemetry = telemetry
        self.provider = provider
        self.resolver = resolver
        self.events = events
        privacy = Privacy()
    }
}

public enum DiagnosticReportEncodingError: Error, Equatable, Sendable {
    case tooManyEvents
    case reportTooLarge
}

public enum DiagnosticReportEncoder {
    public static let maximumReportBytes = 65_536

    public static func encode(_ report: DiagnosticReport) throws -> Data {
        guard report.events.count <= DiagnosticEventBuffer.maximumEvents else {
            throw DiagnosticReportEncodingError.tooManyEvents
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        guard data.count <= maximumReportBytes else {
            throw DiagnosticReportEncodingError.reportTooLarge
        }
        return data
    }
}

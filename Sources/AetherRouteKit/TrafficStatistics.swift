import CryptoKit
import Foundation

/// Bytes moved in each direction.
public struct TrafficVolume: Codable, Sendable, Equatable {
    public var upload: UInt64
    public var download: UInt64

    public init(upload: UInt64 = 0, download: UInt64 = 0) {
        self.upload = upload
        self.download = download
    }

    public var total: UInt64 { upload.addingReportingOverflow(download).partialValue }

    public static func += (lhs: inout TrafficVolume, rhs: TrafficVolume) {
        lhs.upload = lhs.upload.addingReportingOverflow(rhs.upload).partialValue
        lhs.download = lhs.download.addingReportingOverflow(rhs.download).partialValue
    }
}

/// One local day of traffic: the engine's exact total, and the part of it
/// that could be attributed to an app and to an exit node.
public struct TrafficDay: Codable, Sendable, Equatable, Identifiable {
    /// `yyyy-MM-dd` in the Mac's time zone when the traffic was counted.
    public let day: String
    public var total: TrafficVolume
    /// Keyed by the app's grouping key; `appNames` holds its display name.
    public var apps: [String: TrafficVolume]
    public var appNames: [String: String]
    /// Keyed by the exit (the last hop of the proxy chain, or DIRECT).
    public var nodes: [String: TrafficVolume]

    public var id: String { day }

    public init(day: String) {
        self.day = day
        total = TrafficVolume()
        apps = [:]
        appNames = [:]
        nodes = [:]
    }
}

/// The part of one sample that can be attributed, keyed the way the
/// statistics store them.
public struct TrafficSampleAttribution: Sendable, Equatable {
    public var total: TrafficVolume
    public var apps: [String: TrafficVolume]
    public var appNames: [String: String]
    public var nodes: [String: TrafficVolume]

    public init(
        total: TrafficVolume = TrafficVolume(),
        apps: [String: TrafficVolume] = [:],
        appNames: [String: String] = [:],
        nodes: [String: TrafficVolume] = [:]
    ) {
        self.total = total
        self.apps = apps
        self.appNames = appNames
        self.nodes = nodes
    }

    public var isEmpty: Bool { total.total == 0 }
}

/// Turns successive telemetry samples into traffic deltas.
///
/// The overall total comes from the engine's monotonic counters, so it is
/// exact however rarely samples arrive. An engine that reports `ART3`
/// lifetime totals per (app, chain) gives an equally exact split. With an
/// older engine the split falls back to each listed connection's growth
/// between samples; a connection that opens and closes between two samples,
/// or falls outside the listed connections, then counts toward the total but
/// not toward an app or node.
public struct TrafficStatisticsAccumulator: Sendable {
    public struct AppKey: Sendable, Equatable {
        public let key: String
        public let name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    /// Resolves an app from its signing identifier and executable path.
    public typealias AppResolver = (_ identifier: String, _ path: String) -> AppKey

    private var lastTotal: TrafficVolume?
    private var lastConnections: [String: TrafficVolume] = [:]
    /// The last value seen for each lifetime total. A total missing from one
    /// sample (it fell out of the engine's bounded list) keeps its value, so
    /// its return is not counted twice.
    private var lastTrafficTotals: [String: TrafficVolume] = [:]

    public init() {}

    /// Forgets the previous sample, for example after the tunnel stopped:
    /// the next sample only sets a new baseline.
    public mutating func reset() {
        lastTotal = nil
        lastConnections = [:]
        lastTrafficTotals = [:]
    }

    public mutating func ingest(
        _ snapshot: NetworkTelemetrySnapshot,
        appKey: AppResolver
    ) -> TrafficSampleAttribution {
        let currentTotal = TrafficVolume(
            upload: snapshot.uploadTotal,
            download: snapshot.downloadTotal
        )
        var attribution = TrafficSampleAttribution()
        let engineRestarted = lastTotal.map {
            currentTotal.upload < $0.upload || currentTotal.download < $0.download
        } ?? false
        if let lastTotal {
            // Counters only fall when the engine restarted; its new totals
            // are then all new traffic.
            attribution.total = engineRestarted
                ? currentTotal
                : TrafficVolume(
                    upload: currentTotal.upload - lastTotal.upload,
                    download: currentTotal.download - lastTotal.download
                )
        }
        if engineRestarted {
            lastConnections = [:]
            lastTrafficTotals = [:]
        }

        if snapshot.reportsTrafficTotals {
            for total in snapshot.trafficTotals {
                let key = [total.sourceAppIdentifier, total.sourceAppPath, total.proxyChain]
                    .joined(separator: "\u{0}")
                let volume = TrafficVolume(
                    upload: total.uploadTotal,
                    download: total.downloadTotal
                )
                let previous = lastTrafficTotals[key]
                lastTrafficTotals[key] = volume
                guard lastTotal != nil else { continue }
                // A total first seen now moved all of its bytes since the
                // last sample. One that shrank lost bytes the engine could
                // not keep; only growth is new traffic.
                let delta = Self.growth(from: previous ?? TrafficVolume(), to: volume)
                guard delta.total > 0 else { continue }
                let app = appKey(total.sourceAppIdentifier, total.sourceAppPath)
                attribution.apps[app.key, default: TrafficVolume()] += delta
                attribution.appNames[app.key] = app.name
                attribution.nodes[Self.exit(ofChain: total.proxyChain), default: TrafficVolume()] += delta
            }
            lastConnections = [:]
        } else {
            var current: [String: TrafficVolume] = [:]
            for connection in snapshot.connections {
                let key = Self.connectionKey(connection)
                let volume = TrafficVolume(
                    upload: connection.uploadTotal,
                    download: connection.downloadTotal
                )
                current[key] = volume
                guard lastTotal != nil else { continue }
                let delta = Self.growth(from: lastConnections[key] ?? TrafficVolume(), to: volume)
                guard delta.total > 0 else { continue }
                let app = appKey(connection.sourceAppIdentifier, connection.sourceAppPath)
                attribution.apps[app.key, default: TrafficVolume()] += delta
                attribution.appNames[app.key] = app.name
                attribution.nodes[Self.exit(of: connection), default: TrafficVolume()] += delta
            }
            lastConnections = current
        }
        lastTotal = currentTotal
        return attribution
    }

    private static func growth(from previous: TrafficVolume, to current: TrafficVolume) -> TrafficVolume {
        TrafficVolume(
            upload: current.upload >= previous.upload ? current.upload - previous.upload : 0,
            download: current.download >= previous.download ? current.download - previous.download : 0
        )
    }

    /// The last hop of a proxy chain ("Auto → HK 01" is "HK 01").
    public static func exit(of connection: ConnectionTelemetry) -> String {
        exit(ofChain: connection.proxyChain)
    }

    public static func exit(ofChain chain: String) -> String {
        let hops = chain
            .components(separatedBy: " → ")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return hops.last ?? "DIRECT"
    }

    private static func connectionKey(_ connection: ConnectionTelemetry) -> String {
        [
            String(connection.transport.rawValue),
            connection.destination,
            String(connection.destinationPort),
            String(connection.startedAtUnixMilliseconds),
            connection.sourceAppIdentifier,
            connection.sourceAppPath,
        ].joined(separator: "\u{0}")
    }
}

/// Days of traffic, newest last, bounded in days and in entries per day.
public struct TrafficStatisticsLedger: Codable, Sendable, Equatable {
    public static let retainedDays = 31
    public static let maximumEntriesPerDay = 200

    public private(set) var days: [TrafficDay]

    public init(days: [TrafficDay] = []) {
        self.days = days
    }

    public mutating func add(_ sample: TrafficSampleAttribution, day: String) {
        guard !sample.isEmpty else { return }
        if days.last?.day != day {
            days.append(TrafficDay(day: day))
            if days.count > Self.retainedDays {
                days.removeFirst(days.count - Self.retainedDays)
            }
        }
        var today = days[days.count - 1]
        today.total += sample.total
        for (key, volume) in sample.apps {
            guard today.apps[key] != nil || today.apps.count < Self.maximumEntriesPerDay
            else { continue }
            today.apps[key, default: TrafficVolume()] += volume
            if let name = sample.appNames[key] { today.appNames[key] = name }
        }
        for (key, volume) in sample.nodes {
            guard today.nodes[key] != nil || today.nodes.count < Self.maximumEntriesPerDay
            else { continue }
            today.nodes[key, default: TrafficVolume()] += volume
        }
        days[days.count - 1] = today
    }

    /// The traffic of the last `count` calendar days up to and including the
    /// day of `date`, summed. Days with no traffic count toward the range,
    /// so "today" is empty until something moves today.
    public func summary(
        lastDays count: Int,
        endingAt date: Date = Date(),
        calendar: Calendar = .current
    ) -> TrafficDay {
        var result = TrafficDay(day: "")
        guard count > 0 else { return result }
        let end = calendar.startOfDay(for: date)
        let included = Set((0..<count).compactMap { offset in
            calendar.date(byAdding: .day, value: -offset, to: end)
                .map { Self.dayKey(for: $0, calendar: calendar) }
        })
        for day in days where included.contains(day.day) {
            result.total += day.total
            for (key, volume) in day.apps {
                result.apps[key, default: TrafficVolume()] += volume
                if let name = day.appNames[key] { result.appNames[key] = name }
            }
            for (key, volume) in day.nodes {
                result.nodes[key, default: TrafficVolume()] += volume
            }
        }
        return result
    }

    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0
        )
    }
}

/// Keeps the ledger in the app's own Application Support folder, sealed with
/// AES-256-GCM under the same Keychain key as the profiles: which apps were
/// used and through which nodes is as private as the profiles themselves.
/// Only this Mac reads it; it is excluded from backups, never syncs and is
/// never part of a diagnostic report.
public struct TrafficStatisticsStore: Sendable {
    public static let maximumSealedBytes = 4 * 1_024 * 1_024
    static let formatVersion = 1
    static let algorithm = "AES-256-GCM"
    static let purpose = "AetherRoute.TrafficStatistics"

    public let fileURL: URL
    private let keyStore: any ProfileKeyStoring
    private let keyID = EncryptedProfileCodec.defaultKeyID

    public init(
        fileURL: URL,
        keyStore: any ProfileKeyStoring = DataProtectionProfileKeyStore()
    ) {
        self.fileURL = fileURL
        self.keyStore = keyStore
    }

    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> TrafficStatisticsStore {
        TrafficStatisticsStore(
            fileURL: try directory(fileManager: fileManager)
                .appendingPathComponent("TrafficStatistics.v1.sealed", isDirectory: false)
        )
    }

    private static func directory(fileManager: FileManager) throws -> URL {
        try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("AetherRoute", isDirectory: true)
    }

    private struct Envelope: Codable {
        let formatVersion: Int
        let algorithm: String
        let keyID: String
        let sealedBox: Data
    }

    /// The saved ledger, or an empty one when there is none or it cannot be
    /// opened (for example after the Keychain key was removed).
    public func load() -> TrafficStatisticsLedger {
        (try? open()) ?? TrafficStatisticsLedger()
    }

    func open() throws -> TrafficStatisticsLedger {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= Self.maximumSealedBytes else {
            throw CocoaError(.fileReadTooLarge)
        }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard
            envelope.formatVersion == Self.formatVersion,
            envelope.algorithm == Self.algorithm,
            envelope.keyID == keyID
        else { throw CocoaError(.fileReadCorruptFile) }
        let key = SymmetricKey(data: try keyStore.loadKey(keyID: envelope.keyID))
        let plaintext = try AES.GCM.open(
            AES.GCM.SealedBox(combined: envelope.sealedBox),
            using: key,
            authenticating: authenticatedData
        )
        return try JSONDecoder().decode(TrafficStatisticsLedger.self, from: plaintext)
    }

    public func save(_ ledger: TrafficStatisticsLedger) throws {
        let fileManager = FileManager.default
        let key = SymmetricKey(data: try keyStore.loadOrCreateKey(keyID: keyID))
        let box = try AES.GCM.seal(
            try JSONEncoder().encode(ledger),
            using: key,
            authenticating: authenticatedData
        )
        guard let combined = box.combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Envelope(
            formatVersion: Self.formatVersion,
            algorithm: Self.algorithm,
            keyID: keyID,
            sealedBox: combined
        ))
        guard data.count <= Self.maximumSealedBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        // Builds before the ledger was sealed wrote it in plain JSON.
        try? fileManager.removeItem(
            at: directory.appendingPathComponent("TrafficStatistics.json", isDirectory: false)
        )
    }

    public func clear() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        try? fileManager.removeItem(
            at: fileURL.deletingLastPathComponent()
                .appendingPathComponent("TrafficStatistics.json", isDirectory: false)
        )
    }

    private var authenticatedData: Data {
        Data("\(Self.purpose)|\(Self.formatVersion)|\(keyID)".utf8)
    }
}

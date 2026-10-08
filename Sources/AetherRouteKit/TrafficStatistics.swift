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
/// exact however rarely samples arrive. The split by app and node comes from
/// each listed connection's growth between samples; a connection that opens
/// and closes between two samples, or falls outside the listed connections,
/// counts toward the total but not toward an app or node.
public struct TrafficStatisticsAccumulator: Sendable {
    public struct AppKey: Sendable, Equatable {
        public let key: String
        public let name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    private var lastTotal: TrafficVolume?
    private var lastConnections: [String: TrafficVolume] = [:]

    public init() {}

    /// Forgets the previous sample, for example after the tunnel stopped:
    /// the next sample only sets a new baseline.
    public mutating func reset() {
        lastTotal = nil
        lastConnections = [:]
    }

    public mutating func ingest(
        _ snapshot: NetworkTelemetrySnapshot,
        appKey: (ConnectionTelemetry) -> AppKey
    ) -> TrafficSampleAttribution {
        let currentTotal = TrafficVolume(
            upload: snapshot.uploadTotal,
            download: snapshot.downloadTotal
        )
        var attribution = TrafficSampleAttribution()
        if let lastTotal {
            // Counters only fall when the engine restarted; its new totals
            // are then all new traffic.
            attribution.total = TrafficVolume(
                upload: currentTotal.upload >= lastTotal.upload
                    ? currentTotal.upload - lastTotal.upload : currentTotal.upload,
                download: currentTotal.download >= lastTotal.download
                    ? currentTotal.download - lastTotal.download : currentTotal.download
            )
        }

        var current: [String: TrafficVolume] = [:]
        for connection in snapshot.connections {
            let key = Self.connectionKey(connection)
            let volume = TrafficVolume(
                upload: connection.uploadTotal,
                download: connection.downloadTotal
            )
            current[key] = volume
            guard lastTotal != nil else { continue }
            let previous = lastConnections[key] ?? TrafficVolume()
            let delta = TrafficVolume(
                upload: volume.upload >= previous.upload ? volume.upload - previous.upload : 0,
                download: volume.download >= previous.download ? volume.download - previous.download : 0
            )
            guard delta.total > 0 else { continue }
            let app = appKey(connection)
            attribution.apps[app.key, default: TrafficVolume()] += delta
            attribution.appNames[app.key] = app.name
            attribution.nodes[Self.exit(of: connection), default: TrafficVolume()] += delta
        }
        lastConnections = current
        lastTotal = currentTotal
        return attribution
    }

    /// The last hop of a proxy chain ("Auto → HK 01" is "HK 01").
    public static func exit(of connection: ConnectionTelemetry) -> String {
        let hops = connection.proxyChain
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

    /// The days within the last `count` days, summed.
    public func summary(lastDays count: Int) -> TrafficDay {
        var result = TrafficDay(day: "")
        for day in days.suffix(max(0, count)) {
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

/// Keeps the ledger in the app's own Application Support folder. Only this
/// Mac reads it; it never syncs and is never part of a diagnostic report.
public struct TrafficStatisticsStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func applicationSupport(
        fileManager: FileManager = .default
    ) throws -> TrafficStatisticsStore {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return TrafficStatisticsStore(
            fileURL: base
                .appendingPathComponent("AetherRoute", isDirectory: true)
                .appendingPathComponent("TrafficStatistics.json", isDirectory: false)
        )
    }

    public func load() -> TrafficStatisticsLedger {
        guard let data = try? Data(contentsOf: fileURL),
              let ledger = try? JSONDecoder().decode(TrafficStatisticsLedger.self, from: data)
        else { return TrafficStatisticsLedger() }
        return ledger
    }

    public func save(_ ledger: TrafficStatisticsLedger) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try JSONEncoder().encode(ledger).write(to: fileURL, options: [.atomic])
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.removeItem(at: fileURL)
        }
    }
}

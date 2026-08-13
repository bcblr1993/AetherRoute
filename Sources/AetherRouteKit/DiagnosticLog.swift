import Darwin
import Foundation
import OSLog

/// Gated diagnostic logging for the connection hot path.
///
/// Every call site takes an `@autoclosure` message. When the active level does
/// not admit that record the closure is never evaluated, so the interpolation,
/// the `os_log` store write, and the file append all disappear. This is the
/// difference between a diagnostic switch and a permanent tax: an ungated
/// `logger.notice("… \(value)")` still formats its argument even when nobody
/// will ever read it.
///
/// The level is shared through the App Group so the host app and both Network
/// Extensions agree without an IPC round trip. Each process re-reads it when
/// the backing file's modification date changes.
public final class DiagnosticLog: @unchecked Sendable {
    /// How often a process notices a level change made by the app.
    public static let levelRefreshInterval: TimeInterval = 5

    private let category: String
    private let logger: Logger
    private let sink: RotatingLogSink?
    private let levelProvider: @Sendable () -> DiagnosticLogLevel
    private let timestamp: @Sendable () -> Date

    public init(
        category: String,
        sink: RotatingLogSink?,
        levelProvider: @escaping @Sendable () -> DiagnosticLogLevel,
        subsystem: String = "com.aetherroute.desktop",
        timestamp: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.category = category
        self.logger = Logger(subsystem: subsystem, category: category)
        self.sink = sink
        self.levelProvider = levelProvider
        self.timestamp = timestamp
    }

    public var level: DiagnosticLogLevel { levelProvider() }

    /// Per-flow detail. Suppressed unless the user selects verbose.
    public func verbose(_ message: @autoclosure () -> String) {
        guard levelProvider().recordsPerFlow else { return }
        emit(message(), marker: "V")
    }

    /// Aggregate counters and lifecycle milestones. Cheap at any traffic
    /// volume because it does not scale with flow count.
    public func aggregate(_ message: @autoclosure () -> String) {
        guard levelProvider().recordsAggregates else { return }
        emit(message(), marker: "A")
    }

    /// Always recorded to `os_log`; additionally written to the rotating file
    /// whenever debug mode is on. Failures must remain visible with the switch
    /// off, otherwise a field report has nothing to attach.
    public func failure(_ message: @autoclosure () -> String) {
        let text = message()
        logger.error("\(text, privacy: .public)")
        guard levelProvider().recordsAggregates else { return }
        sink?.append(line(text, marker: "E"))
    }

    private func emit(_ text: String, marker: String) {
        logger.notice("\(text, privacy: .public)")
        sink?.append(line(text, marker: marker))
    }

    private func line(_ text: String, marker: String) -> String {
        "\(Self.format(timestamp())) \(marker) [\(category)] \(text)"
    }

    /// `ISO8601DateFormatter` is not `Sendable`, and guarding a shared one with
    /// a lock would put contention on the connection hot path. `gmtime_r` is
    /// thread-safe by contract and needs no shared mutable state.
    static func format(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        var raw = time_t(seconds.rounded(.down))
        var parts = tm()
        gmtime_r(&raw, &parts)
        let milliseconds = Int((seconds - seconds.rounded(.down)) * 1_000)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ",
            parts.tm_year + 1_900,
            parts.tm_mon + 1,
            parts.tm_mday,
            parts.tm_hour,
            parts.tm_min,
            parts.tm_sec,
            milliseconds
        )
    }
}

/// Caches the shared level and refreshes it when the backing file changes.
/// Reading a cached value costs a lock; it must be safe to call per flow.
public final class DiagnosticLogLevelCache: @unchecked Sendable {
    private let store: DiagnosticLogLevelStore
    private let refreshInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cached: DiagnosticLogLevel
    private var lastCheck: Date
    private var lastModified: Date?

    public init(
        store: DiagnosticLogLevelStore,
        refreshInterval: TimeInterval = DiagnosticLog.levelRefreshInterval,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.store = store
        self.refreshInterval = refreshInterval
        self.now = now
        cached = store.load()
        lastCheck = now()
        lastModified = store.modificationDate()
    }

    public func level() -> DiagnosticLogLevel {
        let moment = now()
        lock.lock()
        if moment.timeIntervalSince(lastCheck) < refreshInterval {
            defer { lock.unlock() }
            return cached
        }
        lastCheck = moment
        let previous = lastModified
        lock.unlock()

        let modified = store.modificationDate()
        guard modified != previous else {
            lock.lock()
            defer { lock.unlock() }
            return cached
        }

        let reloaded = store.load()
        lock.lock()
        defer { lock.unlock() }
        lastModified = modified
        cached = reloaded
        return reloaded
    }
}

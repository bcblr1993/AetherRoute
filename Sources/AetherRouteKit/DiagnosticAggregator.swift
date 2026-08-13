import Foundation

/// Traffic-independent summary of what the data plane did.
///
/// The standard debug level records this instead of per-flow detail. Counting
/// is O(1) per event and emission happens on a fixed interval, so the cost does
/// not grow with traffic — which is what makes the level safe to leave on.
public struct DiagnosticAggregateSnapshot: Sendable, Equatable {
    public var flowsAdmitted = 0
    public var flowsBypassed = 0
    public var tcpOpened = 0
    public var tcpOpenFailed = 0
    public var udpOpened = 0
    public var udpOpenFailed = 0
    public var bytesToUpstream = 0
    public var bytesToClient = 0
    public var admissionRejected = 0
    public var sessionsFailed = 0

    public var isEmpty: Bool { self == DiagnosticAggregateSnapshot() }

    public var summary: String {
        """
        flows=\(flowsAdmitted) bypass=\(flowsBypassed) \
        tcpOpen=\(tcpOpened)/\(tcpOpened + tcpOpenFailed) \
        udpOpen=\(udpOpened)/\(udpOpened + udpOpenFailed) \
        up=\(bytesToUpstream) down=\(bytesToClient) \
        admissionRejected=\(admissionRejected) sessionsFailed=\(sessionsFailed)
        """
    }
}

public enum DiagnosticCounter: Sendable {
    case flowAdmitted
    case flowBypassed
    case tcpOpened
    case tcpOpenFailed
    case udpOpened
    case udpOpenFailed
    case admissionRejected
    case sessionFailed
}

/// Thread-safe counters plus a periodic emitter.
///
/// `record` is called from flow callbacks, so it only takes a lock and mutates
/// integers. Emission runs on its own timer and resets the window, making each
/// line a delta rather than a running total — a delta is what tells you whether
/// a problem is happening *now*.
public final class DiagnosticAggregator: @unchecked Sendable {
    public static let defaultInterval: TimeInterval = 60

    private let log: DiagnosticLog
    private let interval: TimeInterval
    private let lock = NSLock()
    private var snapshot = DiagnosticAggregateSnapshot()
    private var timer: DispatchSourceTimer?

    public init(
        log: DiagnosticLog,
        interval: TimeInterval = DiagnosticAggregator.defaultInterval
    ) {
        self.log = log
        self.interval = interval
    }

    public func record(_ counter: DiagnosticCounter, count: Int = 1) {
        lock.lock()
        defer { lock.unlock() }
        switch counter {
        case .flowAdmitted: snapshot.flowsAdmitted += count
        case .flowBypassed: snapshot.flowsBypassed += count
        case .tcpOpened: snapshot.tcpOpened += count
        case .tcpOpenFailed: snapshot.tcpOpenFailed += count
        case .udpOpened: snapshot.udpOpened += count
        case .udpOpenFailed: snapshot.udpOpenFailed += count
        case .admissionRejected: snapshot.admissionRejected += count
        case .sessionFailed: snapshot.sessionsFailed += count
        }
    }

    public func recordBytes(toUpstream: Int = 0, toClient: Int = 0) {
        lock.lock()
        defer { lock.unlock() }
        snapshot.bytesToUpstream += toUpstream
        snapshot.bytesToClient += toClient
    }

    public func start(queue: DispatchQueue = .global(qos: .utility)) {
        lock.lock()
        let alreadyRunning = timer != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + interval, repeating: interval)
        source.setEventHandler { [weak self] in self?.emit() }
        lock.lock()
        timer = source
        lock.unlock()
        source.resume()
    }

    public func stop() {
        lock.lock()
        let source = timer
        timer = nil
        lock.unlock()
        source?.cancel()
        emit()
    }

    /// Drains the window and records it. A window with no activity is skipped
    /// so an idle tunnel does not fill the log with zeroes.
    public func emit() {
        lock.lock()
        let drained = snapshot
        snapshot = DiagnosticAggregateSnapshot()
        lock.unlock()

        guard !drained.isEmpty else { return }
        log.aggregate("stage=aggregate window=\(Int(interval))s \(drained.summary)")
    }

    public func current() -> DiagnosticAggregateSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshot
    }
}

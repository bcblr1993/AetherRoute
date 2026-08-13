import Foundation

/// Bridges flow-open outcomes from the Apple access layer to whichever
/// aggregator the running provider owns.
///
/// The access layer sits below the provider and must not depend on it, but the
/// open success/failure ratio is the single most useful health number this
/// product has — it is what distinguished "the proxy is broken" from "one app
/// is spamming an unreachable endpoint". A one-way observer keeps the counting
/// available without inverting the module dependency.
public final class DiagnosticFlowOpenObserver: @unchecked Sendable {
    public static let shared = DiagnosticFlowOpenObserver()

    private let lock = NSLock()
    private var aggregator: DiagnosticAggregator?

    private init() {}

    public func attach(_ aggregator: DiagnosticAggregator) {
        lock.lock()
        defer { lock.unlock() }
        self.aggregator = aggregator
    }

    public func detach() {
        lock.lock()
        defer { lock.unlock() }
        aggregator = nil
    }

    public func record(transport: String, succeeded: Bool) {
        lock.lock()
        let target = aggregator
        lock.unlock()
        guard let target else { return }
        switch (transport, succeeded) {
        case ("tcp", true): target.record(.tcpOpened)
        case ("tcp", false): target.record(.tcpOpenFailed)
        case ("udp", true): target.record(.udpOpened)
        case ("udp", false): target.record(.udpOpenFailed)
        default: break
        }
    }
}

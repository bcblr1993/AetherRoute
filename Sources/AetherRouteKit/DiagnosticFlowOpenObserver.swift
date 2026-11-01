import Foundation

/// Routes native open outcomes and confirmed TCP/UDP writes to the running
/// provider's aggregate counters, without coupling the pump to the provider.
/// No endpoint, payload or error description crosses this boundary.
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

    public func record(_ counter: DiagnosticCounter) {
        lock.lock()
        let target = aggregator
        lock.unlock()
        target?.record(counter)
    }

    public func record(transport: String, succeeded: Bool) {
        switch (transport, succeeded) {
        case ("tcp", true): record(.tcpOpened)
        case ("tcp", false): record(.tcpOpenFailed)
        case ("udp", true): record(.udpOpened)
        case ("udp", false): record(.udpOpenFailed)
        default: break
        }
    }
}

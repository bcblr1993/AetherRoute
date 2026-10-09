import Foundation

/// Enqueue directly from the owner of the ledger, so save/clear ordering is
/// fixed before any asynchronous work starts. All disk I/O stays off the UI.
public final class TrafficStatisticsWriter: Sendable {
    private let queue = DispatchQueue(label: "com.aetherroute.traffic-statistics", qos: .utility)
    private let pending = DispatchGroup()
    private let saveLedger: @Sendable (TrafficStatisticsLedger) throws -> Void
    private let clearLedger: @Sendable () throws -> Void

    public init(
        save: @escaping @Sendable (TrafficStatisticsLedger) throws -> Void = {
            try TrafficStatisticsStore.applicationSupport().save($0)
        },
        clear: @escaping @Sendable () throws -> Void = {
            try TrafficStatisticsStore.applicationSupport().clear()
        }
    ) {
        saveLedger = save
        clearLedger = clear
    }

    public func save(
        _ ledger: TrafficStatisticsLedger,
        completion: @escaping @Sendable (Bool) -> Void
    ) {
        pending.enter()
        queue.async { [saveLedger, pending] in
            defer { pending.leave() }
            do {
                try saveLedger(ledger)
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    public func clear(completion: @escaping @Sendable (Bool) -> Void) {
        pending.enter()
        queue.async { [clearLedger, pending] in
            defer { pending.leave() }
            do {
                try clearLedger()
                completion(true)
            } catch {
                completion(false)
            }
        }
    }

    public var hasPendingOperations: Bool {
        pending.wait(timeout: .now()) != .success
    }

    /// Wait for writes already enqueued before allowing process termination.
    public func flush() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}

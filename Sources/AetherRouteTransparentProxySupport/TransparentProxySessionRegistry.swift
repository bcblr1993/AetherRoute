import Foundation

public protocol TransparentProxySessionLifetime: AnyObject, Sendable {
    var sessionID: UUID { get }

    /// True for datagram associations that may be evicted in LRU order when
    /// global session or resource capacity is saturated, preventing 120s idle
    /// UDP flows from starving newly arriving TCP or DNS flows.
    var isEvictableUDPSession: Bool { get }

    /// Monotonic uptime timestamp of the last datagram transfer (or creation).
    var lastActivityUptimeNanoseconds: UInt64 { get }

    /// Releases admission budget immediately upon eviction while retaining
    /// native/Rust handles until their async destruction barrier finishes.
    func reclaimAdmissionSlotForEviction()

    /// Idempotently starts cancellation. Implementations report termination to
    /// the registry only after native flow closure and the Rust destroy barrier
    /// have both returned.
    func cancel()
}

public extension TransparentProxySessionLifetime {
    var isEvictableUDPSession: Bool { false }
    var lastActivityUptimeNanoseconds: UInt64 { 0 }
    func reclaimAdmissionSlotForEviction() {}
}

public enum TransparentProxySessionRegistryError:
    Error,
    Sendable,
    Equatable
{
    case invalidCapacity
    case notAccepting
    case capacityExceeded
    case duplicateSessionIdentifier
}

public struct TransparentProxySessionRegistrySnapshot: Sendable, Equatable {
    public enum Lifecycle: Sendable, Equatable {
        case accepting
        case stopping
        case stopped
    }

    public let lifecycle: Lifecycle
    public let activeSessionCount: Int
    public let maximumSessionCount: Int
}

/// Thread-safe ownership boundary for every flow claimed from
/// `NETransparentProxyProvider`. `stopAll` is a true completion barrier: its
/// callbacks do not run until every session has independently acknowledged
/// that its Rust handle is destroyed and no callback can arrive afterward.
public final class TransparentProxySessionRegistry: @unchecked Sendable {
    public static let defaultMaximumSessionCount = 4_096

    public typealias StopCompletion = @Sendable () -> Void

    private let maximumSessionCount: Int
    private let lock = NSLock()
    private var lifecycle: TransparentProxySessionRegistrySnapshot.Lifecycle =
        .accepting
    private var sessions: [UUID: any TransparentProxySessionLifetime] = [:]
    private var evictingSessions: [UUID: any TransparentProxySessionLifetime] = [:]
    private var stopCompletions: [StopCompletion] = []

    public init(
        maximumSessionCount: Int = defaultMaximumSessionCount
    ) throws {
        guard maximumSessionCount > 0 else {
            throw TransparentProxySessionRegistryError.invalidCapacity
        }
        self.maximumSessionCount = maximumSessionCount
    }

    /// Evicts the least-recently-active UDP session so a newly arriving TCP or
    /// DNS flow is never starved by 120s idle UDP associations. The evicted
    /// session remains tracked in `evictingSessions` until `didTerminate` so
    /// `stopAll` continues to act as a strict destruction barrier.
    @discardableResult
    public func evictOldestUDPSession() -> Bool {
        let victim = lock.withLock { () -> (any TransparentProxySessionLifetime)? in
            guard lifecycle == .accepting else { return nil }
            guard let oldest = sessions.values
                .filter(\.isEvictableUDPSession)
                .min(by: { $0.lastActivityUptimeNanoseconds < $1.lastActivityUptimeNanoseconds })
            else {
                return nil
            }
            sessions.removeValue(forKey: oldest.sessionID)
            evictingSessions[oldest.sessionID] = oldest
            return oldest
        }
        guard let victim else { return false }
        victim.reclaimAdmissionSlotForEviction()
        victim.cancel()
        return true
    }

    /// The session itself owns the Apple flow, so a successful insertion is
    /// the synchronous retention point required before a provider returns true.
    public func insert(
        _ session: any TransparentProxySessionLifetime
    ) throws {
        var evictedVictim: (any TransparentProxySessionLifetime)?
        try lock.withLock {
            guard lifecycle == .accepting else {
                throw TransparentProxySessionRegistryError.notAccepting
            }
            guard sessions[session.sessionID] == nil,
                  evictingSessions[session.sessionID] == nil else {
                throw TransparentProxySessionRegistryError
                    .duplicateSessionIdentifier
            }
            if sessions.count >= maximumSessionCount {
                if let oldestUDP = sessions.values
                    .filter(\.isEvictableUDPSession)
                    .min(by: { $0.lastActivityUptimeNanoseconds < $1.lastActivityUptimeNanoseconds }) {
                    sessions.removeValue(forKey: oldestUDP.sessionID)
                    evictingSessions[oldestUDP.sessionID] = oldestUDP
                    evictedVictim = oldestUDP
                } else {
                    throw TransparentProxySessionRegistryError.capacityExceeded
                }
            }
            sessions[session.sessionID] = session
        }
        if let evictedVictim {
            evictedVictim.reclaimAdmissionSlotForEviction()
            evictedVictim.cancel()
        }
    }

    /// Must be called exactly once by a real session after all of its native
    /// destruction barriers return. Duplicate/unknown reports are harmless.
    public func didTerminate(sessionID: UUID) {
        let action = lock.withLock { () -> TerminationAction in
            // Return the removed strong reference as part of the action. Its
            // deinitializer may call arbitrary cleanup code, including back
            // into this registry, and therefore must never run under `lock`.
            let removed = sessions.removeValue(forKey: sessionID)
                ?? evictingSessions.removeValue(forKey: sessionID)
            guard let removed else {
                return .none
            }
            guard lifecycle == .stopping,
                  sessions.isEmpty,
                  evictingSessions.isEmpty else {
                return .release(removed, completions: [])
            }
            lifecycle = .stopped
            defer { stopCompletions.removeAll(keepingCapacity: false) }
            return .release(removed, completions: stopCompletions)
        }

        switch action {
        case .none:
            break
        case let .release(removed, completions):
            // Merely binding `removed` here ensures any final release occurs
            // after the lock has been left. Stop callbacks then observe a
            // registry with no retained session.
            withExtendedLifetime(removed) {}
            completions.forEach { $0() }
        }
    }

    public func stopAll(completion: @escaping StopCompletion) {
        let action = lock.withLock { () -> StopAction in
            switch lifecycle {
            case .stopped:
                return .complete([completion])
            case .stopping:
                stopCompletions.append(completion)
                return .none
            case .accepting:
                lifecycle = .stopping
                stopCompletions.append(completion)
                guard !sessions.isEmpty || !evictingSessions.isEmpty else {
                    lifecycle = .stopped
                    let completions = stopCompletions
                    stopCompletions.removeAll(keepingCapacity: false)
                    return .complete(completions)
                }
                return .cancel(Array(sessions.values) + Array(evictingSessions.values))
            }
        }

        switch action {
        case .none:
            break
        case let .cancel(sessions):
            sessions.forEach { $0.cancel() }
        case let .complete(completions):
            completions.forEach { $0() }
        }
    }

    /// Cancels all currently active sessions without changing the registry's lifecycle state.
    /// This allows stale pre-sleep connections to be terminated cleanly so clients reconnect.
    public func cancelActiveSessions() {
        let activeSessions = lock.withLock { () -> [any TransparentProxySessionLifetime] in
            guard lifecycle == .accepting else { return [] }
            return Array(sessions.values)
        }
        activeSessions.forEach { $0.cancel() }
    }

    public func snapshot() -> TransparentProxySessionRegistrySnapshot {
        lock.withLock {
            TransparentProxySessionRegistrySnapshot(
                lifecycle: lifecycle,
                activeSessionCount: sessions.count,
                maximumSessionCount: maximumSessionCount
            )
        }
    }

    private enum StopAction {
        case none
        case cancel([any TransparentProxySessionLifetime])
        case complete([StopCompletion])
    }

    private enum TerminationAction {
        case none
        case release(
            any TransparentProxySessionLifetime,
            completions: [StopCompletion]
        )
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}

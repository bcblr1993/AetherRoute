import AetherRouteKit
import Foundation
import OSLog

public enum TransparentFlowResourceKind: Sendable, Equatable {
    case tcp
    case udp

    /// Steady-state admission charge for a live flow: the copied read buffer,
    /// both state-machine directions, and bounded FFI operation storage.
    ///
    /// These are accounting reservations, not allocations, and they must track
    /// what a flow actually holds rather than the ceiling it may briefly reach
    /// under backpressure. Charging every flow its worst case reserves the peak
    /// for all flows simultaneously, which collapses concurrency: the previous
    /// 3 MiB/10 MiB charges admitted only 85 TCP or 25 UDP flows against a
    /// 256 MiB budget, while `TransparentProxySessionRegistry` was sized for
    /// 4,096 sessions. A single page load with QUIC exhausted it instantly.
    ///
    /// The per-flow worst case stays bounded where it belongs — the staging
    /// ceilings in `AppleFlowAdapters` and `TCPFlowStateMachine` — so this
    /// budget remains a global backstop rather than the binding limit.
    public var reservationBytes: Int {
        switch self {
        case .tcp:
            // 64 KiB read buffer plus state-machine and FFI overhead.
            256 * 1_024
        case .udp:
            // Datagram staging runs deeper than TCP, so it charges more.
            512 * 1_024
        }
    }
}

public enum FlowResourceBudgetError: Error, Sendable, Equatable {
    case invalidMaximumBytes
    case exhausted
}

public struct FlowResourceBudgetSnapshot: Sendable, Equatable {
    public let maximumBytes: Int
    public let reservedBytes: Int
    public let activeLeaseCount: Int
}

/// Weighted admission control for complete transparent-proxy flow lifetimes.
/// A session must own a lease before it can retain/open an Apple flow, and may
/// release it only after the Rust destroy and Apple-open callback barriers.
public final class FlowResourceBudget: @unchecked Sendable {
    /// Global accounting ceiling. With the steady-state charges above this
    /// admits roughly 2,048 concurrent TCP or 1,024 concurrent UDP flows, so
    /// the session registry's 4,096-session limit is the intended binding
    /// constraint for ordinary traffic instead of this backstop.
    public static let defaultMaximumBytes = 512 * 1_024 * 1_024

    private static let logger = AppLog.logger(category: AppLog.Category.proxyBudget)

    private let maximumBytes: Int
    private let lock = NSLock()
    private var reservedBytes = 0
    private var activeLeaseCount = 0

    public init(maximumBytes: Int = defaultMaximumBytes) throws {
        guard maximumBytes > 0 else {
            throw FlowResourceBudgetError.invalidMaximumBytes
        }
        self.maximumBytes = maximumBytes
    }

    public func lease(
        for kind: TransparentFlowResourceKind
    ) throws -> FlowResourceLease {
        let bytes = kind.reservationBytes
        let outcome = lock.withLock { () -> (Bool, Int, Int) in
            guard bytes <= maximumBytes - reservedBytes else {
                return (false, reservedBytes, activeLeaseCount)
            }
            reservedBytes += bytes
            activeLeaseCount += 1
            return (true, reservedBytes, activeLeaseCount)
        }
        guard outcome.0 else {
            // Admission exhaustion silently drops user traffic, so it must be
            // observable with the numbers needed to retune the charges.
            Self.logger.error(
                """
                stage=flowBudgetExhausted \
                kind=\(String(describing: kind), privacy: .public) \
                requestedBytes=\(bytes, privacy: .public) \
                reservedBytes=\(outcome.1, privacy: .public) \
                maximumBytes=\(self.maximumBytes, privacy: .public) \
                activeLeases=\(outcome.2, privacy: .public)
                """
            )
            throw FlowResourceBudgetError.exhausted
        }
        return FlowResourceLease(budget: self, kind: kind, bytes: bytes)
    }

    public func snapshot() -> FlowResourceBudgetSnapshot {
        lock.withLock {
            FlowResourceBudgetSnapshot(
                maximumBytes: maximumBytes,
                reservedBytes: reservedBytes,
                activeLeaseCount: activeLeaseCount
            )
        }
    }

    fileprivate func release(bytes: Int) {
        lock.withLock {
            guard activeLeaseCount > 0, bytes <= reservedBytes else { return }
            reservedBytes -= bytes
            activeLeaseCount -= 1
        }
    }
}

public final class FlowResourceLease: @unchecked Sendable {
    public let kind: TransparentFlowResourceKind
    public let reservedBytes: Int

    private let lock = NSLock()
    private var budget: FlowResourceBudget?
    private var state: State = .available

    fileprivate init(
        budget: FlowResourceBudget,
        kind: TransparentFlowResourceKind,
        bytes: Int
    ) {
        self.budget = budget
        self.kind = kind
        self.reservedBytes = bytes
    }

    func claim(expectedKind: TransparentFlowResourceKind) -> Bool {
        lock.withLock {
            guard kind == expectedKind, state == .available else {
                return false
            }
            state = .claimed
            return true
        }
    }

    func release() {
        let budget = lock.withLock { () -> FlowResourceBudget? in
            guard state != .released else { return nil }
            state = .released
            defer { self.budget = nil }
            return self.budget
        }
        budget?.release(bytes: reservedBytes)
    }

    deinit {
        release()
    }

    private enum State {
        case available
        case claimed
        case released
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

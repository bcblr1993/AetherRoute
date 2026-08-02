import Foundation

public enum TransparentFlowResourceKind: Sendable, Equatable {
    case tcp
    case udp

    /// Conservative admission charge for the largest raw Apple callback,
    /// copied/staged data, both state-machine directions, and bounded FFI
    /// operation storage. These are accounting reservations, not allocations.
    public var reservationBytes: Int {
        switch self {
        case .tcp:
            3 * 1_024 * 1_024
        case .udp:
            10 * 1_024 * 1_024
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
    public static let defaultMaximumBytes = 256 * 1_024 * 1_024

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
        let accepted = lock.withLock { () -> Bool in
            guard bytes <= maximumBytes - reservedBytes else { return false }
            reservedBytes += bytes
            activeLeaseCount += 1
            return true
        }
        guard accepted else { throw FlowResourceBudgetError.exhausted }
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

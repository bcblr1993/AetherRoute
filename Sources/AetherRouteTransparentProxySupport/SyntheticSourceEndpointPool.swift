import AetherRouteKit
import Foundation

public enum SyntheticSourceEndpointPoolError: Error, Sendable, Equatable {
    case invalidPortRange
    case exhausted
}

/// Issues unique, process-local UDP source endpoints when NetworkExtension
/// cannot expose the socket's bound address. The endpoint is only an identity
/// key for the embedded flow engine; it is never bound on the host network.
///
/// A lease keeps its port reserved for the complete flow lifetime and releases
/// it exactly once, including on early-startup failure through `deinit`.
public final class SyntheticSourceEndpointPool: @unchecked Sendable {
    public static let defaultPortRange: ClosedRange<UInt16> = 49_152...65_535

    private let portRange: ClosedRange<UInt16>
    private let lock = NSLock()
    private var nextPort: UInt16
    private var leasedPorts: Set<UInt16> = []

    public init(
        portRange: ClosedRange<UInt16> = defaultPortRange
    ) throws {
        guard portRange.lowerBound > 0 else {
            throw SyntheticSourceEndpointPoolError.invalidPortRange
        }
        self.portRange = portRange
        self.nextPort = portRange.lowerBound
    }

    public func leaseUDP() throws -> SyntheticSourceEndpointLease {
        let port = try lock.withLock { () throws -> UInt16 in
            let capacity =
                Int(portRange.upperBound) - Int(portRange.lowerBound) + 1
            var candidate = nextPort

            for _ in 0..<capacity {
                if leasedPorts.insert(candidate).inserted {
                    nextPort = successor(of: candidate)
                    return candidate
                }
                candidate = successor(of: candidate)
            }
            throw SyntheticSourceEndpointPoolError.exhausted
        }

        let endpoint = FlowEndpoint(
            host: .ipv4([0, 0, 0, 0]),
            port: port,
            transport: .udp
        )
        return SyntheticSourceEndpointLease(
            endpoint: endpoint,
            pool: self,
            port: port
        )
    }

    public var activeLeaseCount: Int {
        lock.withLock { leasedPorts.count }
    }

    fileprivate func release(port: UInt16) {
        lock.withLock {
            _ = leasedPorts.remove(port)
        }
    }

    private func successor(of port: UInt16) -> UInt16 {
        port == portRange.upperBound ? portRange.lowerBound : port + 1
    }
}

public final class SyntheticSourceEndpointLease: @unchecked Sendable {
    public let endpoint: FlowEndpoint

    private let lock = NSLock()
    private var pool: SyntheticSourceEndpointPool?
    private let port: UInt16
    private var state: State = .available

    fileprivate init(
        endpoint: FlowEndpoint,
        pool: SyntheticSourceEndpointPool,
        port: UInt16
    ) {
        self.endpoint = endpoint
        self.pool = pool
        self.port = port
    }

    func claim() -> Bool {
        lock.withLock {
            guard state == .available else { return false }
            state = .claimed
            return true
        }
    }

    func release() {
        let pool = lock.withLock { () -> SyntheticSourceEndpointPool? in
            guard state != .released else { return nil }
            state = .released
            defer { self.pool = nil }
            return self.pool
        }
        pool?.release(port: port)
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
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}

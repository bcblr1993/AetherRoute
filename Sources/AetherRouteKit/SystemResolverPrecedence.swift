import Foundation

/// Whether the system is actually asking the tunnel's resolver.
///
/// A packet tunnel installs its own DNS server and marks it as matching every
/// domain, but macOS decides between two VPNs that both claim every domain by
/// service order, not by that claim. When another VPN wins, every lookup
/// bypasses the tunnel: the rule engine then sees a bare address instead of a
/// hostname, and on a network that poisons DNS the address is wrong. The tunnel
/// reports itself connected, its counters stay at zero, and nothing resolves.
///
/// That outage is invisible in a report that carries no DNS information — it
/// cost a live debugging session to identify, and the answer was one line of
/// `scutil --dns`. This value type records the comparison so the report can
/// say it outright.
public struct SystemResolverPrecedence: Codable, Equatable, Sendable {
    /// Resolver addresses the system consults first, in order.
    public let primaryServers: [String]
    /// Resolver addresses the tunnel asked the system to use.
    public let tunnelServers: [String]

    /// Upper bound on recorded addresses. A report is a bounded artefact, and
    /// a host with many interfaces can list a surprising number of resolvers.
    public static let maximumRecordedServers = 8

    public init(primaryServers: [String], tunnelServers: [String]) {
        self.primaryServers = Array(
            primaryServers.prefix(Self.maximumRecordedServers)
        )
        self.tunnelServers = Array(
            tunnelServers.prefix(Self.maximumRecordedServers)
        )
    }

    /// True when the tunnel installed a resolver and the system prefers a
    /// different one.
    ///
    /// Deliberately not "the lists differ": a system that lists the tunnel's
    /// resolver first alongside others is working as intended. What matters is
    /// whether any tunnel resolver appears at all.
    public var isPreempted: Bool {
        guard !tunnelServers.isEmpty, !primaryServers.isEmpty else {
            return false
        }
        return !primaryServers.contains { tunnelServers.contains($0) }
    }

    /// The resolver the system reaches first, for the report's summary line.
    public var effectivePrimaryServer: String? { primaryServers.first }

    /// Nothing to compare: either the tunnel is down or the query failed.
    public static let unavailable = SystemResolverPrecedence(
        primaryServers: [],
        tunnelServers: []
    )
}

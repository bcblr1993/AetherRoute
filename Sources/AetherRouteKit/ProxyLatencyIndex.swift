/// One member's last measurement, and how much that number is worth.
///
/// A bare TCP handshake to the node's address proves the socket opened. It
/// does not prove the node's protocol, credentials, or egress still work, so a
/// reachable-but-unusable node would otherwise show the same green number as a
/// working one. `verified` is what lets the list say which of the two it is.
public enum ProxyLatencyMeasurement: Equatable, Sendable {
    /// Latency from a bare TCP handshake to the node's advertised endpoint.
    case reachable(UInt32)
    /// Latency measured by the protocol core through the node's real handler.
    case verified(UInt32)
    case timedOut

    public var delayMilliseconds: UInt32? {
        switch self {
        case let .reachable(value), let .verified(value): value
        case .timedOut: nil
        }
    }

    public var isVerified: Bool {
        if case .verified = self { return true }
        return false
    }
}

/// App-side staging area for user-initiated latency measurement.
///
/// `TunnelManager.proxyLatencies` stays the published, wire-shaped truth that
/// automatic route selection and every view read. This index sits behind it:
/// merging one arriving result is O(1) here, and rebuilding the published
/// arrays happens once per flush window rather than once per result.
///
/// That difference is the whole point. The previous merge rescanned every
/// group's member array for each result and reassigned the full `@Published`
/// dictionary, so a 5,000-member group cost on the order of N x M string
/// comparisons plus N full-array copies on the main actor. Here it costs one
/// dictionary write per result and one rebuild per flush.
public struct ProxyLatencyIndex {
    /// group -> member -> last measurement.
    private var measurements: [String: [String: ProxyLatencyMeasurement]] = [:]
    /// group -> the members actually shown for it, in display order.
    private var groupMembers: [String: [String]] = [:]
    /// member -> every group that lists it. Built once per run so a
    /// cross-group merge never rescans group membership.
    private var membership: [String: [String]] = [:]
    /// Group names, so a member that is itself a strategy group is never
    /// probed as if it were a node.
    private var groupNames: Set<String> = []
    /// Declaration order, which `aggregateChildGroups` walks in reverse to
    /// resolve nested groups bottom-up.
    private var orderedGroups: [String] = []

    public init() {}

    /// Rebuilds the reverse index for one measurement run.
    ///
    /// `groups` must carry the members actually shown for each group, which is
    /// the live selector snapshot when there is one and the profile summary
    /// otherwise.
    public mutating func beginRun(groups: [(name: String, members: [String])]) {
        membership.removeAll(keepingCapacity: true)
        groupMembers.removeAll(keepingCapacity: true)
        groupNames = Set(groups.map(\.name))
        orderedGroups = groups.map(\.name)
        for group in groups {
            groupMembers[group.name] = group.members
            for member in group.members {
                membership[member, default: []].append(group.name)
            }
        }
    }

    public var groupCount: Int { orderedGroups.count }

    /// Members that need probing: every unique member across all groups, minus
    /// the ones that are strategy groups rather than nodes.
    ///
    /// Probing a group name would look up an endpoint that does not exist and
    /// report a timeout, which the UI then showed as a red row until the
    /// aggregation pass overwrote it. Excluding them here removes that flicker
    /// instead of repairing it afterwards.
    public var probeTargets: [String] {
        var targets: [String] = []
        var seen = Set<String>()
        for group in orderedGroups {
            for member in groupMembers[group] ?? [] where !groupNames.contains(member) {
                if seen.insert(member).inserted {
                    targets.append(member)
                }
            }
        }
        return targets
    }

    /// Clears one group so its rows fall back to "testing" while a fresh run
    /// is in flight.
    public mutating func clear(group: String) {
        measurements[group] = [:]
    }

    public mutating func clearAll() {
        for group in orderedGroups {
            measurements[group] = [:]
        }
    }

    public mutating func clear(member: String, in group: String) {
        measurements[group]?[member] = nil
    }

    /// Records one result in every group that lists the member, and returns
    /// those groups so the caller can mark exactly them dirty.
    @discardableResult
    public mutating func merge(
        member: String,
        measurement: ProxyLatencyMeasurement
    ) -> [String] {
        let groups = membership[member] ?? []
        for group in groups {
            measurements[group, default: [:]][member] = measurement
        }
        return groups
    }

    public func measurement(for member: String, in group: String) -> ProxyLatencyMeasurement? {
        measurements[group]?[member]
    }

    public func isVerified(member: String, in group: String) -> Bool {
        measurements[group]?[member]?.isVerified ?? false
    }

    /// Every group that lists the member, for callers that need to mark rows
    /// dirty without merging a result.
    public func groups(containing member: String) -> [String] {
        membership[member] ?? []
    }

    /// Materializes one group in the wire shape the published property and the
    /// automatic selector already consume.
    public func state(for group: String) -> ProxyLatencyState {
        let entries = measurements[group] ?? [:]
        let order = groupMembers[group] ?? []
        // Emit in display order so the published array is stable between
        // flushes and SwiftUI diffs cleanly.
        var results: [ProxyLatencyResult] = []
        results.reserveCapacity(entries.count)
        for member in order {
            guard let measurement = entries[member] else { continue }
            results.append(
                ProxyLatencyResult(
                    member: member,
                    delayMilliseconds: measurement.delayMilliseconds
                )
            )
        }
        return ProxyLatencyState(results: results)
    }

    /// Propagates each strategy group's best child latency up to the rows that
    /// reference that group as a member.
    ///
    /// Resolution walks reverse declaration order and repeats until nothing
    /// changes, so a group nested two or more levels deep resolves regardless
    /// of the order it was declared in. The previous single pass in
    /// declaration order left deeper nesting showing whatever that one pass
    /// happened to produce.
    /// Returns every group whose rows changed, so the caller publishes exactly
    /// those rather than guessing.
    @discardableResult
    public mutating func aggregateChildGroups() -> Set<String> {
        var touched: Set<String> = []
        var didChange = true
        var passes = 0
        // Each pass resolves at least one more level; the bound only stops a
        // pathological cyclic profile from spinning.
        let maximumPasses = max(1, orderedGroups.count)
        while didChange, passes < maximumPasses {
            didChange = false
            passes += 1
            for group in orderedGroups.reversed() {
                for member in groupMembers[group] ?? [] where groupNames.contains(member) {
                    let childEntries = measurements[member] ?? [:]
                    // A child group nobody has measured stays unmeasured.
                    // Reporting a timeout for it would claim a failure that
                    // was never observed, which is what a single-group run
                    // would otherwise do to every sibling group it lists.
                    if childEntries.isEmpty { continue }
                    // The parent inherits its best child whole, confidence
                    // included: if the fastest usable child was core-verified,
                    // the parent row is reporting a verified path.
                    let resolved = childEntries.values
                        .filter { $0.delayMilliseconds != nil }
                        .min { lhs, rhs in
                            (lhs.delayMilliseconds ?? .max)
                                < (rhs.delayMilliseconds ?? .max)
                        } ?? .timedOut
                    if measurements[group]?[member] != resolved {
                        measurements[group, default: [:]][member] = resolved
                        touched.insert(group)
                        didChange = true
                    }
                }
            }
        }
        return touched
    }
}

/// How a member responded the last time it was measured.
///
/// This is the single definition of the four-state machine. The app's
/// `ProxyLatencyStatus` adds presentation on top of it and delegates the
/// decision here, so a rule change cannot land in one copy and be missed by
/// the other. The test suite previously mirrored this logic by hand, which
/// meant the test and the product had to be edited together to stay in
/// agreement and a test pass only proved the two copies matched.
public enum ProxyLatencyReading: Equatable, Sendable {
    case untested
    case testing
    case responded(UInt32)
    case timedOut

    /// Derives a member's reading from the three sources that know about it:
    /// the last returned results, the in-flight request set, and the absence
    /// of any result at all.
    ///
    /// A present result wins over the testing flag. That ordering is what lets
    /// a group sweep stream: a member that has already answered shows its
    /// number while its slower neighbours still read as testing. It also means
    /// a fresh run has to clear the group's old results, or the previous
    /// numbers would sit there for the whole sweep.
    public static func resolve(
        member: String,
        results: [ProxyLatencyResult]?,
        isTesting: Bool
    ) -> ProxyLatencyReading {
        if let result = results?.first(where: { $0.member == member }) {
            guard let delay = result.delayMilliseconds else { return .timedOut }
            return .responded(delay)
        }
        if isTesting { return .testing }
        return .untested
    }
}

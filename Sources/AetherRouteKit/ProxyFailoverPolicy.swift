import Foundation

/// Decisions of failover mode, kept free of I/O so they can be tested.
public enum ProxyFailoverPolicy {
    /// The preferred node: the stored one while the group still lists it,
    /// otherwise the node in use, otherwise the group's first real node.
    public static func preferredMember(
        stored: String?,
        current: String?,
        members: [String]
    ) -> String? {
        let candidates = members.filter(InitialProxySelectionPolicy.isRouteCandidate)
        if let stored, candidates.contains(stored) { return stored }
        if let current, candidates.contains(current) { return current }
        return candidates.first
    }

    /// Puts the preferred node first when it is among the candidates; the
    /// others keep their latency order.
    public static func orderedCandidates(
        _ candidates: [String],
        preferred: String?
    ) -> [String] {
        guard let preferred, candidates.contains(preferred) else {
            return candidates
        }
        return [preferred] + candidates.filter { $0 != preferred }
    }

    /// Computes a composite quality score (lower is better) incorporating current
    /// latency alongside historical jitter and packet-loss rate so unstable
    /// nodes are penalized in auto-selection.
    public static func effectiveScore(
        latencyMilliseconds: UInt32,
        stats: ProxyLatencyStats?
    ) -> Double {
        let base = Double(latencyMilliseconds)
        guard let stats else { return base }
        let jitterPenalty = Double(stats.jitterMilliseconds ?? 0) * 1.5
        let lossPenalty = min(1.0, max(0.0, stats.lossRate)) * 2_000.0
        return base + jitterPenalty + lossPenalty
    }

    /// Orders route candidates by stability-adjusted score (penalizing high
    /// packet-loss and high-jitter nodes) while preserving `preferred` first
    /// when failover pinning is active.
    public static func orderedCandidates(
        _ candidates: [String],
        preferred: String?,
        latencyByMember: [String: UInt32],
        statsByMember: [String: ProxyLatencyStats]
    ) -> [String] {
        let indexByCandidate = Dictionary(
            uniqueKeysWithValues: candidates.enumerated().map { ($1, $0) }
        )
        let sortedByStability = candidates.sorted { lhs, rhs in
            let lhsScore = effectiveScore(
                latencyMilliseconds: latencyByMember[lhs] ?? UInt32.max,
                stats: statsByMember[lhs]
            )
            let rhsScore = effectiveScore(
                latencyMilliseconds: latencyByMember[rhs] ?? UInt32.max,
                stats: statsByMember[rhs]
            )
            if lhsScore != rhsScore {
                return lhsScore < rhsScore
            }
            return (indexByCandidate[lhs] ?? 0) < (indexByCandidate[rhs] ?? 0)
        }
        return orderedCandidates(sortedByStability, preferred: preferred)
    }

    /// Which connections to drop after an automatic switch.
    ///
    /// Moving away from a node that stopped answering drops what still runs
    /// through that node: those connections cannot recover, and apps only
    /// reconnect once they are closed. Returning to the preferred node keeps
    /// the working backup's existing streams alive; new connections use the
    /// preferred node. The manual-switch preference must not interrupt an
    /// automatic recovery.
    public static func closeRequest(
        reason: ProxySwitchEvent.Reason,
        group: String,
        previousMember: String?,
        closesConnectionsOnSwitch: Bool
    ) -> ConnectionCloseRequest? {
        switch reason {
        case .unresponsive:
            guard let previousMember,
                  InitialProxySelectionPolicy.isRouteCandidate(previousMember)
            else { return nil }
            return .proxyChainMember(previousMember)
        case .preferredRecovered:
            return nil
        }
    }

    /// Whether a scan for the preferred node is due while a backup is in use.
    public static func recoveryScanIsDue(
        lastScan: Date?,
        now: Date,
        interval: TimeInterval = TimeInterval(
            TunnelStartupTimingPolicy.failoverRecoveryScanIntervalSeconds
        )
    ) -> Bool {
        guard let lastScan else { return true }
        return now.timeIntervalSince(lastScan) >= interval
    }
}

/// Counts consecutive scans in which the preferred node answered. A switch
/// back needs several in a row, so a node that answers now and then does not
/// pull traffic back and forth.
public struct ProxyFailoverRecoveryTracker: Equatable, Sendable {
    public let requiredStreak: Int
    public private(set) var streaks: [String: Int] = [:]

    public init(
        requiredStreak: Int = TunnelStartupTimingPolicy.failoverRecoveryRequiredStreak
    ) {
        self.requiredStreak = max(1, requiredStreak)
    }

    /// Records one scan and returns whether the group should switch back.
    public mutating func record(group: String, preferredResponded: Bool) -> Bool {
        guard preferredResponded else {
            streaks[group] = nil
            return false
        }
        let streak = (streaks[group] ?? 0) + 1
        streaks[group] = streak
        return streak >= requiredStreak
    }

    public mutating func reset(group: String) {
        streaks[group] = nil
    }

    public mutating func resetAll() {
        streaks = [:]
    }
}

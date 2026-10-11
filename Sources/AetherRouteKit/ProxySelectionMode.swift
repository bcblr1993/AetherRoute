import Foundation

/// How a `select` group chooses its node (1.6.0).
///
/// - `manual`: the person's choice is kept, even when it stops answering, so
///   a pinned node never silently hands traffic to another one.
/// - `fastest`: the group uses the fastest node that passes a real probe and
///   moves on when it stops answering.
/// - `failover`: the person's choice is the preferred node. When it stops
///   answering the group moves to the fastest working sibling, and returns
///   once the preferred node has answered again for a while.
public enum ProxySelectionMode: String, CaseIterable, Sendable, Codable {
    case manual
    case fastest
    case failover

    /// The host checks the route's health and may change its node.
    public var switchesAutomatically: Bool { self != .manual }

    /// Reads a stored mode. Before 1.6.0 only an on/off "pick the fastest
    /// node" switch existed; on means `fastest`.
    public static func resolve(stored: String?, legacyAutomatic: Bool) -> Self {
        if let stored, let mode = Self(rawValue: stored) {
            return mode
        }
        return legacyAutomatic ? .fastest : .manual
    }
}

/// One automatic node change, kept in memory for the current run only: node
/// names never reach disk or notifications through this record.
public struct ProxySwitchEvent: Equatable, Sendable, Identifiable {
    public enum Reason: String, Equatable, Sendable {
        /// The node in use stopped answering and a working one took over.
        case unresponsive
        /// The preferred node answered again and took over from the backup.
        case preferredRecovered
    }

    public let id: UUID
    public let date: Date
    public let group: String
    public let from: String?
    public let to: String
    public let reason: Reason

    public init(
        id: UUID = UUID(),
        date: Date,
        group: String,
        from: String?,
        to: String,
        reason: Reason
    ) {
        self.id = id
        self.date = date
        self.group = group
        self.from = from
        self.to = to
        self.reason = reason
    }
}

/// The most recent automatic switches, newest first.
public struct ProxySwitchLog: Equatable, Sendable {
    public static let capacity = 20

    public private(set) var events: [ProxySwitchEvent] = []

    public init(events: [ProxySwitchEvent] = []) {
        self.events = Array(events.prefix(Self.capacity))
    }

    public mutating func record(_ event: ProxySwitchEvent) {
        events.insert(event, at: 0)
        if events.count > Self.capacity {
            events.removeLast(events.count - Self.capacity)
        }
    }

    public func events(forGroup group: String) -> [ProxySwitchEvent] {
        events.filter { $0.group == group }
    }

    public func latest(forGroup group: String) -> ProxySwitchEvent? {
        events.first { $0.group == group }
    }
}

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

    /// Which connections to drop after an automatic switch.
    ///
    /// Moving away from a node that stopped answering drops what still runs
    /// through that node: those connections cannot recover, and apps only
    /// reconnect once they are closed. Returning to the preferred node from a
    /// working backup follows the "close connections when switching nodes"
    /// setting, because the backup's connections still work.
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
            return closesConnectionsOnSwitch ? .proxyChainMember(group) : nil
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

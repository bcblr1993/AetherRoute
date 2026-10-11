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

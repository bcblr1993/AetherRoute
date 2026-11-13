import Foundation

public struct ProxyLatencyResult: Sendable, Equatable {
    public let member: String
    public let delayMilliseconds: UInt32?

    public init(member: String, delayMilliseconds: UInt32?) {
        self.member = member
        self.delayMilliseconds = delayMilliseconds
    }
}

public struct ProxyLatencyState: Sendable, Equatable {
    public let results: [ProxyLatencyResult]

    public init(results: [ProxyLatencyResult]) {
        self.results = results
    }
}

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

    private var measuredAt: [String: [String: Date]] = [:]
    private var measuredSeq: [String: [String: UInt64]] = [:]
    private var nextSequence: UInt64 = 0
    private var testURL: String?
    private var activeRoutes: [String: [String]] = [:]
    /// Bounded per-member history sample (`nil` latency represents a timeout / packet loss).
    public static let maxHistoryCount = 24

    /// Readiness probes have a different destination and budget. They never
    /// supply display readings, confidence badges or freshness timestamps.
    public private(set) var routeHealth: [String: ProxyLatencyState] = [:]
    private var historyByMember: [String: [ProxyLatencySample]] = [:]

    public init() {}

    public mutating func recordRouteHealth(
        _ state: ProxyLatencyState,
        group: String,
        recordHistory: Bool = false,
        at date: Date = .now
    ) {
        routeHealth[group] = state
        if recordHistory {
            for result in state.results where !groupNames.contains(result.member) {
                appendSample(
                    ProxyLatencySample(
                        latencyMilliseconds: result.delayMilliseconds,
                        testedAt: date
                    ),
                    for: result.member
                )
            }
        }
    }

    public mutating func recordSample(
        for member: String,
        latencyMilliseconds: UInt32?,
        at date: Date = .now
    ) {
        appendSample(
            ProxyLatencySample(
                latencyMilliseconds: latencyMilliseconds,
                testedAt: date
            ),
            for: member
        )
    }

    private mutating func appendSample(
        _ sample: ProxyLatencySample,
        for member: String
    ) {
        var samples = historyByMember[member] ?? []
        samples.append(sample)
        if samples.count > Self.maxHistoryCount {
            samples.removeFirst(samples.count - Self.maxHistoryCount)
        }
        historyByMember[member] = samples
    }

    public func history(for member: String) -> [ProxyLatencySample] {
        historyByMember[member] ?? []
    }

    public func stats(for member: String) -> ProxyLatencyStats {
        ProxyLatencyStats(samples: history(for: member))
    }

    public func jitterMilliseconds(for member: String) -> UInt32? {
        stats(for: member).jitterMilliseconds
    }

    public func lossRate(for member: String) -> Double {
        stats(for: member).lossRate
    }

    public func statsSnapshot(for members: [String]) -> [String: ProxyLatencyStats] {
        var result: [String: ProxyLatencyStats] = [:]
        result.reserveCapacity(members.count)
        for member in members {
            let memberStats = stats(for: member)
            if !memberStats.samples.isEmpty {
                result[member] = memberStats
            }
        }
        return result
    }

    /// Rebuilds the reverse index for one measurement run.
    ///
    /// `groups` must carry the members actually shown for each group, which is
    /// the live selector snapshot when there is one and the profile summary
    /// otherwise.
    public mutating func beginRun(
        groups: [(name: String, members: [String])],
        testURL: String? = nil,
        selectedMembers: [String: String] = [:]
    ) {
        if self.testURL != testURL {
            measurements.removeAll()
            measuredAt.removeAll()
            measuredSeq.removeAll()
            self.testURL = testURL
        }
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
        // A group alias belongs to its current route, not just its name.
        // Invalidate aliases above a changed nested selector as well.
        var routes: [String: [String]] = [:]
        for group in groupNames {
            var chain: [String] = []
            var cursor = group
            var seen: Set<String> = []
            while seen.insert(cursor).inserted, let selected = selectedMembers[cursor] {
                chain.append(selected)
                cursor = selected
            }
            routes[group] = chain
            if activeRoutes[group] != chain {
                for parent in membership[group] ?? [] {
                    clear(member: group, in: parent)
                }
            }
        }
        activeRoutes = routes
    }

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
        measuredAt[group] = [:]
        measuredSeq[group] = [:]
    }

    public mutating func clearAll() {
        for group in orderedGroups { clear(group: group) }
    }

    public mutating func clear(member: String, in group: String) {
        measurements[group]?[member] = nil
        measuredAt[group]?[member] = nil
        measuredSeq[group]?[member] = nil
    }

    /// Records one result in every group that lists the member, and returns
    /// those groups so the caller can mark exactly them dirty.
    @discardableResult
    public mutating func merge(
        member: String,
        measurement: ProxyLatencyMeasurement,
        at date: Date = .now
    ) -> [String] {
        nextSequence &+= 1
        let seq = nextSequence
        let groups = membership[member] ?? []
        for group in groups {
            measurements[group, default: [:]][member] = measurement
            measuredAt[group, default: [:]][member] = date
            measuredSeq[group, default: [:]][member] = seq
        }
        if !groupNames.contains(member) {
            appendSample(
                ProxyLatencySample(
                    latencyMilliseconds: measurement.delayMilliseconds,
                    testedAt: date
                ),
                for: member
            )
        }
        return groups
    }

    public mutating func recordDirect(
        member: String,
        measurement: ProxyLatencyMeasurement,
        in group: String,
        at date: Date = .now
    ) {
        nextSequence &+= 1
        measurements[group, default: [:]][member] = measurement
        measuredAt[group, default: [:]][member] = date
        measuredSeq[group, default: [:]][member] = nextSequence
        if !groupNames.contains(member) {
            appendSample(
                ProxyLatencySample(
                    latencyMilliseconds: measurement.delayMilliseconds,
                    testedAt: date
                ),
                for: member
            )
        }
    }

    public func measurementDates(for group: String) -> [String: Date] {
        measuredAt[group] ?? [:]
    }

    /// A menu opening never treats an old reading as a new test. Reachability
    /// results also need upgrading once a protocol core becomes available.
    public func needsRefresh(
        group: String,
        now: Date = .now,
        maximumAge: TimeInterval = 60,
        requiresVerified: Bool = true
    ) -> Bool {
        let members = groupMembers[group] ?? []
        guard !members.isEmpty else { return false }
        return members.contains { member in
            guard let measurement = measurements[group]?[member],
                  let date = measuredAt[group]?[member] else { return true }
            let age = now.timeIntervalSince(date)
            if age < 0 || age >= maximumAge { return true }
            if requiresVerified, case .reachable = measurement { return true }
            return false
        }
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

    /// Only the active child can describe a strategy group's actual route.
    /// Unknown groups stay unmeasured until their active leaf is measured.
    /// A newer leaf measurement updates every referencing parent/child group,
    /// while a strictly newer explicit probe of the group itself is preserved.
    @discardableResult
    public mutating func aggregateChildGroups(
        selectedMembers: [String: String] = [:]
    ) -> Set<String> {
        var touched: Set<String> = []
        for _ in 0..<max(1, orderedGroups.count) {
            var changed = false
            for group in orderedGroups.reversed() {
                for member in groupMembers[group] ?? [] where groupNames.contains(member) {
                    guard let selected = selectedMembers[member],
                          let resolved = measurements[member]?[selected],
                          let date = measuredAt[member]?[selected] else { continue }
                    let childSeq = measuredSeq[member]?[selected] ?? 0
                    if let existingDate = measuredAt[group]?[member] {
                        if existingDate > date { continue }
                        if existingDate == date,
                           let existingSeq = measuredSeq[group]?[member],
                           existingSeq > childSeq {
                            continue
                        }
                    }
                    if measurements[group]?[member] != resolved
                        || measuredAt[group]?[member] != date
                        || measuredSeq[group]?[member] != childSeq {
                        measurements[group, default: [:]][member] = resolved
                        measuredAt[group, default: [:]][member] = date
                        measuredSeq[group, default: [:]][member] = childSeq
                        touched.insert(group)
                        changed = true
                    }
                }
            }
            if !changed { break }
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

/// One historical probe outcome stored in `ProxyLatencyIndex`'s bounded ring buffer.
public struct ProxyLatencySample: Equatable, Hashable, Sendable {
    public let latencyMilliseconds: UInt32?
    public let testedAt: Date

    public init(latencyMilliseconds: UInt32?, testedAt: Date = .now) {
        self.latencyMilliseconds = latencyMilliseconds
        self.testedAt = testedAt
    }
}

/// Aggregated stability statistics computed from a node's recent latency samples.
public struct ProxyLatencyStats: Equatable, Sendable {
    public let samples: [ProxyLatencySample]
    public let jitterMilliseconds: UInt32?
    public let lossRate: Double
    public let averageLatencyMilliseconds: UInt32?

    public init(
        samples: [ProxyLatencySample],
        jitterMilliseconds: UInt32?,
        lossRate: Double,
        averageLatencyMilliseconds: UInt32?
    ) {
        self.samples = samples
        self.jitterMilliseconds = jitterMilliseconds
        self.lossRate = min(1.0, max(0.0, lossRate))
        self.averageLatencyMilliseconds = averageLatencyMilliseconds
    }

    public init(samples: [ProxyLatencySample]) {
        self.samples = samples
        guard !samples.isEmpty else {
            self.jitterMilliseconds = nil
            self.lossRate = 0.0
            self.averageLatencyMilliseconds = nil
            return
        }

        var successfulLatencies: [UInt32] = []
        successfulLatencies.reserveCapacity(samples.count)
        var timedOutCount = 0
        for sample in samples {
            if let ms = sample.latencyMilliseconds {
                successfulLatencies.append(ms)
            } else {
                timedOutCount += 1
            }
        }

        self.lossRate = Double(timedOutCount) / Double(samples.count)
        if successfulLatencies.isEmpty {
            self.averageLatencyMilliseconds = nil
        } else {
            let total = successfulLatencies.reduce(0 as UInt64) { $0 + UInt64($1) }
            self.averageLatencyMilliseconds = UInt32(
                (Double(total) / Double(successfulLatencies.count)).rounded()
            )
        }

        if successfulLatencies.count >= 2 {
            var deltaSum: UInt64 = 0
            for idx in 1..<successfulLatencies.count {
                let prev = Int64(successfulLatencies[idx - 1])
                let curr = Int64(successfulLatencies[idx])
                deltaSum += UInt64(abs(curr - prev))
            }
            let meanDelta = Double(deltaSum) / Double(successfulLatencies.count - 1)
            self.jitterMilliseconds = UInt32(meanDelta.rounded())
        } else {
            self.jitterMilliseconds = nil
        }
    }
}

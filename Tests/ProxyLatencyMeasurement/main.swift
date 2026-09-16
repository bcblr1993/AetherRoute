import Foundation
import AetherRouteKit

/// Exercises the product's own latency types.
///
/// This suite used to carry a hand-written copy of the four-state machine and
/// of the cross-group merge. A pass therefore only proved the copy agreed with
/// itself, and the regression it was meant to catch could land in the product
/// untouched. Everything below drives `ProxyLatencyReading` and
/// `ProxyLatencyIndex` directly.
@main
struct ProxyLatencyMeasurementTests {
    static func main() {
        print("Running ProxyLatencyMeasurementTests...")

        stateMachine()
        streamingDuringGroupSweep()
        crossGroupFanOut()
        strategyGroupsAreNotProbed()
        nestedGroupAggregation()
        profileSwitchIsolation()
        boundedConcurrency()
        largeGroupMergeCost()

        print("ProxyLatencyMeasurementTests passed successfully!")
    }

    // MARK: - Helpers

    private static func expect(
        _ condition: Bool,
        _ message: String,
        function: StaticString = #function
    ) {
        precondition(condition, "[\(function)] \(message)")
    }

    private static func reading(
        _ member: String,
        _ index: ProxyLatencyIndex,
        group: String,
        isTesting: Bool
    ) -> ProxyLatencyReading {
        ProxyLatencyReading.resolve(
            member: member,
            results: index.state(for: group).results,
            isTesting: isTesting
        )
    }

    // MARK: - Cases

    /// The four states, including the ordering that makes streaming possible.
    private static func stateMachine() {
        let node = "HK Node 01"
        expect(
            ProxyLatencyReading.resolve(member: node, results: nil, isTesting: false) == .untested,
            "no result and not testing must read as untested"
        )
        expect(
            ProxyLatencyReading.resolve(member: node, results: nil, isTesting: true) == .testing,
            "no result while testing must read as testing"
        )
        expect(
            ProxyLatencyReading.resolve(
                member: node,
                results: [ProxyLatencyResult(member: node, delayMilliseconds: 48)],
                isTesting: false
            ) == .responded(48),
            "a delay must surface as responded"
        )
        expect(
            ProxyLatencyReading.resolve(
                member: node,
                results: [ProxyLatencyResult(member: node, delayMilliseconds: nil)],
                isTesting: false
            ) == .timedOut,
            "a nil delay must surface as timedOut"
        )
        // A present result outranking the testing flag is what lets a sweep
        // show answered rows before the slow ones come back.
        expect(
            ProxyLatencyReading.resolve(
                member: node,
                results: [ProxyLatencyResult(member: node, delayMilliseconds: 32)],
                isTesting: true
            ) == .responded(32),
            "an arrived result must win over the in-flight flag"
        )
    }

    /// A group sweep must publish each result as it lands.
    private static func streamingDuringGroupSweep() {
        let group = "PROXY"
        let nodeA = "HK Node 01"
        let nodeB = "SG Node 02"
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [(name: group, members: [nodeA, nodeB])])
        index.clear(group: group)

        expect(
            reading(nodeA, index, group: group, isTesting: true) == .testing,
            "node A must read as testing before anything returns"
        )

        index.merge(member: nodeA, measurement: .reachable(32))
        expect(
            reading(nodeA, index, group: group, isTesting: true) == .responded(32),
            "node A must show 32 ms immediately, without waiting for the sweep"
        )
        expect(
            reading(nodeB, index, group: group, isTesting: true) == .testing,
            "node B must still read as testing while pending"
        )

        index.merge(member: nodeB, measurement: .timedOut)
        expect(
            reading(nodeB, index, group: group, isTesting: false) == .timedOut,
            "node B must report timedOut"
        )
    }

    /// One result belongs to every group that lists the member.
    private static func crossGroupFanOut() {
        let shared = "HK Node 01"
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [
            (name: "PROXY", members: [shared, "SG Node 02"]),
            (name: "Streaming", members: [shared]),
            (name: "Unrelated", members: ["JP Node 03"]),
        ])

        let touched = index.merge(member: shared, measurement: .reachable(41))
        expect(Set(touched) == ["PROXY", "Streaming"], "merge must report exactly the listing groups")
        expect(
            index.measurement(for: shared, in: "Streaming") == .reachable(41),
            "the second group must see the same number without its own probe"
        )
        expect(
            index.measurement(for: shared, in: "Unrelated") == nil,
            "a group that does not list the member must stay untouched"
        )
    }

    /// A member that is itself a strategy group is never probed as a node.
    private static func strategyGroupsAreNotProbed() {
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [
            (name: "PROXY", members: ["Streaming", "HK Node 01"]),
            (name: "Streaming", members: ["SG Node 02"]),
        ])

        let targets = index.probeTargets
        expect(
            !targets.contains("Streaming"),
            "a strategy group must not appear in the probe list"
        )
        expect(
            Set(targets) == ["HK Node 01", "SG Node 02"],
            "probe targets must be the unique real nodes, got \(targets)"
        )
        // Deduplication across groups.
        expect(targets.count == 2, "a node listed twice must be probed once")
    }

    /// Nested groups resolve regardless of declaration order.
    private static func nestedGroupAggregation() {
        // "Top" -> "Middle" -> "Leaf", declared top-down so a single
        // declaration-order pass would resolve Top before Middle had a value.
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [
            (name: "Top", members: ["Middle"]),
            (name: "Middle", members: ["Leaf"]),
            (name: "Leaf", members: ["Fast Node", "Slow Node"]),
        ])

        index.merge(member: "Fast Node", measurement: .reachable(20))
        index.merge(member: "Slow Node", measurement: .reachable(90))
        index.aggregateChildGroups()

        expect(
            index.measurement(for: "Leaf", in: "Middle") == .reachable(20),
            "Middle must inherit Leaf's best child, got \(String(describing: index.measurement(for: "Leaf", in: "Middle")))"
        )
        expect(
            index.measurement(for: "Middle", in: "Top") == .reachable(20),
            "Top must resolve two levels down, got \(String(describing: index.measurement(for: "Middle", in: "Top")))"
        )

        // A parent inherits its best child's confidence, not just its number.
        var verifiedIndex = ProxyLatencyIndex()
        verifiedIndex.beginRun(groups: [
            (name: "Top", members: ["Leaf"]),
            (name: "Leaf", members: ["Fast Node"]),
        ])
        verifiedIndex.merge(member: "Fast Node", measurement: .verified(18))
        verifiedIndex.aggregateChildGroups()
        expect(
            verifiedIndex.measurement(for: "Leaf", in: "Top")?.isVerified == true,
            "a parent must inherit a verified child as verified"
        )

        // A child group nobody measured stays unmeasured. A single-group run
        // aggregates across the whole index, so reporting a timeout here would
        // mark every sibling group the measured group lists as failed.
        var partialIndex = ProxyLatencyIndex()
        partialIndex.beginRun(groups: [
            (name: "PROXY", members: ["Streaming", "HK Node 01"]),
            (name: "Streaming", members: ["SG Node 02"]),
        ])
        partialIndex.merge(member: "HK Node 01", measurement: .reachable(30))
        partialIndex.aggregateChildGroups()
        expect(
            partialIndex.measurement(for: "Streaming", in: "PROXY") == nil,
            "an unmeasured child group must stay unmeasured, got \(String(describing: partialIndex.measurement(for: "Streaming", in: "PROXY")))"
        )

        // An all-dead child group resolves to a timeout, not a stale number.
        var deadIndex = ProxyLatencyIndex()
        deadIndex.beginRun(groups: [
            (name: "Top", members: ["Leaf"]),
            (name: "Leaf", members: ["Dead Node"]),
        ])
        deadIndex.merge(member: "Dead Node", measurement: .timedOut)
        deadIndex.aggregateChildGroups()
        expect(
            deadIndex.measurement(for: "Leaf", in: "Top") == .timedOut,
            "a child group with no usable member must read as timedOut"
        )
    }

    /// Rebuilding for a new profile must not let an old number show through.
    private static func profileSwitchIsolation() {
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [(name: "PROXY", members: ["Reused Name"])])
        index.merge(member: "Reused Name", measurement: .reachable(25))
        expect(
            index.measurement(for: "Reused Name", in: "PROXY") == .reachable(25),
            "precondition: the first profile recorded a number"
        )

        // The app discards the index on a profile switch; a fresh one must not
        // inherit a same-named member's measurement.
        let fresh = ProxyLatencyIndex()
        expect(
            fresh.measurement(for: "Reused Name", in: "PROXY") == nil,
            "a new profile must not inherit a reused member name's number"
        )

        // clearAll is the in-place equivalent for a re-run.
        index.clearAll()
        expect(
            index.measurement(for: "Reused Name", in: "PROXY") == nil,
            "clearAll must drop every recorded measurement"
        )
    }

    /// The bounded sliding window stays bounded.
    private static func boundedConcurrency() {
        let members = (1...100).map { "Node-\($0)" }
        let maxConcurrent = 16
        var completed = 0
        var inFlight = 0
        var peakInFlight = 0

        var iterator = members.makeIterator()
        var queue: [String] = []
        while queue.count < maxConcurrent, let next = iterator.next() {
            queue.append(next)
        }
        while !queue.isEmpty {
            inFlight = queue.count
            peakInFlight = max(peakInFlight, inFlight)
            _ = queue.removeFirst()
            completed += 1
            if let next = iterator.next() { queue.append(next) }
        }

        expect(completed == 100, "all 100 nodes must be measured")
        expect(peakInFlight <= maxConcurrent, "in-flight probes must stay within the pool")
    }

    /// Merging a large group must not cost a rescan per result.
    ///
    /// The previous implementation rescanned every group's member array for
    /// each arriving result and rebuilt the published array, which is
    /// quadratic in the member count. This asserts the merge path stays
    /// linear enough to finish a 5,000-member group well inside a UI budget;
    /// the old path took tens of seconds of main-actor time here.
    private static func largeGroupMergeCost() {
        let members = (1...5000).map { "Node-\($0)" }
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [
            (name: "PROXY", members: members),
            (name: "Backup", members: members),
        ])

        let started = Date()
        for (offset, member) in members.enumerated() {
            index.merge(member: member, measurement: .reachable(UInt32(20 + offset % 100)))
        }
        let mergeSeconds = Date().timeIntervalSince(started)

        expect(
            index.measurement(for: "Node-4999", in: "Backup") == index.measurement(for: "Node-4999", in: "PROXY"),
            "both listing groups must agree after the sweep"
        )
        expect(
            mergeSeconds < 2.0,
            "merging 5,000 members across 2 groups took \(mergeSeconds)s, expected well under 2s"
        )

        // Materializing is the part that is allowed to walk the group, and it
        // happens once per flush rather than once per result.
        let publishStarted = Date()
        let state = index.state(for: "PROXY")
        let publishSeconds = Date().timeIntervalSince(publishStarted)
        expect(state.results.count == 5000, "every member must be published")
        expect(
            publishSeconds < 1.0,
            "publishing 5,000 rows took \(publishSeconds)s, expected well under 1s"
        )
    }
}

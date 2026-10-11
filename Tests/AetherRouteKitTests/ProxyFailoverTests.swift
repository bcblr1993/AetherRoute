import Foundation
import XCTest
@testable import AetherRouteKit

/// Node selection modes and failover decisions (1.6.0).
final class ProxyFailoverTests: XCTestCase {
    // MARK: Modes

    func testStoredModeWinsAndLegacySwitchMeansFastest() {
        XCTAssertEqual(ProxySelectionMode.resolve(stored: nil, legacyAutomatic: false), .manual)
        XCTAssertEqual(ProxySelectionMode.resolve(stored: nil, legacyAutomatic: true), .fastest)
        XCTAssertEqual(ProxySelectionMode.resolve(stored: "failover", legacyAutomatic: true), .failover)
        XCTAssertEqual(ProxySelectionMode.resolve(stored: "manual", legacyAutomatic: true), .manual)
        // An unknown value from a newer version falls back to the old switch.
        XCTAssertEqual(ProxySelectionMode.resolve(stored: "balanced", legacyAutomatic: true), .fastest)
        XCTAssertFalse(ProxySelectionMode.manual.switchesAutomatically)
        XCTAssertTrue(ProxySelectionMode.fastest.switchesAutomatically)
        XCTAssertTrue(ProxySelectionMode.failover.switchesAutomatically)
    }

    // MARK: Preferred node

    func testPreferredNodeIsStoredThenCurrentThenFirstRealNode() {
        let members = ["DIRECT", "HK 01", "SG 02", "JP 03"]
        XCTAssertEqual(
            ProxyFailoverPolicy.preferredMember(stored: "SG 02", current: "JP 03", members: members),
            "SG 02"
        )
        // A stored node the subscription no longer lists is replaced.
        XCTAssertEqual(
            ProxyFailoverPolicy.preferredMember(stored: "Gone", current: "JP 03", members: members),
            "JP 03"
        )
        // DIRECT is not a node to fail over from.
        XCTAssertEqual(
            ProxyFailoverPolicy.preferredMember(stored: nil, current: "DIRECT", members: members),
            "HK 01"
        )
        XCTAssertNil(ProxyFailoverPolicy.preferredMember(stored: nil, current: nil, members: ["DIRECT"]))
    }

    func testPreferredNodeIsTriedFirstOnlyWhenItIsACandidate() {
        let byLatency = ["SG 02", "JP 03", "HK 01"]
        XCTAssertEqual(
            ProxyFailoverPolicy.orderedCandidates(byLatency, preferred: "HK 01"),
            ["HK 01", "SG 02", "JP 03"]
        )
        // An unresponsive preferred node is not among the candidates; the
        // others keep their latency order.
        XCTAssertEqual(
            ProxyFailoverPolicy.orderedCandidates(["SG 02", "JP 03"], preferred: "HK 01"),
            ["SG 02", "JP 03"]
        )
        XCTAssertEqual(ProxyFailoverPolicy.orderedCandidates(byLatency, preferred: nil), byLatency)
    }

    // MARK: Closing connections

    func testFailureSwitchAlwaysDropsTheDeadNodesConnections() {
        for setting in [true, false] {
            XCTAssertEqual(
                ProxyFailoverPolicy.closeRequest(
                    reason: .unresponsive,
                    group: "Proxy",
                    previousMember: "HK 01",
                    closesConnectionsOnSwitch: setting
                ),
                .proxyChainMember("HK 01"),
                "A dead node's connections must close whatever the setting (\(setting))."
            )
        }
        XCTAssertNil(
            ProxyFailoverPolicy.closeRequest(
                reason: .unresponsive,
                group: "Proxy",
                previousMember: nil,
                closesConnectionsOnSwitch: true
            )
        )
        XCTAssertNil(
            ProxyFailoverPolicy.closeRequest(
                reason: .unresponsive,
                group: "Proxy",
                previousMember: "DIRECT",
                closesConnectionsOnSwitch: true
            ),
            "DIRECT is shared by every rule; closing it would drop unrelated traffic."
        )
    }

    func testReturningToThePreferredNodeFollowsTheSetting() {
        XCTAssertEqual(
            ProxyFailoverPolicy.closeRequest(
                reason: .preferredRecovered,
                group: "Proxy",
                previousMember: "SG 02",
                closesConnectionsOnSwitch: true
            ),
            .proxyChainMember("Proxy")
        )
        XCTAssertNil(
            ProxyFailoverPolicy.closeRequest(
                reason: .preferredRecovered,
                group: "Proxy",
                previousMember: "SG 02",
                closesConnectionsOnSwitch: false
            ),
            "The backup's connections still work; keep them unless asked."
        )
    }

    // MARK: Switching back

    func testSwitchBackNeedsConsecutiveAnswers() {
        var tracker = ProxyFailoverRecoveryTracker(requiredStreak: 2)
        XCTAssertFalse(tracker.record(group: "Proxy", preferredResponded: true))
        XCTAssertFalse(tracker.record(group: "Proxy", preferredResponded: false))
        XCTAssertFalse(tracker.record(group: "Proxy", preferredResponded: true))
        XCTAssertTrue(tracker.record(group: "Proxy", preferredResponded: true))
        // Groups count separately.
        XCTAssertFalse(tracker.record(group: "Streaming", preferredResponded: true))
        tracker.reset(group: "Proxy")
        XCTAssertFalse(tracker.record(group: "Proxy", preferredResponded: true))
        tracker.resetAll()
        XCTAssertTrue(tracker.streaks.isEmpty)
        XCTAssertEqual(ProxyFailoverRecoveryTracker().requiredStreak, TunnelStartupTimingPolicy.failoverRecoveryRequiredStreak)
    }

    func testRecoveryScanRunsAtItsInterval() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(ProxyFailoverPolicy.recoveryScanIsDue(lastScan: nil, now: now))
        XCTAssertFalse(ProxyFailoverPolicy.recoveryScanIsDue(lastScan: now.addingTimeInterval(-59), now: now, interval: 60))
        XCTAssertTrue(ProxyFailoverPolicy.recoveryScanIsDue(lastScan: now.addingTimeInterval(-60), now: now, interval: 60))
    }

    func testFailoverTimingKeepsSwitchesFastButNotJumpy() {
        XCTAssertEqual(TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds, 10)
        XCTAssertGreaterThanOrEqual(TunnelStartupTimingPolicy.automaticRouteFailureConfirmationDelayMilliseconds, 500)
        XCTAssertGreaterThanOrEqual(TunnelStartupTimingPolicy.failoverRecoveryRequiredStreak, 2)
        XCTAssertGreaterThanOrEqual(
            TunnelStartupTimingPolicy.failoverRecoveryScanIntervalSeconds,
            TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds * 3,
            "Scanning a whole group for the preferred node must stay rare."
        )
        var schedule = TelemetryPollingSchedule(cadence: .healthOnly)
        XCTAssertEqual(schedule.next(), .init(sleepSeconds: 10, refreshesTelemetry: false, checksRouteHealth: true))
    }

    // MARK: Switch log

    func testSwitchLogKeepsTheNewestTwenty() {
        var log = ProxySwitchLog()
        let start = Date(timeIntervalSince1970: 0)
        for index in 0..<25 {
            log.record(ProxySwitchEvent(
                date: start.addingTimeInterval(TimeInterval(index)),
                group: index.isMultiple(of: 2) ? "Proxy" : "Streaming",
                from: "A\(index)",
                to: "B\(index)",
                reason: .unresponsive
            ))
        }
        XCTAssertEqual(log.events.count, ProxySwitchLog.capacity)
        XCTAssertEqual(log.events.first?.to, "B24")
        XCTAssertEqual(log.events.last?.to, "B5")
        XCTAssertEqual(log.latest(forGroup: "Streaming")?.to, "B23")
        XCTAssertTrue(log.events(forGroup: "Proxy").allSatisfy { $0.group == "Proxy" })
        XCTAssertNil(log.latest(forGroup: "Other"))
    }

    // MARK: Preferred node storage

    func testPreferredNodesAreSealedApartFromSelections() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryProfileKeyStore()
        let yaml = "proxies: []\n"
        let node = "Hong Kong Preferred Node 01"
        let preferences = ProxySelectionStore(directoryURL: directory, keyStore: keys, kind: .preferences)
        let selections = ProxySelectionStore(directoryURL: directory, keyStore: keys, kind: .selections)

        try preferences.recordUserSelection(
            group: "Proxy",
            member: node,
            allowedMembers: [node, "Singapore Backup Node 02"],
            profileYAML: yaml
        )
        XCTAssertEqual(try preferences.selections(forProfileYAML: yaml), ["Proxy": node])
        // The extension's selection file is untouched.
        XCTAssertEqual(try selections.selections(forProfileYAML: yaml), [:])
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("proxy-selections.v1.json").path
        ))

        let sealed = try Data(contentsOf: directory.appendingPathComponent("proxy-preferences.v1.json"))
        XCTAssertNil(sealed.range(of: Data(node.utf8)), "The preferred node is stored in the clear.")

        // A preferences file cannot be opened as a selections file.
        try FileManager.default.copyItem(
            at: directory.appendingPathComponent("proxy-preferences.v1.json"),
            to: directory.appendingPathComponent("proxy-selections.v1.json")
        )
        XCTAssertThrowsError(try selections.selections(forProfileYAML: yaml))

        // A name outside the group is refused.
        XCTAssertThrowsError(try preferences.recordUserSelection(
            group: "Proxy",
            member: "Injected",
            allowedMembers: [node],
            profileYAML: yaml
        ))
        // Without the key the preferences cannot be read.
        let stranger = ProxySelectionStore(
            directoryURL: directory,
            keyStore: InMemoryProfileKeyStore(),
            kind: .preferences
        )
        XCTAssertThrowsError(try stranger.selections(forProfileYAML: yaml))
    }
}

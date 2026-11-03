import Testing
@testable import AetherRouteKit

struct UplinkResetLedgerTests {
    private static let wifi: (UInt32, String) = (14, "en0:14|172.16.3.110")
    private static let ethernet: (UInt32, String) = (36, "en11:36|10.8.5.253")

    /// Plays one run the way the transparent proxy does at attempt 0 and
    /// returns whether it reset the engine.
    private static func run(
        _ ledger: inout UplinkResetLedger,
        reason: String,
        onto uplink: (UInt32, String)
    ) -> Bool {
        ledger.runStarted(reason: reason)
        guard ledger.needsReset(interfaceIndex: uplink.0, signature: uplink.1) else {
            return false
        }
        ledger.invalidate()
        ledger.resetCompleted(interfaceIndex: uplink.0, signature: uplink.1)
        return true
    }

    @Test("waking onto Wi-Fi before USB Ethernet returns resets twice, not three times")
    func wakeThenLateEthernetResetsTwice() {
        // Recorded 2026-11-03 09:01: wake, the same Wi-Fi path one second
        // later, then the AX88179A adapter five seconds after that.
        var ledger = UplinkResetLedger()
        _ = Self.run(&ledger, reason: "pathChanged", onto: Self.ethernet)
        let resets = [
            Self.run(&ledger, reason: "wake", onto: Self.wifi),
            Self.run(&ledger, reason: "pathChanged", onto: Self.wifi),
            Self.run(&ledger, reason: "pathChanged", onto: Self.ethernet),
        ]
        #expect(resets == [true, false, true])
        #expect(ledger.resetSucceeded)
    }

    @Test("wake and app requests reset even when the uplink is unchanged")
    func forcedReasonsAlwaysReset() {
        var ledger = UplinkResetLedger()
        let resets = [
            Self.run(&ledger, reason: "pathChanged", onto: Self.wifi),
            Self.run(&ledger, reason: "wake", onto: Self.wifi),
            Self.run(&ledger, reason: "appMessage", onto: Self.wifi),
        ]
        #expect(resets == [true, true, true])
    }

    @Test("a path change resets when the interface or its addresses differ")
    func pathChangeResetsOnRealChange() {
        var ledger = UplinkResetLedger()
        let resets = [
            Self.run(&ledger, reason: "pathChanged", onto: Self.wifi),
            Self.run(&ledger, reason: "physicalLinkChanged", onto: Self.ethernet),
            Self.run(&ledger, reason: "pathChanged", onto: (14, "en0:14|192.168.1.20")),
        ]
        #expect(resets == [true, true, true])
    }

    @Test("a path change after a failed reset retries the same uplink")
    func failedResetIsRetried() {
        var ledger = UplinkResetLedger()
        let first = Self.run(&ledger, reason: "wake", onto: Self.wifi)
        // Next attempt found no uplink, or the engine refused the reset.
        ledger.invalidate()
        let retried = Self.run(&ledger, reason: "pathChanged", onto: Self.wifi)
        #expect(first && retried)
    }

    @Test("a run rebuilds at most once and a new run may rebuild again")
    func rebuildOncePerRun() {
        var ledger = UplinkResetLedger()
        ledger.runStarted(reason: "wake")
        let first = ledger.claimRebuild()
        let second = ledger.claimRebuild()
        ledger.runStarted(reason: "pathChanged")
        let nextRun = ledger.claimRebuild()
        #expect([first, second, nextRun] == [true, false, true])
    }
}

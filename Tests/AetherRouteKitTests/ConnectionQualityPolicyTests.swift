import Testing
@testable import AetherRouteKit

@Suite("Connection quality policy")
struct ConnectionQualityPolicyTests {
    @Test("readiness never disconnects a tunnel that is already up")
    func readinessNeverDisconnects() {
        for probeSucceeded in [true, false] {
            for trafficReachesInternet in [true, false] {
                let outcome = ConnectionQualityPolicy.outcome(
                    probeSucceeded: probeSucceeded,
                    trafficReachesInternet: trafficReachesInternet
                )
                #expect(outcome.stopsTunnel == false)
            }
        }
    }

    @Test("a passing probe reports a verified, usable route")
    func passingProbeVerifies() {
        let outcome = ConnectionQualityPolicy.outcome(
            probeSucceeded: true,
            trafficReachesInternet: false
        )
        #expect(outcome.quality == .verified)
        #expect(outcome.marksConnectionUsable)
    }

    /// The regression this policy exists for: a healthy but distant node
    /// missed the probe budget, and the app used to tear its tunnel down.
    @Test("a slow route that still passes traffic stays usable")
    func slowRouteThatWorksStaysUsable() {
        let outcome = ConnectionQualityPolicy.outcome(
            probeSucceeded: false,
            trafficReachesInternet: true
        )
        #expect(outcome.quality == .degraded)
        #expect(outcome.quality.isDegraded)
        #expect(outcome.marksConnectionUsable)

        // Being usable is what keeps route-health exhaustion from stopping it.
        #expect(
            AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: outcome.marksConnectionUsable
            ) == .continueMonitoring
        )
    }

    /// The safety valve: the extension is fail-closed, so a tunnel that has
    /// never moved a byte must stay stoppable or every request blackholes.
    @Test("a route that passes no traffic stays stoppable")
    func deadRouteRemainsStoppable() {
        let outcome = ConnectionQualityPolicy.outcome(
            probeSucceeded: false,
            trafficReachesInternet: false
        )
        #expect(outcome.quality == .degraded)
        #expect(outcome.marksConnectionUsable == false)
        #expect(
            AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: outcome.marksConnectionUsable
            ) == .stopProvider
        )
    }
}

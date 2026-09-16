import Testing
@testable import AetherRouteKit

@Suite("Connection quality policy")
struct ConnectionQualityPolicyTests {
    @Test("a disconnected session never shows a previous route quality")
    func disconnectedQualityIsHidden() {
        for quality in [ConnectionQuality.unknown, .verifying, .verified, .degraded] {
            #expect(
                ConnectionQualityPolicy.displayedQuality(
                    quality, isConnected: false
                ) == nil
            )
        }
    }

    @Test("a new connection without a measurement does not claim verification")
    func unmeasuredQualityIsHidden() {
        #expect(
            ConnectionQualityPolicy.displayedQuality(
                .unknown, isConnected: true
            ) == nil
        )
    }

    @Test("a connected session keeps its current route quality notice")
    func connectedQualityRemainsVisible() {
        for quality in [ConnectionQuality.verifying, .verified, .degraded] {
            #expect(
                ConnectionQualityPolicy.displayedQuality(
                    quality, isConnected: true
                ) == quality
            )
        }
    }

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

    /// An unavailable probe target is not proof that every rule is unusable.
    /// The user can disconnect; monitoring must not tear down other routes.
    @Test("an unverified route stays degraded without stopping other routes")
    func unverifiedRouteKeepsMonitoring() {
        let outcome = ConnectionQualityPolicy.outcome(
            probeSucceeded: false,
            trafficReachesInternet: false
        )
        #expect(outcome.quality == .degraded)
        #expect(outcome.marksConnectionUsable == false)
        #expect(
            AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: outcome.marksConnectionUsable
            ) == .continueMonitoring
        )
    }
}

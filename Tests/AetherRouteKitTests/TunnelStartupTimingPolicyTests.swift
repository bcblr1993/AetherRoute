import Testing
@testable import AetherRouteKit

@Suite("Tunnel startup timing policy")
struct TunnelStartupTimingPolicyTests {
    @Test("provider startup has a GeoSite-safe window below the host watchdog")
    func providerWindowPrecedesHostWatchdog() {
        #expect(
            TunnelStartupTimingPolicy.providerCoreReadinessTimeoutSeconds >= 15
        )
        #expect(
            TunnelStartupTimingPolicy.providerCoreReadinessTimeoutSeconds
                < TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds
        )
        #expect(
            TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds
                - TunnelStartupTimingPolicy.providerCoreReadinessTimeoutSeconds
                >= 5
        )
        #expect(
            (5...15).contains(
                TunnelStartupTimingPolicy
                    .hostDisconnectionWatchdogTimeoutSeconds
            )
        )
    }
}

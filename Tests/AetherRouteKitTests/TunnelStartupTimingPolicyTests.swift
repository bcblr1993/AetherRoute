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
            TunnelStartupTimingPolicy
                .selectorReadinessPerMemberTimeoutMilliseconds >= 5_000
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
            (20...40).contains(
                TunnelStartupTimingPolicy
                    .hostDisconnectionWatchdogTimeoutSeconds
            )
        )
        #expect(
            TunnelStartupTimingPolicy
                .providerCoreShutdownWaitTimeoutSeconds >= 5
        )
        #expect(
            TunnelStartupTimingPolicy
                .providerCoreShutdownWaitTimeoutSeconds
                < TunnelStartupTimingPolicy
                    .hostDisconnectionWatchdogTimeoutSeconds
        )
        #expect(
            TunnelStartupTimingPolicy.hostDisconnectionWatchdogTimeoutSeconds
                - TunnelStartupTimingPolicy
                    .providerCoreShutdownWaitTimeoutSeconds
                >= 10
        )
        let selectorBatchCount =
            (TunnelStartupTimingPolicy.selectorReadinessMaximumMemberCount
                + TunnelStartupTimingPolicy.selectorReadinessMaximumConcurrency
                - 1)
            / TunnelStartupTimingPolicy.selectorReadinessMaximumConcurrency
        let embeddedSelectorUpperBound =
            selectorBatchCount
            * Int(TunnelStartupTimingPolicy
                .selectorReadinessPerMemberTimeoutMilliseconds / 1_000)
            + TunnelStartupTimingPolicy
                .selectorReadinessResponseGraceSeconds
        #expect(
            TunnelStartupTimingPolicy
                .selectorReadinessProviderMessageTimeoutSeconds
                > embeddedSelectorUpperBound
        )
        #expect(
            TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds
                > TunnelStartupTimingPolicy
                    .selectorReadinessProviderMessageTimeoutSeconds
        )
        #expect(
            TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds > 0
        )
        #expect(
            TunnelStartupTimingPolicy.telemetryPollingIntervalSeconds == 10
        )
        #expect(
            TunnelStartupTimingPolicy.automaticRouteFailoverAttemptCount >= 2
        )
        #expect(
            TunnelStartupTimingPolicy.automaticRouteFailureThreshold >= 2
        )
        #expect(
            (2...5).contains(
                TunnelStartupTimingPolicy.manualRouteReadinessAttemptCount
            )
        )
        #expect(
            (500...1_500).contains(
                TunnelStartupTimingPolicy
                    .activeRouteReadinessRetryDelayMilliseconds
            )
        )
        #expect(
            (2...5).contains(
                TunnelStartupTimingPolicy.routeDataPlaneReadinessAttemptCount
            )
        )
        #expect(
            (100...1_000).contains(
                TunnelStartupTimingPolicy.routeReadinessRetryDelayMilliseconds
            )
        )
        #expect(
            TunnelStartupTimingPolicy
                .automaticRouteCandidateProbeTimeoutSeconds >= 5
        )
        #expect(
            TunnelStartupTimingPolicy
                .automaticRouteCandidateProbeTimeoutSeconds
                <= Int(
                    TunnelStartupTimingPolicy
                        .selectorReadinessPerMemberTimeoutMilliseconds / 1_000
                )
        )
        #expect(
            TunnelStartupTimingPolicy
                .automaticRouteProviderMessageTimeoutSeconds
                > Int(
                    TunnelStartupTimingPolicy
                        .selectorReadinessPerMemberTimeoutMilliseconds / 1_000
                )
        )
        #expect(
            TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds
                > TunnelStartupTimingPolicy
                    .automaticRouteProviderMessageTimeoutSeconds
        )
    }
}

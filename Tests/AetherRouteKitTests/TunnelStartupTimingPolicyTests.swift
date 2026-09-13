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
        // The connection watchdog is cancelled as soon as the provider reports
        // connected, and route readiness runs after that point in the
        // background. The two budgets are therefore independent: readiness may
        // legitimately outlast the watchdog so that slow-but-healthy nodes are
        // measured properly, without delaying detection of a stuck connection.
        #expect(
            TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds
                > TunnelStartupTimingPolicy.providerCoreReadinessTimeoutSeconds
        )
        #expect(
            TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds > 0
        )
        #expect(
            TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds == 1
        )
        #expect(
            TunnelStartupTimingPolicy.backgroundTelemetryPollingIntervalSeconds == 10
        )
        #expect(
            TunnelStartupTimingPolicy.telemetryPollingIntervalSeconds
                == TunnelStartupTimingPolicy.backgroundTelemetryPollingIntervalSeconds
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
        // Same reasoning as the selector bound above: automatic route health
        // is a background concern and must be allowed to outlast the
        // connection watchdog. It still has to stay finite.
        #expect(
            TunnelStartupTimingPolicy
                .automaticRouteProviderMessageTimeoutSeconds
                >= embeddedSelectorUpperBound
        )
    }

    /// Route readiness became a background quality probe: the tunnel is
    /// reported usable as soon as its network settings install, and a probe
    /// that fails only marks the route degraded. These bounds encode what that
    /// buys us, so a future tightening cannot quietly bring back the old
    /// behaviour where a slow-but-healthy node looked like a dead one.
    @Test("readiness budgets cover real cold starts and stay decoupled")
    func readinessBudgetsSurviveSlowButHealthyNodes() {
        // Measured VLESS/Hysteria2 nodes have taken close to nine seconds for
        // a first HTTPS response through a cold Network Extension. Anything
        // below that rejects routes that actually work.
        #expect(
            TunnelStartupTimingPolicy
                .selectorReadinessPerMemberTimeoutMilliseconds >= 9_000
        )

        // The independent data-plane probe must not be the stricter of the two
        // budgets, or a node cleared by the selector still fails readiness.
        #expect(
            TunnelStartupTimingPolicy.automaticRouteCandidateProbeTimeoutSeconds
                >= Int(
                    TunnelStartupTimingPolicy
                        .selectorReadinessPerMemberTimeoutMilliseconds / 1_000
                )
        )

        // Detecting a stuck connection must stay fast even though readiness is
        // allowed to be slow. These are separate concerns now, so the watchdog
        // is sized against provider startup rather than against readiness.
        #expect(
            TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds <= 90
        )
        #expect(
            TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds
                >= TunnelStartupTimingPolicy
                    .providerCoreReadinessTimeoutSeconds + 5
        )

        // Background work still has to terminate.
        #expect(
            TunnelStartupTimingPolicy
                .automaticRouteProviderMessageTimeoutSeconds <= 240
        )
        #expect(
            TunnelStartupTimingPolicy
                .selectorReadinessProviderMessageTimeoutSeconds <= 240
        )
    }
}

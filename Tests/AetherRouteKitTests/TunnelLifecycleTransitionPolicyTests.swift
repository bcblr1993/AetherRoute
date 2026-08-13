import Testing
@testable import AetherRouteKit

@Suite("Tunnel lifecycle transition policy")
struct TunnelLifecycleTransitionPolicyTests {
    @Test("an adopted provider disconnect receives a watchdog")
    func adoptedDisconnectArmsWatchdog() {
        #expect(
            TunnelLifecycleTransitionPolicy.shouldArmDisconnectionWatchdog(
                providerIsDisconnecting: true,
                disconnectionAttemptPending: false
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldArmDisconnectionWatchdog(
                providerIsDisconnecting: true,
                disconnectionAttemptPending: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldArmDisconnectionWatchdog(
                providerIsDisconnecting: false,
                disconnectionAttemptPending: false
            )
        )
    }

    @Test("connection retry requires an inactive provider")
    func inactiveProviderRequiredForConnectionRetry() {
        #expect(
            TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: false,
                providerPermitsStart: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: true,
                providerPermitsStart: true
            )
        )
        // A failed host state is not transitioning, but Retry must still be
        // rejected while the underlying provider remains connected.
        #expect(
            !TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: false,
                providerPermitsStart: false
            )
        )
    }

    @Test("stale or cancelled connection preparation cannot continue")
    func staleConnectionPreparationStops() {
        #expect(
            TunnelLifecycleTransitionPolicy
                .shouldContinueConnectionPreparation(
                    generationMatches: true,
                    hostIsConnecting: true,
                    providerPermitsStart: true
                )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy
                .shouldContinueConnectionPreparation(
                    generationMatches: false,
                    hostIsConnecting: true,
                    providerPermitsStart: true
                )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy
                .shouldContinueConnectionPreparation(
                    generationMatches: true,
                    hostIsConnecting: false,
                    providerPermitsStart: true
                )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy
                .shouldContinueConnectionPreparation(
                    generationMatches: true,
                    hostIsConnecting: true,
                    providerPermitsStart: false
                )
        )
    }

    @Test("watchdog reconciliation accepts an already completed stop")
    func watchdogUsesReconciledState() {
        #expect(
            TunnelLifecycleTransitionPolicy
                .disconnectionWatchdogResolution(
                    hostIsDisconnectingAfterReconciliation: false
                ) == .completed
        )
        #expect(
            TunnelLifecycleTransitionPolicy
                .disconnectionWatchdogResolution(
                    hostIsDisconnectingAfterReconciliation: true
                ) == .timedOut
        )
    }
}

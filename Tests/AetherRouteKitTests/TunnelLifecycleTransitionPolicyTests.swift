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

    @Test("automatic reconnect is permitted while host is recovering and provider is inactive")
    func automaticReconnectPermittedDuringRecovery() {
        #expect(
            TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: true,
                providerPermitsStart: true,
                isAutomaticReconnect: true,
                hostIsRecovering: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: true,
                providerPermitsStart: false,
                isAutomaticReconnect: true,
                hostIsRecovering: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canBeginConnection(
                hostIsTransitioning: true,
                providerPermitsStart: true,
                isAutomaticReconnect: true,
                hostIsRecovering: false
            )
        )
        #expect(
            TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: true,
                providerPermitsStart: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: false,
                providerPermitsStart: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.canProceedWithAutomaticReconnect(
                isEnabled: true,
                hostIsRecovering: true,
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

    @Test("pre-activation terminal status preserves connecting state while request or attempt is pending")
    func preActivationTerminalStatusAwaitsProviderActivation() {
        #expect(
            TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionRequestPending: true,
                connectionAttemptPending: false,
                disconnectionAttemptPending: false
            )
        )
        #expect(
            TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionRequestPending: false,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: true,
                connectionRequestPending: false,
                connectionAttemptPending: true,
                disconnectionAttemptPending: false
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionRequestPending: true,
                connectionAttemptPending: true,
                disconnectionAttemptPending: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldAwaitProviderActivation(
                currentIsTerminal: true,
                previousWasActive: false,
                connectionRequestPending: false,
                connectionAttemptPending: false,
                disconnectionAttemptPending: false
            )
        )
    }

    @Test("configuration change reload is suppressed while connecting, transitioning, or active")
    func configurationChangeReloadSuppressedDuringConnectionLifecycle() {
        #expect(
            TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPreparing: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                hostIsTransitioning: false,
                connectionRequestPending: false,
                connectionAttemptPending: false,
                disconnectionAttemptPending: false,
                providerIsActive: false
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                connectionRequestPending: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                connectionAttemptPending: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                hostIsTransitioning: true
            )
        )
        #expect(
            !TunnelLifecycleTransitionPolicy.shouldReloadAfterConfigurationChange(
                isUIReviewMode: false,
                isPersistingConfiguration: false,
                isReloadingConfiguration: false,
                isSwitchingNetworkEngine: false,
                providerIsActive: true
            )
        )
    }
}

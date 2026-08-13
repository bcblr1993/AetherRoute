public enum DisconnectionWatchdogResolution: Equatable, Sendable {
    case completed
    case timedOut
}

/// Pure lifecycle decisions shared by the host's Network Extension state
/// machine. The policy intentionally has no NetworkExtension dependency so
/// cancellation and recovery edge cases can be covered by unit tests.
public enum TunnelLifecycleTransitionPolicy {
    public static func shouldArmDisconnectionWatchdog(
        providerIsDisconnecting: Bool,
        disconnectionAttemptPending: Bool
    ) -> Bool {
        providerIsDisconnecting && !disconnectionAttemptPending
    }

    public static func canBeginConnection(
        hostIsTransitioning: Bool,
        providerPermitsStart: Bool
    ) -> Bool {
        !hostIsTransitioning && providerPermitsStart
    }

    public static func shouldContinueConnectionPreparation(
        generationMatches: Bool,
        hostIsConnecting: Bool,
        providerPermitsStart: Bool
    ) -> Bool {
        generationMatches && hostIsConnecting && providerPermitsStart
    }

    public static func disconnectionWatchdogResolution(
        hostIsDisconnectingAfterReconciliation: Bool
    ) -> DisconnectionWatchdogResolution {
        hostIsDisconnectingAfterReconciliation ? .timedOut : .completed
    }
}

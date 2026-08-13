/// The provider's lifecycle reduced to the three phases that change what the
/// person waiting is actually waiting for. Keeping this NetworkExtension-free
/// lets the stage mapping be unit tested, matching
/// `TunnelLifecycleTransitionPolicy`.
public enum ProviderLifecyclePhase: Sendable, Equatable {
    /// Nothing is running yet: no configuration, or it is saved but stopped.
    case inactive
    /// The extension process is launching and bringing the tunnel up.
    case starting
    /// The extension reports the tunnel is up.
    case established
}

/// The four steps the host walks through before it is willing to report
/// "connected". The case names the step currently *in progress*; every step
/// with a lower raw value is complete, every higher one is pending.
public enum ConnectionStage: Int, Sendable, Equatable, CaseIterable {
    case systemAuthorization
    case extensionStartup
    case protocolHandshake
    case readinessCheck
}

/// Because the extension is fail-closed, the gap between requesting a
/// connection and seeing "connected" is not dead time — it is these four steps
/// in sequence. This policy turns the two signals that actually move during
/// that gap into the step to show, so the wait can be rendered honestly rather
/// than as an indeterminate spinner.
public enum ConnectionStagePolicy {
    public static func stage(
        providerPhase: ProviderLifecyclePhase,
        isVerifyingReadiness: Bool
    ) -> ConnectionStage {
        switch providerPhase {
        case .inactive:
            // The configuration is still being saved, or macOS is asking the
            // person to authorize it. Nothing has launched yet.
            .systemAuthorization
        case .starting:
            .extensionStartup
        case .established:
            // The provider's startTunnel returned, so the protocol bridge
            // handshook. What remains is the host's readiness verification.
            isVerifyingReadiness ? .readinessCheck : .protocolHandshake
        }
    }
}

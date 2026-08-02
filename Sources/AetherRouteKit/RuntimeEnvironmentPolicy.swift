import Foundation

public enum RuntimeEnvironmentEvent: Sendable, Equatable {
    case systemWillSleep
    case systemDidWake
    case networkPathChanged
}

public enum RuntimeConnectionActivity: Sendable, Equatable {
    case inactive
    case transitioning
    case connected
}

public struct RuntimeEnvironmentDecision: Sendable, Equatable {
    public let shouldPauseTelemetry: Bool
    public let shouldRefreshProviderState: Bool

    public init(
        shouldPauseTelemetry: Bool,
        shouldRefreshProviderState: Bool
    ) {
        self.shouldPauseTelemetry = shouldPauseTelemetry
        self.shouldRefreshProviderState = shouldRefreshProviderState
    }
}

/// A small deterministic policy for host-environment transitions. It never
/// reconnects a provider or changes system networking; it only decides when
/// the host should pause polling and reread the provider's truthful status.
public enum RuntimeEnvironmentPolicy {
    public static func decision(
        for event: RuntimeEnvironmentEvent,
        activity: RuntimeConnectionActivity
    ) -> RuntimeEnvironmentDecision {
        switch event {
        case .systemWillSleep:
            RuntimeEnvironmentDecision(
                shouldPauseTelemetry: activity != .inactive,
                shouldRefreshProviderState: false
            )
        case .systemDidWake, .networkPathChanged:
            RuntimeEnvironmentDecision(
                shouldPauseTelemetry: false,
                shouldRefreshProviderState: activity != .inactive
            )
        }
    }
}

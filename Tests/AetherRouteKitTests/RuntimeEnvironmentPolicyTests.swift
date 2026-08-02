@testable import AetherRouteKit
import Testing

@Suite("Runtime environment policy")
struct RuntimeEnvironmentPolicyTests {
    @Test("sleep pauses active polling without refreshing the provider")
    func sleepPausesActivePolling() {
        #expect(
            RuntimeEnvironmentPolicy.decision(
                for: .systemWillSleep,
                activity: .connected
            ) == RuntimeEnvironmentDecision(
                shouldPauseTelemetry: true,
                shouldRefreshProviderState: false
            )
        )
    }

    @Test(
        "wake and path changes refresh only an active session",
        arguments: [
            RuntimeEnvironmentEvent.systemDidWake,
            .networkPathChanged,
        ]
    )
    func activeChangesRefreshProvider(_ event: RuntimeEnvironmentEvent) {
        #expect(
            RuntimeEnvironmentPolicy.decision(
                for: event,
                activity: .transitioning
            ).shouldRefreshProviderState
        )
        #expect(
            !RuntimeEnvironmentPolicy.decision(
                for: event,
                activity: .inactive
            ).shouldRefreshProviderState
        )
    }

    @Test("inactive sessions do not create background polling work")
    func inactiveSessionsRemainIdle() {
        for event in [
            RuntimeEnvironmentEvent.systemWillSleep,
            .systemDidWake,
            .networkPathChanged,
        ] {
            #expect(
                RuntimeEnvironmentPolicy.decision(
                    for: event,
                    activity: .inactive
                ) == RuntimeEnvironmentDecision(
                    shouldPauseTelemetry: false,
                    shouldRefreshProviderState: false
                )
            )
        }
    }
}

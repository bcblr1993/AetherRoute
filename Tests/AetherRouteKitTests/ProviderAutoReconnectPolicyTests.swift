import Testing
@testable import AetherRouteKit

@Suite("Provider auto-reconnect policy")
struct ProviderAutoReconnectPolicyTests {
    @Test("an unexpected termination the user did not ask for is retried")
    func unexpectedTerminationReconnects() {
        #expect(
            ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: true,
                attempt: 0
            )
        )
    }

    @Test("a stop the host requested is never retried")
    func expectedTerminationIsLeftAlone() {
        #expect(
            !ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: false,
                userWantsConnection: true,
                attempt: 0
            )
        )
    }

    @Test("a user who disconnected is never reconnected behind their back")
    func userIntentWins() {
        #expect(
            !ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: false,
                attempt: 0
            )
        )
    }

    @Test("the retry budget is finite, so a dead node cannot pin a loop")
    func budgetIsExhausted() {
        let last = ProviderAutoReconnectPolicy.maximumAttempts - 1
        #expect(
            ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: true,
                attempt: last
            )
        )
        #expect(
            !ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: true,
                attempt: last + 1
            )
        )
    }

    @Test("a negative attempt is refused rather than indexing backwards")
    func negativeAttemptIsRefused() {
        #expect(
            !ProviderAutoReconnectPolicy.shouldReconnect(
                terminationWasUnexpected: true,
                userWantsConnection: true,
                attempt: -1
            )
        )
        #expect(ProviderAutoReconnectPolicy.delay(forAttempt: -1) == nil)
    }

    @Test("delays are defined for the whole budget and nothing beyond it")
    func delaysCoverTheBudget() {
        for attempt in 0..<ProviderAutoReconnectPolicy.maximumAttempts {
            #expect(ProviderAutoReconnectPolicy.delay(forAttempt: attempt) != nil)
        }
        #expect(
            ProviderAutoReconnectPolicy.delay(
                forAttempt: ProviderAutoReconnectPolicy.maximumAttempts
            ) == nil
        )
    }

    @Test("delays grow, so a node that stays down is backed off")
    func delaysBackOff() {
        let delays = ProviderAutoReconnectPolicy.delays
        #expect(delays.count > 1)
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            #expect(later > earlier)
        }
        // Front-loaded: an extension killed for a transient stall should be
        // retried in about a second, not after a long wait.
        #expect(delays[0] <= 2)
    }
}

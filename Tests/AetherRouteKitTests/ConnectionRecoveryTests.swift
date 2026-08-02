import Testing
@testable import AetherRouteKit

struct ConnectionRecoveryTests {
    @Test
    func missingProfileRoutesDirectlyToProfileReview() {
        let plan = ConnectionRecoveryPlan(context: .missingProfile)

        #expect(plan.primaryAction == .reviewProfiles)
        #expect(plan.secondaryAction == nil)
    }

    @Test(arguments: [
        ConnectionFailureContext.configuration,
        .provider,
        .unknown,
    ])
    func recoverableFailuresOfferRetryThenProfileReview(
        context: ConnectionFailureContext
    ) {
        let plan = ConnectionRecoveryPlan(context: context)

        #expect(plan.primaryAction == .retry)
        #expect(plan.secondaryAction == .reviewProfiles)
    }
}

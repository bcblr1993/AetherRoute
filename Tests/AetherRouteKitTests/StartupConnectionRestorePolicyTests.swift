import Testing
@testable import AetherRouteKit

@Suite("Startup connection restore policy")
struct StartupConnectionRestorePolicyTests {
    private typealias Policy = StartupConnectionRestorePolicy

    /// A snapshot in which an attempt is due; tests flip one field at a time.
    private func ready(
        elapsed: Double = 0,
        attemptsMade: Int = 0
    ) -> Policy.Snapshot {
        Policy.Snapshot(
            elapsed: elapsed,
            attemptsMade: attemptsMade,
            wasConnectedBeforeTermination: true,
            isTerminating: false,
            isConnected: false,
            networkPathSatisfied: true,
            canStartConnection: true,
            automaticReconnectPending: false
        )
    }

    @Test("restoration is permitted when previously connected and within attempt budget")
    func restorePermittedWhenPreviouslyConnected() {
        #expect(
            Policy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: 0,
                isTerminating: false
            )
        )
        #expect(Policy.nextStep(ready()) == .attempt)
    }

    @Test("restoration is strictly denied if user was disconnected before termination")
    func restoreDeniedWhenPreviouslyDisconnected() {
        #expect(
            !Policy.shouldAttemptRestore(
                wasConnectedBeforeTermination: false,
                attempt: 0,
                isTerminating: false
            )
        )
        var snapshot = ready()
        snapshot.wasConnectedBeforeTermination = false
        #expect(Policy.nextStep(snapshot) == .finish(.intentRevoked))
    }

    @Test("restoration is aborted when application is terminating")
    func restoreDeniedWhenTerminating() {
        #expect(
            !Policy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: 0,
                isTerminating: true
            )
        )
        var snapshot = ready()
        snapshot.isTerminating = true
        snapshot.wasConnectedBeforeTermination = false
        snapshot.isConnected = true
        #expect(Policy.nextStep(snapshot) == .finish(.terminating))
    }

    @Test("a user disconnect wins over every other condition except termination")
    func revokedIntentOutranksEverything() {
        var snapshot = ready(elapsed: 500, attemptsMade: 99)
        snapshot.wasConnectedBeforeTermination = false
        snapshot.isConnected = true
        snapshot.networkPathSatisfied = false
        #expect(Policy.nextStep(snapshot) == .finish(.intentRevoked))
    }

    @Test("a connection made by any route ends the restore, even past the budget")
    func connectedEndsRestore() {
        var snapshot = ready(elapsed: Policy.overallBudget + 10)
        snapshot.isConnected = true
        #expect(Policy.nextStep(snapshot) == .finish(.connected))
    }

    @Test("the overall budget is long enough for a slow boot and is enforced")
    func overallBudgetIsEnforced() {
        #expect(Policy.overallBudget >= 60)
        #expect(Policy.nextStep(ready(elapsed: Policy.overallBudget - 0.1)) == .attempt)
        #expect(
            Policy.nextStep(ready(elapsed: Policy.overallBudget)) == .finish(.budgetExhausted)
        )
    }

    @Test("attempts are finite")
    func attemptsAreFinite() {
        let last = Policy.maximumAttempts - 1
        #expect(Policy.nextStep(ready(attemptsMade: last)) == .attempt)
        #expect(
            Policy.nextStep(ready(attemptsMade: Policy.maximumAttempts))
                == .finish(.attemptsExhausted)
        )
        #expect(
            Policy.shouldAttemptRestore(wasConnectedBeforeTermination: true, attempt: last)
        )
        #expect(
            !Policy.shouldAttemptRestore(wasConnectedBeforeTermination: true, attempt: last + 1)
        )
    }

    @Test("no attempt is spent while the network path is unsatisfied")
    func waitsForNetwork() {
        var snapshot = ready()
        snapshot.networkPathSatisfied = false
        snapshot.canStartConnection = false
        #expect(Policy.nextStep(snapshot) == .waitForNetwork)
    }

    @Test("an unready host or a scheduled automatic reconnect defers the attempt")
    func waitsForReadiness() {
        var unready = ready()
        unready.canStartConnection = false
        #expect(Policy.nextStep(unready) == .waitForReadiness)

        var reconnectPending = ready()
        reconnectPending.automaticReconnectPending = true
        #expect(Policy.nextStep(reconnectPending) == .waitForReadiness)
    }

    @Test("budget exhaustion is reported even while still waiting for network")
    func budgetOutranksWaiting() {
        var snapshot = ready(elapsed: Policy.overallBudget + 1)
        snapshot.networkPathSatisfied = false
        #expect(Policy.nextStep(snapshot) == .finish(.budgetExhausted))
    }

    @Test("an attempt still connecting is not judged before the outcome timeout")
    func attemptOutcomeWaitsForResult() {
        // A warm connect needs about two seconds; the old 1.5 s judgement failed it.
        #expect(Policy.attemptOutcomeTimeout > 2)
        #expect(Policy.attemptOutcome(progress: .inProgress, waited: 1.5) == .pending)
        #expect(
            Policy.attemptOutcome(
                progress: .inProgress,
                waited: Policy.attemptOutcomeTimeout - 0.1
            ) == .pending
        )
        #expect(
            Policy.attemptOutcome(progress: .inProgress, waited: Policy.attemptOutcomeTimeout)
                == .timedOut
        )
        #expect(Policy.attemptOutcome(progress: .connected, waited: 0.2) == .succeeded)
        #expect(Policy.attemptOutcome(progress: .stopped, waited: 0.2) == .failed)
    }

    @Test("retry delays back off progressively and exist between every pair of attempts")
    func retryDelaysBackOff() {
        let delays = Policy.retryDelays
        #expect(delays.count == Policy.maximumAttempts - 1)
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            #expect(later > earlier)
        }
        #expect(Policy.delay(forAttempt: -1) == nil)
        #expect(Policy.delay(forAttempt: delays.count) == nil)
    }

    @Test("backoff never sleeps past the overall budget")
    func backoffIsClampedToBudget() {
        #expect(Policy.backoffDelay(afterAttempts: 0, elapsed: 0) == nil)
        #expect(Policy.backoffDelay(afterAttempts: 1, elapsed: 0) == Policy.retryDelays[0])
        let last = Policy.retryDelays.count
        #expect(
            Policy.backoffDelay(afterAttempts: last, elapsed: Policy.overallBudget - 3) == 3
        )
        #expect(Policy.backoffDelay(afterAttempts: last, elapsed: Policy.overallBudget) == nil)
        #expect(
            Policy.backoffDelay(afterAttempts: Policy.maximumAttempts, elapsed: 0) == nil
        )
    }

    @Test("the full backoff schedule fits inside the budget with time left for attempts")
    func scheduleFitsBudget() {
        let totalBackoff = Policy.retryDelays.reduce(0, +)
        #expect(totalBackoff < Policy.overallBudget)
    }
}

import Testing
@testable import AetherRouteKit

@Suite("Startup connection restore policy")
struct StartupConnectionRestorePolicyTests {
    @Test("restoration is permitted when previously connected and within attempt budget")
    func restorePermittedWhenPreviouslyConnected() {
        #expect(
            StartupConnectionRestorePolicy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: 0,
                isTerminating: false
            )
        )
    }

    @Test("restoration is strictly denied if user was disconnected before termination")
    func restoreDeniedWhenPreviouslyDisconnected() {
        #expect(
            !StartupConnectionRestorePolicy.shouldAttemptRestore(
                wasConnectedBeforeTermination: false,
                attempt: 0,
                isTerminating: false
            )
        )
    }

    @Test("restoration is aborted when application is terminating")
    func restoreDeniedWhenTerminating() {
        #expect(
            !StartupConnectionRestorePolicy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: 0,
                isTerminating: true
            )
        )
    }

    @Test("restoration attempts are finite and exhausted after maximumAttempts")
    func restoreBudgetIsFinite() {
        let last = StartupConnectionRestorePolicy.maximumAttempts - 1
        #expect(
            StartupConnectionRestorePolicy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: last,
                isTerminating: false
            )
        )
        #expect(
            !StartupConnectionRestorePolicy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: last + 1,
                isTerminating: false
            )
        )
    }

    @Test("negative attempt indices are safely rejected")
    func negativeAttemptIsRejected() {
        #expect(
            !StartupConnectionRestorePolicy.shouldAttemptRestore(
                wasConnectedBeforeTermination: true,
                attempt: -1,
                isTerminating: false
            )
        )
        #expect(StartupConnectionRestorePolicy.delay(forAttempt: -1) == nil)
    }

    @Test("retry delays cover all attempts within budget and back off progressively")
    func retryDelaysBackOff() {
        for attempt in 0..<StartupConnectionRestorePolicy.maximumAttempts {
            #expect(StartupConnectionRestorePolicy.delay(forAttempt: attempt) != nil)
        }
        #expect(
            StartupConnectionRestorePolicy.delay(
                forAttempt: StartupConnectionRestorePolicy.maximumAttempts
            ) == nil
        )

        let delays = StartupConnectionRestorePolicy.retryDelays
        #expect(delays.count > 1)
        for (earlier, later) in zip(delays, delays.dropFirst()) {
            #expect(later > earlier)
        }
        // First retry should happen quickly (around 1 second)
        #expect(delays[0] <= 1.5)
    }
}

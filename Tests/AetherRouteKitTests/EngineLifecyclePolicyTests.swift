import Testing
@testable import AetherRouteKit

@Suite("Engine lifecycle policy")
struct EngineLifecyclePolicyTests {
    @Test("an idle process admits a start on the next generation")
    func idleAdmits() {
        #expect(
            EngineLifecyclePolicy.startAdmission(
                for: .idle,
                currentGeneration: 7
            ) == .admit(generation: 8)
        )
    }

    @Test("a running engine rejects a second start")
    func runningRejects() {
        #expect(
            EngineLifecyclePolicy.startAdmission(
                for: .running(generation: 3),
                currentGeneration: 3
            ) == .reject
        )
    }

    @Test("a stopping engine must be joined before its replacement starts")
    func stoppingAwaitsHandoff() {
        #expect(
            EngineLifecyclePolicy.startAdmission(
                for: .stopping(generation: 3),
                currentGeneration: 3
            ) == .awaitStop(generation: 3)
        )
    }

    @Test("the owner of the live generation may stop it")
    func ownerMayStop() {
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .running(generation: 4),
                requestedBy: 4
            ) == .begin(generation: 4)
        )
    }

    /// The regression this whole gate exists for. A bridge belonging to a
    /// retired provider — a readiness task that outlived its instance, say —
    /// must not be able to stop the engine that replaced it: the engine's
    /// cancellation registry is process-wide and a shutdown drains all of it.
    @Test("a stale generation cannot stop the engine that replaced it")
    func staleGenerationCannotStopSuccessor() {
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .running(generation: 2),
                requestedBy: 1
            ) == .ignore
        )
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .stopping(generation: 2),
                requestedBy: 1
            ) == .ignore
        )
    }

    /// A bridge that failed before admission owns nothing. Acting on its stop
    /// would tear down a tunnel belonging to someone else.
    @Test("a caller that never owned a generation is ignored")
    func unownedRequestIsIgnored() {
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .running(generation: 5),
                requestedBy: nil
            ) == .ignore
        )
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .idle,
                requestedBy: nil
            ) == .ignore
        )
    }

    @Test("stopping an idle process is a no-op")
    func idleStopIsIgnored() {
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .idle,
                requestedBy: 1
            ) == .ignore
        )
    }

    /// Repeated stops must not drain the global cancellation registry twice.
    @Test("a repeated stop from the owner is reported as already in flight")
    func repeatedStopIsIdempotent() {
        #expect(
            EngineLifecyclePolicy.stopAdmission(
                for: .stopping(generation: 6),
                requestedBy: 6
            ) == .alreadyStopping(generation: 6)
        )
    }

    @Test("generations advance monotonically and never reuse the absent value")
    func generationsSkipZero() {
        #expect(EngineLifecyclePolicy.nextGeneration(0) == 1)
        #expect(EngineLifecyclePolicy.nextGeneration(1) == 2)
        #expect(EngineLifecyclePolicy.nextGeneration(.max) == 1)
    }

    @Test("a phase reports the generation it owns")
    func phaseExposesGeneration() {
        #expect(EngineLifecyclePhase.idle.generation == nil)
        #expect(EngineLifecyclePhase.running(generation: 9).generation == 9)
        #expect(EngineLifecyclePhase.stopping(generation: 9).generation == 9)
    }

    /// Walks the sequence the 2026-09-14 incident produced: an engine that
    /// overran its shutdown, a replacement start arriving while it was still
    /// winding down, and the retired instance's late stop request.
    @Test("a slow shutdown blocks admission instead of running two engines")
    func slowShutdownSequence() {
        var phase = EngineLifecyclePhase.running(generation: 1)

        guard case let .begin(stopping) = EngineLifecyclePolicy.stopAdmission(
            for: phase,
            requestedBy: 1
        ) else {
            Issue.record("the owner should be allowed to stop its engine")
            return
        }
        phase = .stopping(generation: stopping)

        // Previously this is where a fresh provider instance started a second
        // engine. Admission now has to wait for the first one.
        #expect(
            EngineLifecyclePolicy.startAdmission(
                for: phase,
                currentGeneration: 1
            ) == .awaitStop(generation: 1)
        )

        // Once joined, the replacement gets a distinct generation.
        phase = .idle
        guard case let .admit(replacement) = EngineLifecyclePolicy
            .startAdmission(for: phase, currentGeneration: 1) else {
            Issue.record("an idle process should admit a start")
            return
        }
        #expect(replacement == 2)
        phase = .running(generation: replacement)

        // The retired bridge finally gets around to stopping. It must not take
        // the replacement down with it.
        #expect(
            EngineLifecyclePolicy.stopAdmission(for: phase, requestedBy: 1)
                == .ignore
        )
    }

    @Test("an evicted running engine transitions safely into stopping and then idle")
    func evictedRunningEngineTransitionsToIdle() {
        var phase = EngineLifecyclePhase.running(generation: 3)
        // When a residual running engine is evicted by a fresh session, phase transitions to stopping
        phase = .stopping(generation: 3)
        #expect(
            EngineLifecyclePolicy.startAdmission(
                for: phase,
                currentGeneration: 3
            ) == .awaitStop(generation: 3)
        )
        // Once completed or retired, phase becomes idle and admits next generation
        phase = .idle
        #expect(
            EngineLifecyclePolicy.startAdmission(
                for: phase,
                currentGeneration: 3
            ) == .admit(generation: 4)
        )
    }
}

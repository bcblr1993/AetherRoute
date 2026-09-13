import Foundation
import Testing
@testable import AetherRouteKit

/// Collects coordinator events and lets a test wait for a specific one without
/// sleeping for a fixed duration.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [NetworkRecoveryCoordinator.Event] = []
    private var pending:
        [(
            predicate: (NetworkRecoveryCoordinator.Event) -> Bool,
            signal: DispatchSemaphore
        )] = []

    var recorded: [NetworkRecoveryCoordinator.Event] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    func record(_ event: NetworkRecoveryCoordinator.Event) {
        lock.lock()
        events.append(event)
        let satisfied = pending.filter { $0.predicate(event) }
        pending.removeAll { $0.predicate(event) }
        lock.unlock()
        satisfied.forEach { $0.signal.signal() }
    }

    /// Waits for an event matching `predicate`, including ones already seen.
    @discardableResult
    func wait(
        for predicate: @escaping (NetworkRecoveryCoordinator.Event) -> Bool,
        timeout: TimeInterval = 5
    ) -> Bool {
        lock.lock()
        if events.contains(where: predicate) {
            lock.unlock()
            return true
        }
        let signal = DispatchSemaphore(value: 0)
        pending.append((predicate, signal))
        lock.unlock()
        return signal.wait(timeout: .now() + timeout) == .success
    }
}

struct NetworkRecoveryCoordinatorTests {
    private static let fastDelays: [TimeInterval] = [0.01, 0.01, 0.01, 0.01]

    /// The whole point of the health check: a network that is already back must
    /// cost exactly one attempt, not the full schedule.
    @Test
    func recoveryStopsAtTheFirstHealthyAttempt() {
        let attempts = Counter()
        let recorder = EventRecorder()
        let coordinator = NetworkRecoveryCoordinator(
            delays: Self.fastDelays,
            perform: { _, _ in attempts.increment() },
            verify: { true },
            observer: { recorder.record($0) }
        )

        coordinator.trigger(reason: "wake")

        #expect(recorder.wait(for: { if case .recovered = $0 { return true }; return false }))
        #expect(attempts.value == 1)
    }

    /// A link that needs several seconds to come up is the reported failure:
    /// the old code gave up after two fixed attempts. Recovery must keep going
    /// until the health check passes.
    @Test
    func recoveryRetriesUntilTheDataPathComesBack() {
        let attempts = Counter()
        let recorder = EventRecorder()
        let healthyAfter = 3
        let coordinator = NetworkRecoveryCoordinator(
            delays: Self.fastDelays,
            perform: { _, _ in attempts.increment() },
            verify: { attempts.value >= healthyAfter },
            observer: { recorder.record($0) }
        )

        coordinator.trigger(reason: "wake")

        #expect(recorder.wait(for: {
            if case let .recovered(_, attempt) = $0 { return attempt == healthyAfter - 1 }
            return false
        }))
        #expect(attempts.value == healthyAfter)
    }

    /// A host that never comes back must stop rather than retry forever, and it
    /// must say so, because that is the case worth a log line.
    @Test
    func recoveryReportsExhaustionWhenTheDataPathNeverReturns() {
        let attempts = Counter()
        let recorder = EventRecorder()
        let coordinator = NetworkRecoveryCoordinator(
            delays: Self.fastDelays,
            perform: { _, _ in attempts.increment() },
            verify: { false },
            observer: { recorder.record($0) }
        )

        coordinator.trigger(reason: "wake")

        #expect(recorder.wait(for: { if case .exhausted = $0 { return true }; return false }))
        #expect(attempts.value == Self.fastDelays.count)
    }

    /// The host emits sleep and wake through several independent notifications.
    /// On a live machine that produced four resets and four route reinstalls
    /// inside six seconds; overlapping triggers must collapse into one run.
    @Test
    func overlappingTriggersCollapseIntoOneRun() {
        let starts = Counter()
        let recorder = EventRecorder()
        let coordinator = NetworkRecoveryCoordinator(
            delays: [0.05],
            debounce: 5,
            perform: { _, _ in },
            verify: { true },
            observer: { event in
                if case .started = event { starts.increment() }
                recorder.record(event)
            }
        )

        for reason in ["wake", "screensDidWake", "screenIsUnlocked", "pathChanged"] {
            coordinator.trigger(reason: reason)
        }

        #expect(recorder.wait(for: { if case .recovered = $0 { return true }; return false }))
        #expect(starts.value == 1)
        #expect(recorder.recorded.filter {
            if case .coalesced = $0 { return true }
            return false
        }.count == 3)
    }

    /// Reinstalling the tunnel's settings makes its interface disappear and
    /// reappear, so a finished run is immediately followed by the triggers it
    /// caused itself. Measured on a VM, one genuine recovery set off three more
    /// rounds of resets off that echo.
    @Test
    func triggersArrivingJustAfterARunAreSwallowed() {
        let starts = Counter()
        let recorder = EventRecorder()
        let coordinator = NetworkRecoveryCoordinator(
            delays: [0.01],
            debounce: 5,
            perform: { _, _ in },
            verify: { true },
            observer: { event in
                if case .started = event { starts.increment() }
                recorder.record(event)
            }
        )

        coordinator.trigger(reason: "wake")
        #expect(recorder.wait(for: { if case .recovered = $0 { return true }; return false }))
        // The echo: a path change reported because recovery reinstalled routes.
        coordinator.trigger(reason: "pathChanged")
        coordinator.waitForQuiescence()

        #expect(starts.value == 1)
    }

    /// A cancel is a suspend or a stop. The wake that follows must be able to
    /// start immediately instead of being swallowed as a duplicate trigger.
    @Test
    func cancelClearsTheDebounceSoTheNextWakeIsHonoured() {
        let starts = Counter()
        let recorder = EventRecorder()
        let coordinator = NetworkRecoveryCoordinator(
            delays: [10],
            debounce: 60,
            perform: { _, _ in },
            verify: { true },
            observer: { event in
                if case .started = event { starts.increment() }
                recorder.record(event)
            }
        )

        coordinator.trigger(reason: "wake")
        #expect(recorder.wait(for: { if case .started = $0 { return true }; return false }))
        coordinator.cancel(reason: "sleep")
        #expect(recorder.wait(for: { if case .cancelled = $0 { return true }; return false }))
        coordinator.trigger(reason: "wake")

        coordinator.waitForQuiescence()
        #expect(starts.value == 2)
    }

    /// A queued attempt must not outlive the provider that scheduled it.
    @Test
    func cancelStopsAScheduledAttemptFromRunning() {
        let attempts = Counter()
        let coordinator = NetworkRecoveryCoordinator(
            delays: [0.2],
            perform: { _, _ in attempts.increment() },
            verify: { false }
        )

        coordinator.trigger(reason: "wake")
        coordinator.cancel(reason: "stopTunnel")
        Thread.sleep(forTimeInterval: 0.4)

        #expect(attempts.value == 0)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}

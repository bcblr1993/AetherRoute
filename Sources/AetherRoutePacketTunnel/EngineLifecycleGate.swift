import AetherRouteKit
import Darwin
import Foundation
import OSLog

private enum EngineLifecycleLog {
    static let logger = AppLog.logger(category: AppLog.Category.tunnelCore)
}

/// Process-wide custodian of the embedded engine's lifecycle.
///
/// `RustCoreBridge` is owned by a `NEPacketTunnelProvider` instance, and the
/// framework builds a new provider for every `startTunnel`. The engine behind
/// it is not per-instance: its C ABI takes no handles and its cancellation
/// tokens live in one global registry. Admission therefore has to be decided
/// somewhere that outlives any single bridge, which is what this singleton is
/// for. See `EngineLifecyclePolicy` for the transitions themselves.
final class EngineLifecycleGate: @unchecked Sendable {
    static let shared = EngineLifecycleGate()

    enum StartOutcome: Equatable {
        case admitted(generation: UInt64)
        /// A previous engine did not finish winding down inside the handoff
        /// budget. Starting a replacement now would leave two engines sharing
        /// one cancellation registry, so the caller must not proceed.
        case handoffTimedOut(generation: UInt64)
        case rejected
    }

    struct StopHandle {
        let generation: UInt64
        let completion: DispatchGroup
    }

    private let lock = NSLock()
    private var phase: EngineLifecyclePhase = .idle
    private var generationCounter: UInt64 = 0
    private var engineCompletion: DispatchGroup?

    /// Concurrent, because a join that never returns — the four-minute unwind
    /// this exists to survive — must not block the next disconnect's join.
    private let joinQueue = DispatchQueue(
        label: "com.aetherroute.engine-join",
        qos: .utility,
        attributes: .concurrent
    )

    private init() {}

    /// Claims the process-wide engine slot, joining a still-stopping predecessor
    /// first. Blocks for at most `timeout` and never starts a second engine.
    func acquireForStart(waitingUpTo timeout: DispatchTimeInterval) -> StartOutcome {
        // One retry per observed stop. A second pass can only happen when some
        // other thread finished a stop while this one was waiting, so the loop
        // is bounded in practice; the counter makes that explicit.
        for _ in 0..<4 {
            let stoppingGeneration: UInt64
            let pending: DispatchGroup?
            lock.lock()
            switch EngineLifecyclePolicy.startAdmission(
                for: phase,
                currentGeneration: generationCounter
            ) {
            case let .admit(generation):
                generationCounter = generation
                phase = .running(generation: generation)
                engineCompletion = nil
                lock.unlock()
                EngineLifecycleLog.logger.info(
                    "stage=engineLifecycle admitted generation=\(generation, privacy: .public)"
                )
                return .admitted(generation: generation)
            case .reject:
                let live = phase.generation ?? 0
                EngineLifecycleLog.logger.error(
                    "stage=engineLifecycle residualRunningEngineDetected liveGeneration=\(live, privacy: .public)"
                )
                // A new startTunnel in this process means the previous tunnel session is gone.
                // Evict the zombie generation: signal shutdown, transition to stopping, and await wind-down.
                phase = .stopping(generation: live)
                stoppingGeneration = live
                pending = engineCompletion
                lock.unlock()
                _ = clash_shutdown()
            case let .awaitStop(generation):
                stoppingGeneration = generation
                pending = engineCompletion
                lock.unlock()
            }

            guard let pending else {
                // Stopping with no group to join: the owner signalled a stop
                // before its engine ever registered, so nothing can be waited
                // on. Retire the generation and re-evaluate.
                finishStop(generation: stoppingGeneration)
                continue
            }

            EngineLifecycleLog.logger.info(
                "stage=engineLifecycle awaitingStop generation=\(stoppingGeneration, privacy: .public)"
            )
            guard pending.wait(timeout: .now() + timeout) == .success else {
                EngineLifecycleLog.logger.error(
                    "stage=engineLifecycle handoffTimedOut generation=\(stoppingGeneration, privacy: .public)"
                )
                return .handoffTimedOut(generation: stoppingGeneration)
            }
            finishStop(generation: stoppingGeneration)
        }
        return .rejected
    }

    /// Publishes the group that completes when the engine worker returns, so a
    /// later start can join it. Ignored if the generation is no longer live.
    func registerEngineCompletion(
        _ group: DispatchGroup,
        generation: UInt64
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard phase.generation == generation else { return }
        engineCompletion = group
    }

    /// Transitions a live engine into `stopping`, returning the group to join.
    /// Returns `nil` when the caller does not own the live generation, which is
    /// what keeps a stale bridge from cancelling its successor's engine.
    func beginStop(requestedBy generation: UInt64?) -> StopHandle? {
        lock.lock()
        defer { lock.unlock() }
        switch EngineLifecyclePolicy.stopAdmission(
            for: phase,
            requestedBy: generation
        ) {
        case .ignore:
            EngineLifecycleLog.logger.info(
                "stage=engineLifecycle stopIgnored requested=\(generation ?? 0, privacy: .public) live=\(self.phase.generation ?? 0, privacy: .public)"
            )
            return nil
        case let .alreadyStopping(live):
            EngineLifecycleLog.logger.info(
                "stage=engineLifecycle stopAlreadyInFlight generation=\(live, privacy: .public)"
            )
            return nil
        case let .begin(live):
            guard let completion = engineCompletion else {
                // Admitted, but the engine was never submitted — the window
                // between installing the packet bridge and starting the worker.
                // There is nothing to cancel and nothing to join, so release
                // the slot outright rather than park it in `stopping`.
                phase = .idle
                EngineLifecycleLog.logger.info(
                    "stage=engineLifecycle stopBeforeEngineStarted generation=\(live, privacy: .public)"
                )
                return nil
            }
            phase = .stopping(generation: live)
            return StopHandle(generation: live, completion: completion)
        }
    }

    /// Retires a stopped generation. Safe to call more than once, and from
    /// either the joining worker or a start that waited the stop out.
    func finishStop(generation: UInt64?) {
        guard let generation else { return }
        lock.lock()
        let retired: Bool
        if case let .stopping(live) = phase, live == generation {
            phase = .idle
            engineCompletion = nil
            retired = true
        } else {
            retired = false
        }
        lock.unlock()
        guard retired else { return }
        let releasedBytes = malloc_zone_pressure_relief(nil, 0)
        EngineLifecycleLog.logger.info(
            "stage=engineLifecycle retired generation=\(generation, privacy: .public) releasedBytes=\(releasedBytes, privacy: .public)"
        )
    }

    /// Releases a generation that was admitted but never got an engine running,
    /// so a failed start does not leave the slot permanently occupied.
    func abandonStart(generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard phase.generation == generation else { return }
        phase = .idle
        engineCompletion = nil
        EngineLifecycleLog.logger.info(
            "stage=engineLifecycle abandoned generation=\(generation, privacy: .public)"
        )
    }

    /// Retires an unexpectedly terminated engine generation, ensuring the gate returns to idle
    /// and does not leave a zombie generation blocking future starts.
    func retireUnexpectedlyTerminatedEngine(generation: UInt64) {
        lock.lock()
        let retired: Bool
        if phase.generation == generation {
            phase = .idle
            engineCompletion = nil
            retired = true
        } else {
            retired = false
        }
        lock.unlock()
        guard retired else { return }
        let releasedBytes = malloc_zone_pressure_relief(nil, 0)
        EngineLifecycleLog.logger.error(
            "stage=engineLifecycle retiredUnexpectedly generation=\(generation, privacy: .public) releasedBytes=\(releasedBytes, privacy: .public)"
        )
    }

    /// Joins a stopping engine off the caller's thread. Unbounded on purpose:
    /// nobody is waiting on it, and a start that arrives meanwhile applies its
    /// own bounded handoff budget.
    func joinStoppedEngine(_ handle: StopHandle) {
        joinQueue.async { [self] in
            let began = ContinuousClock.now
            handle.completion.wait()
            let elapsed = ContinuousClock.now - began
            let seconds = Double(elapsed.components.seconds)
                + Double(elapsed.components.attoseconds) / 1e18
            EngineLifecycleLog.logger.info(
                "stage=stopCore joined generation=\(handle.generation, privacy: .public) durationSeconds=\(String(format: "%.1f", seconds), privacy: .public)"
            )
            finishStop(generation: handle.generation)
        }
    }

    /// Ends the extension process after the host has had time to receive the
    /// failure over XPC.
    ///
    /// When a predecessor engine will not unwind, the process is the only unit
    /// of isolation the engine ABI leaves available — its state is global, so
    /// only a fresh process is reliably clean. `_exit` skips `atexit` handlers
    /// on purpose: those would run on top of the very runtime that is stuck.
    /// `os_log` delivers synchronously to `logd`, so the diagnostics above are
    /// already durable by the time this fires.
    func scheduleProcessRelaunch(reason: StaticString) {
        let text = String(describing: reason)
        EngineLifecycleLog.logger.error(
            "stage=engineLifecycle relaunchScheduled reason=\(text, privacy: .public) delayMilliseconds=\(TunnelStartupTimingPolicy.providerEngineRelaunchDelayMilliseconds, privacy: .public)"
        )
        joinQueue.asyncAfter(
            deadline: .now() + .milliseconds(
                TunnelStartupTimingPolicy.providerEngineRelaunchDelayMilliseconds
            )
        ) {
            EngineLifecycleLog.logger.error(
                "stage=engineLifecycle relaunching reason=\(text, privacy: .public)"
            )
            _exit(0)
        }
    }
}

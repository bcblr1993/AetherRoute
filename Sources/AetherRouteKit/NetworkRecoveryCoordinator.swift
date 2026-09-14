import Foundation

/// Drives a Network Extension provider back to a working data path after the
/// host suspends, resumes, or changes network path.
///
/// The provider used to fire a fixed pair of recovery attempts a couple of
/// seconds after `wake()` and then stop. A laptop that reopens onto Wi-Fi needs
/// far longer than that — reassociation and DHCP routinely take five to fifteen
/// seconds, and 802.1X longer — so both attempts ran against a network that did
/// not exist yet, and nothing ever re-ran. The tunnel stayed up and carried no
/// traffic until the user disconnected and reconnected.
///
/// This coordinator replaces that with a converging loop:
///
/// * attempts back off, spanning minutes rather than seconds, so a slow link
///   is still caught;
/// * every attempt is followed by a real health check and the loop stops on the
///   first success, so a fast link costs one attempt;
/// * triggers arriving close together collapse into one run. The host emits
///   sleep and wake through several independent notifications, which produced
///   four resets and four route reinstalls inside six seconds.
public final class NetworkRecoveryCoordinator: @unchecked Sendable {
    /// Outcome of one attempt, reported to `observer` for logging.
    public enum Event: Sendable, Equatable {
        /// A trigger opened a new run.
        case started(reason: String)
        /// A trigger landed inside the debounce window of the current run.
        case coalesced(reason: String)
        /// An attempt ran and the health check still reports no data path.
        case attemptFailed(reason: String, attempt: Int)
        /// The health check passed; the run is complete.
        case recovered(reason: String, attempt: Int)
        /// Every attempt ran without the health check passing.
        case exhausted(reason: String, attempts: Int)
        /// The run was abandoned, because the host is suspending or stopping.
        case cancelled(reason: String)
    }

    /// Delays before each attempt, measured from the end of the previous one.
    ///
    /// Front-loaded so an unchanged network recovers almost immediately, then
    /// stretched so a link that takes a minute to come up is still reached.
    /// The default spans roughly two and a half minutes.
    public static let defaultDelays: [TimeInterval] = [
        0.5, 1, 2, 4, 8, 12, 20, 30, 45, 60,
    ]

    /// Triggers closer together than this join the run already in flight.
    public static let defaultDebounce: TimeInterval = 1.5

    private let delays: [TimeInterval]
    private let debounce: TimeInterval
    private let queue: DispatchQueue
    private let perform: @Sendable (String, Int) -> Void
    private let verify: @Sendable () -> Bool
    private let observer: @Sendable (Event) -> Void
    private let clock: @Sendable () -> Date

    private var pending: DispatchWorkItem?
    private var runToken: UInt64 = 0
    private var isRunning = false
    /// Stamped when a run starts *and* when it ends. Reinstalling the tunnel's
    /// settings makes the tunnel interface disappear and reappear, which the
    /// path monitor reports as a change, so a completed run is immediately
    /// followed by triggers the run itself caused. Debouncing from the end of a
    /// run as well as its start swallows that echo instead of starting another
    /// round of resets.
    private var lastRunActivityAt: Date?

    /// - Parameters:
    ///   - perform: One recovery attempt: reset the core's network state and
    ///     reinstall the provider's network settings. Receives the trigger
    ///     reason and the zero-based attempt index.
    ///   - verify: Health check. Returns `true` once traffic can leave the
    ///     host again. Runs on the coordinator's queue and may block.
    public init(
        delays: [TimeInterval] = NetworkRecoveryCoordinator.defaultDelays,
        debounce: TimeInterval = NetworkRecoveryCoordinator.defaultDebounce,
        queue: DispatchQueue = DispatchQueue(
            label: "com.aetherroute.network-recovery",
            qos: .userInitiated
        ),
        clock: @escaping @Sendable () -> Date = { Date() },
        perform: @escaping @Sendable (String, Int) -> Void,
        verify: @escaping @Sendable () -> Bool,
        observer: @escaping @Sendable (Event) -> Void = { _ in }
    ) {
        precondition(!delays.isEmpty, "recovery needs at least one attempt")
        self.delays = delays
        self.debounce = debounce
        self.queue = queue
        self.clock = clock
        self.perform = perform
        self.verify = verify
        self.observer = observer
    }

    /// Requests recovery. Safe to call from any thread and from any number of
    /// notification sources; overlapping requests collapse into one run.
    public func trigger(reason: String, supersedes: Bool = false) {
        queue.async { [self] in
            // A run already in flight is the answer to any new trigger: it
            // retries on its own and stops on its own health check. Restarting
            // it would reset the backoff, and reinstalling routes itself emits
            // path-change notifications, so accepting triggers mid-run kept the
            // loop pinned to its shortest delays and it never reached the long
            // ones a slow link needs.
            if isRunning && !supersedes {
                observer(.coalesced(reason: reason))
                return
            }
            let now = clock()
            if !supersedes, let activeAt = lastRunActivityAt,
               now.timeIntervalSince(activeAt) < debounce {
                observer(.coalesced(reason: reason))
                return
            }
            lastRunActivityAt = now
            isRunning = true
            runToken &+= 1
            pending?.cancel()
            pending = nil
            observer(.started(reason: reason))
            scheduleAttempt(index: 0, token: runToken, reason: reason)
        }
    }

    /// Abandons any run in flight. Call when the host is suspending or the
    /// provider is stopping, so a queued attempt cannot outlive it.
    public func cancel(reason: String = "cancelled") {
        queue.async { [self] in
            let wasRunning = isRunning
            pending?.cancel()
            pending = nil
            runToken &+= 1
            isRunning = false
            // Deliberately clears the debounce stamp: a cancel is a suspend or
            // a stop, and the wake that follows must be able to start a run
            // immediately instead of being swallowed as a duplicate.
            lastRunActivityAt = nil
            if wasRunning {
                observer(.cancelled(reason: reason))
            }
        }
    }

    /// Blocks until the queue has drained. Tests only.
    public func waitForQuiescence() {
        queue.sync {}
    }

    private func scheduleAttempt(index: Int, token: UInt64, reason: String) {
        guard index < delays.count else {
            pending = nil
            isRunning = false
            lastRunActivityAt = clock()
            observer(.exhausted(reason: reason, attempts: delays.count))
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A newer run, or a cancel, invalidates this attempt. The token
            // check matters because `DispatchWorkItem.cancel` cannot interrupt
            // an item the queue has already begun executing.
            guard self.runToken == token else { return }
            self.perform(reason, index)
            guard self.runToken == token else { return }
            if self.verify() {
                self.pending = nil
                self.isRunning = false
                self.lastRunActivityAt = self.clock()
                self.observer(.recovered(reason: reason, attempt: index))
                return
            }
            self.observer(.attemptFailed(reason: reason, attempt: index))
            self.scheduleAttempt(index: index + 1, token: token, reason: reason)
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delays[index], execute: item)
    }
}

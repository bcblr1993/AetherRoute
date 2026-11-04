import Foundation

/// Connectivity probes are evidence about a route, not proof that a provider
/// has failed. A blocked endpoint or an unused GLOBAL selection must never
/// cause the provider to tear down unrelated, working rule-based traffic.
///
/// Only a probe through the engine counts. Received bytes used to count as
/// well, but any flow produces them, including ones that bypass the engine's
/// outbound path, so a recovery could report success while proxied traffic
/// was still dead (1.7.1).
public enum NetworkRecoveryHealthPolicy {
    public static let probeURLs = [
        "https://www.google.com/generate_204",
        "https://cp.cloudflare.com/generate_204",
        "https://www.apple.com/library/test/success.html",
    ]

    public static let directProbeURLs = [
        "https://www.apple.com/library/test/success.html",
        "https://cp.cloudflare.com/generate_204",
        "https://www.google.com/generate_204",
    ]

    public static func probeURLStrings(forTargetGroup group: String) -> [String] {
        if group.caseInsensitiveCompare("DIRECT") == .orderedSame {
            return directProbeURLs
        }
        return probeURLs
    }

    public static func probeURLs(forTargetGroup group: String) -> [URL] {
        probeURLStrings(forTargetGroup: group).compactMap(URL.init(string:))
    }

    public static func isReachable(
        probe: (String) throws -> Bool
    ) -> Bool {
        for url in probeURLs {
            if (try? probe(url)) == true { return true }
        }
        return false
    }

    /// Engine groups to probe, in order; the first that answers proves the
    /// data path. GLOBAL comes first: its node usually works and answers in
    /// a few hundred milliseconds, while a direct probe of the first URL waits
    /// out its timeout where that host is blocked. DIRECT follows because
    /// what a network change breaks is the engine's own outbound path
    /// (interface binding, DNS), which DIRECT tests without depending on a
    /// node: a dead GLOBAL node alone must not keep a recovery failing, which
    /// would rebuild a healthy transparent engine or hold TUN reasserting.
    public static func probeGroups(routingMode: RoutingMode) -> [String] {
        routingMode == .direct
            ? ["DIRECT"]
            : [ProxyConnectionReadinessPolicy.globalGroupName, "DIRECT"]
    }

    /// Whether any of `groups` reaches any probe URL.
    public static func isReachable(
        groups: [String],
        probe: (_ group: String, _ url: String) throws -> Bool
    ) -> Bool {
        groups.contains { group in
            for url in probeURLStrings(forTargetGroup: group) {
                if (try? probe(group, url)) == true { return true }
            }
            return false
        }
    }
}

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

    private let stateLock = NSLock()
    private var pending: DispatchWorkItem?
    private var runToken: UInt64 = 0
    private var isRunning = false
    private var currentReason: String?
    private var currentAttemptIndex = 0
    private var lastCompletedReason: String?
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
        let decision: (coalesced: Bool, token: UInt64) = stateLock.withLock {
            let effectiveSupersedes: Bool
            if reason == "appMessage",
               (isRunning && (currentReason == "wake" || currentAttemptIndex == 0))
                || (!isRunning && lastCompletedReason != nil) {
                // The host app sends resetNetwork on systemDidWake ~500ms after
                // wake. Often SCDynamicStore (physicalLinkChanged) or NWPathMonitor
                // (pathChanged) has already started attempt 0 or just completed a
                // recovery run on wake, whereas NEProvider.wake() may never arrive.
                // Coalesce into an active attempt 0 or a just-completed run, while
                // still superseding a stale run that already failed attempt 0 and
                // is waiting on a long backoff delay.
                effectiveSupersedes = false
            } else {
                effectiveSupersedes = supersedes
            }
            if isRunning && !effectiveSupersedes {
                return (true, runToken)
            }
            let now = clock()
            if !effectiveSupersedes, let activeAt = lastRunActivityAt,
               now.timeIntervalSince(activeAt) < debounce {
                return (true, runToken)
            }
            lastRunActivityAt = now
            isRunning = true
            currentReason = reason
            currentAttemptIndex = 0
            runToken &+= 1
            pending?.cancel()
            pending = nil
            return (false, runToken)
        }
        if decision.coalesced {
            observer(.coalesced(reason: reason))
            return
        }
        let token = decision.token
        queue.async { [self] in
            guard stateLock.withLock({ runToken == token }) else { return }
            observer(.started(reason: reason))
            scheduleAttempt(index: 0, token: token, reason: reason)
        }
    }

    /// Abandons any run in flight. Call when the host is suspending or the
    /// provider is stopping, so a queued attempt cannot outlive it.
    public func cancel(reason: String = "cancelled") {
        let wasRunning: Bool = stateLock.withLock {
            let running = isRunning
            pending?.cancel()
            pending = nil
            runToken &+= 1
            isRunning = false
            currentReason = nil
            currentAttemptIndex = 0
            lastCompletedReason = nil
            // Deliberately clears the debounce stamp: a cancel is a suspend or
            // a stop, and the wake that follows must be able to start a run
            // immediately instead of being swallowed as a duplicate.
            lastRunActivityAt = nil
            return running
        }
        if wasRunning {
            observer(.cancelled(reason: reason))
        }
    }

    /// Blocks until the queue has drained. Tests only.
    public func waitForQuiescence() {
        queue.sync {}
    }

    private func scheduleAttempt(index: Int, token: UInt64, reason: String) {
        guard index < delays.count else {
            let stillValid: Bool = stateLock.withLock {
                guard runToken == token else { return false }
                pending = nil
                isRunning = false
                currentReason = nil
                lastCompletedReason = reason
                lastRunActivityAt = clock()
                return true
            }
            guard stillValid else { return }
            observer(.exhausted(reason: reason, attempts: delays.count))
            return
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // A newer run, or a cancel, invalidates this attempt. The token
            // check matters because `DispatchWorkItem.cancel` cannot interrupt
            // an item the queue has already begun executing.
            guard self.stateLock.withLock({ self.runToken == token }) else { return }
            self.perform(reason, index)
            guard self.stateLock.withLock({ self.runToken == token }) else { return }
            let healthy = self.verify()
            let stillValid: Bool = self.stateLock.withLock {
                guard self.runToken == token else { return false }
                if healthy {
                    self.pending = nil
                    self.isRunning = false
                    self.currentReason = nil
                    self.currentAttemptIndex = 0
                    self.lastCompletedReason = reason
                    self.lastRunActivityAt = self.clock()
                } else {
                    self.currentAttemptIndex = index + 1
                }
                return true
            }
            guard stillValid else { return }
            if healthy {
                self.observer(.recovered(reason: reason, attempt: index))
                return
            }
            self.observer(.attemptFailed(reason: reason, attempt: index))
            self.scheduleAttempt(index: index + 1, token: token, reason: reason)
        }
        let scheduled: Bool = stateLock.withLock {
            guard runToken == token else { return false }
            pending = item
            return true
        }
        guard scheduled else { return }
        queue.asyncAfter(deadline: .now() + delays[index], execute: item)
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

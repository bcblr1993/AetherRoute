import Foundation

/// Policy for restoring the user's previous connection intent upon application startup.
///
/// When the system boots or the application starts via login items, network interfaces
/// (such as Wi-Fi or DHCP) may take well over twenty seconds to acquire an address and a
/// default route, and system extension daemons (`sysextd`) or `NEVPNManager` configurations
/// may still be settling.
///
/// The restore therefore waits for a usable network path before spending an attempt,
/// waits for each attempt's actual outcome instead of judging after a fixed sleep, and
/// gives up only after an overall time budget. An explicit user disconnect revokes the
/// saved intent and always wins.
public enum StartupConnectionRestorePolicy {
    /// Total time the restore may run, measured from the moment it begins.
    public static let overallBudget: TimeInterval = 120

    /// How long a submitted attempt may stay connecting before it is judged failed.
    /// A warm connect passes readiness in about two seconds; a cold one after boot
    /// can take several times that.
    public static let attemptOutcomeTimeout: TimeInterval = 20

    /// Backoff delays in seconds after each failed attempt. Attempt `n` (zero-based)
    /// is followed by `retryDelays[n]`; the last attempt has no delay after it.
    public static let retryDelays: [TimeInterval] = [2, 4, 8, 15, 30]

    /// Maximum number of restoration attempts allowed.
    public static var maximumAttempts: Int { retryDelays.count + 1 }

    /// Why a restore stopped.
    public enum FinishReason: String, Equatable, Sendable {
        case connected
        case intentRevoked
        case terminating
        case budgetExhausted
        case attemptsExhausted
    }

    /// What the restore loop should do next.
    public enum Step: Equatable, Sendable {
        case finish(FinishReason)
        /// No satisfied network path yet; an attempt now would only fail.
        case waitForNetwork
        /// The host cannot start a connection right now (still preparing, a
        /// profile update in flight, an automatic reconnect already scheduled…).
        case waitForReadiness
        case attempt
    }

    /// Everything `nextStep` needs, captured at one instant.
    public struct Snapshot: Equatable, Sendable {
        public var elapsed: TimeInterval
        public var attemptsMade: Int
        public var wasConnectedBeforeTermination: Bool
        public var isTerminating: Bool
        public var isConnected: Bool
        public var networkPathSatisfied: Bool
        public var canStartConnection: Bool
        public var automaticReconnectPending: Bool

        public init(
            elapsed: TimeInterval,
            attemptsMade: Int,
            wasConnectedBeforeTermination: Bool,
            isTerminating: Bool,
            isConnected: Bool,
            networkPathSatisfied: Bool,
            canStartConnection: Bool,
            automaticReconnectPending: Bool
        ) {
            self.elapsed = elapsed
            self.attemptsMade = attemptsMade
            self.wasConnectedBeforeTermination = wasConnectedBeforeTermination
            self.isTerminating = isTerminating
            self.isConnected = isConnected
            self.networkPathSatisfied = networkPathSatisfied
            self.canStartConnection = canStartConnection
            self.automaticReconnectPending = automaticReconnectPending
        }
    }

    /// Decides the next step. Termination and a revoked intent come first so a
    /// user disconnect is never fought; a connection made by any route ends the
    /// restore before the budget is consulted.
    public static func nextStep(_ snapshot: Snapshot) -> Step {
        if snapshot.isTerminating { return .finish(.terminating) }
        if !snapshot.wasConnectedBeforeTermination { return .finish(.intentRevoked) }
        if snapshot.isConnected { return .finish(.connected) }
        if snapshot.elapsed >= overallBudget { return .finish(.budgetExhausted) }
        if snapshot.attemptsMade >= maximumAttempts { return .finish(.attemptsExhausted) }
        if !snapshot.networkPathSatisfied { return .waitForNetwork }
        if !snapshot.canStartConnection || snapshot.automaticReconnectPending {
            return .waitForReadiness
        }
        return .attempt
    }

    /// Where a submitted attempt currently stands, as seen from the host state.
    public enum AttemptProgress: Equatable, Sendable {
        case connected
        /// Loading, connecting or recovering.
        case inProgress
        /// Disconnected or failed.
        case stopped
    }

    public enum AttemptOutcome: Equatable, Sendable {
        case succeeded
        case failed
        case pending
        case timedOut
    }

    /// Judges a submitted attempt after it has been observed for `waited` seconds.
    public static func attemptOutcome(
        progress: AttemptProgress,
        waited: TimeInterval
    ) -> AttemptOutcome {
        switch progress {
        case .connected: .succeeded
        case .stopped: .failed
        case .inProgress: waited >= attemptOutcomeTimeout ? .timedOut : .pending
        }
    }

    /// The delay after the given zero-based attempt, or `nil` if attempts are exhausted.
    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < retryDelays.count else { return nil }
        return retryDelays[attempt]
    }

    /// The backoff after `attemptsMade` attempts, clamped so it never sleeps past
    /// the overall budget. `nil` when no further attempt can be made.
    public static func backoffDelay(
        afterAttempts attemptsMade: Int,
        elapsed: TimeInterval
    ) -> TimeInterval? {
        guard attemptsMade >= 1,
              let delay = delay(forAttempt: attemptsMade - 1)
        else { return nil }
        let remaining = overallBudget - elapsed
        guard remaining > 0 else { return nil }
        return min(delay, remaining)
    }

    /// Whether an auto-restoration attempt should be made.
    public static func shouldAttemptRestore(
        wasConnectedBeforeTermination: Bool,
        attempt: Int,
        isTerminating: Bool = false
    ) -> Bool {
        wasConnectedBeforeTermination
            && !isTerminating
            && attempt >= 0
            && attempt < maximumAttempts
    }
}

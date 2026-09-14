import Foundation

/// Decides whether the host brings the tunnel back up after the provider
/// terminated without being asked to.
///
/// macOS kills a Network Extension that stops answering IPC. When that happened
/// the host landed in `.disconnected` and stayed there — the provider was gone,
/// nothing was retrying, and the only way back was for the user to press
/// Connect. A dropped uplink could therefore cost the connection permanently
/// even though the tunnel would have come straight back.
///
/// The schedule below closes that gap without introducing the opposite failure:
/// a node that is genuinely dead must not pin the host in a reconnect loop, and
/// a user who pressed Disconnect must never be reconnected behind their back.
public enum ProviderAutoReconnectPolicy {
    /// Delays before each reconnect, measured from the termination.
    ///
    /// Front-loaded because an extension killed for a transient stall is
    /// usually startable again immediately, then stretched so a link that is
    /// still settling is reached without hammering an unreachable node. The
    /// budget spans roughly a minute and a quarter in total.
    public static let delays: [TimeInterval] = [1, 3, 8, 20, 45]

    /// How many reconnects the host will attempt before giving up and leaving
    /// the failure on screen for the user to act on.
    public static var maximumAttempts: Int { delays.count }

    /// The delay before `attempt`, or `nil` once the budget is spent.
    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < delays.count else { return nil }
        return delays[attempt]
    }

    /// Whether a reconnect should be scheduled.
    ///
    /// - Parameters:
    ///   - terminationWasUnexpected: the provider stopped without the host
    ///     asking it to. A stop the host requested is never retried.
    ///   - userWantsConnection: the user's standing intent is to be connected.
    ///     False as soon as they disconnect, which cancels the schedule.
    ///   - attempt: zero-based index of the reconnect about to be scheduled.
    public static func shouldReconnect(
        terminationWasUnexpected: Bool,
        userWantsConnection: Bool,
        attempt: Int
    ) -> Bool {
        terminationWasUnexpected
            && userWantsConnection
            && attempt >= 0
            && attempt < maximumAttempts
    }
}

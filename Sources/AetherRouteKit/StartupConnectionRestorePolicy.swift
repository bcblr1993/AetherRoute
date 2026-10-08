import Foundation

/// Policy for restoring the user's previous connection intent upon application startup.
///
/// When the system boots or the application starts via login items, network interfaces
/// (such as Wi-Fi or DHCP) may take several seconds to acquire an IP address and default route.
/// Furthermore, system extension daemons (`sysextd`) or `NEVPNManager` configurations may be
/// settling.
///
/// This policy governs retry attempts and backoff delays to robustly re-establish the connection
/// without spamming the system or pinning the app when conditions cannot be satisfied.
public enum StartupConnectionRestorePolicy {
    /// Retry backoff delays in seconds between failed or unready restore attempts.
    public static let retryDelays: [TimeInterval] = [1.0, 2.0, 3.0, 5.0, 8.0]

    /// Maximum number of restoration attempts allowed.
    public static var maximumAttempts: Int { retryDelays.count }

    /// The delay before the given zero-based attempt, or `nil` if attempts are exhausted.
    public static func delay(forAttempt attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < retryDelays.count else { return nil }
        return retryDelays[attempt]
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

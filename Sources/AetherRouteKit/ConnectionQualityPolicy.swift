import Foundation

/// Quality of the route behind a tunnel that is already carrying traffic.
///
/// "The tunnel is up" and "the selected route is fast" are separate questions.
/// Conflating them is what made a healthy-but-distant node look like a failed
/// connection: the app withheld `connected` until a probe answered, then tore
/// the tunnel down when it did not. These cases describe only the second
/// question, so the first can be answered the moment network settings install.
public enum ConnectionQuality: Equatable, Sendable {
    /// No probe has run yet for this connection.
    case unknown
    /// A probe is in flight. The tunnel is usable meanwhile.
    case verifying
    /// The route answered both the latency and data-plane checks.
    case verified
    /// The route missed its probe budget. Still connected, still usable.
    case degraded

    public var isDegraded: Bool { self == .degraded }
}

/// Decides what a finished readiness probe means for an already-usable tunnel.
///
/// The distinction that matters is not "did the probe pass" but "does traffic
/// reach the internet". A slow node fails the first and passes the second, and
/// must keep its tunnel. A dead node fails both, and must leave the tunnel
/// stoppable: the extension is fail-closed, so keeping a dead tunnel alive
/// blackholes every request instead of returning the user to direct access.
public enum ConnectionQualityPolicy {
    /// A quality notice belongs to the current connected session. An old
    /// result, or a session without a measurement, must not imply verification.
    public static func displayedQuality(
        _ quality: ConnectionQuality,
        isConnected: Bool
    ) -> ConnectionQuality? {
        guard isConnected, quality != .unknown else { return nil }
        return quality
    }

    /// What the host should do once a readiness probe resolves.
    public struct Outcome: Equatable, Sendable {
        public let quality: ConnectionQuality
        /// Whether the connection should be recorded as having carried real
        /// traffic. Route-health exhaustion keeps such a tunnel alive rather
        /// than stopping it on a transient outage.
        public let marksConnectionUsable: Bool
        /// Readiness never disconnects. Kept explicit so the invariant is
        /// visible at the call site and in tests.
        public let stopsTunnel: Bool = false

        public init(quality: ConnectionQuality, marksConnectionUsable: Bool) {
            self.quality = quality
            self.marksConnectionUsable = marksConnectionUsable
        }
    }

    /// - Parameters:
    ///   - probeSucceeded: whether the full readiness sequence passed.
    ///   - trafficReachesInternet: result of the fallback data-plane request,
    ///     consulted only when `probeSucceeded` is `false`.
    public static func outcome(
        probeSucceeded: Bool,
        trafficReachesInternet: Bool
    ) -> Outcome {
        guard probeSucceeded else {
            return Outcome(
                quality: .degraded,
                marksConnectionUsable: trafficReachesInternet
            )
        }
        return Outcome(quality: .verified, marksConnectionUsable: true)
    }
}

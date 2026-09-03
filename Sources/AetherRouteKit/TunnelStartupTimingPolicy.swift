import Foundation

/// Shared upper bounds for the host and packet-provider startup sequence.
///
/// Profiles that use GeoIP or GeoSite resources can spend several seconds
/// compiling their routing matchers before the protocol core reports ready.
/// The provider must therefore get a meaningful initialization window while
/// still finishing before the host watchdog supplies a final safety bound.
public enum TunnelStartupTimingPolicy {
    public static let providerCoreReadinessTimeoutSeconds = 20
    public static let hostConnectionWatchdogTimeoutSeconds = 60
    /// Real VLESS/Hysteria2 cold starts in a fresh Network Extension can spend
    /// more than three seconds on DNS, transport and TLS even though the route
    /// is healthy. Five seconds still fails quickly, while avoiding a false
    /// "no responsive proxy" result before the first HTTPS response arrives.
    public static let selectorReadinessPerMemberTimeoutMilliseconds: UInt32 = 5_000
    public static let selectorReadinessMaximumMemberCount = 64
    public static let selectorReadinessMaximumConcurrency = 8
    public static let selectorReadinessResponseGraceSeconds = 2
    /// Traffic counters are informational UI data. Each sample also crosses
    /// the Network Extension boundary and asks the embedded core for a bounded
    /// connection snapshot. A ten-second cadence keeps the dashboard useful
    /// while preventing the provider allocator from accumulating short-lived
    /// snapshot/channel pages during long sessions.
    public static let telemetryPollingIntervalSeconds = 10
    public static let automaticRouteHealthIntervalSeconds = 15
    public static let automaticRouteFailoverAttemptCount = 8
    public static let automaticRouteFailureThreshold = 2
    /// Manual mode stays pinned to the selected leaf, but a single lost
    /// readiness request must not turn a healthy node into a failed profile
    /// switch. These retries never select a sibling node.
    public static let manualRouteReadinessAttemptCount = 3
    /// Immediately after a profile restart, the selector can report the
    /// pinned leaf as unavailable while its transport is still warming up.
    /// Space retries far enough apart to observe that transition instead of
    /// issuing three equivalent probes in the same scheduler slice.
    public static let activeRouteReadinessRetryDelayMilliseconds = 750
    /// The external data-plane check is intentionally independent from the
    /// selector probe. Retry the same active route so an isolated HTTP timeout
    /// cannot force an otherwise healthy connection to roll back.
    public static let routeDataPlaneReadinessAttemptCount = 3
    public static let routeReadinessRetryDelayMilliseconds = 250
    /// Candidates are already ordered by a common provider latency batch.
    /// A five-second independent data-plane request preserves the cold-start
    /// allowance used by selector readiness while keeping failover bounded.
    public static let automaticRouteCandidateProbeTimeoutSeconds = 5
    /// Covers all eight bounded selector batches (64 members / concurrency 8)
    /// at the five-second member timeout, plus reply and scheduling grace.
    public static let automaticRouteProviderMessageTimeoutSeconds = 50
    /// `clash_shutdown` requests cancellation but the embedded Tokio runtime
    /// is not destroyed until its worker returns. Keep the provider alive long
    /// enough to join that worker before a subsequent tunnel start can reuse
    /// the process, while still completing below the host disconnect watchdog.
    public static let providerCoreShutdownWaitTimeoutSeconds = 10
    public static let hostDisconnectionWatchdogTimeoutSeconds = 35

    /// The embedded selector runs bounded batches and adds a two-second reply
    /// grace period. Keep the host deadline beyond that hard upper bound so a
    /// large subscription cannot be mistaken for a dead provider while still
    /// keeping cancellation and shutdown finite.
    public static let selectorReadinessProviderMessageTimeoutSeconds =
        ((selectorReadinessMaximumMemberCount
            + selectorReadinessMaximumConcurrency - 1)
            / selectorReadinessMaximumConcurrency)
        * Int(selectorReadinessPerMemberTimeoutMilliseconds / 1_000)
        + selectorReadinessResponseGraceSeconds
        + 4

    public static var providerCoreReadinessTimeout: Duration {
        .seconds(providerCoreReadinessTimeoutSeconds)
    }

    public static var hostConnectionWatchdogTimeout: Duration {
        .seconds(hostConnectionWatchdogTimeoutSeconds)
    }

    public static var hostDisconnectionWatchdogTimeout: Duration {
        .seconds(hostDisconnectionWatchdogTimeoutSeconds)
    }

    public static var providerCoreShutdownWaitTimeout: Duration {
        .seconds(providerCoreShutdownWaitTimeoutSeconds)
    }

    public static var selectorReadinessProviderMessageTimeout: Duration {
        .seconds(selectorReadinessProviderMessageTimeoutSeconds)
    }

    public static var automaticRouteProviderMessageTimeout: Duration {
        .seconds(automaticRouteProviderMessageTimeoutSeconds)
    }
}

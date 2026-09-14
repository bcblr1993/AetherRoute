import Foundation

/// Shared upper bounds for the host and packet-provider startup sequence.
///
/// Profiles that use GeoIP or GeoSite resources can spend several seconds
/// compiling their routing matchers before the protocol core reports ready.
/// The provider must therefore get a meaningful initialization window while
/// still finishing before the host watchdog supplies a final safety bound.
public enum TunnelStartupTimingPolicy {
    public static let providerCoreReadinessTimeoutSeconds = 20
    /// Guards only the window between requesting a connection and the provider
    /// reporting connected; it is cancelled the moment that happens. Route
    /// readiness runs afterwards in the background, so this bound is
    /// deliberately independent of the selector timeouts below — a slow node
    /// must never lengthen the time it takes to notice a stuck connection.
    public static let hostConnectionWatchdogTimeoutSeconds = 60
    /// Real VLESS/Hysteria2 cold starts in a fresh Network Extension can spend
    /// well over five seconds on DNS, transport and TLS even though the route
    /// is healthy — measured nodes have needed close to nine. Because readiness
    /// no longer gates the connection (the tunnel is usable as soon as its
    /// network settings install, and a failed probe only marks the route
    /// degraded), a longer budget costs the user nothing and stops healthy but
    /// distant nodes from being reported as dead.
    public static let selectorReadinessPerMemberTimeoutMilliseconds: UInt32 = 10_000
    public static let selectorReadinessMaximumMemberCount = 64
    public static let selectorReadinessMaximumConcurrency = 8
    public static let selectorReadinessResponseGraceSeconds = 2
    /// When the live traffic dashboard (or connections inspector) is actively visible
    /// in the foreground, telemetry polls at 1 Hz to provide a real-time sliding waveform.
    public static let activeTelemetryPollingIntervalSeconds = 1
    /// When the dashboard is idle, in background, or running in tray, telemetry
    /// steps down to 10 seconds to conserve battery and CPU.
    public static let backgroundTelemetryPollingIntervalSeconds = 10
    /// Legacy alias for backward compatibility with existing tests and call sites.
    public static let telemetryPollingIntervalSeconds = backgroundTelemetryPollingIntervalSeconds
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
    /// This independent data-plane request mirrors the selector cold-start
    /// allowance so a node is never rejected by the stricter of two budgets.
    public static let automaticRouteCandidateProbeTimeoutSeconds = 10
    /// Covers all eight bounded selector batches (64 members / concurrency 8)
    /// at the member timeout, plus reply and scheduling grace.
    public static let automaticRouteProviderMessageTimeoutSeconds = 90
    /// `clash_shutdown` only cancels; the embedded Tokio runtime is not
    /// destroyed until every task observes that cancellation. Against a node
    /// that has stopped answering, tasks blocked on their own I/O deadlines
    /// have been measured taking over four minutes to unwind — far longer than
    /// any budget a user should wait behind. Disconnect therefore never blocks
    /// on the join; this bound applies to the opposite edge, where a *new*
    /// tunnel start finds the previous engine still winding down.
    ///
    /// The engine ABI is process-wide and handle-free, so the replacement
    /// cannot simply start alongside it. Wait this long for a clean handoff,
    /// then relaunch the extension process rather than run two engines that
    /// share one cancellation registry. Sized to leave the readiness budget
    /// intact underneath the host connection watchdog.
    public static let providerEngineHandoffWaitTimeoutSeconds = 15
    /// How long the provider keeps running after reporting a failed handoff, so
    /// the host receives the error over XPC before the process exits.
    public static let providerEngineRelaunchDelayMilliseconds = 1_000
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

    public static var providerEngineHandoffWaitTimeout: Duration {
        .seconds(providerEngineHandoffWaitTimeoutSeconds)
    }

    public static var selectorReadinessProviderMessageTimeout: Duration {
        .seconds(selectorReadinessProviderMessageTimeoutSeconds)
    }

    public static var automaticRouteProviderMessageTimeout: Duration {
        .seconds(automaticRouteProviderMessageTimeoutSeconds)
    }
}

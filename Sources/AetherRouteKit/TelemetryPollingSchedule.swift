import Foundation

/// How often the host asks the extension for traffic numbers.
public enum TelemetryCadence: Equatable, Sendable {
    /// A surface showing live traffic is visible and frontmost.
    case realtime
    /// A surface showing live traffic is visible behind another app.
    case background
    /// Nothing showing traffic is visible, but traffic statistics are on.
    case statistics
    /// Nothing showing traffic is visible; only route health is checked.
    case healthOnly

    public var telemetryIntervalSeconds: Int? {
        switch self {
        case .realtime: TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds
        case .background: TunnelStartupTimingPolicy.backgroundTelemetryPollingIntervalSeconds
        case .statistics: TunnelStartupTimingPolicy.statisticsTelemetryPollingIntervalSeconds
        case .healthOnly: nil
        }
    }

    /// The strongest demand across surfaces wins.
    public static func resolve(realtimeSources: Int, backgroundSources: Int) -> TelemetryCadence {
        if realtimeSources > 0 { return .realtime }
        if backgroundSources > 0 { return .background }
        return .healthOnly
    }
}

/// Interleaves traffic refreshes with automatic route health checks.
///
/// The two run on independent countdowns so route health keeps its own
/// interval whatever the traffic cadence is: a 10 s traffic cadence does not
/// divide the 15 s health interval, and counting health in traffic ticks
/// would silently stretch it to 20 s.
public struct TelemetryPollingSchedule: Equatable, Sendable {
    public struct Step: Equatable, Sendable {
        public let sleepSeconds: Int
        public let refreshesTelemetry: Bool
        public let checksRouteHealth: Bool
    }

    private let telemetryInterval: Int?
    private let healthInterval: Int
    private var untilTelemetry: Int?
    private var untilHealth: Int

    public init(
        cadence: TelemetryCadence,
        healthIntervalSeconds: Int = TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds
    ) {
        telemetryInterval = cadence.telemetryIntervalSeconds
        healthInterval = max(1, healthIntervalSeconds)
        untilTelemetry = telemetryInterval.map { max(1, $0) }
        untilHealth = healthInterval
    }

    /// The next wait and what to do when it ends.
    public mutating func next() -> Step {
        let sleep = min(untilTelemetry ?? untilHealth, untilHealth)
        untilHealth -= sleep
        var refreshesTelemetry = false
        if let remaining = untilTelemetry, let interval = telemetryInterval {
            let left = remaining - sleep
            refreshesTelemetry = left <= 0
            untilTelemetry = refreshesTelemetry ? max(1, interval) : left
        }
        let checksRouteHealth = untilHealth <= 0
        if checksRouteHealth { untilHealth = healthInterval }
        return Step(
            sleepSeconds: sleep,
            refreshesTelemetry: refreshesTelemetry,
            checksRouteHealth: checksRouteHealth
        )
    }
}

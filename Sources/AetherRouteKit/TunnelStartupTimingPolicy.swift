import Foundation

/// Shared upper bounds for the host and packet-provider startup sequence.
///
/// Profiles that use GeoIP or GeoSite resources can spend several seconds
/// compiling their routing matchers before the protocol core reports ready.
/// The provider must therefore get a meaningful initialization window while
/// still finishing before the host watchdog supplies a final safety bound.
public enum TunnelStartupTimingPolicy {
    public static let providerCoreReadinessTimeoutSeconds = 20
    public static let hostConnectionWatchdogTimeoutSeconds = 30
    public static let hostDisconnectionWatchdogTimeoutSeconds = 12

    public static var providerCoreReadinessTimeout: Duration {
        .seconds(providerCoreReadinessTimeoutSeconds)
    }

    public static var hostConnectionWatchdogTimeout: Duration {
        .seconds(hostConnectionWatchdogTimeoutSeconds)
    }

    public static var hostDisconnectionWatchdogTimeout: Duration {
        .seconds(hostDisconnectionWatchdogTimeoutSeconds)
    }
}

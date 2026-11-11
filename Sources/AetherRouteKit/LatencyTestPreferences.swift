import Foundation

/// Shared latency-testing preferences stored in `UserDefaults`, used by both
/// the Settings toggle and the latency measurement / presentation layers.
public enum LatencyTestPreferences {
    public static let unifiedDelayKey = "aetherroute.latency.unifiedDelayEnabled"

    /// Whether latency tests measure unified pure-HTTP tunnel RTT (two
    /// keep-alive requests on the same stream, timing only the second) instead
    /// of full cold-start connection + TLS handshake latency. Defaults to `true`.
    public static var isUnifiedDelayEnabled: Bool {
        get { isUnifiedDelayEnabled(in: .standard) }
        set { setUnifiedDelayEnabled(newValue, in: .standard) }
    }

    public static func isUnifiedDelayEnabled(in defaults: UserDefaults) -> Bool {
        guard let raw = defaults.object(forKey: unifiedDelayKey) else {
            return true
        }
        if let flag = raw as? Bool {
            return flag
        }
        if let number = raw as? NSNumber {
            return number.boolValue
        }
        return true
    }

    public static func setUnifiedDelayEnabled(_ enabled: Bool, in defaults: UserDefaults) {
        defaults.set(enabled, forKey: unifiedDelayKey)
    }
}

/// Color-band millisecond cutoffs for latency display.
///
/// Unified delay strips TCP/TLS cold-start overhead and uses standard client
/// thresholds (`<= 120 ms` green, `121–300 ms` orange, `> 300 ms` red); full
/// cold-start handshake mode retains the wider `200 / 500 ms` thresholds.
public struct LatencyBandThresholds: Equatable, Sendable {
    public let fastMaximum: UInt32
    public let moderateMaximum: UInt32

    public init(fastMaximum: UInt32, moderateMaximum: UInt32) {
        self.fastMaximum = fastMaximum
        self.moderateMaximum = moderateMaximum
    }

    public static let unifiedDelay = LatencyBandThresholds(fastMaximum: 120, moderateMaximum: 300)
    public static let fullHandshake = LatencyBandThresholds(fastMaximum: 200, moderateMaximum: 500)

    public static func forUnifiedDelay(_ unifiedDelay: Bool) -> LatencyBandThresholds {
        unifiedDelay ? .unifiedDelay : .fullHandshake
    }

    public static var current: LatencyBandThresholds {
        forUnifiedDelay(LatencyTestPreferences.isUnifiedDelayEnabled)
    }
}

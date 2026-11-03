import Foundation

/// Remembers which physical uplink the engine was last reset onto, so a
/// recovery run only resets when the uplink actually differs.
///
/// Every run used to forget the last reset when it started. Waking a Mac with
/// Wi-Fi and a USB Ethernet adapter then reset the engine three times in five
/// seconds: the wake run reset onto Wi-Fi, the path monitor reported the same
/// Wi-Fi uplink a second later (it still compared against the pre-sleep
/// Ethernet path) and that run reset onto it again, and finally the adapter
/// came back. Each reset closes every proxied connection.
///
/// Runs started by a path change now keep the record, because the change they
/// report may be one an earlier run has already handled. Wake and app requests
/// still force a reset: sockets that slept are stale even on the same uplink.
public struct UplinkResetLedger: Sendable, Equatable {
    /// Reasons whose run reports a new uplink rather than stale sockets.
    public static let pathDrivenReasons: Set<String> = [
        "pathChanged",
        "physicalLinkChanged",
    ]

    /// Whether the last reset succeeded and nothing has invalidated it since.
    /// The health check is meaningless before one has.
    public private(set) var resetSucceeded = false
    public private(set) var rebuiltDuringRun = false
    private var lastResetInterface: UInt32?
    private var lastResetSignature: String?

    public init() {}

    public mutating func runStarted(reason: String) {
        rebuiltDuringRun = false
        guard !Self.pathDrivenReasons.contains(reason) else { return }
        resetSucceeded = false
        lastResetInterface = nil
        lastResetSignature = nil
    }

    /// Whether resetting onto this uplink would change anything.
    public func needsReset(interfaceIndex: UInt32, signature: String?) -> Bool {
        !resetSucceeded
            || lastResetInterface != interfaceIndex
            || lastResetSignature != signature
    }

    /// Call before a reset, and when no uplink is available.
    public mutating func invalidate() {
        resetSucceeded = false
    }

    public mutating func resetCompleted(interfaceIndex: UInt32, signature: String?) {
        lastResetInterface = interfaceIndex
        lastResetSignature = signature
        resetSucceeded = true
    }

    /// Returns `true` the first time in a run, so a run rebuilds at most once.
    public mutating func claimRebuild() -> Bool {
        guard !rebuiltDuringRun else { return false }
        rebuiltDuringRun = true
        return true
    }
}

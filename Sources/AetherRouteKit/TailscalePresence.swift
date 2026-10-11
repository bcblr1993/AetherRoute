import Darwin
import Foundation
import SystemConfiguration

/// Whether Tailscale (or another CGNAT overlay) is running beside
/// AetherRoute (1.7.0), so the app can say how the two share the network.
public struct TailscalePresence: Equatable, Sendable {
    /// A virtual interface holds an address in 100.64.0.0/10.
    public let isRunning: Bool
    /// The overlay owns the default route: a Tailscale exit node competes
    /// with AetherRoute for all traffic.
    public let usesExitNode: Bool

    public init(isRunning: Bool, usesExitNode: Bool) {
        self.isRunning = isRunning
        self.usesExitNode = usesExitNode
    }

    public static let absent = TailscalePresence(isRunning: false, usesExitNode: false)

    /// Reads the current interfaces and the primary IPv4 interface.
    public static func current() -> TailscalePresence {
        let overlays = overlayInterfaces()
        guard !overlays.isEmpty else { return .absent }
        let primary = primaryIPv4Interface()
        return TailscalePresence(
            isRunning: true,
            usesExitNode: primary.map(overlays.contains) ?? false
        )
    }

    /// Names of `utun` interfaces with an IPv4 address in 100.64.0.0/10.
    static func overlayInterfaces() -> Set<String> {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }
        var names = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix("utun") else { continue }
            let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            if isCGNAT(ipv4) { names.insert(name) }
        }
        return names
    }

    /// 100.64.0.0/10.
    static func isCGNAT(_ address: UInt32) -> Bool {
        address & 0xFFC0_0000 == 0x6440_0000
    }

    private static func primaryIPv4Interface() -> String? {
        guard let store = SCDynamicStoreCreate(nil, "AetherRoute.TailscalePresence" as CFString, nil, nil),
              let global = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any]
        else { return nil }
        return global["PrimaryInterface"] as? String
    }
}

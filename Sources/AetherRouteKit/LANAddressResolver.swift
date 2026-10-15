import Darwin
import Foundation

/// Discovers the active local network (LAN) IPv4 address of this Mac.
///
/// Filters out loopback (127.0.0.1), link-local (169.254.x.x), and virtual/tunnel
/// interfaces (utun, awdl, llw, bridge), returning the real IP assigned by the
/// local router on the active physical interface (Wi-Fi or Ethernet).
public enum LANAddressResolver: Sendable {
    public struct InterfaceAddress: Equatable, Sendable {
        public let interfaceName: String
        public let ipAddress: String

        public init(interfaceName: String, ipAddress: String) {
            self.interfaceName = interfaceName
            self.ipAddress = ipAddress
        }
    }

    /// Resolves the primary active LAN IPv4 address (e.g. "192.168.1.108" or "10.0.0.5").
    /// Returns `nil` if the machine is disconnected from all local networks.
    public static func primaryIPv4Address() -> String? {
        allActiveIPv4Addresses().first?.ipAddress
    }

    /// Resolves all active local network IPv4 addresses ordered with physical Wi-Fi/Ethernet first.
    public static func allActiveIPv4Addresses() -> [InterfaceAddress] {
        var ifaddrPointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPointer) == 0, let first = ifaddrPointer else {
            return []
        }
        defer { freeifaddrs(ifaddrPointer) }

        var results: [InterfaceAddress] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = first

        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            guard let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }

            let flags = Int32(current.pointee.ifa_flags)
            // Interface must be up and running, and not loopback
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_RUNNING) != 0,
                  (flags & IFF_LOOPBACK) == 0 else {
                continue
            }

            let name = String(cString: current.pointee.ifa_name)
            // Exclude Apple internal/virtual/P2P wireless interfaces
            guard !isIgnoredInterface(name) else {
                continue
            }

            let sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
            var inAddr = sin.sin_addr
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(AF_INET, &inAddr, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
                continue
            }

            let ip = buffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? ""
            }

            // Ignore loopback, link-local (169.254.x.x), and unspecified
            guard !ip.isEmpty,
                  !ip.hasPrefix("127."),
                  !ip.hasPrefix("169.254."),
                  ip != "0.0.0.0" else {
                continue
            }

            results.append(InterfaceAddress(interfaceName: name, ipAddress: ip))
        }

        // Prioritize physical Wi-Fi/Ethernet (en0, en1, en2...) over others
        return results.sorted { lhs, rhs in
            let lhsPriority = interfacePriority(lhs.interfaceName)
            let rhsPriority = interfacePriority(rhs.interfaceName)
            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }
            return lhs.interfaceName < rhs.interfaceName
        }
    }

    private static func isIgnoredInterface(_ name: String) -> Bool {
        let ignoredPrefixes = [
            "lo",      // Loopback
            "utun",    // VPN/TUN tunnels
            "ipsec",   // IPSec tunnels
            "ppp",     // Point-to-point
            "awdl",    // Apple Wireless Direct Link (AirDrop)
            "llw",     // Low-latency WLAN
            "bridge",  // Thunderbolt bridge / Virtual bridges
            "gif",     // Generic tunnel
            "stf",     // 6to4 tunnel
            "ap",      // Access point virtual interfaces
            "anpi"     // Apple network provisioning
        ]
        return ignoredPrefixes.any { name.hasPrefix($0) }
    }

    private static func interfacePriority(_ name: String) -> Int {
        if name == "en0" { return 0 }
        if name == "en1" { return 1 }
        if name.hasPrefix("en") { return 2 }
        return 3
    }
}

private extension Collection {
    func any(_ predicate: (Element) -> Bool) -> Bool {
        contains(where: predicate)
    }
}

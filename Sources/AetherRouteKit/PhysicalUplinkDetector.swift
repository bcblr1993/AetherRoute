import Darwin
import Foundation
import Network
import SystemConfiguration

/// Represents an identified physical network interface on the host.
public struct PhysicalUplink: Equatable, Hashable, Sendable, CustomStringConvertible {
    public let name: String
    public let index: Int

    public init(name: String, index: Int) {
        self.name = name
        self.index = index
    }

    public var description: String {
        "\(name) (index \(index))"
    }
}

/// Detects, filters and prioritizes physical network uplinks on macOS.
///
/// Ensures virtual interfaces (Docker/OrbStack `feth`, VM bridges, VPN `utun`)
/// are never mistaken for physical egress paths, and dynamically discovers
/// newly attached hardware devices (e.g. USB or Thunderbolt Ethernet) even when
/// sandboxed path monitors fail to emit push updates.
public enum PhysicalUplinkDetector {
    /// Blacklisted virtual, container, or loopback interface prefixes that should never
    /// be treated as the host's physical Internet uplink.
    /// Mirroring the Rust engine's `VIRTUAL_PREFIXES` in `app/net/mod.rs`.
    public static let virtualInterfacePrefixes: [String] = [
        "utun", "bridge", "vmenet", "feth", "awdl", "llw", "ap", "gif", "stf",
        "lo", "anpi",
    ]

    /// Allowed hardware interface prefixes.
    public static let physicalInterfacePrefixes: [String] = [
        "en", "pdp_ip",
    ]

    /// Returns true if the interface name represents an eligible physical hardware interface.
    public static func isEligiblePhysicalInterfaceName(_ name: String) -> Bool {
        let isVirtual = virtualInterfacePrefixes.contains { name.hasPrefix($0) }
        if isVirtual { return false }
        return physicalInterfacePrefixes.contains { name.hasPrefix($0) }
    }

    /// Discovers eligible hardware interfaces currently configured in Darwin libc.
    public static func discoverSystemHardwareInterfaces() -> [PhysicalUplink] {
        guard let ptr = if_nameindex() else { return [] }
        defer { if_freenameindex(ptr) }
        var result: [PhysicalUplink] = []
        var current = ptr
        while current.pointee.if_index != 0 {
            let name = String(cString: current.pointee.if_name)
            let index = Int(current.pointee.if_index)
            if isEligiblePhysicalInterfaceName(name) {
                result.append(PhysicalUplink(name: name, index: index))
            }
            current = current.advanced(by: 1)
        }
        return result
    }

    /// Returns non-link-local, routable IPv4 and IPv6 addresses assigned to the interface.
    public static func physicalAddresses(
        store: SCDynamicStore,
        interfaceName: String
    ) -> [String] {
        ["IPv4", "IPv6"].flatMap { family -> [String] in
            guard let state = SCDynamicStoreCopyValue(
                store,
                "State:/Network/Interface/\(interfaceName)/\(family)" as CFString
            ) as? [String: Any],
                let addresses = state["Addresses"] as? [String] else { return [] }
            return addresses.filter { address in
                !address.hasPrefix("169.254.")
                    && !address.lowercased().hasPrefix("fe80:")
                    && address != "0.0.0.0"
                    && address != "::"
            }
        }
    }

    /// Resolves the current primary physical uplink interface.
    ///
    /// Candidates are evaluated in priority order:
    /// 1. User/System ServiceOrder from `Setup:/Network/Global/IPv4` (macOS Network service priority)
    /// 2. Active interfaces from `cachedPathInterfaces` (from `NWPathMonitor`, if present)
    /// 3. All hardware interfaces discovered via libc `if_nameindex()`
    ///
    /// Selects the first interface with an active physical link and at least one routable IP address.
    public static func currentPhysicalUplink(
        store: SCDynamicStore,
        cachedPathInterfaces: [NWInterface] = []
    ) -> PhysicalUplink? {
        var candidateNames: [String] = []
        var nameToIndex: [String: Int] = [:]

        // 1. Populate all hardware interfaces from if_nameindex
        let allHardware = discoverSystemHardwareInterfaces()
        for iface in allHardware {
            nameToIndex[iface.name] = iface.index
        }

        // 2. Read macOS system ServiceOrder
        if let global = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/IPv4" as CFString) as? [String: Any],
           let serviceOrder = global["ServiceOrder"] as? [String] {
            for serviceID in serviceOrder {
                if let service = SCDynamicStoreCopyValue(store, "Setup:/Network/Service/\(serviceID)/Interface" as CFString) as? [String: Any],
                   let deviceName = service["DeviceName"] as? String,
                   isEligiblePhysicalInterfaceName(deviceName),
                   nameToIndex[deviceName] != nil,
                   !candidateNames.contains(deviceName) {
                    candidateNames.append(deviceName)
                }
            }
        }

        // 3. Append cached path interfaces from NWPathMonitor
        for iface in cachedPathInterfaces {
            let name = iface.name
            if isEligiblePhysicalInterfaceName(name),
               nameToIndex[name] != nil,
               !candidateNames.contains(name) {
                candidateNames.append(name)
            }
        }

        // 4. Append any remaining hardware interfaces
        for iface in allHardware {
            if !candidateNames.contains(iface.name) {
                candidateNames.append(iface.name)
            }
        }

        // 5. Select the first candidate that has an active physical link and valid IP addresses
        for name in candidateNames {
            guard let link = SCDynamicStoreCopyValue(
                store,
                "State:/Network/Interface/\(name)/Link" as CFString
            ) as? [String: Any],
                link["Active"] as? Bool == true else { continue }
            let addrs = physicalAddresses(store: store, interfaceName: name)
            guard !addrs.isEmpty else { continue }
            if let index = nameToIndex[name] {
                return PhysicalUplink(name: name, index: index)
            }
        }

        return nil
    }

    /// Computes a deterministic identity signature for the current physical uplink state.
    public static func pathSignature(
        store: SCDynamicStore,
        uplink: PhysicalUplink?
    ) -> String {
        guard let uplink else { return "offline" }
        let addresses = physicalAddresses(store: store, interfaceName: uplink.name)
        guard !addresses.isEmpty else { return "offline" }
        return "\(uplink.name):\(uplink.index)|" + addresses.sorted().joined(separator: ",")
    }
}

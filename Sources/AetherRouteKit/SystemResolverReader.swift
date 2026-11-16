import Foundation
import SystemConfiguration

/// Reads which resolver macOS consults first.
///
/// Kept apart from `SystemResolverPrecedence` so the comparison stays a pure
/// value type that tests can drive, while the part that talks to the system
/// stays small enough to read in one sitting.
public enum SystemResolverReader {
    /// The global resolver's server addresses, in the order macOS uses them.
    ///
    /// `State:/Network/Global/DNS` is the resolver the system resolves through
    /// after it has ranked every claimant, which is exactly the question worth
    /// asking: two VPNs can both claim every domain, and only one wins.
    /// Read-only system configuration, so a sandboxed app can ask.
    public static func primaryServers(
        store: SCDynamicStore? = SCDynamicStoreCreate(
            nil,
            "com.aetherroute.desktop.diagnostics" as CFString,
            nil,
            nil
        )
    ) -> [String] {
        guard let store else { return [] }
        let globalServers = (SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/DNS" as CFString
        ) as? [String: Any])?["ServerAddresses"] as? [String] ?? []

        var primaryServiceServers: [String] = []
        if let globalIPv4 = SCDynamicStoreCopyValue(
            store,
            "State:/Network/Global/IPv4" as CFString
        ) as? [String: Any],
           let primaryService = globalIPv4["PrimaryService"] as? String,
           !primaryService.isEmpty,
           let serviceDNS = SCDynamicStoreCopyValue(
               store,
               "State:/Network/Service/\(primaryService)/DNS" as CFString
           ) as? [String: Any] {
            primaryServiceServers = serviceDNS["ServerAddresses"] as? [String] ?? []
        }

        var supplementalWildcardServers: [String] = []
        if let serviceKeys = SCDynamicStoreCopyKeyList(
            store,
            "State:/Network/Service/.*/DNS" as CFString
        ) as? [String] {
            for key in serviceKeys.sorted() {
                guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                      let domains = dict["SupplementalMatchDomains"] as? [String],
                      domains.contains(""),
                      let servers = dict["ServerAddresses"] as? [String]
                else { continue }
                supplementalWildcardServers.append(contentsOf: servers)
            }
        }

        return mergedServers(
            globalServers: globalServers,
            primaryServiceServers: primaryServiceServers,
            supplementalWildcardServers: supplementalWildcardServers
        )
    }

    static func mergedServers(
        globalServers: [String],
        primaryServiceServers: [String],
        supplementalWildcardServers: [String]
    ) -> [String] {
        var result = globalServers.isEmpty ? primaryServiceServers : globalServers
        for server in supplementalWildcardServers where !server.isEmpty && !result.contains(server) {
            result.append(server)
        }
        return result
    }

    /// Compares the system's choice against the resolvers the tunnel installed.
    public static func precedence(
        tunnelServers: [String],
        store: SCDynamicStore? = SCDynamicStoreCreate(
            nil,
            "com.aetherroute.desktop.diagnostics" as CFString,
            nil,
            nil
        )
    ) -> SystemResolverPrecedence {
        SystemResolverPrecedence(
            primaryServers: primaryServers(store: store),
            tunnelServers: tunnelServers
        )
    }
}

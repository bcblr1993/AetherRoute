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
        guard let store,
              let value = SCDynamicStoreCopyValue(
                  store,
                  "State:/Network/Global/DNS" as CFString
              ) as? [String: Any],
              let servers = value["ServerAddresses"] as? [String]
        else { return [] }
        return servers
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

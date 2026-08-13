import Foundation

/// A NetworkExtension-independent description of packet-tunnel settings.
///
/// The packet-tunnel provider is responsible only for converting this plan to
/// `NEPacketTunnelNetworkSettings`. Keeping routing and DNS decisions here
/// makes the effective full-tunnel and bypass policy directly testable. The
/// presence of an excluded route does not by itself prove runtime interface
/// selection; the signed lifecycle gate verifies that separately.
public struct PacketTunnelNetworkSettingsPlan: Equatable, Sendable {
    public struct IPv4Route: Equatable, Sendable {
        public let destinationAddress: String
        public let subnetMask: String

        public init(destinationAddress: String, subnetMask: String) {
            self.destinationAddress = destinationAddress
            self.subnetMask = subnetMask
        }
    }

    public struct IPv4Settings: Equatable, Sendable {
        public let addresses: [String]
        public let subnetMasks: [String]
        public let includedRoutes: [IPv4Route]
        public let excludedRoutes: [IPv4Route]

        public init(
            addresses: [String],
            subnetMasks: [String],
            includedRoutes: [IPv4Route],
            excludedRoutes: [IPv4Route]
        ) {
            self.addresses = addresses
            self.subnetMasks = subnetMasks
            self.includedRoutes = includedRoutes
            self.excludedRoutes = excludedRoutes
        }
    }

    public struct IPv6Route: Equatable, Sendable {
        public let destinationAddress: String
        public let prefixLength: Int

        public init(destinationAddress: String, prefixLength: Int) {
            self.destinationAddress = destinationAddress
            self.prefixLength = prefixLength
        }
    }

    public struct IPv6Settings: Equatable, Sendable {
        public let addresses: [String]
        public let prefixLengths: [Int]
        public let includedRoutes: [IPv6Route]
        public let excludedRoutes: [IPv6Route]

        public init(
            addresses: [String],
            prefixLengths: [Int],
            includedRoutes: [IPv6Route],
            excludedRoutes: [IPv6Route]
        ) {
            self.addresses = addresses
            self.prefixLengths = prefixLengths
            self.includedRoutes = includedRoutes
            self.excludedRoutes = excludedRoutes
        }
    }

    public struct DNSSettings: Equatable, Sendable {
        public let servers: [String]
        public let matchDomains: [String]

        public init(servers: [String], matchDomains: [String]) {
            self.servers = servers
            self.matchDomains = matchDomains
        }
    }

    public let tunnelRemoteAddress: String
    public let mtu: Int
    public let ipv4: IPv4Settings
    public let ipv6: IPv6Settings
    public let dns: DNSSettings

    public init(
        configuration: TunnelConfiguration,
        bypassPlan: BypassNetworkSettingsPlan
    ) {
        tunnelRemoteAddress = "127.0.0.1"
        mtu = configuration.mtu

        let customIPv4Routes = bypassPlan.ipv4Routes.map {
            IPv4Route(
                destinationAddress: $0.destinationAddress,
                subnetMask: $0.subnetMask
            )
        }
        ipv4 = IPv4Settings(
            addresses: [configuration.ipv4Address],
            subnetMasks: [configuration.ipv4SubnetMask],
            includedRoutes: [
                IPv4Route(
                    destinationAddress: "0.0.0.0",
                    subnetMask: "0.0.0.0"
                ),
            ],
            excludedRoutes: Self.uniqueIPv4Routes(
                (configuration.excludeLocalNetworks
                    ? Self.localIPv4Routes
                    : []) + customIPv4Routes
            )
        )

        let customIPv6Routes = bypassPlan.ipv6Routes.map {
            IPv6Route(
                destinationAddress: $0.destinationAddress,
                prefixLength: $0.prefixLength
            )
        }
        ipv6 = IPv6Settings(
            addresses: [configuration.ipv6Address],
            prefixLengths: [configuration.ipv6PrefixLength],
            includedRoutes: [
                IPv6Route(destinationAddress: "::", prefixLength: 0),
            ],
            excludedRoutes: Self.uniqueIPv6Routes(
                (configuration.excludeLocalNetworks
                    ? Self.localIPv6Routes
                    : []) + customIPv6Routes
            )
        )

        dns = DNSSettings(
            servers: configuration.dnsServers,
            matchDomains: [""]
        )
    }

    private static let localIPv4Routes = [
        IPv4Route(destinationAddress: "10.0.0.0", subnetMask: "255.0.0.0"),
        IPv4Route(destinationAddress: "127.0.0.0", subnetMask: "255.0.0.0"),
        IPv4Route(
            destinationAddress: "169.254.0.0",
            subnetMask: "255.255.0.0"
        ),
        IPv4Route(
            destinationAddress: "172.16.0.0",
            subnetMask: "255.240.0.0"
        ),
        IPv4Route(
            destinationAddress: "192.168.0.0",
            subnetMask: "255.255.0.0"
        ),
    ]

    private static let localIPv6Routes = [
        IPv6Route(destinationAddress: "::1", prefixLength: 128),
        IPv6Route(destinationAddress: "fc00::", prefixLength: 7),
        IPv6Route(destinationAddress: "fe80::", prefixLength: 10),
    ]

    private static func uniqueIPv4Routes(
        _ routes: [IPv4Route]
    ) -> [IPv4Route] {
        var seen = Set<String>()
        return routes.filter {
            seen.insert(
                "\($0.destinationAddress)/\($0.subnetMask)"
            ).inserted
        }
    }

    private static func uniqueIPv6Routes(
        _ routes: [IPv6Route]
    ) -> [IPv6Route] {
        var seen = Set<String>()
        return routes.filter {
            seen.insert(
                "\($0.destinationAddress)/\($0.prefixLength)"
            ).inserted
        }
    }
}

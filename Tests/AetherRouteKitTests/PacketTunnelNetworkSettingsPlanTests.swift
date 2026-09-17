import XCTest
@testable import AetherRouteKit

final class PacketTunnelNetworkSettingsPlanTests: XCTestCase {
    func testDefaultFullTunnelPlanIncludesTailscaleBypassAndSyntheticDNS() throws {
        let bypassPlan = try BypassNetworkSettingsPlan(
            policy: BypassPolicy(
                rules: [try BypassRule.parse("100.64.0.0/10")]
            )
        )

        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: TunnelConfiguration(),
            bypassPlan: bypassPlan
        )

        XCTAssertEqual(
            plan.ipv4.includedRoutes,
            [
                .init(
                    destinationAddress: "0.0.0.0",
                    subnetMask: "0.0.0.0"
                ),
            ]
        )
        XCTAssertTrue(
            plan.ipv4.excludedRoutes.contains(
                .init(
                    destinationAddress: "100.64.0.0",
                    subnetMask: "255.192.0.0"
                )
            )
        )
        XCTAssertEqual(plan.dns.servers, ["198.18.0.2"])
        XCTAssertEqual(plan.dns.matchDomains, [""])
    }

    /// An IPv4-only profile that still claimed `::/0` black-holed every flow
    /// the system's Happy Eyeballs preferred over IPv6, because the outbound
    /// had no IPv6 egress to carry it.
    func testPlanLeavesIPv6UntouchedWhenProfileDoesNotEnableIt() throws {
        let bypassPlan = try BypassNetworkSettingsPlan(policy: BypassPolicy())

        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: TunnelConfiguration(),
            bypassPlan: bypassPlan
        )

        XCTAssertNil(plan.ipv6)
    }

    func testPlanClaimsIPv6DefaultRouteOnlyWhenProfileEnablesIt() throws {
        let bypassPlan = try BypassNetworkSettingsPlan(policy: BypassPolicy())

        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: TunnelConfiguration(enableIPv6: true),
            bypassPlan: bypassPlan
        )

        XCTAssertEqual(
            plan.ipv6?.includedRoutes,
            [.init(destinationAddress: "::", prefixLength: 0)]
        )
    }

    func testPlanRetainsProviderSettingsAndDeduplicatesExcludedRoutes() throws {
        let bypassPlan = try BypassNetworkSettingsPlan(
            policy: BypassPolicy(
                rules: [
                    try BypassRule.parse("10.0.0.0/8"),
                    try BypassRule.parse("fc00::/7"),
                ]
            )
        )
        let configuration = TunnelConfiguration(
            mtu: 1_280,
            ipv4Address: "198.18.12.1",
            ipv4SubnetMask: "255.255.255.0",
            ipv6Address: "fd00:a37e:0:12::1",
            ipv6PrefixLength: 96,
            enableIPv6: true,
            dnsServers: ["198.18.0.2", "2001:db8::53"]
        )

        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: configuration,
            bypassPlan: bypassPlan
        )

        XCTAssertEqual(plan.tunnelRemoteAddress, "198.18.12.1")
        XCTAssertEqual(plan.mtu, 1_280)
        XCTAssertEqual(plan.ipv4.addresses, ["198.18.12.1"])
        XCTAssertEqual(plan.ipv4.subnetMasks, ["255.255.255.0"])
        XCTAssertEqual(plan.ipv6?.addresses, ["fd00:a37e:0:12::1"])
        XCTAssertEqual(plan.ipv6?.prefixLengths, [96])
        XCTAssertEqual(
            plan.ipv4.excludedRoutes.filter {
                $0.destinationAddress == "10.0.0.0"
                    && $0.subnetMask == "255.0.0.0"
            }.count,
            1
        )
        XCTAssertEqual(
            plan.ipv6?.excludedRoutes.filter {
                $0.destinationAddress == "fc00::" && $0.prefixLength == 7
            }.count,
            1
        )
        XCTAssertEqual(plan.dns.servers, ["198.18.0.2", "2001:db8::53"])
        XCTAssertEqual(plan.dns.matchDomains, [""])
    }

    func testPlanOmitsLocalRoutesWhenConfigurationDisablesThem() throws {
        let bypassPlan = try BypassNetworkSettingsPlan(
            policy: BypassPolicy(
                rules: [try BypassRule.parse("100.64.0.0/10")]
            )
        )

        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: TunnelConfiguration(
                enableIPv6: true,
                excludeLocalNetworks: false
            ),
            bypassPlan: bypassPlan
        )

        XCTAssertEqual(
            plan.ipv4.excludedRoutes,
            [
                .init(
                    destinationAddress: "100.64.0.0",
                    subnetMask: "255.192.0.0"
                ),
            ]
        )
        XCTAssertEqual(plan.ipv6?.excludedRoutes, [])
    }

    func testPlanNeverIncludesLoopbackInIPv6ExcludedRoutes() throws {
        let bypassPlan = try BypassNetworkSettingsPlan(policy: BypassPolicy())
        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: TunnelConfiguration(
                enableIPv6: true,
                excludeLocalNetworks: true
            ),
            bypassPlan: bypassPlan
        )
        let containsLoopback = plan.ipv6?.excludedRoutes.contains {
            $0.destinationAddress == "::1"
        } ?? false
        XCTAssertFalse(containsLoopback, "macOS NetworkExtension rejects loopback in IPv6 excluded routes")
    }
}

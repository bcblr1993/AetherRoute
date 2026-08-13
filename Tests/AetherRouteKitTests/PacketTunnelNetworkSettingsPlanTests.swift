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
        XCTAssertEqual(
            plan.ipv6.includedRoutes,
            [.init(destinationAddress: "::", prefixLength: 0)]
        )
        XCTAssertEqual(plan.dns.servers, ["198.18.0.2"])
        XCTAssertEqual(plan.dns.matchDomains, [""])
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
            dnsServers: ["198.18.0.2", "2001:db8::53"]
        )

        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: configuration,
            bypassPlan: bypassPlan
        )

        XCTAssertEqual(plan.tunnelRemoteAddress, "127.0.0.1")
        XCTAssertEqual(plan.mtu, 1_280)
        XCTAssertEqual(plan.ipv4.addresses, ["198.18.12.1"])
        XCTAssertEqual(plan.ipv4.subnetMasks, ["255.255.255.0"])
        XCTAssertEqual(plan.ipv6.addresses, ["fd00:a37e:0:12::1"])
        XCTAssertEqual(plan.ipv6.prefixLengths, [96])
        XCTAssertEqual(
            plan.ipv4.excludedRoutes.filter {
                $0.destinationAddress == "10.0.0.0"
                    && $0.subnetMask == "255.0.0.0"
            }.count,
            1
        )
        XCTAssertEqual(
            plan.ipv6.excludedRoutes.filter {
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
            configuration: TunnelConfiguration(excludeLocalNetworks: false),
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
        XCTAssertTrue(plan.ipv6.excludedRoutes.isEmpty)
    }
}

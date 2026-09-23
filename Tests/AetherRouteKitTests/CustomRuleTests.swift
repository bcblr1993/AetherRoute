import XCTest
@testable import AetherRouteKit

final class CustomRuleTests: XCTestCase {

    func testParseValidClashRules() throws {
        let rule1 = try CustomRule.parse("DOMAIN-SUFFIX,baizhiedu.xin,DIRECT")
        XCTAssertEqual(rule1.kind, .domainSuffix)
        XCTAssertEqual(rule1.value, "baizhiedu.xin")
        XCTAssertEqual(rule1.target, .direct)
        XCTAssertFalse(rule1.noResolve)
        XCTAssertEqual(rule1.toClashRuleString(), "DOMAIN-SUFFIX,baizhiedu.xin,DIRECT")

        let rule2 = try CustomRule.parse("IP-CIDR,100.64.0.0/10,DIRECT,no-resolve")
        XCTAssertEqual(rule2.kind, .ipCIDR)
        XCTAssertEqual(rule2.value, "100.64.0.0/10")
        XCTAssertEqual(rule2.target, .direct)
        XCTAssertTrue(rule2.noResolve)
        XCTAssertEqual(rule2.toClashRuleString(), "IP-CIDR,100.64.0.0/10,DIRECT,no-resolve")

        let rule3 = try CustomRule.parse("- DOMAIN-KEYWORD,google,ProxyNode")
        XCTAssertEqual(rule3.kind, .domainKeyword)
        XCTAssertEqual(rule3.value, "google")
        XCTAssertEqual(rule3.target, .proxy("ProxyNode"))
        XCTAssertFalse(rule3.noResolve)

        let rule4 = try CustomRule.parse("GEOIP,CN,DIRECT,no-resolve")
        XCTAssertEqual(rule4.kind, .geoIP)
        XCTAssertEqual(rule4.value, "CN")
        XCTAssertEqual(rule4.target, .direct)
        XCTAssertTrue(rule4.noResolve)
    }

    func testParseInvalidClashRules() {
        XCTAssertThrowsError(try CustomRule.parse("INVALID"))
        XCTAssertThrowsError(try CustomRule.parse("DOMAIN-SUFFIX,DIRECT"))
        XCTAssertThrowsError(try CustomRule.parse("UNKNOWN-KIND,example.com,DIRECT"))
        XCTAssertThrowsError(try CustomRule.parse("IP-CIDR,invalid-ip/24,DIRECT"))
        XCTAssertThrowsError(try CustomRule.parse("IP-CIDR,10.0.0.1/35,DIRECT"))
    }

    func testCustomRuleValidator() {
        XCTAssertTrue(CustomRuleValidator.validate(kind: .domain, value: "example.com", target: .direct).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .domainSuffix, value: "apple.com", target: .direct).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .domainKeyword, value: "tailscale", target: .direct).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .ipCIDR, value: "100.64.0.0/10", target: .direct).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .ipCIDR6, value: "fd00::/8", target: .direct).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .geoIP, value: "CN", target: .direct).isValid)

        // Invalid cases
        XCTAssertFalse(CustomRuleValidator.validate(kind: .domain, value: "invalid domain with space.com", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .ipCIDR, value: "10.0.0.0", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .ipCIDR, value: "999.0.0.0/24", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .geoIP, value: "CHINA", target: .direct).isValid)
    }

    func testCustomRuleStoreCRUD() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let store = CustomRuleStore(directoryURL: tempDir)

        XCTAssertEqual(try store.load(), [])

        let rule1 = CustomRule(kind: .domainSuffix, value: "baizhiedu.xin", target: .direct)
        let updated1 = try store.add(rule1)
        XCTAssertEqual(updated1.count, 1)
        XCTAssertEqual(updated1.first?.value, "baizhiedu.xin")

        let loaded = try store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, rule1.id)

        // Toggle
        let toggled = try store.toggle(id: rule1.id)
        XCTAssertFalse(toggled.first!.isEnabled)

        // Delete
        let deleted = try store.delete(id: rule1.id)
        XCTAssertTrue(deleted.isEmpty)

        try? FileManager.default.removeItem(at: tempDir)
    }

    func testCustomRulesInDomesticRoutingOptimizer() throws {
        let rawYAML = """
        mode: rule
        rules:
          - DOMAIN-SUFFIX,google.com,ProxyNode
          - MATCH,ProxyNode
        """

        let custom1 = CustomRule(kind: .domainSuffix, value: "baizhiedu.xin", target: .direct)
        let custom2 = CustomRule(kind: .ipCIDR, value: "100.64.0.0/10", target: .direct, noResolve: true)

        let optimized = DomesticRoutingOptimizer.optimizedProfile(for: rawYAML, customRules: [custom1, custom2])

        // Verify custom rules are injected
        XCTAssertTrue(optimized.contains("DOMAIN-SUFFIX,baizhiedu.xin,DIRECT"))
        XCTAssertTrue(optimized.contains("IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"))

        // Verify fake-ip-filter includes direct domain
        XCTAssertTrue(optimized.contains("*.baizhiedu.xin"))

        // Verify order: custom rule must appear before subscription rule
        let customIdx = optimized.range(of: "DOMAIN-SUFFIX,baizhiedu.xin,DIRECT")!.lowerBound
        let subIdx = optimized.range(of: "DOMAIN-SUFFIX,google.com,ProxyNode")!.lowerBound
        XCTAssertTrue(customIdx < subIdx)
    }

    func testOverlayNetworksNotExcludedInPacketTunnelNetworkSettingsPlan() {
        let plan = PacketTunnelNetworkSettingsPlan(
            configuration: TunnelConfiguration(),
            bypassPlan: try! BypassNetworkSettingsPlan(policy: BypassPolicy())
        )

        // Verifies 100.64.0.0/10 (Tailscale CGNAT) is NOT in excludedRoutes,
        // preventing Darwin kernel static gateway route hijack to the physical router.
        XCTAssertFalse(plan.ipv4.excludedRoutes.contains {
            $0.destinationAddress == "100.64.0.0"
        })

        // Standard RFC 1918 LAN routes must still be excluded
        XCTAssertTrue(plan.ipv4.excludedRoutes.contains {
            $0.destinationAddress == "10.0.0.0" && $0.subnetMask == "255.0.0.0"
        })
        XCTAssertTrue(plan.ipv4.excludedRoutes.contains {
            $0.destinationAddress == "192.168.0.0" && $0.subnetMask == "255.255.0.0"
        })
        XCTAssertTrue(plan.ipv4.excludedRoutes.contains {
            $0.destinationAddress == "172.16.0.0" && $0.subnetMask == "255.240.0.0"
        })
    }
}

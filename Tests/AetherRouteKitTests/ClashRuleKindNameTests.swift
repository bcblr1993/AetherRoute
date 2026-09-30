import AetherRouteKit
import XCTest

final class ClashRuleKindNameTests: XCTestCase {
    func testEngineNamesUseConfigurationSpelling() {
        XCTAssertEqual(ClashRuleKindName.display("DomainSuffix"), "DOMAIN-SUFFIX")
        XCTAssertEqual(ClashRuleKindName.display("IPCIDR"), "IP-CIDR")
        XCTAssertEqual(ClashRuleKindName.display("IPCIDR6"), "IP-CIDR6")
        XCTAssertEqual(ClashRuleKindName.display("GeoIP"), "GEOIP")
        XCTAssertEqual(ClashRuleKindName.display("Match"), "MATCH")
        XCTAssertEqual(ClashRuleKindName.display("RuleSet"), "RULE-SET")
    }

    func testConfigurationSpellingIsStable() {
        XCTAssertEqual(ClashRuleKindName.display("DOMAIN-SUFFIX"), "DOMAIN-SUFFIX")
        XCTAssertEqual(ClashRuleKindName.display("IP-CIDR"), "IP-CIDR")
    }

    func testUnknownNamesPassThrough() {
        XCTAssertEqual(ClashRuleKindName.display("Script"), "Script")
        XCTAssertEqual(ClashRuleKindName.display(""), "")
    }
}

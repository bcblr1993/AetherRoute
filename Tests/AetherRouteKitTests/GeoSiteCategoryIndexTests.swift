import XCTest
@testable import AetherRouteKit

final class GeoSiteCategoryIndexTests: XCTestCase {
    func testReadsCategoryCodesAndSkipsOtherFields() throws {
        // GeoSiteList { entry { country_code "CN"; domain {...}; fixed64 } entry { "OPENAI" } }
        // plus an unknown varint field at the top level.
        let cn: [UInt8] = [0x0A, 0x02] + Array("CN".utf8)
            + [0x12, 0x03, 0x08, 0x01, 0x00]                    // domain (len 3)
            + [0x19] + [UInt8](repeating: 0, count: 8)         // field 3, fixed64
        let openAI: [UInt8] = [0x0A, 0x06] + Array("OPENAI".utf8)
        let bytes: [UInt8] = [0x0A, UInt8(cn.count)] + cn
            + [0x10, 0x96, 0x01]                                // field 2 varint 150
            + [0x0A, UInt8(openAI.count)] + openAI
        let index = try GeoSiteCategoryIndex(data: Data(bytes))
        XCTAssertEqual(index.codes, ["cn", "openai"])
    }

    func testRejectsTruncatedOrEmptyDatabases() {
        for bytes: [UInt8] in [[], [0x0A, 0x10, 0x0A], [0x0A, 0x02, 0x0A, 0x7F], [0x0F]] {
            XCTAssertThrowsError(try GeoSiteCategoryIndex(data: Data(bytes)), "\(bytes)")
        }
    }

    func testRuleValuesAreParsedAsTheCoreParsesThem() {
        let index = GeoSiteCategoryIndex(codes: ["CN", "category-ai-!cn", "geolocation-!cn"])
        XCTAssertTrue(index.contains(ruleValue: "cn"))
        XCTAssertTrue(index.contains(ruleValue: " CN "))
        XCTAssertTrue(index.contains(ruleValue: "!cn"))           // negation
        XCTAssertTrue(index.contains(ruleValue: "cn@ads"))        // attribute filter
        XCTAssertTrue(index.contains(ruleValue: "category-ai-!cn"))
        XCTAssertFalse(index.contains(ruleValue: "youtub"))
        XCTAssertEqual(GeoSiteCategoryIndex.categoryCode(of: "!Geolocation-!CN@cn"), "geolocation-!cn")
    }

    func testUnknownCategoriesListsOnlyEnabledGeoSiteRules() {
        let index = GeoSiteCategoryIndex(codes: ["cn"])
        var disabled = CustomRule(kind: .geoSite, value: "missing-two", target: .direct)
        disabled.isEnabled = false
        let rules = [
            CustomRule(kind: .geoSite, value: "cn", target: .direct),
            CustomRule(kind: .geoSite, value: "youtub", target: .proxy("Media")),
            CustomRule(kind: .domainSuffix, value: "youtub", target: .direct),
            disabled,
        ]
        XCTAssertEqual(index.unknownCategories(in: rules), ["youtub"])
    }

    func testBundledDatabaseListsTheCategoriesTheEditorSuggests() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/RoutingResources/GeoSite.dat")
        let index = try GeoSiteCategoryIndex(data: Data(contentsOf: url))
        XCTAssertGreaterThan(index.codes.count, 1_000)
        // The editor's own examples must exist, or its hint would mislead.
        for example in ["cn", "apple", "openai", "youtube", "category-ai-!cn", "netflix"] {
            XCTAssertTrue(index.contains(ruleValue: example), example)
        }
    }
}

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

    func testMatchesDomainAgainstPlainRegexSuffixFullAttributeAndNegation() {
        let data = Self.syntheticGeoSiteDatabase()

        // Domain (type 2: root/suffix) "baidu.com" with attribute "ads" on "ad.baidu.com"
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "baidu.com", ruleValue: "cn", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "www.baidu.com", ruleValue: "cn", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "notbaidu.com", ruleValue: "cn", in: data), false)

        // Full (type 3: exact) "exact.cn.example"
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "exact.cn.example", ruleValue: "cn", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "sub.exact.cn.example", ruleValue: "cn", in: data), false)

        // Plain (type 0: keyword) "cn-keyword"
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "my-cn-keyword-host.org", ruleValue: "cn", in: data), true)

        // Regex (type 1: regex) "^api-[0-9]+\\.example\\.com$"
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "api-42.example.com", ruleValue: "cn", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "api-abc.example.com", ruleValue: "cn", in: data), false)

        // Attribute filter (@ads)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "ad.baidu.com", ruleValue: "cn@ads", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "www.baidu.com", ruleValue: "cn@ads", in: data), false)

        // Negation (!cn)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "www.baidu.com", ruleValue: "!cn", in: data), false)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "openai.com", ruleValue: "!cn", in: data), true)

        // Unknown category returns nil (indeterminate)
        XCTAssertNil(GeoSiteCategoryIndex.matches(domain: "example.com", ruleValue: "nonexistent-category", in: data))
    }

    func testMatchesDomainInBundledGeoSiteDatabase() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/RoutingResources/GeoSite.dat")
        let data = try Data(contentsOf: url)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "www.apple.com", ruleValue: "apple", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "www.baidu.com", ruleValue: "cn", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "api.openai.com", ruleValue: "openai", in: data), true)
        XCTAssertEqual(GeoSiteCategoryIndex.matches(domain: "www.baidu.com", ruleValue: "openai", in: data), false)
    }

    private static func syntheticGeoSiteDatabase() -> Data {
        func protoString(field: UInt8, _ text: String) -> [UInt8] {
            let utf8 = Array(text.utf8)
            return [(field << 3) | 2, UInt8(utf8.count)] + utf8
        }
        func protoDomain(type: UInt8, value: String, attribute: String? = nil) -> [UInt8] {
            var body: [UInt8] = [0x08, type] + protoString(field: 2, value)
            if let attribute {
                let attrBody = protoString(field: 1, attribute)
                body += [0x1A, UInt8(attrBody.count)] + attrBody
            }
            return [0x12, UInt8(body.count)] + body
        }
        let entryBody: [UInt8] = protoString(field: 1, "CN")
            + protoDomain(type: 2, value: "baidu.com")
            + protoDomain(type: 2, value: "ad.baidu.com", attribute: "ads")
            + protoDomain(type: 3, value: "exact.cn.example")
            + protoDomain(type: 0, value: "cn-keyword")
            + protoDomain(type: 1, value: "^api-[0-9]+\\.example\\.com$")
        return Data([0x0A, UInt8(entryBody.count)] + entryBody)
    }
}

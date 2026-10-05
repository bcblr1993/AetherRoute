@testable import AetherRouteKit
import Foundation
import XCTest

final class ApplicationRuleTests: XCTestCase {
    func testApplicationRuleEncodesThePathSoCommasCannotSplitIt() throws {
        let rule = try XCTUnwrap(CustomRule.application(
            bundleIdentifier: "com.example.Tool",
            bundlePath: "/Applications/A, B; C%.app",
            displayName: "A, B",
            target: .proxy("Proxy")
        ))
        XCTAssertEqual(
            rule.toClashRuleString(),
            "AETHER-APP,com.example.Tool;/Applications/A%2C%20B%3B%20C%25.app,Proxy"
        )
        XCTAssertEqual(rule.comment, "A, B")
        XCTAssertEqual(rule.applicationMatch?.bundleIdentifier, "com.example.Tool")
        XCTAssertEqual(rule.applicationMatch?.bundlePath, "/Applications/A, B; C%.app")
    }

    func testApplicationRuleNeedsAUsableIdentifierOrPath() {
        XCTAssertNil(CustomRule.application(
            bundleIdentifier: nil, bundlePath: nil, displayName: "x", target: .direct
        ))
        XCTAssertNil(CustomRule.application(
            bundleIdentifier: "bad id", bundlePath: nil, displayName: "x", target: .direct
        ))
        XCTAssertNil(CustomRule.application(
            bundleIdentifier: nil, bundlePath: "relative.app", displayName: "x", target: .direct
        ))
        XCTAssertNotNil(CustomRule.application(
            bundleIdentifier: nil, bundlePath: "/usr/bin/curl", displayName: "curl", target: .reject
        ))
        XCTAssertNotNil(CustomRule.application(
            bundleIdentifier: "com.apple.WebKit.Networking", bundlePath: nil,
            displayName: "Safari", target: .direct
        ))
    }

    func testRuleTextCannotCreateAnApplicationRule() {
        XCTAssertThrowsError(try CustomRule.parse("AETHER-APP,com.example;,DIRECT"))
        XCTAssertFalse(CustomRuleKind.editableKinds.contains(.application))
    }

    func testStoredApplicationRulesRoundTrip() throws {
        let rule = try XCTUnwrap(CustomRule.application(
            bundleIdentifier: "com.example", bundlePath: "/Applications/Example.app",
            displayName: "Example", target: .direct
        ))
        let data = try JSONEncoder().encode(rule)
        XCTAssertEqual(try JSONDecoder().decode(CustomRule.self, from: data), rule)
    }

    func testApplicationRulesComeFirstAndProfileCopiesAreDropped() throws {
        let domain = CustomRule(kind: .domainSuffix, value: "example.com", target: .proxy("Proxy"))
        let app = try XCTUnwrap(CustomRule.application(
            bundleIdentifier: "com.example", bundlePath: nil,
            displayName: "Example", target: .direct
        ))
        let profile = """
        proxies:
          - {name: Proxy, type: ss, server: 1.2.3.4, port: 1, cipher: aes-128-gcm, password: p}
        rules:
          - AETHER-APP,com.attacker;,DIRECT
          - MATCH,Proxy
        """
        let output = DomesticRoutingOptimizer.optimizedProfile(
            for: profile,
            customRules: [domain, app]
        )
        let rules = output.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") && ($0.contains(",") ) }
            .map { String($0.dropFirst(2)).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
        let appIndex = try XCTUnwrap(rules.firstIndex { $0.hasPrefix("AETHER-APP,com.example;") })
        let domainIndex = try XCTUnwrap(rules.firstIndex { $0.hasPrefix("DOMAIN-SUFFIX,example.com") })
        XCTAssertLessThan(appIndex, domainIndex)
        XCTAssertFalse(output.contains("com.attacker"))
    }

    func testImportRejectsTheReservedRuleButNotLookalikeNames() {
        let reserved = Data("""
        proxies:
          - {name: A, type: ss, server: 1.2.3.4, port: 1, cipher: aes-128-gcm, password: p}
        rules:
          - AETHER-APP,com.example;,DIRECT
        """.utf8)
        XCTAssertThrowsError(try ProfileImportValidator.validate(data: reserved)) {
            XCTAssertEqual($0 as? ProfileImportError, .reservedRule("AETHER-APP"))
        }
        let lookalike = Data("""
        proxies:
          - {name: Aether-Apple, type: ss, server: 1.2.3.4, port: 1, cipher: aes-128-gcm, password: p}
        rules:
          - MATCH,Aether-Apple
        """.utf8)
        XCTAssertNoThrow(try ProfileImportValidator.validate(data: lookalike))
    }

    func testRouteTesterSkipsApplicationRules() {
        let rules = [
            RuleConfigurationSummary(
                id: 0, order: 1, kind: "AETHER-APP",
                criteria: "com.example;", target: "DIRECT", isCustom: true
            ),
            RuleConfigurationSummary(
                id: 1, order: 2, kind: "MATCH",
                criteria: nil, target: "Proxy", isCustom: false
            ),
        ]
        guard case let .matched(result) = RouteMatchEngine.assess(
            destination: "example.com",
            against: rules
        ) else { return XCTFail("expected a match") }
        XCTAssertEqual(result.target, "Proxy")
    }
}

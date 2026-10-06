import Foundation
import XCTest
@testable import AetherRouteKit

final class RuleProviderEngineTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RuleProviderEngineTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testRejectsInsecureHTTPURL() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let insecure = RuleProviderMetadata(
            name: "Insecure",
            url: URL(string: "http://example.com/rules.txt")!
        )
        do {
            try await engine.registerProvider(insecure)
            XCTFail("Must reject insecure HTTP")
        } catch let error as RuleProviderError {
            XCTAssertEqual(error, .insecureScheme)
        }
    }

    func testParsesDomainTextFormat() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let content = """
        # Comments should be ignored
        // Another comment
        apple.com
        - 'google.com'
        - "DOMAIN,github.com,PROXY"
        """
        let rules = await engine.parseRawRuleContent(content, behavior: .domain, format: .text)
        XCTAssertEqual(rules.count, 3)
        XCTAssertEqual(rules[0].type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rules[0].payload, "apple.com")
        XCTAssertEqual(rules[1].type, "DOMAIN-SUFFIX")
        XCTAssertEqual(rules[1].payload, "google.com")
        XCTAssertEqual(rules[2].type, "DOMAIN")
        XCTAssertEqual(rules[2].payload, "github.com")
        XCTAssertEqual(rules[2].target, "PROXY")
    }

    func testParsesIPCIDRYAMLFormat() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let content = """
        payload:
          - 192.168.1.0/24
          - '10.0.0.0/8,DIRECT,no-resolve'
        """
        let rules = await engine.parseRawRuleContent(content, behavior: .ipcidr, format: .yaml)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].type, "IP-CIDR")
        XCTAssertEqual(rules[0].payload, "192.168.1.0/24")
        XCTAssertFalse(rules[0].noResolve)

        XCTAssertEqual(rules[1].type, "IP-CIDR")
        XCTAssertEqual(rules[1].payload, "10.0.0.0/8")
        XCTAssertEqual(rules[1].target, "DIRECT")
        XCTAssertTrue(rules[1].noResolve)
    }

    func testParsesClassicalFormat() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let content = """
        - DOMAIN-KEYWORD,openai,AI-Group
        - IP-CIDR,1.1.1.1/32,DNS-Group,no-resolve
        """
        let rules = await engine.parseRawRuleContent(content, behavior: .classical, format: .yaml)
        XCTAssertEqual(rules.count, 2)
        XCTAssertEqual(rules[0].type, "DOMAIN-KEYWORD")
        XCTAssertEqual(rules[0].payload, "openai")
        XCTAssertEqual(rules[0].target, "AI-Group")

        XCTAssertEqual(rules[1].type, "IP-CIDR")
        XCTAssertEqual(rules[1].payload, "1.1.1.1/32")
        XCTAssertEqual(rules[1].target, "DNS-Group")
        XCTAssertTrue(rules[1].noResolve)
    }

    func testProviderPersistenceAndRemoval() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let id = UUID()
        let metadata = RuleProviderMetadata(
            id: id,
            name: "Test Rule",
            url: URL(string: "https://example.com/rules.txt")!
        )
        try await engine.registerProvider(metadata)
        let loaded = await engine.provider(id: id)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.name, "Test Rule")

        await engine.removeProvider(id: id)
        let empty = await engine.provider(id: id)
        XCTAssertNil(empty)
    }

    func testToggleProvider() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let id = UUID()
        let metadata = RuleProviderMetadata(
            id: id,
            name: "Toggle Test",
            url: URL(string: "https://example.com/toggle.txt")!,
            isEnabled: true
        )
        try await engine.registerProvider(metadata)
        var current = await engine.provider(id: id)
        XCTAssertTrue(current?.isEnabled ?? false)

        let toggledState = await engine.toggleProvider(id: id)
        XCTAssertFalse(toggledState)
        current = await engine.provider(id: id)
        XCTAssertFalse(current?.isEnabled ?? true)
    }

    func testCompileActiveRulesWithTargetAndSafetyBudget() async throws {
        let engine = RuleProviderEngine(directoryURL: tempDir)
        let id = UUID()
        let metadata = RuleProviderMetadata(
            id: id,
            name: "AdBlock",
            url: URL(string: "https://example.com/adblock.txt")!,
            behavior: .domain,
            format: .text,
            defaultTarget: "REJECT",
            isEnabled: true
        )
        try await engine.registerProvider(metadata)

        // Write simulated cached content
        let cacheFile = tempDir.appendingPathComponent("\(id.uuidString).dat")
        let testRules = """
        adservice.google.com
        adsystem.facebook.com
        doubleclick.net
        """
        try testRules.data(using: .utf8)!.write(to: cacheFile)

        let compiled = await engine.compileActiveRules(maxRulesPerProvider: 2, maxTotalRules: 10)
        XCTAssertEqual(compiled.count, 2) // Budget limited to 2
        XCTAssertEqual(compiled[0], "DOMAIN-SUFFIX,adservice.google.com,REJECT")
        XCTAssertEqual(compiled[1], "DOMAIN-SUFFIX,adsystem.facebook.com,REJECT")
    }

    func testDomesticRoutingOptimizerWithRemoteRules() {
        let inputYAML = """
        port: 7890
        rules:
          - DOMAIN-SUFFIX,example.com,DIRECT
          - MATCH,PROXY
        """
        let remoteRules = [
            "DOMAIN-SUFFIX,adservice.google.com,REJECT",
            "DOMAIN,openai.com,AI-Group"
        ]
        let customRules = [
            CustomRule(
                kind: .domain,
                value: "special.internal",
                target: .direct
            )
        ]
        let enhanced = DomesticRoutingOptimizer.optimizedProfile(
            for: inputYAML,
            customRules: customRules,
            remoteRules: remoteRules
        )

        XCTAssertTrue(enhanced.contains("rules:"))
        XCTAssertTrue(enhanced.contains("- DOMAIN,special.internal,DIRECT"))
        XCTAssertTrue(enhanced.contains("- DOMAIN-SUFFIX,adservice.google.com,REJECT"))
        XCTAssertTrue(enhanced.contains("- DOMAIN,openai.com,AI-Group"))

        // Priority order: customRules -> remoteRules -> highPriorityBypass -> original rules
        let customRange = enhanced.range(of: "DOMAIN,special.internal,DIRECT")!
        let remoteRange = enhanced.range(of: "DOMAIN-SUFFIX,adservice.google.com,REJECT")!
        let bypassRange = enhanced.range(of: "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve")!
        let originalRange = enhanced.range(of: "DOMAIN-SUFFIX,example.com,DIRECT")!

        XCTAssertTrue(customRange.lowerBound < remoteRange.lowerBound)
        XCTAssertTrue(remoteRange.lowerBound < bypassRange.lowerBound)
        XCTAssertTrue(bypassRange.lowerBound < originalRange.lowerBound)
    }

    func testCloudSyncExportAndMerge() async throws {
        let engine1 = RuleProviderEngine(directoryURL: tempDir.appendingPathComponent("engine1"))
        let engine2 = RuleProviderEngine(directoryURL: tempDir.appendingPathComponent("engine2"))

        let provider = RuleProviderMetadata(
            name: "Cloud Rule",
            url: URL(string: "https://example.com/cloud.txt")!,
            behavior: .domain,
            format: .text,
            defaultTarget: "REJECT",
            isEnabled: true
        )
        try await engine1.registerProvider(provider)

        guard let payloadData = await engine1.exportCloudSyncPayload(deviceIdentifier: "device-1") else {
            XCTFail("Must export payload data")
            return
        }

        let merged = await engine2.mergeCloudSyncPayload(payloadData)
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged.first?.name, "Cloud Rule")
        XCTAssertEqual(merged.first?.defaultTarget, "REJECT")
        XCTAssertTrue(merged.first?.isEnabled ?? false)
    }
}

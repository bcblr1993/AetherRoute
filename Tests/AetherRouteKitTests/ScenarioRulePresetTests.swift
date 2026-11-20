import AetherRouteKit
import Foundation
import XCTest

final class ScenarioRulePresetTests: XCTestCase {
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ScenarioRulePresetTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testDefaultStatesAreAllDisabledAndCanonicalOrder() {
        let defaults = ScenarioRulePresetState.defaultStates()
        XCTAssertEqual(
            defaults.map(\.id),
            [.aiDeveloperSuite, .developerAccelerator, .adAndTrackerBlock, .domesticAndLANBoost]
        )
        XCTAssertTrue(defaults.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(defaults[0].target, .primaryProxy)
        XCTAssertEqual(defaults[1].target, .primaryProxy)
        XCTAssertEqual(defaults[2].target, .reject)
        XCTAssertEqual(defaults[3].target, .direct)

        let compiled = ScenarioRulePresetCompiler.compileRules(
            states: defaults,
            availableGroups: ["Proxy", "Auto"]
        )
        XCTAssertEqual(compiled, [])
    }

    func testStorePersistenceRoundTripAndCorruptFallback() throws {
        let store = ScenarioRulePresetStore(directoryURL: tempDirectory)
        let initial = store.load()
        XCTAssertTrue(initial.allSatisfy { !$0.isEnabled })

        let afterEnable = try store.setEnabled(true, for: .aiDeveloperSuite)
        XCTAssertTrue(afterEnable.first(where: { $0.id == .aiDeveloperSuite })?.isEnabled == true)

        let afterTarget = try store.setTarget(.group("US Nodes"), for: .aiDeveloperSuite)
        XCTAssertEqual(
            afterTarget.first(where: { $0.id == .aiDeveloperSuite })?.target,
            .group("US Nodes")
        )

        let afterDisable = try store.setEnabled(false, for: .aiDeveloperSuite)
        XCTAssertEqual(afterDisable.first(where: { $0.id == .aiDeveloperSuite })?.isEnabled, false)
        XCTAssertEqual(
            afterDisable.first(where: { $0.id == .aiDeveloperSuite })?.target,
            .group("US Nodes")
        )

        // Fresh store instance reads persisted JSON cleanly.
        let reloaded = ScenarioRulePresetStore(directoryURL: tempDirectory).load()
        XCTAssertEqual(reloaded, afterDisable)

        // Corrupt JSON falls back safely to all-disabled defaults.
        try Data("not-json".utf8).write(to: store.fileURL, options: .atomic)
        let recovered = ScenarioRulePresetStore(directoryURL: tempDirectory).load()
        XCTAssertEqual(recovered, ScenarioRulePresetState.defaultStates())
    }

    func testDeterministicRuleEmissionForAllFourPresets() {
        let states = ScenarioRulePresetID.allCases.map { id in
            ScenarioRulePresetState(id: id, isEnabled: true, target: id.defaultTarget)
        }
        let rules = ScenarioRulePresetCompiler.compileRules(
            states: states,
            availableGroups: ["🚀 节点选择", "♻️ 自动选择"]
        )

        XCTAssertEqual(
            rules,
            [
                // AI Developer Suite
                "GEOSITE,openai,🚀 节点选择",
                "GEOSITE,anthropic,🚀 节点选择",
                "GEOSITE,google-gemini,🚀 节点选择",
                "DOMAIN-SUFFIX,cursor.sh,🚀 节点选择",
                "DOMAIN-SUFFIX,cursor.com,🚀 节点选择",
                "DOMAIN-SUFFIX,perplexity.ai,🚀 节点选择",
                "DOMAIN-SUFFIX,claude.ai,🚀 节点选择",
                // Developer Accelerator
                "GEOSITE,github,🚀 节点选择",
                "DOMAIN-SUFFIX,docker.io,🚀 节点选择",
                "DOMAIN-SUFFIX,ghcr.io,🚀 节点选择",
                "DOMAIN-SUFFIX,npmjs.org,🚀 节点选择",
                "DOMAIN-SUFFIX,pypi.org,🚀 节点选择",
                "DOMAIN-SUFFIX,crates.io,🚀 节点选择",
                "DOMAIN-SUFFIX,brew.sh,🚀 节点选择",
                // Ad & Tracker Blocking
                "GEOSITE,category-ads-all,REJECT",
                "DOMAIN-SUFFIX,doubleclick.net,REJECT",
                "DOMAIN-SUFFIX,googlesyndication.com,REJECT",
                // Domestic & LAN Direct
                "GEOSITE,cn,DIRECT",
                "GEOIP,private,DIRECT,no-resolve",
                "GEOIP,cn,DIRECT,no-resolve",
            ]
        )

        // Order of input states does not alter deterministic output order.
        let reversedRules = ScenarioRulePresetCompiler.compileRules(
            states: states.reversed(),
            availableGroups: ["🚀 节点选择", "♻️ 自动选择"]
        )
        XCTAssertEqual(reversedRules, rules)
    }

    func testTargetSwitchingAndMissingGroupFallback() {
        let aiState = ScenarioRulePresetState(
            id: .aiDeveloperSuite,
            isEnabled: true,
            target: .group("🇺🇸 US AI")
        )
        let adState = ScenarioRulePresetState(
            id: .adAndTrackerBlock,
            isEnabled: true,
            target: .group("MissingGroup")
        )
        let cnState = ScenarioRulePresetState(
            id: .domesticAndLANBoost,
            isEnabled: true,
            target: .group("MissingGroup")
        )

        // When target group exists, it is used verbatim.
        let matched = ScenarioRulePresetCompiler.compileRules(
            states: [aiState],
            availableGroups: ["Proxy", "🇺🇸 US AI"]
        )
        XCTAssertTrue(matched.allSatisfy { $0.hasSuffix(",🇺🇸 US AI") })

        // When target group is missing, each preset falls back cleanly to its default target.
        let fallback = ScenarioRulePresetCompiler.compileRules(
            states: [aiState, adState, cnState],
            availableGroups: ["Proxy", "Fallback"]
        )
        XCTAssertEqual(fallback.first, "GEOSITE,openai,Proxy")
        XCTAssertTrue(fallback.contains("GEOSITE,category-ads-all,REJECT"))
        XCTAssertTrue(fallback.contains("GEOSITE,cn,DIRECT"))
        XCTAssertTrue(fallback.contains("GEOIP,private,DIRECT,no-resolve"))

        // When no proxy groups exist at all, primaryProxy falls back to first proxy node or DIRECT.
        let proxyOnly = ScenarioRulePresetCompiler.compileRules(
            states: [ScenarioRulePresetState(id: .developerAccelerator, isEnabled: true, target: .primaryProxy)],
            availableGroups: [],
            availableProxies: ["Node-A"]
        )
        XCTAssertEqual(proxyOnly.first, "GEOSITE,github,Node-A")

        let noProxiesAtAll = ScenarioRulePresetCompiler.compileRules(
            states: [ScenarioRulePresetState(id: .developerAccelerator, isEnabled: true, target: .primaryProxy)],
            availableGroups: [],
            availableProxies: []
        )
        XCTAssertEqual(noProxiesAtAll.first, "GEOSITE,github,DIRECT")
    }

    func testAllBuiltInGeoSiteCategoriesExistInBundledGeoSiteDatabase() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let geoSiteURL = repoRoot.appendingPathComponent("Config/RoutingResources/GeoSite.dat")
        let data = try Data(contentsOf: geoSiteURL)
        let index = try GeoSiteCategoryIndex(data: data)

        let missing = ScenarioRulePresetCompiler.validateGeoSiteCategories(against: index)
        XCTAssertEqual(missing, [], "Built-in scenario presets reference GEOSITE categories missing from GeoSite.dat: \(missing)")

        // Negative check: synthetic incomplete index must report missing categories.
        let partialIndex = GeoSiteCategoryIndex(codes: ["cn"])
        let missingFromPartial = ScenarioRulePresetCompiler.validateGeoSiteCategories(against: partialIndex)
        XCTAssertTrue(missingFromPartial.contains("openai"))
        XCTAssertTrue(missingFromPartial.contains("anthropic"))
        XCTAssertTrue(missingFromPartial.contains("google-gemini"))
        XCTAssertTrue(missingFromPartial.contains("github"))
        XCTAssertTrue(missingFromPartial.contains("category-ads-all"))
        XCTAssertFalse(missingFromPartial.contains("cn"))
    }

    func testProfileOverrideCompilerIntegrationPrependsAndDeduplicates() {
        let baseYAML = """
        proxies:
          - {name: "HK-1", type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: secret}
        proxy-groups:
          - {name: "Proxy", type: select, proxies: ["HK-1"]}
          - {name: "AI Group", type: select, proxies: ["HK-1"]}
        rules:
          - GEOSITE,cn,DIRECT
          - MATCH,Proxy
        """

        // All disabled: YAML stays byte-for-byte identical.
        let disabledGlobal = ProfileOverride(scenarioPresets: ScenarioRulePresetState.defaultStates())
        let untouched = ProfileOverrideCompiler.apply(nil, globalOverride: disabledGlobal, to: baseYAML)
        XCTAssertEqual(untouched.yaml, baseYAML)

        // Enable AI Suite (custom target "AI Group") + Domestic & LAN Direct.
        let enabledStates = [
            ScenarioRulePresetState(id: .aiDeveloperSuite, isEnabled: true, target: .group("AI Group")),
            ScenarioRulePresetState(id: .domesticAndLANBoost, isEnabled: true, target: .direct),
        ]
        let globalOverride = ProfileOverride(scenarioPresets: enabledStates)
        let compiled = ProfileOverrideCompiler.apply(nil, globalOverride: globalOverride, to: baseYAML)

        XCTAssertNotEqual(compiled.yaml, baseYAML)
        XCTAssertEqual(compiled.diagnostics, [])

        let lines = compiled.yaml.components(separatedBy: "\n")
        guard let rulesIdx = lines.firstIndex(of: "rules:") else {
            return XCTFail("Missing rules section")
        }
        let ruleLines = lines[(rulesIdx + 1)...].map { $0.trimmingCharacters(in: .whitespaces) }

        // Preset rules are prepended ahead of existing profile rules.
        XCTAssertEqual(ruleLines.first, "- GEOSITE,openai,AI Group")
        XCTAssertTrue(ruleLines.contains("- DOMAIN-SUFFIX,cursor.sh,AI Group"))
        XCTAssertTrue(ruleLines.contains("- GEOIP,private,DIRECT,no-resolve"))
        XCTAssertTrue(ruleLines.contains("- GEOIP,cn,DIRECT,no-resolve"))

        // Existing GEOSITE,cn,DIRECT is deduplicated (appears only once).
        let cnCount = ruleLines.filter { $0.uppercased() == "- GEOSITE,CN,DIRECT" }.count
        XCTAssertEqual(cnCount, 1)

        // MATCH,Proxy stays at the bottom.
        XCTAssertEqual(ruleLines.last, "- MATCH,Proxy")
    }

    func testProfileOverrideCompilerExplicitPresetsAndShadowing() {
        let baseYAML = """
        proxies:
          - {name: "JP-1", type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: secret}
        proxy-groups:
          - {name: "MainProxy", type: select, proxies: ["JP-1"]}
        rules:
          - MATCH,MainProxy
        """

        // Global enables ad blocking, explicit parameter disables it and enables developer accelerator.
        let globalOverride = ProfileOverride(scenarioPresets: [
            ScenarioRulePresetState(id: .adAndTrackerBlock, isEnabled: true, target: .reject),
        ])
        let explicit = [
            ScenarioRulePresetState(id: .adAndTrackerBlock, isEnabled: false, target: .reject),
            ScenarioRulePresetState(id: .developerAccelerator, isEnabled: true, target: .primaryProxy),
        ]
        let result = ProfileOverrideCompiler.apply(
            nil,
            globalOverride: globalOverride,
            scenarioPresets: explicit,
            to: baseYAML
        )
        XCTAssertFalse(result.yaml.contains("GEOSITE,category-ads-all"))
        XCTAssertTrue(result.yaml.contains("- GEOSITE,github,MainProxy"))
        XCTAssertTrue(result.yaml.contains("- DOMAIN-SUFFIX,crates.io,MainProxy"))
    }

    func testProfileOverrideCodableBackwardCompatibility() throws {
        let legacyJSON = """
        {
          "formatVersion": 1,
          "groups": [],
          "hiddenNodeKeywords": ["expire"]
        }
        """
        let decoded = try JSONDecoder().decode(ProfileOverride.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.hiddenNodeKeywords, ["expire"])
        XCTAssertEqual(decoded.scenarioPresets, [])

        var withPresets = decoded
        withPresets.scenarioPresets = [
            ScenarioRulePresetState(id: .aiDeveloperSuite, isEnabled: true, target: .primaryProxy),
        ]
        let encoded = try JSONEncoder().encode(withPresets)
        let roundTripped = try JSONDecoder().decode(ProfileOverride.self, from: encoded)
        XCTAssertEqual(roundTripped, withPresets)
    }
}

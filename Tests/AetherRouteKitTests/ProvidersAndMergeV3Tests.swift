import Foundation
import XCTest
@testable import AetherRouteKit

final class ProvidersAndMergeV3Tests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ProvidersAndMergeV3Tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - P0-1: Native .mrs Binary Rulesets & >2500 Rule Staging

    func testRuleProviderFormatSupportsMRS() throws {
        XCTAssertEqual(RuleProviderFormat.mrs.rawValue, "mrs")
        let metadata = RuleProviderMetadata(
            name: "geosite-ads",
            url: URL(string: "https://example.com/geosite-ads.mrs")!,
            format: .mrs
        )
        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(RuleProviderMetadata.self, from: data)
        XCTAssertEqual(decoded.format, .mrs)
    }

    func testMRSProviderStoresAndStagesRawBinaryBytesWithoutUTF8Decoding() async throws {
        let storageDir = tempDir.appendingPathComponent("RuleProviders", isDirectory: true)
        let binaryPayload = Data([0x4D, 0x52, 0x53, 0x01, 0xFF, 0xFE, 0x00, 0x80, 0xC3, 0x28, 0xDE, 0xAD, 0xBE, 0xEF])
        let url = URL(string: "https://rules.example.com/geosite-cn.mrs")!

        let engine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                XCTAssertEqual(requestURL, url)
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (binaryPayload, response)
            }
        )

        let provider = RuleProviderMetadata(name: "geosite-cn", url: url, format: .mrs)
        try await engine.registerProvider(provider)
        _ = try await engine.forceRefresh(id: provider.id)

        let raw = await engine.loadRawData(for: provider.id)
        XCTAssertEqual(raw, binaryPayload)

        let rules = try await engine.loadRules(for: provider.id)
        XCTAssertTrue(rules.isEmpty)

        let stagedURL = tempDir.appendingPathComponent("providers/rules/geosite-cn.mrs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
        XCTAssertEqual(try Data(contentsOf: stagedURL), binaryPayload)

        let tunStagedURL = tempDir.appendingPathComponent("Runtime/providers/rules/geosite-cn.mrs")
        let flowStagedURL = tempDir.appendingPathComponent("Runtime/FlowCore/providers/rules/geosite-cn.mrs")
        XCTAssertEqual(try Data(contentsOf: tunStagedURL), binaryPayload)
        XCTAssertEqual(try Data(contentsOf: flowStagedURL), binaryPayload)
    }

    func testLargeRuleProvidersStageBeyond2500RulesAndRewriteHTTPToFileInBothModes() async throws {
        let storageDir = tempDir.appendingPathComponent("RuleProviders", isDirectory: true)

        var yamlLines = ["payload:"]
        for i in 0..<3200 {
            yamlLines.append("  - 'DOMAIN-SUFFIX,domain-\(i).example.com'")
        }
        let largeYAMLData = Data(yamlLines.joined(separator: "\n").utf8)

        var txtLines: [String] = []
        for i in 0..<2800 {
            let a = (i / 250) + 1
            let b = i % 250
            txtLines.append("10.\(a).\(b).0/24")
        }
        let largeTXTData = Data(txtLines.joined(separator: "\n").utf8)
        let mrsData = Data([0x4D, 0x52, 0x53, 0x02, 0xFF, 0x00, 0x99])

        let engine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                switch requestURL.lastPathComponent {
                case "classical-large.yaml":
                    return (largeYAMLData, response)
                case "ip-large.txt":
                    return (largeTXTData, response)
                case "ads.mrs":
                    return (mrsData, response)
                default:
                    throw URLError(.fileDoesNotExist)
                }
            }
        )

        let profileYAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK-1, DIRECT]}
        rule-providers:
          classical-large:
            type: http
            behavior: classical
            format: yaml
            url: https://rules.example.com/classical-large.yaml
            path: ./ruleset/classical-large.yaml
            interval: 86400
          ip-large:
            type: http
            behavior: ipcidr
            format: text
            url: https://rules.example.com/ip-large.txt
            path: ./ruleset/ip-large.txt
            interval: 86400
          ads-mrs:
            type: http
            behavior: domain
            format: mrs
            url: https://rules.example.com/ads.mrs
            path: ./ruleset/ads.mrs
            interval: 86400
        rules:
          - RULE-SET,ads-mrs,REJECT
          - RULE-SET,classical-large,Proxy
          - RULE-SET,ip-large,DIRECT
          - MATCH,Proxy
        """

        _ = await engine.stageProviders(inProfileYAML: profileYAML)

        let stagedYAML = tempDir.appendingPathComponent("providers/rules/classical-large.yaml")
        let stagedTXT = tempDir.appendingPathComponent("providers/rules/ip-large.txt")
        let stagedMRS = tempDir.appendingPathComponent("providers/rules/ads-mrs.mrs")
        XCTAssertEqual(try Data(contentsOf: stagedYAML), largeYAMLData)
        XCTAssertEqual(try Data(contentsOf: stagedTXT), largeTXTData)
        XCTAssertEqual(try Data(contentsOf: stagedMRS), mrsData)

        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: profileYAML,
            enableDomesticDirect: true,
            providerBaseDirectoryURL: tempDir
        )

        XCTAssertTrue(optimized.contains("rule-providers:"))
        XCTAssertFalse(optimized.contains("type: http"))
        XCTAssertFalse(optimized.contains("https://rules.example.com/"))
        XCTAssertTrue(optimized.contains("type: file"))
        XCTAssertTrue(optimized.contains("./providers/rules/classical-large.yaml"))
        XCTAssertTrue(optimized.contains("./providers/rules/ip-large.txt"))
        XCTAssertTrue(optimized.contains("./providers/rules/ads-mrs.mrs"))
        XCTAssertTrue(optimized.contains("format: mrs"))
        XCTAssertTrue(optimized.contains("RULE-SET,ads-mrs,REJECT"))
        XCTAssertTrue(optimized.contains("RULE-SET,classical-large,Proxy"))
        XCTAssertTrue(optimized.contains("RULE-SET,ip-large,DIRECT"))
    }

    func testUncachedHTTPRuleProviderPreservesFallbackWhenNoStagedSnapshotExists() {
        let profileYAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK-1, DIRECT]}
        rule-providers:
          reject:
            type: http
            behavior: domain
            url: https://rules.example.com/reject.yaml
            interval: 86400
        rules:
          - RULE-SET,reject,REJECT
          - MATCH,Proxy
        """

        let emptyDir = tempDir.appendingPathComponent("EmptyProviders", isDirectory: true)
        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: profileYAML,
            enableDomesticDirect: true,
            providerBaseDirectoryURL: emptyDir
        )

        XCTAssertFalse(optimized.contains("https://rules.example.com/reject.yaml"))
        XCTAssertFalse(optimized.contains("RULE-SET,reject,REJECT"))
        XCTAssertFalse(optimized.contains("rule-providers:"))
    }

    // MARK: - P0-1: ProxyProviderEngine Staging, SubscriptionUsage & HTTP -> File Rewriting

    func testProxyProviderEngineStagesYAMLComputesUsageAndRewritesProfile() async throws {
        let storageDir = tempDir.appendingPathComponent("ProxyProviders", isDirectory: true)
        let providerYAML = """
        proxies:
          - {name: Airport-HK-01, type: ss, server: 10.10.1.1, port: 443, cipher: aes-128-gcm, password: secret}
          - {name: Airport-JP-02, type: vmess, server: 10.10.1.2, port: 8443, uuid: 11111111-1111-1111-1111-111111111111, alterId: 0, cipher: auto}
        """
        let providerURL = URL(string: "https://sub.example.com/nodes.yaml")!

        let engine = ProxyProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                XCTAssertEqual(requestURL, providerURL)
                let response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: [
                        "Subscription-Userinfo": "upload=1073741824; download=2147483648; total=10737418240; expire=1893456000"
                    ]
                )!
                return (Data(providerYAML.utf8), response)
            }
        )

        let profileYAML = """
        mixed-port: 7890
        proxy-providers:
          airport-a:
            type: http
            url: https://sub.example.com/nodes.yaml
            path: ./proxies/airport-a.yaml
            interval: 3600
            health-check:
              enable: true
              url: https://www.gstatic.com/generate_204
              interval: 600
        proxy-groups:
          - {name: Proxy, type: select, use: [airport-a]}
        rules:
          - MATCH,Proxy
        """

        let staged = await engine.stageProviders(inProfileYAML: profileYAML)
        XCTAssertEqual(staged.count, 1)
        let meta = try XCTUnwrap(staged.first)
        XCTAssertEqual(meta.name, "airport-a")
        XCTAssertEqual(meta.proxyCount, 2)
        XCTAssertEqual(meta.usage?.totalBytes, 10_737_418_240)
        XCTAssertEqual(meta.usage?.usedBytes, 3_221_225_472)
        XCTAssertEqual(meta.stagedRelativePath, "./providers/proxies/airport-a.yaml")
        XCTAssertNil(meta.lastError)

        let rootFile = tempDir.appendingPathComponent("providers/proxies/airport-a.yaml")
        let tunFile = tempDir.appendingPathComponent("Runtime/providers/proxies/airport-a.yaml")
        let flowFile = tempDir.appendingPathComponent("Runtime/FlowCore/providers/proxies/airport-a.yaml")
        XCTAssertEqual(try String(contentsOf: rootFile, encoding: .utf8), providerYAML)
        XCTAssertEqual(try String(contentsOf: tunFile, encoding: .utf8), providerYAML)
        XCTAssertEqual(try String(contentsOf: flowFile, encoding: .utf8), providerYAML)

        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: profileYAML,
            enableDomesticDirect: true,
            providerBaseDirectoryURL: tempDir
        )
        XCTAssertTrue(optimized.contains("proxy-providers:"))
        XCTAssertFalse(optimized.contains("type: http"))
        XCTAssertFalse(optimized.contains("https://sub.example.com/nodes.yaml"))
        XCTAssertTrue(optimized.contains("type: file"))
        XCTAssertTrue(optimized.contains("./providers/proxies/airport-a.yaml"))
    }

    func testProxyProviderEngineRejectsHTMLPayloadWithoutOverwritingCache() async throws {
        let storageDir = tempDir.appendingPathComponent("ProxyProviders", isDirectory: true)
        let providerURL = URL(string: "https://sub.example.com/broken.yaml")!
        let engine = ProxyProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("<!DOCTYPE html><html><body>Cloudflare</body></html>".utf8), response)
            }
        )

        let item = ProxyProviderMetadata(name: "broken", url: providerURL)
        try await engine.addProvider(item)
        do {
            try await engine.fetchAndStage(id: item.id)
            XCTFail("Expected invalid payload to fail")
        } catch {
            // expected
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("providers/proxies/broken.yaml").path))
    }

    // MARK: - P0-2: ProfileOverrideStore.globalOverride & MergedProfileSpec

    func testProfileOverrideStorePersistsGlobalOverride() throws {
        let store = ProfileOverrideStore(directoryURL: tempDir)
        XCTAssertTrue(store.globalOverride.isEmpty)

        let global = ProfileOverride(
            groups: [
                CustomProxyGroup(
                    name: "Global-HK",
                    regions: ["HK"],
                    groupKind: .urlTest(interval: 300, tolerance: 50)
                )
            ],
            hiddenNodeKeywords: ["Expired", "Traffic"],
            customHosts: [
                CustomHostMapping(domain: "home.lan", ip: "192.168.1.10")
            ]
        )
        try store.saveGlobalOverride(global)

        let reloaded = ProfileOverrideStore(directoryURL: tempDir)
        XCTAssertEqual(reloaded.globalOverride, global)
    }

    func testGlobalOverrideAppliesBeforePerProfileWithPerProfilePrecedence() throws {
        let baseYAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-01, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: a}
          - {name: JP-01, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: a}
          - {name: SG-01, type: ss, server: 3.3.3.3, port: 443, cipher: aes-128-gcm, password: a}
          - {name: US-01, type: ss, server: 4.4.4.4, port: 443, cipher: aes-128-gcm, password: a}
          - {name: Expired-Info, type: ss, server: 5.5.5.5, port: 443, cipher: aes-128-gcm, password: a}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK-01, JP-01, SG-01, US-01, Expired-Info]}
        rules:
          - MATCH,Proxy
        """

        let global = ProfileOverride(
            groups: [
                CustomProxyGroup(name: "Global-HK", regions: ["HK"], parentGroup: "Proxy", position: .top),
                CustomProxyGroup(name: "Shared-Route", regions: ["JP"], parentGroup: "Proxy", position: .bottom)
            ],
            hiddenNodeKeywords: ["Expired"],
            customHosts: [
                CustomHostMapping(domain: "shared.example", ip: "1.1.1.1"),
                CustomHostMapping(domain: "global.example", ip: "9.9.9.9")
            ]
        )
        let perProfile = ProfileOverride(
            groups: [
                CustomProxyGroup(name: "Shared-Route", regions: ["SG"], parentGroup: "Proxy", position: .top),
                CustomProxyGroup(name: "Profile-US", regions: ["US"], parentGroup: "Proxy", position: .bottom)
            ],
            customHosts: [
                CustomHostMapping(domain: "shared.example", ip: "8.8.8.8")
            ]
        )

        let result = ProfileOverrideCompiler.apply(perProfile, globalOverride: global, to: baseYAML)
        let summary = ProfileConfigurationInspector.inspect(yaml: result.yaml)

        XCTAssertTrue(result.diagnostics.isEmpty, "Unexpected diagnostics: \(result.diagnostics)")
        XCTAssertEqual(result.hiddenNodes, ["Expired-Info"])
        let baseProxyGroup = try XCTUnwrap(summary.proxyGroups.first(where: { $0.name == "Proxy" }))
        XCTAssertFalse(baseProxyGroup.members.contains("Expired-Info"))

        let globalHK = try XCTUnwrap(summary.proxyGroups.first(where: { $0.name == "Global-HK" }))
        XCTAssertEqual(globalHK.members, ["HK-01"])

        let sharedRoute = try XCTUnwrap(summary.proxyGroups.first(where: { $0.name == "Shared-Route" }))
        XCTAssertEqual(sharedRoute.members, ["SG-01"])

        let profileUS = try XCTUnwrap(summary.proxyGroups.first(where: { $0.name == "Profile-US" }))
        XCTAssertEqual(profileUS.members, ["US-01"])

        XCTAssertTrue(result.yaml.contains("\"shared.example\": \"8.8.8.8\""))
        XCTAssertTrue(result.yaml.contains("\"global.example\": \"9.9.9.9\""))
        XCTAssertFalse(result.yaml.contains("\"1.1.1.1\""))
    }

    func testMergedProfileSpecCombinesSourcesDeduplicatesAndSupportsCrossSubscriptionDialerChain() throws {
        let keyStore = InMemoryProfileKeyStore(
            keys: [EncryptedProfileCodec.defaultKeyID: Data(repeating: 0xA5, count: 32)]
        )
        let store = ProfileCatalogStore(directoryURL: tempDir, keyStore: keyStore)

        let subAYAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-01, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
          - {name: Relay-A, type: ss, server: 2.3.4.5, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK-01, Relay-A]}
        rules:
          - MATCH,Proxy
        """
        let subBYAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-01, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
          - {name: Landing-B, type: ss, server: 6.7.8.9, port: 8443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK-01, Landing-B]}
        rules:
          - MATCH,Proxy
        """

        let catalogA = try store.addValidated(data: Data(subAYAML.utf8), suggestedName: "SubA")
        let subA = try XCTUnwrap(catalogA.profiles.first(where: { $0.profile.name == "SubA" }))
        let catalogB = try store.addValidated(data: Data(subBYAML.utf8), suggestedName: "SubB")
        let subB = try XCTUnwrap(catalogB.profiles.first(where: { $0.profile.name == "SubB" }))

        let spec = MergedProfileSpec(
            sourceProfileIDs: [subA.id, subB.id],
            prefixSourceName: true,
            deduplicateByServerPort: true
        )

        let mergedCatalog = try store.createMergedProfile(name: "Merged-AB", spec: spec)
        let merged = try XCTUnwrap(mergedCatalog.profiles.first(where: { $0.profile.name == "Merged-AB" }))
        XCTAssertEqual(merged.mergedSpec, spec)

        let summary = ProfileConfigurationInspector.inspect(yaml: merged.profile.yaml)
        let nodeNames = summary.proxies.map(\.name)
        // HK-01 from SubB shares server:port 1.2.3.4:443 with SubA's HK-01, so dedup drops the duplicate.
        XCTAssertEqual(nodeNames, ["[SubA] HK-01", "[SubA] Relay-A", "[SubB] Landing-B"])

        // Cross-subscription dialer-proxy chain: Landing-B via Relay-A
        let crossChain = ChainedProxyOverride(
            name: "Chain-A-to-B",
            dialerProxy: "[SubA] Relay-A",
            target: .existingNode(name: "[SubB] Landing-B")
        )
        let override = ProfileOverride(chainedProxies: [crossChain])
        let compiled = ProfileOverrideCompiler.apply(override, to: merged.profile.yaml)
        XCTAssertTrue(compiled.diagnostics.isEmpty, "Unexpected chain diagnostics: \(compiled.diagnostics)")
        XCTAssertEqual(compiled.chainedProxies["Chain-A-to-B"], "[SubA] Relay-A")
        XCTAssertTrue(compiled.yaml.contains("dialer-proxy: '[SubA] Relay-A'") || compiled.yaml.contains("dialer-proxy: \"[SubA] Relay-A\""))

        // Reload store from disk to verify mergedSpec persistence
        let reloadedCatalog = try ProfileCatalogStore(directoryURL: tempDir, keyStore: keyStore).loadOrMigrate()
        let reloadedMerged = try XCTUnwrap(reloadedCatalog.profiles.first(where: { $0.id == merged.id }))
        XCTAssertEqual(reloadedMerged.mergedSpec, spec)

        // Replace SubB with a new node and rebuild merged profile while preserving overrides
        _ = try store.setOverrides(id: merged.id, overrides: override)
        let subBUpdated = """
        mixed-port: 7890
        proxies:
          - {name: Landing-B2, type: ss, server: 7.7.7.7, port: 8443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [Landing-B2]}
        rules:
          - MATCH,Proxy
        """
        _ = try store.replace(id: subB.id, with: ActiveProfile(name: "SubB", yaml: subBUpdated))
        let rebuiltCatalog = try store.rebuildMergedProfile(id: merged.id)
        let rebuiltMerged = try XCTUnwrap(rebuiltCatalog.profiles.first(where: { $0.id == merged.id }))
        XCTAssertEqual(rebuiltMerged.mergedSpec, spec)
        XCTAssertEqual(rebuiltMerged.profile.overrides, override)
        let rebuiltNodes = ProfileConfigurationInspector.inspect(yaml: rebuiltMerged.profile.yaml).proxies.map(\.name)
        XCTAssertTrue(rebuiltNodes.contains("[SubB] Landing-B2"))
        XCTAssertFalse(rebuiltNodes.contains("[SubB] Landing-B"))
    }

    // MARK: - P0-3: Engine-Native Custom Proxy Group Kinds (select, url-test, fallback, load-balance, smart)

    func testCustomProxyGroupBackwardCompatibleJSONDecodingDefaultsToSelect() throws {
        let legacyJSON = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "name": "Legacy-HK",
          "regions": ["HK"],
          "includeKeywords": [],
          "excludeKeywords": [],
          "manualNodes": [],
          "mode": "fastest",
          "position": "top"
        }
        """
        let decoded = try JSONDecoder().decode(CustomProxyGroup.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.groupKind, .select)
    }

    func testCustomProxyGroupKindsCompileToYAMLAndJSONAndSummarize() throws {
        let baseYAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: a}
          - {name: HK-2, type: ss, server: 1.1.1.2, port: 443, cipher: aes-128-gcm, password: a}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK-1, HK-2]}
        rules:
          - MATCH,Proxy
        """

        let groups: [CustomProxyGroup] = [
            CustomProxyGroup(name: "G-Select", manualNodes: ["HK-1", "HK-2"], groupKind: .select),
            CustomProxyGroup(name: "G-URLTest", manualNodes: ["HK-1", "HK-2"], groupKind: .urlTest(interval: 300, tolerance: 50)),
            CustomProxyGroup(name: "G-Fallback", manualNodes: ["HK-1", "HK-2"], groupKind: .fallback(interval: 180)),
            CustomProxyGroup(name: "G-LBRound", manualNodes: ["HK-1", "HK-2"], groupKind: .loadBalance(strategy: .roundRobin)),
            CustomProxyGroup(name: "G-LBConsistent", manualNodes: ["HK-1", "HK-2"], groupKind: .loadBalance(strategy: .consistentHashing)),
            CustomProxyGroup(name: "G-LBSticky", manualNodes: ["HK-1", "HK-2"], groupKind: .loadBalance(strategy: .stickySession)),
            CustomProxyGroup(name: "G-Smart", manualNodes: ["HK-1", "HK-2"], groupKind: .smart),
        ]

        let yamlResult = ProfileOverrideCompiler.apply(ProfileOverride(groups: groups), to: baseYAML)
        let yamlSummary = ProfileConfigurationInspector.inspect(yaml: yamlResult.yaml)

        let selectGroup = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-Select" }))
        XCTAssertEqual(selectGroup.strategy, "select")

        let urlTestGroup = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-URLTest" }))
        XCTAssertEqual(urlTestGroup.strategy, "url-test")
        XCTAssertEqual(urlTestGroup.intervalSeconds, 300)
        XCTAssertEqual(urlTestGroup.toleranceMilliseconds, 50)

        let fallbackGroup = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-Fallback" }))
        XCTAssertEqual(fallbackGroup.strategy, "fallback")
        XCTAssertEqual(fallbackGroup.intervalSeconds, 180)

        let lbRound = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-LBRound" }))
        XCTAssertEqual(lbRound.strategy, "load-balance")
        XCTAssertEqual(lbRound.loadBalanceStrategy, "round-robin")

        let lbConsistent = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-LBConsistent" }))
        XCTAssertEqual(lbConsistent.strategy, "load-balance")
        XCTAssertEqual(lbConsistent.loadBalanceStrategy, "consistent-hashing")

        let lbSticky = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-LBSticky" }))
        XCTAssertEqual(lbSticky.strategy, "load-balance")
        XCTAssertEqual(lbSticky.loadBalanceStrategy, "sticky-session")

        let smartGroup = try XCTUnwrap(yamlSummary.proxyGroups.first(where: { $0.name == "G-Smart" }))
        XCTAssertEqual(smartGroup.strategy, "smart")

        // Also verify JSON profile compilation path
        let baseJSON = """
        {
          "mixed-port": 7890,
          "proxies": [
            {"name": "HK-1", "type": "ss", "server": "1.1.1.1", "port": 443, "cipher": "aes-128-gcm", "password": "a"},
            {"name": "HK-2", "type": "ss", "server": "1.1.1.2", "port": 443, "cipher": "aes-128-gcm", "password": "a"}
          ],
          "proxy-groups": [
            {"name": "Proxy", "type": "select", "proxies": ["HK-1", "HK-2"]}
          ],
          "rules": ["MATCH,Proxy"]
        }
        """
        let jsonResult = ProfileOverrideCompiler.apply(ProfileOverride(groups: groups), to: baseJSON)
        let jsonSummary = ProfileConfigurationInspector.inspect(yaml: jsonResult.yaml)
        XCTAssertEqual(jsonSummary.proxyGroups.first(where: { $0.name == "G-Smart" })?.strategy, "smart")
        XCTAssertEqual(jsonSummary.proxyGroups.first(where: { $0.name == "G-LBConsistent" })?.loadBalanceStrategy, "consistent-hashing")
        XCTAssertEqual(jsonSummary.proxyGroups.first(where: { $0.name == "G-URLTest" })?.toleranceMilliseconds, 50)
    }
}

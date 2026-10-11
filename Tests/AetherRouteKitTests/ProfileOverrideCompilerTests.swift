import Foundation
import XCTest
@testable import AetherRouteKit

/// Profile overrides (1.7.0): custom groups, listing them in an existing
/// group, hiding nodes, without disturbing anything else in the profile.
final class ProfileOverrideCompilerTests: XCTestCase {
    private let blockProfile = """
    mixed-port: 7890
    # Provider header comment
    proxies:
      - name: "🇭🇰 Hong Kong 01"
        type: ss
        server: hk1.example.com
        port: 443
        cipher: aes-128-gcm
        password: secret
      - name: HK 02 游戏
        type: ss
        server: hk2.example.com
        port: 443
        cipher: aes-128-gcm
        password: secret
      - name: 日本 东京 03
        type: vmess
        server: 2001:db8::3
        port: 443
        uuid: 11111111-2222-3333-4444-555555555555
        alterId: 0
        cipher: auto
      - name: 剩余流量：10 GB
        type: ss
        server: info.example.com
        port: 1
        cipher: aes-128-gcm
        password: x
    proxy-groups:
      - name: 节点选择
        type: select
        proxies:
          - 自动选择
          - "🇭🇰 Hong Kong 01"
          - HK 02 游戏
          - 日本 东京 03
          - 剩余流量：10 GB
      - name: 自动选择
        type: url-test
        url: http://www.gstatic.com/generate_204
        interval: 300 # seconds
        proxies: ["🇭🇰 Hong Kong 01", HK 02 游戏, 日本 东京 03]
    rules:
      - DOMAIN-SUFFIX,example.com,节点选择
      - MATCH,节点选择
    """

    private func group(_ name: String, in yaml: String) -> ProxyGroupConfigurationSummary? {
        ProfileConfigurationInspector.inspect(yaml: yaml).proxyGroups.first { $0.name == name }
    }

    func testAnEmptyOverrideLeavesTheProfileAlone() {
        XCTAssertEqual(ProfileOverrideCompiler.apply(nil, to: blockProfile).yaml, blockProfile)
        XCTAssertEqual(ProfileOverrideCompiler.apply(ProfileOverride(), to: blockProfile).yaml, blockProfile)
    }

    func testRegionGroupIsAddedListedInItsParentAndFollowsRules() throws {
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "香港自动", regions: ["HK"], excludeKeywords: ["游戏"], parentGroup: "节点选择", position: .top),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: blockProfile)

        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.customGroupMembers["香港自动"], ["🇭🇰 Hong Kong 01"])
        let custom = try XCTUnwrap(group("香港自动", in: result.yaml))
        XCTAssertEqual(custom.strategy, "select")
        XCTAssertEqual(custom.members, ["🇭🇰 Hong Kong 01"])
        let parent = try XCTUnwrap(group("节点选择", in: result.yaml))
        XCTAssertEqual(parent.members, ["香港自动", "自动选择", "🇭🇰 Hong Kong 01", "HK 02 游戏", "日本 东京 03", "剩余流量：10 GB"])
        // The untouched group keeps every byte, comment included.
        XCTAssertTrue(result.yaml.contains("    interval: 300 # seconds\n"))
        XCTAssertTrue(result.yaml.contains("# Provider header comment\n"))
        XCTAssertTrue(result.yaml.contains("    server: 2001:db8::3\n"))
        XCTAssertEqual(ProfileConfigurationInspector.inspect(yaml: result.yaml).proxyCount, 4)
        // The custom group comes first, before anything lists it.
        let groups = ProfileConfigurationInspector.inspect(yaml: result.yaml).proxyGroups.map(\.name)
        XCTAssertEqual(groups, ["香港自动", "节点选择", "自动选择"])
    }

    func testHiddenNodesLeaveEveryGroupButStayDefined() throws {
        let override = try ProfileOverride(hiddenNodeKeywords: ["剩余流量", "游戏"]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: blockProfile)

        XCTAssertEqual(Set(result.hiddenNodes), ["剩余流量：10 GB", "HK 02 游戏"])
        XCTAssertEqual(group("节点选择", in: result.yaml)?.members, ["自动选择", "🇭🇰 Hong Kong 01", "日本 东京 03"])
        XCTAssertEqual(group("自动选择", in: result.yaml)?.members, ["🇭🇰 Hong Kong 01", "日本 东京 03"])
        // url-test keeps its url and interval when rewritten.
        let line = try XCTUnwrap(result.yaml.components(separatedBy: "\n").first { $0.contains("name: 自动选择") })
        XCTAssertTrue(line.contains("url: http://www.gstatic.com/generate_204"), line)
        XCTAssertTrue(line.contains("interval: 300"), line)
        XCTAssertTrue(line.contains("type: url-test"), line)
        XCTAssertEqual(ProfileConfigurationInspector.inspect(yaml: result.yaml).proxyCount, 4)
    }

    func testFlowStyleProfileAndUnusualNames() throws {
        let yaml = """
        proxies:
        - {name: 'It''s HK: 1', type: socks5, server: 127.0.0.1, port: 1080}
        - {name: "SG \\"2\\"", type: socks5, server: 127.0.0.1, port: 1081}
        - {name: Plain JP, type: socks5, server: 127.0.0.1, port: 1082}
        proxy-groups:
        - {name: Proxy, type: select, proxies: ['It''s HK: 1', "SG \\"2\\"", Plain JP]}
        rules:
        - MATCH,Proxy

        """
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "Asia, picked: HK & SG", includeKeywords: ["hk", "sg"], parentGroup: "Proxy", position: .bottom),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)

        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.customGroupMembers["Asia, picked: HK & SG"], ["It's HK: 1", "SG \"2\""])
        // Members are listed exactly as the profile spells them.
        let line = try XCTUnwrap(result.yaml.components(separatedBy: "\n").first { $0.contains("Asia, picked") && $0.contains("type: select") })
        XCTAssertTrue(line.contains("proxies: ['It''s HK: 1', \"SG \\\"2\\\"\"]"), line)
        XCTAssertEqual(group("Asia, picked: HK & SG", in: result.yaml)?.memberCount, 2)
        XCTAssertEqual(group("Proxy", in: result.yaml)?.members.last, "Asia, picked: HK & SG")
        XCTAssertEqual(group("Proxy", in: result.yaml)?.memberCount, 4)
        XCTAssertTrue(result.yaml.hasPrefix("proxies:\n- {name: 'It''s HK: 1'"))
        XCTAssertThrowsError(try CustomProxyGroup(name: "Say \"hi\"", regions: ["HK"]).validated())
    }

    func testDashAtKeyIndentAndBareDashItems() throws {
        let yaml = """
        proxies:
        -
          name: HK A
          type: socks5
          server: 127.0.0.1
          port: 1080
        - name: HK B
          type: socks5
          server: 127.0.0.1
          port: 1081
        proxy-groups:
        - name: Proxy
          type: select
          proxies:
          - HK A
          - HK B
        """
        let override = try ProfileOverride(
            groups: [CustomProxyGroup(name: "HK", regions: ["HK"], parentGroup: "Proxy")],
            hiddenNodeKeywords: ["B"]
        ).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(group("HK", in: result.yaml)?.members, ["HK A"])
        XCTAssertEqual(group("Proxy", in: result.yaml)?.members, ["HK", "HK A"])
    }

    func testProblemsAreReportedNotFatal() throws {
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "节点选择", regions: ["HK"]),
            CustomProxyGroup(name: "Brazil", regions: ["BR"], parentGroup: "节点选择"),
            CustomProxyGroup(name: "Japan", regions: ["JP"], parentGroup: "Gone"),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: blockProfile)

        XCTAssertTrue(result.diagnostics.contains(.nameConflict(group: "节点选择")))
        XCTAssertTrue(result.diagnostics.contains(.noMatchingNodes(group: "Brazil")))
        XCTAssertTrue(result.diagnostics.contains(.parentGroupMissing(group: "Japan", parent: "Gone")))
        XCTAssertEqual(group("Brazil", in: result.yaml)?.members, ["DIRECT"])
        XCTAssertEqual(group("Japan", in: result.yaml)?.members, ["日本 东京 03"])
        XCTAssertEqual(group("节点选择", in: result.yaml)?.members.first, "Brazil")
        XCTAssertEqual(ProfileConfigurationInspector.inspect(yaml: result.yaml).proxyGroupCount, 4)
    }

    func testGroupsItCannotReadSafelyAreLeftAsTheyAre() throws {
        let yaml = """
        proxies:
          - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [HK 1]
            health-check:
              enable: true
        rules:
          - MATCH,Proxy
        """
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "HK", regions: ["HK"], parentGroup: "Proxy"),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        XCTAssertTrue(result.diagnostics.contains(.groupNotEditable(group: "Proxy")))
        XCTAssertTrue(result.yaml.contains("    health-check:\n      enable: true"))
        XCTAssertEqual(group("HK", in: result.yaml)?.members, ["HK 1"])
        XCTAssertEqual(group("Proxy", in: result.yaml)?.members, ["HK 1"])
    }

    func testProviderOnlyGroupGainsAProxiesList() throws {
        let yaml = """
        proxies:
          - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
        proxy-groups:
          - {name: Remote, type: select, use: [provider-a]}
        rules:
          - MATCH,Remote
        """
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "HK", regions: ["HK"], parentGroup: "Remote"),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        let line = try XCTUnwrap(result.yaml.components(separatedBy: "\n").first { $0.contains("name: Remote") })
        XCTAssertTrue(line.contains("use: [provider-a]"), line)
        XCTAssertTrue(line.contains("proxies: [\"HK\"]"), line)
    }

    func testProfileWithoutGroupsGetsASection() throws {
        let yaml = """
        proxies:
          - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
        rules:
          - MATCH,DIRECT
        """
        let override = try ProfileOverride(groups: [CustomProxyGroup(name: "HK", regions: ["HK"])]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        XCTAssertEqual(group("HK", in: result.yaml)?.members, ["HK 1"])
        XCTAssertTrue(result.yaml.contains("proxy-groups:\n  - {name: \"HK\""), result.yaml)
    }

    func testJSONProfile() throws {
        let json = """
        {"proxies":[{"name":"HK 1","type":"socks5","server":"127.0.0.1","port":1080},{"name":"Info 1GB","type":"socks5","server":"127.0.0.1","port":1}],
         "proxy-groups":[{"name":"Proxy","type":"select","proxies":["HK 1","Info 1GB"]}],
         "rules":["MATCH,Proxy"]}
        """
        let override = try ProfileOverride(
            groups: [CustomProxyGroup(name: "HK", regions: ["HK"], parentGroup: "Proxy")],
            hiddenNodeKeywords: ["Info"]
        ).validated()
        let result = ProfileOverrideCompiler.apply(override, to: json)
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(group("HK", in: result.yaml)?.members, ["HK 1"])
        XCTAssertEqual(group("Proxy", in: result.yaml)?.members, ["HK", "HK 1"])
    }

    func testValidationBoundsAndCleansInput() throws {
        let cleaned = try CustomProxyGroup(
            name: "  HK  ",
            regions: ["hk", "HK", "xyz"],
            includeKeywords: [" a ", "a", ""],
            parentGroup: " "
        ).validated()
        XCTAssertEqual(cleaned.name, "HK")
        XCTAssertEqual(cleaned.regions, ["HK"])
        XCTAssertEqual(cleaned.includeKeywords, ["a"])
        XCTAssertNil(cleaned.parentGroup)
        XCTAssertThrowsError(try CustomProxyGroup(name: "DIRECT", regions: ["HK"]).validated())
        XCTAssertThrowsError(try CustomProxyGroup(name: "Empty").validated())
        XCTAssertThrowsError(try ProfileOverride(groups: [
            CustomProxyGroup(name: "A", regions: ["HK"]), CustomProxyGroup(name: "A", regions: ["JP"]),
        ]).validated())
        XCTAssertThrowsError(try ProfileOverride(
            groups: (0...ProfileOverride.maximumGroupCount).map { CustomProxyGroup(name: "G\($0)", regions: ["HK"]) }
        ).validated())
    }

    func testLargeSubscriptionCompilesQuickly() throws {
        var lines = ["proxies:"]
        let regions = ["香港", "日本", "新加坡", "美国", "台湾"]
        for index in 0..<3_000 {
            lines.append("  - {name: \(regions[index % 5]) \(index), type: socks5, server: 127.0.0.1, port: \(1_000 + index % 50_000)}")
        }
        lines.append("proxy-groups:")
        let names = (0..<3_000).map { "\(regions[$0 % 5]) \($0)" }
        lines.append("  - {name: Proxy, type: select, proxies: [\(names.joined(separator: ", "))]}")
        lines.append("rules:")
        lines.append("  - MATCH,Proxy")
        let yaml = lines.joined(separator: "\n")
        let override = try ProfileOverride(
            groups: ["HK", "JP", "SG", "US", "TW"].map { CustomProxyGroup(name: "Auto \($0)", regions: [$0], parentGroup: "Proxy") },
            hiddenNodeKeywords: ["美国 1"]
        ).validated()
        let start = ContinuousClock.now
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        let elapsed = ContinuousClock.now - start
        XCTAssertEqual(result.diagnostics, [])
        XCTAssertEqual(result.customGroupMembers["Auto HK"]?.count, 600)
        XCTAssertLessThan(elapsed, .milliseconds(1_500), "3,000 nodes took \(elapsed)")
    }
}

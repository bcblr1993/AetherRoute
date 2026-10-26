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

        let rule5 = try CustomRule.parse("GEOSITE,category-ai-!cn,ProxyNode")
        XCTAssertEqual(rule5.kind, .geoSite)
        XCTAssertEqual(rule5.value, "category-ai-!cn")
        XCTAssertEqual(rule5.target, .proxy("ProxyNode"))
        XCTAssertFalse(rule5.noResolve)
        XCTAssertEqual(rule5.toClashRuleString(), "GEOSITE,category-ai-!cn,ProxyNode")

        let rule6 = try CustomRule.parse("DST-PORT,443,REJECT")
        XCTAssertEqual(rule6.kind, .dstPort)
        XCTAssertEqual(rule6.value, "443")
        XCTAssertEqual(rule6.target, .reject)
        XCTAssertFalse(rule6.noResolve)
        XCTAssertEqual(rule6.toClashRuleString(), "DST-PORT,443,REJECT")
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
        XCTAssertTrue(CustomRuleValidator.validate(kind: .geoSite, value: "youtube", target: .proxy("ProxyNode")).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .geoSite, value: "category-ai-!cn", target: .proxy("ProxyNode")).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .dstPort, value: "1", target: .direct).isValid)
        XCTAssertTrue(CustomRuleValidator.validate(kind: .dstPort, value: "65535", target: .reject).isValid)

        // Invalid cases
        XCTAssertFalse(CustomRuleValidator.validate(kind: .domain, value: "invalid domain with space.com", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .ipCIDR, value: "10.0.0.0", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .ipCIDR, value: "999.0.0.0/24", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .geoIP, value: "CHINA", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .geoSite, value: "-invalid-start", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .geoSite, value: "bad space", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .dstPort, value: "0", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .dstPort, value: "65536", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .dstPort, value: "80-443", target: .direct).isValid)
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

    func testDestinationRuleCandidatesForSubdomainRootAndMultiPartPublicSuffix() {
        let subCandidates = ConnectionDestinationRulePlanner.candidates(for: "api.openai.com:443")
        XCTAssertEqual(
            subCandidates,
            [
                ConnectionDestinationRuleCandidate(kind: .domainSuffix, value: "openai.com", noResolve: false),
                ConnectionDestinationRuleCandidate(kind: .domain, value: "api.openai.com", noResolve: false),
            ]
        )

        let rootCandidates = ConnectionDestinationRulePlanner.candidates(for: "openai.com:443")
        XCTAssertEqual(
            rootCandidates,
            [
                ConnectionDestinationRuleCandidate(kind: .domainSuffix, value: "openai.com", noResolve: false),
            ]
        )

        let ukCandidates = ConnectionDestinationRulePlanner.candidates(for: "news.bbc.co.uk:443")
        XCTAssertEqual(
            ukCandidates,
            [
                ConnectionDestinationRuleCandidate(kind: .domainSuffix, value: "bbc.co.uk", noResolve: false),
                ConnectionDestinationRuleCandidate(kind: .domain, value: "news.bbc.co.uk", noResolve: false),
            ]
        )
    }

    func testDestinationRuleCandidatesForPublicIPv4AndIPv6AndRejectsFakeIPOrLAN() {
        XCTAssertEqual(
            ConnectionDestinationRulePlanner.candidates(for: "8.8.8.8:53"),
            [ConnectionDestinationRuleCandidate(kind: .ipCIDR, value: "8.8.8.8/32", noResolve: true)]
        )
        XCTAssertEqual(
            ConnectionDestinationRulePlanner.candidates(for: "[2606:4700:4700::1111]:443"),
            [ConnectionDestinationRuleCandidate(kind: .ipCIDR6, value: "2606:4700:4700::1111/128", noResolve: true)]
        )

        // Synthetic Fake-IP, loopback, RFC1918 LAN, and local hostnames must never produce rules
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "198.18.0.25:443").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "198.19.12.34:80").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "127.0.0.1:7890").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "[::1]:7890").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "192.168.1.1:80").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "10.0.0.1:80").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "172.16.5.4:443").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "localhost:8080").isEmpty)
        XCTAssertTrue(ConnectionDestinationRulePlanner.candidates(for: "mac-mini.local:443").isEmpty)
    }

    func testCustomRuleStoreMoveUpAndDown() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = CustomRuleStore(directoryURL: tempDir)

        let r1 = CustomRule(kind: .domainSuffix, value: "first.example.com", target: .direct)
        let r2 = CustomRule(kind: .domainSuffix, value: "second.example.com", target: .proxy("Proxy"))
        let r3 = CustomRule(kind: .domainSuffix, value: "third.example.com", target: .reject)
        try store.save([r1, r2, r3])

        let movedUp = try store.move(id: r2.id, direction: .up)
        XCTAssertEqual(movedUp.map(\.id), [r2.id, r1.id, r3.id])

        // Moving top item up is a safe no-op
        let movedTopUp = try store.move(id: r2.id, direction: .up)
        XCTAssertEqual(movedTopUp.map(\.id), [r2.id, r1.id, r3.id])

        let movedDown = try store.move(id: r1.id, direction: .down)
        XCTAssertEqual(movedDown.map(\.id), [r2.id, r3.id, r1.id])

        // Moving bottom item down is a safe no-op
        let movedBottomDown = try store.move(id: r1.id, direction: .down)
        XCTAssertEqual(movedBottomDown.map(\.id), [r2.id, r3.id, r1.id])
    }

    func testCustomRuleBatchParseAndImportDeduplication() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = CustomRuleStore(directoryURL: tempDir)

        let existing = CustomRule(kind: .domainSuffix, value: "openai.com", target: .direct)
        try store.save([existing])

        let batchText = """
        # AI & Streaming rules
        payload:
          - DOMAIN-SUFFIX,openai.com,AI-Group
          - DOMAIN-SUFFIX,anthropic.com,AI-Group
          - GEOSITE,youtube,Media
          - IP-CIDR,1.1.1.1/32,DIRECT,no-resolve
          - DOMAIN-SUFFIX,internal.corp
        """

        let parsed = CustomRule.parseBatchReport(batchText, defaultTarget: .direct).rules
        XCTAssertEqual(parsed.count, 5)
        XCTAssertEqual(parsed[0].kind, .domainSuffix)
        XCTAssertEqual(parsed[0].value, "openai.com")
        XCTAssertEqual(parsed[0].target, .proxy("AI-Group"))
        XCTAssertEqual(parsed[4].value, "internal.corp")
        XCTAssertEqual(parsed[4].target, .direct)

        let merged = try store.importBatch(parsed)
        XCTAssertEqual(merged.count, 5)
        // Existing openai.com rule should have its target updated to AI-Group without duplicating
        let openAIRules = merged.filter { $0.value == "openai.com" }
        XCTAssertEqual(openAIRules.count, 1)
        XCTAssertEqual(openAIRules.first?.id, existing.id)
        XCTAssertEqual(openAIRules.first?.target, .proxy("AI-Group"))
    }

    func testImportBatchOverLimitKeepsEveryExistingRule() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = CustomRuleStore(directoryURL: tempDir)
        let existing = (0..<100).map {
            CustomRule(kind: .domainSuffix, value: "kept\($0).example.com", target: .direct)
        }
        try store.save(existing)
        let incoming = (0..<450).map {
            CustomRule(kind: .domainSuffix, value: "new\($0).example.com", target: .direct)
        }

        // 100 + 450 exceeds 512: refuse the whole batch instead of silently
        // truncating the oldest existing rules.
        XCTAssertThrowsError(try store.importBatch(incoming)) { error in
            XCTAssertEqual(error as? CustomRuleStoreError, .tooManyRules(550))
        }
        XCTAssertEqual(try store.load().map(\.id), existing.map(\.id))

        let fitting = Array(incoming.prefix(412))
        let merged = try store.importBatch(fitting)
        XCTAssertEqual(merged.count, 512)
        XCTAssertEqual(Set(existing.map(\.id)).subtracting(merged.map(\.id)), [])
    }

    func testMoveWithinScopeSkipsHiddenApplicationRules() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = CustomRuleStore(directoryURL: tempDir)
        let first = CustomRule(kind: .domainSuffix, value: "first.example.com", target: .direct)
        let app = try XCTUnwrap(CustomRule.application(
            bundleIdentifier: "com.example.app",
            bundlePath: "/Applications/Example.app",
            displayName: "Example",
            target: .direct
        ))
        let second = CustomRule(kind: .domainSuffix, value: "second.example.com", target: .reject)
        try store.save([first, app, second])

        let isDestination: @Sendable (CustomRule) -> Bool = { $0.kind != .application }
        // The Rules page lists destination rules only; "up" must reach the
        // previous visible rule, not the hidden application rule between them.
        let movedUp = try store.move(id: second.id, direction: .up, within: isDestination)
        XCTAssertEqual(movedUp.map(\.id), [second.id, app.id, first.id])

        let noOp = try store.move(id: second.id, direction: .up, within: isDestination)
        XCTAssertEqual(noOp.map(\.id), [second.id, app.id, first.id])

        let movedDown = try store.move(id: second.id, direction: .down, within: isDestination)
        XCTAssertEqual(movedDown.map(\.id), [first.id, app.id, second.id])

        let third = CustomRule(kind: .domainSuffix, value: "third.example.com", target: .proxy("Proxy"))
        try store.save([first, app, second, third])

        // Move third to top within destination scope: third becomes first destination rule, app stays in its slot
        let movedToTop = try store.move(id: third.id, direction: .top, within: isDestination)
        XCTAssertEqual(movedToTop.map(\.id), [third.id, app.id, first.id, second.id])

        // Moving top item to top is a safe no-op
        let topNoOp = try store.move(id: third.id, direction: .top, within: isDestination)
        XCTAssertEqual(topNoOp.map(\.id), [third.id, app.id, first.id, second.id])

        // Move third to bottom within destination scope
        let movedToBottom = try store.move(id: third.id, direction: .bottom, within: isDestination)
        XCTAssertEqual(movedToBottom.map(\.id), [first.id, app.id, second.id, third.id])

        // Moving bottom item to bottom is a safe no-op
        let bottomNoOp = try store.move(id: third.id, direction: .bottom, within: isDestination)
        XCTAssertEqual(bottomNoOp.map(\.id), [first.id, app.id, second.id, third.id])
    }

    func testBatchReportSkipsUnsupportedLinesInsteadOfFailing() throws {
        let text = """
        payload:
          - DOMAIN-SUFFIX,openai.com,DIRECT
          - RULE-SET,streaming,Proxy
          - PROCESS-NAME,curl,DIRECT
          - MATCH,DIRECT
          - DOMAIN-SUFFIX,anthropic.com
          - not a rule
        """
        let report = CustomRule.parseBatchReport(text, defaultTarget: .proxy("AI"))
        XCTAssertEqual(report.rules.map(\.value), ["openai.com", "anthropic.com"])
        XCTAssertEqual(report.rules.last?.target, .proxy("AI"))
        XCTAssertEqual(report.skipped.map(\.lineNumber), [3, 4, 5, 7])
        XCTAssertEqual(report.skipped.first?.line, "RULE-SET,streaming,Proxy")
        XCTAssertFalse(report.wasTruncated)

        let oversized = (0..<(CustomRule.maximumBatchRules + 5))
            .map { "DOMAIN-SUFFIX,host\($0).example.com,DIRECT" }
            .joined(separator: "\n")
        let truncated = CustomRule.parseBatchReport(oversized)
        XCTAssertEqual(truncated.rules.count, CustomRule.maximumBatchRules)
        XCTAssertTrue(truncated.wasTruncated)

        // An extra check (the editor's GEOSITE lookup) skips with its reason
        // and keeps the line number of the pasted text.
        let checked = CustomRule.parseBatchReport(
            "GEOSITE,cn,DIRECT\nGEOSITE,youtub,DIRECT",
            rejection: { $0.value == "youtub" ? "unknown category" : nil }
        )
        XCTAssertEqual(checked.rules.map(\.value), ["cn"])
        XCTAssertEqual(checked.skipped.map(\.lineNumber), [2])
        XCTAssertEqual(checked.skipped.first?.reason, "unknown category")
    }
}

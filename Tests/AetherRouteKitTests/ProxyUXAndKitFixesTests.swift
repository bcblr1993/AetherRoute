import Foundation
import XCTest
@testable import AetherRouteKit

/// Regression tests for the proxy page / Kit fixes (2.9.3): subscription
/// notice entries, region misreads, primary outbound group, custom group
/// ordering, GLOBAL persistence, latency aggregation, DNS policy storage,
/// realtime telemetry cadence and latency preferences.
final class ProxyUXAndKitFixesTests: XCTestCase {
    // MARK: - Region

    func testTrafficUnitIsNotReadAsBritain() {
        XCTAssertNil(NodeRegion.resolve(from: "剩余流量：154.92 GB"))
        XCTAssertNil(NodeRegion.resolve(from: "Remaining 100GB"))
        XCTAssertNil(NodeRegion.resolve(from: "Bandwidth 10 Gbps"))
        XCTAssertNil(NodeRegion.resolve(from: "Left 512 MB"))
        XCTAssertNil(NodeRegion.resolve(from: "Left 1.5 TiB"))
        XCTAssertNil(NodeRegion.resolve(from: "Left 3 GiB"))
    }

    func testRealBritishNodesStillResolve() {
        XCTAssertEqual(NodeRegion.resolve(from: "GB 01")?.code, "UK")
        XCTAssertEqual(NodeRegion.resolve(from: "UK-London 2")?.code, "UK")
        XCTAssertEqual(NodeRegion.resolve(from: "🇬🇧 英国 01")?.code, "UK")
        // A region named next to a traffic figure still counts.
        XCTAssertEqual(NodeRegion.resolve(from: "HK 01 100GB")?.code, "HK")
    }

    func testSubscriptionNoticesHaveNoRegion() {
        XCTAssertNil(NodeRegion.resolve(from: "套餐到期：2027-05-01"))
        XCTAssertNil(NodeRegion.resolve(from: "x2cloud.cc@gmail.com"))
        XCTAssertNil(NodeRegion.resolve(from: "剩余流量：154.92 GB"))
    }

    func testRegionSuggestionsSkipTrafficNotices() {
        let regions = ProfileOverrideSuggestions.regions(in: [
            "剩余流量：154.92 GB", "HK 01", "HK 02",
        ])
        XCTAssertEqual(regions.map(\.code), ["HK"])
    }

    // MARK: - Subscription notices

    func testMetadataRecognizesCommonNoticeForms() {
        XCTAssertTrue(InitialProxySelectionPolicy.isSubscriptionMetadata("剩余流量：154.92 GB"))
        XCTAssertTrue(InitialProxySelectionPolicy.isSubscriptionMetadata("套餐到期：长期有效"))
        XCTAssertTrue(InitialProxySelectionPolicy.isSubscriptionMetadata("x2cloud.cc@gmail.com"))
        XCTAssertTrue(InitialProxySelectionPolicy.isSubscriptionMetadata("距离下次重置剩余：12 天"))
        XCTAssertTrue(InitialProxySelectionPolicy.isSubscriptionMetadata("Traffic: 20.5 GB / 200 GB"))
        XCTAssertTrue(InitialProxySelectionPolicy.isSubscriptionMetadata("Expire: 2027-05-01"))
        XCTAssertFalse(InitialProxySelectionPolicy.isSubscriptionMetadata("HK 01 100GB"))
        XCTAssertFalse(InitialProxySelectionPolicy.isSubscriptionMetadata("香港 02 [HY2]"))
    }

    func testNoticeExtractionReadsTrafficExpiryAndContact() throws {
        let notice = try XCTUnwrap(SubscriptionNoticeSummary.extract(from: [
            "自动选择", "剩余流量：154.92 GB", "套餐到期：长期有效",
            "x2cloud.cc@gmail.com", "香港 01",
        ]))
        XCTAssertEqual(notice.noticeNames, ["剩余流量：154.92 GB", "套餐到期：长期有效", "x2cloud.cc@gmail.com"])
        XCTAssertEqual(notice.remainingTraffic, "154.92 GB")
        XCTAssertEqual(notice.remainingBytes, UInt64(154.92 * 1_073_741_824))
        XCTAssertEqual(notice.expiry, "长期有效")
        XCTAssertTrue(notice.isLongTerm)
        XCTAssertNil(notice.expiresAt)
        XCTAssertEqual(notice.contacts, ["x2cloud.cc@gmail.com"])

        let reportedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = try XCTUnwrap(notice.usage(reportedAt: reportedAt))
        XCTAssertEqual(usage.remainingBytes, notice.remainingBytes)
        XCTAssertNil(usage.expiresAt)
        XCTAssertEqual(usage.reportedAt, reportedAt)
    }

    func testNoticeExtractionReadsExpiryDate() throws {
        let notice = try XCTUnwrap(SubscriptionNoticeSummary.extract(from: [
            "套餐到期：2027-05-01", "剩余流量：512MB",
        ]))
        XCTAssertFalse(notice.isLongTerm)
        XCTAssertEqual(notice.expiry, "2027-05-01")
        let expiresAt = try XCTUnwrap(notice.expiresAt)
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: expiresAt)
        XCTAssertEqual(parts.year, 2027)
        XCTAssertEqual(parts.month, 5)
        XCTAssertEqual(parts.day, 1)
        XCTAssertEqual(notice.remainingBytes, 512 * 1_048_576)
        XCTAssertEqual(notice.usage(reportedAt: .now)?.expiresAt, expiresAt)
    }

    func testNoticeExtractionReturnsNilWithoutNotices() {
        XCTAssertNil(SubscriptionNoticeSummary.extract(from: ["HK 01", "JP 02"]))
    }

    func testProxyCountExcludesNoticeEntries() throws {
        let summary = ProfileConfigurationInspector.inspect(yaml: Self.noticeProfile)
        XCTAssertEqual(summary.proxyCount, 2)
        XCTAssertEqual(summary.subscriptionNoticeNames, ["剩余流量：154.92 GB", "套餐到期：长期有效"])
        let notice = try XCTUnwrap(summary.subscriptionNotice)
        XCTAssertEqual(notice.remainingTraffic, "154.92 GB")
        XCTAssertTrue(notice.isLongTerm)
    }

    // MARK: - Primary outbound group

    func testPrimaryOutboundGroupFollowsCatchAllAndSkipsCustomGroups() {
        let summary = ProfileConfigurationInspector.inspect(yaml: Self.customGroupFirstProfile)
        XCTAssertEqual(summary.primaryOutboundGroup(), "Proxy")
        XCTAssertEqual(summary.primaryOutboundGroup(excluding: ["Proxy"]), "HK")
    }

    func testPrimaryOutboundGroupFallsBackToFirstNonCustomGroup() {
        let summary = ProfileConfigurationInspector.inspect(yaml: """
        proxies:
          - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
        proxy-groups:
          - {name: Mine, type: select, proxies: [HK 1]}
          - {name: Main, type: select, proxies: [HK 1]}
        rules:
          - MATCH,DIRECT
        """)
        XCTAssertEqual(summary.primaryOutboundGroup(excluding: ["Mine"]), "Main")
    }

    // MARK: - Custom groups are appended

    func testCustomGroupsAreAppendedAfterProfileGroups() throws {
        let yaml = """
        proxies:
          - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
          - {name: JP 1, type: socks5, server: 127.0.0.1, port: 1081}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [HK 1, JP 1]}
          - {name: Auto, type: url-test, proxies: [HK 1, JP 1]}
        rules:
          - MATCH,Proxy
        """
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "HK", regions: ["HK"], parentGroup: "Proxy"),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        let summary = ProfileConfigurationInspector.inspect(yaml: result.yaml)
        XCTAssertEqual(summary.proxyGroups.map(\.name), ["Proxy", "Auto", "HK"], result.yaml)
        XCTAssertEqual(summary.proxyGroups.first { $0.name == "HK" }?.members, ["HK 1"])
    }

    func testCustomGroupsAreAppendedInJSONProfiles() throws {
        let json = """
        {"proxies":[{"name":"HK 1","type":"socks5","server":"127.0.0.1","port":1080}],
         "proxy-groups":[{"name":"Proxy","type":"select","proxies":["HK 1"]}],
         "rules":["MATCH,Proxy"]}
        """
        let override = try ProfileOverride(groups: [
            CustomProxyGroup(name: "HK", regions: ["HK"], parentGroup: "Proxy"),
        ]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: json)
        let summary = ProfileConfigurationInspector.inspect(yaml: result.yaml)
        XCTAssertEqual(summary.proxyGroups.map(\.name), ["Proxy", "HK"])
    }

    // MARK: - GLOBAL and large groups

    func testInitialSelectionsBindGlobalToPrimaryGroup() {
        let summary = ProfileConfigurationInspector.inspect(yaml: Self.customGroupFirstProfile)
        let selections = InitialProxySelectionPolicy.selections(
            persisted: [:],
            summary: summary,
            includeGlobal: true
        )
        XCTAssertEqual(selections["GLOBAL"], "Proxy")
    }

    func testInitialSelectionsKeepValidPersistedGlobal() {
        let summary = ProfileConfigurationInspector.inspect(yaml: Self.customGroupFirstProfile)
        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(persisted: ["GLOBAL": "HK 1"], summary: summary)["GLOBAL"],
            "HK 1"
        )
        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(persisted: ["GLOBAL": "Gone"], summary: summary)["GLOBAL"],
            "Proxy"
        )
    }

    func testGlobalMembersListGroupsThenNodesWithoutNotices() {
        let summary = ProfileConfigurationInspector.inspect(yaml: Self.noticeProfile)
        XCTAssertEqual(
            InitialProxySelectionPolicy.globalMembers(summary: summary),
            ["Proxy", "HK 1", "JP 1", "DIRECT", "REJECT"]
        )
    }

    func testGroupsToVerifyAcceptsGroupsLargerThanSixtyFour() {
        let members = (1...120).map { "HK \($0)" }
        let summary = SummaryFixture.summary(
            groups: [ProxyGroupConfigurationSummary(
                id: 0, name: "Big", strategy: "select",
                memberCount: members.count, members: members
            )],
            rules: [RuleConfigurationSummary(id: 0, order: 0, kind: "MATCH", criteria: nil, target: "Big")]
        )
        XCTAssertEqual(ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary).map(\.name), ["Big"])
    }

    func testOrderedRouteCandidatesSkipNestedGroups() {
        let latency = ProxyLatencyState(results: [
            ProxyLatencyResult(member: "Auto", delayMilliseconds: 10),
            ProxyLatencyResult(member: "HK 1", delayMilliseconds: 50),
        ])
        let candidates = ProxyConnectionReadinessPolicy.orderedRouteCandidates(
            selectedMember: nil,
            summaryMembers: ["Auto", "HK 1", "JP 1"],
            snapshotMembers: [],
            latency: latency,
            groupNames: ["Auto"]
        )
        XCTAssertEqual(candidates, ["HK 1", "JP 1"])
    }

    // MARK: - Latency aggregation

    func testLeafMeasuredAfterChildGroupRefreshesParentRow() {
        var index = ProxyLatencyIndex()
        index.beginRun(
            groups: [
                (name: "x2cloud", members: ["自动选择", "香港 02", "KR"]),
                (name: "自动选择", members: ["香港 02", "KR"]),
            ],
            selectedMembers: ["x2cloud": "KR", "自动选择": "香港 02"]
        )
        let start = Date(timeIntervalSince1970: 1_000)
        index.merge(member: "自动选择", measurement: .verified(217), at: start)
        index.merge(member: "香港 02", measurement: .verified(115), at: start.addingTimeInterval(1))
        let touched = index.aggregateChildGroups(selectedMembers: ["x2cloud": "KR", "自动选择": "香港 02"])
        XCTAssertTrue(touched.contains("x2cloud"))
        XCTAssertEqual(index.measurement(for: "自动选择", in: "x2cloud"), .verified(115))
    }

    func testNewerExplicitGroupMeasurementIsKept() {
        var index = ProxyLatencyIndex()
        index.beginRun(
            groups: [
                (name: "x2cloud", members: ["自动选择", "香港 02"]),
                (name: "自动选择", members: ["香港 02"]),
            ],
            selectedMembers: ["自动选择": "香港 02"]
        )
        let start = Date(timeIntervalSince1970: 1_000)
        index.merge(member: "香港 02", measurement: .verified(115), at: start)
        index.merge(member: "自动选择", measurement: .verified(130), at: start.addingTimeInterval(5))
        index.aggregateChildGroups(selectedMembers: ["自动选择": "香港 02"])
        XCTAssertEqual(index.measurement(for: "自动选择", in: "x2cloud"), .verified(130))
    }

    // MARK: - DNS policy store

    func testDNSPoliciesAreKeptPerProfile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyUXAndKitFixesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DNSRuntimePolicyStore(directoryURL: directory)
        let a = DNSRuntimePolicy(resolutionMode: .fakeIP, ipv6: .disabled)
        let b = DNSRuntimePolicy(resolutionMode: .normal, ipv6: .enabled)
        try store.save(a, forProfileYAML: "profile-a")
        try store.save(b, forProfileYAML: "profile-b")
        XCTAssertEqual(try store.loadIfPresent(forProfileYAML: "profile-a"), a)
        XCTAssertEqual(try store.loadIfPresent(forProfileYAML: "profile-b"), b)
        XCTAssertNil(try store.loadIfPresent(forProfileYAML: "profile-c"))
    }

    func testLegacySingleProfileDNSFileStillLoads() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyUXAndKitFixesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let digest = ProxySelectionStore.profileDigest(yaml: "legacy")
        let legacy = """
        {"formatVersion":1,"policy":{"ipv6":0,"resolutionMode":1,"respectsRules":-1},"profileDigest":"\(digest)"}
        """
        try Data(legacy.utf8).write(to: directory.appendingPathComponent("dns-runtime-policy.v1.json"))
        let store = DNSRuntimePolicyStore(directoryURL: directory)
        let expected = DNSRuntimePolicy(resolutionMode: .fakeIP, ipv6: .disabled)
        XCTAssertEqual(try store.loadIfPresent(forProfileYAML: "legacy"), expected)
        // Saving another profile keeps the legacy one.
        try store.save(.inherited, forProfileYAML: "other")
        XCTAssertEqual(try store.loadIfPresent(forProfileYAML: "legacy"), expected)
        XCTAssertEqual(try store.loadIfPresent(forProfileYAML: "other"), .inherited)
    }

    func testDNSStoreStaysWithinItsSizeBoundWithManyProfiles() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProxyUXAndKitFixesTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DNSRuntimePolicyStore(directoryURL: directory)
        for index in 0..<200 {
            try store.save(DNSRuntimePolicy(resolutionMode: .fakeIP), forProfileYAML: "p\(index)")
        }
        XCTAssertEqual(try store.loadIfPresent(forProfileYAML: "p199"), DNSRuntimePolicy(resolutionMode: .fakeIP))
        XCTAssertNil(try store.loadIfPresent(forProfileYAML: "p0"))
    }

    // MARK: - Telemetry and preferences

    func testRealtimeTelemetryPollsEverySecond() {
        XCTAssertEqual(TelemetryCadence.realtime.telemetryIntervalSeconds, 1)
        XCTAssertEqual(TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds, 1)
    }

    func testUnifiedDelayPreferenceDefaultsOnAndPersists() throws {
        let suite = "ProxyUXAndKitFixesTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(LatencyTestPreferences.unifiedDelayKey, "aetherroute.latency.unifiedDelayEnabled")
        XCTAssertTrue(LatencyTestPreferences.isUnifiedDelayEnabled(in: defaults))
        LatencyTestPreferences.setUnifiedDelayEnabled(false, in: defaults)
        XCTAssertFalse(LatencyTestPreferences.isUnifiedDelayEnabled(in: defaults))
    }

    func testLatencyBandsFollowMeasurementMode() {
        XCTAssertEqual(LatencyBandThresholds.forUnifiedDelay(true), LatencyBandThresholds(fastMaximum: 120, moderateMaximum: 300))
        XCTAssertEqual(LatencyBandThresholds.forUnifiedDelay(false), LatencyBandThresholds(fastMaximum: 200, moderateMaximum: 500))
    }

    // MARK: - Fixtures

    private static let noticeProfile = """
    proxies:
      - {name: "剩余流量：154.92 GB", type: socks5, server: 127.0.0.1, port: 1}
      - {name: "套餐到期：长期有效", type: socks5, server: 127.0.0.1, port: 2}
      - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
      - {name: JP 1, type: socks5, server: 127.0.0.1, port: 1081}
    proxy-groups:
      - {name: Proxy, type: select, proxies: ["剩余流量：154.92 GB", "套餐到期：长期有效", HK 1, JP 1]}
    rules:
      - MATCH,Proxy
    """

    private static let customGroupFirstProfile = """
    proxies:
      - {name: HK 1, type: socks5, server: 127.0.0.1, port: 1080}
      - {name: JP 1, type: socks5, server: 127.0.0.1, port: 1081}
    proxy-groups:
      - {name: HK, type: select, proxies: [HK 1]}
      - {name: Proxy, type: select, proxies: [HK, HK 1, JP 1]}
    rules:
      - DOMAIN,example.com,HK
      - MATCH,Proxy
    """
}

private enum SummaryFixture {
    static func summary(
        groups: [ProxyGroupConfigurationSummary],
        rules: [RuleConfigurationSummary]
    ) -> ProfileConfigurationSummary {
        ProfileConfigurationSummary(
            dns: ProfileConfigurationInspector.inspect(yaml: "").dns,
            proxies: [],
            proxyGroups: groups,
            proxyProviders: [],
            rules: rules,
            ruleProviders: [],
            proxyCount: 0,
            proxyGroupCount: groups.count,
            proxyProviderCount: 0,
            ruleCount: rules.count,
            ruleProviderCount: 0
        )
    }
}

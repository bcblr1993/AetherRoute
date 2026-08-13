import AetherRouteKit
import Foundation
import XCTest

final class ProxySelectionStoreTests: XCTestCase {
    func testInitialSelectionSkipsSubscriptionMetadataAndBuiltins() {
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [
                .init(
                    id: 0,
                    name: "Subscription",
                    strategy: "select",
                    memberCount: 6,
                    members: [
                        "剩余流量：180 GB",
                        "套餐到期：长期有效",
                        "support@example.com",
                        "DIRECT",
                        "Hong Kong 1",
                        "Hong Kong 2",
                    ]
                ),
            ],
            proxyProviders: [],
            rules: [],
            ruleProviders: [],
            proxyCount: 6,
            proxyGroupCount: 1,
            proxyProviderCount: 0,
            ruleCount: 0,
            ruleProviderCount: 0
        )

        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(
                persisted: [:],
                summary: summary
            ),
            ["Subscription": "Hong Kong 1"]
        )
    }

    func testInitialSelectionKeepsVerifiedMemberAndDropsStaleChoice() {
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [
                .init(
                    id: 0,
                    name: "Route",
                    strategy: "select",
                    memberCount: 2,
                    members: ["Edge A", "Edge B"]
                ),
            ],
            proxyProviders: [],
            rules: [],
            ruleProviders: [],
            proxyCount: 2,
            proxyGroupCount: 1,
            proxyProviderCount: 0,
            ruleCount: 0,
            ruleProviderCount: 0
        )

        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(
                persisted: ["Route": "Edge B"],
                summary: summary
            ),
            ["Route": "Edge B"]
        )
        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(
                persisted: ["Route": "Removed"],
                summary: summary
            ),
            ["Route": "Edge A"]
        )
    }

    func testConnectionReadinessTargetsRuleGroupAndKeepsResponsiveSelection() {
        let route = ProxyGroupConfigurationSummary(
            id: 0,
            name: "Route",
            strategy: "select",
            memberCount: 2,
            members: ["Edge A", "Edge B"]
        )
        let unused = ProxyGroupConfigurationSummary(
            id: 1,
            name: "Unused",
            strategy: "select",
            memberCount: 1,
            members: ["Other"]
        )
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [unused, route],
            proxyProviders: [],
            rules: [
                .init(
                    id: 0,
                    order: 1,
                    kind: "MATCH",
                    criteria: nil,
                    target: "Route"
                ),
            ],
            ruleProviders: [],
            proxyCount: 3,
            proxyGroupCount: 2,
            proxyProviderCount: 0,
            ruleCount: 1,
            ruleProviderCount: 0
        )

        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary),
            [route]
        )
        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.preferredMember(
                snapshot: .init(
                    selectedMember: "Edge B",
                    members: ["Edge A", "Edge B"]
                ),
                latency: .init(results: [
                    .init(member: "Edge A", delayMilliseconds: 20),
                    .init(member: "Edge B", delayMilliseconds: 50),
                ])
            ),
            "Edge B"
        )
    }

    func testConnectionReadinessChoosesFastestWhenSelectionIsDead() {
        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.preferredMember(
                snapshot: .init(
                    selectedMember: "Notice",
                    members: ["Notice", "Edge A", "Edge B"]
                ),
                latency: .init(results: [
                    .init(member: "Notice", delayMilliseconds: nil),
                    .init(member: "Edge A", delayMilliseconds: 80),
                    .init(member: "Edge B", delayMilliseconds: 30),
                ])
            ),
            "Edge B"
        )
        XCTAssertNil(
            ProxyConnectionReadinessPolicy.preferredMember(
                snapshot: .init(selectedMember: "Notice", members: ["Notice"]),
                latency: .init(results: [
                    .init(member: "Notice", delayMilliseconds: nil),
                ])
            )
        )
    }

    func testConnectionReadinessDistinguishesManualAndAutomaticGroups() {
        for strategy in ["url-test", "fallback", "load-balance"] {
            XCTAssertEqual(
                ProxyConnectionReadinessPolicy.behavior(
                    for: .init(
                        id: 0,
                        name: "Automatic",
                        strategy: strategy,
                        memberCount: 1,
                        members: ["Edge"]
                    )
                ),
                .automatic
            )
        }
        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.behavior(
                for: .init(
                    id: 0,
                    name: "Manual",
                    strategy: "select",
                    memberCount: 1,
                    members: ["Edge"]
                )
            ),
            .manual
        )
    }

    func testAutomaticCandidatesExcludePseudoRoutesDeduplicateAndBound() {
        let candidates = ProxyConnectionReadinessPolicy
            .orderedRouteCandidates(
                selectedMember: "Notice",
                summaryMembers: [
                    "DIRECT", "REJECT", "REJECT-DROP", "PASS",
                    "剩余流量：100 GB", "support@example.com",
                ] + (0..<12).map { "Edge \($0)" },
                snapshotMembers: ["Edge 2", "Edge 0", "Edge 11"],
                latency: .init(results: [
                    .init(member: "Edge 2", delayMilliseconds: 12),
                    .init(member: "Edge 0", delayMilliseconds: 40),
                ])
            )

        XCTAssertEqual(candidates.count, 8)
        XCTAssertEqual(candidates.first, "Edge 2")
        XCTAssertEqual(Set(candidates).count, candidates.count)
        XCTAssertFalse(candidates.contains("DIRECT"))
        XCTAssertFalse(candidates.contains("剩余流量：100 GB"))
        XCTAssertFalse(candidates.contains("support@example.com"))
    }

    func testManualCandidateNeverFallsBackFromExplicitSelection() {
        let candidates = ProxyConnectionReadinessPolicy
            .orderedRouteCandidates(
                selectedMember: "Chosen",
                summaryMembers: ["Chosen", "Fallback"],
                snapshotMembers: ["Chosen", "Fallback"],
                latency: .init(results: [])
            )
        let manualCandidates = Array(candidates.prefix(1))

        XCTAssertEqual(manualCandidates, ["Chosen"])
    }

    func testFastestSuccessfulRealProbeWinsAndOnly204IsAccepted() {
        let measurements = [
            ProxyConnectionReadinessPolicy.ProbeMeasurement(
                member: "Slow",
                elapsedMilliseconds: 240,
                statusCode: 204
            ),
            .init(
                member: "Redirect",
                elapsedMilliseconds: 5,
                statusCode: 302
            ),
            .init(
                member: "Fast",
                elapsedMilliseconds: 80,
                statusCode: 204
            ),
        ]

        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.fastestSuccessfulProbe(
                measurements
            )?.member,
            "Fast"
        )
        XCTAssertTrue(
            ProxyConnectionReadinessPolicy.acceptsProbeStatus(204)
        )
        XCTAssertFalse(
            ProxyConnectionReadinessPolicy.acceptsProbeStatus(200)
        )
        XCTAssertFalse(
            ProxyConnectionReadinessPolicy.acceptsProbeStatus(nil)
        )
        XCTAssertNil(
            ProxyConnectionReadinessPolicy.fastestSuccessfulProbe([
                .init(
                    member: "Failed",
                    elapsedMilliseconds: 1,
                    statusCode: nil
                ),
            ])
        )
    }

    func testConnectionReadinessBoundsGroupsAndSkipsOversizedSelectors() {
        let groups = (0..<6).map { index in
            ProxyGroupConfigurationSummary(
                id: index,
                name: "Route \(index)",
                strategy: "select",
                memberCount: index == 1 ? 65 : 2,
                members: index == 1
                    ? (0..<65).map { "Node \($0)" }
                    : ["Edge A", "Edge B"]
            )
        }
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: groups,
            proxyProviders: [],
            rules: groups.enumerated().map { index, group in
                .init(
                    id: index,
                    order: index,
                    kind: "MATCH",
                    criteria: nil,
                    target: group.name
                )
            },
            ruleProviders: [],
            proxyCount: 75,
            proxyGroupCount: groups.count,
            proxyProviderCount: 0,
            ruleCount: groups.count,
            ruleProviderCount: 0
        )

        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary)
                .map(\.name),
            ["Route 0", "Route 2", "Route 3", "Route 4"]
        )
    }

    func testVerifiedSelectionRoundTripsAndIsBoundToProfile() throws {
        let fixture = try makeFixture()
        try fixture.store.recordVerified(
            snapshot: .init(
                selectedMember: "Edge B",
                members: ["Edge A", "Edge B"]
            ),
            group: "Route",
            profileYAML: "proxies: [a]"
        )

        XCTAssertEqual(
            try fixture.store.selections(
                forProfileYAML: "proxies: [a]"
            ),
            ["Route": "Edge B"]
        )
        XCTAssertTrue(
            try fixture.store.selections(
                forProfileYAML: "proxies: [b]"
            ).isEmpty
        )
    }

    func testCiphertextHidesNamesAndUsesFreshNonce() throws {
        let fixture = try makeFixture()
        let snapshot = ProxySelectionState(
            selectedMember: "private-edge-sentinel",
            members: ["private-edge-sentinel"]
        )
        try fixture.store.recordVerified(
            snapshot: snapshot,
            group: "private-group-sentinel",
            profileYAML: "secret-profile-sentinel"
        )
        let first = try Data(contentsOf: fixture.fileURL)
        try fixture.store.recordVerified(
            snapshot: snapshot,
            group: "private-group-sentinel",
            profileYAML: "secret-profile-sentinel"
        )
        let second = try Data(contentsOf: fixture.fileURL)

        XCTAssertNotEqual(first, second)
        for sentinel in [
            "private-edge-sentinel",
            "private-group-sentinel",
            "secret-profile-sentinel",
        ] {
            XCTAssertFalse(String(decoding: second, as: UTF8.self).contains(sentinel))
        }
    }

    func testTamperingAndWrongKeyAreRejected() throws {
        let fixture = try makeFixture()
        try fixture.store.recordVerified(
            snapshot: .init(selectedMember: "A", members: ["A"]),
            group: "Route",
            profileYAML: "profile"
        )
        var data = try Data(contentsOf: fixture.fileURL)
        data[data.index(before: data.endIndex)] ^= 0x01
        try data.write(to: fixture.fileURL, options: .atomic)
        XCTAssertThrowsError(
            try fixture.store.selections(forProfileYAML: "profile")
        )

        let wrongStore = ProxySelectionStore(
            directoryURL: fixture.directory,
            keyStore: InMemoryProfileKeyStore(
                keys: ["profile-master-key.v1": Data(repeating: 0x55, count: 32)]
            )
        )
        XCTAssertThrowsError(
            try wrongStore.selections(forProfileYAML: "profile")
        )
    }

    func testUnverifiedAndInvalidNamesAreRejectedBeforeCreatingFile() throws {
        let fixture = try makeFixture()
        XCTAssertThrowsError(
            try fixture.store.recordVerified(
                snapshot: .init(selectedMember: nil, members: ["A"]),
                group: "Route",
                profileYAML: "profile"
            )
        )
        XCTAssertThrowsError(
            try fixture.store.recordVerified(
                snapshot: .init(selectedMember: "A", members: ["A"]),
                group: "bad\0group",
                profileYAML: "profile"
            )
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    private func makeFixture() throws -> (
        store: ProxySelectionStore,
        directory: URL,
        fileURL: URL
    ) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let keyStore = InMemoryProfileKeyStore(
            keys: ["profile-master-key.v1": Data(repeating: 0x2a, count: 32)]
        )
        return (
            ProxySelectionStore(
                directoryURL: directory,
                keyStore: keyStore
            ),
            directory,
            directory.appendingPathComponent("proxy-selections.v1.json")
        )
    }
}

import AetherRouteKit
import Foundation
import XCTest

final class ProxySelectionStoreTests: XCTestCase {
    func testProxySelectionCycleWrapsAndRecoversFromStaleSelection() {
        let members = ["VLESS", "HY2", "VMess"]

        XCTAssertEqual(
            ProxySelectionCyclePolicy.adjacentMember(
                members: members,
                selectedMember: "VLESS",
                direction: .next
            ),
            "HY2"
        )
        XCTAssertEqual(
            ProxySelectionCyclePolicy.adjacentMember(
                members: members,
                selectedMember: "VMess",
                direction: .next
            ),
            "VLESS"
        )
        XCTAssertEqual(
            ProxySelectionCyclePolicy.adjacentMember(
                members: members,
                selectedMember: "VLESS",
                direction: .previous
            ),
            "VMess"
        )
        XCTAssertEqual(
            ProxySelectionCyclePolicy.adjacentMember(
                members: members,
                selectedMember: "Removed",
                direction: .next
            ),
            "VLESS"
        )
        XCTAssertEqual(
            ProxySelectionCyclePolicy.adjacentMember(
                members: members,
                selectedMember: nil,
                direction: .previous
            ),
            "VMess"
        )
        XCTAssertNil(
            ProxySelectionCyclePolicy.adjacentMember(
                members: [],
                selectedMember: nil,
                direction: .next
            )
        )
    }

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

    func testInitialSelectionPrefersAutomaticChildButKeepsManualOverride() {
        let manual = ProxyGroupConfigurationSummary(
            id: 0,
            name: "Route",
            strategy: "select",
            memberCount: 3,
            members: ["Edge A", "Automatic", "DIRECT"]
        )
        let automatic = ProxyGroupConfigurationSummary(
            id: 1,
            name: "Automatic",
            strategy: "url-test",
            memberCount: 2,
            members: ["Edge A", "Edge B"]
        )
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [manual, automatic],
            proxyProviders: [],
            rules: [],
            ruleProviders: [],
            proxyCount: 2,
            proxyGroupCount: 2,
            proxyProviderCount: 0,
            ruleCount: 0,
            ruleProviderCount: 0
        )

        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(
                persisted: [:],
                summary: summary
            ),
            ["Route": "Automatic"]
        )
        XCTAssertEqual(
            InitialProxySelectionPolicy.selections(
                persisted: ["Route": "Edge A"],
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

    func testExplicitAutomaticModeChoosesFastestRealResponsiveProxy() {
        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.fastestResponsiveRoute(
                members: [
                    "DIRECT", "Remaining traffic: 10 GB", "Slow", "Fast",
                    "Unavailable",
                ],
                latency: .init(results: [
                    .init(member: "DIRECT", delayMilliseconds: 1),
                    .init(
                        member: "Remaining traffic: 10 GB",
                        delayMilliseconds: 2
                    ),
                    .init(member: "Slow", delayMilliseconds: 180),
                    .init(member: "Fast", delayMilliseconds: 42),
                    .init(member: "Unavailable", delayMilliseconds: nil),
                    .init(member: "Not in group", delayMilliseconds: 3),
                ])
            ),
            "Fast"
        )
        XCTAssertNil(
            ProxyConnectionReadinessPolicy.fastestResponsiveRoute(
                members: ["DIRECT", "Unavailable"],
                latency: .init(results: [
                    .init(member: "DIRECT", delayMilliseconds: 1),
                    .init(member: "Unavailable", delayMilliseconds: nil),
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

    func testRouteIntentTreatsLeafAsManualAndAutomaticChildAsAutomatic() {
        let route = ProxyGroupConfigurationSummary(
            id: 0,
            name: "Route",
            strategy: "select",
            memberCount: 2,
            members: ["Edge", "Automatic"]
        )
        let automatic = ProxyGroupConfigurationSummary(
            id: 1,
            name: "Automatic",
            strategy: "fallback",
            memberCount: 1,
            members: ["Edge"]
        )
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [route, automatic],
            proxyProviders: [],
            rules: [],
            ruleProviders: [],
            proxyCount: 1,
            proxyGroupCount: 2,
            proxyProviderCount: 0,
            ruleCount: 0,
            ruleProviderCount: 0
        )

        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.routeIntent(
                selectedMember: "Edge",
                summary: summary
            ).behavior,
            .manual
        )
        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.routeIntent(
                selectedMember: "Automatic",
                summary: summary
            ),
            .init(behavior: .automatic, automaticGroup: automatic)
        )
    }

    func testExplicitAutomaticSelectorRefreshKeepsHealthMonitoringIntent() {
        let route = ProxyGroupConfigurationSummary(
            id: 0,
            name: "Route",
            strategy: "select",
            memberCount: 2,
            members: ["Fixture A", "Fixture B"]
        )
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [route],
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
            ProxyConnectionReadinessPolicy.effectiveRouteIntent(
                selectedMember: "Fixture A",
                summary: summary,
                explicitlyAutomatic: true
            ),
            .init(behavior: .automatic)
        )
        XCTAssertEqual(
            ProxyConnectionReadinessPolicy.effectiveRouteIntent(
                selectedMember: "Fixture A",
                summary: summary,
                explicitlyAutomatic: false
            ),
            .init(behavior: .manual)
        )
    }

    func testAutomaticRouteHealthRecoveryRescansChildBeforeStopping() {
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.action(
                automaticChildGroup: "Automatic",
                explicitlyAutomatic: false,
                recoveryAlreadyAttempted: false
            ),
            .rescanAutomaticChild("Automatic")
        )
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.action(
                automaticChildGroup: nil,
                explicitlyAutomatic: true,
                recoveryAlreadyAttempted: false
            ),
            .reselectExplicitGroup
        )
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.action(
                automaticChildGroup: "Automatic",
                explicitlyAutomatic: true,
                recoveryAlreadyAttempted: true
            ),
            .none
        )
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.action(
                automaticChildGroup: nil,
                explicitlyAutomatic: false,
                recoveryAlreadyAttempted: false
            ),
            .none
        )
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: true
            ),
            .continueMonitoring
        )
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: false
            ),
            .stopProvider
        )
        XCTAssertEqual(
            AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: false,
                isInGracePeriod: true
            ),
            .continueMonitoring
        )
    }

    func testConnectedManualHotSwitchRequiresSelectedLeafToRespond() {
        let automatic = ProxyGroupConfigurationSummary(
            id: 2,
            name: "Automatic",
            strategy: "url-test",
            memberCount: 2,
            members: ["Edge A", "Edge B"]
        )
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [automatic],
            proxyProviders: [],
            rules: [],
            ruleProviders: [],
            proxyCount: 2,
            proxyGroupCount: 1,
            proxyProviderCount: 0,
            ruleCount: 0,
            ruleProviderCount: 0
        )

        XCTAssertTrue(
            ProxySelectionHotSwitchPolicy.accepts(
                requestedMember: "Edge A",
                summary: summary,
                latency: .init(results: [
                    .init(member: "Edge A", delayMilliseconds: 42),
                ])
            )
        )
        XCTAssertFalse(
            ProxySelectionHotSwitchPolicy.accepts(
                requestedMember: "Edge A",
                summary: summary,
                latency: .init(results: [
                    .init(member: "Edge B", delayMilliseconds: 21),
                ])
            )
        )
        XCTAssertFalse(
            ProxySelectionHotSwitchPolicy.accepts(
                requestedMember: "Edge A",
                summary: summary,
                latency: .init(results: [
                    .init(member: "Edge A", delayMilliseconds: nil),
                ])
            )
        )
    }

    func testConnectedAutomaticChildHotSwitchAcceptsResponsiveLeaf() {
        let automatic = ProxyGroupConfigurationSummary(
            id: 2,
            name: "Automatic",
            strategy: "url-test",
            memberCount: 2,
            members: ["Edge A", "Edge B"]
        )
        let summary = ProfileConfigurationSummary(
            dns: .init(),
            proxies: [],
            proxyGroups: [automatic],
            proxyProviders: [],
            rules: [],
            ruleProviders: [],
            proxyCount: 2,
            proxyGroupCount: 1,
            proxyProviderCount: 0,
            ruleCount: 0,
            ruleProviderCount: 0
        )

        XCTAssertTrue(
            ProxySelectionHotSwitchPolicy.accepts(
                requestedMember: "Automatic",
                summary: summary,
                latency: .init(results: [
                    .init(member: "Edge B", delayMilliseconds: 18),
                ])
            )
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

    func testAutomaticCandidatesIncludeFastestLateMemberBeforeBound() {
        let members = (0..<12).map { "Edge \($0)" }
        let candidates = ProxyConnectionReadinessPolicy
            .orderedRouteCandidates(
                selectedMember: "Edge 0",
                summaryMembers: members,
                snapshotMembers: members,
                latency: .init(results: members.enumerated().map {
                    index, member in
                    .init(
                        member: member,
                        delayMilliseconds: index == 11
                            ? 5
                            : 100 + UInt32(index)
                    )
                })
            )

        XCTAssertEqual(candidates.count, 8)
        XCTAssertEqual(candidates.first, "Edge 11")
        XCTAssertTrue(candidates.contains("Edge 0"))
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

    func testConnectionReadinessProbeTargetsRequiredHTTPSExternalRoute() {
        let probe = URL(
            string: ProxyConnectionReadinessPolicy
                .requiredExternalProbeURLString
        )

        XCTAssertEqual(probe?.scheme, "https")
        XCTAssertEqual(probe?.host, "www.google.com")
        XCTAssertEqual(probe?.path, "/generate_204")
        XCTAssertNil(probe?.query)
        XCTAssertNil(probe?.user)
        XCTAssertNil(probe?.password)
    }

    func testConnectionReadinessUsesLastCatchAllAndSkipsOversizedSelectors() {
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
            ["Route 5"]
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

    func testSelectionsForMultipleProfilesRemainIndependent() throws {
        let fixture = try makeFixture()
        try fixture.store.recordUserSelection(
            group: "Route",
            member: "Fixture A",
            allowedMembers: ["Dead Fixture", "Fixture A", "Fixture B"],
            profileYAML: "fixture-profile"
        )
        try fixture.store.recordUserSelection(
            group: "Proxy",
            member: "Verge Node",
            allowedMembers: ["Verge Node"],
            profileYAML: "verge-profile"
        )

        XCTAssertEqual(
            try fixture.store.selections(
                forProfileYAML: "fixture-profile"
            ),
            ["Route": "Fixture A"]
        )
        XCTAssertEqual(
            try fixture.store.selections(
                forProfileYAML: "verge-profile"
            ),
            ["Proxy": "Verge Node"]
        )
    }

    func testOfflineUserSelectionMustBelongToValidatedGroup() throws {
        let fixture = try makeFixture()

        try fixture.store.recordUserSelection(
            group: "Route",
            member: "Edge B",
            allowedMembers: ["Edge A", "Edge B", "DIRECT"],
            profileYAML: "profile"
        )
        XCTAssertEqual(
            try fixture.store.selections(forProfileYAML: "profile"),
            ["Route": "Edge B"]
        )
        XCTAssertThrowsError(
            try fixture.store.recordUserSelection(
                group: "Route",
                member: "Removed",
                allowedMembers: ["Edge A", "Edge B"],
                profileYAML: "profile"
            )
        ) { error in
            XCTAssertEqual(
                error as? ProxySelectionStoreError,
                .unverifiedSelection
            )
        }
        XCTAssertEqual(
            try fixture.store.selections(forProfileYAML: "profile"),
            ["Route": "Edge B"]
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

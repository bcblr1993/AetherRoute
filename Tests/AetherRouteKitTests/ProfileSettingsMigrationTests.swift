import Foundation
import XCTest
@testable import AetherRouteKit

/// Settings survive a subscription update that changes the profile's text
/// (1.7.0).
final class ProfileSettingsMigrationTests: XCTestCase {
    private var directory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        suiteName = "ProfileSettingsMigrationTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func profile(nodes: [String], streamingMembers: [String]? = nil) -> String {
        var lines = ["mode: rule", "proxies:"]
        for node in nodes {
            lines.append("  - {name: \(node), type: socks5, server: 127.0.0.1, port: 1080}")
        }
        lines.append("proxy-groups:")
        lines.append("  - {name: Proxy, type: select, proxies: [\(nodes.joined(separator: ", "))]}")
        if let streamingMembers {
            lines.append("  - {name: Streaming, type: select, proxies: [\(streamingMembers.joined(separator: ", "))]}")
        }
        lines.append("rules:")
        lines.append("  - MATCH,Proxy")
        return lines.joined(separator: "\n") + "\n"
    }

    private func stores() -> (ProxySelectionStore, ProxySelectionStore, DNSRuntimePolicyStore) {
        let keys = InMemoryProfileKeyStore()
        return (
            ProxySelectionStore(directoryURL: directory, keyStore: keys, kind: .selections),
            ProxySelectionStore(directoryURL: directory, keyStore: keys, kind: .preferences),
            DNSRuntimePolicyStore(directoryURL: directory)
        )
    }

    func testEverySettingFollowsATextChangeThatKeepsItsNodes() throws {
        // The provider renamed one node (remaining traffic in its name).
        let old = profile(nodes: ["HK 01", "JP 02", "Traffic 10GB"], streamingMembers: ["JP 02", "HK 01"])
        let new = profile(nodes: ["HK 01", "JP 02", "Traffic 9GB"], streamingMembers: ["JP 02", "HK 01"])
        let (selections, preferences, dns) = stores()
        try selections.mergeSelections(["Proxy": "JP 02", "Streaming": "HK 01"], profileYAML: old)
        try preferences.mergeSelections(["Proxy": "HK 01"], profileYAML: old)
        defaults.set("failover", forKey: ProxySelectionPreferenceKeys.mode(profileYAML: old, group: "Proxy"))
        defaults.set(true, forKey: ProxySelectionPreferenceKeys.legacyAutomatic(profileYAML: old, group: "Proxy"))
        let policy = DNSRuntimePolicy(resolutionMode: .fakeIP, ipv6: .disabled, respectsRules: .enabled)
        try dns.save(policy, forProfileYAML: old)

        let report = ProfileSettingsMigration.migrate(
            fromYAML: old, toYAML: new,
            selectionStore: selections, preferenceStore: preferences, dnsStore: dns,
            defaults: defaults
        )

        XCTAssertEqual(try selections.selections(forProfileYAML: new), ["Proxy": "JP 02", "Streaming": "HK 01"])
        XCTAssertEqual(try preferences.selections(forProfileYAML: new), ["Proxy": "HK 01"])
        XCTAssertEqual(defaults.string(forKey: ProxySelectionPreferenceKeys.mode(profileYAML: new, group: "Proxy")), "failover")
        XCTAssertTrue(defaults.bool(forKey: ProxySelectionPreferenceKeys.legacyAutomatic(profileYAML: new, group: "Proxy")))
        XCTAssertEqual(try dns.loadIfPresent(forProfileYAML: new), policy)
        XCTAssertEqual(report.selections, 2)
        XCTAssertEqual(report.preferredNodes, 1)
        XCTAssertEqual(report.modes, 1)
        XCTAssertTrue(report.dnsPolicy)
    }

    func testANodeOrGroupThatIsGoneIsNotCarriedOver() throws {
        let old = profile(nodes: ["HK 01", "JP 02"], streamingMembers: ["JP 02"])
        // JP 02 left the subscription and Streaming was removed.
        let new = profile(nodes: ["HK 01", "SG 03"])
        let (selections, preferences, _) = stores()
        try selections.mergeSelections(["Proxy": "JP 02", "Streaming": "JP 02"], profileYAML: old)
        try preferences.mergeSelections(["Proxy": "JP 02"], profileYAML: old)
        defaults.set("fastest", forKey: ProxySelectionPreferenceKeys.mode(profileYAML: old, group: "Streaming"))

        let report = ProfileSettingsMigration.migrate(
            fromYAML: old, toYAML: new,
            selectionStore: selections, preferenceStore: preferences, dnsStore: nil,
            defaults: defaults
        )

        XCTAssertEqual(try selections.selections(forProfileYAML: new), [:])
        XCTAssertEqual(try preferences.selections(forProfileYAML: new), [:])
        XCTAssertNil(defaults.object(forKey: ProxySelectionPreferenceKeys.mode(profileYAML: new, group: "Streaming")))
        XCTAssertTrue(report.isEmpty)
    }

    func testSettingsAlreadyMadeOnTheNewTextWin() throws {
        let old = profile(nodes: ["HK 01", "JP 02"])
        let new = profile(nodes: ["HK 01", "JP 02", "SG 03"])
        let (selections, _, dns) = stores()
        try selections.mergeSelections(["Proxy": "JP 02"], profileYAML: old)
        try selections.mergeSelections(["Proxy": "SG 03"], profileYAML: new)
        defaults.set("failover", forKey: ProxySelectionPreferenceKeys.mode(profileYAML: old, group: "Proxy"))
        defaults.set("manual", forKey: ProxySelectionPreferenceKeys.mode(profileYAML: new, group: "Proxy"))
        try dns.save(.inherited, forProfileYAML: new)

        _ = ProfileSettingsMigration.migrate(
            fromYAML: old, toYAML: new,
            selectionStore: selections, preferenceStore: nil, dnsStore: dns,
            defaults: defaults
        )

        XCTAssertEqual(try selections.selections(forProfileYAML: new), ["Proxy": "SG 03"])
        XCTAssertEqual(defaults.string(forKey: ProxySelectionPreferenceKeys.mode(profileYAML: new, group: "Proxy")), "manual")
        XCTAssertEqual(try dns.loadIfPresent(forProfileYAML: new), .inherited)
    }

    func testUnchangedTextIsLeftAlone() throws {
        let yaml = profile(nodes: ["HK 01"])
        let (selections, _, _) = stores()
        try selections.mergeSelections(["Proxy": "HK 01"], profileYAML: yaml)
        let report = ProfileSettingsMigration.migrate(
            fromYAML: yaml, toYAML: yaml,
            selectionStore: selections, preferenceStore: nil, dnsStore: nil,
            defaults: defaults
        )
        XCTAssertTrue(report.isEmpty)
        XCTAssertEqual(try selections.selections(forProfileYAML: yaml), ["Proxy": "HK 01"])
    }

    func testPreferenceKeysAreTheOnes160Wrote() {
        // 1.6.0 derived these in the app; moving them to the kit must not
        // change a single byte, or every saved mode would be lost.
        let yaml = "proxies: []\n"
        XCTAssertEqual(
            ProxySelectionPreferenceKeys.mode(profileYAML: yaml, group: "Proxy"),
            "AetherRoute.ProxySelection.Mode."
                + ProxySelectionStore.profileDigest(yaml: yaml + "\u{0}selection-mode\u{0}Proxy")
        )
        XCTAssertEqual(
            ProxySelectionPreferenceKeys.legacyAutomatic(profileYAML: yaml, group: "Proxy"),
            "AetherRoute.ProxySelection.Automatic."
                + ProxySelectionStore.profileDigest(yaml: yaml + "\u{0}automatic-selection\u{0}Proxy")
        )
    }
}

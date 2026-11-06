import Foundation
import Testing
@testable import AetherRouteKit

@Suite(.serialized)
struct AppAutomationPreferencesTests {
    @Test
    func defaultsAreDisabledAndConflictFree() {
        let preferences = GlobalShortcutPreferences()

        #expect(!preferences.isEnabled)
        #expect(preferences.hasUniqueAssignments)
        #expect(preferences[.toggleConnection] == .controlOptionC)
        #expect(preferences[.routingRule] == .controlOption1)
        #expect(preferences[.routingGlobal] == .controlOption2)
        #expect(preferences[.routingDirect] == .controlOption3)
    }

    @Test
    func assigningAnOccupiedKeySwapsInsteadOfCreatingConflict() {
        var preferences = GlobalShortcutPreferences()

        preferences.assign(.controlOption2, to: .toggleConnection)

        #expect(preferences[.toggleConnection] == .controlOption2)
        #expect(preferences[.routingGlobal] == .controlOptionC)
        #expect(preferences.hasUniqueAssignments)
    }

    @Test
    func validationRejectsDuplicateAndUnknownVersions() {
        var duplicate = GlobalShortcutPreferences()
        duplicate.routingRule = duplicate.toggleConnection
        #expect(throws: AppAutomationPreferencesError.duplicateShortcut) {
            try duplicate.validated()
        }

        let future = GlobalShortcutPreferences(version: 2)
        #expect(throws: AppAutomationPreferencesError.unsupportedVersion) {
            try future.validated()
        }
    }

    @Test
    func storeRoundTripsAndFallsBackOnCorruption() throws {
        let suite = "AppAutomationPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppAutomationPreferenceStore(defaults: defaults)
        var expected = GlobalShortcutPreferences(isEnabled: true)
        expected.assign(.controlShiftSpace, to: .toggleConnection)

        try store.save(expected)
        #expect(store.load() == expected)

        defaults.set(Data([0x00, 0xFF]), forKey: AppAutomationPreferenceStore.storageKey)
        #expect(store.load() == GlobalShortcutPreferences())
    }

    @Test
    func networkAutomationRulesMatchEnvironmentByPriorityAndValidate() throws {
        let corpWiFi = NetworkAutomationRule(
            triggerKind: .wifiSSID,
            matchValue: "  Corp-WiFi  ",
            action: .setRoutingMode(.direct)
        )
        let homeGateway = NetworkAutomationRule(
            triggerKind: .gatewayAddress,
            matchValue: "192.168.50.1",
            action: .setRoutingMode(.rule)
        )
        let wiredDock = NetworkAutomationRule(
            triggerKind: .ethernet,
            matchValue: "",
            action: .connect
        )
        let prefs = try NetworkAutomationPreferences(
            isEnabled: true,
            rules: [corpWiFi, homeGateway, wiredDock]
        ).validated()

        #expect(prefs.rules.count == 3)
        #expect(prefs.rules[0].matchValue == "Corp-WiFi")

        // 1. Matching Wi-Fi SSID (case-insensitive)
        let officeEnv = NetworkEnvironmentSnapshot(
            interfaceName: "en0",
            isEthernet: false,
            wifiSSID: "corp-wifi",
            gatewayAddress: "10.0.0.1"
        )
        #expect(prefs.matchedAction(for: officeEnv) == .setRoutingMode(.direct))

        // 2. Matching router gateway IPv4 when Wi-Fi SSID is unavailable (no Location permission)
        let homeEnv = NetworkEnvironmentSnapshot(
            interfaceName: "en0",
            isEthernet: false,
            wifiSSID: nil,
            gatewayAddress: "192.168.50.1"
        )
        #expect(prefs.matchedAction(for: homeEnv) == .setRoutingMode(.rule))

        // 3. Matching wired Ethernet dock
        let dockEnv = NetworkEnvironmentSnapshot(
            interfaceName: "en7",
            isEthernet: true,
            wifiSSID: nil,
            gatewayAddress: "172.16.0.1"
        )
        #expect(prefs.matchedAction(for: dockEnv) == .connect)

        // 4. Invalid gateway IP or empty SSID must fail validation
        #expect(throws: AppAutomationPreferencesError.invalidNetworkRule) {
            try NetworkAutomationRule(
                triggerKind: .wifiSSID,
                matchValue: "   ",
                action: .disconnect
            ).validated()
        }
        #expect(throws: AppAutomationPreferencesError.invalidNetworkRule) {
            try NetworkAutomationRule(
                triggerKind: .gatewayAddress,
                matchValue: "not-an-ip",
                action: .disconnect
            ).validated()
        }
    }

    @Test
    func networkAutomationPreferenceStoreRoundTrips() throws {
        let suite = "NetworkAutomationPreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = NetworkAutomationPreferenceStore(defaults: defaults)
        let rule = try NetworkAutomationRule(
            triggerKind: .gatewayAddress,
            matchValue: "192.168.1.1",
            action: .setRoutingMode(.global)
        ).validated()
        let expected = try NetworkAutomationPreferences(isEnabled: true, rules: [rule]).validated()

        try store.save(expected)
        #expect(store.load() == expected)
    }
}

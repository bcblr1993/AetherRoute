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
}

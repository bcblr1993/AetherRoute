import Foundation
import Testing
@testable import AetherRouteKit

@Suite(.serialized)
struct AppLanguagePreferenceTests {
    @Test
    func defaultsToSystemAndExposesOnlySupportedLocales() throws {
        let suite = "AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppLanguagePreferenceStore(defaults: defaults)
        #expect(store.load() == .system)
        #expect(AppLanguagePreference.system.localeIdentifier == nil)
        #expect(
            AppLanguagePreference.simplifiedChinese.localeIdentifier
                == "zh-Hans"
        )
        #expect(AppLanguagePreference.english.localeIdentifier == "en")
    }

    @Test
    func roundTripsEverySupportedPreference() throws {
        let suite = "AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppLanguagePreferenceStore(defaults: defaults)

        for preference in AppLanguagePreference.allCases {
            store.save(preference)
            #expect(store.load() == preference)
        }
    }

    @Test
    func corruptedPreferenceFailsClosedToSystem() throws {
        let suite = "AppLanguagePreferenceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unsupported-locale", forKey: AppLanguagePreferenceStore.storageKey)

        #expect(
            AppLanguagePreferenceStore(defaults: defaults).load() == .system
        )
    }
}

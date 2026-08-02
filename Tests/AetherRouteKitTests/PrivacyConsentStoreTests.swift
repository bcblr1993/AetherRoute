import Foundation
import XCTest
@testable import AetherRouteKit

final class PrivacyConsentStoreTests: XCTestCase {
    func testConsentIsRequiredUntilCurrentDisclosureIsAccepted() throws {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }

        XCTAssertFalse(store.hasAcceptedCurrentDisclosure)
        XCTAssertNil(store.acceptedDisclosureVersion)
        XCTAssertThrowsError(try store.requireCurrentConsent()) { error in
            XCTAssertEqual(error as? PrivacyConsentError, .required)
        }

        store.acceptCurrentDisclosure()

        XCTAssertTrue(store.hasAcceptedCurrentDisclosure)
        XCTAssertEqual(
            store.acceptedDisclosureVersion,
            PrivacyConsentStore.currentDisclosureVersion
        )
        XCTAssertNoThrow(try store.requireCurrentConsent())
    }

    func testAcceptancePersistsAcrossStoreInstances() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }

        store.acceptCurrentDisclosure()
        let reloaded = PrivacyConsentStore(defaults: defaults, key: testKey)

        XCTAssertTrue(reloaded.hasAcceptedCurrentDisclosure)
    }

    func testOlderDisclosureAcceptanceDoesNotUnlockCurrentGate() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }
        defaults.set(
            PrivacyConsentStore.currentDisclosureVersion - 1,
            forKey: testKey
        )

        XCTAssertFalse(store.hasAcceptedCurrentDisclosure)
        XCTAssertThrowsError(try store.requireCurrentConsent())
    }

    private let testKey = "testPrivacyDisclosureAcceptedVersion"

    private func makeStore() -> (UserDefaults, PrivacyConsentStore) {
        let name = "PrivacyConsentStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(name, forKey: "testSuiteName")
        return (defaults, PrivacyConsentStore(defaults: defaults, key: testKey))
    }

    private func suiteName(for defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName")!
    }
}

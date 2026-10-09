import Foundation
import XCTest
@testable import AetherRouteKit

final class ConnectionIntentStoreTests: XCTestCase {
    func testShutdownCallbacksDoNotOverwriteConnectedIntentAfterProviderStops() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }
        store.save(intendedConnected: true)
        store.saveForApplicationTermination(
            managerIsActive: true, userIntendsToConnect: true, alreadyTerminating: false
        )
        store.saveForApplicationTermination(
            managerIsActive: false, userIntendsToConnect: false, alreadyTerminating: true
        )
        let relaunched = ConnectionIntentStore(defaults: defaults, key: testKey)
        XCTAssertTrue(relaunched.wasConnected)
    }

    func testSystemStoppingProviderBeforeAppPreservesStandingIntent() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }
        store.save(intendedConnected: true)
        store.saveForApplicationTermination(
            managerIsActive: false, userIntendsToConnect: false, alreadyTerminating: false
        )
        XCTAssertTrue(store.wasConnected)
    }

    func testExplicitDisconnectStaysDisconnectedAcrossTermination() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }
        store.save(intendedConnected: true)
        store.save(intendedConnected: false)
        store.saveForApplicationTermination(
            managerIsActive: true, userIntendsToConnect: false, alreadyTerminating: false
        )
        XCTAssertFalse(store.wasConnected)
    }

    func testExistingActiveConnectionWithoutSavedIntentIsRestored() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }
        store.saveForApplicationTermination(
            managerIsActive: true, userIntendsToConnect: false, alreadyTerminating: false
        )
        XCTAssertTrue(store.wasConnected)
    }

    func testDefaultConnectionIntentIsFalse() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }

        XCTAssertFalse(store.wasConnected)
    }

    func testSavePersistsConnectionIntentAcrossInstances() {
        let (defaults, store) = makeStore()
        defer { defaults.removePersistentDomain(forName: suiteName(for: defaults)) }

        store.save(intendedConnected: true)
        XCTAssertTrue(store.wasConnected)

        let reloaded = ConnectionIntentStore(defaults: defaults, key: testKey)
        XCTAssertTrue(reloaded.wasConnected)

        store.save(intendedConnected: false)
        XCTAssertFalse(store.wasConnected)
        XCTAssertFalse(reloaded.wasConnected)
    }

    private let testKey = "testLastConnectionIntent"

    private func makeStore() -> (UserDefaults, ConnectionIntentStore) {
        let name = "ConnectionIntentStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set(name, forKey: "testSuiteName")
        return (defaults, ConnectionIntentStore(defaults: defaults, key: testKey))
    }

    private func suiteName(for defaults: UserDefaults) -> String {
        defaults.string(forKey: "testSuiteName")!
    }
}

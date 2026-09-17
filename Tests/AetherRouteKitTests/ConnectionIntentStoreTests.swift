import Foundation
import XCTest
@testable import AetherRouteKit

final class ConnectionIntentStoreTests: XCTestCase {
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

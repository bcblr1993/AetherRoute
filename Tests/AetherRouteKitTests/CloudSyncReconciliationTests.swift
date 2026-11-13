import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class CloudSyncReconciliationTests: XCTestCase {
    private final class InMemoryKVS: CloudKeyValueStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func synchronize() -> Bool { true }

        func data(forKey defaultName: String) -> Data? {
            lock.withLock { storage[defaultName] }
        }

        func set(_ value: Any?, forKey defaultName: String) {
            lock.withLock { storage[defaultName] = value as? Data }
        }
    }

    private final class ThreadCheckingKeyStore: ProfileKeyStoring, @unchecked Sendable {
        private let inner = InMemoryProfileKeyStore()
        private let lock = NSLock()
        private(set) var loadKeyOnMainThreadCount = 0
        private(set) var loadOrCreateKeyOnMainThreadCount = 0

        func loadOrCreateKey(keyID: String) throws -> Data {
            if Thread.isMainThread {
                lock.withLock { loadOrCreateKeyOnMainThreadCount += 1 }
            }
            return try inner.loadOrCreateKey(keyID: keyID)
        }

        func loadKey(keyID: String) throws -> Data {
            if Thread.isMainThread {
                lock.withLock { loadKeyOnMainThreadCount += 1 }
            }
            return try inner.loadKey(keyID: keyID)
        }

        func resetTracking() {
            lock.withLock {
                loadKeyOnMainThreadCount = 0
                loadOrCreateKeyOnMainThreadCount = 0
            }
        }
    }

    private func validYAML(server: String) -> String {
        """
        proxies:
          - {name: Edge-1, type: ss, server: \(server), port: 443, cipher: aes-128-gcm, password: test}
        """
    }

    @MainActor
    func testSyncRefreshesExistingProfileInPlaceWithoutDuplicatesAcrossDevices() async throws {
        let kvs = InMemoryKVS()
        let keyStore = InMemoryProfileKeyStore()
        let macADir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-macA-\(UUID().uuidString)")
        let macBDir = FileManager.default.temporaryDirectory.appendingPathComponent("sync-macB-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: macADir)
            try? FileManager.default.removeItem(at: macBDir)
        }

        let storeA = ProfileCatalogStore(directoryURL: macADir, keyStore: keyStore)
        let storeB = ProfileCatalogStore(directoryURL: macBDir, keyStore: keyStore)

        let subURL = URL(string: "https://sub.example.com/clash?token=abc")!
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let sub1 = try ProfileSubscription(url: subURL, lastUpdatedAt: t1)
        let catalogA = try storeA.addValidated(
            data: Data(validYAML(server: "1.1.1.1").utf8),
            suggestedName: "Main Sub",
            importedAt: t1,
            subscription: sub1
        )
        let profileID = try XCTUnwrap(catalogA.activeProfileID)

        let managerA = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: storeA,
            deviceIdentifier: "mac-a",
            deviceName: "Mac A"
        )
        managerA.isCloudSyncEnabled = true
        _ = try await managerA.forcePushToCloud()

        let managerB = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: storeB,
            deviceIdentifier: "mac-b",
            deviceName: "Mac B"
        )
        managerB.isCloudSyncEnabled = true
        _ = try await managerB.sync()

        let initialB = try storeB.loadOrMigrate()
        XCTAssertEqual(initialB.profiles.map(\.id), [profileID])

        // Mac A refreshes the subscription at t2 > t1
        let t2 = Date(timeIntervalSince1970: 1_700_003_600)
        let sub2 = try ProfileSubscription(url: subURL, lastUpdatedAt: t2)
        try storeA.replace(
            id: profileID,
            with: ActiveProfile(
                name: "Main Sub",
                yaml: validYAML(server: "2.2.2.2"),
                importedAt: t1,
                subscription: sub2
            )
        )
        _ = try await managerA.forcePushToCloud()

        // Mac B syncs: must update in place with the SAME UUID, no duplicate!
        _ = try await managerB.sync()
        let updatedB = try storeB.loadOrMigrate()
        XCTAssertEqual(updatedB.profiles.count, 1, "Updated profile must not be duplicated")
        XCTAssertEqual(updatedB.profiles.first?.id, profileID, "Updated profile must preserve its UUID")
        XCTAssertTrue(updatedB.profiles.first?.profile.yaml.contains("2.2.2.2") ?? false)
    }

    @MainActor
    func testDeletedProfileStaysDeletedAcrossDevicesAndIsNotResurrected() async throws {
        let kvs = InMemoryKVS()
        let keyStore = InMemoryProfileKeyStore()
        let macADir = FileManager.default.temporaryDirectory.appendingPathComponent("del-macA-\(UUID().uuidString)")
        let macBDir = FileManager.default.temporaryDirectory.appendingPathComponent("del-macB-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: macADir)
            try? FileManager.default.removeItem(at: macBDir)
        }

        let storeA = ProfileCatalogStore(directoryURL: macADir, keyStore: keyStore)
        let storeB = ProfileCatalogStore(directoryURL: macBDir, keyStore: keyStore)

        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        _ = try storeA.addValidated(
            data: Data(validYAML(server: "1.1.1.1").utf8),
            suggestedName: "Keep Me",
            importedAt: t1
        )
        let addedTwo = try storeA.addValidated(
            data: Data(validYAML(server: "2.2.2.2").utf8),
            suggestedName: "Delete Me",
            importedAt: t1,
            makeActive: false
        )
        let deleteID = try XCTUnwrap(addedTwo.profiles.first { $0.profile.name == "Delete Me" }?.id)

        let managerA = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: storeA,
            deviceIdentifier: "mac-a",
            deviceName: "Mac A"
        )
        managerA.isCloudSyncEnabled = true
        _ = try await managerA.forcePushToCloud()

        let managerB = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: storeB,
            deviceIdentifier: "mac-b",
            deviceName: "Mac B"
        )
        managerB.isCloudSyncEnabled = true
        _ = try await managerB.sync()
        XCTAssertEqual(try storeB.loadOrMigrate().profiles.count, 2)

        // Mac A deletes "Delete Me" and pushes
        _ = try storeA.remove(id: deleteID)
        _ = try await managerA.forcePushToCloud()

        // Mac B syncs: "Delete Me" must be removed from Mac B and NOT resurrected back to cloud
        _ = try await managerB.sync()
        let catalogB = try storeB.loadOrMigrate()
        XCTAssertEqual(catalogB.profiles.map(\.profile.name), ["Keep Me"])

        // Mac A syncs again: still only "Keep Me"
        _ = try await managerA.sync()
        let catalogA = try storeA.loadOrMigrate()
        XCTAssertEqual(catalogA.profiles.map(\.profile.name), ["Keep Me"])
    }

    @MainActor
    func testProfileCloudSyncOffloadsKeychainWorkOffMainActor() async throws {
        let kvs = InMemoryKVS()
        let keyStore = ThreadCheckingKeyStore()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("offload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProfileCatalogStore(directoryURL: dir, keyStore: keyStore)
        _ = try store.addValidated(
            data: Data(validYAML(server: "1.1.1.1").utf8),
            suggestedName: "Main Thread Check"
        )

        let manager = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: store,
            deviceIdentifier: "mac-offload",
            deviceName: "Mac Offload"
        )
        keyStore.resetTracking()

        manager.isCloudSyncEnabled = true
        _ = try await manager.forcePushToCloud()
        XCTAssertEqual(keyStore.loadOrCreateKeyOnMainThreadCount, 0, "forcePushToCloud must not load/create Keychain key on @MainActor")
        XCTAssertEqual(keyStore.loadKeyOnMainThreadCount, 0, "forcePushToCloud diagnostics/sync must not load Keychain key on @MainActor")

        keyStore.resetTracking()
        _ = try await manager.forcePullFromCloud()
        XCTAssertEqual(keyStore.loadKeyOnMainThreadCount, 0, "forcePullFromCloud must not load Keychain key on @MainActor")
    }

    func testManagedProfileUpdatedAtDecodesSafelyFromLegacyJSON() throws {
        let legacyID = UUID()
        let importedAt = Date(timeIntervalSince1970: 1_750_000_000)
        let subUpdatedAt = Date(timeIntervalSince1970: 1_760_000_000)

        let legacyWithoutSub = ManagedProfile(
            id: legacyID,
            profile: ActiveProfile(name: "Legacy", yaml: validYAML(server: "1.1.1.1"), importedAt: importedAt)
        )
        let encodedNoUpdatedAt = """
        {"id":"\(legacyID.uuidString)","profile":{"formatVersion":1,"name":"Legacy","yaml":"proxies: []","importedAt":\(importedAt.timeIntervalSinceReferenceDate)}}
        """.data(using: .utf8)!
        let decodedNoSub = try JSONDecoder().decode(ManagedProfile.self, from: encodedNoUpdatedAt)
        XCTAssertEqual(decodedNoSub.updatedAt, importedAt)
        XCTAssertEqual(legacyWithoutSub.updatedAt, importedAt)

        let withSub = ManagedProfile(
            id: legacyID,
            profile: ActiveProfile(
                name: "Sub",
                yaml: validYAML(server: "1.1.1.1"),
                importedAt: importedAt,
                subscription: try ProfileSubscription(
                    url: URL(string: "https://example.com/sub")!,
                    lastUpdatedAt: subUpdatedAt
                )
            )
        )
        XCTAssertEqual(withSub.updatedAt, subUpdatedAt)
    }

    func testReconcileCloudSyncByIDAndCanonicalURLUsesLastWriterWinsAndRespectsTombstones() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("reconcile-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let keyStore = InMemoryProfileKeyStore()
        let store = ProfileCatalogStore(directoryURL: dir, keyStore: keyStore)

        let t1 = Date(timeIntervalSince1970: 1_800_000_000)
        let t2 = Date(timeIntervalSince1970: 1_800_001_000)
        let t3 = Date(timeIntervalSince1970: 1_800_002_000)
        let tDelete = Date(timeIntervalSince1970: 1_800_003_000)

        let idByID = UUID()
        let localIDByURL = UUID()
        let remoteIDByURL = UUID()
        let deletedID = UUID()

        let localCatalog = ProfileCatalog(
            activeProfileID: deletedID,
            profiles: [
                ManagedProfile(
                    id: idByID,
                    profile: ActiveProfile(name: "Local Newer", yaml: validYAML(server: "local-new.example"), importedAt: t1),
                    updatedAt: t3
                ),
                ManagedProfile(
                    id: localIDByURL,
                    profile: ActiveProfile(
                        name: "Canonical Sub",
                        yaml: validYAML(server: "old-sub.example"),
                        importedAt: t1,
                        subscription: try ProfileSubscription(url: URL(string: "https://sub.example.com/feed?k=1")!, lastUpdatedAt: t1)
                    ),
                    updatedAt: t1
                ),
                ManagedProfile(
                    id: deletedID,
                    profile: ActiveProfile(name: "To Be Deleted", yaml: validYAML(server: "del.example"), importedAt: t1),
                    updatedAt: t1
                ),
            ]
        )
        try store.replaceCatalog(localCatalog)

        let remoteCatalog = ProfileCatalog(
            activeProfileID: idByID,
            profiles: [
                ManagedProfile(
                    id: idByID,
                    profile: ActiveProfile(name: "Remote Stale", yaml: validYAML(server: "remote-old.example"), importedAt: t1),
                    updatedAt: t2 // older than local t3
                ),
                ManagedProfile(
                    id: remoteIDByURL,
                    profile: ActiveProfile(
                        name: "Canonical Sub Updated",
                        yaml: validYAML(server: "new-sub.example"),
                        importedAt: t1,
                        subscription: try ProfileSubscription(url: URL(string: "HTTPS://SUB.EXAMPLE.COM:443/feed?k=1")!, lastUpdatedAt: t2)
                    ),
                    updatedAt: t2 // newer than local t1
                ),
                ManagedProfile(
                    id: deletedID,
                    profile: ActiveProfile(name: "To Be Deleted", yaml: validYAML(server: "del.example"), importedAt: t1),
                    updatedAt: t1 // older than tombstone tDelete
                ),
            ]
        )

        let reconciled = try store.reconcileCloudSync(
            remoteCatalog,
            tombstones: [deletedID: tDelete]
        )

        XCTAssertEqual(reconciled.profiles.count, 2)
        XCTAssertEqual(reconciled.profiles.map(\.id), [idByID, localIDByURL], "Canonical URL match must preserve local UUID")
        XCTAssertEqual(reconciled.profiles[0].profile.name, "Local Newer", "Newer local edit must win over older remote")
        XCTAssertEqual(reconciled.profiles[1].profile.name, "Canonical Sub Updated", "Newer remote subscription must update local in place")
        XCTAssertTrue(reconciled.profiles[1].profile.yaml.contains("new-sub.example"))
        XCTAssertEqual(reconciled.activeProfileID, idByID, "Active profile must fall back cleanly when previous active was deleted")
        XCTAssertEqual(store.loadDeletedProfiles()[deletedID], tDelete)
    }

    func testCloudSyncCatalogPayloadDecodesLegacyCatalogSafely() throws {
        let catalog = ProfileCatalog(
            activeProfileID: nil,
            profiles: []
        )
        let legacyData = try JSONEncoder().encode(catalog)
        let decoded = ProfileCloudSyncManager.decodeCatalogPayload(from: legacyData)
        XCTAssertEqual(decoded?.catalog, catalog)
        XCTAssertEqual(decoded?.deletedProfiles, [:])

        let deletedID = UUID()
        let deletionDate = Date(timeIntervalSince1970: 1_800_005_000)
        let modernPayload = CloudSyncCatalogPayload(
            catalog: catalog,
            deletedProfiles: [deletedID: deletionDate]
        )
        let modernData = try JSONEncoder().encode(modernPayload)
        let decodedModern = ProfileCloudSyncManager.decodeCatalogPayload(from: modernData)
        XCTAssertEqual(decodedModern, modernPayload)
    }
}

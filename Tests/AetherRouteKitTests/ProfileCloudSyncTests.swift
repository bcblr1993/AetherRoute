import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class ProfileCloudSyncTests: XCTestCase {

    func testCloudSyncPayloadSerialization() throws {
        let fakeData = "Encrypted-Ciphertext-Payload".data(using: .utf8)!
        let payload = CloudSyncPayload(
            version: 1,
            updatedAtUnixMilliseconds: 1700000000000,
            deviceIdentifier: "MacBookPro-M4",
            encryptedData: fakeData,
            sha256: "abc123def456"
        )

        let encoded = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(CloudSyncPayload.self, from: encoded)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.deviceIdentifier, "MacBookPro-M4")
        XCTAssertEqual(decoded.updatedAtUnixMilliseconds, 1700000000000)
        XCTAssertEqual(decoded.encryptedData, fakeData)
        XCTAssertEqual(decoded.sha256, "abc123def456")
    }

    func testSynchronizableProfileKeyStore() {
        let syncStore = DataProtectionProfileKeyStore(
            service: "com.aetherroute.profile-encryption.cloud-sync",
            isSynchronizable: true
        )
        XCTAssertTrue(syncStore.isSynchronizable)

        let localStore = DataProtectionProfileKeyStore(
            service: "com.aetherroute.profile-encryption",
            isSynchronizable: false
        )
        XCTAssertFalse(localStore.isSynchronizable)
    }

    func testSharedKeychainAndKVSResolution() throws {
        let mockInfo: [String: Any] = [
            AppConstants.sharedKeychainAccessGroupInfoKey: "5984KQD4D7.com.aetherroute.shared",
            AppConstants.sharedKVSIdentifierInfoKey: "5984KQD4D7.com.aetherroute.shared.kvstore",
            AppConstants.keychainAccessGroupInfoKey: "5984KQD4D7.com.aetherroute.desktop.shared"
        ]

        let sharedGroup = try AppConstants.sharedKeychainAccessGroup(infoDictionary: mockInfo)
        XCTAssertEqual(sharedGroup, "5984KQD4D7.com.aetherroute.shared")

        let fallbackGroup = try AppConstants.sharedKeychainAccessGroup(infoDictionary: [
            AppConstants.keychainAccessGroupInfoKey: "5984KQD4D7.com.aetherroute.desktop.shared"
        ])
        XCTAssertEqual(fallbackGroup, "5984KQD4D7.com.aetherroute.desktop.shared")

        let sharedKVS = AppConstants.sharedKVSIdentifier(bundle: .main)
        XCTAssertTrue(sharedKVS == nil || !sharedKVS!.isEmpty)
    }

    func testCloudSyncPayloadEncryptionAndDecryptionRoundTrip() throws {
        let keyStore = InMemoryProfileKeyStore()
        let masterKey = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        XCTAssertEqual(masterKey.count, 32)

        let catalog = ProfileCatalog(
            activeProfileID: UUID(),
            profiles: [
                ManagedProfile(
                    profile: ActiveProfile(
                        name: "Mac Sync Node",
                        yaml: "proxies:\n  - {name: Edge-1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: test}\n"
                    )
                )
            ]
        )

        let catalogData = try JSONEncoder().encode(catalog)
        let symmetricKey = SymmetricKey(data: masterKey)

        // Encrypt with AES-256-GCM
        let sealedBox = try AES.GCM.seal(catalogData, using: symmetricKey)
        guard let combined = sealedBox.combined else {
            XCTFail("Failed to produce combined ciphertext")
            return
        }

        let sha256 = SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
        let payload = CloudSyncPayload(
            deviceIdentifier: "mac-test-device",
            encryptedData: combined,
            sha256: sha256
        )

        // Decrypt
        let receivedSealedBox = try AES.GCM.SealedBox(combined: payload.encryptedData)
        let decryptedData = try AES.GCM.open(receivedSealedBox, using: symmetricKey)
        let decryptedCatalog = try JSONDecoder().decode(ProfileCatalog.self, from: decryptedData)

        XCTAssertEqual(decryptedCatalog.profiles.count, 1)
        XCTAssertEqual(decryptedCatalog.profiles.first?.profile.name, "Mac Sync Node")
    }

    func testNotificationNameDefined() {
        XCTAssertEqual(
            Notification.Name.aetherRouteCloudSyncDidUpdateProfiles.rawValue,
            "com.aetherroute.cloudSyncDidUpdateProfiles"
        )
    }

    func testValidateSharedKeychainAccessGroupSuccess() throws {
        let validated = try AppConstants.validateKeychainAccessGroup("5984KQD4D7.com.aetherroute.shared")
        XCTAssertEqual(validated, "5984KQD4D7.com.aetherroute.shared")

        let localValidated = try AppConstants.validateKeychainAccessGroup("5984KQD4D7.com.aetherroute.desktop.shared")
        XCTAssertEqual(localValidated, "5984KQD4D7.com.aetherroute.desktop.shared")
    }

    func testValidateSharedKeychainAccessGroupRejectsInvalidSuffix() {
        XCTAssertThrowsError(
            try AppConstants.validateKeychainAccessGroup("5984KQD4D7.com.aetherroute.unknown")
        ) { error in
            XCTAssertEqual(
                error as? KeychainAccessGroupResolutionError,
                .unexpectedSuffix("5984KQD4D7.com.aetherroute.unknown")
            )
        }
    }

    func testCloudSyncPayloadSHA256IntegrityFailure() throws {
        let fakeData = "Encrypted-Ciphertext-Payload".data(using: .utf8)!
        let correctSHA = SHA256.hash(data: fakeData).map { String(format: "%02x", $0) }.joined()
        let corruptedSHA = "0000000000000000000000000000000000000000000000000000000000000000"

        let payload = CloudSyncPayload(
            deviceIdentifier: "test-device",
            encryptedData: fakeData,
            sha256: corruptedSHA
        )

        let actualSHA = SHA256.hash(data: payload.encryptedData).map { String(format: "%02x", $0) }.joined()
        XCTAssertNotEqual(actualSHA, payload.sha256)
        XCTAssertEqual(actualSHA, correctSHA)
    }

    func testUserRulesSnapshotEncryptionAndSmartMergeRoundTrip() throws {
        let keyStore = InMemoryProfileKeyStore()
        _ = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)

        let remoteCustomRules = [
            CustomRule(kind: .geoSite, value: "openai", target: .proxy("AI-Group")),
            CustomRule(kind: .dstPort, value: "443", target: .direct),
            CustomRule(kind: .domainSuffix, value: "apple.com", target: .direct),
        ]
        let remoteBypassPolicy = try BypassPolicy(rules: [
            BypassRule(kind: .domainSuffix, value: "corp.internal"),
            BypassRule(kind: .ipv4CIDR, value: "10.20.0.0/16"),
        ]).validated()

        let remoteSnapshot = CloudSyncUserRulesSnapshot(
            customRules: remoteCustomRules,
            bypassPolicy: remoteBypassPolicy
        )
        let encryptedPayload = try ProfileCloudSyncManager.encryptUserRulesSnapshot(
            remoteSnapshot,
            deviceIdentifier: "iPad-Pro-M4",
            keyStore: keyStore
        )

        let localCustomRules = [
            CustomRule(kind: .domainSuffix, value: "apple.com", target: .direct),
            CustomRule(kind: .ipCIDR, value: "100.64.0.0/10", target: .direct, noResolve: true),
        ]
        let localBypassPolicy = try BypassPolicy(rules: [
            BypassRule(kind: .domainSuffix, value: "corp.internal"),
            BypassRule(kind: .domainSuffix, value: "home.arpa"),
        ]).validated()

        let merged = try ProfileCloudSyncManager.decryptAndMergeUserRulesSnapshot(
            encryptedPayload,
            localRules: localCustomRules,
            localBypassPolicy: localBypassPolicy,
            keyStore: keyStore
        )

        // Deduplicated union of local (2) + remote (3, 1 overlapping) = 4 custom rules
        XCTAssertEqual(merged.customRules.count, 4)
        XCTAssertEqual(merged.customRules[0].value, "apple.com")
        XCTAssertEqual(merged.customRules[1].value, "100.64.0.0/10")
        XCTAssertEqual(merged.customRules[2].kind, .geoSite)
        XCTAssertEqual(merged.customRules[2].value, "openai")
        XCTAssertEqual(merged.customRules[3].kind, .dstPort)
        XCTAssertEqual(merged.customRules[3].value, "443")

        // Deduplicated union of local (2) + remote (2, 1 overlapping) = 3 bypass rules
        XCTAssertEqual(merged.bypassPolicy.rules.count, 3)
        XCTAssertEqual(merged.bypassPolicy.domains, ["corp.internal", "home.arpa"])
        XCTAssertEqual(merged.bypassPolicy.ipv4CIDRs, ["10.20.0.0/16"])
    }

    // MARK: - Deletions and edits across devices (1.8.7)

    private func roundTrip(
        _ snapshot: CloudSyncUserRulesSnapshot,
        intoLocal rules: [CustomRule],
        metadata: RuleSyncMetadata,
        bypass: BypassPolicy = .empty,
        bypassSync: RuleSyncMetadata = .empty,
        keyStore: InMemoryProfileKeyStore
    ) throws -> CloudSyncUserRulesSnapshot {
        let payload = try ProfileCloudSyncManager.encryptUserRulesSnapshot(
            snapshot, deviceIdentifier: "other-mac", keyStore: keyStore
        )
        return try ProfileCloudSyncManager.decryptAndMergeUserRulesSnapshot(
            payload,
            localRules: rules,
            localBypassPolicy: bypass,
            localCustomRuleSync: metadata,
            localBypassSync: bypassSync,
            keyStore: keyStore
        )
    }

    func testDeletedRuleStaysDeletedOnBothDevices() throws {
        let keyStore = InMemoryProfileKeyStore()
        _ = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        let kept = CustomRule(kind: .domainSuffix, value: "kept.example", target: .direct)
        let removed = CustomRule(kind: .domainSuffix, value: "removed.example", target: .direct)

        // Mac A deletes `removed`; Mac B still has both, with no metadata
        // (as written by 1.8.6).
        var macA = RuleSyncMetadata.empty
        macA.recordChanges(from: [kept, removed], to: [kept])
        let onA = try roundTrip(
            CloudSyncUserRulesSnapshot(customRules: [kept, removed]),
            intoLocal: [kept], metadata: macA, keyStore: keyStore
        )
        XCTAssertEqual(onA.customRules.map(\.id), [kept.id])

        // B merges what A published: the deletion reaches B too.
        let onB = try roundTrip(onA, intoLocal: [kept, removed], metadata: .empty, keyStore: keyStore)
        XCTAssertEqual(onB.customRules.map(\.id), [kept.id])
        // And A, merging B's result again, still does not restore it.
        let again = try roundTrip(onB, intoLocal: [kept], metadata: onA.customRuleSync ?? .empty, keyStore: keyStore)
        XCTAssertEqual(again.customRules.map(\.id), [kept.id])
    }

    func testNewerEditOfTheSameRuleWins() throws {
        let keyStore = InMemoryProfileKeyStore()
        _ = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        let original = CustomRule(kind: .domainSuffix, value: "edited.example", target: .direct)
        var proxied = original
        proxied.target = .proxy("Proxy")
        let older = Date(timeIntervalSince1970: 1_000)
        let newer = Date(timeIntervalSince1970: 2_000)

        var local = RuleSyncMetadata.empty
        local.recordChanges(from: [], to: [original], at: older)
        var remote = RuleSyncMetadata.empty
        remote.recordChanges(from: [], to: [proxied], at: newer)
        let merged = try roundTrip(
            CloudSyncUserRulesSnapshot(customRules: [proxied], customRuleSync: remote),
            intoLocal: [original], metadata: local, keyStore: keyStore
        )
        XCTAssertEqual(merged.customRules, [proxied])

        // The local edit wins when it is the newer one.
        let mergedBack = try roundTrip(
            CloudSyncUserRulesSnapshot(customRules: [original], customRuleSync: local),
            intoLocal: [proxied], metadata: remote, keyStore: keyStore
        )
        XCTAssertEqual(mergedBack.customRules, [proxied])
    }

    func testSameMatchWithAnotherTargetIsNotDuplicated() throws {
        let keyStore = InMemoryProfileKeyStore()
        _ = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        let local = CustomRule(kind: .domainSuffix, value: "Example.com", target: .direct)
        let remote = CustomRule(kind: .domainSuffix, value: "example.com", target: .reject)
        let merged = try roundTrip(
            CloudSyncUserRulesSnapshot(customRules: [remote]),
            intoLocal: [local], metadata: .empty, keyStore: keyStore
        )
        XCTAssertEqual(merged.customRules.map(\.id), [local.id])
    }

    func testBypassRuleDeletionSurvivesSync() throws {
        let keyStore = InMemoryProfileKeyStore()
        _ = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        let kept = try BypassRule(kind: .domainSuffix, value: "kept.internal")
        let removed = try BypassRule(kind: .domainSuffix, value: "removed.internal")
        var sync = RuleSyncMetadata.empty
        sync.recordChanges(from: [kept, removed], to: [kept])
        let merged = try roundTrip(
            CloudSyncUserRulesSnapshot(bypassPolicy: try BypassPolicy(rules: [kept, removed]).validated()),
            intoLocal: [], metadata: .empty,
            bypass: try BypassPolicy(rules: [kept]).validated(), bypassSync: sync,
            keyStore: keyStore
        )
        XCTAssertEqual(merged.bypassPolicy.rules.map(\.id), [kept.id])
    }

    func testStoreRecordsDeletionsButNotSynchronizedWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CustomRuleStore(directoryURL: directory)
        let first = CustomRule(kind: .domainSuffix, value: "a.example", target: .direct)
        let second = CustomRule(kind: .domainSuffix, value: "b.example", target: .direct)
        try store.save([first, second])
        try store.delete(id: second.id)
        let metadata = store.loadSyncMetadata()
        XCTAssertNotNil(metadata.deletedAt[second.id.uuidString])
        XCTAssertNotNil(metadata.modifiedAt[first.id.uuidString])

        // A synchronized write keeps exactly the metadata it was given.
        try store.saveSynchronized([first], metadata: .empty)
        XCTAssertEqual(store.loadSyncMetadata(), .empty)
        // Reordering is not an edit.
        try store.save([first, second])
        let stamped = store.loadSyncMetadata().modifiedAt[first.id.uuidString]
        try store.save([second, first])
        XCTAssertEqual(store.loadSyncMetadata().modifiedAt[first.id.uuidString], stamped)
    }
}

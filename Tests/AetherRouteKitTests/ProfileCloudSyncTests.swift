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
}

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
}

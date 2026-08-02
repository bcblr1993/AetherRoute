import Foundation
import Security
import XCTest
@testable import AetherRouteKit

final class ProfileKeyStoreTests: XCTestCase {
    private let sharedAccessGroup =
        "TESTTEAMID.com.aetherroute.desktop.shared"

    func testResolvesExpandedAccessGroupFromExecutableInfo() throws {
        XCTAssertEqual(
            try AppConstants.keychainAccessGroup(
                infoDictionary: [
                    AppConstants.keychainAccessGroupInfoKey:
                        sharedAccessGroup,
                ]
            ),
            sharedAccessGroup
        )
        XCTAssertNotEqual(sharedAccessGroup, AppConstants.appGroup)
    }

    func testRejectsMissingOrUnexpandedAccessGroupInfo() {
        XCTAssertThrowsError(
            try AppConstants.keychainAccessGroup(infoDictionary: [:])
        ) { error in
            XCTAssertEqual(
                error as? KeychainAccessGroupResolutionError,
                .missingInfoValue
            )
        }

        let placeholder =
            "$(AppIdentifierPrefix)\(AppConstants.keychainAccessGroupSuffix)"
        XCTAssertThrowsError(
            try AppConstants.keychainAccessGroup(
                infoDictionary: [
                    AppConstants.keychainAccessGroupInfoKey: placeholder,
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainAccessGroupResolutionError,
                .unresolvedBuildSetting(placeholder)
            )
        }

        XCTAssertThrowsError(
            try AppConstants.keychainAccessGroup(
                infoDictionary: [
                    AppConstants.keychainAccessGroupInfoKey:
                        AppConstants.keychainAccessGroupSuffix,
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainAccessGroupResolutionError,
                .unexpectedSuffix(AppConstants.keychainAccessGroupSuffix)
            )
        }

        XCTAssertThrowsError(
            try AppConstants.validateKeychainAccessGroup(
                AppConstants.appGroup
            )
        ) { error in
            XCTAssertEqual(
                error as? KeychainAccessGroupResolutionError,
                .unexpectedSuffix(AppConstants.appGroup)
            )
        }
    }

    func testProductionStoreUsesDataProtectionKeychainAttributes() throws {
        let candidate = Data(repeating: 0x81, count: 32)
        var addQuery: [String: Any]?
        let operations = ProfileKeyStoreOperations(
            copyMatching: { _ in (errSecItemNotFound, nil) },
            add: { query in
                addQuery = query
                return errSecSuccess
            },
            randomData: { _ in candidate }
        )
        let store = DataProtectionProfileKeyStore(
            accessGroup: sharedAccessGroup,
            service: DataProtectionProfileKeyStore.defaultService,
            operations: operations
        )

        XCTAssertEqual(
            try store.loadOrCreateKey(
                keyID: EncryptedProfileCodec.defaultKeyID
            ),
            candidate
        )

        let query = try XCTUnwrap(addQuery)
        XCTAssertEqual(
            query[kSecAttrAccessGroup as String] as? String,
            sharedAccessGroup
        )
        XCTAssertNotEqual(
            query[kSecAttrAccessGroup as String] as? String,
            AppConstants.appGroup
        )
        XCTAssertEqual(
            query[kSecAttrSynchronizable as String] as? Bool,
            false
        )
        XCTAssertEqual(
            query[kSecUseDataProtectionKeychain as String] as? Bool,
            true
        )
        XCTAssertEqual(
            query[kSecAttrAccessible as String] as? String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
        XCTAssertEqual(
            query[kSecAttrService as String] as? String,
            DataProtectionProfileKeyStore.defaultService
        )
        XCTAssertEqual(
            query[kSecAttrAccount as String] as? String,
            EncryptedProfileCodec.defaultKeyID
        )
    }

    func testDuplicateAddFromConcurrentCreatorReloadsWinningKey() throws {
        let losingCandidate = Data(repeating: 0x91, count: 32)
        let winningKey = Data(repeating: 0xA2, count: 32)
        var copyCount = 0
        let operations = ProfileKeyStoreOperations(
            copyMatching: { _ in
                copyCount += 1
                if copyCount == 1 {
                    return (errSecItemNotFound, nil)
                }
                return (errSecSuccess, winningKey)
            },
            add: { _ in errSecDuplicateItem },
            randomData: { _ in losingCandidate }
        )
        let store = DataProtectionProfileKeyStore(
            accessGroup: sharedAccessGroup,
            service: DataProtectionProfileKeyStore.defaultService,
            operations: operations
        )

        let loaded = try store.loadOrCreateKey(
            keyID: EncryptedProfileCodec.defaultKeyID
        )

        XCTAssertEqual(loaded, winningKey)
        XCTAssertEqual(copyCount, 2)
        XCTAssertNotEqual(loaded, losingCandidate)
    }

    func testLoadNeverCreatesMissingKey() {
        var addCount = 0
        let operations = ProfileKeyStoreOperations(
            copyMatching: { _ in (errSecItemNotFound, nil) },
            add: { _ in
                addCount += 1
                return errSecSuccess
            },
            randomData: { _ in Data(repeating: 0xB3, count: 32) }
        )
        let store = DataProtectionProfileKeyStore(
            accessGroup: sharedAccessGroup,
            service: DataProtectionProfileKeyStore.defaultService,
            operations: operations
        )

        XCTAssertThrowsError(
            try store.loadKey(keyID: EncryptedProfileCodec.defaultKeyID)
        ) { error in
            XCTAssertEqual(error as? ProfileKeyStoreError, .keyNotFound)
        }
        XCTAssertEqual(addCount, 0)
    }

    func testMissingRuntimeAccessGroupFailsBeforeSecurityQuery() {
        var copyCount = 0
        let store = DataProtectionProfileKeyStore(
            accessGroupResolver: {
                throw KeychainAccessGroupResolutionError.missingInfoValue
            },
            service: DataProtectionProfileKeyStore.defaultService,
            operations: ProfileKeyStoreOperations(
                copyMatching: { _ in
                    copyCount += 1
                    return (errSecItemNotFound, nil)
                },
                add: { _ in errSecSuccess },
                randomData: { _ in Data(repeating: 0xC4, count: 32) }
            )
        )

        XCTAssertThrowsError(
            try store.loadKey(keyID: EncryptedProfileCodec.defaultKeyID)
        ) { error in
            XCTAssertEqual(
                error as? KeychainAccessGroupResolutionError,
                .missingInfoValue
            )
        }
        XCTAssertEqual(copyCount, 0)
    }
}

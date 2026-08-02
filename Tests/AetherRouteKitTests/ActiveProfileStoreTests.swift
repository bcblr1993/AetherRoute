import Foundation
import XCTest
@testable import AetherRouteKit

final class ActiveProfileStoreTests: XCTestCase {
    private let encryptedFilename = "active-profile.v2.json"

    func testRoundTripsValidatedProfileAtomically() throws {
        try withTemporaryDirectory { directory in
            let store = makeStore(directory: directory)
            let data = validProfile(password: "round-trip-password")

            let saved = try store.saveValidated(
                data: data,
                suggestedName: "Office"
            )
            let loaded = try store.loadValidated()

            XCTAssertEqual(saved.formatVersion, loaded.formatVersion)
            XCTAssertEqual(saved.yaml, loaded.yaml)
            XCTAssertEqual(loaded.name, "Office")
        }
    }

    func testEncryptedFileContainsNoProfileOrCredentialSentinel() throws {
        try withTemporaryDirectory { directory in
            let secret = "AETHER-SENTINEL-PASSWORD-7429"
            let store = makeStore(directory: directory)
            try store.saveValidated(
                data: validProfile(password: secret),
                suggestedName: "Sensitive"
            )

            let encryptedURL = directory.appendingPathComponent(
                encryptedFilename
            )
            let stored = try Data(contentsOf: encryptedURL)
            let text = try XCTUnwrap(String(data: stored, encoding: .utf8))

            XCTAssertFalse(text.contains(secret))
            XCTAssertFalse(text.contains("proxies:"))
            XCTAssertFalse(text.contains("server: example.com"))

            let attributes = try FileManager.default.attributesOfItem(
                atPath: encryptedURL.path
            )
            let permissions = try XCTUnwrap(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertEqual(permissions & 0o777, 0o600)

            let resourceValues = try encryptedURL.resourceValues(
                forKeys: [.isExcludedFromBackupKey]
            )
            XCTAssertEqual(resourceValues.isExcludedFromBackup, true)
        }
    }

    func testSubscriptionMetadataIsEncryptedAndRoundTrips() throws {
        try withTemporaryDirectory { directory in
            let secretURL = try XCTUnwrap(
                URL(string: "https://profiles.example/config.yaml?token=AETHER-URL-SECRET")
            )
            let subscription = try ProfileSubscription(
                url: secretURL,
                etag: "\"revision-7\"",
                lastCheckedAt: Date(timeIntervalSince1970: 2_000),
                lastUpdatedAt: Date(timeIntervalSince1970: 1_900)
            )
            let store = makeStore(directory: directory)
            try store.saveValidated(
                data: validProfile(password: "subscription-secret"),
                suggestedName: "Subscribed",
                subscription: subscription
            )

            let encryptedURL = directory.appendingPathComponent(
                encryptedFilename
            )
            let ciphertext = try Data(contentsOf: encryptedURL)
            let text = try XCTUnwrap(String(data: ciphertext, encoding: .utf8))
            XCTAssertFalse(text.contains("AETHER-URL-SECRET"))
            XCTAssertFalse(text.contains("profiles.example"))
            XCTAssertFalse(text.contains("revision-7"))

            let loaded = try store.loadValidated()
            XCTAssertEqual(loaded.subscription, subscription)
        }
    }

    func testRepeatedSaveUsesDifferentNonce() throws {
        try withTemporaryDirectory { directory in
            let store = makeStore(directory: directory)
            let data = validProfile(password: "same-plaintext")
            let encryptedURL = directory.appendingPathComponent(
                encryptedFilename
            )

            try store.saveValidated(data: data, suggestedName: "Same")
            let first = try decodeEnvelope(at: encryptedURL)

            try store.saveValidated(data: data, suggestedName: "Same")
            let second = try decodeEnvelope(at: encryptedURL)

            XCTAssertNotEqual(first.sealedBox, second.sealedBox)
        }
    }

    func testRejectsTamperedCiphertext() throws {
        try withTemporaryDirectory { directory in
            let store = makeStore(directory: directory)
            let encryptedURL = directory.appendingPathComponent(
                encryptedFilename
            )
            try store.saveValidated(
                data: validProfile(password: "tamper-test"),
                suggestedName: "Tamper"
            )

            var envelope = try decodeEnvelope(at: encryptedURL)
            envelope.sealedBox[envelope.sealedBox.startIndex] ^= 0x01
            try JSONEncoder().encode(envelope).write(
                to: encryptedURL,
                options: [.atomic]
            )

            XCTAssertThrowsError(try store.loadValidated()) { error in
                XCTAssertEqual(
                    error as? EncryptedProfileCodecError,
                    .authenticationFailed
                )
            }
        }
    }

    func testRejectsWrongKey() throws {
        try withTemporaryDirectory { directory in
            let writer = makeStore(
                directory: directory,
                key: key(byte: 0x11)
            )
            try writer.saveValidated(
                data: validProfile(password: "wrong-key-test"),
                suggestedName: "Wrong Key"
            )

            let reader = makeStore(
                directory: directory,
                key: key(byte: 0x22)
            )
            XCTAssertThrowsError(try reader.loadValidated()) { error in
                XCTAssertEqual(
                    error as? EncryptedProfileCodecError,
                    .authenticationFailed
                )
            }
        }
    }

    func testMissingKeyDoesNotOverwriteExistingCiphertext() throws {
        try withTemporaryDirectory { directory in
            let writer = makeStore(directory: directory)
            let encryptedURL = directory.appendingPathComponent(
                encryptedFilename
            )
            try writer.saveValidated(
                data: validProfile(password: "original-password"),
                suggestedName: "Original"
            )
            let before = try Data(contentsOf: encryptedURL)

            let missingKeyStore = InMemoryProfileKeyStore(
                keys: [:],
                keyGenerator: {
                    throw UnexpectedKeyGenerationError()
                }
            )
            let replacement = ActiveProfileStore(
                directoryURL: directory,
                keyStore: missingKeyStore
            )

            XCTAssertThrowsError(
                try replacement.saveValidated(
                    data: validProfile(password: "replacement-password"),
                    suggestedName: "Replacement"
                )
            ) { error in
                XCTAssertEqual(error as? ProfileKeyStoreError, .keyNotFound)
            }
            XCTAssertEqual(try Data(contentsOf: encryptedURL), before)
        }
    }

    func testRejectsInvalidProfileBeforeCreatingEncryptedFile() throws {
        try withTemporaryDirectory { directory in
            let store = makeStore(directory: directory)

            XCTAssertThrowsError(
                try store.saveValidated(
                    data: Data("script:\n  code: unsafe\n".utf8),
                    suggestedName: "Unsafe"
                )
            )
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        encryptedFilename
                    ).path
                )
            )
        }
    }

    func testValidatesDecryptedProfileBeforeReturningIt() throws {
        try withTemporaryDirectory { directory in
            let key = key(byte: 0x44)
            let codec = EncryptedProfileCodec()
            let unsafeProfile = ActiveProfile(
                name: "Tampered",
                yaml: "proxies:\n  - { name: direct, type: direct }\ncommand: whoami\n"
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try codec.seal(unsafeProfile, keyData: key).write(
                to: directory.appendingPathComponent(encryptedFilename),
                options: [.atomic]
            )
            let store = makeStore(directory: directory, key: key)

            XCTAssertThrowsError(try store.loadValidated()) { error in
                XCTAssertEqual(
                    error as? ProfileImportError,
                    .forbiddenExecutableKey("command")
                )
            }
        }
    }

    func testLegacyPlaintextIsRejectedWithoutDeletionOrOverwrite() throws {
        try withTemporaryDirectory { directory in
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let legacyURL = directory.appendingPathComponent(
                "active-profile.json"
            )
            let legacyData = validProfile(password: "legacy-secret")
            try legacyData.write(to: legacyURL, options: [.atomic])
            let store = makeStore(directory: directory)

            XCTAssertThrowsError(try store.loadValidated()) { error in
                XCTAssertEqual(
                    error as? ActiveProfileStoreError,
                    .legacyPlaintextProfileFound
                )
            }
            XCTAssertThrowsError(
                try store.saveValidated(
                    data: validProfile(password: "new-secret"),
                    suggestedName: "New"
                )
            ) { error in
                XCTAssertEqual(
                    error as? ActiveProfileStoreError,
                    .legacyPlaintextProfileFound
                )
            }
            XCTAssertEqual(try Data(contentsOf: legacyURL), legacyData)
            XCTAssertFalse(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        encryptedFilename
                    ).path
                )
            )
        }
    }

    private func makeStore(
        directory: URL,
        key: Data = Data(repeating: 0xA5, count: 32)
    ) -> ActiveProfileStore {
        ActiveProfileStore(
            directoryURL: directory,
            keyStore: InMemoryProfileKeyStore(
                keys: [EncryptedProfileCodec.defaultKeyID: key]
            )
        )
    }

    private func validProfile(password: String) -> Data {
        Data(
            """
            proxies:
              - name: sentinel
                type: trojan
                server: example.com
                port: 443
                password: \(password)
            """.utf8
        )
    }

    private func key(byte: UInt8) -> Data {
        Data(repeating: byte, count: 32)
    }

    private func decodeEnvelope(at url: URL) throws -> EncryptedProfileEnvelope {
        try JSONDecoder().decode(
            EncryptedProfileEnvelope.self,
            from: Data(contentsOf: url)
        )
    }

    private func withTemporaryDirectory(
        _ operation: (URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try operation(directory)
    }
}

private struct UnexpectedKeyGenerationError: Error {}

import Foundation
import XCTest
@testable import AetherRouteKit

final class ProfileCatalogStoreTests: XCTestCase {
    func testMigratesEncryptedActiveProfileWithoutLosingContents() throws {
        try withStores { directory, activeStore, catalogStore in
            let original = try activeStore.saveValidated(
                data: profileData(name: "legacy", secret: "migration-secret"),
                suggestedName: "Existing",
                importedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )

            let catalog = try catalogStore.loadOrMigrate()

            XCTAssertEqual(catalog.profiles.count, 1)
            XCTAssertEqual(catalog.activeProfile?.profile, original)
            XCTAssertEqual(try activeStore.loadValidated(), original)
            XCTAssertTrue(
                FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(
                        ProfileCatalogStore.encryptedFilename
                    ).path
                )
            )
        }
    }

    func testCatalogCiphertextHidesNamesServersAndSubscriptionTokens() throws {
        try withStores { directory, _, catalogStore in
            let url = try XCTUnwrap(
                URL(
                    string: "https://profiles.example/config.yaml?token=CATALOG-TOKEN"
                )
            )
            let subscription = try ProfileSubscription(url: url)
            _ = try catalogStore.addValidated(
                data: profileData(
                    name: "private-edge",
                    secret: "CATALOG-PASSWORD"
                ),
                suggestedName: "Private Office",
                subscription: subscription
            )

            let urlOnDisk = directory.appendingPathComponent(
                ProfileCatalogStore.encryptedFilename
            )
            let stored = try Data(contentsOf: urlOnDisk)
            let text = try XCTUnwrap(String(data: stored, encoding: .utf8))
            XCTAssertFalse(text.contains("Private Office"))
            XCTAssertFalse(text.contains("private-edge"))
            XCTAssertFalse(text.contains("profiles.example"))
            XCTAssertFalse(text.contains("CATALOG-TOKEN"))
            XCTAssertFalse(text.contains("CATALOG-PASSWORD"))

            let attributes = try FileManager.default.attributesOfItem(
                atPath: urlOnDisk.path
            )
            let permissions = try XCTUnwrap(
                (attributes[.posixPermissions] as? NSNumber)?.intValue
            )
            XCTAssertEqual(permissions & 0o777, 0o600)
            XCTAssertEqual(
                try urlOnDisk.resourceValues(
                    forKeys: [.isExcludedFromBackupKey]
                ).isExcludedFromBackup,
                true
            )
        }
    }

    func testAddsAndAtomicallySwitchesActiveMirror() throws {
        try withStores { _, activeStore, catalogStore in
            let first = try catalogStore.addValidated(
                data: profileData(name: "first", secret: "one"),
                suggestedName: "First",
                importedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            let firstID = try XCTUnwrap(first.activeProfileID)
            let second = try catalogStore.addValidated(
                data: profileData(name: "second", secret: "two"),
                suggestedName: "Second",
                importedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
            let secondID = try XCTUnwrap(second.activeProfileID)

            XCTAssertNotEqual(firstID, secondID)
            XCTAssertEqual(second.profiles.count, 2)
            XCTAssertEqual(try activeStore.loadValidated().name, "Second")

            let switched = try catalogStore.activate(id: firstID)
            XCTAssertEqual(switched.activeProfileID, firstID)
            XCTAssertEqual(switched.activeProfile?.profile.name, "First")
            XCTAssertEqual(try activeStore.loadValidated().name, "First")
        }
    }

    func testNativeNodeProfileIsEncryptedBoundAndMirroredAsCoreYAML() throws {
        try withStores { directory, activeStore, catalogStore in
            let node = AetherNode(
                name: "Native Edge",
                protocolID: .http,
                server: "native.example",
                port: 443,
                username: "native-user",
                password: "NATIVE-NODE-SECRET",
                tls: .init(enabled: true, serverName: "native.example")
            )
            let catalog = try catalogStore.addNative(
                nodes: [node],
                suggestedName: "Native Profile"
            )

            XCTAssertEqual(catalog.activeProfile?.profile.nativeNodes, [node])
            XCTAssertEqual(
                catalog.activeProfile?.profile.yaml,
                try AetherNodeProfileCompiler.compile(nodes: [node])
            )
            let mirror = try activeStore.loadValidated()
            XCTAssertEqual(mirror.yaml, catalog.activeProfile?.profile.yaml)
            XCTAssertNil(mirror.nativeNodes)

            let stored = try Data(
                contentsOf: directory.appendingPathComponent(
                    ProfileCatalogStore.encryptedFilename
                )
            )
            let text = try XCTUnwrap(String(data: stored, encoding: .utf8))
            XCTAssertFalse(text.contains("Native Edge"))
            XCTAssertFalse(text.contains("native.example"))
            XCTAssertFalse(text.contains("NATIVE-NODE-SECRET"))

            let renamed = try catalogStore.rename(
                id: try XCTUnwrap(catalog.activeProfileID),
                to: "Renamed Native Profile"
            )
            XCTAssertEqual(renamed.activeProfile?.profile.nativeNodes, [node])
        }
    }

    func testSSHPrivateKeyAndPassphraseNeverAppearInCatalogCiphertext() throws {
        try withStores { directory, _, catalogStore in
            let privateKey = """
            -----BEGIN OPENSSH PRIVATE KEY-----
            U1NILUNBVEFMT0ctVEVTVC1LRVk=
            -----END OPENSSH PRIVATE KEY-----
            """
            let node = AetherNode(
                name: "SSH Encrypted",
                protocolID: .ssh,
                server: "ssh-private.example",
                port: 22,
                username: "private-user",
                privateKey: privateKey,
                privateKeyPassphrase: "PRIVATE-KEY-PASSPHRASE"
            )
            _ = try catalogStore.addNative(
                nodes: [node],
                suggestedName: "SSH Native"
            )

            let stored = try Data(
                contentsOf: directory.appendingPathComponent(
                    ProfileCatalogStore.encryptedFilename
                )
            )
            let text = try XCTUnwrap(String(data: stored, encoding: .utf8))
            XCTAssertFalse(text.contains("SSH Encrypted"))
            XCTAssertFalse(text.contains("ssh-private.example"))
            XCTAssertFalse(text.contains("U1NILUNBVEFMT0ctVEVTVC1LRVk="))
            XCTAssertFalse(text.contains("PRIVATE-KEY-PASSPHRASE"))
        }
    }

    func testRejectsNativeNodeDocumentThatDoesNotMatchCoreYAML() throws {
        let node = AetherNode(
            name: "Native Edge",
            protocolID: .http,
            server: "native.example",
            port: 443
        )
        let profile = ActiveProfile(
            name: "Mismatch",
            yaml: "proxies:\n  - {name: Other, type: direct}\n",
            nativeNodes: [node]
        )

        XCTAssertThrowsError(try profile.validateForStorage()) { error in
            XCTAssertEqual(
                error as? ProfileCatalogStoreError,
                .nativeProfileMismatch
            )
        }
    }

    func testUpdatesNativeNodesAndActiveMirrorInOneTransaction() throws {
        try withStores { _, activeStore, catalogStore in
            let first = AetherNode(
                name: "First",
                protocolID: .http,
                server: "first.example",
                port: 443
            )
            let initial = try catalogStore.addNative(
                nodes: [first],
                suggestedName: "Native"
            )
            let profileID = try XCTUnwrap(initial.activeProfileID)
            let second = AetherNode(
                name: "Second",
                protocolID: .socks5,
                server: "second.example",
                port: 1080
            )

            let updated = try catalogStore.updateNative(
                id: profileID,
                nodes: [first, second],
                updatedAt: Date(timeIntervalSince1970: 1_900_000_000)
            )

            XCTAssertEqual(updated.activeProfile?.profile.nativeNodes, [first, second])
            XCTAssertEqual(
                updated.activeProfile?.profile.yaml,
                try AetherNodeProfileCompiler.compile(nodes: [first, second])
            )
            let mirror = try activeStore.loadValidated()
            XCTAssertEqual(mirror.yaml, updated.activeProfile?.profile.yaml)
            XCTAssertNil(mirror.nativeNodes)
        }
    }

    func testImportedYAMLProfileCannotCrossNativeEditBoundary() throws {
        try withStores { _, _, catalogStore in
            let catalog = try catalogStore.addValidated(
                data: profileData(name: "imported", secret: "secret"),
                suggestedName: "Imported"
            )
            let node = AetherNode(
                name: "Native",
                protocolID: .http,
                server: "native.example",
                port: 443
            )

            XCTAssertThrowsError(
                try catalogStore.updateNative(
                    id: try XCTUnwrap(catalog.activeProfileID),
                    nodes: [node]
                )
            ) { error in
                XCTAssertEqual(
                    error as? ProfileCatalogStoreError,
                    .notNativeProfile
                )
            }
        }
    }

    func testFirstProfileBecomesActiveEvenWhenCallerRequestsInactive() throws {
        try withStores { _, activeStore, catalogStore in
            let catalog = try catalogStore.addValidated(
                data: profileData(name: "first", secret: "one"),
                suggestedName: "First",
                makeActive: false
            )

            XCTAssertNotNil(catalog.activeProfileID)
            XCTAssertEqual(catalog.activeProfile?.profile.name, "First")
            XCTAssertEqual(try activeStore.loadValidated().name, "First")
        }
    }

    func testLoadRepairsStaleExtensionMirrorFromCatalog() throws {
        try withStores { _, activeStore, catalogStore in
            let first = try catalogStore.addValidated(
                data: profileData(name: "first", secret: "one"),
                suggestedName: "First",
                importedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
            let firstProfile = try XCTUnwrap(first.activeProfile?.profile)
            let second = try catalogStore.addValidated(
                data: profileData(name: "second", secret: "two"),
                suggestedName: "Second",
                importedAt: Date(timeIntervalSince1970: 1_800_000_100)
            )
            let expected = try XCTUnwrap(second.activeProfile?.profile)

            try activeStore.saveValidated(
                data: try XCTUnwrap(firstProfile.yaml.data(using: .utf8)),
                suggestedName: firstProfile.name,
                importedAt: firstProfile.importedAt
            )
            XCTAssertEqual(try activeStore.loadValidated().name, "First")

            let repaired = try catalogStore.loadOrMigrate()
            XCTAssertEqual(repaired.activeProfile?.profile, expected)
            XCTAssertEqual(try activeStore.loadValidated(), expected)
        }
    }

    func testRenameAndRemoveInactiveProfilePreserveActiveMirror() throws {
        try withStores { _, activeStore, catalogStore in
            let first = try catalogStore.addValidated(
                data: profileData(name: "first", secret: "one"),
                suggestedName: "First"
            )
            let firstID = try XCTUnwrap(first.activeProfileID)
            let second = try catalogStore.addValidated(
                data: profileData(name: "second", secret: "two"),
                suggestedName: "Second"
            )
            let secondID = try XCTUnwrap(second.activeProfileID)

            let renamed = try catalogStore.rename(
                id: firstID,
                to: "Office Backup"
            )
            XCTAssertEqual(
                renamed.profiles.first(where: { $0.id == firstID })?.profile.name,
                "Office Backup"
            )
            XCTAssertEqual(try activeStore.loadValidated().name, "Second")

            let removed = try catalogStore.remove(id: firstID)
            XCTAssertEqual(removed.profiles.map(\.id), [secondID])
            XCTAssertEqual(try activeStore.loadValidated().name, "Second")
        }
    }

    func testRefusesToRemoveActiveProfile() throws {
        try withStores { _, _, catalogStore in
            let catalog = try catalogStore.addValidated(
                data: profileData(name: "only", secret: "one"),
                suggestedName: "Only"
            )
            let activeID = try XCTUnwrap(catalog.activeProfileID)

            XCTAssertThrowsError(try catalogStore.remove(id: activeID)) { error in
                XCTAssertEqual(
                    error as? ProfileCatalogStoreError,
                    .cannotRemoveActiveProfile
                )
            }
        }
    }

    func testRejectsTamperedCatalogCiphertext() throws {
        try withStores { directory, _, catalogStore in
            _ = try catalogStore.addValidated(
                data: profileData(name: "tamper", secret: "secret"),
                suggestedName: "Tamper"
            )
            let url = directory.appendingPathComponent(
                ProfileCatalogStore.encryptedFilename
            )
            var envelope = try JSONDecoder().decode(
                EncryptedProfileEnvelope.self,
                from: Data(contentsOf: url)
            )
            envelope.sealedBox[envelope.sealedBox.startIndex] ^= 0x01
            try JSONEncoder().encode(envelope).write(to: url, options: [.atomic])

            XCTAssertThrowsError(try catalogStore.loadOrMigrate()) { error in
                XCTAssertEqual(
                    error as? EncryptedProfileCodecError,
                    .authenticationFailed
                )
            }
        }
    }

    func testRejectsOversizedEncryptedCatalogBeforeDecoding() throws {
        try withStores { directory, _, catalogStore in
            let url = directory.appendingPathComponent(
                ProfileCatalogStore.encryptedFilename
            )
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            XCTAssertTrue(FileManager.default.createFile(
                atPath: url.path,
                contents: nil
            ))
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(
                atOffset: UInt64(ProfileCatalogStore.maximumEncryptedBytes + 1)
            )
            try handle.close()

            XCTAssertThrowsError(try catalogStore.loadOrMigrate()) { error in
                XCTAssertEqual(
                    error as? ProfileCatalogStoreError,
                    .encryptedCatalogTooLarge(
                        ProfileCatalogStore.maximumEncryptedBytes + 1
                    )
                )
            }
        }
    }

    func testCatalogCiphertextCannotBeOpenedAsActiveProfile() throws {
        try withStores { directory, _, catalogStore in
            _ = try catalogStore.addValidated(
                data: profileData(name: "aad", secret: "secret"),
                suggestedName: "AAD"
            )
            let data = try Data(
                contentsOf: directory.appendingPathComponent(
                    ProfileCatalogStore.encryptedFilename
                )
            )
            let activeCodec = EncryptedProfileCodec()

            XCTAssertThrowsError(
                try activeCodec.open(
                    data,
                    keyData: Data(repeating: 0xA5, count: 32)
                )
            ) { error in
                XCTAssertEqual(
                    error as? EncryptedProfileCodecError,
                    .authenticationFailed
                )
            }
        }
    }

    func testPortableMergePreservesLocalActiveAndDeduplicatesProfiles() throws {
        try withStores { _, activeStore, catalogStore in
            let local = try catalogStore.addValidated(
                data: profileData(name: "local", secret: "one"),
                suggestedName: "Local"
            )
            let localActive = try XCTUnwrap(local.activeProfileID)
            let sharedProfile = try XCTUnwrap(local.activeProfile?.profile)
            let collision = ManagedProfile(
                id: localActive,
                profile: ActiveProfile(
                    name: "Remote",
                    yaml: String(
                        decoding: profileData(name: "remote", secret: "two"),
                        as: UTF8.self
                    )
                )
            )
            let duplicate = ManagedProfile(profile: sharedProfile)
            let imported = ProfileCatalog(
                activeProfileID: collision.id,
                profiles: [duplicate, collision]
            )

            let merged = try catalogStore.mergeValidated(imported)

            XCTAssertEqual(merged.activeProfileID, localActive)
            XCTAssertEqual(merged.profiles.count, 2)
            XCTAssertEqual(
                merged.profiles.filter {
                    $0.profile.name == sharedProfile.name
                        && $0.profile.yaml == sharedProfile.yaml
                }.count,
                1
            )
            XCTAssertNotEqual(
                merged.profiles.first { $0.profile.name == "Remote" }?.id,
                localActive
            )
            XCTAssertEqual(try activeStore.loadValidated().name, "Local")
        }
    }

    func testPortableMergeIntoEmptyLibraryActivatesArchivedSelection() throws {
        try withStores { _, activeStore, catalogStore in
            let importedProfile = ManagedProfile(
                profile: ActiveProfile(
                    name: "Imported",
                    yaml: String(
                        decoding: profileData(
                            name: "imported",
                            secret: "portable"
                        ),
                        as: UTF8.self
                    )
                )
            )
            let imported = ProfileCatalog(
                activeProfileID: importedProfile.id,
                profiles: [importedProfile]
            )

            let merged = try catalogStore.mergeValidated(imported)

            XCTAssertEqual(merged.activeProfileID, importedProfile.id)
            XCTAssertEqual(merged.activeProfile?.profile.name, "Imported")
            XCTAssertEqual(try activeStore.loadValidated().name, "Imported")
        }
    }

    private func profileData(name: String, secret: String) -> Data {
        Data(
            """
            proxies:
              - name: \(name)
                type: trojan
                server: \(name).example
                port: 443
                password: \(secret)
            """.utf8
        )
    }

    private func withStores(
        _ operation: (
            URL,
            ActiveProfileStore,
            ProfileCatalogStore
        ) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyStore = InMemoryProfileKeyStore(
            keys: [
                EncryptedProfileCodec.defaultKeyID:
                    Data(repeating: 0xA5, count: 32),
            ]
        )
        try operation(
            directory,
            ActiveProfileStore(directoryURL: directory, keyStore: keyStore),
            ProfileCatalogStore(directoryURL: directory, keyStore: keyStore)
        )
    }
}

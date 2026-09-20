import CryptoKit
import Foundation

public struct ManagedProfile: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let profile: ActiveProfile

    public init(id: UUID = UUID(), profile: ActiveProfile) {
        self.id = id
        self.profile = profile
    }
}

public struct ProfileCatalog: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let activeProfileID: UUID?
    public let profiles: [ManagedProfile]

    public init(
        activeProfileID: UUID? = nil,
        profiles: [ManagedProfile] = []
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.activeProfileID = activeProfileID
        self.profiles = profiles
    }

    public var activeProfile: ManagedProfile? {
        guard let activeProfileID else { return nil }
        return profiles.first { $0.id == activeProfileID }
    }
}

/// Encrypted, host-app-owned profile collection. Network extensions deliberately
/// continue to consume only ``ActiveProfileStore``. This keeps their startup
/// input small and gives activation an explicit, validated mirror boundary.
public struct ProfileCatalogStore: Sendable {
    public static let maximumProfiles = 64
    static let encryptedFilename = "profile-catalog.v1.json"
    static let maximumEncryptedBytes = 64 * 1_024 * 1_024

    public let directoryURL: URL
    private let keyStore: any ProfileKeyStoring
    private let activeProfileStore: ActiveProfileStore
    private let codec = EncryptedProfileCatalogCodec()

    private var catalogURL: URL {
        directoryURL.appendingPathComponent(Self.encryptedFilename)
    }

    public init(
        directoryURL: URL,
        keyStore: any ProfileKeyStoring = DataProtectionProfileKeyStore()
    ) {
        self.directoryURL = directoryURL
        self.keyStore = keyStore
        self.activeProfileStore = ActiveProfileStore(
            directoryURL: directoryURL,
            keyStore: keyStore
        )
    }

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        guard let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) else {
            throw ActiveProfileStoreError.appGroupUnavailable
        }
        return Self(
            directoryURL: container.appendingPathComponent(
                "Library/Application Support/AetherRoute",
                isDirectory: true
            )
        )
    }

    /// Loads the encrypted collection and repairs its extension-facing active
    /// mirror when needed. A pre-catalog encrypted active profile is migrated
    /// without changing its identifier-visible contents.
    public func loadOrMigrate(
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        if fileManager.fileExists(atPath: catalogURL.path) {
            let catalog = try load(fileManager: fileManager)
            try repairActiveMirror(for: catalog, fileManager: fileManager)
            return catalog
        }

        do {
            let profile = try activeProfileStore.loadValidated(
                fileManager: fileManager
            )
            let managed = ManagedProfile(profile: profile)
            let catalog = ProfileCatalog(
                activeProfileID: managed.id,
                profiles: [managed]
            )
            try save(catalog, fileManager: fileManager)
            return catalog
        } catch ActiveProfileStoreError.noActiveProfile {
            return ProfileCatalog()
        }
    }

    @discardableResult
    public func addValidated(
        data: Data,
        suggestedName: String,
        importedAt: Date = .now,
        subscription: ProfileSubscription? = nil,
        makeActive: Bool = true,
        cancellationCheck: () throws -> Void = {},
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try ProfileImportValidator.validate(
            data: data,
            cancellationCheck: cancellationCheck
        )
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try cancellationCheck()

        let cleanName = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ActiveProfile(
            name: cleanName.isEmpty ? "Imported profile" : cleanName,
            yaml: yaml,
            importedAt: importedAt,
            subscription: subscription
        )
        let current = try loadOrMigrate(fileManager: fileManager)
        guard current.profiles.count < Self.maximumProfiles else {
            throw ProfileCatalogStoreError.profileLimitReached(
                Self.maximumProfiles
            )
        }

        let managed = ManagedProfile(profile: profile)
        var profiles = current.profiles
        profiles.append(managed)
        let shouldActivate = makeActive || current.activeProfileID == nil
        let catalog = ProfileCatalog(
            activeProfileID: shouldActivate
                ? managed.id
                : current.activeProfileID,
            profiles: profiles
        )
        try cancellationCheck()
        try commit(
            catalog,
            previous: current,
            mirrorProfile: shouldActivate ? profile : nil,
            fileManager: fileManager
        )
        return catalog
    }

    /// Adds an AetherRoute-authored profile while keeping the native node
    /// document and its deterministic core configuration bound together in the
    /// same encrypted catalog transaction.
    @discardableResult
    public func addNative(
        nodes: [AetherNode],
        suggestedName: String,
        importedAt: Date = .now,
        makeActive: Bool = true,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let yaml = try AetherNodeProfileCompiler.compile(nodes: nodes)
        let cleanName = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ActiveProfile(
            name: cleanName.isEmpty ? "Manual profile" : cleanName,
            yaml: yaml,
            importedAt: importedAt,
            nativeNodes: nodes
        )
        try profile.validateForStorage()

        let current = try loadOrMigrate(fileManager: fileManager)
        guard current.profiles.count < Self.maximumProfiles else {
            throw ProfileCatalogStoreError.profileLimitReached(
                Self.maximumProfiles
            )
        }
        let managed = ManagedProfile(profile: profile)
        var profiles = current.profiles
        profiles.append(managed)
        let shouldActivate = makeActive || current.activeProfileID == nil
        let catalog = ProfileCatalog(
            activeProfileID: shouldActivate
                ? managed.id
                : current.activeProfileID,
            profiles: profiles
        )
        try commit(
            catalog,
            previous: current,
            mirrorProfile: shouldActivate ? profile : nil,
            fileManager: fileManager
        )
        return catalog
    }

    @discardableResult
    public func activate(
        id: UUID,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let current = try loadOrMigrate(fileManager: fileManager)
        guard let selected = current.profiles.first(where: { $0.id == id }) else {
            throw ProfileCatalogStoreError.profileNotFound
        }
        guard current.activeProfileID != id else { return current }

        let updated = ProfileCatalog(
            activeProfileID: id,
            profiles: current.profiles
        )
        try commit(
            updated,
            previous: current,
            mirrorProfile: selected.profile,
            fileManager: fileManager
        )
        return updated
    }

    @discardableResult
    public func replace(
        id: UUID,
        with profile: ActiveProfile,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try profile.validateForStorage()
        let current = try loadOrMigrate(fileManager: fileManager)
        guard let index = current.profiles.firstIndex(where: { $0.id == id }) else {
            throw ProfileCatalogStoreError.profileNotFound
        }

        var profiles = current.profiles
        profiles[index] = ManagedProfile(id: id, profile: profile)
        let updated = ProfileCatalog(
            activeProfileID: current.activeProfileID,
            profiles: profiles
        )
        try commit(
            updated,
            previous: current,
            mirrorProfile: current.activeProfileID == id ? profile : nil,
            fileManager: fileManager
        )
        return updated
    }

    /// Recompiles an AetherRoute-authored profile after a bounded native-node
    /// edit. Imported YAML and subscription profiles cannot silently cross this
    /// boundary because they do not carry a native node document.
    @discardableResult
    public func updateNative(
        id: UUID,
        nodes: [AetherNode],
        updatedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let current = try loadOrMigrate(fileManager: fileManager)
        guard let existing = current.profiles.first(where: { $0.id == id }) else {
            throw ProfileCatalogStoreError.profileNotFound
        }
        guard existing.profile.nativeNodes != nil,
              existing.profile.subscription == nil else {
            throw ProfileCatalogStoreError.notNativeProfile
        }
        let yaml = try AetherNodeProfileCompiler.compile(nodes: nodes)
        let profile = ActiveProfile(
            name: existing.profile.name,
            yaml: yaml,
            importedAt: updatedAt,
            nativeNodes: nodes
        )
        return try replace(
            id: id,
            with: profile,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func rename(
        id: UUID,
        to name: String,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else {
            throw ProfileCatalogStoreError.emptyName
        }
        let current = try loadOrMigrate(fileManager: fileManager)
        guard let existing = current.profiles.first(where: { $0.id == id }) else {
            throw ProfileCatalogStoreError.profileNotFound
        }
        let profile = ActiveProfile(
            name: cleanName,
            yaml: existing.profile.yaml,
            importedAt: existing.profile.importedAt,
            subscription: existing.profile.subscription,
            nativeNodes: existing.profile.nativeNodes
        )
        return try replace(
            id: id,
            with: profile,
            fileManager: fileManager
        )
    }

    @discardableResult
    public func remove(
        id: UUID,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        let current = try loadOrMigrate(fileManager: fileManager)
        guard current.profiles.contains(where: { $0.id == id }) else {
            throw ProfileCatalogStoreError.profileNotFound
        }
        guard current.activeProfileID != id else {
            throw ProfileCatalogStoreError.cannotRemoveActiveProfile
        }

        let updated = ProfileCatalog(
            activeProfileID: current.activeProfileID,
            profiles: current.profiles.filter { $0.id != id }
        )
        try save(updated, fileManager: fileManager)
        return updated
    }

    /// Merges a decrypted portable catalog while preserving the profile that
    /// is active on this Mac. Identical profiles are skipped and identifier
    /// collisions are assigned fresh identifiers. An empty local library uses
    /// the archived active profile only after this explicit import call.
    @discardableResult
    public func mergeValidated(
        _ imported: ProfileCatalog,
        fileManager: FileManager = .default
    ) throws -> ProfileCatalog {
        try imported.validateForStorage()
        guard !imported.profiles.isEmpty else {
            throw PortableProfileArchiveError.emptyCatalog
        }
        let current = try loadOrMigrate(fileManager: fileManager)
        var profiles = current.profiles
        var identifiers = Set(profiles.map(\.id))
        var importedIdentifierMap: [UUID: UUID] = [:]

        for managed in imported.profiles {
            if let existing = profiles.first(where: {
                $0.profile.isEquivalentForPortableMerge(to: managed.profile)
            }) {
                importedIdentifierMap[managed.id] = existing.id
                continue
            }
            guard profiles.count < Self.maximumProfiles else {
                throw ProfileCatalogStoreError.profileLimitReached(
                    Self.maximumProfiles
                )
            }
            var identifier = managed.id
            while identifiers.contains(identifier) {
                identifier = UUID()
            }
            identifiers.insert(identifier)
            importedIdentifierMap[managed.id] = identifier
            profiles.append(
                ManagedProfile(id: identifier, profile: managed.profile)
            )
        }

        let activeProfileID: UUID?
        if let currentActive = current.activeProfileID {
            activeProfileID = currentActive
        } else if let importedActive = imported.activeProfileID {
            activeProfileID = importedIdentifierMap[importedActive]
        } else {
            activeProfileID = nil
        }
        let merged = ProfileCatalog(
            activeProfileID: activeProfileID,
            profiles: profiles
        )
        guard merged != current else { return current }
        let mirror = current.activeProfileID == nil
            ? merged.activeProfile?.profile
            : nil
        try commit(
            merged,
            previous: current,
            mirrorProfile: mirror,
            fileManager: fileManager
        )
        return merged
    }

    public func replaceCatalog(
        _ catalog: ProfileCatalog,
        fileManager: FileManager = .default
    ) throws {
        try catalog.validateForStorage()
        let current = try? load(fileManager: fileManager)
        let mirror = catalog.activeProfile?.profile
        try commit(
            catalog,
            previous: current,
            mirrorProfile: mirror,
            fileManager: fileManager
        )
    }

    private func load(fileManager: FileManager) throws -> ProfileCatalog {
        // Reading attributes can block indefinitely on macOS 26 when the
        // encrypted catalog carries provenance and backup-exclusion xattrs.
        // Mapping the file keeps the pre-decode size gate without forcing
        // Foundation to enumerate those extended attributes.
        let data = try Data(contentsOf: catalogURL, options: [.mappedIfSafe])
        let size = data.count
        guard size <= Self.maximumEncryptedBytes else {
            throw ProfileCatalogStoreError.encryptedCatalogTooLarge(size)
        }
        let metadata = try codec.decodeEnvelope(data)
        let key = try keyStore.loadKey(keyID: metadata.keyID)
        let catalog = try codec.open(data, keyData: key)
        try catalog.validateForStorage()
        return catalog
    }

    private func commit(
        _ catalog: ProfileCatalog,
        previous: ProfileCatalog?,
        mirrorProfile: ActiveProfile?,
        fileManager: FileManager
    ) throws {
        try save(catalog, fileManager: fileManager)
        guard let mirrorProfile else { return }
        do {
            try saveActiveMirror(mirrorProfile, fileManager: fileManager)
        } catch {
            guard let previous else {
                throw ProfileCatalogStoreError.activeMirrorWriteFailed
            }
            do {
                try save(previous, fileManager: fileManager)
                if let oldMirror = previous.activeProfile?.profile {
                    try saveActiveMirror(oldMirror, fileManager: fileManager)
                } else {
                    try activeProfileStore.removeEncryptedProfile(
                        fileManager: fileManager
                    )
                }
            } catch {
                throw ProfileCatalogStoreError.transactionRecoveryFailed
            }
            throw ProfileCatalogStoreError.activeMirrorWriteFailed
        }
    }

    private func save(
        _ catalog: ProfileCatalog,
        fileManager: FileManager
    ) throws {
        try catalog.validateForStorage()
        let key: Data
        if fileManager.fileExists(atPath: catalogURL.path) {
            let current = try Data(
                contentsOf: catalogURL,
                options: [.mappedIfSafe]
            )
            let metadata = try codec.decodeEnvelope(current)
            key = try keyStore.loadKey(keyID: metadata.keyID)
        } else {
            key = try keyStore.loadOrCreateKey(keyID: codec.keyID)
        }
        let encrypted = try codec.seal(catalog, keyData: key)
        guard encrypted.count <= Self.maximumEncryptedBytes else {
            throw ProfileCatalogStoreError.encryptedCatalogTooLarge(
                encrypted.count
            )
        }
        try writeAtomically(encrypted, fileManager: fileManager)
    }

    private func repairActiveMirror(
        for catalog: ProfileCatalog,
        fileManager: FileManager
    ) throws {
        guard let active = catalog.activeProfile else { return }
        do {
            let mirror = try activeProfileStore.loadValidated(
                fileManager: fileManager
            )
            guard !mirror.isEquivalentForActiveMirror(to: active.profile) else {
                return
            }
        } catch ActiveProfileStoreError.noActiveProfile {
            // The authoritative catalog can recreate a missing mirror.
        }
        try saveActiveMirror(active.profile, fileManager: fileManager)
    }

    private func saveActiveMirror(
        _ profile: ActiveProfile,
        fileManager: FileManager
    ) throws {
        guard let data = profile.yaml.data(using: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try activeProfileStore.saveValidated(
            data: data,
            suggestedName: profile.name,
            importedAt: profile.importedAt,
            subscription: profile.subscription,
            fileManager: fileManager
        )
    }

}

extension ProfileCatalog {
    func validateForStorage() throws {
        guard formatVersion == ProfileCatalog.currentFormatVersion else {
            throw ProfileCatalogStoreError.unsupportedFormat(
                formatVersion
            )
        }
        guard profiles.count <= ProfileCatalogStore.maximumProfiles else {
            throw ProfileCatalogStoreError.profileLimitReached(
                ProfileCatalogStore.maximumProfiles
            )
        }
        let identifiers = Set(profiles.map(\.id))
        guard identifiers.count == profiles.count else {
            throw ProfileCatalogStoreError.duplicateIdentifier
        }
        if let activeProfileID,
           !identifiers.contains(activeProfileID) {
            throw ProfileCatalogStoreError.activeProfileNotFound
        }
        if !profiles.isEmpty, activeProfileID == nil {
            throw ProfileCatalogStoreError.activeProfileNotFound
        }
        for managed in profiles {
            try managed.profile.validateForStorage()
        }
    }
}

extension ActiveProfile {
    func validateForStorage() throws {
        guard formatVersion == ActiveProfile.currentFormatVersion else {
            throw ActiveProfileStoreError.unsupportedFormat(
                formatVersion
            )
        }
        guard let data = yaml.data(using: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try ProfileImportValidator.validate(data: data)
        if let nativeNodes {
            guard try AetherNodeProfileCompiler.compile(nodes: nativeNodes)
                    == yaml else {
                throw ProfileCatalogStoreError.nativeProfileMismatch
            }
        }
    }

    fileprivate func isEquivalentForPortableMerge(
        to other: ActiveProfile
    ) -> Bool {
        name == other.name
            && yaml == other.yaml
            && subscription?.url == other.subscription?.url
            && nativeNodes == other.nativeNodes
    }

    fileprivate func isEquivalentForActiveMirror(
        to other: ActiveProfile
    ) -> Bool {
        name == other.name
            && yaml == other.yaml
            && importedAt == other.importedAt
            && subscription == other.subscription
    }

}

extension ProfileCatalogStore {
    private func writeAtomically(
        _ data: Data,
        fileManager: FileManager
    ) throws {
        let directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication,
        ]
        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: directoryAttributes
        )
        try fileManager.setAttributes(
            directoryAttributes,
            ofItemAtPath: directoryURL.path
        )
        try excludeFromBackup(directoryURL)

        try data.write(to: catalogURL, options: [.atomic])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: catalogURL.path
        )
        try excludeFromBackup(catalogURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

public enum ProfileCatalogStoreError: LocalizedError, Equatable {
    case activeMirrorWriteFailed
    case activeProfileNotFound
    case cannotRemoveActiveProfile
    case duplicateIdentifier
    case emptyName
    case encryptedCatalogTooLarge(Int)
    case nativeProfileMismatch
    case notNativeProfile
    case profileLimitReached(Int)
    case profileNotFound
    case transactionRecoveryFailed
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .activeMirrorWriteFailed:
            "The active profile could not be synchronized with the network extension. No profile switch was completed."
        case .activeProfileNotFound:
            "The encrypted profile catalog does not contain its active profile."
        case .cannotRemoveActiveProfile:
            "Activate another profile before removing this one."
        case .duplicateIdentifier:
            "The encrypted profile catalog contains duplicate identifiers."
        case .emptyName:
            "Enter a profile name."
        case let .encryptedCatalogTooLarge(bytes):
            "The encrypted profile catalog is too large (\(bytes) bytes)."
        case .nativeProfileMismatch:
            "The native node document does not match its compiled core profile."
        case .notNativeProfile:
            "Only AetherRoute-native profiles can be edited as nodes."
        case let .profileLimitReached(limit):
            "The profile limit (\(limit)) has been reached."
        case .profileNotFound:
            "The selected profile no longer exists."
        case .transactionRecoveryFailed:
            "The profile switch could not be rolled back. Restart AetherRoute to repair the active profile mirror before connecting."
        case let .unsupportedFormat(version):
            "The profile catalog format version \(version) is not supported."
        }
    }
}

private struct EncryptedProfileCatalogCodec: Sendable {
    static let purpose = "AetherRoute.ProfileCatalog"
    let keyID = EncryptedProfileCodec.defaultKeyID

    func seal(_ catalog: ProfileCatalog, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        let plaintext: Data
        do {
            plaintext = try Self.payloadEncoder.encode(catalog)
        } catch {
            throw EncryptedProfileCodecError.profileEncodingFailed
        }
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: authenticatedData(keyID: keyID)
            )
        } catch {
            throw EncryptedProfileCodecError.encryptionFailed
        }
        guard let combined = box.combined else {
            throw EncryptedProfileCodecError.encryptionFailed
        }
        let envelope = EncryptedProfileEnvelope(
            formatVersion: EncryptedProfileCodec.currentFormatVersion,
            algorithm: EncryptedProfileCodec.algorithm,
            keyID: keyID,
            sealedBox: combined
        )
        do {
            return try Self.envelopeEncoder.encode(envelope)
        } catch {
            throw EncryptedProfileCodecError.envelopeEncodingFailed
        }
    }

    func open(_ data: Data, keyData: Data) throws -> ProfileCatalog {
        let envelope = try decodeEnvelope(data)
        let key = try symmetricKey(from: keyData)
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        } catch {
            throw EncryptedProfileCodecError.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: key,
                authenticating: authenticatedData(keyID: envelope.keyID)
            )
        } catch {
            throw EncryptedProfileCodecError.authenticationFailed
        }
        do {
            return try Self.payloadDecoder.decode(
                ProfileCatalog.self,
                from: plaintext
            )
        } catch {
            throw EncryptedProfileCodecError.profileDecodingFailed
        }
    }

    func decodeEnvelope(_ data: Data) throws -> EncryptedProfileEnvelope {
        let envelope: EncryptedProfileEnvelope
        do {
            envelope = try JSONDecoder().decode(
                EncryptedProfileEnvelope.self,
                from: data
            )
        } catch {
            throw EncryptedProfileCodecError.malformedEnvelope
        }
        guard envelope.formatVersion == EncryptedProfileCodec.currentFormatVersion else {
            throw EncryptedProfileCodecError.unsupportedFormat(
                envelope.formatVersion
            )
        }
        guard envelope.algorithm == EncryptedProfileCodec.algorithm else {
            throw EncryptedProfileCodecError.unsupportedAlgorithm(
                envelope.algorithm
            )
        }
        guard envelope.keyID == keyID else {
            throw EncryptedProfileCodecError.unsupportedKeyID(
                envelope.keyID
            )
        }
        return envelope
    }

    private func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw EncryptedProfileCodecError.invalidKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func authenticatedData(keyID: String) -> Data {
        Data(
            "\(Self.purpose)|\(EncryptedProfileCodec.currentFormatVersion)|\(keyID)".utf8
        )
    }

    private static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var payloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var envelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

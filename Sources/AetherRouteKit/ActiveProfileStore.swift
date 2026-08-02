import Foundation

public struct ActiveProfile: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let name: String
    public let yaml: String
    public let importedAt: Date
    public let subscription: ProfileSubscription?
    public let nativeNodes: [AetherNode]?

    public init(
        name: String,
        yaml: String,
        importedAt: Date = .now,
        subscription: ProfileSubscription? = nil,
        nativeNodes: [AetherNode]? = nil
    ) {
        self.formatVersion = Self.currentFormatVersion
        self.name = name
        self.yaml = yaml
        self.importedAt = importedAt
        self.subscription = subscription
        self.nativeNodes = nativeNodes
    }
}

public struct ActiveProfileStore: Sendable {
    public let directoryURL: URL
    private let keyStore: any ProfileKeyStoring
    private let codec: EncryptedProfileCodec

    private var profileURL: URL {
        directoryURL.appendingPathComponent(
            "active-profile.v2.json",
            isDirectory: false
        )
    }

    private var legacyProfileURL: URL {
        directoryURL.appendingPathComponent(
            "active-profile.json",
            isDirectory: false
        )
    }

    public init(
        directoryURL: URL,
        keyStore: any ProfileKeyStoring = DataProtectionProfileKeyStore()
    ) {
        self.directoryURL = directoryURL
        self.keyStore = keyStore
        self.codec = EncryptedProfileCodec()
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

    @discardableResult
    public func saveValidated(
        data: Data,
        suggestedName: String,
        importedAt: Date = .now,
        subscription: ProfileSubscription? = nil,
        fileManager: FileManager = .default
    ) throws -> ActiveProfile {
        try rejectLegacyProfile(fileManager: fileManager)
        try ProfileImportValidator.validate(data: data)
        guard let yaml = String(data: data, encoding: .utf8) else {
            throw ProfileImportError.notUTF8
        }

        let cleanName = suggestedName
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = ActiveProfile(
            name: cleanName.isEmpty ? "Imported profile" : cleanName,
            yaml: yaml,
            importedAt: importedAt,
            subscription: subscription
        )

        let key: Data
        if fileManager.fileExists(atPath: profileURL.path) {
            let currentEnvelope = try Data(
                contentsOf: profileURL,
                options: [.mappedIfSafe]
            )
            let metadata = try codec.decodeEnvelope(currentEnvelope)
            // Existing ciphertext must never be overwritten with a newly
            // generated key. A missing key is a recoverable import error, not
            // permission to destroy the encrypted profile.
            key = try keyStore.loadKey(keyID: metadata.keyID)
        } else {
            key = try keyStore.loadOrCreateKey(keyID: codec.keyID)
        }

        let encrypted = try codec.seal(profile, keyData: key)
        try writeAtomically(
            encrypted,
            fileManager: fileManager
        )
        return profile
    }

    public func loadValidated(
        fileManager: FileManager = .default
    ) throws -> ActiveProfile {
        try rejectLegacyProfile(fileManager: fileManager)
        let data: Data
        do {
            data = try Data(contentsOf: profileURL, options: [.mappedIfSafe])
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            throw ActiveProfileStoreError.noActiveProfile
        }

        let metadata = try codec.decodeEnvelope(data)
        let key = try keyStore.loadKey(keyID: metadata.keyID)
        let profile = try codec.open(data, keyData: key)
        guard profile.formatVersion == ActiveProfile.currentFormatVersion else {
            throw ActiveProfileStoreError.unsupportedFormat(profile.formatVersion)
        }
        guard let yamlData = profile.yaml.data(using: .utf8) else {
            throw ProfileImportError.notUTF8
        }
        try ProfileImportValidator.validate(data: yamlData)
        return profile
    }

    /// Used only to roll back a catalog transaction that created its first
    /// active mirror but could not finish applying file protection metadata.
    /// Legacy plaintext input is never removed by this path.
    func removeEncryptedProfile(
        fileManager: FileManager = .default
    ) throws {
        try rejectLegacyProfile(fileManager: fileManager)
        guard fileManager.fileExists(atPath: profileURL.path) else { return }
        try fileManager.removeItem(at: profileURL)
    }

    private func rejectLegacyProfile(fileManager: FileManager) throws {
        guard !fileManager.fileExists(atPath: legacyProfileURL.path) else {
            throw ActiveProfileStoreError.legacyPlaintextProfileFound
        }
    }

    private func writeAtomically(
        _ data: Data,
        fileManager: FileManager
    ) throws {
        let directoryAttributes: [FileAttributeKey: Any] = [
            .posixPermissions: 0o700,
            .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
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

        try data.write(to: profileURL, options: [.atomic])
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o600,
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: profileURL.path
        )
        try excludeFromBackup(profileURL)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }
}

public enum ActiveProfileStoreError: LocalizedError, Equatable {
    case appGroupUnavailable
    case legacyPlaintextProfileFound
    case noActiveProfile
    case unsupportedFormat(Int)

    public var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            "The shared App Group container is unavailable."
        case .legacyPlaintextProfileFound:
            "A legacy plaintext profile exists. Encrypted storage will not read, overwrite, or delete it until an explicit migration is performed."
        case .noActiveProfile:
            "Import and activate a profile before connecting."
        case let .unsupportedFormat(version):
            "The active profile format version \(version) is not supported."
        }
    }
}

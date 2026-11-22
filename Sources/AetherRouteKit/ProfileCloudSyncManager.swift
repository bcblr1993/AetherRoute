import Combine
import CryptoKit
import Foundation
import OSLog

public extension Notification.Name {
    static let aetherRouteCloudSyncDidUpdateProfiles = Notification.Name("com.aetherroute.cloudSyncDidUpdateProfiles")
    static let aetherRouteCloudSyncDidUpdateRuleProviders = Notification.Name("com.aetherroute.cloudSyncDidUpdateRuleProviders")
    static let aetherRouteCloudSyncDidUpdateUserRules = Notification.Name("com.aetherroute.cloudSyncDidUpdateUserRules")
}

public protocol CloudKeyValueStoring: AnyObject, Sendable {
    @discardableResult
    func synchronize() -> Bool
    func data(forKey defaultName: String) -> Data?
    func set(_ value: Any?, forKey defaultName: String)
}

extension NSUbiquitousKeyValueStore: CloudKeyValueStoring {}

public struct CloudSyncArchiveSummary: Equatable, Sendable {
    public let profileCount: Int?
    public let payloadByteCount: Int
    public let updatedAt: Date
    public let sourceDeviceIdentifier: String
    public let sourceDeviceName: String
    public let isFromCurrentDevice: Bool

    public init(
        profileCount: Int?,
        payloadByteCount: Int,
        updatedAt: Date,
        sourceDeviceIdentifier: String,
        sourceDeviceName: String,
        isFromCurrentDevice: Bool
    ) {
        self.profileCount = profileCount
        self.payloadByteCount = payloadByteCount
        self.updatedAt = updatedAt
        self.sourceDeviceIdentifier = sourceDeviceIdentifier
        self.sourceDeviceName = sourceDeviceName
        self.isFromCurrentDevice = isFromCurrentDevice
    }
}

public struct CloudSyncDiagnosticsSnapshot: Equatable, Sendable {
    public let isICloudAccountSignedIn: Bool
    public let isEncryptionKeyAvailable: Bool
    public let pairingFingerprint: String?
    public let currentDeviceName: String
    public let remoteArchive: CloudSyncArchiveSummary?
    public let localStorageDirectoryPath: String?

    public init(
        isICloudAccountSignedIn: Bool,
        isEncryptionKeyAvailable: Bool,
        pairingFingerprint: String?,
        currentDeviceName: String,
        remoteArchive: CloudSyncArchiveSummary?,
        localStorageDirectoryPath: String?
    ) {
        self.isICloudAccountSignedIn = isICloudAccountSignedIn
        self.isEncryptionKeyAvailable = isEncryptionKeyAvailable
        self.pairingFingerprint = pairingFingerprint
        self.currentDeviceName = currentDeviceName
        self.remoteArchive = remoteArchive
        self.localStorageDirectoryPath = localStorageDirectoryPath
    }
}

public struct CloudSyncUserRulesSnapshot: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public let version: Int
    public var customRules: [CustomRule]
    public var bypassPolicy: BypassPolicy
    /// Change and deletion times (1.8.7). Absent in snapshots from 1.8.5
    /// and 1.8.6, which merged by union and so could not delete.
    public var customRuleSync: RuleSyncMetadata?
    public var bypassSync: RuleSyncMetadata?

    public init(
        version: Int = Self.currentVersion,
        customRules: [CustomRule] = [],
        bypassPolicy: BypassPolicy = .empty,
        customRuleSync: RuleSyncMetadata? = nil,
        bypassSync: RuleSyncMetadata? = nil
    ) {
        self.version = version
        self.customRules = customRules
        self.bypassPolicy = bypassPolicy
        self.customRuleSync = customRuleSync
        self.bypassSync = bypassSync
    }
}

public struct CloudSyncCatalogPayload: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let catalog: ProfileCatalog
    public let deletedProfiles: [UUID: Date]

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        catalog: ProfileCatalog,
        deletedProfiles: [UUID: Date] = [:]
    ) {
        self.formatVersion = formatVersion
        self.catalog = catalog
        self.deletedProfiles = deletedProfiles
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion, catalog, deletedProfiles
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.formatVersion = try container.decodeIfPresent(Int.self, forKey: .formatVersion) ?? Self.currentFormatVersion
        self.catalog = try container.decode(ProfileCatalog.self, forKey: .catalog)
        self.deletedProfiles = try container.decodeIfPresent([UUID: Date].self, forKey: .deletedProfiles) ?? [:]
    }
}

public struct CloudSyncPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let storageKey = "aetherroute.profile_catalog.sync.v1"
    public static let userRulesStorageKey = "aetherroute.user_rules.sync.v1"

    public let version: Int
    public let updatedAtUnixMilliseconds: UInt64
    public let deviceIdentifier: String
    public let deviceName: String?
    public let encryptedData: Data
    public let sha256: String

    public var displayDeviceName: String {
        if let trimmed = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
            return trimmed
        }
        return deviceIdentifier
    }

    public init(
        version: Int = Self.currentVersion,
        updatedAtUnixMilliseconds: UInt64 = UInt64(max(0, Int64(Date().timeIntervalSince1970 * 1000))),
        deviceIdentifier: String,
        deviceName: String? = nil,
        encryptedData: Data,
        sha256: String
    ) {
        self.version = version
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
        self.deviceIdentifier = deviceIdentifier
        self.deviceName = deviceName
        self.encryptedData = encryptedData
        self.sha256 = sha256
    }
}

public enum CloudSyncError: LocalizedError, Equatable, Sendable {
    case cloudUnavailable
    case encryptionFailed
    case decryptionFailed
    case catalogCorrupted
    case keychainUnavailable
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            "iCloud storage is unavailable. Sign in to iCloud and try again."
        case .encryptionFailed:
            "The profiles could not be encrypted for iCloud."
        case .decryptionFailed:
            "The profiles from iCloud could not be decrypted with this Mac's key."
        case .catalogCorrupted:
            "The profiles in iCloud are damaged or failed their checksum."
        case .keychainUnavailable:
            "The encryption key is not available in the keychain."
        case .payloadTooLarge:
            "The profiles exceed the 1 MB iCloud limit."
        }
    }
}

/// What the last sync step did. The kit keeps no user-facing text; the app
/// localizes these (1.8.7: the status used to be hard-coded Chinese).
public enum CloudSyncStatus: Equatable, Sendable {
    public enum Operation: Equatable, Sendable {
        case sync, upload, pull, push
    }

    case enableSyncFirst
    case syncing
    case pulling
    case pushing
    case merged(profileCount: Int)
    case pulledLatest(profileCount: Int)
    case uploaded(profileCount: Int)
    case forcePulled(profileCount: Int)
    case forcePushed(profileCount: Int)
    case noCloudData
    case noCloudArchive
    case nothingToUpload
    case keychainUnavailable
    case decryptionFailed
    /// `cloudError` lets the app localize the cause; `detail` describes
    /// any other error.
    case failed(Operation, cloudError: CloudSyncError?, detail: String)

    public var isFailure: Bool {
        switch self {
        case .keychainUnavailable, .decryptionFailed, .failed: true
        default: false
        }
    }
}

/// Coordinates AES-256-GCM encrypted profile catalog sync across user devices via iCloud.
@MainActor
public final class ProfileCloudSyncManager: ObservableObject {
    public static let shared = ProfileCloudSyncManager()
    private static let logger = AppLog.logger(category: AppLog.Category.cloudSync)

    private let kvStore: any CloudKeyValueStoring
    private let keyStore: any ProfileKeyStoring
    private let injectedCatalogStore: ProfileCatalogStore?
    private let deviceID: String
    private var deviceName: String
    private let worker: CloudSyncWorker
    private let observerToken = ObserverToken()

    private final class ObserverToken: @unchecked Sendable {
        var token: (any NSObjectProtocol)?
        init(_ token: (any NSObjectProtocol)? = nil) {
            self.token = token
        }
    }

    @Published public var isSyncing: Bool = false
    @Published public var lastSyncedAt: Date? {
        didSet {
            if let date = lastSyncedAt {
                UserDefaults.standard.set(date.timeIntervalSince1970, forKey: "lastCloudSyncTime")
            }
        }
    }
    @Published public var isCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isCloudSyncEnabled, forKey: "isCloudSyncEnabled")
            refreshDiagnostics()
            if isCloudSyncEnabled {
                startObserving()
                Task { try? await sync() }
            } else {
                stopObserving()
            }
        }
    }
    @Published public var status: CloudSyncStatus?
    @Published public private(set) var diagnostics: CloudSyncDiagnosticsSnapshot = CloudSyncDiagnosticsSnapshot(
        isICloudAccountSignedIn: false,
        isEncryptionKeyAvailable: false,
        pairingFingerprint: nil,
        currentDeviceName: "Mac",
        remoteArchive: nil,
        localStorageDirectoryPath: nil
    )

    public init(
        kvStore: any CloudKeyValueStoring = NSUbiquitousKeyValueStore.default,
        keyStore: (any ProfileKeyStoring)? = nil,
        catalogStore: ProfileCatalogStore? = nil,
        ruleProviderEngine: RuleProviderEngine? = nil,
        deviceIdentifier: String? = nil,
        deviceName: String? = nil
    ) {
        self.injectedCatalogStore = catalogStore
        self.kvStore = kvStore
        if let keyStore {
            self.keyStore = keyStore
        } else {
            let sharedGroup = try? AppConstants.sharedKeychainAccessGroup()
            self.keyStore = DataProtectionProfileKeyStore(
                accessGroup: sharedGroup,
                service: Self.cloudSyncService,
                isSynchronizable: true
            )
        }

        // Retrieve or generate unique device ID
        if let explicitID = deviceIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitID.isEmpty {
            self.deviceID = explicitID
        } else if let stored = UserDefaults.standard.string(forKey: "aetherroute.device_id") {
            self.deviceID = stored
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "aetherroute.device_id")
            self.deviceID = newID
        }

        let explicitName = deviceName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedDeviceName: String
        let needsHostLookup: Bool
        if let explicitName, !explicitName.isEmpty {
            resolvedDeviceName = explicitName
            needsHostLookup = false
        } else {
            let fallbackHost = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
            resolvedDeviceName = fallbackHost.isEmpty ? "Mac" : fallbackHost
            needsHostLookup = true
        }
        self.deviceName = resolvedDeviceName

        let resolvedRuleProviderEngine: RuleProviderEngine
        if let ruleProviderEngine {
            resolvedRuleProviderEngine = ruleProviderEngine
        } else if let dir = catalogStore?.directoryURL {
            resolvedRuleProviderEngine = RuleProviderEngine(
                directoryURL: dir.appendingPathComponent("RuleProviders", isDirectory: true),
                stagingBaseURL: dir
            )
        } else {
            resolvedRuleProviderEngine = .shared
        }

        self.worker = CloudSyncWorker(
            kvStore: self.kvStore,
            keyStore: self.keyStore,
            injectedCatalogStore: catalogStore,
            ruleProviderEngine: resolvedRuleProviderEngine,
            deviceID: self.deviceID,
            initialDeviceName: resolvedDeviceName,
            needsHostLookup: needsHostLookup
        )

        self.isCloudSyncEnabled = UserDefaults.standard.bool(forKey: "isCloudSyncEnabled")
        let savedTime = UserDefaults.standard.double(forKey: "lastCloudSyncTime")
        if savedTime > 0 {
            self.lastSyncedAt = Date(timeIntervalSince1970: savedTime)
        }

        self.diagnostics = CloudSyncDiagnosticsSnapshot(
            isICloudAccountSignedIn: false,
            isEncryptionKeyAvailable: false,
            pairingFingerprint: nil,
            currentDeviceName: resolvedDeviceName,
            remoteArchive: nil,
            localStorageDirectoryPath: catalogStore?.directoryURL.path
        )
        if isCloudSyncEnabled {
            startObserving()
        }

        let worker = self.worker
        Task.detached(priority: .utility) { [weak self] in
            let name = await worker.resolveDeviceNameIfNeeded()
            let snapshot = await worker.inspectDiagnostics(ubiquityIdentityAvailable: nil)
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.deviceName = name
                self.diagnostics = snapshot
            }
        }
    }

    deinit {
        if let token = observerToken.token {
            NotificationCenter.default.removeObserver(token)
        }
    }

    private func startObserving() {
        guard observerToken.token == nil else { return }
        observerToken.token = NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: kvStore,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                try? await self?.handleExternalChange()
            }
        }
        kvStore.synchronize()
    }

    private func stopObserving() {
        if let token = observerToken.token {
            NotificationCenter.default.removeObserver(token)
            observerToken.token = nil
        }
    }

    // MARK: - Sync Engine
    @discardableResult
    public func sync() async throws -> Bool {
        guard isCloudSyncEnabled else {
            self.status = .enableSyncFirst
            return false
        }
        guard !isSyncing else { return false }

        isSyncing = true
        self.status = .syncing
        defer {
            isSyncing = false
        }

        do {
            let outcome = try await worker.performSync(lastSyncedAt: lastSyncedAt)
            if let providers = outcome.updatedProviders {
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateRuleProviders, object: providers)
            }
            if let userRules = outcome.updatedUserRules {
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateUserRules, object: userRules)
            }
            if let syncedCatalog = outcome.updatedCatalog {
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateProfiles, object: syncedCatalog)
            }
            if let syncedAt = outcome.newLastSyncedAt {
                self.lastSyncedAt = syncedAt
            }
            self.status = outcome.status
            await refreshDiagnosticsAsync()
            return outcome.didSync
        } catch CloudSyncError.keychainUnavailable {
            self.status = .keychainUnavailable
            await refreshDiagnosticsAsync()
            throw CloudSyncError.keychainUnavailable
        } catch CloudSyncError.decryptionFailed {
            self.status = .decryptionFailed
            await refreshDiagnosticsAsync()
            throw CloudSyncError.decryptionFailed
        } catch {
            if let op = (error as? SyncOperationFailure)?.operation {
                self.status = .failed(op, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
            } else {
                self.status = .failed(.sync, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
            }
            await refreshDiagnosticsAsync()
            throw (error as? SyncOperationFailure)?.underlying ?? error
        }
    }

    /// Explicit manual pull from iCloud, bypassing timestamp check.
    @discardableResult
    public func forcePullFromCloud() async throws -> Bool {
        guard isCloudSyncEnabled else {
            self.status = .enableSyncFirst
            return false
        }
        guard !isSyncing else { return false }
        isSyncing = true
        self.status = .pulling
        defer {
            isSyncing = false
        }

        do {
            let outcome = try await worker.performForcePull()
            if let providers = outcome.updatedProviders {
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateRuleProviders, object: providers)
            }
            if let userRules = outcome.updatedUserRules {
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateUserRules, object: userRules)
            }
            if let syncedCatalog = outcome.updatedCatalog {
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateProfiles, object: syncedCatalog)
            }
            if let syncedAt = outcome.newLastSyncedAt {
                self.lastSyncedAt = syncedAt
            }
            self.status = outcome.status
            await refreshDiagnosticsAsync()
            return outcome.didSync
        } catch CloudSyncError.keychainUnavailable {
            self.status = .keychainUnavailable
            await refreshDiagnosticsAsync()
            throw CloudSyncError.keychainUnavailable
        } catch CloudSyncError.decryptionFailed {
            self.status = .decryptionFailed
            await refreshDiagnosticsAsync()
            throw CloudSyncError.decryptionFailed
        } catch {
            let underlying = (error as? SyncOperationFailure)?.underlying ?? error
            self.status = .failed(.pull, cloudError: underlying as? CloudSyncError, detail: underlying.localizedDescription)
            await refreshDiagnosticsAsync()
            throw underlying
        }
    }

    /// Explicit manual push to iCloud.
    @discardableResult
    public func forcePushToCloud() async throws -> Bool {
        guard isCloudSyncEnabled else {
            self.status = .enableSyncFirst
            return false
        }
        guard !isSyncing else { return false }
        isSyncing = true
        self.status = .pushing
        defer {
            isSyncing = false
        }

        do {
            let outcome = try await worker.performForcePush()
            if let syncedAt = outcome.newLastSyncedAt {
                self.lastSyncedAt = syncedAt
            }
            self.status = outcome.status
            await refreshDiagnosticsAsync()
            return outcome.didSync
        } catch {
            let underlying = (error as? SyncOperationFailure)?.underlying ?? error
            self.status = .failed(.push, cloudError: underlying as? CloudSyncError, detail: underlying.localizedDescription)
            await refreshDiagnosticsAsync()
            throw underlying
        }
    }

    nonisolated public static func encryptUserRulesSnapshot(
        _ snapshot: CloudSyncUserRulesSnapshot,
        deviceIdentifier: String,
        keyStore: any ProfileKeyStoring,
        fallbackKey: Data? = nil
    ) throws -> Data {
        let plaintext = try JSONEncoder().encode(snapshot)
        let key: Data
        if let existing = try? keyStore.loadKey(keyID: Self.cloudSyncKeyID), existing.count == 32 {
            key = existing
        } else if let fallbackKey, fallbackKey.count == 32 {
            key = fallbackKey
        } else {
            key = try keyStore.loadOrCreateKey(keyID: Self.cloudSyncKeyID)
        }
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey)
        guard let encryptedCombined = sealedBox.combined else {
            throw CloudSyncError.encryptionFailed
        }
        let sha256 = SHA256.hash(data: encryptedCombined).map { String(format: "%02x", $0) }.joined()
        let payload = CloudSyncPayload(
            deviceIdentifier: deviceIdentifier,
            encryptedData: encryptedCombined,
            sha256: sha256
        )
        let payloadData = try JSONEncoder().encode(payload)
        guard payloadData.count <= 1_000_000 else {
            throw CloudSyncError.payloadTooLarge
        }
        return payloadData
    }

    nonisolated public static func decryptAndMergeUserRulesSnapshot(
        _ payloadData: Data,
        localRules: [CustomRule],
        localBypassPolicy: BypassPolicy,
        localCustomRuleSync: RuleSyncMetadata = .empty,
        localBypassSync: RuleSyncMetadata = .empty,
        keyStore: any ProfileKeyStoring,
        fallbackKey: Data? = nil
    ) throws -> CloudSyncUserRulesSnapshot {
        try reconcileRemoteUserRulesSnapshot(
            payloadData,
            localRules: localRules,
            localBypassPolicy: localBypassPolicy,
            localCustomRuleSync: localCustomRuleSync,
            localBypassSync: localBypassSync,
            keyStore: keyStore,
            fallbackKey: fallbackKey
        ).merged
    }

    nonisolated static func reconcileRemoteUserRulesSnapshot(
        _ payloadData: Data,
        localRules: [CustomRule],
        localBypassPolicy: BypassPolicy,
        localCustomRuleSync: RuleSyncMetadata = .empty,
        localBypassSync: RuleSyncMetadata = .empty,
        keyStore: any ProfileKeyStoring,
        fallbackKey: Data? = nil
    ) throws -> (merged: CloudSyncUserRulesSnapshot, shouldPushRemote: Bool) {
        guard let payload = try? JSONDecoder().decode(CloudSyncPayload.self, from: payloadData) else {
            throw CloudSyncError.catalogCorrupted
        }
        let actualSHA256 = SHA256.hash(data: payload.encryptedData).map { String(format: "%02x", $0) }.joined()
        guard actualSHA256.caseInsensitiveCompare(payload.sha256) == .orderedSame else {
            throw CloudSyncError.catalogCorrupted
        }
        let localKey: Data?
        do {
            let loaded = try keyStore.loadKey(keyID: Self.cloudSyncKeyID)
            localKey = loaded.count == 32 ? loaded : nil
        } catch ProfileKeyStoreError.keyNotFound {
            localKey = nil
        } catch {
            throw CloudSyncError.keychainUnavailable
        }
        guard let sealedBox = try? AES.GCM.SealedBox(combined: payload.encryptedData) else {
            throw CloudSyncError.catalogCorrupted
        }
        let decryptedData: Data
        if let localKey,
           let opened = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: localKey)) {
            decryptedData = opened
        } else if let fallbackKey,
                  fallbackKey.count == 32,
                  let opened = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: fallbackKey)) {
            decryptedData = opened
        } else {
            throw localKey == nil ? CloudSyncError.keychainUnavailable : CloudSyncError.decryptionFailed
        }
        guard let remoteSnapshot = try? JSONDecoder().decode(CloudSyncUserRulesSnapshot.self, from: decryptedData) else {
            throw CloudSyncError.catalogCorrupted
        }

        // Merge by rule ID with change and deletion times, so a rule deleted
        // on one device is not restored by another device's older copy.
        let customMerge = UserRuleSyncMerge.merge(
            local: localRules,
            localMetadata: localCustomRuleSync,
            remote: remoteSnapshot.customRules,
            remoteMetadata: remoteSnapshot.customRuleSync ?? .empty,
            dedupKey: { "\($0.kind.rawValue)|\($0.value.lowercased())" },
            isValid: { CustomRuleValidator.validate(kind: $0.kind, value: $0.value, target: $0.target).isValid },
            limit: CustomRuleCollection.maximumRules
        )
        let bypassMerge = UserRuleSyncMerge.merge(
            local: localBypassPolicy.rules,
            localMetadata: localBypassSync,
            remote: remoteSnapshot.bypassPolicy.rules,
            remoteMetadata: remoteSnapshot.bypassSync ?? .empty,
            dedupKey: { "\($0.kind.rawValue)|\($0.value)" },
            isValid: { (try? BypassRule(id: $0.id, kind: $0.kind, value: $0.value)) != nil },
            limit: BypassPolicy.maximumRules
        )
        let mergedBypassPolicy = (try? BypassPolicy(rules: bypassMerge.rules).validated()) ?? localBypassPolicy

        let merged = CloudSyncUserRulesSnapshot(
            customRules: customMerge.rules,
            bypassPolicy: mergedBypassPolicy,
            customRuleSync: customMerge.metadata,
            bypassSync: bypassMerge.metadata
        )
        let shouldPushRemote = merged.customRules != remoteSnapshot.customRules
            || merged.bypassPolicy != remoteSnapshot.bypassPolicy
            || merged.customRuleSync != (remoteSnapshot.customRuleSync ?? .empty)
            || merged.bypassSync != (remoteSnapshot.bypassSync ?? .empty)
        return (merged, shouldPushRemote)
    }

    private func handleExternalChange() async throws {
        guard isCloudSyncEnabled else { return }
        Self.logger.info("External iCloud change detected, syncing...")
        try await sync()
    }

    nonisolated public static let cloudSyncKeyID = "cloud-sync-master-key.v1"
    /// Legacy KVS key retained strictly as a read-only fallback after authenticating
    /// and decoding remote archives before migrating into synchronized Keychain.
    nonisolated public static let cloudSyncMasterKeyStorageKey = "aetherroute.cloud_sync.master_key.v1"
    /// Synchronizable through iCloud Keychain: shared by the user's devices.
    nonisolated public static let cloudSyncService = "com.aetherroute.profile-encryption.cloud-sync"

    /// Domain-separated, non-reversible 8-hex-character pairing code (`#XXXX-XXXX`)
    /// derived from the 32-byte iCloud Keychain synchronization master key.
    /// Devices signed into the same Apple ID with iCloud Keychain enabled display
    /// the exact same pairing fingerprint without exposing raw key material.
    nonisolated public static func keyFingerprint(for keyData: Data) -> String? {
        guard keyData.count == 32 else { return nil }
        var input = Data("aetherroute.cloud-sync.pairing-fingerprint.v1:".utf8)
        input.append(keyData)
        let digest = Array(SHA256.hash(data: input))
        return String(
            format: "#%02X%02X-%02X%02X",
            digest[0], digest[1], digest[2], digest[3]
        )
    }

    public func localStorageDirectoryURL() -> URL? {
        if let injectedCatalogStore {
            return injectedCatalogStore.directoryURL
        }
        return (try? ProfileCatalogStore.applicationGroup())?.directoryURL
    }

    public func refreshDiagnostics(ubiquityIdentityAvailable: Bool? = nil) {
        let worker = self.worker
        Task.detached(priority: .utility) { [weak self] in
            let snapshot = await worker.inspectDiagnostics(ubiquityIdentityAvailable: ubiquityIdentityAvailable)
            await MainActor.run { [weak self] in
                self?.diagnostics = snapshot
            }
        }
    }

    public func refreshDiagnosticsAsync(ubiquityIdentityAvailable: Bool? = nil) async {
        let snapshot = await worker.inspectDiagnostics(ubiquityIdentityAvailable: ubiquityIdentityAvailable)
        self.diagnostics = snapshot
    }

    public func inspectDiagnostics(ubiquityIdentityAvailable: Bool? = nil) -> CloudSyncDiagnosticsSnapshot {
        Self.buildDiagnosticsSnapshot(
            kvStore: kvStore,
            keyStore: keyStore,
            deviceID: deviceID,
            deviceName: deviceName,
            localStorageDirectoryPath: localStorageDirectoryURL()?.path,
            ubiquityIdentityAvailable: ubiquityIdentityAvailable
        )
    }

    nonisolated private static let compressedCatalogMagic = Data([0x41, 0x52, 0x43, 0x5A]) // "ARCZ"
    nonisolated public static let maximumTotalKVSBytes = 980_000

    nonisolated static func encodeCatalogPayloadData(_ payload: CloudSyncCatalogPayload) throws -> Data {
        let json = try JSONEncoder().encode(payload)
        // Keep standard JSON wire format for normal catalogs so cross-version peers
        // decode seamlessly; compress only when approaching the 1 MB KVS ceiling.
        guard json.count > 750_000 else {
            return json
        }
        if let compressed = try? (json as NSData).compressed(using: .zlib) as Data,
           compressed.count + compressedCatalogMagic.count < json.count {
            var framed = compressedCatalogMagic
            framed.append(compressed)
            return framed
        }
        return json
    }

    nonisolated static func decodeCatalogPayload(from decryptedData: Data) -> CloudSyncCatalogPayload? {
        let candidateData: Data
        if decryptedData.starts(with: compressedCatalogMagic) {
            let body = Data(decryptedData.dropFirst(compressedCatalogMagic.count))
            guard let decompressed = try? (body as NSData).decompressed(using: .zlib) as Data,
                  decompressed.count <= 64 * 1_024 * 1_024 else {
                return nil
            }
            candidateData = decompressed
        } else {
            candidateData = decryptedData
        }
        if let wrapper = try? JSONDecoder().decode(CloudSyncCatalogPayload.self, from: candidateData) {
            return wrapper
        }
        if let legacyCatalog = try? JSONDecoder().decode(ProfileCatalog.self, from: candidateData) {
            return CloudSyncCatalogPayload(catalog: legacyCatalog, deletedProfiles: [:])
        }
        return nil
    }

    /// Authenticates and decrypts a remote cloud payload using the synchronized Keychain key,
    /// falling back read-only to `cloudSyncMasterKeyStorageKey` ONLY after AEAD authentication
    /// and payload decoding succeed.
    nonisolated static func authenticateAndDecodeCatalogPayload(
        _ payload: CloudSyncPayload,
        keyStore: any ProfileKeyStoring,
        kvStore: any CloudKeyValueStoring
    ) throws -> (key: Data, catalogPayload: CloudSyncCatalogPayload, usedLegacyFallback: Bool) {
        let actualSHA256 = SHA256.hash(data: payload.encryptedData).map { String(format: "%02x", $0) }.joined()
        guard payload.version == CloudSyncPayload.currentVersion,
              actualSHA256.caseInsensitiveCompare(payload.sha256) == .orderedSame,
              let sealedBox = try? AES.GCM.SealedBox(combined: payload.encryptedData) else {
            throw CloudSyncError.catalogCorrupted
        }

        let localKey: Data?
        do {
            let loaded = try keyStore.loadKey(keyID: Self.cloudSyncKeyID)
            localKey = loaded.count == 32 ? loaded : nil
        } catch ProfileKeyStoreError.keyNotFound {
            localKey = nil
        } catch {
            throw CloudSyncError.keychainUnavailable
        }

        if let localKey,
           let decrypted = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: localKey)) {
            guard let decoded = Self.decodeCatalogPayload(from: decrypted) else {
                throw CloudSyncError.catalogCorrupted
            }
            return (localKey, decoded, false)
        }

        if let legacyKey = kvStore.data(forKey: Self.cloudSyncMasterKeyStorageKey),
           legacyKey.count == 32,
           let decrypted = try? AES.GCM.open(sealedBox, using: SymmetricKey(data: legacyKey)),
           let decoded = Self.decodeCatalogPayload(from: decrypted) {
            return (legacyKey, decoded, true)
        }

        throw localKey == nil ? CloudSyncError.keychainUnavailable : CloudSyncError.decryptionFailed
    }

    nonisolated static func buildDiagnosticsSnapshot(
        kvStore: any CloudKeyValueStoring,
        keyStore: any ProfileKeyStoring,
        deviceID: String,
        deviceName: String,
        localStorageDirectoryPath: String?,
        ubiquityIdentityAvailable: Bool?
    ) -> CloudSyncDiagnosticsSnapshot {
        let isSignedIn = ubiquityIdentityAvailable ?? (FileManager.default.ubiquityIdentityToken != nil)
        let localKey = (try? keyStore.loadKey(keyID: Self.cloudSyncKeyID)).flatMap { $0.count == 32 ? $0 : nil }
        let fingerprint = localKey.flatMap { Self.keyFingerprint(for: $0) }

        var remoteSummary: CloudSyncArchiveSummary?
        if let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
           let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) {
            var decodedCount: Int?
            let legacyCandidate = kvStore.data(forKey: Self.cloudSyncMasterKeyStorageKey).flatMap { $0.count == 32 ? $0 : nil }
            let inspectionKeys = [localKey, legacyCandidate].compactMap { $0 }
            let actualSHA = SHA256.hash(data: remotePayload.encryptedData).map { String(format: "%02x", $0) }.joined()
            if actualSHA.caseInsensitiveCompare(remotePayload.sha256) == .orderedSame,
               let box = try? AES.GCM.SealedBox(combined: remotePayload.encryptedData) {
                for candidateKey in inspectionKeys {
                    if let plain = try? AES.GCM.open(box, using: SymmetricKey(data: candidateKey)),
                       let catalogPayload = Self.decodeCatalogPayload(from: plain) {
                        decodedCount = catalogPayload.catalog.profiles.count
                        break
                    }
                }
            }
            remoteSummary = CloudSyncArchiveSummary(
                profileCount: decodedCount,
                payloadByteCount: remoteData.count,
                updatedAt: Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0),
                sourceDeviceIdentifier: remotePayload.deviceIdentifier,
                sourceDeviceName: remotePayload.displayDeviceName,
                isFromCurrentDevice: remotePayload.deviceIdentifier == deviceID
            )
        }

        return CloudSyncDiagnosticsSnapshot(
            isICloudAccountSignedIn: isSignedIn,
            isEncryptionKeyAvailable: localKey != nil,
            pairingFingerprint: fingerprint,
            currentDeviceName: deviceName,
            remoteArchive: remoteSummary,
            localStorageDirectoryPath: localStorageDirectoryPath
        )
    }
}

private struct SyncOutcome: Sendable {
    let didSync: Bool
    let status: CloudSyncStatus
    let newLastSyncedAt: Date?
    let updatedCatalog: ProfileCatalog?
    let updatedProviders: [RuleProviderMetadata]?
    let updatedUserRules: CloudSyncUserRulesSnapshot?
}

private struct SyncOperationFailure: Error {
    let operation: CloudSyncStatus.Operation
    let underlying: Error
}

private actor CloudSyncWorker {
    private static let logger = AppLog.logger(category: AppLog.Category.cloudSync)

    private let kvStore: any CloudKeyValueStoring
    private let keyStore: any ProfileKeyStoring
    private let injectedCatalogStore: ProfileCatalogStore?
    private let ruleProviderEngine: RuleProviderEngine
    private let deviceID: String
    private var deviceName: String
    private var needsHostLookup: Bool
    private var authenticatedLegacyKey: Data?

    init(
        kvStore: any CloudKeyValueStoring,
        keyStore: any ProfileKeyStoring,
        injectedCatalogStore: ProfileCatalogStore?,
        ruleProviderEngine: RuleProviderEngine,
        deviceID: String,
        initialDeviceName: String,
        needsHostLookup: Bool
    ) {
        self.kvStore = kvStore
        self.keyStore = keyStore
        self.injectedCatalogStore = injectedCatalogStore
        self.ruleProviderEngine = ruleProviderEngine
        self.deviceID = deviceID
        self.deviceName = initialDeviceName
        self.needsHostLookup = needsHostLookup
    }

    func resolveDeviceNameIfNeeded() -> String {
        if needsHostLookup {
            if let hostName = Host.current().localizedName?.trimmingCharacters(in: .whitespacesAndNewlines), !hostName.isEmpty {
                deviceName = hostName
            } else {
                let fallbackHost = ProcessInfo.processInfo.hostName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !fallbackHost.isEmpty {
                    deviceName = fallbackHost
                }
            }
            needsHostLookup = false
        }
        return deviceName
    }

    func inspectDiagnostics(ubiquityIdentityAvailable: Bool?) -> CloudSyncDiagnosticsSnapshot {
        let currentName = resolveDeviceNameIfNeeded()
        let storagePath: String?
        if let injectedCatalogStore {
            storagePath = injectedCatalogStore.directoryURL.path
        } else {
            storagePath = (try? ProfileCatalogStore.applicationGroup())?.directoryURL.path
        }
        return ProfileCloudSyncManager.buildDiagnosticsSnapshot(
            kvStore: kvStore,
            keyStore: keyStore,
            deviceID: deviceID,
            deviceName: currentName,
            localStorageDirectoryPath: storagePath,
            ubiquityIdentityAvailable: ubiquityIdentityAvailable
        )
    }

    private func ensureCloudAvailable() throws {
        if kvStore is NSUbiquitousKeyValueStore, FileManager.default.ubiquityIdentityToken == nil {
            throw CloudSyncError.cloudUnavailable
        }
        guard kvStore.synchronize() else {
            throw CloudSyncError.cloudUnavailable
        }
    }

    func performSync(lastSyncedAt: Date?) async throws -> SyncOutcome {
        try ensureCloudAvailable()
        _ = resolveDeviceNameIfNeeded()
        let catalogStore = try injectedCatalogStore ?? ProfileCatalogStore.applicationGroup()
        let localCatalog = (try? catalogStore.loadOrMigrate()) ?? ProfileCatalog()
        let localTombstones = catalogStore.loadDeletedProfiles()

        let (updatedProviders, updatedUserRules) = await syncRuleProvidersAndUserRules()

        guard kvStore.synchronize() else {
            throw CloudSyncError.cloudUnavailable
        }
        if let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
           let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) {
            let lastLocalMillis: UInt64
            if let lastSyncedAt, lastSyncedAt.timeIntervalSince1970 > 0 {
                lastLocalMillis = UInt64(lastSyncedAt.timeIntervalSince1970 * 1000)
            } else {
                lastLocalMillis = 0
            }

            if (remotePayload.updatedAtUnixMilliseconds > lastLocalMillis && remotePayload.deviceIdentifier != deviceID)
                || (localCatalog.profiles.isEmpty && remotePayload.updatedAtUnixMilliseconds > 0)
                || ((!localCatalog.profiles.isEmpty || !localTombstones.isEmpty) && remotePayload.deviceIdentifier != deviceID) {
                Self.logger.info("Remote catalog found in iCloud. Pulling and merging...")
                let (appliedCatalog, mergedTombstones, shouldPushBack) = try applyRemotePayload(remotePayload, to: catalogStore)
                let didChangeLocal = appliedCatalog != localCatalog || mergedTombstones != localTombstones
                if shouldPushBack {
                    Self.logger.info("Local profiles reconciled with cloud catalog; pushing reconciled state back to iCloud...")
                    try pushLocalToCloud(appliedCatalog, tombstones: mergedTombstones)
                    return SyncOutcome(
                        didSync: true,
                        status: .merged(profileCount: appliedCatalog.profiles.count),
                        newLastSyncedAt: Date(),
                        updatedCatalog: didChangeLocal ? appliedCatalog : nil,
                        updatedProviders: updatedProviders,
                        updatedUserRules: updatedUserRules
                    )
                }
                return SyncOutcome(
                    didSync: true,
                    status: .pulledLatest(profileCount: appliedCatalog.profiles.count),
                    newLastSyncedAt: Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0),
                    updatedCatalog: didChangeLocal ? appliedCatalog : nil,
                    updatedProviders: updatedProviders,
                    updatedUserRules: updatedUserRules
                )
            }

            if remotePayload.deviceIdentifier == deviceID,
               let (resolvedKey, decodedRemote, usedLegacyFallback) = try? ProfileCloudSyncManager.authenticateAndDecodeCatalogPayload(
                   remotePayload,
                   keyStore: keyStore,
                   kvStore: kvStore
               ),
               decodedRemote.catalog.activeProfileID == localCatalog.activeProfileID,
               decodedRemote.catalog == localCatalog,
               decodedRemote.deletedProfiles == localTombstones {
                _ = resolvedKey
                if !usedLegacyFallback,
                   kvStore.data(forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey) != nil {
                    kvStore.set(nil, forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey)
                    kvStore.synchronize()
                }
                return SyncOutcome(
                    didSync: true,
                    status: .pulledLatest(profileCount: localCatalog.profiles.count),
                    newLastSyncedAt: Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0),
                    updatedCatalog: nil,
                    updatedProviders: updatedProviders,
                    updatedUserRules: updatedUserRules
                )
            }
        }

        if !localCatalog.profiles.isEmpty || !localTombstones.isEmpty {
            do {
                try pushLocalToCloud(localCatalog, tombstones: localTombstones)
                return SyncOutcome(
                    didSync: true,
                    status: .uploaded(profileCount: localCatalog.profiles.count),
                    newLastSyncedAt: Date(),
                    updatedCatalog: nil,
                    updatedProviders: updatedProviders,
                    updatedUserRules: updatedUserRules
                )
            } catch {
                throw SyncOperationFailure(operation: .upload, underlying: error)
            }
        }

        return SyncOutcome(
            didSync: false,
            status: .noCloudData,
            newLastSyncedAt: nil,
            updatedCatalog: nil,
            updatedProviders: updatedProviders,
            updatedUserRules: updatedUserRules
        )
    }

    func performForcePull() async throws -> SyncOutcome {
        try ensureCloudAvailable()
        _ = resolveDeviceNameIfNeeded()
        guard kvStore.synchronize() else {
            throw CloudSyncError.cloudUnavailable
        }
        guard let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
              let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) else {
            return SyncOutcome(
                didSync: false,
                status: .noCloudArchive,
                newLastSyncedAt: nil,
                updatedCatalog: nil,
                updatedProviders: nil,
                updatedUserRules: nil
            )
        }

        let catalogStore = try injectedCatalogStore ?? ProfileCatalogStore.applicationGroup()
        let (applied, _, _) = try applyRemotePayload(remotePayload, to: catalogStore)

        var updatedProviders: [RuleProviderMetadata]?
        if let remoteRuleData = kvStore.data(forKey: RuleProviderSyncPayload.storageKey) {
            let localKey = (try? keyStore.loadKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID))
                .flatMap { $0.count == 32 ? $0 : nil }
            let fallbackKey = resolveAuthenticatedLegacyFallbackKey()
            let outcome = await ruleProviderEngine.mergeCloudSyncPayloadOutcome(
                remoteRuleData,
                encryptionKey: localKey,
                fallbackKey: fallbackKey
            )
            if outcome.didChangeLocal {
                updatedProviders = outcome.providers
            }
        }
        let updatedUserRules = syncUserRulesSnapshot()

        return SyncOutcome(
            didSync: true,
            status: .forcePulled(profileCount: applied.profiles.count),
            newLastSyncedAt: Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0),
            updatedCatalog: applied,
            updatedProviders: updatedProviders,
            updatedUserRules: updatedUserRules
        )
    }

    func performForcePush() async throws -> SyncOutcome {
        try ensureCloudAvailable()
        _ = resolveDeviceNameIfNeeded()
        if !(await ruleProviderEngine.allProviders().isEmpty),
           let pushKey = (try? resolveEncryptionKeyForPush().key),
           let localRulePayload = await ruleProviderEngine.exportCloudSyncPayload(
               deviceIdentifier: deviceID,
               encryptionKey: pushKey
           ),
           totalKVSBytesWouldFit(writing: localRulePayload, forKey: RuleProviderSyncPayload.storageKey) {
            kvStore.set(localRulePayload, forKey: RuleProviderSyncPayload.storageKey)
            guard kvStore.synchronize() else {
                throw CloudSyncError.cloudUnavailable
            }
        }
        pushLocalUserRulesToCloudIfAvailable()

        let catalogStore = try injectedCatalogStore ?? ProfileCatalogStore.applicationGroup()
        let localCatalog = (try? catalogStore.loadOrMigrate()) ?? ProfileCatalog()
        let localTombstones = catalogStore.loadDeletedProfiles()
        guard !localCatalog.profiles.isEmpty || !localTombstones.isEmpty else {
            try ensureCloudAvailable()
            return SyncOutcome(
                didSync: false,
                status: .nothingToUpload,
                newLastSyncedAt: nil,
                updatedCatalog: nil,
                updatedProviders: nil,
                updatedUserRules: nil
            )
        }

        try pushLocalToCloud(localCatalog, tombstones: localTombstones)
        return SyncOutcome(
            didSync: true,
            status: .forcePushed(profileCount: localCatalog.profiles.count),
            newLastSyncedAt: Date(),
            updatedCatalog: nil,
            updatedProviders: nil,
            updatedUserRules: nil
        )
    }

    private func syncRuleProvidersAndUserRules() async -> ([RuleProviderMetadata]?, CloudSyncUserRulesSnapshot?) {
        var updatedProviders: [RuleProviderMetadata]?
        var shouldPushProviders = false
        let localKey = (try? keyStore.loadKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID))
            .flatMap { $0.count == 32 ? $0 : nil }
        let fallbackKey = resolveAuthenticatedLegacyFallbackKey()
            ?? kvStore.data(forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey)
                .flatMap { $0.count == 32 ? $0 : nil }
        if let remoteRuleData = kvStore.data(forKey: RuleProviderSyncPayload.storageKey) {
            let outcome = await ruleProviderEngine.mergeCloudSyncPayloadOutcome(
                remoteRuleData,
                encryptionKey: localKey,
                fallbackKey: fallbackKey
            )
            if outcome.didChangeLocal {
                updatedProviders = outcome.providers
            }
            shouldPushProviders = !outcome.matchesRemote
        } else {
            shouldPushProviders = !(await ruleProviderEngine.allProviders().isEmpty)
        }
        if shouldPushProviders,
           let pushKey = localKey ?? (try? resolveEncryptionKeyForPush().key),
           let localRulePayload = await ruleProviderEngine.exportCloudSyncPayload(
               deviceIdentifier: deviceID,
               encryptionKey: pushKey
           ),
           totalKVSBytesWouldFit(writing: localRulePayload, forKey: RuleProviderSyncPayload.storageKey) {
            kvStore.set(localRulePayload, forKey: RuleProviderSyncPayload.storageKey)
            kvStore.synchronize()
        }
        let updatedUserRules = syncUserRulesSnapshot()
        return (updatedProviders, updatedUserRules)
    }

    private func totalKVSBytesWouldFit(writing newData: Data, forKey targetKey: String) -> Bool {
        let trackedKeys = [
            CloudSyncPayload.storageKey,
            CloudSyncPayload.userRulesStorageKey,
            RuleProviderSyncPayload.storageKey,
        ]
        var total = newData.count
        for key in trackedKeys where key != targetKey {
            total += kvStore.data(forKey: key)?.count ?? 0
        }
        return total <= ProfileCloudSyncManager.maximumTotalKVSBytes
    }

    private func resolveAuthenticatedLegacyFallbackKey() -> Data? {
        if let authenticatedLegacyKey, authenticatedLegacyKey.count == 32 {
            return authenticatedLegacyKey
        }
        if let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
           let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData),
           let (resolvedKey, _, usedFallback) = try? ProfileCloudSyncManager.authenticateAndDecodeCatalogPayload(
               remotePayload,
               keyStore: keyStore,
               kvStore: kvStore
           ),
           usedFallback {
            authenticatedLegacyKey = resolvedKey
            return resolvedKey
        }
        return nil
    }

    private func resolveEncryptionKeyForPush() throws -> (key: Data, canRetireLegacyKey: Bool) {
        if let existing = try? keyStore.loadKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID),
           existing.count == 32 {
            return (existing, true)
        }
        if let legacyKey = resolveAuthenticatedLegacyFallbackKey() {
            return (legacyKey, false)
        }
        let created = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        return (created, true)
    }

    private func resolveUserRuleStores() -> (customStore: CustomRuleStore, bypassStore: BypassPolicyStore)? {
        if let dir = injectedCatalogStore?.directoryURL {
            return (
                CustomRuleStore(directoryURL: dir),
                BypassPolicyStore(directoryURL: dir, keyStore: keyStore)
            )
        }
        guard let customStore = try? CustomRuleStore.applicationGroup(),
              let bypassStore = try? BypassPolicyStore.applicationGroup() else {
            return nil
        }
        return (customStore, bypassStore)
    }

    private func syncUserRulesSnapshot() -> CloudSyncUserRulesSnapshot? {
        guard let stores = resolveUserRuleStores() else {
            return nil
        }
        let customStore = stores.customStore
        let bypassStore = stores.bypassStore
        let localRules = (try? customStore.load()) ?? []
        let localBypass = (try? bypassStore.load()) ?? .empty
        let localRuleSync = customStore.loadSyncMetadata()
        let localBypassSync = bypassStore.loadSyncMetadata()
        let fallbackKey = resolveAuthenticatedLegacyFallbackKey()
            ?? kvStore.data(forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey)
                .flatMap { $0.count == 32 ? $0 : nil }

        if let remoteData = kvStore.data(forKey: CloudSyncPayload.userRulesStorageKey),
           let reconciled = try? ProfileCloudSyncManager.reconcileRemoteUserRulesSnapshot(
               remoteData,
               localRules: localRules,
               localBypassPolicy: localBypass,
               localCustomRuleSync: localRuleSync,
               localBypassSync: localBypassSync,
               keyStore: keyStore,
               fallbackKey: fallbackKey
           ) {
            let merged = reconciled.merged
            let mergedRuleSync = merged.customRuleSync ?? localRuleSync
            let mergedBypassSync = merged.bypassSync ?? localBypassSync
            let customChanged = merged.customRules != localRules || mergedRuleSync != localRuleSync
            let bypassChanged = merged.bypassPolicy != localBypass || mergedBypassSync != localBypassSync
            if customChanged {
                try? customStore.saveSynchronized(merged.customRules, metadata: mergedRuleSync)
            }
            if bypassChanged {
                try? bypassStore.saveSynchronized(merged.bypassPolicy, metadata: mergedBypassSync)
            }
            if reconciled.shouldPushRemote,
               let encoded = try? ProfileCloudSyncManager.encryptUserRulesSnapshot(
                   merged,
                   deviceIdentifier: deviceID,
                   keyStore: keyStore,
                   fallbackKey: resolveAuthenticatedLegacyFallbackKey()
               ),
               totalKVSBytesWouldFit(writing: encoded, forKey: CloudSyncPayload.userRulesStorageKey) {
                kvStore.set(encoded, forKey: CloudSyncPayload.userRulesStorageKey)
                kvStore.synchronize()
            }
            return (customChanged || bypassChanged) ? merged : nil
        } else if !localRules.isEmpty || !localBypass.rules.isEmpty
                    || !localRuleSync.deletedAt.isEmpty || !localBypassSync.deletedAt.isEmpty {
            pushLocalUserRulesToCloudIfAvailable()
        }
        return nil
    }

    private func pushLocalUserRulesToCloudIfAvailable() {
        guard let stores = resolveUserRuleStores() else {
            return
        }
        let customStore = stores.customStore
        let bypassStore = stores.bypassStore
        let localRules = (try? customStore.load()) ?? []
        let localBypass = (try? bypassStore.load()) ?? .empty
        let ruleSync = customStore.loadSyncMetadata()
        let bypassSync = bypassStore.loadSyncMetadata()
        guard !localRules.isEmpty || !localBypass.rules.isEmpty
                || !ruleSync.deletedAt.isEmpty || !bypassSync.deletedAt.isEmpty else { return }
        let snapshot = CloudSyncUserRulesSnapshot(
            customRules: localRules,
            bypassPolicy: localBypass,
            customRuleSync: ruleSync,
            bypassSync: bypassSync
        )
        if let encoded = try? ProfileCloudSyncManager.encryptUserRulesSnapshot(
            snapshot,
            deviceIdentifier: deviceID,
            keyStore: keyStore,
            fallbackKey: resolveAuthenticatedLegacyFallbackKey()
        ),
        totalKVSBytesWouldFit(writing: encoded, forKey: CloudSyncPayload.userRulesStorageKey) {
            kvStore.set(encoded, forKey: CloudSyncPayload.userRulesStorageKey)
            kvStore.synchronize()
        }
    }

    private func pushLocalToCloud(_ catalog: ProfileCatalog, tombstones: [UUID: Date]) throws {
        let syncPayload = CloudSyncCatalogPayload(catalog: catalog, deletedProfiles: tombstones)
        let catalogData = try ProfileCloudSyncManager.encodeCatalogPayloadData(syncPayload)
        let (key, canRetireLegacyKey) = try resolveEncryptionKeyForPush()

        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.seal(catalogData, using: symmetricKey)
        guard let encryptedCombined = sealedBox.combined else {
            throw CloudSyncError.encryptionFailed
        }

        let sha256 = SHA256.hash(data: encryptedCombined).map { String(format: "%02x", $0) }.joined()
        let payload = CloudSyncPayload(
            deviceIdentifier: deviceID,
            deviceName: resolveDeviceNameIfNeeded(),
            encryptedData: encryptedCombined,
            sha256: sha256
        )

        let payloadData = try JSONEncoder().encode(payload)
        guard payloadData.count <= 1_000_000,
              totalKVSBytesWouldFit(writing: payloadData, forKey: CloudSyncPayload.storageKey) else {
            Self.logger.error("Cloud sync payload size exceeds 1MB KVS quota: \(payloadData.count) bytes")
            throw CloudSyncError.payloadTooLarge
        }

        kvStore.set(payloadData, forKey: CloudSyncPayload.storageKey)
        if canRetireLegacyKey,
           kvStore.data(forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey) != nil {
            kvStore.set(nil, forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey)
        }
        guard kvStore.synchronize() else {
            throw CloudSyncError.cloudUnavailable
        }
    }

    private func applyRemotePayload(
        _ payload: CloudSyncPayload,
        to store: ProfileCatalogStore
    ) throws -> (catalog: ProfileCatalog, tombstones: [UUID: Date], shouldPushBack: Bool) {
        let (resolvedKey, remoteCatalogPayload, usedLegacyFallback) = try ProfileCloudSyncManager.authenticateAndDecodeCatalogPayload(
            payload,
            keyStore: keyStore,
            kvStore: kvStore
        )
        if usedLegacyFallback {
            authenticatedLegacyKey = resolvedKey
        }

        let reconciled = try store.reconcileCloudSync(
            remoteCatalogPayload.catalog,
            tombstones: remoteCatalogPayload.deletedProfiles
        )
        // Retire legacy plaintext KVS key only after the synchronized Keychain key succeeds
        // and local catalog persistence finishes.
        if !usedLegacyFallback,
           kvStore.data(forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey) != nil {
            kvStore.set(nil, forKey: ProfileCloudSyncManager.cloudSyncMasterKeyStorageKey)
            kvStore.synchronize()
        }
        let mergedTombstones = store.loadDeletedProfiles()
        let shouldPushBack = Self.remoteNeedsUpdate(
            appliedCatalog: reconciled,
            mergedTombstones: mergedTombstones,
            remoteCatalog: remoteCatalogPayload.catalog,
            remoteTombstones: remoteCatalogPayload.deletedProfiles
        )
        return (reconciled, mergedTombstones, shouldPushBack)
    }

    private static func remoteNeedsUpdate(
        appliedCatalog: ProfileCatalog,
        mergedTombstones: [UUID: Date],
        remoteCatalog: ProfileCatalog,
        remoteTombstones: [UUID: Date]
    ) -> Bool {
        if mergedTombstones != remoteTombstones {
            return true
        }
        if appliedCatalog.profiles.count != remoteCatalog.profiles.count {
            return true
        }
        for localManaged in appliedCatalog.profiles {
            let match = remoteCatalog.profiles.first(where: { $0.id == localManaged.id })
                ?? localManaged.profile.subscription.flatMap { localSub in
                    let canonical = ProfileCatalogStore.canonicalSubscriptionURL(localSub.url)
                    return remoteCatalog.profiles.first {
                        $0.profile.subscription.map {
                            ProfileCatalogStore.canonicalSubscriptionURL($0.url) == canonical
                        } ?? false
                    }
                }
            guard let remoteManaged = match,
                  remoteManaged.profile == localManaged.profile,
                  remoteManaged.updatedAt == localManaged.updatedAt,
                  remoteManaged.mergedSpec == localManaged.mergedSpec else {
                return true
            }
        }
        return false
    }
}

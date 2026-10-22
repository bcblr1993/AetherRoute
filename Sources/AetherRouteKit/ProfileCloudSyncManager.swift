import Combine
import CryptoKit
import Foundation
import OSLog

public extension Notification.Name {
    static let aetherRouteCloudSyncDidUpdateProfiles = Notification.Name("com.aetherroute.cloudSyncDidUpdateProfiles")
    static let aetherRouteCloudSyncDidUpdateRuleProviders = Notification.Name("com.aetherroute.cloudSyncDidUpdateRuleProviders")
    static let aetherRouteCloudSyncDidUpdateUserRules = Notification.Name("com.aetherroute.cloudSyncDidUpdateUserRules")
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

public struct CloudSyncPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let storageKey = "aetherroute.profile_catalog.sync.v1"
    public static let userRulesStorageKey = "aetherroute.user_rules.sync.v1"

    public let version: Int
    public let updatedAtUnixMilliseconds: UInt64
    public let deviceIdentifier: String
    public let encryptedData: Data
    public let sha256: String

    public init(
        version: Int = Self.currentVersion,
        updatedAtUnixMilliseconds: UInt64 = UInt64(max(0, Int64(Date().timeIntervalSince1970 * 1000))),
        deviceIdentifier: String,
        encryptedData: Data,
        sha256: String
    ) {
        self.version = version
        self.updatedAtUnixMilliseconds = updatedAtUnixMilliseconds
        self.deviceIdentifier = deviceIdentifier
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

    private let kvStore: NSUbiquitousKeyValueStore
    private let keyStore: any ProfileKeyStoring
    private let deviceID: String
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
            if isCloudSyncEnabled {
                startObserving()
                Task { try? await sync() }
            } else {
                stopObserving()
            }
        }
    }
    @Published public var status: CloudSyncStatus?

    public init(
        kvStore: NSUbiquitousKeyValueStore = .default,
        keyStore: (any ProfileKeyStoring)? = nil
    ) {
        self.kvStore = kvStore
        if let keyStore {
            self.keyStore = keyStore
        } else {
            let sharedGroup = try? AppConstants.sharedKeychainAccessGroup()
            self.keyStore = DataProtectionProfileKeyStore(
                accessGroup: sharedGroup,
                service: "com.aetherroute.profile-encryption.cloud-sync",
                isSynchronizable: true
            )
        }

        // Retrieve or generate unique device ID
        if let stored = UserDefaults.standard.string(forKey: "aetherroute.device_id") {
            self.deviceID = stored
        } else {
            let newID = UUID().uuidString
            UserDefaults.standard.set(newID, forKey: "aetherroute.device_id")
            self.deviceID = newID
        }

        self.isCloudSyncEnabled = UserDefaults.standard.bool(forKey: "isCloudSyncEnabled")
        let savedTime = UserDefaults.standard.double(forKey: "lastCloudSyncTime")
        if savedTime > 0 {
            self.lastSyncedAt = Date(timeIntervalSince1970: savedTime)
        }

        if isCloudSyncEnabled {
            startObserving()
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
        defer { isSyncing = false }
        self.status = .syncing

        let catalogStore = try ProfileCatalogStore.applicationGroup()
        let localCatalog = try catalogStore.loadOrMigrate()

        // Synchronize lightweight rule providers alongside profiles
        await syncRuleProviders()

        // 1. Fetch remote payload
        kvStore.synchronize()
        if let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
           let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) {

            let lastLocalMillis: UInt64
            if let lastSyncedAt, lastSyncedAt.timeIntervalSince1970 > 0 {
                lastLocalMillis = UInt64(lastSyncedAt.timeIntervalSince1970 * 1000)
            } else {
                lastLocalMillis = 0
            }

            // If remote is newer, or local is empty while remote has profiles
            if (remotePayload.updatedAtUnixMilliseconds > lastLocalMillis && remotePayload.deviceIdentifier != deviceID)
                || (localCatalog.profiles.isEmpty && remotePayload.updatedAtUnixMilliseconds > 0)
                || (!localCatalog.profiles.isEmpty && remotePayload.deviceIdentifier != deviceID) {
                Self.logger.info("Remote catalog found in iCloud. Pulling and merging...")
                do {
                    let (appliedCatalog, didMergeNewLocal) = try await applyRemotePayload(remotePayload, to: catalogStore)
                    self.lastSyncedAt = Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0)
                    if didMergeNewLocal {
                        Self.logger.info("Local profiles merged into cloud catalog; pushing merged union back to iCloud...")
                        try await pushLocalToCloud(appliedCatalog)
                        self.lastSyncedAt = Date()
                        self.status = .merged(profileCount: appliedCatalog.profiles.count)
                    } else {
                        self.status = .pulledLatest(profileCount: appliedCatalog.profiles.count)
                    }
                    return true
                } catch CloudSyncError.keychainUnavailable {
                    self.status = .keychainUnavailable
                    throw CloudSyncError.keychainUnavailable
                } catch CloudSyncError.decryptionFailed {
                    self.status = .decryptionFailed
                    throw CloudSyncError.decryptionFailed
                } catch {
                    self.status = .failed(.sync, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
                    throw error
                }
            }
        }

        // 2. Otherwise push local catalog to iCloud if local has profiles
        if !localCatalog.profiles.isEmpty {
            do {
                try await pushLocalToCloud(localCatalog)
                self.lastSyncedAt = Date()
                self.status = .uploaded(profileCount: localCatalog.profiles.count)
                return true
            } catch {
                self.status = .failed(.upload, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
                throw error
            }
        }

        // 3. Both local and remote are empty or no remote data yet
        self.status = .noCloudData
        return false
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
        defer { isSyncing = false }
        self.status = .pulling

        kvStore.synchronize()
        guard let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
              let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) else {
            self.status = .noCloudArchive
            return false
        }
        do {
            let catalogStore = try ProfileCatalogStore.applicationGroup()
            let (applied, _) = try await applyRemotePayload(remotePayload, to: catalogStore)
            if let remoteRuleData = kvStore.data(forKey: RuleProviderSyncPayload.storageKey) {
                let updatedProviders = await RuleProviderEngine.shared.mergeCloudSyncPayload(remoteRuleData)
                NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateRuleProviders, object: updatedProviders)
            }
            syncUserRulesSnapshot()
            self.lastSyncedAt = Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0)
            self.status = .forcePulled(profileCount: applied.profiles.count)
            return true
        } catch CloudSyncError.keychainUnavailable {
            self.status = .keychainUnavailable
            throw CloudSyncError.keychainUnavailable
        } catch CloudSyncError.decryptionFailed {
            self.status = .decryptionFailed
            throw CloudSyncError.decryptionFailed
        } catch {
            self.status = .failed(.pull, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
            throw error
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
        defer { isSyncing = false }
        self.status = .pushing

        if let localRulePayload = await RuleProviderEngine.shared.exportCloudSyncPayload(deviceIdentifier: deviceID) {
            kvStore.set(localRulePayload, forKey: RuleProviderSyncPayload.storageKey)
            kvStore.synchronize()
        }
        pushLocalUserRulesToCloudIfAvailable()

        let catalogStore = try ProfileCatalogStore.applicationGroup()
        let localCatalog = try catalogStore.loadOrMigrate()
        guard !localCatalog.profiles.isEmpty else {
            self.status = .nothingToUpload
            return false
        }

        do {
            try await pushLocalToCloud(localCatalog)
            self.lastSyncedAt = Date()
            self.status = .forcePushed(profileCount: localCatalog.profiles.count)
            return true
        } catch {
            self.status = .failed(.push, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
            throw error
        }
    }

    private func syncRuleProviders() async {
        if let remoteRuleData = kvStore.data(forKey: RuleProviderSyncPayload.storageKey) {
            let updatedProviders = await RuleProviderEngine.shared.mergeCloudSyncPayload(remoteRuleData)
            NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateRuleProviders, object: updatedProviders)
        }
        if let localRulePayload = await RuleProviderEngine.shared.exportCloudSyncPayload(deviceIdentifier: deviceID) {
            kvStore.set(localRulePayload, forKey: RuleProviderSyncPayload.storageKey)
            kvStore.synchronize()
        }
        syncUserRulesSnapshot()
    }

    private func syncUserRulesSnapshot() {
        guard let customStore = try? CustomRuleStore.applicationGroup(),
              let bypassStore = try? BypassPolicyStore.applicationGroup() else {
            return
        }
        let localRules = (try? customStore.load()) ?? []
        let localBypass = (try? bypassStore.load()) ?? .empty
        let localRuleSync = customStore.loadSyncMetadata()
        let localBypassSync = bypassStore.loadSyncMetadata()

        if let remoteData = kvStore.data(forKey: CloudSyncPayload.userRulesStorageKey),
           let merged = try? Self.decryptAndMergeUserRulesSnapshot(
               remoteData,
               localRules: localRules,
               localBypassPolicy: localBypass,
               localCustomRuleSync: localRuleSync,
               localBypassSync: localBypassSync,
               keyStore: keyStore
           ) {
            let mergedRuleSync = merged.customRuleSync ?? localRuleSync
            let mergedBypassSync = merged.bypassSync ?? localBypassSync
            if merged.customRules != localRules || mergedRuleSync != localRuleSync {
                try? customStore.saveSynchronized(merged.customRules, metadata: mergedRuleSync)
            }
            if merged.bypassPolicy != localBypass || mergedBypassSync != localBypassSync {
                try? bypassStore.saveSynchronized(merged.bypassPolicy, metadata: mergedBypassSync)
            }
            NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateUserRules, object: merged)
            // Always publish the merge: the remote copy may lack this
            // device's deletions even when the merge changed nothing here.
            if let encoded = try? Self.encryptUserRulesSnapshot(
                merged,
                deviceIdentifier: deviceID,
                keyStore: keyStore
            ), encoded != remoteData {
                kvStore.set(encoded, forKey: CloudSyncPayload.userRulesStorageKey)
                kvStore.synchronize()
            }
        } else if !localRules.isEmpty || !localBypass.rules.isEmpty
                    || !localRuleSync.deletedAt.isEmpty || !localBypassSync.deletedAt.isEmpty {
            pushLocalUserRulesToCloudIfAvailable()
        }
    }

    private func pushLocalUserRulesToCloudIfAvailable() {
        guard let customStore = try? CustomRuleStore.applicationGroup(),
              let bypassStore = try? BypassPolicyStore.applicationGroup() else {
            return
        }
        let localRules = (try? customStore.load()) ?? []
        let localBypass = (try? bypassStore.load()) ?? .empty
        let ruleSync = customStore.loadSyncMetadata()
        let bypassSync = bypassStore.loadSyncMetadata()
        // An empty list with deletions is still news: it removes the rules
        // other devices hold.
        guard !localRules.isEmpty || !localBypass.rules.isEmpty
                || !ruleSync.deletedAt.isEmpty || !bypassSync.deletedAt.isEmpty else { return }
        let snapshot = CloudSyncUserRulesSnapshot(
            customRules: localRules,
            bypassPolicy: localBypass,
            customRuleSync: ruleSync,
            bypassSync: bypassSync
        )
        if let encoded = try? Self.encryptUserRulesSnapshot(
            snapshot,
            deviceIdentifier: deviceID,
            keyStore: keyStore
        ) {
            kvStore.set(encoded, forKey: CloudSyncPayload.userRulesStorageKey)
            kvStore.synchronize()
        }
    }

    nonisolated public static func encryptUserRulesSnapshot(
        _ snapshot: CloudSyncUserRulesSnapshot,
        deviceIdentifier: String,
        keyStore: any ProfileKeyStoring
    ) throws -> Data {
        let plaintext = try JSONEncoder().encode(snapshot)
        let key = try keyStore.loadOrCreateKey(keyID: Self.cloudSyncKeyID)
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
        keyStore: any ProfileKeyStoring
    ) throws -> CloudSyncUserRulesSnapshot {
        guard let payload = try? JSONDecoder().decode(CloudSyncPayload.self, from: payloadData) else {
            throw CloudSyncError.catalogCorrupted
        }
        let actualSHA256 = SHA256.hash(data: payload.encryptedData).map { String(format: "%02x", $0) }.joined()
        guard actualSHA256.caseInsensitiveCompare(payload.sha256) == .orderedSame else {
            throw CloudSyncError.catalogCorrupted
        }
        let key: Data
        do {
            key = try keyStore.loadKey(keyID: Self.cloudSyncKeyID)
        } catch {
            throw CloudSyncError.keychainUnavailable
        }
        let symmetricKey = SymmetricKey(data: key)
        guard let sealedBox = try? AES.GCM.SealedBox(combined: payload.encryptedData) else {
            throw CloudSyncError.catalogCorrupted
        }
        guard let decryptedData = try? AES.GCM.open(sealedBox, using: symmetricKey) else {
            throw CloudSyncError.decryptionFailed
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

        return CloudSyncUserRulesSnapshot(
            customRules: customMerge.rules,
            bypassPolicy: mergedBypassPolicy,
            customRuleSync: customMerge.metadata,
            bypassSync: bypassMerge.metadata
        )
    }

    private func handleExternalChange() async throws {
        guard isCloudSyncEnabled else { return }
        Self.logger.info("External iCloud change detected, syncing...")
        try await sync()
    }

    nonisolated public static let cloudSyncKeyID = "cloud-sync-master-key.v1"

    // MARK: - Encryption & Cloud Push/Pull
    private func pushLocalToCloud(_ catalog: ProfileCatalog) async throws {
        let catalogData = try JSONEncoder().encode(catalog)
        let key = try keyStore.loadOrCreateKey(keyID: Self.cloudSyncKeyID)

        // AES-256-GCM encryption
        let symmetricKey = SymmetricKey(data: key)
        let sealedBox = try AES.GCM.seal(catalogData, using: symmetricKey)
        guard let encryptedCombined = sealedBox.combined else {
            throw CloudSyncError.encryptionFailed
        }

        let sha256 = SHA256.hash(data: encryptedCombined).map { String(format: "%02x", $0) }.joined()
        let payload = CloudSyncPayload(
            deviceIdentifier: deviceID,
            encryptedData: encryptedCombined,
            sha256: sha256
        )

        let payloadData = try JSONEncoder().encode(payload)
        guard payloadData.count <= 1_000_000 else {
            Self.logger.error("Cloud sync payload size exceeds 1MB limit: \(payloadData.count) bytes")
            throw CloudSyncError.payloadTooLarge
        }

        kvStore.set(payloadData, forKey: CloudSyncPayload.storageKey)
        kvStore.synchronize()
    }

    @discardableResult
    private func applyRemotePayload(
        _ payload: CloudSyncPayload,
        to store: ProfileCatalogStore
    ) async throws -> (catalog: ProfileCatalog, didMergeNewLocalProfiles: Bool) {
        // Verify SHA-256 integrity
        let actualSHA256 = SHA256.hash(data: payload.encryptedData).map { String(format: "%02x", $0) }.joined()
        guard actualSHA256.caseInsensitiveCompare(payload.sha256) == .orderedSame else {
            Self.logger.error("Cloud sync payload SHA256 integrity verification failed: expected \(payload.sha256), got \(actualSHA256)")
            throw CloudSyncError.catalogCorrupted
        }

        let key: Data
        do {
            key = try keyStore.loadKey(keyID: Self.cloudSyncKeyID)
        } catch {
            Self.logger.error("Failed to load cloud sync master key from Keychain: \(String(describing: error), privacy: .public)")
            throw CloudSyncError.keychainUnavailable
        }
        let symmetricKey = SymmetricKey(data: key)

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: payload.encryptedData)
        } catch {
            throw CloudSyncError.catalogCorrupted
        }

        guard let decryptedData = try? AES.GCM.open(sealedBox, using: symmetricKey) else {
            Self.logger.error("Failed to decrypt remote catalog payload with master key")
            throw CloudSyncError.decryptionFailed
        }

        guard let remoteCatalog = try? JSONDecoder().decode(ProfileCatalog.self, from: decryptedData) else {
            throw CloudSyncError.catalogCorrupted
        }

        let localCatalog = (try? store.loadOrMigrate()) ?? ProfileCatalog()
        let resultCatalog: ProfileCatalog
        var didMergeNewLocalProfiles = false

        if localCatalog.profiles.isEmpty {
            try store.replaceCatalog(remoteCatalog)
            resultCatalog = remoteCatalog
        } else {
            // Smart merge with existing local profiles
            if !remoteCatalog.profiles.isEmpty {
                let merged = try store.mergeValidated(remoteCatalog)
                resultCatalog = merged
                didMergeNewLocalProfiles = (resultCatalog != remoteCatalog)
            } else {
                resultCatalog = localCatalog
                didMergeNewLocalProfiles = true
            }
        }
        NotificationCenter.default.post(name: .aetherRouteCloudSyncDidUpdateProfiles, object: resultCatalog)
        return (resultCatalog, didMergeNewLocalProfiles)
    }
}

import Combine
import CryptoKit
import Foundation
import OSLog

public extension Notification.Name {
    static let aetherRouteCloudSyncDidUpdateProfiles = Notification.Name("com.aetherroute.cloudSyncDidUpdateProfiles")
}

public struct CloudSyncPayload: Codable, Sendable, Equatable {
    public static let currentVersion = 1
    public static let storageKey = "aetherroute.profile_catalog.sync.v1"

    public let version: Int
    public let updatedAtUnixMilliseconds: UInt64
    public let deviceIdentifier: String
    public let encryptedData: Data
    public let sha256: String

    public init(
        version: Int = Self.currentVersion,
        updatedAtUnixMilliseconds: UInt64 = UInt64(Date().timeIntervalSince1970 * 1000),
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

public enum CloudSyncError: LocalizedError, Equatable {
    case cloudUnavailable
    case encryptionFailed
    case decryptionFailed
    case catalogCorrupted
    case keychainUnavailable
    case payloadTooLarge

    public var errorDescription: String? {
        switch self {
        case .cloudUnavailable:
            "iCloud 存储不可用，请登录 Apple ID / iCloud storage unavailable"
        case .encryptionFailed:
            "配置加密失败 / Failed to encrypt profile for iCloud"
        case .decryptionFailed:
            "配置解密失败，密钥不匹配 / Failed to decrypt profile from iCloud"
        case .catalogCorrupted:
            "云端配置损坏或校验和不匹配 / Cloud profile catalog corrupted or checksum mismatch"
        case .keychainUnavailable:
            "安全密钥不可用 / Security keychain key unavailable"
        case .payloadTooLarge:
            "云端配置超出容量限制 (1MB) / Cloud profile catalog exceeds 1MB limit"
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
    @Published public var statusMessage: String?

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
            self.statusMessage = "请先开启 iCloud 端到端加密同步"
            return false
        }
        guard !isSyncing else { return false }

        isSyncing = true
        defer { isSyncing = false }
        self.statusMessage = "正在同步 iCloud 配置..."

        let catalogStore = try ProfileCatalogStore.applicationGroup()
        let localCatalog = try catalogStore.loadOrMigrate()

        // 1. Fetch remote payload
        kvStore.synchronize()
        if let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
           let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) {

            let lastLocalMillis = UInt64((lastSyncedAt ?? Date.distantPast).timeIntervalSince1970 * 1000)

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
                        self.statusMessage = "已合并并双向同步至 iCloud (\(appliedCatalog.profiles.count) 个配置)"
                    } else {
                        self.statusMessage = "已从 iCloud 同步最新配置 (\(appliedCatalog.profiles.count) 个配置)"
                    }
                    return true
                } catch CloudSyncError.keychainUnavailable {
                    self.statusMessage = "未获取到加密密钥：请在系统设置中开启「iCloud 密码与钥匙串」并稍候"
                    throw CloudSyncError.keychainUnavailable
                } catch CloudSyncError.decryptionFailed {
                    self.statusMessage = "解密失败：请确保设备登录同一 Apple ID 并开启 iCloud 钥匙串"
                    throw CloudSyncError.decryptionFailed
                } catch {
                    self.statusMessage = "同步失败: \(error.localizedDescription)"
                    throw error
                }
            }
        }

        // 2. Otherwise push local catalog to iCloud if local has profiles
        if !localCatalog.profiles.isEmpty {
            do {
                try await pushLocalToCloud(localCatalog)
                self.lastSyncedAt = Date()
                self.statusMessage = "本地配置已加密同步至 iCloud (\(localCatalog.profiles.count) 个配置)"
                return true
            } catch {
                self.statusMessage = "上传至 iCloud 失败: \(error.localizedDescription)"
                throw error
            }
        }

        // 3. Both local and remote are empty or no remote data yet
        self.statusMessage = "iCloud 云端暂无配置数据 (请在已配置设备上开启同步并上传)"
        return false
    }

    /// Explicit manual pull from iCloud, bypassing timestamp check.
    @discardableResult
    public func forcePullFromCloud() async throws -> Bool {
        guard isCloudSyncEnabled else {
            self.statusMessage = "请先开启 iCloud 端到端加密同步"
            return false
        }
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        self.statusMessage = "正在从 iCloud 拉取配置..."

        kvStore.synchronize()
        guard let remoteData = kvStore.data(forKey: CloudSyncPayload.storageKey),
              let remotePayload = try? JSONDecoder().decode(CloudSyncPayload.self, from: remoteData) else {
            self.statusMessage = "iCloud 云端暂无配置归档 (或云端数据尚未同步到本机缓存，请稍候再试)"
            return false
        }
        do {
            let catalogStore = try ProfileCatalogStore.applicationGroup()
            let (applied, _) = try await applyRemotePayload(remotePayload, to: catalogStore)
            self.lastSyncedAt = Date(timeIntervalSince1970: Double(remotePayload.updatedAtUnixMilliseconds) / 1000.0)
            self.statusMessage = "已强制从 iCloud 拉取配置 (\(applied.profiles.count) 个配置)"
            return true
        } catch CloudSyncError.keychainUnavailable {
            self.statusMessage = "未获取到加密密钥：请在系统设置中开启「iCloud 密码与钥匙串」并稍候"
            throw CloudSyncError.keychainUnavailable
        } catch CloudSyncError.decryptionFailed {
            self.statusMessage = "解密失败：请确保设备登录同一 Apple ID 并开启 iCloud 钥匙串"
            throw CloudSyncError.decryptionFailed
        } catch {
            self.statusMessage = "拉取失败: \(error.localizedDescription)"
            throw error
        }
    }

    /// Explicit manual push to iCloud.
    @discardableResult
    public func forcePushToCloud() async throws -> Bool {
        guard isCloudSyncEnabled else {
            self.statusMessage = "请先开启 iCloud 端到端加密同步"
            return false
        }
        guard !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        self.statusMessage = "正在上传配置至 iCloud..."

        let catalogStore = try ProfileCatalogStore.applicationGroup()
        let localCatalog = try catalogStore.loadOrMigrate()
        guard !localCatalog.profiles.isEmpty else {
            self.statusMessage = "本地配置为空，无需上传"
            return false
        }

        do {
            try await pushLocalToCloud(localCatalog)
            self.lastSyncedAt = Date()
            self.statusMessage = "已强制推送至 iCloud (\(localCatalog.profiles.count) 个配置)"
            return true
        } catch {
            self.statusMessage = "上传失败: \(error.localizedDescription)"
            throw error
        }
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

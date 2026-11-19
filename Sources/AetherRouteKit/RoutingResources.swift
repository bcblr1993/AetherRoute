import CryptoKit
import Darwin
@preconcurrency import Foundation

public enum RoutingResourceKind: String, CaseIterable, Codable, Hashable,
    Sendable
{
    case countryMMDB
    case geoSite
    case asnMMDB

    public var fileName: String {
        switch self {
        case .countryMMDB: "Country.mmdb"
        case .geoSite: "GeoSite.dat"
        case .asnMMDB: "ASN.mmdb"
        }
    }

    public var maximumBytes: Int {
        switch self {
        case .countryMMDB: 64 * 1_024 * 1_024
        case .geoSite: 64 * 1_024 * 1_024
        case .asnMMDB: 64 * 1_024 * 1_024
        }
    }
}

public extension ProfileConfigurationSummary {
    var requiredRoutingResources: Set<RoutingResourceKind> {
        var resources = Set<RoutingResourceKind>()
        if requiresCountryMMDB { resources.insert(.countryMMDB) }
        if requiresGeoSiteDatabase { resources.insert(.geoSite) }
        if allRules.contains(where: { rule in
            let kind = rule.kind.uppercased()
            if kind == "IP-ASN" || kind == "SRC-IP-ASN" {
                return true
            }
            if let criteria = rule.criteria?.uppercased(),
               criteria.contains("IP-ASN,") || criteria.contains("SRC-IP-ASN,") {
                return true
            }
            return false
        }) {
            resources.insert(.asnMMDB)
        }
        return resources
    }
}

public enum RoutingResourceOrigin: String, Codable, Equatable, Sendable {
    /// Public data distributed with the signed app (DB-IP Lite and V2Fly).
    case bundled
    case verifiedDownload
    case userProvided
}

public struct RoutingResourceRecord: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let kind: RoutingResourceKind
    public let sha256: String
    public let byteCount: Int
    public let installedAt: Date
    public let origin: RoutingResourceOrigin
    /// When the upstream checksum last matched these exact bytes. Absent in
    /// metadata written before 1.1.6, which decodes it as nil.
    public let lastCheckedAt: Date?

    public init(
        kind: RoutingResourceKind,
        sha256: String,
        byteCount: Int,
        installedAt: Date,
        origin: RoutingResourceOrigin,
        lastCheckedAt: Date? = nil
    ) {
        formatVersion = Self.currentFormatVersion
        self.kind = kind
        self.sha256 = sha256
        self.byteCount = byteCount
        self.installedAt = installedAt
        self.origin = origin
        self.lastCheckedAt = lastCheckedAt
    }

    /// The last time these bytes were known to match their upstream release:
    /// installation, or a later checksum check that found nothing newer.
    public var verifiedCurrentAt: Date {
        max(installedAt, lastCheckedAt ?? installedAt)
    }
}

/// When AetherRoute looks upstream for newer routing databases. The country
/// database is rebuilt weekly and the domain list changes in small steps, so
/// a weekly checksum check keeps both current without daily downloads, and
/// leaves three weeks of retries before the 30-day expiry is reached.
public enum RoutingResourceRefreshPolicy {
    public static let checkInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let expiryWarningAge: TimeInterval = 25 * 24 * 60 * 60
    public static let retryDelays: [TimeInterval] = [
        60 * 60, 6 * 60 * 60, 24 * 60 * 60,
    ]

    /// User imports are never replaced automatically.
    public static func isDue(
        _ record: RoutingResourceRecord,
        now: Date
    ) -> Bool {
        record.origin != .userProvided
            && now.timeIntervalSince(record.verifiedCurrentAt) >= checkInterval
    }

    public static func isNearingExpiry(
        _ record: RoutingResourceRecord,
        now: Date
    ) -> Bool {
        now.timeIntervalSince(record.verifiedCurrentAt) >= expiryWarningAge
    }

    public static func retryDelay(afterConsecutiveFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return retryDelays[min(failures, retryDelays.count) - 1]
    }
}

public enum RoutingResourceStatus: Equatable, Sendable {
    case missing
    case ready(RoutingResourceRecord)
    case stale(RoutingResourceRecord)
    case invalid(RoutingResourceError)

    public var isUsableForConnection: Bool {
        switch self {
        case .ready: true
        case let .stale(record):
            // The maintained Country and ASN downloads currently use MaxMind data.
            // Retain their expiry policy; our DB-IP bundle and the MIT GeoSite
            // list can remain available while a refresh is attempted.
            (record.kind != .countryMMDB && record.kind != .asnMMDB)
                || record.origin != .verifiedDownload
        case .missing, .invalid: false
        }
    }
}

public struct RoutingResourceStore: Sendable {
    public static let maximumResourceAge: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumMetadataBytes = 8 * 1_024
    private static let clockSkewTolerance: TimeInterval = 5 * 60

    public let applicationSupportDirectory: URL

    private var resourceDirectory: URL {
        applicationSupportDirectory.appendingPathComponent(
            "RoutingResources",
            isDirectory: true
        )
    }

    public init(applicationSupportDirectory: URL) {
        self.applicationSupportDirectory = applicationSupportDirectory
    }

    public static func applicationGroup(
        fileManager: FileManager = .default
    ) throws -> Self {
        let profileStore = try ActiveProfileStore.applicationGroup(
            fileManager: fileManager
        )
        return Self(applicationSupportDirectory: profileStore.directoryURL)
    }

    @discardableResult
    public func installVerified(
        data: Data,
        kind: RoutingResourceKind,
        expectedSHA256: String,
        installedAt: Date = .now,
        fileManager: FileManager = .default,
        replacing expectedRecord: RoutingResourceRecord? = nil
    ) throws -> RoutingResourceRecord {
        guard Self.isLowercaseSHA256(expectedSHA256) else {
            throw RoutingResourceError.invalidExpectedSHA256
        }
        let digest = try Self.validate(data: data, kind: kind)
        guard digest == expectedSHA256 else {
            throw RoutingResourceError.checksumMismatch(kind)
        }
        return try commit(
            data: data,
            kind: kind,
            digest: digest,
            installedAt: installedAt,
            origin: .verifiedDownload,
            fileManager: fileManager,
            replacing: expectedRecord
        )
    }

    @discardableResult
    public func installBundled(
        data: Data,
        kind: RoutingResourceKind,
        expectedSHA256: String,
        installedAt: Date = .now,
        fileManager: FileManager = .default,
        preservingUsableResource: Bool = false
    ) throws -> RoutingResourceRecord {
        guard Self.isLowercaseSHA256(expectedSHA256) else {
            throw RoutingResourceError.invalidExpectedSHA256
        }
        let digest = try Self.validate(data: data, kind: kind)
        guard digest == expectedSHA256 else {
            throw RoutingResourceError.checksumMismatch(kind)
        }
        return try commit(
            data: data, kind: kind, digest: digest, installedAt: installedAt,
            origin: .bundled, fileManager: fileManager,
            preservingUsableResource: preservingUsableResource
        )
    }

    @discardableResult
    public func installUserProvided(
        data: Data,
        kind: RoutingResourceKind,
        installedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> RoutingResourceRecord {
        let digest = try Self.validate(data: data, kind: kind)
        return try commit(
            data: data,
            kind: kind,
            digest: digest,
            installedAt: installedAt,
            origin: .userProvided,
            fileManager: fileManager
        )
    }

    public func status(
        for kind: RoutingResourceKind,
        now: Date = .now,
        fileManager: FileManager = .default
    ) -> RoutingResourceStatus {
        do {
            return try withResourceReadLock(for: [kind], fileManager: fileManager) {
                let record = try loadVerifiedRecord(for: kind, fileManager: fileManager)
                return try Self.status(for: record, now: now)
            }
        } catch let error as RoutingResourceError {
            if error == .missing(kind) { return .missing }
            return .invalid(error)
        } catch {
            return .invalid(.metadataUnreadable(kind))
        }
    }

    /// Verifies every required database and atomically places identical copies
    /// in the Packet Tunnel and FlowOnly runtime directories. This performs no
    /// network access and rejects symlinked runtime paths.
    @discardableResult
    public func prepareRuntimeResources(
        for profileYAML: String,
        now: Date = .now,
        fileManager: FileManager = .default
    ) throws -> Set<RoutingResourceKind> {
        let verifiedData = try launchResourceSnapshot(
            for: profileYAML, now: now, fileManager: fileManager
        )
        guard !verifiedData.isEmpty else { return [] }

        let runtimeRoot = applicationSupportDirectory.appendingPathComponent(
            "Runtime",
            isDirectory: true
        )
        let flowRuntime = runtimeRoot.appendingPathComponent(
            "FlowCore",
            isDirectory: true
        )
        try preparePrivateDirectory(runtimeRoot, fileManager: fileManager)
        try preparePrivateDirectory(flowRuntime, fileManager: fileManager)
        try verifyRuntimeHierarchy(
            runtimeRoot: runtimeRoot,
            flowRuntime: flowRuntime
        )

        for (kind, data) in verifiedData {
            for directory in [runtimeRoot, flowRuntime] {
                try writeProtected(
                    data,
                    to: directory.appendingPathComponent(
                        kind.fileName,
                        isDirectory: false
                    ),
                    fileManager: fileManager
                )
            }
        }
        return Set(verifiedData.keys)
    }

    /// Returns the exact verified public routing databases needed by one
    /// profile so a root-context Network System Extension can install them in
    /// its own private runtime container. Profile YAML and credentials are not
    /// written by this operation.
    public func launchResourceSnapshot(
        for profileYAML: String,
        now: Date = .now,
        fileManager: FileManager = .default
    ) throws -> [RoutingResourceKind: Data] {
        let requirements = ProfileConfigurationInspector
            .inspect(yaml: profileYAML)
            .requiredRoutingResources
        return try withResourceReadLock(for: requirements, fileManager: fileManager) {
            var snapshot = [RoutingResourceKind: Data]()
            for kind in requirements {
                let resource = try loadVerifiedResource(for: kind, fileManager: fileManager)
                let status = try Self.status(for: resource.record, now: now)
                guard status.isUsableForConnection else {
                    throw RoutingResourceError.stale(kind, installedAt: resource.record.installedAt)
                }
                // Return the same bytes that were checked against the record,
                // rather than reopening the asset after releasing its lock.
                snapshot[kind] = resource.data
            }
            return snapshot
        }
    }

    /// Resolves required routing resources inside a running Network Extension
    /// during `.reloadProfile`, installing any inline resources carried in the
    /// reload payload and falling back to the signed host `.app`'s bundled
    /// databases when a newly required database is absent from `root`'s container.
    public func resolveReloadResourceSnapshot(
        for profileYAML: String,
        inlineResources: [RoutingResourceKind: Data]? = nil,
        extensionBundle: Bundle = .main,
        now: Date = .now,
        fileManager: FileManager = .default
    ) throws -> [RoutingResourceKind: Data] {
        if let inlineResources {
            for (kind, data) in inlineResources where !data.isEmpty {
                _ = try installUserProvided(
                    data: data,
                    kind: kind,
                    installedAt: now,
                    fileManager: fileManager
                )
            }
        }
        let requirements = ProfileConfigurationInspector
            .inspect(yaml: profileYAML)
            .requiredRoutingResources
        let hasMissing = requirements.contains { kind in
            !status(for: kind, now: now, fileManager: fileManager).isUsableForConnection
        }
        if hasMissing,
           let bundledDir = BundledRoutingResources.extensionFallbackDirectoryURL(
               extensionBundle: extensionBundle
           ) {
            _ = try? BundledRoutingResources(directoryURL: bundledDir)
                .installMissingResources(for: profileYAML, in: self)
        }
        return try launchResourceSnapshot(
            for: profileYAML,
            now: now,
            fileManager: fileManager
        )
    }

    /// Returns lowercase SHA-256 digests of usable routing databases currently
    /// installed in this store.
    public func usableResourceDigests(
        now: Date = .now,
        fileManager: FileManager = .default
    ) -> [RoutingResourceKind: String] {
        var digests: [RoutingResourceKind: String] = [:]
        for kind in RoutingResourceKind.allCases {
            switch status(for: kind, now: now, fileManager: fileManager) {
            case let .ready(record):
                digests[kind] = record.sha256
            case let .stale(record) where RoutingResourceStatus.stale(record).isUsableForConnection:
                digests[kind] = record.sha256
            default:
                break
            }
        }
        return digests
    }

    private func commit(
        data: Data,
        kind: RoutingResourceKind,
        digest: String,
        installedAt: Date,
        origin: RoutingResourceOrigin,
        fileManager: FileManager,
        replacing expectedRecord: RoutingResourceRecord? = nil,
        preservingUsableResource: Bool = false
    ) throws -> RoutingResourceRecord {
        try preparePrivateDirectory(
            applicationSupportDirectory,
            fileManager: fileManager
        )
        try preparePrivateDirectory(resourceDirectory, fileManager: fileManager)
        let normalizedInstallDate = Date(
            timeIntervalSince1970: installedAt.timeIntervalSince1970
                .rounded(.down)
        )
        let record = RoutingResourceRecord(
            kind: kind,
            sha256: digest,
            byteCount: data.count,
            installedAt: normalizedInstallDate,
            origin: origin
        )
        let metadata = try Self.encodedMetadata(record)

        // Finish both writes, file protection and validation without changing
        // the live pair. Staging shares the resource filesystem so committing
        // and restoring backups need no second copy of a large database.
        let stagingDirectory = resourceDirectory.appendingPathComponent(
            ".staging-\(UUID().uuidString)", isDirectory: true
        )
        guard Darwin.mkdir(stagingDirectory.path, 0o700) == 0 else {
            throw RoutingResourceError.writeFailed
        }
        let stagedData = stagingDirectory.appendingPathComponent(kind.fileName)
        let stagedMetadata = stagingDirectory.appendingPathComponent(
            metadataURL(for: kind).lastPathComponent
        )
        let committed: RoutingResourceRecord
        do {
            try preparePrivateDirectory(
                stagingDirectory,
                fileManager: fileManager,
                excludeFromBackup: false
            )
            try writeProtected(data, to: stagedData, fileManager: fileManager)
            try writeProtected(metadata, to: stagedMetadata, fileManager: fileManager)
            let prepared = try loadVerifiedResource(
                for: kind, fileManager: fileManager, directory: stagingDirectory
            )
            guard prepared.record == record else {
                throw RoutingResourceError.metadataMismatch(kind)
            }
            committed = try commitPreparedResource(
                record, stagedData: stagedData, stagedMetadata: stagedMetadata,
                stagingDirectory: stagingDirectory, fileManager: fileManager,
                replacing: expectedRecord, preservingUsableResource: preservingUsableResource
            )
        } catch {
            // A failed rollback must keep its remaining original files for
            // recovery. Other failures leave the live pair untouched/restored.
            if error as? RoutingResourceError == .rollbackFailed { throw error }
            try removeStagingDirectory(stagingDirectory, fileManager: fileManager)
            throw error
        }
        try removeStagingDirectory(stagingDirectory, fileManager: fileManager)
        return committed
    }

    /// Records that the upstream checksum still matches the installed bytes,
    /// without rewriting the database. Only the metadata file changes, and
    /// only while the resource is still exactly `expectedRecord`.
    @discardableResult
    public func recordUpstreamCheck(
        for expectedRecord: RoutingResourceRecord,
        checkedAt: Date = .now,
        fileManager: FileManager = .default
    ) throws -> RoutingResourceRecord {
        let kind = expectedRecord.kind
        let lock = try acquireCommitLock()
        defer {
            flock(lock, LOCK_UN)
            Darwin.close(lock)
        }
        try Task.checkCancellation()
        let current = try loadVerifiedRecord(for: kind, fileManager: fileManager)
        guard current == expectedRecord else {
            throw RoutingResourceError.superseded(kind)
        }
        let normalizedCheckDate = Date(
            timeIntervalSince1970: checkedAt.timeIntervalSince1970.rounded(.down)
        )
        let record = RoutingResourceRecord(
            kind: kind,
            sha256: current.sha256,
            byteCount: current.byteCount,
            installedAt: current.installedAt,
            origin: current.origin,
            lastCheckedAt: max(normalizedCheckDate, current.lastCheckedAt ?? normalizedCheckDate)
        )
        // An atomic write replaces the metadata by rename; readers hold the
        // shared lock, so they see either the previous or the new record.
        try writeProtected(
            try Self.encodedMetadata(record),
            to: metadataURL(for: kind),
            fileManager: fileManager
        )
        let committed = try loadVerifiedRecord(for: kind, fileManager: fileManager)
        guard committed == record else {
            throw RoutingResourceError.metadataMismatch(kind)
        }
        return committed
    }

    private static func encodedMetadata(_ record: RoutingResourceRecord) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let metadata: Data
        do {
            metadata = try encoder.encode(record)
        } catch {
            throw RoutingResourceError.metadataEncodingFailed(record.kind)
        }
        guard metadata.count <= maximumMetadataBytes else {
            throw RoutingResourceError.metadataEncodingFailed(record.kind)
        }
        return metadata
    }

    private func commitPreparedResource(
        _ record: RoutingResourceRecord,
        stagedData: URL,
        stagedMetadata: URL,
        stagingDirectory: URL,
        fileManager: FileManager,
        replacing expectedRecord: RoutingResourceRecord?,
        preservingUsableResource: Bool
    ) throws -> RoutingResourceRecord {
        // Every reader/writer uses this lock. CAS runs after staging so a user
        // import that completed during preparation always wins over old work.
        let lock = try acquireCommitLock()
        defer {
            flock(lock, LOCK_UN)
            Darwin.close(lock)
        }
        try Task.checkCancellation()
        let kind = record.kind
        let previous = try? loadVerifiedRecord(for: kind, fileManager: fileManager)
        if let expectedRecord {
            guard expectedRecord.kind == kind, previous == expectedRecord else {
                throw RoutingResourceError.superseded(kind)
            }
        }
        if preservingUsableResource, let previous,
           let status = try? Self.status(for: previous, now: .now),
           status.isUsableForConnection {
            throw RoutingResourceError.superseded(kind)
        }

        let destinations = [resourceURL(for: kind), metadataURL(for: kind)]
        let sources = [stagedData, stagedMetadata]
        let backups = ["previous-data", "previous-metadata"].map {
            stagingDirectory.appendingPathComponent($0)
        }
        var hadOriginal = [Bool]()
        for (destination, backup) in zip(destinations, backups) {
            let exists = try pathExists(destination)
            hadOriginal.append(exists)
            if exists {
                try rejectSymlinkOrNonRegularFile(destination)
                do {
                    // Hard links retain the exact old bytes without allocating
                    // another database. All links exist before any live unlink.
                    try fileManager.linkItem(at: destination, to: backup)
                } catch {
                    throw RoutingResourceError.writeFailed
                }
            }
        }

        do {
            for index in destinations.indices {
                if hadOriginal[index] {
                    try fileManager.removeItem(at: destinations[index])
                }
                // Both paths are on the same filesystem. The live path can be
                // briefly absent here, but readers hold the shared store lock.
                try fileManager.moveItem(at: sources[index], to: destinations[index])
            }
            let committed = try loadVerifiedRecord(for: kind, fileManager: fileManager)
            guard committed == record else {
                throw RoutingResourceError.metadataMismatch(kind)
            }
            return committed
        } catch {
            var restored = true
            for index in destinations.indices {
                if hadOriginal[index] {
                    // rename replaces a partially installed new file without
                    // requiring free space to copy the original database back.
                    if Darwin.rename(backups[index].path, destinations[index].path) != 0 {
                        restored = false
                    }
                } else if Darwin.unlink(destinations[index].path) != 0, errno != ENOENT {
                    restored = false
                }
            }
            if let previous,
               (try? loadVerifiedRecord(for: kind, fileManager: fileManager)) != previous {
                restored = false
            }
            guard restored else { throw RoutingResourceError.rollbackFailed }
            throw (error as? RoutingResourceError) ?? RoutingResourceError.writeFailed
        }
    }

    private func removeStagingDirectory(_ directory: URL, fileManager: FileManager) throws {
        do {
            try fileManager.removeItem(at: directory)
        } catch {
            // A completed commit or rollback remains valid. Surface cleanup
            // failure rather than silently accumulating backup databases.
            throw RoutingResourceError.temporaryCleanupFailed
        }
    }

    private func withResourceReadLock<T>(
        for kinds: Set<RoutingResourceKind>,
        fileManager: FileManager,
        _ body: () throws -> T
    ) throws -> T {
        guard let first = RoutingResourceKind.allCases.first(where: kinds.contains) else {
            return try body()
        }
        for directory in [applicationSupportDirectory, resourceDirectory] {
            guard try pathExists(directory) else { throw RoutingResourceError.missing(first) }
            try rejectSymlinkOrNonDirectory(directory)
        }
        let lockURL = resourceDirectory.appendingPathComponent(".commit.lock")
        if try !pathExists(lockURL) {
            // Missing reads must not create a directory or a lock file. Only
            // a complete legacy store needs its first coordination lock.
            for kind in RoutingResourceKind.allCases where kinds.contains(kind) {
                guard fileManager.fileExists(atPath: resourceURL(for: kind).path),
                      fileManager.fileExists(atPath: metadataURL(for: kind).path) else {
                    throw RoutingResourceError.missing(kind)
                }
            }
        }
        let lock = try acquireCommitLock(shared: true)
        defer {
            flock(lock, LOCK_UN)
            Darwin.close(lock)
        }
        return try body()
    }

    private static func status(for record: RoutingResourceRecord, now: Date) throws -> RoutingResourceStatus {
        let age = now.timeIntervalSince(record.installedAt)
        guard age >= -clockSkewTolerance else {
            throw RoutingResourceError.metadataDateInFuture(record.kind)
        }
        if let lastCheckedAt = record.lastCheckedAt,
           now.timeIntervalSince(lastCheckedAt) < -clockSkewTolerance {
            throw RoutingResourceError.metadataDateInFuture(record.kind)
        }
        let freshness = now.timeIntervalSince(record.verifiedCurrentAt)
        return freshness > maximumResourceAge ? .stale(record) : .ready(record)
    }

    private func acquireCommitLock(shared: Bool = false) throws -> Int32 {
        let url = resourceDirectory.appendingPathComponent(".commit.lock")
        let commonFlags = O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor = Darwin.open(
            url.path,
            commonFlags | (shared ? O_RDONLY : O_CREAT | O_RDWR),
            0o600
        )
        if shared, descriptor < 0, errno == ENOENT {
            // Existing versions predate the lock file. O_CREAT without
            // truncation also safely joins a writer creating it concurrently.
            descriptor = Darwin.open(url.path, commonFlags | O_CREAT | O_RDWR, 0o600)
        }
        guard descriptor >= 0 else { throw RoutingResourceError.unsafeResourceFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1,
              shared || fchmod(descriptor, 0o600) == 0 else {
            Darwin.close(descriptor)
            throw RoutingResourceError.unsafeResourceFile
        }
        while flock(descriptor, shared ? LOCK_SH : LOCK_EX) != 0 {
            if errno == EINTR { continue }
            Darwin.close(descriptor)
            throw RoutingResourceError.writeFailed
        }
        return descriptor
    }

    private func loadVerifiedRecord(
        for kind: RoutingResourceKind,
        fileManager: FileManager
    ) throws -> RoutingResourceRecord {
        try loadVerifiedResource(for: kind, fileManager: fileManager).record
    }

    // The caller owns the store lock, or supplies its own private staging
    // directory that has not been published to any other reader/writer.
    private func loadVerifiedResource(
        for kind: RoutingResourceKind,
        fileManager: FileManager,
        directory: URL? = nil
    ) throws -> (record: RoutingResourceRecord, data: Data) {
        let assetURL = directory?.appendingPathComponent(kind.fileName) ?? resourceURL(for: kind)
        let metadataURL = directory?.appendingPathComponent(metadataURL(for: kind).lastPathComponent)
            ?? metadataURL(for: kind)
        guard fileManager.fileExists(atPath: assetURL.path),
              fileManager.fileExists(atPath: metadataURL.path) else {
            throw RoutingResourceError.missing(kind)
        }
        try rejectSymlinkOrNonRegularFile(assetURL)
        try rejectSymlinkOrNonRegularFile(metadataURL)

        let metadata = try Data(
            contentsOf: metadataURL,
            options: [.mappedIfSafe]
        )
        guard metadata.count <= Self.maximumMetadataBytes else {
            throw RoutingResourceError.metadataTooLarge(kind)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let record: RoutingResourceRecord
        do {
            record = try decoder.decode(
                RoutingResourceRecord.self,
                from: metadata
            )
        } catch {
            throw RoutingResourceError.metadataUnreadable(kind)
        }
        guard record.formatVersion == RoutingResourceRecord.currentFormatVersion,
              record.kind == kind,
              Self.isLowercaseSHA256(record.sha256) else {
            throw RoutingResourceError.metadataMismatch(kind)
        }

        let data = try Data(contentsOf: assetURL, options: [.mappedIfSafe])
        let digest = try Self.validate(data: data, kind: kind)
        guard record.byteCount == data.count, record.sha256 == digest else {
            throw RoutingResourceError.metadataMismatch(kind)
        }
        return (record, data)
    }

    private func resourceURL(for kind: RoutingResourceKind) -> URL {
        resourceDirectory.appendingPathComponent(
            kind.fileName,
            isDirectory: false
        )
    }

    private func metadataURL(for kind: RoutingResourceKind) -> URL {
        resourceDirectory.appendingPathComponent(
            "\(kind.fileName).metadata.json",
            isDirectory: false
        )
    }

    private var mirrorConfigurationURL: URL {
        resourceDirectory.appendingPathComponent(
            "mirror-urls.v1.json",
            isDirectory: false
        )
    }

    private struct MirrorEntry: Codable {
        let resourceURL: String
        let checksumURL: String
    }

    public func customMirrorDescriptor(
        for kind: RoutingResourceKind,
        fileManager: FileManager = .default
    ) -> RoutingResourceRemoteDescriptor? {
        let entries = loadMirrorEntries(fileManager: fileManager)
        guard let entry = entries[kind.rawValue],
              let resourceURL = URL(string: entry.resourceURL),
              let checksumURL = URL(string: entry.checksumURL) else {
            return nil
        }
        return try? RoutingResourceRemoteDescriptor(
            kind: kind,
            resourceURL: resourceURL,
            checksumURL: checksumURL
        )
    }

    public func setCustomMirrorURLs(
        for kind: RoutingResourceKind,
        resourceURL: URL,
        checksumURL: URL? = nil,
        fileManager: FileManager = .default
    ) throws {
        let resolvedChecksumURL: URL
        if let checksumURL {
            resolvedChecksumURL = checksumURL
        } else if let derived = URL(string: resourceURL.absoluteString + ".sha256sum") {
            resolvedChecksumURL = derived
        } else {
            throw RoutingResourceError.invalidRemoteURL
        }
        _ = try RoutingResourceRemoteDescriptor(
            kind: kind,
            resourceURL: resourceURL,
            checksumURL: resolvedChecksumURL
        )
        try preparePrivateDirectory(applicationSupportDirectory, fileManager: fileManager)
        try preparePrivateDirectory(resourceDirectory, fileManager: fileManager)
        var entries = loadMirrorEntries(fileManager: fileManager)
        entries[kind.rawValue] = MirrorEntry(
            resourceURL: resourceURL.absoluteString,
            checksumURL: resolvedChecksumURL.absoluteString
        )
        try saveMirrorEntries(entries, fileManager: fileManager)
    }

    public func clearCustomMirrorURLs(
        for kind: RoutingResourceKind,
        fileManager: FileManager = .default
    ) throws {
        var entries = loadMirrorEntries(fileManager: fileManager)
        guard entries.removeValue(forKey: kind.rawValue) != nil else { return }
        if entries.isEmpty {
            if fileManager.fileExists(atPath: mirrorConfigurationURL.path) {
                try fileManager.removeItem(at: mirrorConfigurationURL)
            }
            return
        }
        try preparePrivateDirectory(applicationSupportDirectory, fileManager: fileManager)
        try preparePrivateDirectory(resourceDirectory, fileManager: fileManager)
        try saveMirrorEntries(entries, fileManager: fileManager)
    }

    private func loadMirrorEntries(fileManager: FileManager) -> [String: MirrorEntry] {
        guard fileManager.fileExists(atPath: mirrorConfigurationURL.path),
              let data = try? Data(contentsOf: mirrorConfigurationURL),
              let decoded = try? JSONDecoder().decode([String: MirrorEntry].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveMirrorEntries(
        _ entries: [String: MirrorEntry],
        fileManager: FileManager
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(entries)
        try data.write(to: mirrorConfigurationURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: mirrorConfigurationURL.path
        )
    }

    private func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager,
        excludeFromBackup shouldExcludeFromBackup: Bool = true
    ) throws {
        guard url.isFileURL, url.path.hasPrefix("/"), url.path != "/" else {
            throw RoutingResourceError.invalidApplicationSupportDirectory
        }
        if try pathExists(url) {
            try rejectSymlinkOrNonDirectory(url)
        } else {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true,
                attributes: [
                    .posixPermissions: 0o700,
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ]
            )
            try rejectSymlinkOrNonDirectory(url)
        }
        try fileManager.setAttributes(
            [
                .posixPermissions: 0o700,
                .protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication,
            ],
            ofItemAtPath: url.path
        )
        if shouldExcludeFromBackup {
            try excludeFromBackup(url)
        }
    }

    private func verifyRuntimeHierarchy(
        runtimeRoot: URL,
        flowRuntime: URL
    ) throws {
        let base = applicationSupportDirectory
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let root = runtimeRoot.resolvingSymlinksInPath().standardizedFileURL
        let flow = flowRuntime.resolvingSymlinksInPath().standardizedFileURL
        let basePrefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard root.path.hasPrefix(basePrefix),
              flow.path.hasPrefix(root.path + "/") else {
            throw RoutingResourceError.unsafeRuntimeDirectory
        }
    }

    private func writeProtected(
        _ data: Data,
        to url: URL,
        fileManager: FileManager
    ) throws {
        let exists = try pathExists(url)
        if exists {
            try rejectSymlinkOrNonRegularFile(url)
        }
        do {
            let matchesExisting = exists
                && (try? Data(contentsOf: url, options: [.mappedIfSafe])) == data
            if !matchesExisting {
                try data.write(to: url, options: [.atomic])
            }
            try fileManager.setAttributes(
                [
                    .posixPermissions: 0o600,
                    .protectionKey:
                        FileProtectionType.completeUntilFirstUserAuthentication,
                ],
                ofItemAtPath: url.path
            )
            try excludeFromBackup(url)
        } catch let error as RoutingResourceError {
            throw error
        } catch {
            throw RoutingResourceError.writeFailed
        }
    }

    private func rejectSymlinkOrNonDirectory(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFDIR else {
            throw RoutingResourceError.unsafeRuntimeDirectory
        }
    }

    private func rejectSymlinkOrNonRegularFile(_ url: URL) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw RoutingResourceError.unsafeResourceFile
        }
    }

    private func pathExists(_ url: URL) throws -> Bool {
        var info = stat()
        if lstat(url.path, &info) == 0 { return true }
        guard errno == ENOENT else {
            throw RoutingResourceError.unsafeResourceFile
        }
        return false
    }

    private static let backupExcludeXattrName =
        "com.apple.metadata:com_apple_backup_excludeItem"

    private func excludeFromBackup(_ url: URL) throws {
        if getxattr(
            url.path,
            Self.backupExcludeXattrName,
            nil,
            0,
            0,
            XATTR_NOFOLLOW
        ) > 0 {
            return
        }
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }

    private static func validate(
        data: Data,
        kind: RoutingResourceKind
    ) throws -> String {
        let minimumBytes = (kind == .countryMMDB || kind == .asnMMDB) ? 1_024 : 16
        guard data.count >= minimumBytes else {
            throw RoutingResourceError.resourceTooSmall(kind, data.count)
        }
        guard data.count <= kind.maximumBytes else {
            throw RoutingResourceError.resourceTooLarge(kind, data.count)
        }
        switch kind {
        case .countryMMDB, .asnMMDB:
            let marker = Data([0xAB, 0xCD, 0xEF])
                + Data("MaxMind.com".utf8)
            let tail = data.suffix(min(data.count, 128 * 1_024))
            guard tail.range(of: marker) != nil else {
                throw RoutingResourceError.invalidResourceFormat(kind)
            }
        case .geoSite:
            // GeoSite is a protobuf stream of GeoSite entries; every supported
            // upstream begins with field 1 as a length-delimited message.
            guard data.first == 0x0A,
                  data.contains(where: { $0 != 0 }) else {
                throw RoutingResourceError.invalidResourceFormat(kind)
            }
        }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.range(
            of: "^[0-9a-f]{64}$",
            options: .regularExpression
        ) != nil
    }
}

public struct RoutingResourceRemoteDescriptor: Equatable, Sendable {
    public let kind: RoutingResourceKind
    public let resourceURL: URL
    public let checksumURL: URL

    public init(
        kind: RoutingResourceKind,
        resourceURL: URL,
        checksumURL: URL
    ) throws {
        try RoutingResourceDownloadClient.validateRemoteURL(resourceURL)
        try RoutingResourceDownloadClient.validateRemoteURL(checksumURL)
        self.kind = kind
        self.resourceURL = resourceURL
        self.checksumURL = checksumURL
    }

    public static func maintainedDefault(
        for kind: RoutingResourceKind
    ) throws -> Self {
        switch kind {
        case .countryMMDB:
            return try Self(
                kind: kind,
                resourceURL: URL(
                    string: "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country-without-asn.mmdb"
                )!,
                checksumURL: URL(
                    string: "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/Country-without-asn.mmdb.sha256sum"
                )!
            )
        case .geoSite:
            return try Self(
                kind: kind,
                resourceURL: URL(
                    string: "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
                )!,
                checksumURL: URL(
                    string: "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat.sha256sum"
                )!
            )
        case .asnMMDB:
            return try Self(
                kind: kind,
                resourceURL: URL(
                    string: "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/GeoLite2-ASN.mmdb"
                )!,
                checksumURL: URL(
                    string: "https://raw.githubusercontent.com/Loyalsoldier/geoip/release/GeoLite2-ASN.mmdb.sha256sum"
                )!
            )
        }
    }

    public static func resolved(
        for kind: RoutingResourceKind,
        in store: RoutingResourceStore,
        fileManager: FileManager = .default
    ) throws -> Self {
        if let custom = store.customMirrorDescriptor(for: kind, fileManager: fileManager) {
            return custom
        }
        return try maintainedDefault(for: kind)
    }
}

public enum RoutingResourceRefreshOutcome: Equatable, Sendable {
    case updated(RoutingResourceRecord)
    case alreadyCurrent(RoutingResourceRecord)

    public var record: RoutingResourceRecord {
        switch self {
        case let .updated(record), let .alreadyCurrent(record): record
        }
    }
}

public struct RoutingResourceHTTPResponse: Equatable, Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL
    public let contentLength: Int?

    public init(
        data: Data,
        statusCode: Int,
        finalURL: URL,
        contentLength: Int? = nil
    ) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.contentLength = contentLength
    }
}

public struct RoutingResourceDownloadClient: Sendable {
    public typealias Transport = @Sendable (
        URL,
        Int
    ) async throws -> RoutingResourceHTTPResponse

    private let transport: Transport
    private let now: @Sendable () -> Date

    public init(
        transport: @escaping Transport,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.transport = transport
        self.now = now
    }

    public static func live() -> Self {
        Self { url, maximumBytes in
            try validateRemoteURL(url)
            let delegate = HTTPSOnlyRedirectDelegate()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 120
            configuration.waitsForConnectivity = false
            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 30
            request.setValue(
                "AetherRoute/1.0 (macOS; Apple Silicon)",
                forHTTPHeaderField: "User-Agent"
            )
            request.setValue(
                "application/octet-stream, text/plain;q=0.9",
                forHTTPHeaderField: "Accept"
            )
            let (bytes, response) = try await session.bytes(for: request)
            if delegate.redirectError != nil {
                throw RoutingResourceError.insecureRedirect
            }
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url else {
                throw RoutingResourceError.invalidHTTPResponse
            }
            try validateRemoteURL(finalURL)
            let contentLength = response.expectedContentLength >= 0
                ? Int(response.expectedContentLength)
                : nil
            if let contentLength, contentLength > maximumBytes {
                throw RoutingResourceError.responseTooLarge(contentLength)
            }
            var data = Data()
            data.reserveCapacity(min(contentLength ?? 0, maximumBytes))
            for try await byte in bytes {
                guard data.count < maximumBytes else {
                    throw RoutingResourceError.responseTooLarge(data.count + 1)
                }
                data.append(byte)
            }
            guard data.count <= maximumBytes else {
                throw RoutingResourceError.responseTooLarge(data.count)
            }
            return RoutingResourceHTTPResponse(
                data: data,
                statusCode: response.statusCode,
                finalURL: finalURL,
                contentLength: contentLength
            )
        }
    }

    @discardableResult
    public func downloadAndInstall(
        _ descriptor: RoutingResourceRemoteDescriptor,
        into store: RoutingResourceStore,
        fileManager: FileManager = .default,
        replacing expectedRecord: RoutingResourceRecord? = nil
    ) async throws -> RoutingResourceRecord {
        let effective = resolveEffectiveDescriptor(
            descriptor, in: store, fileManager: fileManager
        )
        let expectedSHA256 = try await upstreamChecksum(for: effective)
        return try await install(
            effective, expectedSHA256: expectedSHA256, into: store,
            fileManager: fileManager, replacing: expectedRecord
        )
    }

    /// Fetches the small upstream checksum first and downloads the database
    /// only when it differs from `current`. An unchanged resource just records
    /// the check, which also renews how long it stays usable.
    public func refresh(
        _ descriptor: RoutingResourceRemoteDescriptor,
        into store: RoutingResourceStore,
        current: RoutingResourceRecord?,
        fileManager: FileManager = .default
    ) async throws -> RoutingResourceRefreshOutcome {
        let effective = resolveEffectiveDescriptor(
            descriptor, in: store, fileManager: fileManager
        )
        let expectedSHA256 = try await upstreamChecksum(for: effective)
        if let current, current.kind == effective.kind,
           current.sha256 == expectedSHA256 {
            try Task.checkCancellation()
            return .alreadyCurrent(try store.recordUpstreamCheck(
                for: current, checkedAt: now(), fileManager: fileManager
            ))
        }
        return .updated(try await install(
            effective, expectedSHA256: expectedSHA256, into: store,
            fileManager: fileManager, replacing: current
        ))
    }

    private func resolveEffectiveDescriptor(
        _ descriptor: RoutingResourceRemoteDescriptor,
        in store: RoutingResourceStore,
        fileManager: FileManager
    ) -> RoutingResourceRemoteDescriptor {
        guard let maintained = try? RoutingResourceRemoteDescriptor
            .maintainedDefault(for: descriptor.kind),
            descriptor == maintained,
            let custom = store.customMirrorDescriptor(
                for: descriptor.kind,
                fileManager: fileManager
            ) else {
            return descriptor
        }
        return custom
    }

    private func upstreamChecksum(
        for descriptor: RoutingResourceRemoteDescriptor
    ) async throws -> String {
        try Task.checkCancellation()
        let checksumResponse = try await transport(
            descriptor.checksumURL,
            4 * 1_024
        )
        try Self.validate(response: checksumResponse, maximumBytes: 4 * 1_024)
        return try Self.parseChecksum(checksumResponse.data)
    }

    private func install(
        _ descriptor: RoutingResourceRemoteDescriptor,
        expectedSHA256: String,
        into store: RoutingResourceStore,
        fileManager: FileManager,
        replacing expectedRecord: RoutingResourceRecord?
    ) async throws -> RoutingResourceRecord {
        try Task.checkCancellation()
        let resourceResponse = try await transport(
            descriptor.resourceURL,
            descriptor.kind.maximumBytes
        )
        try Self.validate(
            response: resourceResponse,
            maximumBytes: descriptor.kind.maximumBytes
        )
        try Task.checkCancellation()
        return try store.installVerified(
            data: resourceResponse.data,
            kind: descriptor.kind,
            expectedSHA256: expectedSHA256,
            installedAt: now(),
            fileManager: fileManager,
            replacing: expectedRecord
        )
    }

    /// Makes every public routing database referenced by one profile ready for
    /// launch. Usable checksum-verified resources stay available; refreshes of
    /// older public resources happen separately from connection startup.
    @discardableResult
    public func ensureRequiredResources(
        for profileYAML: String,
        in store: RoutingResourceStore,
        statusDate: Date = .now,
        fileManager: FileManager = .default
    ) async throws -> Set<RoutingResourceKind> {
        let required = ProfileConfigurationInspector
            .inspect(yaml: profileYAML)
            .requiredRoutingResources
        var installed = Set<RoutingResourceKind>()

        for kind in RoutingResourceKind.allCases where required.contains(kind) {
            if store.status(
                for: kind,
                now: statusDate,
                fileManager: fileManager
            ).isUsableForConnection {
                continue
            }
            try Task.checkCancellation()
            let descriptor = try RoutingResourceRemoteDescriptor
                .resolved(for: kind, in: store, fileManager: fileManager)
            try await downloadAndInstall(
                descriptor,
                into: store,
                fileManager: fileManager
            )
            installed.insert(kind)
        }
        return installed
    }

    public static func validateRemoteURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw RoutingResourceError.invalidRemoteURL
        }
    }

    private static func validate(
        response: RoutingResourceHTTPResponse,
        maximumBytes: Int
    ) throws {
        try validateRemoteURL(response.finalURL)
        guard response.statusCode == 200 else {
            throw RoutingResourceError.httpStatus(response.statusCode)
        }
        if let contentLength = response.contentLength,
           contentLength > maximumBytes {
            throw RoutingResourceError.responseTooLarge(contentLength)
        }
        guard response.data.count <= maximumBytes else {
            throw RoutingResourceError.responseTooLarge(response.data.count)
        }
    }

    private static func parseChecksum(_ data: Data) throws -> String {
        guard let text = String(data: data, encoding: .utf8),
              let token = text
                .split(whereSeparator: { $0.isWhitespace })
                .first?
                .lowercased(),
              token.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw RoutingResourceError.invalidChecksumResponse
        }
        return token
    }
}

public enum RoutingResourceError: LocalizedError, Equatable, Sendable {
    case invalidApplicationSupportDirectory
    case unsafeRuntimeDirectory
    case unsafeResourceFile
    case invalidExpectedSHA256
    case checksumMismatch(RoutingResourceKind)
    case superseded(RoutingResourceKind)
    case resourceTooSmall(RoutingResourceKind, Int)
    case resourceTooLarge(RoutingResourceKind, Int)
    case invalidResourceFormat(RoutingResourceKind)
    case missing(RoutingResourceKind)
    case stale(RoutingResourceKind, installedAt: Date)
    case metadataDateInFuture(RoutingResourceKind)
    case metadataEncodingFailed(RoutingResourceKind)
    case metadataUnreadable(RoutingResourceKind)
    case metadataTooLarge(RoutingResourceKind)
    case metadataMismatch(RoutingResourceKind)
    case writeFailed
    case rollbackFailed
    case temporaryCleanupFailed
    case invalidRemoteURL
    case insecureRedirect
    case invalidHTTPResponse
    case httpStatus(Int)
    case responseTooLarge(Int)
    case invalidChecksumResponse

    public var errorDescription: String? {
        switch self {
        case .invalidApplicationSupportDirectory:
            "The shared routing-resource directory is invalid."
        case .unsafeRuntimeDirectory, .unsafeResourceFile:
            "A routing-resource path is unsafe."
        case .invalidExpectedSHA256, .invalidChecksumResponse:
            "The routing-resource checksum is invalid."
        case let .checksumMismatch(kind):
            "The downloaded \(kind.fileName) file failed its checksum."
        case let .superseded(kind):
            "The saved \(kind.fileName) changed while the update was running. The newer resource was kept."
        case let .resourceTooSmall(kind, _),
             let .resourceTooLarge(kind, _),
             let .invalidResourceFormat(kind):
            "The \(kind.fileName) file is not a valid routing database."
        case let .missing(kind):
            "Download or import \(kind.fileName) before connecting."
        case let .stale(kind, _):
            "The \(kind.fileName) routing database is older than 30 days and must be updated."
        case let .metadataDateInFuture(kind),
             let .metadataEncodingFailed(kind),
             let .metadataUnreadable(kind),
             let .metadataTooLarge(kind),
             let .metadataMismatch(kind):
            "The saved metadata for \(kind.fileName) is invalid."
        case .writeFailed:
            "The routing database could not be saved securely."
        case .rollbackFailed:
            "The routing database update could not be rolled back. The remaining original files were kept for recovery."
        case .temporaryCleanupFailed:
            "Temporary routing-database update files could not be removed. Free disk space and try again."
        case .invalidRemoteURL, .insecureRedirect:
            "Routing databases must be downloaded through a valid HTTPS address."
        case .invalidHTTPResponse:
            "The routing-resource server returned an invalid response."
        case let .httpStatus(status):
            "The routing-resource server returned HTTP \(status)."
        case let .responseTooLarge(bytes):
            "The routing-resource response is too large (\(bytes) bytes)."
        }
    }
}

/// Bounded, disk-backed chunk assembler for staging routing databases into a
/// running root-context Network System Extension without holding the full
/// database buffer in memory across IPC messages.
public final class RoutingResourceChunkStagingReceiver: @unchecked Sendable {
    private struct ActiveTransfer {
        let transferID: UUID
        let kind: RoutingResourceKind
        let expectedSHA256: String
        let totalBytes: Int
        let totalChunks: UInt32
        var nextChunkIndex: UInt32
        var receivedBytes: Int
        let partFileURL: URL
    }

    private let lock = NSLock()
    private let storeProvider: @Sendable () throws -> RoutingResourceStore
    private var activeTransfers: [RoutingResourceKind: ActiveTransfer] = [:]

    public init(store: RoutingResourceStore) {
        self.storeProvider = { store }
    }

    public init(storeProvider: @escaping @Sendable () throws -> RoutingResourceStore) {
        self.storeProvider = storeProvider
    }

    public func installedDigests(
        now: Date = .now,
        fileManager: FileManager = .default
    ) -> [RoutingResourceKind: String] {
        guard let store = try? storeProvider() else { return [:] }
        return store.usableResourceDigests(now: now, fileManager: fileManager)
    }

    public func receive(
        _ chunk: RoutingResourceTransferChunk,
        fileManager: FileManager = .default
    ) throws {
        let normalizedSHA = chunk.expectedSHA256.lowercased()
        guard normalizedSHA.utf8.count == 64,
              normalizedSHA.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              chunk.totalChunks > 0,
              chunk.chunkIndex < chunk.totalChunks,
              !chunk.data.isEmpty,
              chunk.data.count <= RoutingResourceTransferChunk.maximumChunkDataBytes,
              chunk.totalBytes > 0,
              chunk.totalBytes <= chunk.kind.maximumBytes else {
            throw ProxySelectionProviderMessageError.malformed
        }

        lock.lock()
        defer { lock.unlock() }

        let store = try storeProvider()
        let stagingDir = store.applicationSupportDirectory.appendingPathComponent(
            "RoutingResourcesStaging",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: stagingDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let partURL = stagingDir.appendingPathComponent("\(chunk.kind.rawValue).part", isDirectory: false)

        if chunk.chunkIndex == 0 {
            try? fileManager.removeItem(at: partURL)
            guard chunk.data.count <= chunk.totalBytes else {
                throw ProxySelectionProviderMessageError.malformed
            }
            try chunk.data.write(to: partURL, options: [.atomic])
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: partURL.path)
            activeTransfers[chunk.kind] = ActiveTransfer(
                transferID: chunk.transferID,
                kind: chunk.kind,
                expectedSHA256: normalizedSHA,
                totalBytes: chunk.totalBytes,
                totalChunks: chunk.totalChunks,
                nextChunkIndex: 1,
                receivedBytes: chunk.data.count,
                partFileURL: partURL
            )
        } else {
            guard var state = activeTransfers[chunk.kind],
                  state.transferID == chunk.transferID,
                  state.expectedSHA256 == normalizedSHA,
                  state.totalBytes == chunk.totalBytes,
                  state.totalChunks == chunk.totalChunks,
                  state.nextChunkIndex == chunk.chunkIndex,
                  state.receivedBytes + chunk.data.count <= state.totalBytes else {
                activeTransfers.removeValue(forKey: chunk.kind)
                try? fileManager.removeItem(at: partURL)
                throw ProxySelectionProviderMessageError.malformed
            }
            let handle = try FileHandle(forWritingTo: state.partFileURL)
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: chunk.data)
                try handle.close()
            } catch {
                try? handle.close()
                activeTransfers.removeValue(forKey: chunk.kind)
                try? fileManager.removeItem(at: partURL)
                throw error
            }
            state.nextChunkIndex += 1
            state.receivedBytes += chunk.data.count
            activeTransfers[chunk.kind] = state
        }

        if let completed = activeTransfers[chunk.kind],
           completed.nextChunkIndex == completed.totalChunks {
            defer {
                activeTransfers.removeValue(forKey: chunk.kind)
                try? fileManager.removeItem(at: completed.partFileURL)
            }
            guard completed.receivedBytes == completed.totalBytes else {
                throw ProxySelectionProviderMessageError.malformed
            }
            let assembled = try Data(contentsOf: completed.partFileURL, options: [.mappedIfSafe])
            guard assembled.count == completed.totalBytes else {
                throw ProxySelectionProviderMessageError.malformed
            }
            let actualSHA = SHA256.hash(data: assembled).map { String(format: "%02x", $0) }.joined()
            guard actualSHA == completed.expectedSHA256 else {
                throw RoutingResourceError.checksumMismatch(chunk.kind)
            }
            _ = try store.installUserProvided(
                data: assembled,
                kind: chunk.kind,
                fileManager: fileManager
            )
        }
    }
}

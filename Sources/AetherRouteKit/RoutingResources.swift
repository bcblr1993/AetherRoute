import CryptoKit
import Darwin
@preconcurrency import Foundation

public enum RoutingResourceKind: String, CaseIterable, Codable, Hashable,
    Sendable
{
    case countryMMDB
    case geoSite

    public var fileName: String {
        switch self {
        case .countryMMDB: "Country.mmdb"
        case .geoSite: "GeoSite.dat"
        }
    }

    public var maximumBytes: Int {
        switch self {
        case .countryMMDB: 64 * 1_024 * 1_024
        case .geoSite: 64 * 1_024 * 1_024
        }
    }
}

public extension ProfileConfigurationSummary {
    var requiredRoutingResources: Set<RoutingResourceKind> {
        var resources = Set<RoutingResourceKind>()
        if requiresCountryMMDB { resources.insert(.countryMMDB) }
        if requiresGeoSiteDatabase { resources.insert(.geoSite) }
        return resources
    }
}

public enum RoutingResourceOrigin: String, Codable, Equatable, Sendable {
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

    public init(
        kind: RoutingResourceKind,
        sha256: String,
        byteCount: Int,
        installedAt: Date,
        origin: RoutingResourceOrigin
    ) {
        formatVersion = Self.currentFormatVersion
        self.kind = kind
        self.sha256 = sha256
        self.byteCount = byteCount
        self.installedAt = installedAt
        self.origin = origin
    }
}

public enum RoutingResourceStatus: Equatable, Sendable {
    case missing
    case ready(RoutingResourceRecord)
    case stale(RoutingResourceRecord)
    case invalid(RoutingResourceError)
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
        fileManager: FileManager = .default
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
            fileManager: fileManager
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
            let record = try loadVerifiedRecord(
                for: kind,
                fileManager: fileManager
            )
            let age = now.timeIntervalSince(record.installedAt)
            guard age >= -Self.clockSkewTolerance else {
                return .invalid(.metadataDateInFuture(kind))
            }
            if age > Self.maximumResourceAge {
                return .stale(record)
            }
            return .ready(record)
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
        let requirements = ProfileConfigurationInspector
            .inspect(yaml: profileYAML)
            .requiredRoutingResources
        guard !requirements.isEmpty else { return [] }

        var verifiedData = [RoutingResourceKind: Data]()
        for kind in requirements {
            switch status(for: kind, now: now, fileManager: fileManager) {
            case .missing:
                throw RoutingResourceError.missing(kind)
            case let .stale(record):
                throw RoutingResourceError.stale(
                    kind,
                    installedAt: record.installedAt
                )
            case let .invalid(error):
                throw error
            case .ready:
                let data = try Data(
                    contentsOf: resourceURL(for: kind),
                    options: [.mappedIfSafe]
                )
                _ = try Self.validate(data: data, kind: kind)
                verifiedData[kind] = data
            }
        }

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
        return requirements
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
        var snapshot = [RoutingResourceKind: Data]()
        for kind in requirements {
            switch status(for: kind, now: now, fileManager: fileManager) {
            case .missing:
                throw RoutingResourceError.missing(kind)
            case let .stale(record):
                throw RoutingResourceError.stale(
                    kind,
                    installedAt: record.installedAt
                )
            case let .invalid(error):
                throw error
            case .ready:
                let data = try Data(
                    contentsOf: resourceURL(for: kind),
                    options: [.mappedIfSafe]
                )
                _ = try Self.validate(data: data, kind: kind)
                snapshot[kind] = data
            }
        }
        return snapshot
    }

    private func commit(
        data: Data,
        kind: RoutingResourceKind,
        digest: String,
        installedAt: Date,
        origin: RoutingResourceOrigin,
        fileManager: FileManager
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
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let metadata: Data
        do {
            metadata = try encoder.encode(record)
        } catch {
            throw RoutingResourceError.metadataEncodingFailed(kind)
        }
        guard metadata.count <= Self.maximumMetadataBytes else {
            throw RoutingResourceError.metadataEncodingFailed(kind)
        }

        try writeProtected(
            data,
            to: resourceURL(for: kind),
            fileManager: fileManager
        )
        try writeProtected(
            metadata,
            to: metadataURL(for: kind),
            fileManager: fileManager
        )
        let committed = try loadVerifiedRecord(
            for: kind,
            fileManager: fileManager
        )
        guard committed == record else {
            throw RoutingResourceError.metadataMismatch(kind)
        }
        return record
    }

    private func loadVerifiedRecord(
        for kind: RoutingResourceKind,
        fileManager: FileManager
    ) throws -> RoutingResourceRecord {
        let assetURL = resourceURL(for: kind)
        let metadataURL = metadataURL(for: kind)
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
        return record
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

    private func preparePrivateDirectory(
        _ url: URL,
        fileManager: FileManager
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
        try excludeFromBackup(url)
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
        if try pathExists(url) {
            try rejectSymlinkOrNonRegularFile(url)
        }
        do {
            try data.write(to: url, options: [.atomic])
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

    private func excludeFromBackup(_ url: URL) throws {
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resourceURL.setResourceValues(values)
    }

    private static func validate(
        data: Data,
        kind: RoutingResourceKind
    ) throws -> String {
        let minimumBytes = kind == .countryMMDB ? 1_024 : 16
        guard data.count >= minimumBytes else {
            throw RoutingResourceError.resourceTooSmall(kind, data.count)
        }
        guard data.count <= kind.maximumBytes else {
            throw RoutingResourceError.resourceTooLarge(kind, data.count)
        }
        switch kind {
        case .countryMMDB:
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
        fileManager: FileManager = .default
    ) async throws -> RoutingResourceRecord {
        let checksumResponse = try await transport(
            descriptor.checksumURL,
            4 * 1_024
        )
        try Self.validate(response: checksumResponse, maximumBytes: 4 * 1_024)
        let expectedSHA256 = try Self.parseChecksum(checksumResponse.data)

        let resourceResponse = try await transport(
            descriptor.resourceURL,
            descriptor.kind.maximumBytes
        )
        try Self.validate(
            response: resourceResponse,
            maximumBytes: descriptor.kind.maximumBytes
        )
        return try store.installVerified(
            data: resourceResponse.data,
            kind: descriptor.kind,
            expectedSHA256: expectedSHA256,
            installedAt: now(),
            fileManager: fileManager
        )
    }

    /// Makes every public routing database referenced by one profile ready for
    /// launch. A ready, checksum-verified resource is left untouched; missing,
    /// stale, or invalid resources are replaced from the maintained HTTPS
    /// source and verified before either embedded core can see them.
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
            if case .ready = store.status(
                for: kind,
                now: statusDate,
                fileManager: fileManager
            ) {
                continue
            }
            try Task.checkCancellation()
            let descriptor = try RoutingResourceRemoteDescriptor
                .maintainedDefault(for: kind)
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

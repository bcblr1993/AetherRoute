import CryptoKit
import Darwin
import Foundation

/// Installs the public routing databases shipped with the app without making a
/// network request. The entire supplied pack is checked before any store write;
/// usable user data always takes precedence over the packaged fallback.
public struct BundledRoutingResources: Sendable {
    public static let maximumManifestBytes = 16 * 1_024

    private let directoryURL: URL?

    public init(directoryURL: URL?) {
        self.directoryURL = directoryURL
    }

    @discardableResult
    public func installMissingResources(
        for profileYAML: String,
        in store: RoutingResourceStore
    ) throws -> Set<RoutingResourceKind> {
        guard let directoryURL else { return [] }
        guard directoryURL.isFileURL,
              directoryURL.path.hasPrefix("/"),
              !directoryURL.path.utf8.contains(0) else {
            throw BundledRoutingResourceError.unsafeDirectory
        }

        // Hold the directory descriptor throughout validation. openat with
        // O_NOFOLLOW prevents a replaced file or directory symlink from escaping
        // the selected pack between path inspection and the actual read.
        var directoryPath = directoryURL.path
        while directoryPath.hasSuffix("/"), directoryPath.count > 1 {
            directoryPath.removeLast()
        }
        let directory = Darwin.open(
            directoryPath,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard directory >= 0 else {
            if errno == ENOENT { return [] }
            throw BundledRoutingResourceError.unsafeDirectory
        }
        defer { Darwin.close(directory) }

        let manifestData = try Self.readRegularFile(
            "manifest.json",
            in: directory,
            maximumBytes: Self.maximumManifestBytes
        )
        let manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manifestData)
        } catch {
            throw BundledRoutingResourceError.invalidManifest
        }
        guard manifest.schema == 1,
              !manifest.resources.isEmpty,
              manifest.resources.count <= RoutingResourceKind.allCases.count else {
            throw BundledRoutingResourceError.invalidManifest
        }
        let installedAt = try Self.installDate(packagedAt: manifest.packagedAt)

        var entries = [RoutingResourceKind: Entry]()
        for entry in manifest.resources {
            guard entries[entry.kind] == nil,
                  entry.fileName == entry.kind.fileName,
                  entry.byteCount > 0,
                  entry.byteCount <= entry.kind.maximumBytes,
                  entry.sha256.utf8.count == 64,
                  entry.sha256.utf8.allSatisfy({
                      (48...57).contains($0) || (97...102).contains($0)
                  }),
                  entry.sourceURL.utf8.count <= 4_096,
                  let source = URL(string: entry.sourceURL) else {
                throw BundledRoutingResourceError.invalidManifest
            }
            do {
                try RoutingResourceDownloadClient.validateRemoteURL(source)
            } catch {
                throw BundledRoutingResourceError.invalidManifest
            }
            entries[entry.kind] = entry
        }

        let requirements = ProfileConfigurationInspector.inspect(yaml: profileYAML)
            .requiredRoutingResources
        for kind in requirements where entries[kind] == nil {
            // A present but incomplete pack must not silently masquerade as an
            // absent optional pack and send first launch back to the network.
            throw BundledRoutingResourceError.missingResource(kind)
        }

        var verified = [RoutingResourceKind: Data]()
        for kind in RoutingResourceKind.allCases {
            guard let entry = entries[kind] else { continue }
            let data = try Self.readRegularFile(
                entry.fileName,
                in: directory,
                maximumBytes: kind.maximumBytes,
                expectedBytes: entry.byteCount
            )
            let digest = SHA256.hash(data: data)
                .map { String(format: "%02x", $0) }
                .joined()
            guard digest == entry.sha256 else {
                throw BundledRoutingResourceError.checksumMismatch(kind)
            }
            verified[kind] = data
        }

        var installed = Set<RoutingResourceKind>()
        for kind in RoutingResourceKind.allCases where requirements.contains(kind) {
            // Recheck immediately before writing: a background refresh may have
            // made a resource usable while the packaged files were verified.
            guard !store.status(for: kind).isUsableForConnection else { continue }
            guard let entry = entries[kind], let data = verified[kind] else {
                throw BundledRoutingResourceError.missingResource(kind)
            }
            do {
                try store.installBundled(
                    data: data,
                    kind: kind,
                    expectedSHA256: entry.sha256,
                    installedAt: installedAt,
                    preservingUsableResource: true
                )
            } catch RoutingResourceError.superseded(kind) {
                continue
            }
            installed.insert(kind)
        }
        return installed
    }

    private struct Manifest: Decodable {
        let schema: Int
        let resources: [Entry]
        let packagedAt: String?
    }

    private struct Entry: Decodable {
        let kind: RoutingResourceKind
        let fileName: String
        let sha256: String
        let byteCount: Int
        let sourceURL: String
    }

    private static func installDate(packagedAt: String?) throws -> Date {
        let now = Date.now
        guard let packagedAt else { return now }
        // The manifest uses canonical UTC seconds with optional milliseconds.
        // ISO8601DateFormatter alone accepts impossible dates and trailing text,
        // so require the exact syntax and round-trip every calendar component.
        guard packagedAt.range(
            of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\\.[0-9]{3})?Z$",
            options: .regularExpression
        ) != nil else {
            throw BundledRoutingResourceError.invalidManifest
        }
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.formatOptions = [.withInternetDateTime]
        if packagedAt.contains(".") {
            formatter.formatOptions.insert(.withFractionalSeconds)
        }
        guard let date = formatter.date(from: packagedAt),
              formatter.string(from: date) == packagedAt,
              date <= now else {
            throw BundledRoutingResourceError.invalidManifest
        }
        // Keep the pack's real age when an older DMG is installed later. Bundled
        // data stays usable while its age can correctly trigger a refresh.
        return date
    }

    private static func readRegularFile(
        _ fileName: String,
        in directory: Int32,
        maximumBytes: Int,
        expectedBytes: Int? = nil
    ) throws -> Data {
        let descriptor = openat(
            directory,
            fileName,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            throw BundledRoutingResourceError.unreadableFile(fileName)
        }
        defer { Darwin.close(descriptor) }

        var info = stat()
        guard fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG else {
            throw BundledRoutingResourceError.unreadableFile(fileName)
        }
        guard info.st_size > 0, info.st_size <= maximumBytes else {
            throw BundledRoutingResourceError.invalidFileSize(fileName)
        }
        if let expectedBytes, info.st_size != expectedBytes {
            throw BundledRoutingResourceError.invalidFileSize(fileName)
        }
        let initialSize = Int(info.st_size)
        var data = Data()
        data.reserveCapacity(initialSize)
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                throw BundledRoutingResourceError.unreadableFile(fileName)
            }
            guard count <= initialSize - data.count else {
                throw BundledRoutingResourceError.invalidFileSize(fileName)
            }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard data.count == initialSize else {
            throw BundledRoutingResourceError.invalidFileSize(fileName)
        }
        return data
    }
}

public enum BundledRoutingResourceError: LocalizedError, Equatable, Sendable {
    case unsafeDirectory
    case invalidManifest
    case unreadableFile(String)
    case invalidFileSize(String)
    case missingResource(RoutingResourceKind)
    case checksumMismatch(RoutingResourceKind)

    public var errorDescription: String? {
        switch self {
        case .unsafeDirectory, .invalidManifest, .unreadableFile,
             .invalidFileSize, .missingResource, .checksumMismatch:
            "The routing databases included with this app could not be verified. Reinstall AetherRoute and try again."
        }
    }
}

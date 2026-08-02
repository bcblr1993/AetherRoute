import CryptoKit
@preconcurrency import Foundation

public struct VerifiedSoftwareUpdateArtifact: Equatable, Sendable {
    public let fileURL: URL
    public let byteCount: Int64
    public let sha256: String

    public init(fileURL: URL, byteCount: Int64, sha256: String) {
        self.fileURL = fileURL
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct SoftwareUpdateDownloadResponse: Sendable {
    public let temporaryFileURL: URL
    public let statusCode: Int
    public let finalURL: URL

    public init(
        temporaryFileURL: URL,
        statusCode: Int,
        finalURL: URL
    ) {
        self.temporaryFileURL = temporaryFileURL
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public struct SoftwareUpdateArtifactVerifier: Sendable {
    public static let maximumArtifactBytes: Int64 = 512 * 1_024 * 1_024
    private static let readChunkBytes = 1 * 1_024 * 1_024

    public init() {}

    public func verify(
        fileAt fileURL: URL,
        expectedSHA256: String
    ) throws -> VerifiedSoftwareUpdateArtifact {
        guard fileURL.isFileURL,
              expectedSHA256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw IndependentDistributionError.invalidUpdateArtifact
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              let byteCount = values.fileSize.map(Int64.init),
              byteCount > 0 else {
            throw IndependentDistributionError.invalidUpdateArtifact
        }
        guard byteCount <= Self.maximumArtifactBytes else {
            throw IndependentDistributionError.updateArtifactTooLarge(
                byteCount
            )
        }

        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        var hasher = SHA256()
        var observedBytes: Int64 = 0
        while true {
            let data = try handle.read(upToCount: Self.readChunkBytes) ?? Data()
            if data.isEmpty { break }
            observedBytes += Int64(data.count)
            guard observedBytes <= Self.maximumArtifactBytes else {
                throw IndependentDistributionError.updateArtifactTooLarge(
                    observedBytes
                )
            }
            hasher.update(data: data)
        }
        guard observedBytes == byteCount else {
            throw IndependentDistributionError.invalidUpdateArtifact
        }
        let digest = hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
        guard digest == expectedSHA256 else {
            throw IndependentDistributionError.updateArtifactHashMismatch
        }
        return VerifiedSoftwareUpdateArtifact(
            fileURL: fileURL,
            byteCount: observedBytes,
            sha256: digest
        )
    }
}

public struct VerifiedSoftwareUpdateDownloader: Sendable {
    public typealias Transport = @Sendable (
        URL
    ) async throws -> SoftwareUpdateDownloadResponse
    typealias ArtifactCommitter = @Sendable (
        SoftwareUpdateDownloadResponse,
        SoftwareUpdateManifest,
        URL
    ) throws -> VerifiedSoftwareUpdateArtifact

    private let transport: Transport
    private let artifactCommitter: ArtifactCommitter

    public init(
        transport: @escaping Transport,
        verifier: SoftwareUpdateArtifactVerifier = .init()
    ) {
        self.transport = transport
        artifactCommitter = { response, manifest, destinationURL in
            try Self.commit(
                response: response,
                manifest: manifest,
                to: destinationURL,
                fileManager: FileManager(),
                verifier: verifier
            )
        }
    }

    init(
        transport: @escaping Transport,
        artifactCommitter: @escaping ArtifactCommitter
    ) {
        self.transport = transport
        self.artifactCommitter = artifactCommitter
    }

    public static func live() -> Self {
        Self { downloadURL in
            try IndependentDistributionConfiguration.validateHTTPSURL(
                downloadURL
            )
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.httpCookieAcceptPolicy = .never
            configuration.httpShouldSetCookies = false
            configuration.timeoutIntervalForRequest = 30
            configuration.timeoutIntervalForResource = 15 * 60
            configuration.waitsForConnectivity = false
            let delegate = SoftwareUpdateNoRedirectDelegate()
            let session = URLSession(
                configuration: configuration,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: downloadURL)
            request.httpMethod = "GET"
            request.setValue(
                "application/x-apple-diskimage, application/octet-stream",
                forHTTPHeaderField: "Accept"
            )
            request.setValue(
                "AetherRoute/1 UpdateDownloader",
                forHTTPHeaderField: "User-Agent"
            )
            let (temporaryFileURL, response) = try await session.download(
                for: request
            )
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url else {
                throw IndependentDistributionError.invalidHTTPResponse
            }
            return SoftwareUpdateDownloadResponse(
                temporaryFileURL: temporaryFileURL,
                statusCode: response.statusCode,
                finalURL: finalURL
            )
        }
    }

    public func download(
        manifest: SoftwareUpdateManifest,
        to destinationURL: URL
    ) async throws -> VerifiedSoftwareUpdateArtifact {
        try IndependentDistributionConfiguration.validateHTTPSURL(
            manifest.downloadURL
        )
        guard destinationURL.isFileURL,
              destinationURL.pathExtension.lowercased() == "dmg" else {
            throw IndependentDistributionError.invalidUpdateDestination
        }
        let response = try await transport(manifest.downloadURL)
        guard response.finalURL == manifest.downloadURL else {
            throw IndependentDistributionError.redirectRejected
        }
        guard response.statusCode == 200 else {
            throw IndependentDistributionError.httpStatus(
                response.statusCode
            )
        }
        return try await Task.detached(priority: .userInitiated) {
            try artifactCommitter(
                response,
                manifest,
                destinationURL
            )
        }.value
    }

    private static func commit(
        response: SoftwareUpdateDownloadResponse,
        manifest: SoftwareUpdateManifest,
        to destinationURL: URL,
        fileManager: FileManager,
        verifier: SoftwareUpdateArtifactVerifier
    ) throws -> VerifiedSoftwareUpdateArtifact {
        _ = try verifier.verify(
            fileAt: response.temporaryFileURL,
            expectedSHA256: manifest.sha256
        )

        let parent = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw IndependentDistributionError.invalidUpdateDestination
        }
        let stagedURL = parent.appendingPathComponent(
            ".aetherroute-update-\(UUID().uuidString).download",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: stagedURL) }
        try fileManager.copyItem(
            at: response.temporaryFileURL,
            to: stagedURL
        )
        _ = try verifier.verify(
            fileAt: stagedURL,
            expectedSHA256: manifest.sha256
        )

        if fileManager.fileExists(atPath: destinationURL.path) {
            _ = try fileManager.replaceItemAt(
                destinationURL,
                withItemAt: stagedURL,
                backupItemName: nil,
                options: [.usingNewMetadataOnly]
            )
        } else {
            try fileManager.moveItem(at: stagedURL, to: destinationURL)
        }
        return try verifier.verify(
            fileAt: destinationURL,
            expectedSHA256: manifest.sha256
        )
    }
}

private final class SoftwareUpdateNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

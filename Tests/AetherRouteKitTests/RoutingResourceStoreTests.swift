import AetherRouteKit
import CryptoKit
import XCTest

final class RoutingResourceStoreTests: XCTestCase {
    func testVerifiedResourcesMaterializeForBothEmbeddedCores() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support")
        let store = RoutingResourceStore(
            applicationSupportDirectory: support
        )
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let mmdb = validMMDB()
        let geoSite = validGeoSite()

        let mmdbRecord = try store.installVerified(
            data: mmdb,
            kind: .countryMMDB,
            expectedSHA256: digest(mmdb),
            installedAt: installedAt
        )
        let geoSiteRecord = try store.installVerified(
            data: geoSite,
            kind: .geoSite,
            expectedSHA256: digest(geoSite),
            installedAt: installedAt
        )

        XCTAssertEqual(mmdbRecord.origin, .verifiedDownload)
        XCTAssertEqual(geoSiteRecord.origin, .verifiedDownload)
        XCTAssertEqual(
            store.status(
                for: .countryMMDB,
                now: installedAt.addingTimeInterval(24 * 60 * 60)
            ),
            .ready(mmdbRecord)
        )
        XCTAssertEqual(
            store.status(
                for: .geoSite,
                now: installedAt.addingTimeInterval(24 * 60 * 60)
            ),
            .ready(geoSiteRecord)
        )

        let requirements = try store.prepareRuntimeResources(
            for: """
            rules:
              - GEOIP,CN,DIRECT,no-resolve
              - GEOSITE,private,DIRECT
            """,
            now: installedAt.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(requirements, [.countryMMDB, .geoSite])

        for runtime in [
            support.appendingPathComponent("Runtime"),
            support.appendingPathComponent("Runtime/FlowCore"),
        ] {
            XCTAssertEqual(
                try Data(contentsOf: runtime.appendingPathComponent("Country.mmdb")),
                mmdb
            )
            XCTAssertEqual(
                try Data(contentsOf: runtime.appendingPathComponent("GeoSite.dat")),
                geoSite
            )
            let permissions = try FileManager.default.attributesOfItem(
                atPath: runtime.appendingPathComponent("Country.mmdb").path
            )[.posixPermissions] as? NSNumber
            XCTAssertEqual(permissions?.intValue, 0o600)
        }
    }

    func testUserProvidedResourceIsRecordedAndBecomesStale() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let record = try store.installUserProvided(
            data: validMMDB(),
            kind: .countryMMDB,
            installedAt: installedAt
        )

        XCTAssertEqual(record.origin, .userProvided)
        XCTAssertEqual(
            store.status(
                for: .countryMMDB,
                now: installedAt.addingTimeInterval(
                    RoutingResourceStore.maximumResourceAge + 1
                )
            ),
            .stale(record)
        )
        XCTAssertThrowsError(
            try store.prepareRuntimeResources(
                for: "rules:\n  - GEOIP,CN,DIRECT",
                now: installedAt.addingTimeInterval(
                    RoutingResourceStore.maximumResourceAge + 1
                )
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .stale(.countryMMDB, installedAt: record.installedAt)
            )
        }
    }

    func testMissingCorruptAndFutureDatedResourcesFailClosed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let store = RoutingResourceStore(
            applicationSupportDirectory: support
        )
        let now = Date(timeIntervalSince1970: 1_700_000_000)

        XCTAssertEqual(store.status(for: .countryMMDB, now: now), .missing)
        XCTAssertThrowsError(
            try store.prepareRuntimeResources(
                for: "rules:\n  - GEOIP,CN,DIRECT",
                now: now
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .missing(.countryMMDB)
            )
        }

        _ = try store.installUserProvided(
            data: validMMDB(),
            kind: .countryMMDB,
            installedAt: now.addingTimeInterval(60 * 60)
        )
        XCTAssertEqual(
            store.status(for: .countryMMDB, now: now),
            .invalid(.metadataDateInFuture(.countryMMDB))
        )

        let asset = support.appendingPathComponent(
            "RoutingResources/Country.mmdb"
        )
        var corrupted = try Data(contentsOf: asset)
        corrupted[0] ^= 0xFF
        try corrupted.write(to: asset, options: [.atomic])
        XCTAssertEqual(
            store.status(
                for: .countryMMDB,
                now: now.addingTimeInterval(60 * 60)
            ),
            .invalid(.metadataMismatch(.countryMMDB))
        )
    }

    func testRejectsBadChecksumsFormatsAndSymlinkedRuntime() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let support = root.appendingPathComponent("Support")
        let store = RoutingResourceStore(
            applicationSupportDirectory: support
        )
        let mmdb = validMMDB()

        XCTAssertThrowsError(
            try store.installVerified(
                data: mmdb,
                kind: .countryMMDB,
                expectedSHA256: String(repeating: "0", count: 64)
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .checksumMismatch(.countryMMDB)
            )
        }
        XCTAssertThrowsError(
            try store.installUserProvided(
                data: Data(repeating: 0, count: 2_048),
                kind: .countryMMDB
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .invalidResourceFormat(.countryMMDB)
            )
        }
        XCTAssertThrowsError(
            try store.installUserProvided(
                data: Data(repeating: 0, count: 32),
                kind: .geoSite
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .invalidResourceFormat(.geoSite)
            )
        }

        _ = try store.installUserProvided(
            data: mmdb,
            kind: .countryMMDB,
            installedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let outside = root.appendingPathComponent("Outside")
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: true
        )
        let runtime = support.appendingPathComponent("Runtime")
        try FileManager.default.createSymbolicLink(
            at: runtime,
            withDestinationURL: outside
        )
        XCTAssertThrowsError(
            try store.prepareRuntimeResources(
                for: "rules:\n  - GEOIP,CN,DIRECT",
                now: Date(timeIntervalSince1970: 1_700_000_001)
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .unsafeRuntimeDirectory
            )
        }
    }

    func testDownloaderRequiresHTTPSChecksumAndInstallsVerifiedBytes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        let resourceURL = try XCTUnwrap(
            URL(string: "https://resources.example/GeoSite.dat")
        )
        let checksumURL = try XCTUnwrap(
            URL(string: "https://resources.example/GeoSite.dat.sha256sum")
        )
        let descriptor = try RoutingResourceRemoteDescriptor(
            kind: .geoSite,
            resourceURL: resourceURL,
            checksumURL: checksumURL
        )
        let data = validGeoSite()
        let expected = digest(data)
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let client = RoutingResourceDownloadClient(
            transport: { url, _ in
                if url == checksumURL {
                    return RoutingResourceHTTPResponse(
                        data: Data("\(expected)  GeoSite.dat\n".utf8),
                        statusCode: 200,
                        finalURL: checksumURL
                    )
                }
                return RoutingResourceHTTPResponse(
                    data: data,
                    statusCode: 200,
                    finalURL: resourceURL,
                    contentLength: data.count
                )
            },
            now: { installedAt }
        )

        let record = try await client.downloadAndInstall(
            descriptor,
            into: store
        )
        XCTAssertEqual(record.sha256, expected)
        XCTAssertEqual(record.installedAt, installedAt)
        XCTAssertEqual(
            store.status(for: .geoSite, now: installedAt),
            .ready(record)
        )

        XCTAssertThrowsError(
            try RoutingResourceRemoteDescriptor(
                kind: .geoSite,
                resourceURL: URL(string: "http://resources.example/GeoSite.dat")!,
                checksumURL: checksumURL
            )
        ) {
            XCTAssertEqual(
                $0 as? RoutingResourceError,
                .invalidRemoteURL
            )
        }
    }

    func testEnsureRequiredResourcesDownloadsMissingDatabasesAndSkipsReadyOnes() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(
            applicationSupportDirectory: root.appendingPathComponent("Support")
        )
        let mmdb = validMMDB()
        let geoSite = validGeoSite()
        let mmdbDigest = digest(mmdb)
        let geoSiteDigest = digest(geoSite)
        let installedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let requestCount = LockedRequestCount()
        let client = RoutingResourceDownloadClient(
            transport: { url, _ in
                requestCount.increment()
                let isMMDB = url.absoluteString.localizedCaseInsensitiveContains(
                    "mmdb"
                )
                let data = isMMDB ? mmdb : geoSite
                let expectedDigest = isMMDB ? mmdbDigest : geoSiteDigest
                if url.lastPathComponent.hasSuffix("sha256sum") {
                    return RoutingResourceHTTPResponse(
                        data: Data("\(expectedDigest)  resource\n".utf8),
                        statusCode: 200,
                        finalURL: url
                    )
                }
                return RoutingResourceHTTPResponse(
                    data: data,
                    statusCode: 200,
                    finalURL: url,
                    contentLength: data.count
                )
            },
            now: { installedAt }
        )
        let profile = """
        rules:
          - GEOIP,CN,DIRECT,no-resolve
          - GEOSITE,private,DIRECT
        """

        let installed = try await client.ensureRequiredResources(
            for: profile,
            in: store,
            statusDate: installedAt
        )
        XCTAssertEqual(installed, [.countryMMDB, .geoSite])
        XCTAssertEqual(requestCount.value, 4)

        let installedAgain = try await client.ensureRequiredResources(
            for: profile,
            in: store,
            statusDate: installedAt.addingTimeInterval(60)
        )
        XCTAssertEqual(installedAgain, [])
        XCTAssertEqual(requestCount.value, 4)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoutingResourceStoreTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    private func validMMDB() -> Data {
        var data = Data(repeating: 0x42, count: 2_048)
        data.append(contentsOf: [0xAB, 0xCD, 0xEF])
        data.append(Data("MaxMind.com".utf8))
        data.append(Data(repeating: 0x21, count: 64))
        return data
    }

    private func validGeoSite() -> Data {
        Data([0x0A, 0x1E]) + Data(repeating: 0x41, count: 30)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private final class LockedRequestCount: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }
}

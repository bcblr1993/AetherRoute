import AetherRouteKit
import CryptoKit
import XCTest

final class BundledRoutingResourcesTests: XCTestCase {
    private let bothResources = """
    rules:
      - GEOIP,CN,DIRECT,no-resolve
      - GEOSITE,private,DIRECT
    """

    func testFirstLaunchInstallsBothResourcesWithoutNetworkAndIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bundled = BundledRoutingResources(directoryURL: fixture.bundle)

        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            [.countryMMDB, .geoSite]
        )
        let snapshot = try fixture.store.launchResourceSnapshot(for: bothResources)
        XCTAssertEqual(snapshot[.countryMMDB], validMMDB())
        XCTAssertEqual(snapshot[.geoSite], validGeoSite())
        guard case let .ready(country) = fixture.store.status(for: .countryMMDB),
              case let .ready(geoSite) = fixture.store.status(for: .geoSite) else {
            return XCTFail("Packaged resources were not ready after offline installation")
        }
        XCTAssertEqual(country.origin, .bundled)
        XCTAssertEqual(geoSite.origin, .bundled)
        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            []
        )
        XCTAssertEqual(fixture.store.status(for: .countryMMDB), .ready(country))
        XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(geoSite))
    }

    func testOnlyResourcesRequiredByProfileAreInstalled() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let bundled = BundledRoutingResources(directoryURL: fixture.bundle)
        XCTAssertEqual(
            try bundled.installMissingResources(
                for: "rules:\n  - GEOIP,CN,DIRECT",
                in: fixture.store
            ),
            [.countryMMDB]
        )
        XCTAssertEqual(fixture.store.status(for: .geoSite), .missing)
    }

    func testReadyAndStaleUserResourcesAreNeverOverwritten() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let staleDate = Date.now.addingTimeInterval(-RoutingResourceStore.maximumResourceAge - 60)
        let country = try fixture.store.installUserProvided(
            data: validMMDB(marker: 0x55),
            kind: .countryMMDB
        )
        let geoSite = try fixture.store.installUserProvided(
            data: validGeoSite(marker: 0x56),
            kind: .geoSite,
            installedAt: staleDate
        )
        let bundled = BundledRoutingResources(directoryURL: fixture.bundle)
        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            []
        )
        XCTAssertEqual(fixture.store.status(for: .countryMMDB), .ready(country))
        XCTAssertEqual(fixture.store.status(for: .geoSite), .stale(geoSite))
        XCTAssertEqual(try fixture.resourceData(.countryMMDB), validMMDB(marker: 0x55))
        XCTAssertEqual(try fixture.resourceData(.geoSite), validGeoSite(marker: 0x56))
        let staleCountry = try fixture.store.installUserProvided(
            data: validMMDB(marker: 0x55),
            kind: .countryMMDB,
            installedAt: staleDate
        )
        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            []
        )
        XCTAssertEqual(fixture.store.status(for: .countryMMDB), .stale(staleCountry))
    }

    func testStaleBundledCountryRemainsUsableButExpiredDownloadedCountryIsReplaced() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let staleDate = Date.now.addingTimeInterval(-RoutingResourceStore.maximumResourceAge - 60)
        let customCountry = validMMDB(marker: 0x55)
        let country = try fixture.store.installBundled(
            data: customCountry,
            kind: .countryMMDB,
            expectedSHA256: digest(customCountry),
            installedAt: staleDate
        )
        let customGeoSite = validGeoSite(marker: 0x56)
        let geoSite = try fixture.store.installVerified(
            data: customGeoSite,
            kind: .geoSite,
            expectedSHA256: digest(customGeoSite),
            installedAt: staleDate
        )
        let bundled = BundledRoutingResources(directoryURL: fixture.bundle)
        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            []
        )
        XCTAssertEqual(fixture.store.status(for: .countryMMDB), .stale(country))
        XCTAssertEqual(fixture.store.status(for: .geoSite), .stale(geoSite))

        try fixture.store.installVerified(
            data: customCountry,
            kind: .countryMMDB,
            expectedSHA256: digest(customCountry),
            installedAt: staleDate
        )
        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            [.countryMMDB]
        )
        guard case let .ready(replacement) = fixture.store.status(for: .countryMMDB) else {
            return XCTFail("Expired downloaded Country database was not replaced")
        }
        XCTAssertEqual(replacement.origin, .bundled)
        XCTAssertEqual(try fixture.resourceData(.countryMMDB), validMMDB())
        XCTAssertEqual(fixture.store.status(for: .geoSite), .stale(geoSite))
    }

    func testCorruptInstalledResourceIsRepairedFromVerifiedPack() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.store.installUserProvided(data: validMMDB(marker: 0x55), kind: .countryMMDB)
        try Data("corrupt".utf8).write(to: fixture.resourceURL(.countryMMDB))
        XCTAssertEqual(
            try BundledRoutingResources(directoryURL: fixture.bundle)
                .installMissingResources(for: "rules:\n  - GEOIP,CN,DIRECT", in: fixture.store),
            [.countryMMDB]
        )
        XCTAssertEqual(try fixture.resourceData(.countryMMDB), validMMDB())
    }

    func testPackagedDatePreservesDatabaseAgeAndRejectsInvalidOrFutureDates() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let oldDate = Date(timeIntervalSince1970: 1_700_000_000)
        let formatter = ISO8601DateFormatter()
        let bundled = BundledRoutingResources(directoryURL: fixture.bundle)
        for packagedAt in [
            "not-a-date",
            "2026-02-30T00:00:00Z",
            "2026-09-05T00:00:00Zgarbage",
            formatter.string(from: .now.addingTimeInterval(3_600)),
        ] {
            try writeManifest([
                "schema": 1,
                "resources": manifestEntries(),
                "packagedAt": packagedAt,
            ], to: fixture.bundle)
            XCTAssertThrowsError(try bundled.installMissingResources(for: bothResources, in: fixture.store)) {
                XCTAssertEqual($0 as? BundledRoutingResourceError, .invalidManifest)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
        }
        try writeManifest([
            "schema": 1,
            "resources": manifestEntries(),
            "packagedAt": formatter.string(from: oldDate),
        ], to: fixture.bundle)
        XCTAssertEqual(
            try bundled.installMissingResources(for: bothResources, in: fixture.store),
            [.countryMMDB, .geoSite]
        )
        guard case let .stale(country) = fixture.store.status(for: .countryMMDB),
              case let .stale(geoSite) = fixture.store.status(for: .geoSite) else {
            return XCTFail("Old packaged resources were incorrectly marked as freshly published")
        }
        XCTAssertEqual(country.installedAt, oldDate)
        XCTAssertEqual(geoSite.installedAt, oldDate)
        XCTAssertTrue(fixture.store.status(for: .countryMMDB).isUsableForConnection)
        XCTAssertTrue(fixture.store.status(for: .geoSite).isUsableForConnection)
    }

    func testAbsentOptionalPackFallsBackWithoutWritingButPresentIncompletePackThrows() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        for directory in [nil, fixture.root.appendingPathComponent("Not Installed")] {
            XCTAssertEqual(
                try BundledRoutingResources(directoryURL: directory)
                    .installMissingResources(for: bothResources, in: fixture.store),
                []
            )
        }
        try FileManager.default.removeItem(at: fixture.bundle.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: fixture.bundle)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .unreadableFile("manifest.json"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
    }

    func testTamperedSecondDatabasePreventsEveryStoreWrite() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try validGeoSite(marker: 0x55).write(to: fixture.bundle.appendingPathComponent("GeoSite.dat"))
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: fixture.bundle)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .checksumMismatch(.geoSite))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
    }

    func testManifestRejectsPathEscapeDuplicateKindUnknownSchemaAndInsecureSource() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let entries = manifestEntries()
        var traversal = entries
        traversal[0]["fileName"] = "../Country.mmdb"
        var oversized = entries
        oversized[0]["byteCount"] = RoutingResourceKind.countryMMDB.maximumBytes + 1
        var insecure = entries
        insecure[0]["sourceURL"] = "http://resources.example/Country.mmdb"
        for manifest in [
            ["schema": 1, "resources": traversal],
            ["schema": 1, "resources": [entries[0], entries[0]]],
            ["schema": 2, "resources": entries],
            ["schema": 1, "resources": oversized],
            ["schema": 1, "resources": insecure],
        ] as [[String: Any]] {
            try writeManifest(manifest, to: fixture.bundle)
            XCTAssertThrowsError(
                try BundledRoutingResources(directoryURL: fixture.bundle)
                    .installMissingResources(for: bothResources, in: fixture.store)
            ) {
                XCTAssertEqual($0 as? BundledRoutingResourceError, .invalidManifest)
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
    }

    func testMissingRequiredManifestEntryThrowsBeforeWriting() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try writeManifest(["schema": 1, "resources": [manifestEntries()[0]]], to: fixture.bundle)
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: fixture.bundle)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .missingResource(.geoSite))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
    }

    func testOversizedManifestAndSparseResourceAreRejectedBeforeReadingPayload() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try Data(repeating: 32, count: BundledRoutingResources.maximumManifestBytes + 1)
            .write(to: fixture.bundle.appendingPathComponent("manifest.json"))
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: fixture.bundle)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .invalidFileSize("manifest.json"))
        }
        try writeManifest(["schema": 1, "resources": manifestEntries()], to: fixture.bundle)
        let oversized = try FileHandle(forWritingTo: fixture.bundle.appendingPathComponent("GeoSite.dat"))
        try oversized.truncate(atOffset: UInt64(RoutingResourceKind.geoSite.maximumBytes + 1))
        try oversized.close()
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: fixture.bundle)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .invalidFileSize("GeoSite.dat"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
    }

    func testSymlinkedResourceManifestAndPackDirectoryAreRejected() throws {
        for fileName in ["Country.mmdb", "manifest.json"] {
            let fixture = try makeFixture()
            defer { fixture.remove() }
            let original = fixture.bundle.appendingPathComponent(fileName)
            let outside = fixture.root.appendingPathComponent("Outside")
            try FileManager.default.moveItem(at: original, to: outside)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: outside)
            XCTAssertThrowsError(
                try BundledRoutingResources(directoryURL: fixture.bundle)
                    .installMissingResources(for: bothResources, in: fixture.store)
            ) {
                XCTAssertEqual($0 as? BundledRoutingResourceError, .unreadableFile(fileName))
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
        }
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("Linked Pack", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.bundle)
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: link)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .unsafeDirectory)
        }
        let trailingSlashLink = try XCTUnwrap(URL(string: link.absoluteString + "/"))
        XCTAssertThrowsError(
            try BundledRoutingResources(directoryURL: trailingSlashLink)
                .installMissingResources(for: bothResources, in: fixture.store)
        ) {
            XCTAssertEqual($0 as? BundledRoutingResourceError, .unsafeDirectory)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
    }

    private struct Fixture {
        let root: URL
        let bundle: URL
        let store: RoutingResourceStore

        func remove() { try? FileManager.default.removeItem(at: root) }

        func resourceURL(_ kind: RoutingResourceKind) -> URL {
            store.applicationSupportDirectory.appendingPathComponent("RoutingResources/\(kind.fileName)")
        }

        func resourceData(_ kind: RoutingResourceKind) throws -> Data {
            try Data(contentsOf: resourceURL(kind))
        }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "BundledRoutingResourcesTests-\(UUID().uuidString)",
            isDirectory: true
        )
        let bundle = root.appendingPathComponent("Pack", isDirectory: true)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try validMMDB().write(to: bundle.appendingPathComponent("Country.mmdb"))
        try validGeoSite().write(to: bundle.appendingPathComponent("GeoSite.dat"))
        try writeManifest([
            "schema": 1,
            "resources": manifestEntries(),
            "packagedAt": ISO8601DateFormatter().string(from: .now),
        ], to: bundle)
        return Fixture(
            root: root,
            bundle: bundle,
            store: RoutingResourceStore(applicationSupportDirectory: root.appendingPathComponent("Support"))
        )
    }

    private func manifestEntries() -> [[String: Any]] {
        [(.countryMMDB, validMMDB()), (.geoSite, validGeoSite())].map {
            (kind: RoutingResourceKind, data: Data) in
            [
                "kind": kind.rawValue,
                "fileName": kind.fileName,
                "sha256": digest(data),
                "byteCount": data.count,
                "sourceURL": "https://resources.example/\(kind.fileName)",
            ]
        }
    }

    private func writeManifest(_ manifest: [String: Any], to directory: URL) throws {
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("manifest.json"), options: [.atomic])
    }

    private func validMMDB(marker: UInt8 = 0x42) -> Data {
        Data(repeating: marker, count: 2_048)
            + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
            + Data(repeating: 0x21, count: 64)
    }

    private func validGeoSite(marker: UInt8 = 0x41) -> Data {
        Data([0x0A, 0x1E]) + Data(repeating: marker, count: 30)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

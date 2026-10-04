import AetherRouteKit
import CryptoKit
import XCTest

final class RoutingResourceRefreshTests: XCTestCase {
    private let day: TimeInterval = 24 * 60 * 60

    func testUnchangedUpstreamRecordsTheCheckWithoutDownloadingTheDatabase() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(applicationSupportDirectory: root)
        let data = validMMDB(marker: 0x42)
        // A MaxMind download past 30 days is unusable until it is refreshed.
        let installedAt = Date.now.addingTimeInterval(-35 * day)
        let original = try store.installVerified(
            data: data, kind: .countryMMDB, expectedSHA256: digest(data), installedAt: installedAt
        )
        XCTAssertFalse(store.status(for: .countryMMDB).isUsableForConnection)

        let requests = RequestLog()
        let checkedAt = Date.now
        let checksum = digest(data)
        let client = RoutingResourceDownloadClient(transport: { url, _ in
            requests.append(url)
            guard url.lastPathComponent.hasSuffix("sha256sum") else {
                XCTFail("An unchanged database was downloaded again")
                return RoutingResourceHTTPResponse(data: data, statusCode: 200, finalURL: url)
            }
            return RoutingResourceHTTPResponse(
                data: Data("\(checksum)  Country.mmdb\n".utf8), statusCode: 200, finalURL: url
            )
        }, now: { checkedAt })

        let outcome = try await client.refresh(
            .maintainedDefault(for: .countryMMDB), into: store, current: original
        )

        guard case let .alreadyCurrent(record) = outcome else {
            return XCTFail("Expected an unchanged upstream, got \(outcome)")
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(record.sha256, original.sha256)
        XCTAssertEqual(record.installedAt, original.installedAt)
        XCTAssertEqual(record.origin, .verifiedDownload)
        XCTAssertEqual(
            record.lastCheckedAt?.timeIntervalSince1970,
            checkedAt.timeIntervalSince1970.rounded(.down)
        )
        XCTAssertEqual(store.status(for: .countryMMDB), .ready(record))
        XCTAssertEqual(try store.launchResourceSnapshot(for: "rules:\n  - GEOIP,CN,DIRECT\n")[.countryMMDB], data)
    }

    func testChangedUpstreamDownloadsAndReplacesTheResource() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(applicationSupportDirectory: root)
        let old = validGeoSite(marker: 0x41)
        let original = try store.installBundled(
            data: old, kind: .geoSite, expectedSHA256: digest(old),
            installedAt: .now.addingTimeInterval(-8 * day)
        )
        let update = validGeoSite(marker: 0x42)
        let checksum = digest(update)
        let requests = RequestLog()
        let client = RoutingResourceDownloadClient { url, _ in
            requests.append(url)
            if url.lastPathComponent.hasSuffix("sha256sum") {
                return RoutingResourceHTTPResponse(
                    data: Data("\(checksum) dlc.dat\n".utf8), statusCode: 200, finalURL: url
                )
            }
            return RoutingResourceHTTPResponse(data: update, statusCode: 200, finalURL: url)
        }

        let outcome = try await client.refresh(
            .maintainedDefault(for: .geoSite), into: store, current: original
        )

        guard case let .updated(record) = outcome else {
            return XCTFail("Expected a download, got \(outcome)")
        }
        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(record.sha256, digest(update))
        XCTAssertEqual(record.origin, .verifiedDownload)
        XCTAssertNil(record.lastCheckedAt)
        XCTAssertEqual(store.status(for: .geoSite), .ready(record))
    }

    func testRecordedCheckLosesToAResourceThatChangedMeanwhile() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(applicationSupportDirectory: root)
        let bundled = validGeoSite(marker: 0x41)
        let original = try store.installBundled(
            data: bundled, kind: .geoSite, expectedSHA256: digest(bundled)
        )
        let imported = try store.installUserProvided(data: validGeoSite(marker: 0x43), kind: .geoSite)

        XCTAssertThrowsError(try store.recordUpstreamCheck(for: original)) {
            XCTAssertEqual($0 as? RoutingResourceError, .superseded(.geoSite))
        }
        XCTAssertEqual(store.status(for: .geoSite), .ready(imported))
    }

    func testMetadataWithoutCheckDateFromEarlierVersionsStillLoads() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(applicationSupportDirectory: root)
        let data = validGeoSite(marker: 0x41)
        let installedAt = Date(timeIntervalSince1970: Date.now.timeIntervalSince1970.rounded(.down) - 2 * day)
        let record = try store.installBundled(
            data: data, kind: .geoSite, expectedSHA256: digest(data), installedAt: installedAt
        )
        // 1.1.5 wrote exactly these keys.
        let metadataURL = root.appendingPathComponent("RoutingResources/GeoSite.dat.metadata.json")
        let metadata = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: metadataURL)) as? [String: Any]
        )
        XCTAssertEqual(
            Set(metadata.keys),
            ["byteCount", "formatVersion", "installedAt", "kind", "origin", "sha256"]
        )
        XCTAssertNil(record.lastCheckedAt)
        XCTAssertEqual(record.verifiedCurrentAt, installedAt)
        XCTAssertEqual(store.status(for: .geoSite), .ready(record))
    }

    func testCheckDateInTheFutureIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = RoutingResourceStore(applicationSupportDirectory: root)
        let data = validGeoSite(marker: 0x41)
        let record = try store.installBundled(data: data, kind: .geoSite, expectedSHA256: digest(data))
        let future = Date.now.addingTimeInterval(2 * day)
        try store.recordUpstreamCheck(for: record, checkedAt: future)

        XCTAssertEqual(store.status(for: .geoSite), .invalid(.metadataDateInFuture(.geoSite)))
        if case .ready = store.status(for: .geoSite, now: future) {} else {
            XCTFail("The same record is valid once its check date has passed")
        }
    }

    func testWeeklyCheckPolicyAndBackoff() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func record(age: TimeInterval, checkedAge: TimeInterval? = nil, origin: RoutingResourceOrigin) -> RoutingResourceRecord {
            RoutingResourceRecord(
                kind: .geoSite, sha256: String(repeating: "a", count: 64), byteCount: 32,
                installedAt: now.addingTimeInterval(-age), origin: origin,
                lastCheckedAt: checkedAge.map { now.addingTimeInterval(-$0) }
            )
        }
        typealias Policy = RoutingResourceRefreshPolicy
        XCTAssertFalse(Policy.isDue(record(age: 7 * day - 60, origin: .verifiedDownload), now: now))
        XCTAssertTrue(Policy.isDue(record(age: 7 * day, origin: .verifiedDownload), now: now))
        XCTAssertTrue(Policy.isDue(record(age: 8 * day, origin: .bundled), now: now))
        XCTAssertFalse(Policy.isDue(record(age: 40 * day, origin: .userProvided), now: now))
        // A recent unchanged-upstream check resets the weekly clock.
        XCTAssertFalse(Policy.isDue(record(age: 20 * day, checkedAge: day, origin: .verifiedDownload), now: now))
        XCTAssertTrue(Policy.isNearingExpiry(record(age: 25 * day, origin: .bundled), now: now))
        XCTAssertFalse(Policy.isNearingExpiry(record(age: 26 * day, checkedAge: day, origin: .bundled), now: now))

        XCTAssertEqual(Policy.retryDelay(afterConsecutiveFailures: 0), 0)
        XCTAssertEqual(Policy.retryDelay(afterConsecutiveFailures: 1), 60 * 60)
        XCTAssertEqual(Policy.retryDelay(afterConsecutiveFailures: 2), 6 * 60 * 60)
        XCTAssertEqual(Policy.retryDelay(afterConsecutiveFailures: 3), day)
        XCTAssertEqual(Policy.retryDelay(afterConsecutiveFailures: 9), day)
        // Weekly checks plus the longest retry stay well inside the 30-day expiry.
        XCTAssertLessThan(
            Policy.checkInterval + Policy.retryDelays.reduce(0, +),
            RoutingResourceStore.maximumResourceAge
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoutingResourceRefreshTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    private func validMMDB(marker: UInt8) -> Data {
        Data(repeating: marker, count: 2_048)
            + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
            + Data(repeating: 0x21, count: 64)
    }

    private func validGeoSite(marker: UInt8) -> Data {
        Data([0x0A, 0x1E]) + Data(repeating: marker, count: 30)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class RequestLog: @unchecked Sendable {
    private let lock = NSLock()
    private var urls = [URL]()

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return urls.count
    }

    func append(_ url: URL) {
        lock.lock()
        urls.append(url)
        lock.unlock()
    }
}

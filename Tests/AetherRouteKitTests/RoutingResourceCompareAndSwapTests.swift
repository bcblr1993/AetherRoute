import AetherRouteKit
import CryptoKit
import XCTest

@MainActor
final class RoutingResourceCompareAndSwapTests: XCTestCase {
    func testDelayedAutomaticDownloadDoesNotOverwriteUserImport() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let originalData = validGeoSite(marker: 0x41)
        let original = try fixture.store.installBundled(
            data: originalData,
            kind: .geoSite,
            expectedSHA256: digest(originalData),
            installedAt: .now.addingTimeInterval(-RoutingResourceStore.maximumResourceAge - 60)
        )
        let update = validGeoSite(marker: 0x42)
        let checksum = digest(update)
        let gate = RoutingDownloadGate()
        let client = RoutingResourceDownloadClient { url, _ in
            if url.lastPathComponent.hasSuffix("sha256sum") {
                return RoutingResourceHTTPResponse(
                    data: Data("\(checksum) GeoSite.dat\n".utf8), statusCode: 200, finalURL: url
                )
            }
            await gate.pause()
            return RoutingResourceHTTPResponse(data: update, statusCode: 200, finalURL: url)
        }
        let descriptor = try RoutingResourceRemoteDescriptor.maintainedDefault(for: .geoSite)
        let download = Task {
            try await client.downloadAndInstall(descriptor, into: fixture.store, replacing: original)
        }
        await gate.waitUntilPaused()
        let userData = validGeoSite(marker: 0x43)
        let imported = try fixture.store.installUserProvided(data: userData, kind: .geoSite)
        await gate.resume()
        do {
            _ = try await download.value
            XCTFail("An outdated background result overwrote the user import")
        } catch {
            XCTAssertEqual(error as? RoutingResourceError, .superseded(.geoSite))
        }
        XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(imported))
        XCTAssertEqual(try Data(contentsOf: fixture.resourceURL), userData)
    }

    func testParallelCompareAndSwapCommitsHaveExactlyOneWinner() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        for round in 0..<12 {
            let original = try fixture.store.installUserProvided(
                data: validGeoSite(marker: 0x41), kind: .geoSite
            )
            let candidates = [validGeoSite(marker: 0x42), validGeoSite(marker: 0x43)]
            let payloads = candidates.map { (data: $0, digest: digest($0)) }
            let store = fixture.store
            let outcomes = await withTaskGroup(of: Result<RoutingResourceRecord, Error>.self) { group in
                for payload in payloads {
                    group.addTask {
                        do {
                            return .success(try store.installVerified(
                                data: payload.data,
                                kind: .geoSite,
                                expectedSHA256: payload.digest,
                                replacing: original
                            ))
                        } catch {
                            return .failure(error)
                        }
                    }
                }
                var outcomes = [Result<RoutingResourceRecord, Error>]()
                for await outcome in group { outcomes.append(outcome) }
                return outcomes
            }
            var winners = [RoutingResourceRecord]()
            for outcome in outcomes {
                switch outcome {
                case let .success(record): winners.append(record)
                case let .failure(error):
                    XCTAssertEqual(error as? RoutingResourceError, .superseded(.geoSite))
                }
            }
            XCTAssertEqual(winners.count, 1, "round \(round) committed more than one stale snapshot")
            let winner = try XCTUnwrap(winners.first)
            XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(winner))
            XCTAssertEqual(digest(try Data(contentsOf: fixture.resourceURL)), winner.sha256)
        }
    }

    func testBundledFallbackPreservesUsableDataUnderTheCommitLock() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let userData = validGeoSite(marker: 0x41)
        let userRecord = try fixture.store.installUserProvided(data: userData, kind: .geoSite)
        let bundled = validGeoSite(marker: 0x42)
        XCTAssertThrowsError(try fixture.store.installBundled(
            data: bundled,
            kind: .geoSite,
            expectedSHA256: digest(bundled),
            preservingUsableResource: true
        )) {
            XCTAssertEqual($0 as? RoutingResourceError, .superseded(.geoSite))
        }
        XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(userRecord))
        XCTAssertEqual(try Data(contentsOf: fixture.resourceURL), userData)
    }

    func testCancelledDownloadCannotCommitEvenIfItsTransportFinishes() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let original = try fixture.store.installUserProvided(data: validGeoSite(marker: 0x41), kind: .geoSite)
        let update = validGeoSite(marker: 0x42)
        let checksum = digest(update)
        let gate = RoutingDownloadGate()
        let client = RoutingResourceDownloadClient { url, _ in
            if url.lastPathComponent.hasSuffix("sha256sum") {
                return RoutingResourceHTTPResponse(
                    data: Data("\(checksum) GeoSite.dat\n".utf8), statusCode: 200, finalURL: url
                )
            }
            await gate.pause()
            return RoutingResourceHTTPResponse(data: update, statusCode: 200, finalURL: url)
        }
        let descriptor = try RoutingResourceRemoteDescriptor.maintainedDefault(for: .geoSite)
        let download = Task {
            try await client.downloadAndInstall(descriptor, into: fixture.store, replacing: original)
        }
        await gate.waitUntilPaused()
        download.cancel()
        await gate.resume()
        do {
            _ = try await download.value
            XCTFail("A cancelled refresh committed its downloaded bytes")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(original))
    }

    func testCommitRejectsSymlinkedLockWithoutChangingResource() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let original = try fixture.store.installUserProvided(data: validGeoSite(marker: 0x41), kind: .geoSite)
        let lock = fixture.resourceURL.deletingLastPathComponent().appendingPathComponent(".commit.lock")
        let outside = fixture.root.appendingPathComponent("outside-lock")
        try Data("untouched".utf8).write(to: outside)
        try FileManager.default.removeItem(at: lock)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: outside)
        XCTAssertThrowsError(try fixture.store.installUserProvided(data: validGeoSite(marker: 0x42), kind: .geoSite)) {
            XCTAssertEqual($0 as? RoutingResourceError, .unsafeResourceFile)
        }
        XCTAssertEqual(fixture.store.status(for: .geoSite), .invalid(.unsafeResourceFile))
        XCTAssertEqual(digest(try Data(contentsOf: fixture.resourceURL)), original.sha256)
        XCTAssertEqual(try Data(contentsOf: outside), Data("untouched".utf8))
    }

    func testReadersWaitForACompleteDataAndMetadataCommit() async throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        try fixture.store.installUserProvided(data: validGeoSite(marker: 0x41), kind: .geoSite)
        let update = validGeoSite(marker: 0x42)
        let store = fixture.store
        let resourcePath = fixture.resourceURL.path
        let didReplaceData = DispatchSemaphore(value: 0)
        let allowMetadataWrite = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            let fileManager = PausingRoutingResourceFileManager(
                resourcePath: resourcePath,
                didReplaceData: didReplaceData,
                allowMetadataWrite: allowMetadataWrite
            )
            return try store.installUserProvided(data: update, kind: .geoSite, fileManager: fileManager)
        }
        XCTAssertEqual(didReplaceData.wait(timeout: .now() + 10), .success)
        defer { allowMetadataWrite.signal() }
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let profile = "rules:\n  - GEOSITE,cn,DIRECT\n  - MATCH,DIRECT\n"
        let status = Task.detached {
            started.signal()
            defer { finished.signal() }
            return store.status(for: .geoSite)
        }
        let snapshot = Task.detached {
            started.signal()
            defer { finished.signal() }
            return try store.launchResourceSnapshot(for: profile)
        }
        let runtime = Task.detached {
            started.signal()
            defer { finished.signal() }
            return try store.prepareRuntimeResources(for: profile)
        }
        for _ in 0..<3 {
            XCTAssertEqual(started.wait(timeout: .now() + 10), .success)
        }
        XCTAssertEqual(
            finished.wait(timeout: .now() + 0.25), .timedOut,
            "A reader observed the interval between replacing data and metadata"
        )
        allowMetadataWrite.signal()
        let committed = try await writer.value
        let observedStatus = await status.value
        let observedSnapshot = try await snapshot.value
        let prepared = try await runtime.value
        XCTAssertEqual(observedStatus, .ready(committed))
        XCTAssertEqual(observedSnapshot[.geoSite], update)
        XCTAssertEqual(prepared, [.geoSite])
        XCTAssertEqual(try Data(contentsOf: store.applicationSupportDirectory
            .appendingPathComponent("Runtime/GeoSite.dat")), update)
    }

    func testMissingReadsDoNotCreateDirectoriesOrLockFiles() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let profile = "rules:\n  - GEOSITE,cn,DIRECT\n"
        XCTAssertEqual(fixture.store.status(for: .geoSite), .missing)
        XCTAssertThrowsError(try fixture.store.launchResourceSnapshot(for: profile)) {
            XCTAssertEqual($0 as? RoutingResourceError, .missing(.geoSite))
        }
        XCTAssertThrowsError(try fixture.store.prepareRuntimeResources(for: profile))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.applicationSupportDirectory.path))
        let directory = fixture.resourceURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        XCTAssertEqual(fixture.store.status(for: .geoSite), .missing)
        XCTAssertThrowsError(try fixture.store.launchResourceSnapshot(for: profile))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testExistingResourceWithoutALockMigratesToCoordinatedReads() throws {
        let fixture = try makeFixture()
        defer { fixture.remove() }
        let original = try fixture.store.installUserProvided(data: validGeoSite(marker: 0x41), kind: .geoSite)
        let lock = fixture.resourceURL.deletingLastPathComponent().appendingPathComponent(".commit.lock")
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(original))
        XCTAssertTrue(FileManager.default.fileExists(atPath: lock.path))
    }

    private struct Fixture {
        let root: URL
        let store: RoutingResourceStore
        var resourceURL: URL {
            store.applicationSupportDirectory.appendingPathComponent("RoutingResources/GeoSite.dat")
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "RoutingResourceCASTests-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        return Fixture(root: root, store: RoutingResourceStore(applicationSupportDirectory: root.appendingPathComponent("Support")))
    }

    private func validGeoSite(marker: UInt8) -> Data {
        Data([0x0A, 0x1E]) + Data(repeating: marker, count: 30)
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class PausingRoutingResourceFileManager: FileManager, @unchecked Sendable {
    let didReplaceData: DispatchSemaphore
    let allowMetadataWrite: DispatchSemaphore
    private let resourcePath: String

    init(resourcePath: String, didReplaceData: DispatchSemaphore, allowMetadataWrite: DispatchSemaphore) {
        self.resourcePath = resourcePath
        self.didReplaceData = didReplaceData
        self.allowMetadataWrite = allowMetadataWrite
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        try super.setAttributes(attributes, ofItemAtPath: path)
        guard path == resourcePath else { return }
        didReplaceData.signal()
        guard allowMetadataWrite.wait(timeout: .now() + 20) == .success else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private actor RoutingDownloadGate {
    private var paused = false
    private var pendingDownload: CheckedContinuation<Void, Never>?
    private var pendingObserver: CheckedContinuation<Void, Never>?

    func pause() async {
        await withCheckedContinuation { continuation in
            pendingDownload = continuation
            paused = true
            pendingObserver?.resume()
            pendingObserver = nil
        }
    }

    func waitUntilPaused() async {
        guard !paused else { return }
        await withCheckedContinuation { pendingObserver = $0 }
    }

    func resume() {
        pendingDownload?.resume()
        pendingDownload = nil
    }
}

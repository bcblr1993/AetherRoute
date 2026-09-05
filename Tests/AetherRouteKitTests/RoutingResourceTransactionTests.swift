import AetherRouteKit
import CryptoKit
import Darwin
import XCTest

@MainActor
final class RoutingResourceTransactionTests: XCTestCase {
    func testDataProtectionFailurePreservesUserAndBundledResources() throws {
        try assertProtectionFailurePreservesOriginal(failingFileName: "GeoSite.dat")
    }

    func testMetadataProtectionFailurePreservesUserAndBundledResources() throws {
        try assertProtectionFailurePreservesOriginal(failingFileName: "GeoSite.dat.metadata.json")
    }

    func testBackupFailurePreservesUserAndBundledResources() throws {
        try assertCommitFailurePreservesOriginal(.backup)
    }

    func testDataMoveFailureRestoresUserAndBundledResources() throws {
        try assertCommitFailurePreservesOriginal(.dataMove)
    }

    func testMetadataMoveFailureRestoresUserAndBundledResources() throws {
        try assertCommitFailurePreservesOriginal(.metadataMove)
    }

    func testPostCommitVerificationFailureRestoresUserAndBundledResources() throws {
        try assertCommitFailurePreservesOriginal(.verification, expectedError: .metadataMismatch(.geoSite))
    }

    func testSuccessfulCommitProtectsFilesAndRemovesBackups() throws {
        let fixture = try Fixture(origin: .userProvided)
        defer { fixture.remove() }
        let installed = try fixture.update(fileManager: .default)
        XCTAssertEqual(fixture.store.status(for: .geoSite), .ready(installed))
        XCTAssertEqual(try fixture.store.launchResourceSnapshot(for: fixture.profile)[.geoSite], fixture.updateData)
        for fileName in ["GeoSite.dat", "GeoSite.dat.metadata.json"] {
            let attributes = try FileManager.default.attributesOfItem(
                atPath: fixture.resourceDirectory.appendingPathComponent(fileName).path
            )
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
            XCTAssertEqual((attributes[.referenceCount] as? NSNumber)?.intValue, 1)
        }
        try fixture.assertNoTemporaryFiles()
    }

    func testFirstInstallFailureRestoresMissingStateAndRemovesTemporaryFiles() throws {
        let fixture = try Fixture(origin: .bundled)
        defer { fixture.remove() }
        for fileName in ["GeoSite.dat", "GeoSite.dat.metadata.json"] {
            try FileManager.default.removeItem(at: fixture.resourceDirectory.appendingPathComponent(fileName))
        }
        let fileManager = FailingRoutingResourceCommitFileManager(fault: .metadataMove)
        XCTAssertThrowsError(try fixture.store.installUserProvided(
            data: fixture.updateData, kind: .geoSite, fileManager: fileManager
        )) {
            XCTAssertEqual($0 as? RoutingResourceError, .writeFailed)
        }
        XCTAssertTrue(fileManager.injectedFailure)
        XCTAssertEqual(fixture.store.status(for: .geoSite), .missing)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.resourceDirectory.path), [".commit.lock"])
    }

    func testRollbackFailureIsReportedAndRetainsOriginalMetadataForRecovery() throws {
        let fixture = try Fixture(origin: .userProvided)
        defer { fixture.remove() }
        let metadataURL = fixture.resourceDirectory.appendingPathComponent("GeoSite.dat.metadata.json")
        let originalMetadata = try Data(contentsOf: metadataURL)
        let fileManager = FailingRoutingResourceCommitFileManager(fault: .rollback)
        XCTAssertThrowsError(try fixture.update(fileManager: fileManager)) {
            XCTAssertEqual($0 as? RoutingResourceError, .rollbackFailed)
        }
        XCTAssertTrue(fileManager.injectedFailure)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.resourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".staging-") }
        XCTAssertEqual(remaining.count, 1)
        let recoveryDirectory = try XCTUnwrap(remaining.first)
        XCTAssertEqual(try Data(contentsOf: recoveryDirectory.appendingPathComponent("previous-metadata")), originalMetadata)
        XCTAssertEqual(try Data(contentsOf: fixture.resourceDirectory.appendingPathComponent("GeoSite.dat")), fixture.originalData)
    }

    func testCleanupFailureIsReportedWithoutBreakingTheCommittedPair() throws {
        let fixture = try Fixture(origin: .bundled)
        defer { fixture.remove() }
        let fileManager = FailingRoutingResourceCommitFileManager(fault: .cleanup)
        XCTAssertThrowsError(try fixture.update(fileManager: fileManager)) {
            XCTAssertEqual($0 as? RoutingResourceError, .temporaryCleanupFailed)
        }
        XCTAssertTrue(fileManager.injectedFailure)
        XCTAssertTrue(fixture.store.status(for: .geoSite).isUsableForConnection)
        XCTAssertEqual(try fixture.store.launchResourceSnapshot(for: fixture.profile)[.geoSite], fixture.updateData)
        let remaining = try FileManager.default.contentsOfDirectory(at: fixture.resourceDirectory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".staging-") }
        XCTAssertEqual(remaining.count, 1)
        let recoveryDirectory = try XCTUnwrap(remaining.first)
        XCTAssertEqual(try Data(contentsOf: recoveryDirectory.appendingPathComponent("previous-data")), fixture.originalData)
    }

    private func assertCommitFailurePreservesOriginal(
        _ fault: FailingRoutingResourceCommitFileManager.Fault,
        expectedError: RoutingResourceError = .writeFailed
    ) throws {
        for origin in [RoutingResourceOrigin.userProvided, .bundled] {
            let fixture = try Fixture(origin: origin)
            defer { fixture.remove() }
            let fileManager = FailingRoutingResourceCommitFileManager(fault: fault)
            XCTAssertThrowsError(try fixture.update(fileManager: fileManager)) {
                XCTAssertEqual($0 as? RoutingResourceError, expectedError)
            }
            XCTAssertTrue(fileManager.injectedFailure)
            try fixture.assertOriginalIsUsable()
            try fixture.assertNoTemporaryFiles()
        }
    }

    private func assertProtectionFailurePreservesOriginal(failingFileName: String) throws {
        for origin in [RoutingResourceOrigin.userProvided, .bundled] {
            let fixture = try Fixture(origin: origin)
            defer { fixture.remove() }
            let fileManager = FailingRoutingResourceAttributesFileManager(failingFileName: failingFileName)
            XCTAssertThrowsError(try fixture.update(fileManager: fileManager)) {
                XCTAssertEqual($0 as? RoutingResourceError, .writeFailed)
            }
            XCTAssertTrue(fileManager.injectedFailure, "The fault must occur after the atomic file write")
            try fixture.assertOriginalIsUsable()
            try fixture.assertNoTemporaryFiles()
        }
    }

    private struct Fixture {
        let root: URL
        let store: RoutingResourceStore
        let originalData = Data([0x0A, 0x1E]) + Data(repeating: 0x41, count: 30)
        let updateData = Data([0x0A, 0x1E]) + Data(repeating: 0x42, count: 30)
        let original: RoutingResourceRecord
        let profile = "rules:\n  - GEOSITE,cn,DIRECT\n  - MATCH,DIRECT\n"

        var resourceDirectory: URL {
            store.applicationSupportDirectory.appendingPathComponent("RoutingResources")
        }

        init(origin: RoutingResourceOrigin) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RoutingResourceTransactionTests-\(UUID().uuidString)", isDirectory: true
            )
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            store = RoutingResourceStore(applicationSupportDirectory: root.appendingPathComponent("Support"))
            if origin == .bundled {
                original = try store.installBundled(
                    data: originalData, kind: .geoSite, expectedSHA256: Self.digest(originalData)
                )
            } else {
                original = try store.installUserProvided(data: originalData, kind: .geoSite)
            }
        }

        @discardableResult
        func update(fileManager: FileManager) throws -> RoutingResourceRecord {
            try store.installVerified(
                data: updateData, kind: .geoSite, expectedSHA256: Self.digest(updateData),
                fileManager: fileManager, replacing: original
            )
        }

        func assertOriginalIsUsable(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(store.status(for: .geoSite), .ready(original), file: file, line: line)
            XCTAssertEqual(
                try store.launchResourceSnapshot(for: profile)[.geoSite], originalData,
                file: file, line: line
            )
            XCTAssertEqual(try store.prepareRuntimeResources(for: profile), [.geoSite], file: file, line: line)
            XCTAssertEqual(
                try Data(contentsOf: store.applicationSupportDirectory.appendingPathComponent("Runtime/GeoSite.dat")),
                originalData, file: file, line: line
            )
        }

        func assertNoTemporaryFiles(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(
                Set(try FileManager.default.contentsOfDirectory(atPath: resourceDirectory.path)),
                [".commit.lock", "GeoSite.dat", "GeoSite.dat.metadata.json"],
                file: file, line: line
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }

        static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }
}

private final class FailingRoutingResourceAttributesFileManager: FileManager, @unchecked Sendable {
    let failingFileName: String
    private(set) var injectedFailure = false

    init(failingFileName: String) {
        self.failingFileName = failingFileName
        super.init()
    }

    override func setAttributes(_ attributes: [FileAttributeKey: Any], ofItemAtPath path: String) throws {
        if !injectedFailure, URL(fileURLWithPath: path).lastPathComponent == failingFileName {
            injectedFailure = true
            throw POSIXError(.ENOSPC)
        }
        try super.setAttributes(attributes, ofItemAtPath: path)
    }
}

private final class FailingRoutingResourceCommitFileManager: FileManager, @unchecked Sendable {
    enum Fault { case backup, dataMove, metadataMove, verification, rollback, cleanup }
    let fault: Fault
    private(set) var injectedFailure = false

    init(fault: Fault) {
        self.fault = fault
        super.init()
    }

    override func linkItem(at source: URL, to destination: URL) throws {
        if fault == .backup, destination.lastPathComponent == "previous-metadata" {
            injectedFailure = true
            throw POSIXError(.ENOSPC)
        }
        try super.linkItem(at: source, to: destination)
    }

    override func moveItem(at source: URL, to destination: URL) throws {
        if (fault == .dataMove && destination.lastPathComponent == "GeoSite.dat")
            || (fault == .metadataMove && destination.lastPathComponent == "GeoSite.dat.metadata.json") {
            injectedFailure = true
            throw POSIXError(.ENOSPC)
        }
        if fault == .rollback, destination.lastPathComponent == "GeoSite.dat.metadata.json" {
            // A second filesystem failure makes restoring the metadata path
            // impossible. The original backup must survive for recovery.
            try super.createDirectory(at: destination, withIntermediateDirectories: false)
            injectedFailure = true
            throw POSIXError(.ENOSPC)
        }
        try super.moveItem(at: source, to: destination)
        if fault == .verification, destination.lastPathComponent == "GeoSite.dat.metadata.json" {
            let dataURL = destination.deletingLastPathComponent().appendingPathComponent("GeoSite.dat")
            var damaged = try Data(contentsOf: dataURL)
            damaged.append(0x43)
            try damaged.write(to: dataURL, options: [.atomic])
            injectedFailure = true
        }
    }

    override func removeItem(at url: URL) throws {
        if fault == .cleanup, url.lastPathComponent.hasPrefix(".staging-") {
            injectedFailure = true
            throw POSIXError(.EACCES)
        }
        try super.removeItem(at: url)
    }
}

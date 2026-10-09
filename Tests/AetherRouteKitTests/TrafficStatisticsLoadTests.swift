import Foundation
import Security
import XCTest
@testable import AetherRouteKit

/// A saved ledger that cannot be read must never be replaced by an empty
/// one: only a ledger that is lost for good is set aside.
final class TrafficStatisticsLoadTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private var url: URL {
        directory.appendingPathComponent("TrafficStatistics.v1.sealed")
    }

    private var setAsideURL: URL {
        directory.appendingPathComponent(TrafficStatisticsStore.setAsideFileName)
    }

    private func ledger(day: String, upload: UInt64, download: UInt64) -> TrafficStatisticsLedger {
        var ledger = TrafficStatisticsLedger()
        ledger.add(
            TrafficSampleAttribution(
                total: TrafficVolume(upload: upload, download: download),
                apps: ["safari": TrafficVolume(upload: upload, download: download)],
                appNames: ["safari": "Safari"],
                nodes: ["HK": TrafficVolume(upload: upload, download: download)]
            ),
            day: day
        )
        return ledger
    }

    func testMissingLedgerIsReportedAsMissing() {
        let store = TrafficStatisticsStore(fileURL: url, keyStore: InMemoryProfileKeyStore())
        XCTAssertEqual(store.loadResult(), .missing)
    }

    func testSavedLedgerLoads() throws {
        let keys = InMemoryProfileKeyStore()
        let store = TrafficStatisticsStore(fileURL: url, keyStore: keys)
        let saved = ledger(day: "2026-10-01", upload: 1, download: 2)
        try store.save(saved)
        XCTAssertEqual(store.loadResult(), .loaded(saved))
    }

    /// A locked or unavailable Keychain is temporary: the file stays exactly
    /// as it was so a later attempt can still read it.
    func testUnavailableKeychainLeavesTheFileUntouched() throws {
        let keys = InMemoryProfileKeyStore()
        try TrafficStatisticsStore(fileURL: url, keyStore: keys)
            .save(ledger(day: "2026-10-01", upload: 1, download: 2))
        let before = try Data(contentsOf: url)

        let locked = TrafficStatisticsStore(fileURL: url, keyStore: LockedKeyStore())
        XCTAssertEqual(locked.loadResult(), .temporarilyUnavailable)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: setAsideURL.path))
    }

    /// A ledger whose key is gone can never be opened again; it is set aside
    /// rather than silently overwritten, and clearing removes it too.
    func testLedgerWithoutItsKeyIsSetAside() throws {
        try TrafficStatisticsStore(fileURL: url, keyStore: InMemoryProfileKeyStore())
            .save(ledger(day: "2026-10-01", upload: 1, download: 2))
        let before = try Data(contentsOf: url)

        let stranger = TrafficStatisticsStore(fileURL: url, keyStore: InMemoryProfileKeyStore())
        XCTAssertEqual(stranger.loadResult(), .unreadable)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try Data(contentsOf: setAsideURL), before)

        try stranger.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: setAsideURL.path))
    }

    func testDamagedLedgerIsSetAside() throws {
        try Data("not a sealed ledger".utf8).write(to: url)
        let store = TrafficStatisticsStore(fileURL: url, keyStore: InMemoryProfileKeyStore())
        XCTAssertEqual(store.loadResult(), .unreadable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: setAsideURL.path))
    }

    func testMergingAddsDaysInOrderAndKeepsTheRetentionBound() {
        var saved = ledger(day: "2026-10-02", upload: 10, download: 20)
        saved.add(
            TrafficSampleAttribution(total: TrafficVolume(upload: 1, download: 1)),
            day: "2026-10-03"
        )
        let pending = ledger(day: "2026-10-03", upload: 5, download: 5)
            .merging(ledger(day: "2026-10-01", upload: 7, download: 7))

        let merged = saved.merging(pending)
        XCTAssertEqual(merged.days.map(\.day), ["2026-10-01", "2026-10-02", "2026-10-03"])
        XCTAssertEqual(merged.days[2].total, TrafficVolume(upload: 6, download: 6))
        XCTAssertEqual(merged.days[2].apps["safari"], TrafficVolume(upload: 5, download: 5))
        XCTAssertEqual(merged.days[2].appNames["safari"], "Safari")

        var many = TrafficStatisticsLedger()
        for day in 1...TrafficStatisticsLedger.retainedDays {
            many.add(
                TrafficSampleAttribution(total: TrafficVolume(upload: 1, download: 0)),
                day: String(format: "2026-08-%02d", day)
            )
        }
        let bounded = many.merging(ledger(day: "2026-09-01", upload: 1, download: 0))
        XCTAssertEqual(bounded.days.count, TrafficStatisticsLedger.retainedDays)
        XCTAssertEqual(bounded.days.first?.day, "2026-08-02")
        XCTAssertEqual(bounded.days.last?.day, "2026-09-01")
    }
}

/// The Keychain while the login keychain is locked.
private struct LockedKeyStore: ProfileKeyStoring {
    func loadKey(keyID _: String) throws -> Data {
        throw ProfileKeyStoreError.securityError(errSecInteractionNotAllowed)
    }

    func loadOrCreateKey(keyID _: String) throws -> Data {
        throw ProfileKeyStoreError.securityError(errSecInteractionNotAllowed)
    }
}

import Foundation
import XCTest
@testable import AetherRouteKit

final class TrafficStatisticsWriterTests: XCTestCase {
    func testDelayedSaveThenClearCannotResurrectHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStatisticsStore(
            fileURL: directory.appendingPathComponent("ledger.sealed"),
            keyStore: InMemoryProfileKeyStore()
        )
        let started = expectation(description: "save started")
        let release = DispatchSemaphore(value: 0)
        let saved = expectation(description: "save succeeded")
        let cleared = expectation(description: "clear succeeded")
        let writer = TrafficStatisticsWriter(save: { ledger in
            started.fulfill()
            guard release.wait(timeout: .now() + 10) == .success else {
                throw CocoaError(.fileWriteUnknown)
            }
            try store.save(ledger)
        }, clear: { try store.clear() })
        writer.save(ledger(100)) { success in
            XCTAssertTrue(success)
            saved.fulfill()
        }
        await fulfillment(of: [started], timeout: 5)
        XCTAssertTrue(writer.hasPendingOperations)
        writer.clear { success in
            XCTAssertTrue(success)
            cleared.fulfill()
        }
        release.signal()
        await writer.flush()
        await fulfillment(of: [saved, cleared], timeout: 5)
        XCTAssertFalse(writer.hasPendingOperations)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    func testFlushPersistsLatestSnapshotInSubmissionOrder() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = TrafficStatisticsStore(
            fileURL: directory.appendingPathComponent("ledger.sealed"),
            keyStore: InMemoryProfileKeyStore()
        )
        let writer = TrafficStatisticsWriter(save: { try store.save($0) }, clear: { try store.clear() })
        writer.save(ledger(100)) { XCTAssertTrue($0) }
        writer.clear { XCTAssertTrue($0) }
        writer.save(ledger(200)) { XCTAssertTrue($0) }
        await writer.flush()
        XCTAssertEqual(store.load(), ledger(200))
    }

    func testFailedWriteReportsFailureAndAllowsRetry() async {
        let writer = TrafficStatisticsWriter(save: { ledger in
            if ledger.days.isEmpty { throw CocoaError(.fileWriteUnknown) }
        })
        let failed = expectation(description: "failure reported")
        let retried = expectation(description: "retry succeeded")
        writer.save(TrafficStatisticsLedger()) { success in
            XCTAssertFalse(success)
            failed.fulfill()
        }
        writer.save(ledger(1)) { success in
            XCTAssertTrue(success)
            retried.fulfill()
        }
        await writer.flush()
        await fulfillment(of: [failed, retried], timeout: 5)
    }

    private func ledger(_ bytes: UInt64) -> TrafficStatisticsLedger {
        var ledger = TrafficStatisticsLedger()
        ledger.add(.init(total: .init(upload: bytes)), day: "2026-10-08")
        return ledger
    }
}

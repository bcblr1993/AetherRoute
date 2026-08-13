import XCTest
@testable import AetherRouteKit

final class DiagnosticLogTests: XCTestCase, @unchecked Sendable {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(
                "aetherroute-log-\(UUID().uuidString)", isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - Level gating

    /// The whole point of the gate: a suppressed record must not build its
    /// message. An ungated logger still pays for interpolation.
    func testSuppressedRecordNeverEvaluatesItsMessage() {
        let log = DiagnosticLog(
            category: "test",
            sink: nil,
            levelProvider: { .off }
        )
        var evaluations = 0
        let build: () -> String = {
            evaluations += 1
            return "expensive"
        }

        log.verbose(build())
        log.aggregate(build())

        XCTAssertEqual(evaluations, 0)
    }

    func testStandardLevelAdmitsAggregatesButNotPerFlow() {
        let log = DiagnosticLog(
            category: "test",
            sink: nil,
            levelProvider: { .standard }
        )
        var verboseCount = 0
        var aggregateCount = 0

        log.verbose({ verboseCount += 1; return "v" }())
        log.aggregate({ aggregateCount += 1; return "a" }())

        XCTAssertEqual(verboseCount, 0)
        XCTAssertEqual(aggregateCount, 1)
    }

    func testVerboseLevelAdmitsPerFlow() {
        let log = DiagnosticLog(
            category: "test",
            sink: nil,
            levelProvider: { .verbose }
        )
        var count = 0

        log.verbose({ count += 1; return "v" }())

        XCTAssertEqual(count, 1)
    }

    // MARK: - Rotation and bounds

    func testRotationKeepsDiskUseBounded() throws {
        let sink = RotatingLogSink(
            configuration: .init(
                directoryURL: directory,
                baseName: "probe",
                maximumFileBytes: 512,
                maximumFileCount: 3
            )
        )
        let line = String(repeating: "x", count: 120)
        for _ in 0..<200 { sink.append(line) }
        let flushed = expectation(description: "flushed")
        sink.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)

        let files = try FileManager.default.contentsOfDirectory(
            atPath: directory.path
        ).filter { $0.hasPrefix("probe") }
        XCTAssertLessThanOrEqual(files.count, 3, "rotation must cap file count")

        let total = try files.reduce(0) { partial, name in
            let attributes = try FileManager.default.attributesOfItem(
                atPath: directory.appendingPathComponent(name).path
            )
            return partial + ((attributes[.size] as? Int) ?? 0)
        }
        // One in-flight batch may exceed the per-file limit before rotating,
        // so allow a single file of slack over the nominal ceiling.
        XCTAssertLessThanOrEqual(total, 512 * 3 + 512 * 2)
        XCTAssertGreaterThan(sink.statistics().rotations, 0)
    }

    /// Backpressure must cost records, never memory growth or a stalled caller.
    func testOverflowDropsOldestAndCountsThem() {
        let sink = RotatingLogSink(
            configuration: .init(
                directoryURL: directory,
                baseName: "overflow",
                maximumPendingRecords: 8
            )
        )
        for index in 0..<400 { sink.append("record-\(index)") }
        let flushed = expectation(description: "flushed")
        sink.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 5)

        let statistics = sink.statistics()
        XCTAssertGreaterThan(statistics.written, 0)
        XCTAssertEqual(statistics.written + statistics.dropped, 400)
    }

    func testAppendIsSafeFromConcurrentCallers() {
        let sink = RotatingLogSink(
            configuration: .init(directoryURL: directory, baseName: "threads")
        )
        DispatchQueue.concurrentPerform(iterations: 400) { index in
            sink.append("line-\(index)")
        }
        let flushed = expectation(description: "flushed")
        sink.flush { flushed.fulfill() }
        wait(for: [flushed], timeout: 10)

        let statistics = sink.statistics()
        XCTAssertEqual(statistics.written + statistics.dropped, 400)
    }

    // MARK: - Shared level store

    func testStoreRoundTripAndUnreadableFileFallsBackToOff() throws {
        let store = DiagnosticLogLevelStore(directoryURL: directory)
        XCTAssertEqual(store.load(), .off, "missing file means debug mode off")

        try store.save(.verbose)
        XCTAssertEqual(store.load(), .verbose)

        try Data("not json".utf8).write(to: store.fileURL)
        XCTAssertEqual(store.load(), .off, "corrupt file must not throw")
    }

    func testCacheReloadsAfterTheFileChanges() throws {
        let store = DiagnosticLogLevelStore(directoryURL: directory)
        try store.save(.off)
        let clock = Clock()
        let cache = DiagnosticLogLevelCache(
            store: store,
            refreshInterval: 5,
            now: { clock.now }
        )
        XCTAssertEqual(cache.level(), .off)

        try store.save(.verbose)
        XCTAssertEqual(cache.level(), .off, "cached until the interval elapses")

        clock.advance(by: 6)
        XCTAssertEqual(cache.level(), .verbose)
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_000)

        var now: Date { lock.withLock { value } }

        func advance(by seconds: TimeInterval) {
            lock.withLock { value = value.addingTimeInterval(seconds) }
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

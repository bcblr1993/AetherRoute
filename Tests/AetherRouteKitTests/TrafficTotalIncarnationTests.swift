import XCTest
@testable import AetherRouteKit

/// `ART4` totals: the engine forgets idle (app, chain) pairs past its bound
/// and a pair seen again restarts from zero under a new incarnation.
final class TrafficTotalIncarnationTests: XCTestCase {
    private func key(_ identifier: String, _ path: String) -> TrafficStatisticsAccumulator.AppKey {
        .init(key: identifier, name: identifier)
    }

    private func total(
        _ app: String,
        _ incarnation: UInt64,
        download: UInt64,
        upload: UInt64 = 0
    ) -> TrafficTotalTelemetry {
        TrafficTotalTelemetry(
            sourceAppIdentifier: app,
            sourceAppPath: "/x",
            proxyChain: "Auto → HK",
            uploadTotal: upload,
            downloadTotal: download,
            incarnation: incarnation
        )
    }

    private func sample(
        download: UInt64,
        watermark: UInt64,
        _ totals: [TrafficTotalTelemetry]
    ) -> NetworkTelemetrySnapshot {
        NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: download,
            memoryBytes: 0,
            connections: [],
            trafficTotals: totals,
            trafficTotalWatermark: watermark
        )
    }

    func testForgottenPairReturningSmallerIsCountedFromZero() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(sample(download: 0, watermark: 1, []), appKey: key)
        let first = accumulator.ingest(
            sample(download: 500, watermark: 2, [total("com.a", 1, download: 500)]),
            appKey: key
        )
        XCTAssertEqual(first.apps["com.a"], TrafficVolume(upload: 0, download: 500))

        // Forgotten, then back from zero: 30 < 500 must not be lost.
        let back = accumulator.ingest(
            sample(download: 530, watermark: 9, [total("com.a", 8, download: 30)]),
            appKey: key
        )
        XCTAssertEqual(back.apps["com.a"], TrafficVolume(upload: 0, download: 30))
        XCTAssertEqual(back.nodes["HK"], TrafficVolume(upload: 0, download: 30))

        // Growth within the new incarnation is differenced against it.
        let grown = accumulator.ingest(
            sample(download: 540, watermark: 9, [total("com.a", 8, download: 40)]),
            appKey: key
        )
        XCTAssertEqual(grown.apps["com.a"], TrafficVolume(upload: 0, download: 10))
    }

    func testForgottenPairReturningLargerIsNotReducedByTheOldValue() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(sample(download: 0, watermark: 1, []), appKey: key)
        _ = accumulator.ingest(
            sample(download: 100, watermark: 2, [total("com.a", 1, download: 100)]),
            appKey: key
        )
        let back = accumulator.ingest(
            sample(download: 400, watermark: 4, [total("com.a", 3, download: 300)]),
            appKey: key
        )
        XCTAssertEqual(back.apps["com.a"], TrafficVolume(upload: 0, download: 300))
    }

    func testTotalsLeftOutOfASampleAreNotCountedTwice() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(sample(download: 0, watermark: 1, []), appKey: key)
        _ = accumulator.ingest(
            sample(download: 50, watermark: 2, [total("com.a", 1, download: 50)]),
            appKey: key
        )
        // Crowded out of one sample by more recently changed pairs.
        let crowded = accumulator.ingest(
            sample(download: 60, watermark: 3, [total("com.b", 2, download: 10)]),
            appKey: key
        )
        XCTAssertNil(crowded.apps["com.a"])
        let again = accumulator.ingest(
            sample(download: 65, watermark: 3, [
                total("com.a", 1, download: 55),
                total("com.b", 2, download: 10),
            ]),
            appKey: key
        )
        XCTAssertEqual(again.apps, ["com.a": TrafficVolume(upload: 0, download: 5)])
    }

    func testAnOlderIncarnationNeverCountsAgain() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(sample(download: 0, watermark: 1, []), appKey: key)
        _ = accumulator.ingest(
            sample(download: 20, watermark: 6, [total("com.a", 5, download: 20)]),
            appKey: key
        )
        let stale = accumulator.ingest(
            sample(download: 20, watermark: 6, [total("com.a", 2, download: 900)]),
            appKey: key
        )
        XCTAssertTrue(stale.apps.isEmpty)
        let current = accumulator.ingest(
            sample(download: 21, watermark: 6, [total("com.a", 5, download: 21)]),
            appKey: key
        )
        XCTAssertEqual(current.apps["com.a"], TrafficVolume(upload: 0, download: 1))
    }

    func testHostStartingMidSessionOnlyBaselinesPairsItNeverSaw() {
        var accumulator = TrafficStatisticsAccumulator()
        // The app relaunches while the engine keeps running: incarnations
        // 1 through 9 already exist, and the first sample shows only one.
        _ = accumulator.ingest(
            sample(download: 10_000, watermark: 10, [total("com.seen", 9, download: 100)]),
            appKey: key
        )
        let later = accumulator.ingest(
            sample(download: 10_015, watermark: 11, [
                // Old pair with bytes from before the relaunch.
                total("com.old", 3, download: 9_000),
                // Pair created after the baseline: all of it is new.
                total("com.new", 10, download: 5),
                total("com.seen", 9, download: 110),
            ]),
            appKey: key
        )
        XCTAssertNil(later.apps["com.old"])
        XCTAssertEqual(later.apps["com.new"], TrafficVolume(upload: 0, download: 5))
        XCTAssertEqual(later.apps["com.seen"], TrafficVolume(upload: 0, download: 10))

        let grown = accumulator.ingest(
            sample(download: 10_016, watermark: 11, [total("com.old", 3, download: 9_001)]),
            appKey: key
        )
        XCTAssertEqual(grown.apps["com.old"], TrafficVolume(upload: 0, download: 1))
    }

    func testEngineRestartCountsEveryNewTotalWhateverItsIncarnation() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(
            sample(download: 1_000, watermark: 50, [total("com.a", 40, download: 1_000)]),
            appKey: key
        )
        let restarted = accumulator.ingest(
            sample(download: 7, watermark: 2, [total("com.a", 1, download: 7)]),
            appKey: key
        )
        XCTAssertEqual(restarted.total, TrafficVolume(upload: 0, download: 7))
        XCTAssertEqual(restarted.apps["com.a"], TrafficVolume(upload: 0, download: 7))
    }

    func testAttributedBytesMatchTheTotalAcrossManyForgottenPairs() {
        // A long session: 3,000 short-lived apps, each sample carrying only
        // the pairs that changed, and every pair forgotten after it closed.
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(sample(download: 0, watermark: 1, []), appKey: key)
        var engineTotal: UInt64 = 0
        var attributed: UInt64 = 0
        for index in 0..<3_000 {
            let app = "app.\(index % 400)"
            let bytes = UInt64(index % 7 + 1)
            engineTotal += bytes
            let incarnation = UInt64(index + 1)
            let attribution = accumulator.ingest(
                sample(
                    download: engineTotal,
                    watermark: incarnation + 1,
                    [total(app, incarnation, download: bytes)]
                ),
                appKey: key
            )
            attributed += attribution.apps.values.reduce(0) { $0 + $1.download }
        }
        XCTAssertEqual(attributed, engineTotal)
    }

    func testART3TotalsKeepTheirPreviousBehaviour() {
        var accumulator = TrafficStatisticsAccumulator()
        let art3 = { (download: UInt64, value: UInt64) in
            NetworkTelemetrySnapshot(
                uploadBytesPerSecond: 0,
                downloadBytesPerSecond: 0,
                uploadTotal: 0,
                downloadTotal: download,
                memoryBytes: 0,
                connections: [],
                trafficTotals: [TrafficTotalTelemetry(
                    sourceAppIdentifier: "com.a",
                    sourceAppPath: "/x",
                    proxyChain: "",
                    uploadTotal: 0,
                    downloadTotal: value
                )],
                reportsTrafficTotals: true
            )
        }
        _ = accumulator.ingest(art3(10, 10), appKey: key)
        XCTAssertEqual(
            accumulator.ingest(art3(15, 15), appKey: key).apps["com.a"],
            TrafficVolume(upload: 0, download: 5)
        )
        // Without incarnations a shrunken total only counts once it grows
        // past its old value.
        XCTAssertNil(accumulator.ingest(art3(20, 3), appKey: key).apps["com.a"])
    }
}

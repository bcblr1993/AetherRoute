@testable import AetherRouteKit
import Foundation
import XCTest

/// Wire formats and pure policies behind the 1.4 features: closing
/// connections, reading provider logs, and local traffic statistics.
final class ConnectionCloseRequestCodecTests: XCTestCase {
    func testEncodesEveryKindInTheEngineFormat() throws {
        XCTAssertEqual(
            [UInt8](try ConnectionCloseRequestCodec.encode(.all)),
            [0x41, 0x52, 0x43, 0x31, 0]
        )
        XCTAssertEqual(
            [UInt8](try ConnectionCloseRequestCodec.encode(.proxyChainMember("A"))),
            [0x41, 0x52, 0x43, 0x31, 3, 0, 1, 0x41]
        )
        XCTAssertEqual(
            [UInt8](try ConnectionCloseRequestCodec.encode(
                .sourceApp(signingIdentifier: "", executablePath: "/b")
            )),
            [0x41, 0x52, 0x43, 0x31, 1, 0, 0, 0, 2, 0x2f, 0x62]
        )
        let row = [UInt8](try ConnectionCloseRequestCodec.encode(
            .connection(
                transport: .udp,
                destination: "a",
                port: 443,
                startedAtUnixMilliseconds: 258
            )
        ))
        XCTAssertEqual(
            row,
            [0x41, 0x52, 0x43, 0x31, 2, 2, 0, 1, 0x61, 0x01, 0xbb,
             0, 0, 0, 0, 0, 0, 0x01, 0x02]
        )
    }

    func testValidationAcceptsEncodedRequestsAndRejectsMalformedOnes() throws {
        for request: ConnectionCloseRequest in [
            .all,
            .sourceApp(signingIdentifier: "com.example", executablePath: ""),
            .connection(transport: .tcp, destination: "x", port: 1, startedAtUnixMilliseconds: 0),
            .proxyChainMember("Auto"),
        ] {
            XCTAssertTrue(
                ConnectionCloseRequestCodec.isValid(try ConnectionCloseRequestCodec.encode(request))
            )
        }
        for bytes: [UInt8] in [
            [0x41, 0x52, 0x43, 0x32, 0],
            [0x41, 0x52, 0x43, 0x31, 9],
            [0x41, 0x52, 0x43, 0x31, 0, 0],
            [0x41, 0x52, 0x43, 0x31, 3, 0, 0],
            [0x41, 0x52, 0x43, 0x31, 2, 7, 0, 1, 0x61],
        ] {
            XCTAssertFalse(ConnectionCloseRequestCodec.isValid(Data(bytes)), "\(bytes)")
        }
        XCTAssertThrowsError(try ConnectionCloseRequestCodec.encode(.proxyChainMember("")))
    }

    func testProviderMessagesRoundTrip() throws {
        let close = try ConnectionCloseRequestCodec.encode(.proxyChainMember("Auto"))
        for request: ProxySelectionProviderRequest in [
            .closeConnections(close),
            .recentLog(maximumKilobytes: 256),
            .closeConnections(try ConnectionCloseRequestCodec.encode(.sourceApps([
                ConnectionCloseApp(signingIdentifier: "com.a", executablePath: ""),
                ConnectionCloseApp(signingIdentifier: "", executablePath: "/b"),
            ]))),
        ] + DiagnosticLogLevel.allCases.map(ProxySelectionProviderRequest.setDiagnosticLogLevel) {
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(
                    ProxySelectionProviderMessageCodec.encode(request: request)
                ),
                request
            )
        }
        for response: ProxySelectionProviderResponse in [
            .connectionsClosed(3),
            .recentLog(Data("line\n".utf8)),
            .recentLog(Data()),
            .diagnosticLogLevelApplied,
        ] {
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeResponse(
                    ProxySelectionProviderMessageCodec.encode(response: response)
                ),
                response
            )
        }
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.encode(request: .closeConnections(Data([1, 2])))
        )
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.encode(request: .recentLog(maximumKilobytes: 0))
        )
        XCTAssertEqual(
            ProviderMessageClass(.closeConnections(close)),
            .control
        )
        XCTAssertEqual(ProviderMessageClass(.setDiagnosticLogLevel(.verbose)), .control)
        // Operation 12 with an unknown level is rejected.
        var unknownLevel = [UInt8](try ProxySelectionProviderMessageCodec.encode(
            request: .setDiagnosticLogLevel(.verbose)
        ))
        unknownLevel[5] = 9
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.decodeRequest(Data(unknownLevel))
        )
    }

    func testSourceAppsEncodesInTheEngineLayoutAndBatchesToTheBound() throws {
        XCTAssertEqual(
            [UInt8](try ConnectionCloseRequestCodec.encode(.sourceApps([
                ConnectionCloseApp(signingIdentifier: "a", executablePath: ""),
                ConnectionCloseApp(signingIdentifier: "", executablePath: "/b"),
            ]))),
            [0x41, 0x52, 0x43, 0x31, 4, 0, 2, 0, 1, 0x61, 0, 0, 0, 0, 0, 2, 0x2f, 0x62]
        )
        XCTAssertThrowsError(try ConnectionCloseRequestCodec.encode(.sourceApps([])))
        XCTAssertFalse(ConnectionCloseRequestCodec.isValid(Data([0x41, 0x52, 0x43, 0x31, 4, 0, 0])))

        let one = ConnectionCloseApp(signingIdentifier: "com.a", executablePath: "/a")
        XCTAssertEqual(
            ConnectionCloseRequest.closing(apps: [one, one]),
            [.sourceApp(signingIdentifier: "com.a", executablePath: "/a")]
        )
        let long = (0..<10).map {
            ConnectionCloseApp(
                signingIdentifier: "com.example.\($0)",
                executablePath: String(repeating: "p", count: 500)
            )
        }
        let batches = ConnectionCloseRequest.closing(apps: long)
        XCTAssertGreaterThan(batches.count, 1)
        var named = 0
        for batch in batches {
            let data = try ConnectionCloseRequestCodec.encode(batch)
            XCTAssertLessThanOrEqual(data.count, ConnectionCloseRequestCodec.maximumBytes)
            XCTAssertTrue(ConnectionCloseRequestCodec.isValid(data))
            if case let .sourceApps(apps) = batch { named += apps.count }
        }
        XCTAssertEqual(named, long.count)
    }
}

final class DiagnosticLogLineTests: XCTestCase {
    func testMultilineRecordsRemainTogetherWhenMergedChronologically() {
        let app = DiagnosticLogLine.parse(
            "2026-10-08T03:00:00.000Z E [test] late\ncontinuation",
            process: "app"
        )
        let tunnel = DiagnosticLogLine.parse(
            "2026-10-08T01:00:00.000Z E [test] early",
            process: "tunnel", firstID: 2
        )
        XCTAssertEqual(DiagnosticLogLine.merged([app, tunnel]).map(\.message),
                       ["early", "late", "continuation"])
    }

    func testParsesMarkersAndKeepsUnformattedLines() {
        let text = """
        2026-10-08T01:02:03.004Z E [tunnel] start failed
        2026-10-08T01:02:04.000Z A [flow] admitted=3
        continuation without a header
        """
        let lines = DiagnosticLogLine.parse(text, process: "tunnel", firstID: 10)
        XCTAssertEqual(lines.map(\.kind), [.error, .aggregate, .other])
        XCTAssertEqual(lines.map(\.id), [10, 11, 12])
        XCTAssertEqual(lines[0].category, "tunnel")
        XCTAssertEqual(lines[0].message, "start failed")
        XCTAssertEqual(lines[0].rawText, "2026-10-08T01:02:03.004Z E [tunnel] start failed")
        XCTAssertEqual(lines[2].message, "continuation without a header")
    }

    func testMergesProcessesInTimeOrder() {
        let app = DiagnosticLogLine.parse(
            "2026-10-08T01:00:02.000Z L [app] b",
            process: "app"
        )
        let tunnel = DiagnosticLogLine.parse(
            "2026-10-08T01:00:01.000Z L [core] a\n2026-10-08T01:00:03.000Z L [core] c",
            process: "tunnel",
            firstID: 1
        )
        XCTAssertEqual(
            DiagnosticLogLine.merged([app, tunnel]).map(\.message),
            ["a", "b", "c"]
        )
    }

    func testRotatingSinkTailStartsAtALineBoundary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "app"))
        try Data("first line\nsecond line\nthird\n".utf8).write(to: sink.currentFileURL)
        XCTAssertEqual(sink.tail(maximumBytes: 14), "third\n")
        XCTAssertEqual(sink.tail(maximumBytes: 1_000), "first line\nsecond line\nthird\n")
        XCTAssertEqual(sink.tail(maximumBytes: 0), "")
    }

    func testTailReadsAcrossRotationAndDiscardsOversizedPartialRecord() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sink = RotatingLogSink(configuration: .init(directoryURL: directory, baseName: "app"))
        try Data((String(repeating: "x", count: 1_048_576) + "\nprevious\n").utf8)
            .write(to: directory.appendingPathComponent("app.1.log"))
        try Data("current\n".utf8).write(to: sink.currentFileURL)
        XCTAssertEqual(sink.tail(maximumBytes: 20), "previous\ncurrent\n")
        XCTAssertEqual(sink.tail(maximumBytes: 3), "")
    }
}

final class TrafficStatisticsTests: XCTestCase {
    private func connection(
        _ destination: String,
        upload: UInt64,
        download: UInt64,
        chain: String = "Auto → HK 01",
        app: String = "com.example.app"
    ) -> ConnectionTelemetry {
        ConnectionTelemetry(
            transport: .tcp,
            destination: destination,
            destinationPort: 443,
            uploadTotal: upload,
            downloadTotal: download,
            startedAtUnixMilliseconds: 1,
            rule: "Match",
            rulePayload: "",
            proxyChain: chain,
            sourceAppIdentifier: app,
            sourceAppPath: ""
        )
    }

    private func snapshot(
        upload: UInt64,
        download: UInt64,
        _ connections: [ConnectionTelemetry]
    ) -> NetworkTelemetrySnapshot {
        NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: upload,
            downloadTotal: download,
            memoryBytes: 0,
            connections: connections
        )
    }

    private func key(_ identifier: String, _ path: String) -> TrafficStatisticsAccumulator.AppKey {
        .init(key: identifier, name: "Example")
    }

    private func total(
        _ app: String,
        chain: String,
        upload: UInt64,
        download: UInt64
    ) -> TrafficTotalTelemetry {
        TrafficTotalTelemetry(
            sourceAppIdentifier: app,
            sourceAppPath: "",
            proxyChain: chain,
            uploadTotal: upload,
            downloadTotal: download
        )
    }

    private func totalsSnapshot(
        upload: UInt64,
        download: UInt64,
        _ totals: [TrafficTotalTelemetry]
    ) -> NetworkTelemetrySnapshot {
        NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: upload,
            downloadTotal: download,
            memoryBytes: 0,
            connections: [],
            trafficTotals: totals,
            reportsTrafficTotals: true
        )
    }

    func testEngineTotalsSplitEveryConnectionExactly() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(
            totalsSnapshot(upload: 10, download: 20, [
                total("com.a", chain: "Auto → HK", upload: 10, download: 20),
            ]),
            appKey: key
        )
        // com.a grew by 5/10; com.b appeared (all of it is new); a total
        // missing from this sample keeps its last value.
        let second = accumulator.ingest(
            totalsSnapshot(upload: 20, download: 40, [
                total("com.a", chain: "Auto → HK", upload: 15, download: 30),
                total("com.b", chain: "", upload: 5, download: 10),
            ]),
            appKey: key
        )
        XCTAssertEqual(second.total, TrafficVolume(upload: 10, download: 20))
        XCTAssertEqual(second.apps["com.a"], TrafficVolume(upload: 5, download: 10))
        XCTAssertEqual(second.apps["com.b"], TrafficVolume(upload: 5, download: 10))
        XCTAssertEqual(second.nodes["HK"], TrafficVolume(upload: 5, download: 10))
        XCTAssertEqual(second.nodes["DIRECT"], TrafficVolume(upload: 5, download: 10))

        let third = accumulator.ingest(
            totalsSnapshot(upload: 21, download: 40, [
                total("com.b", chain: "", upload: 6, download: 10),
            ]),
            appKey: key
        )
        XCTAssertEqual(third.apps, ["com.b": TrafficVolume(upload: 1, download: 0)])
        let fourth = accumulator.ingest(
            totalsSnapshot(upload: 22, download: 40, [
                total("com.a", chain: "Auto → HK", upload: 16, download: 30),
            ]),
            appKey: key
        )
        XCTAssertEqual(fourth.apps, ["com.a": TrafficVolume(upload: 1, download: 0)])
    }

    func testEngineRestartStartsTotalsOver() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(
            totalsSnapshot(upload: 100, download: 100, [
                total("com.a", chain: "", upload: 100, download: 100),
            ]),
            appKey: key
        )
        let sample = accumulator.ingest(
            totalsSnapshot(upload: 3, download: 4, [
                total("com.a", chain: "", upload: 3, download: 4),
            ]),
            appKey: key
        )
        XCTAssertEqual(sample.total, TrafficVolume(upload: 3, download: 4))
        XCTAssertEqual(sample.apps["com.a"], TrafficVolume(upload: 3, download: 4))
    }

    func testNewSessionCountsAllBytesEvenWhenItsCountersExceedPreviousSession() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(
            totalsSnapshot(upload: 100, download: 100, [
                total("com.a", chain: "", upload: 100, download: 100),
            ]), sessionStartedAt: Date(timeIntervalSince1970: 1), appKey: key
        )
        let sample = accumulator.ingest(
            totalsSnapshot(upload: 150, download: 180, [
                total("com.a", chain: "", upload: 150, download: 180),
            ]), sessionStartedAt: Date(timeIntervalSince1970: 2), appKey: key
        )
        XCTAssertEqual(sample.total, TrafficVolume(upload: 150, download: 180))
        XCTAssertEqual(sample.apps["com.a"], sample.total)
    }

    func testSameSessionPreservesBaselineAcrossPollingGaps() {
        var accumulator = TrafficStatisticsAccumulator()
        let started = Date(timeIntervalSince1970: 1)
        _ = accumulator.ingest(
            totalsSnapshot(upload: 100, download: 100, []),
            sessionStartedAt: started, appKey: key
        )
        let sample = accumulator.ingest(
            totalsSnapshot(upload: 150, download: 180, []),
            sessionStartedAt: started, appKey: key
        )
        XCTAssertEqual(sample.total, TrafficVolume(upload: 50, download: 80))
    }

    func testFirstSampleOnlySetsTheBaseline() {
        var accumulator = TrafficStatisticsAccumulator()
        let sample = accumulator.ingest(
            snapshot(upload: 100, download: 200, [connection("a", upload: 10, download: 20)]),
            appKey: key
        )
        XCTAssertTrue(sample.isEmpty)
    }

    func testCountsGrowthByAppAndExitNode() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(
            snapshot(upload: 100, download: 200, [connection("a", upload: 10, download: 20)]),
            appKey: key
        )
        let sample = accumulator.ingest(
            snapshot(upload: 150, download: 500, [
                connection("a", upload: 30, download: 120),
                connection("b", upload: 5, download: 5, chain: "DIRECT", app: "com.other"),
            ]),
            appKey: key
        )
        XCTAssertEqual(sample.total, TrafficVolume(upload: 50, download: 300))
        XCTAssertEqual(sample.apps["com.example.app"], TrafficVolume(upload: 20, download: 100))
        XCTAssertEqual(sample.apps["com.other"], TrafficVolume(upload: 5, download: 5))
        XCTAssertEqual(sample.nodes["HK 01"], TrafficVolume(upload: 20, download: 100))
        XCTAssertEqual(sample.nodes["DIRECT"], TrafficVolume(upload: 5, download: 5))
    }

    func testEngineRestartCountsItsNewTotals() {
        var accumulator = TrafficStatisticsAccumulator()
        _ = accumulator.ingest(snapshot(upload: 1_000, download: 1_000, []), appKey: key)
        let sample = accumulator.ingest(snapshot(upload: 40, download: 60, []), appKey: key)
        XCTAssertEqual(sample.total, TrafficVolume(upload: 40, download: 60))
    }

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ day: Int, month: Int = 9) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
    }

    private func sample() -> TrafficSampleAttribution {
        TrafficSampleAttribution(
            total: TrafficVolume(upload: 1, download: 2),
            apps: ["app": TrafficVolume(upload: 1, download: 0)],
            appNames: ["app": "App"],
            nodes: ["HK": TrafficVolume(upload: 0, download: 2)]
        )
    }

    func testLedgerKeepsBoundedDaysAndSums() {
        var ledger = TrafficStatisticsLedger()
        for offset in 0..<40 {
            let day = utc.date(byAdding: .day, value: offset, to: date(1))!
            ledger.add(sample(), day: TrafficStatisticsLedger.dayKey(for: day, calendar: utc))
        }
        XCTAssertEqual(ledger.days.count, TrafficStatisticsLedger.retainedDays)
        let lastDay = utc.date(byAdding: .day, value: 39, to: date(1))!
        let week = ledger.summary(lastDays: 7, endingAt: lastDay, calendar: utc)
        XCTAssertEqual(week.total, TrafficVolume(upload: 7, download: 14))
        XCTAssertEqual(week.apps["app"], TrafficVolume(upload: 7, download: 0))
        XCTAssertEqual(week.appNames["app"], "App")
        XCTAssertEqual(week.nodes["HK"], TrafficVolume(upload: 0, download: 14))
    }

    func testSummaryCountsCalendarDaysNotRecordedDays() {
        var ledger = TrafficStatisticsLedger()
        ledger.add(sample(), day: "2026-09-01")
        ledger.add(sample(), day: "2026-09-05")
        // Nothing moved on the 10th yet: today is empty, the week only has
        // the 5th, and the month has both.
        XCTAssertEqual(ledger.summary(lastDays: 1, endingAt: date(10), calendar: utc).total, TrafficVolume())
        XCTAssertEqual(
            ledger.summary(lastDays: 7, endingAt: date(10), calendar: utc).total,
            TrafficVolume(upload: 1, download: 2)
        )
        XCTAssertEqual(
            ledger.summary(lastDays: 30, endingAt: date(10), calendar: utc).total,
            TrafficVolume(upload: 2, download: 4)
        )
        XCTAssertEqual(ledger.summary(lastDays: 0, endingAt: date(10), calendar: utc).total, TrafficVolume())
    }

    func testStoreSealsTheLedgerAndOpensItOnlyWithItsKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("TrafficStatistics.v1.sealed")
        let keys = InMemoryProfileKeyStore()
        let store = TrafficStatisticsStore(fileURL: url, keyStore: keys)
        var ledger = TrafficStatisticsLedger()
        ledger.add(sample(), day: "2026-09-01")

        try store.save(ledger)
        XCTAssertEqual(store.load(), ledger)
        let onDisk = try Data(contentsOf: url)
        XCTAssertNil(onDisk.range(of: Data("2026-09-01".utf8)))
        XCTAssertNil(onDisk.range(of: Data("HK".utf8)))

        // Without the key the ledger reads as empty instead of failing.
        let stranger = TrafficStatisticsStore(fileURL: url, keyStore: InMemoryProfileKeyStore())
        XCTAssertEqual(stranger.load(), TrafficStatisticsLedger())

        try store.clear()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(store.load(), TrafficStatisticsLedger())
    }

    func testExitIsTheLastHop() {
        XCTAssertEqual(TrafficStatisticsAccumulator.exit(of: connection("a", upload: 0, download: 0)), "HK 01")
        XCTAssertEqual(
            TrafficStatisticsAccumulator.exit(of: connection("a", upload: 0, download: 0, chain: "")),
            "DIRECT"
        )
    }
}

final class ShareLinkNodesTests: XCTestCase {
    func testRejectsTextWithoutLinks() {
        XCTAssertThrowsError(try SubscriptionPayloadNormalizer.nodes(fromShareText: "hello"))
        XCTAssertThrowsError(try SubscriptionPayloadNormalizer.nodes(fromShareText: "   "))
    }
}

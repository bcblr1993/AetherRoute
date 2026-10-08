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
        ] {
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
    }
}

final class DiagnosticLogLineTests: XCTestCase {
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

    private func key(_ connection: ConnectionTelemetry) -> TrafficStatisticsAccumulator.AppKey {
        .init(key: connection.sourceAppIdentifier, name: "Example")
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

    func testLedgerKeepsBoundedDaysAndSums() {
        var ledger = TrafficStatisticsLedger()
        for day in 1...40 {
            ledger.add(
                TrafficSampleAttribution(
                    total: TrafficVolume(upload: 1, download: 2),
                    apps: ["app": TrafficVolume(upload: 1, download: 0)],
                    appNames: ["app": "App"],
                    nodes: ["HK": TrafficVolume(upload: 0, download: 2)]
                ),
                day: String(format: "2026-09-%02d", day)
            )
        }
        XCTAssertEqual(ledger.days.count, TrafficStatisticsLedger.retainedDays)
        let week = ledger.summary(lastDays: 7)
        XCTAssertEqual(week.total, TrafficVolume(upload: 7, download: 14))
        XCTAssertEqual(week.apps["app"], TrafficVolume(upload: 7, download: 0))
        XCTAssertEqual(week.appNames["app"], "App")
        XCTAssertEqual(week.nodes["HK"], TrafficVolume(upload: 0, download: 14))
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

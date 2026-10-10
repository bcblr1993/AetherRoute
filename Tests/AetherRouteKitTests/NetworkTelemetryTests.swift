@testable import AetherRouteKit
import Foundation
import XCTest

final class NetworkTelemetryTests: XCTestCase {
    func testART1RoundTripsBoundedConnectionSnapshot() throws {
        let snapshot = sampleTelemetry()
        let data = try NetworkTelemetryCodec.encode(snapshot, version: .v1)
        XCTAssertEqual(Array(data.prefix(4)), [0x41, 0x52, 0x54, 0x31])
        XCTAssertLessThanOrEqual(data.count, NetworkTelemetryCodec.maximumMessageBytes)
        XCTAssertEqual(try NetworkTelemetryCodec.decode(data), snapshot)
    }

    func testART1DropsTheSourceAppAndART2KeepsIt() throws {
        let snapshot = sampleTelemetry(
            sourceAppIdentifier: "com.google.Chrome",
            sourceAppPath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        )
        let v2 = try NetworkTelemetryCodec.encode(snapshot)
        XCTAssertEqual(Array(v2.prefix(4)), [0x41, 0x52, 0x54, 0x32])
        XCTAssertEqual(try NetworkTelemetryCodec.decode(v2), snapshot)

        let v1 = try NetworkTelemetryCodec.decode(
            NetworkTelemetryCodec.encode(snapshot, version: .v1)
        )
        XCTAssertEqual(v1.connections[0].sourceAppIdentifier, "")
        XCTAssertEqual(v1.connections[0].sourceAppPath, "")
        XCTAssertEqual(v1, sampleTelemetry())
    }

    func testART2MatchesTheEngineLayout() throws {
        // Mirrors clash-ffi's telemetry_v2_appends_the_bounded_source_app:
        // the record header grows by two u32 lengths and the two strings
        // follow the proxy chain.
        let snapshot = sampleTelemetry(sourceAppIdentifier: "id", sourceAppPath: "/p")
        let data = [UInt8](try NetworkTelemetryCodec.encode(snapshot))
        XCTAssertEqual(Array(data[92..<96]), [0, 0, 0, 2])
        XCTAssertEqual(Array(data[96..<100]), [0, 0, 0, 2])
        XCTAssertEqual(Array(data.suffix(4)), Array("id/p".utf8))
    }

    func testART2RejectsAnOversizedOrMalformedSourceApp() throws {
        let long = String(
            repeating: "a",
            count: NetworkTelemetryCodec.maximumSourceAppBytes + 1
        )
        XCTAssertThrowsError(try NetworkTelemetryCodec.encode(
            sampleTelemetry(sourceAppIdentifier: long)
        ))

        var truncated = try NetworkTelemetryCodec.encode(
            sampleTelemetry(sourceAppIdentifier: "id", sourceAppPath: "/p")
        )
        truncated.removeLast()
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(truncated))

        var unknownMagic = try NetworkTelemetryCodec.encode(sampleTelemetry())
        unknownMagic[3] = 0x39
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(unknownMagic))
    }

    func testDecoderRejectsTrailingBytesUnknownTransportAndNUL() throws {
        var trailing = try NetworkTelemetryCodec.encode(sampleTelemetry(), version: .v1)
        trailing.append(0)
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(trailing))

        var unknownTransport = try NetworkTelemetryCodec.encode(sampleTelemetry(), version: .v1)
        unknownTransport[48] = 99
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(unknownTransport))

        var nulDestination = try NetworkTelemetryCodec.encode(sampleTelemetry(), version: .v1)
        // First record starts at 48, has a 44-byte header, then destination.
        nulDestination[92] = 0
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(nulDestination))
    }

    func testART3CarriesTrafficTotalsInTheEngineLayout() throws {
        // Mirrors clash-ffi's telemetry_v3_appends_bounded_traffic_totals.
        let totals = [
            TrafficTotalTelemetry(
                sourceAppIdentifier: "com.a",
                sourceAppPath: "/p",
                proxyChain: "Auto → HK",
                uploadTotal: 5,
                downloadTotal: 7
            ),
            TrafficTotalTelemetry(
                sourceAppIdentifier: "",
                sourceAppPath: "/p",
                proxyChain: "Auto → HK",
                uploadTotal: 0,
                downloadTotal: 7
            ),
        ]
        let snapshot = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            connections: [],
            trafficTotals: totals
        )
        let data = [UInt8](try NetworkTelemetryCodec.encode(snapshot))
        XCTAssertEqual(Array(data.prefix(4)), [0x41, 0x52, 0x54, 0x33])
        XCTAssertEqual(Array(data[48..<52]), [0, 0, 0, 2])
        XCTAssertEqual(Array(data[52..<60]), [0, 0, 0, 0, 0, 0, 0, 5])
        XCTAssertEqual(Array(data[68..<72]), [0, 0, 0, 5])
        XCTAssertEqual(Array(data[80..<(80 + 7)]), Array("com.a/p".utf8))
        let decoded = try NetworkTelemetryCodec.decode(Data(data))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.reportsTrafficTotals)

        // An ART3 engine with no traffic yet still reports totals.
        let empty = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            connections: [],
            reportsTrafficTotals: true
        )
        let emptyData = try NetworkTelemetryCodec.encode(empty)
        XCTAssertEqual(emptyData.count, 52)
        XCTAssertTrue(try NetworkTelemetryCodec.decode(emptyData).reportsTrafficTotals)
        XCTAssertFalse(
            try NetworkTelemetryCodec.decode(
                NetworkTelemetryCodec.encode(empty, version: .v2)
            ).reportsTrafficTotals
        )

        var truncated = Data(data)
        truncated.removeLast()
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(truncated))
    }

    func testART4CarriesIncarnationsInTheEngineLayout() throws {
        // Mirrors clash-ffi's telemetry_v3_appends_bounded_traffic_totals.
        let totals = [
            TrafficTotalTelemetry(
                sourceAppIdentifier: "com.a",
                sourceAppPath: "/p",
                proxyChain: "Auto → HK",
                uploadTotal: 5,
                downloadTotal: 7,
                incarnation: 9
            ),
            TrafficTotalTelemetry(
                sourceAppIdentifier: "",
                sourceAppPath: "/p",
                proxyChain: "Auto → HK",
                uploadTotal: 0,
                downloadTotal: 7,
                incarnation: 9
            ),
        ]
        let snapshot = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            connections: [],
            trafficTotals: totals,
            trafficTotalWatermark: 12
        )
        let data = [UInt8](try NetworkTelemetryCodec.encode(snapshot))
        XCTAssertEqual(Array(data.prefix(4)), [0x41, 0x52, 0x54, 0x34])
        XCTAssertEqual(Array(data[48..<56]), [0, 0, 0, 0, 0, 0, 0, 12])
        XCTAssertEqual(Array(data[56..<60]), [0, 0, 0, 2])
        XCTAssertEqual(Array(data[60..<68]), [0, 0, 0, 0, 0, 0, 0, 5])
        XCTAssertEqual(Array(data[76..<84]), [0, 0, 0, 0, 0, 0, 0, 9])
        XCTAssertEqual(Array(data[84..<88]), [0, 0, 0, 5])
        XCTAssertEqual(Array(data[96..<(96 + 7)]), Array("com.a/p".utf8))
        let decoded = try NetworkTelemetryCodec.decode(Data(data))
        XCTAssertEqual(decoded, snapshot)
        XCTAssertTrue(decoded.reportsTrafficTotals)
        XCTAssertEqual(decoded.trafficTotalWatermark, 12)

        // The same totals as ART3 lose only the incarnations.
        let art3 = try NetworkTelemetryCodec.decode(
            NetworkTelemetryCodec.encode(snapshot, version: .v3)
        )
        XCTAssertNil(art3.trafficTotalWatermark)
        XCTAssertEqual(art3.trafficTotals.map(\.incarnation), [nil, nil])
        XCTAssertEqual(art3.trafficTotals.map(\.downloadTotal), [7, 7])

        var truncated = Data(data)
        truncated.removeLast()
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(truncated))
        // A watermark with no count after it is malformed.
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(Data(data[0..<56])))
    }

    func testEncoderRejectsOversizedConnectionList() {
        let connection = sampleTelemetry().connections[0]
        let snapshot = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 0,
            downloadBytesPerSecond: 0,
            uploadTotal: 0,
            downloadTotal: 0,
            memoryBytes: 0,
            connections: Array(
                repeating: connection,
                count: NetworkTelemetryCodec.maximumConnections + 1
            )
        )
        XCTAssertThrowsError(try NetworkTelemetryCodec.encode(snapshot))
    }

    private func sampleTelemetry(
        sourceAppIdentifier: String = "",
        sourceAppPath: String = ""
    ) -> NetworkTelemetrySnapshot {
        NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 1_024,
            downloadBytesPerSecond: 2_048,
            uploadTotal: 4_096,
            downloadTotal: 8_192,
            memoryBytes: 16_384,
            connections: [
                ConnectionTelemetry(
                    transport: .tcp,
                    destination: "example.com",
                    destinationPort: 443,
                    uploadTotal: 512,
                    downloadTotal: 1_024,
                    startedAtUnixMilliseconds: 1_775_000_000_000,
                    rule: "DomainSuffix",
                    rulePayload: "example.com",
                    proxyChain: "Balanced → Singapore Edge",
                    sourceAppIdentifier: sourceAppIdentifier,
                    sourceAppPath: sourceAppPath
                ),
            ]
        )
    }
}

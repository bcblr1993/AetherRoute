@testable import AetherRouteKit
import Foundation
import XCTest

final class NetworkTelemetryTests: XCTestCase {
    func testART1RoundTripsBoundedConnectionSnapshot() throws {
        let snapshot = sampleTelemetry()
        let data = try NetworkTelemetryCodec.encode(snapshot)
        XCTAssertEqual(Array(data.prefix(4)), [0x41, 0x52, 0x54, 0x31])
        XCTAssertLessThanOrEqual(data.count, NetworkTelemetryCodec.maximumMessageBytes)
        XCTAssertEqual(try NetworkTelemetryCodec.decode(data), snapshot)
    }

    func testDecoderRejectsTrailingBytesUnknownTransportAndNUL() throws {
        var trailing = try NetworkTelemetryCodec.encode(sampleTelemetry())
        trailing.append(0)
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(trailing))

        var unknownTransport = try NetworkTelemetryCodec.encode(sampleTelemetry())
        unknownTransport[48] = 99
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(unknownTransport))

        var nulDestination = try NetworkTelemetryCodec.encode(sampleTelemetry())
        // First record starts at 48, has a 44-byte header, then destination.
        nulDestination[92] = 0
        XCTAssertThrowsError(try NetworkTelemetryCodec.decode(nulDestination))
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

    private func sampleTelemetry() -> NetworkTelemetrySnapshot {
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
                    proxyChain: "Balanced → Singapore Edge"
                ),
            ]
        )
    }
}

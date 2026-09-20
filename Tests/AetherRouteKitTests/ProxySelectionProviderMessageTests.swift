@testable import AetherRouteKit
import Foundation
import XCTest

final class ProxySelectionProviderMessageTests: XCTestCase {
    func testRawSelectorLatencyCapacityUsesProtocolBoundInsteadOfEnvelope() {
        XCTAssertEqual(
            ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(memberCount: 0),
            8
        )
        XCTAssertEqual(
            ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(memberCount: 1),
            1_040
        )
        XCTAssertEqual(
            ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(memberCount: 64),
            66_056
        )
        XCTAssertNil(
            ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(memberCount: -1)
        )
        XCTAssertNil(
            ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(
                    memberCount: ProxySelectionProviderMessageCodec
                        .maximumMemberCount
                )
        )
    }

    func testRequestRoundTripsSnapshotAndSelection() throws {
        let requests: [ProxySelectionProviderRequest] = [
            .snapshot(group: "Balanced"),
            .select(group: "Balanced", member: "Tokyo · Reality"),
            .latency(
                group: "Balanced",
                url: "https://example.invalid/generate_204",
                timeoutMilliseconds: 5_000
            ),
            .activeLatency(
                group: "Balanced",
                url: "https://example.invalid/generate_204",
                timeoutMilliseconds: 5_000
            ),
            .telemetry(maximumConnections: 50),
            .diagnostics,
            .setRoutingMode(.rule),
            .setRoutingMode(.global),
            .setRoutingMode(.direct),
            .resetNetwork,
            .reloadProfile(Data()),
            .reloadProfile(Data([1, 2, 3, 4])),
        ]
        for request in requests {
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(
                    ProxySelectionProviderMessageCodec.encode(request: request)
                ),
                request
            )
        }
    }

    func testReloadProfilePayloadCodecRoundTrip() throws {
        let payload = ReloadProfilePayload(
            profileYAML: "proxies:\n  - name: test\n    type: direct\n",
            routingMode: .rule,
            bypassPolicy: BypassPolicy(rules: []),
            dnsPolicy: .inherited,
            proxySelections: ["GLOBAL": "test"]
        )
        let encoded = try ReloadProfilePayloadCodec.encode(payload)
        let decoded = try ReloadProfilePayloadCodec.decode(encoded)
        XCTAssertEqual(decoded, payload)
    }

    func testProfileReloadedResponseRoundTrips() throws {
        let encoded = try ProxySelectionProviderMessageCodec.encode(
            response: .profileReloaded
        )
        XCTAssertEqual(encoded.count, 16)
        XCTAssertEqual(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
            .profileReloaded
        )
    }

    func testNetworkResetResponseRoundTrips() throws {
        let encoded = try ProxySelectionProviderMessageCodec.encode(
            response: .networkReset
        )
        XCTAssertEqual(encoded.count, 16)
        XCTAssertEqual(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
            .networkReset
        )
    }

    func testRoutingModeResponseRoundTripsAndRejectsUnknownCode() throws {
        for mode in RoutingMode.allCases {
            var encoded = try ProxySelectionProviderMessageCodec.encode(
                response: .routingMode(mode)
            )
            XCTAssertEqual(encoded.count, 16)
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
                .routingMode(mode)
            )
            encoded[5] = 3
            XCTAssertThrowsError(
                try ProxySelectionProviderMessageCodec.decodeResponse(encoded)
            )
        }
    }

    func testRequestRejectsUnknownOperationNULAndTrailingBytes() throws {
        var unknown = try ProxySelectionProviderMessageCodec.encode(
            request: .snapshot(group: "Route")
        )
        unknown[4] = 99
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.decodeRequest(unknown)
        )

        var trailing = try ProxySelectionProviderMessageCodec.encode(
            request: .snapshot(group: "Route")
        )
        trailing.append(0)
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.decodeRequest(trailing)
        )

        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.encode(
                request: .snapshot(group: "Route\0Hidden")
            )
        )
    }

    func testSnapshotResponseRoundTripsVerifiedSelection() throws {
        let state = ProxySelectionState(
            selectedMember: "Singapore",
            members: ["DIRECT", "Singapore", "Tokyo"]
        )
        let encoded = try ProxySelectionProviderMessageCodec.encode(
            response: .snapshot(state)
        )
        XCTAssertEqual(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
            .snapshot(state)
        )
    }

    func testFailureResponseRoundTripsWithoutDetailLeakage() throws {
        for failure in [
            ProxySelectionProviderFailure.invalidRequest,
            .unavailable,
            .rejected,
            .responseTooLarge,
            .internalFailure,
        ] {
            let encoded = try ProxySelectionProviderMessageCodec.encode(
                response: .failure(failure)
            )
            XCTAssertEqual(encoded.count, 16)
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
                .failure(failure)
            )
        }
    }

    func testLatencyResponseRoundTripsFailuresAndMeasurements() throws {
        let state = ProxyLatencyState(
            results: [
                ProxyLatencyResult(member: "Edge A", delayMilliseconds: 19),
                ProxyLatencyResult(member: "Edge B", delayMilliseconds: nil),
            ]
        )
        let encoded = try ProxySelectionProviderMessageCodec.encode(
            response: .latency(state)
        )
        XCTAssertEqual(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
            .latency(state)
        )

        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.encode(
                request: .latency(
                    group: "Route",
                    url: "file:///private/etc/hosts",
                    timeoutMilliseconds: 5_000
                )
            )
        )
    }

    func testTelemetryResponseRoundTripsWithoutSourceIdentityFields() throws {
        let state = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 100,
            downloadBytesPerSecond: 200,
            uploadTotal: 300,
            downloadTotal: 400,
            memoryBytes: 500,
            connections: [
                ConnectionTelemetry(
                    transport: .udp,
                    destination: "dns.example",
                    destinationPort: 53,
                    uploadTotal: 10,
                    downloadTotal: 20,
                    startedAtUnixMilliseconds: 30,
                    rule: "Match",
                    rulePayload: "",
                    proxyChain: "DIRECT"
                ),
            ]
        )
        let encoded = try ProxySelectionProviderMessageCodec.encode(
            response: .telemetry(state)
        )
        XCTAssertEqual(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
            .telemetry(state)
        )
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("sourceIP"))
    }

    func testDiagnosticsResponseIsFixedSizeAndRejectsTrailingData() throws {
        let snapshot = ProviderDiagnosticSnapshot(
            startupFailureCount: 1,
            networkSettingsFailureCount: 2,
            invalidControlRequestCount: 3,
            unavailableControlRequestCount: 4,
            rejectedControlRequestCount: 5,
            oversizedControlResponseCount: 6,
            internalControlFailureCount: 7,
            flowAdmissionFailureCount: 8
        )
        var encoded = try ProxySelectionProviderMessageCodec.encode(
            response: .diagnostics(snapshot)
        )
        XCTAssertEqual(encoded.count, 80)
        XCTAssertEqual(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded),
            .diagnostics(snapshot)
        )

        encoded.append(0)
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.decodeResponse(encoded)
        )
    }

    func testResponseRejectsInvalidSelectionAndOversizedNames() throws {
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.encode(
                response: .snapshot(
                    ProxySelectionState(
                        selectedMember: "Missing",
                        members: ["DIRECT"]
                    )
                )
            )
        )
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.encode(
                request: .snapshot(group: String(repeating: "x", count: 1_025))
            )
        )

        var invalidIndex = try ProxySelectionProviderMessageCodec.encode(
            response: .snapshot(
                ProxySelectionState(selectedMember: nil, members: ["DIRECT"])
            )
        )
        invalidIndex.replaceSubrange(8..<12, with: [0, 0, 0, 2])
        XCTAssertThrowsError(
            try ProxySelectionProviderMessageCodec.decodeResponse(invalidIndex)
        )
    }
}

import AetherRouteKit
import XCTest

final class ProxySelectionProviderClientTests: XCTestCase {
    func testSnapshotUsesBoundedWireProtocol() async throws {
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .snapshot(group: "Route")
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .snapshot(
                    ProxySelectionState(
                        selectedMember: "Edge A",
                        members: ["Edge A", "Edge B"]
                    )
                )
            )
        }

        let snapshot = try await client.snapshot(group: "Route")
        XCTAssertEqual(
            snapshot,
            ProxySelectionState(
                selectedMember: "Edge A",
                members: ["Edge A", "Edge B"]
            )
        )
    }

    func testSelectionRequiresProviderConfirmation() async throws {
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .select(group: "Route", member: "Edge B")
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .snapshot(
                    ProxySelectionState(
                        selectedMember: "Edge A",
                        members: ["Edge A", "Edge B"]
                    )
                )
            )
        }

        do {
            _ = try await client.select(group: "Route", member: "Edge B")
            XCTFail("Unconfirmed selection must fail")
        } catch {
            XCTAssertEqual(
                error as? ProxySelectionProviderClientError,
                .selectionNotApplied
            )
        }
    }

    func testProviderFailureIsPreservedWithoutDetailPayload() async throws {
        let client = ProxySelectionProviderClient { _ in
            try ProxySelectionProviderMessageCodec.encode(
                response: .failure(.unavailable)
            )
        }

        do {
            _ = try await client.snapshot(group: "Route")
            XCTFail("Provider failure must not become an empty snapshot")
        } catch {
            XCTAssertEqual(
                error as? ProxySelectionProviderClientError,
                .providerFailure(.unavailable)
            )
        }
    }

    func testLatencyRequiresMatchingTypedResponse() async throws {
        let expected = ProxyLatencyState(
            results: [
                ProxyLatencyResult(member: "Edge A", delayMilliseconds: 24),
                ProxyLatencyResult(member: "Edge B", delayMilliseconds: nil),
            ]
        )
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .latency(
                    group: "Route",
                    url: "https://example.invalid/generate_204",
                    timeoutMilliseconds: 5_000
                )
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .latency(expected)
            )
        }

        let latency = try await client.latency(
            group: "Route",
            url: "https://example.invalid/generate_204",
            timeoutMilliseconds: 5_000
        )
        XCTAssertEqual(latency, expected)
    }

    func testTelemetryRequiresMatchingTypedResponse() async throws {
        let expected = NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 1,
            downloadBytesPerSecond: 2,
            uploadTotal: 3,
            downloadTotal: 4,
            memoryBytes: 5,
            connections: []
        )
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .telemetry(maximumConnections: 50)
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .telemetry(expected)
            )
        }

        let received = try await client.telemetry()
        XCTAssertEqual(received, expected)
    }

    func testDiagnosticsRequiresMatchingFixedResponse() async throws {
        let expected = ProviderDiagnosticSnapshot(
            startupFailureCount: 2,
            flowAdmissionFailureCount: 9
        )
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .diagnostics
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .diagnostics(expected)
            )
        }

        let received = try await client.diagnostics()
        XCTAssertEqual(received, expected)
    }

    func testRoutingModeRequiresProviderConfirmation() async throws {
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .setRoutingMode(.global)
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .routingMode(.global)
            )
        }

        let applied = try await client.setRoutingMode(.global)
        XCTAssertEqual(applied, .global)
    }

    func testResetNetworkSendsValidWireRequestAndAcceptsNetworkResetResponse() async throws {
        let client = ProxySelectionProviderClient { data in
            XCTAssertEqual(
                try ProxySelectionProviderMessageCodec.decodeRequest(data),
                .resetNetwork
            )
            return try ProxySelectionProviderMessageCodec.encode(
                response: .networkReset
            )
        }

        try await client.resetNetwork()
    }
}

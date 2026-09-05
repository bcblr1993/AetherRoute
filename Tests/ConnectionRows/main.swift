import AetherRouteKit
import Foundation

@main
enum ConnectionRowsRegression {
    static func main() throws {
        let initial = ConnectionTableItem.identify([
            connection("a.example", downloaded: 200),
            connection("b.example", downloaded: 100),
        ]).sorted { $0.connection.downloadTotal > $1.connection.downloadTotal }
        let updated = ConnectionTableItem.identify([
            connection("b.example", downloaded: 400),
            connection("a.example", downloaded: 250),
        ]).sorted { $0.connection.downloadTotal > $1.connection.downloadTotal }
        try expect(
            initial.map(\.connection.destination) != updated.map(\.connection.destination),
            "Fixture must reverse the displayed traffic order."
        )
        let initialIDs = Dictionary(uniqueKeysWithValues: initial.map {
            ($0.connection.destination, $0.id)
        })
        for row in updated {
            try expect(
                initialIDs[row.connection.destination] == row.id,
                "A traffic update and provider reordering replaced an existing row."
            )
        }

        let duplicates = ConnectionTableItem.identify([
            connection("same.example", downloaded: 20),
            connection("same.example", downloaded: 10, outlet: "DIRECT"),
            connection("same.example", downloaded: 30, transport: .udp),
        ])
        try expect(
            Set(duplicates.map(\.id)).count == duplicates.count,
            "Concurrent connections must never create duplicate Table IDs."
        )
        let direct = duplicates.filter { $0.connection.proxyChain == "DIRECT" }
        try expect(
            direct.count == 1 && direct[0].id == duplicates[1].id,
            "Filtering a row to the first position changed its identity."
        )
        let reopened = ConnectionTableItem.identify([
            connection("a.example", downloaded: 200, startedAt: 2_000),
        ])
        try expect(
            reopened[0].id != initial[0].id,
            "A new session reused the closed session's row identity."
        )
        print("Connection row regression passed: traffic reorder, filter, concurrent duplicates, transport, and new session.")
    }

    private static func connection(
        _ destination: String,
        downloaded: UInt64,
        transport: NetworkTelemetryTransport = .tcp,
        outlet: String = "Proxy",
        startedAt: UInt64 = 1_000
    ) -> ConnectionTelemetry {
        ConnectionTelemetry(
            transport: transport,
            destination: destination,
            destinationPort: 443,
            uploadTotal: 0,
            downloadTotal: downloaded,
            startedAtUnixMilliseconds: startedAt,
            rule: "MATCH",
            rulePayload: "",
            proxyChain: outlet
        )
    }

    private static func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private struct Failure: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }
}

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
        let named = connection("http-intake.logs.datadoghq.com", downloaded: 0)
        try expect(
            named.destinationHost == "http-intake.logs.datadoghq.com"
                && named.destinationAddress == "http-intake.logs.datadoghq.com:443",
            "A host name must be shown unchanged before its port."
        )
        let ipv6 = connection("2001:db8::1", downloaded: 0)
        try expect(
            ipv6.destinationHost == "[2001:db8::1]"
                && ipv6.destinationAddress == "[2001:db8::1]:443",
            "An IPv6 literal must be bracketed so its port stays unambiguous."
        )
        let bracketed = connection("[2001:db8::1]", downloaded: 0)
        try expect(
            bracketed.destinationHost == "[2001:db8::1]",
            "An already bracketed IPv6 literal must not be bracketed twice."
        )

        // Zero-allocation outlet classification & leaf extraction regression
        try expect(
            ConnectionOutletClassifier.classify("") == .direct
                && ConnectionOutletClassifier.classify("  direct ") == .direct
                && ConnectionOutletClassifier.classify("DIRECT") == .direct,
            "Empty and case-insensitive DIRECT chains must classify as .direct."
        )
        try expect(
            ConnectionOutletClassifier.classify("REJECT") == .rejected
                && ConnectionOutletClassifier.classify("reject-drop") == .rejected
                && ConnectionOutletClassifier.classify(" REJECT-DROP ") == .rejected,
            "REJECT and REJECT-DROP chains must classify as .rejected."
        )
        try expect(
            ConnectionOutletClassifier.classify("Proxy → SG-Edge-01") == .proxied
                && ConnectionOutletClassifier.leafOutletName("Proxy → SG-Edge-01") == "SG-Edge-01"
                && ConnectionOutletClassifier.leafOutletName("Auto -> Group -> HK-02") == "HK-02"
                && ConnectionOutletClassifier.leafOutletName("SingleNode") == "SingleNode",
            "Proxied chains must extract the final leaf node without allocating component arrays."
        )
        let mixedConnections = [
            connection("a.example", downloaded: 10, outlet: "Proxy → SG-01"),
            connection("b.example", downloaded: 20, outlet: "DIRECT"),
            connection("c.example", downloaded: 30, outlet: "REJECT-DROP"),
            connection("d.example", downloaded: 40, outlet: "Auto -> JP-02"),
        ]
        let counts = ConnectionOutletClassifier.counts(for: mixedConnections)
        try expect(
            counts.all == 4 && counts.proxied == 2 && counts.direct == 1 && counts.rejected == 1,
            "Batch outlet counting must accurately tally all, proxied, direct, and rejected connections."
        )
        print("Connection row regression passed: traffic reorder, filter, concurrent duplicates, transport, new session, and host formatting.")
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

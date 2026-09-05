import AetherRouteKit

/// Presentation identity uses immutable telemetry fields, never the row's
/// sorted position or changing byte counters. The telemetry protocol omits
/// private flow UUIDs, so otherwise indistinguishable flows receive an
/// occurrence number before the UI applies its filter and sort order.
struct ConnectionTableItem: Identifiable {
    struct ID: Hashable {
        let transport: UInt8
        let destination: String
        let destinationPort: UInt16
        let startedAtUnixMilliseconds: UInt64
        let occurrence: Int
    }

    let id: ID
    let connection: ConnectionTelemetry

    static func identify(_ connections: [ConnectionTelemetry]) -> [Self] {
        var occurrences: [ID: Int] = [:]
        return connections.map { connection in
            let key = ID(
                transport: connection.transport.rawValue,
                destination: connection.destination,
                destinationPort: connection.destinationPort,
                startedAtUnixMilliseconds: connection.startedAtUnixMilliseconds,
                occurrence: 0
            )
            let occurrence = occurrences[key, default: 0]
            occurrences[key] = occurrence + 1
            return Self(
                id: ID(
                    transport: key.transport,
                    destination: key.destination,
                    destinationPort: key.destinationPort,
                    startedAtUnixMilliseconds: key.startedAtUnixMilliseconds,
                    occurrence: occurrence
                ),
                connection: connection
            )
        }
    }
}

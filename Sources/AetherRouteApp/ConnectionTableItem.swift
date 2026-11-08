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
        guard !connections.isEmpty else { return [] }
        var occurrences: [ID: Int] = [:]
        occurrences.reserveCapacity(connections.count)
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

/// Zero-allocation classifier and leaf extractor for connection `proxyChain` strings.
///
/// Called thousands of times per render pass on the 2,000-row connection table;
/// avoids allocating `[String]` arrays via `components(separatedBy:)` or `.uppercased()`.
enum ConnectionOutletClassifier {
    enum Kind: Equatable, Sendable {
        case proxied
        case direct
        case rejected
    }

    struct Counts: Equatable, Sendable {
        let all: Int
        let proxied: Int
        let direct: Int
        let rejected: Int
    }

    static func classify(_ proxyChain: String) -> Kind {
        let trimmed = trimSpaces(proxyChain[...])
        if trimmed.isEmpty {
            return .direct
        }
        if trimmed.caseInsensitiveCompare("DIRECT") == .orderedSame {
            return .direct
        }
        if trimmed.caseInsensitiveCompare("REJECT") == .orderedSame
            || trimmed.caseInsensitiveCompare("REJECT-DROP") == .orderedSame {
            return .rejected
        }
        return .proxied
    }

    static func leafOutletName(_ proxyChain: String) -> String {
        var slice = trimSpaces(proxyChain[...])
        if let unicodeArrow = slice.range(of: "→", options: .backwards) {
            slice = slice[unicodeArrow.upperBound...]
        }
        if let asciiArrow = slice.range(of: "->", options: .backwards) {
            slice = slice[asciiArrow.upperBound...]
        }
        let leaf = trimSpaces(slice)
        if !leaf.isEmpty {
            return String(leaf)
        }
        return String(trimSpaces(proxyChain[...]))
    }

    static func counts(for connections: [ConnectionTelemetry]) -> Counts {
        var proxied = 0
        var direct = 0
        var rejected = 0
        for connection in connections {
            switch classify(connection.proxyChain) {
            case .proxied:
                proxied += 1
            case .direct:
                direct += 1
            case .rejected:
                rejected += 1
            }
        }
        return Counts(
            all: connections.count,
            proxied: proxied,
            direct: direct,
            rejected: rejected
        )
    }

    private static func trimSpaces(_ substring: Substring) -> Substring {
        var start = substring.startIndex
        var end = substring.endIndex
        while start < end, substring[start].isWhitespace {
            start = substring.index(after: start)
        }
        while end > start {
            let prev = substring.index(before: end)
            guard substring[prev].isWhitespace else { break }
            end = prev
        }
        return substring[start..<end]
    }
}

extension ConnectionTelemetry {
    /// The host as it appears before ":port": IPv6 literals are bracketed.
    var destinationHost: String {
        destination.contains(":") && !destination.hasPrefix("[")
            ? "[\(destination)]" : destination
    }

    var destinationAddress: String {
        "\(destinationHost):\(destinationPort)"
    }
}

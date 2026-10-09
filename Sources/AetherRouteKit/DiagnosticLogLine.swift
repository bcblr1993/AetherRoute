import Foundation

/// One record of a diagnostic log file, as `DiagnosticLog` writes it:
/// `<ISO-8601 time> <marker> [<category>] <message>`.
public struct DiagnosticLogLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable, CaseIterable {
        case error
        case lifecycle
        case aggregate
        case verbose
        /// A line that does not follow the format (a wrapped message).
        case other
    }

    public let id: Int
    /// Which process wrote it: "app", "tunnel" or "transparent-proxy".
    public let process: String
    public let timestamp: String
    public let kind: Kind
    public let category: String
    public let message: String

    public init(
        id: Int,
        process: String,
        timestamp: String,
        kind: Kind,
        category: String,
        message: String
    ) {
        self.id = id
        self.process = process
        self.timestamp = timestamp
        self.kind = kind
        self.category = category
        self.message = message
    }

    /// The line as it appears in the file, for copying.
    public var rawText: String {
        kind == .other
            ? message
            : "\(timestamp) \(Self.marker(kind)) [\(category)] \(message)"
    }

    /// Parses a log file's text. `firstID` lets lines from several processes
    /// share one list without colliding identifiers.
    public static func parse(
        _ text: String,
        process: String,
        firstID: Int = 0
    ) -> [DiagnosticLogLine] {
        var lines: [DiagnosticLogLine] = []
        var nextID = firstID
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            lines.append(parseLine(String(raw), process: process, id: nextID))
            nextID += 1
        }
        return lines
    }

    /// Lines from several processes in time order. ISO-8601 UTC timestamps
    /// sort correctly as strings; a line without one keeps its position
    /// after the line before it.
    public static func merged(_ sources: [[DiagnosticLogLine]]) -> [DiagnosticLogLine] {
        var records: [(timestamp: String, order: Int, lines: [DiagnosticLogLine])] = []
        for source in sources {
            for (index, line) in source.enumerated() {
                if !line.timestamp.isEmpty || index == 0 {
                    records.append((line.timestamp, records.count, [line]))
                } else {
                    records[records.count - 1].lines.append(line)
                }
            }
        }
        return records.sorted {
            $0.timestamp == $1.timestamp ? $0.order < $1.order : $0.timestamp < $1.timestamp
        }.flatMap(\.lines)
    }

    private static func parseLine(_ raw: String, process: String, id: Int) -> DiagnosticLogLine {
        let parts = raw.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4,
              parts[0].count >= 20,
              parts[0].hasSuffix("Z"),
              let kind = kind(marker: parts[1]),
              parts[2].hasPrefix("["),
              parts[2].hasSuffix("]")
        else {
            return DiagnosticLogLine(
                id: id, process: process, timestamp: "",
                kind: .other, category: "", message: raw
            )
        }
        return DiagnosticLogLine(
            id: id,
            process: process,
            timestamp: String(parts[0]),
            kind: kind,
            category: String(parts[2].dropFirst().dropLast()),
            message: String(parts[3])
        )
    }

    private static func kind(marker: Substring) -> Kind? {
        switch marker {
        case "E": .error
        case "L": .lifecycle
        case "A": .aggregate
        case "V": .verbose
        default: nil
        }
    }

    private static func marker(_ kind: Kind) -> String {
        switch kind {
        case .error: "E"
        case .lifecycle: "L"
        case .aggregate: "A"
        case .verbose: "V"
        case .other: ""
        }
    }
}

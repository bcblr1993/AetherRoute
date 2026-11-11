import AetherRouteKit
import Foundation

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

/// Computes accurate average upload/download byte rates across arbitrary polling
/// intervals from monotonic cumulative byte counters (`uploadTotal` / `downloadTotal`),
/// eliminating the 2-out-of-3-second sampling drop when polling every 3s or 10s.
struct TelemetryRateSampler: Sendable {
    private static let minimumElapsedSeconds: TimeInterval = 0.2
    private static let maximumElapsedSeconds: TimeInterval = 180.0

    private var previousUploadTotal: UInt64?
    private var previousDownloadTotal: UInt64?
    private var previousSampleAt: Date?

    mutating func reset() {
        previousUploadTotal = nil
        previousDownloadTotal = nil
        previousSampleAt = nil
    }

    mutating func resolve(
        snapshot: NetworkTelemetrySnapshot,
        at now: Date = .now
    ) -> NetworkTelemetrySnapshot {
        guard let prevUp = previousUploadTotal,
              let prevDown = previousDownloadTotal,
              let prevAt = previousSampleAt
        else {
            previousUploadTotal = snapshot.uploadTotal
            previousDownloadTotal = snapshot.downloadTotal
            previousSampleAt = now
            return snapshot
        }

        let elapsed = now.timeIntervalSince(prevAt)
        guard elapsed >= Self.minimumElapsedSeconds else {
            if elapsed < 0 {
                previousUploadTotal = snapshot.uploadTotal
                previousDownloadTotal = snapshot.downloadTotal
                previousSampleAt = now
            }
            return snapshot
        }

        guard elapsed <= Self.maximumElapsedSeconds,
              snapshot.uploadTotal >= prevUp,
              snapshot.downloadTotal >= prevDown
        else {
            previousUploadTotal = snapshot.uploadTotal
            previousDownloadTotal = snapshot.downloadTotal
            previousSampleAt = now
            return snapshot
        }

        let uploadDelta = snapshot.uploadTotal - prevUp
        let downloadDelta = snapshot.downloadTotal - prevDown
        let resolvedUp = UInt64((Double(uploadDelta) / elapsed).rounded())
        let resolvedDown = UInt64((Double(downloadDelta) / elapsed).rounded())

        previousUploadTotal = snapshot.uploadTotal
        previousDownloadTotal = snapshot.downloadTotal
        previousSampleAt = now

        return NetworkTelemetrySnapshot(
            uploadBytesPerSecond: resolvedUp,
            downloadBytesPerSecond: resolvedDown,
            uploadTotal: snapshot.uploadTotal,
            downloadTotal: snapshot.downloadTotal,
            memoryBytes: snapshot.memoryBytes,
            connections: snapshot.connections,
            trafficTotals: snapshot.trafficTotals,
            reportsTrafficTotals: snapshot.reportsTrafficTotals,
            trafficTotalWatermark: snapshot.trafficTotalWatermark
        )
    }
}

/// Live upload and download transfer rates for a single active connection.
struct ConnectionTransferRates: Equatable, Sendable {
    let uploadBytesPerSecond: UInt64
    let downloadBytesPerSecond: UInt64

    var totalBytesPerSecond: UInt64 {
        uploadBytesPerSecond &+ downloadBytesPerSecond
    }

    static let zero = Self(uploadBytesPerSecond: 0, downloadBytesPerSecond: 0)
}

/// Tracks per-connection byte counter deltas across consecutive telemetry polls.
struct ConnectionLiveRateTracker: Sendable {
    private static let minimumElapsedSeconds: TimeInterval = 0.2
    private static let maximumElapsedSeconds: TimeInterval = 180.0

    private var previousTotals: [ConnectionTableItem.ID: (upload: UInt64, download: UInt64)] = [:]
    private var previousSampleAt: Date?
    private var lastRates: [ConnectionTableItem.ID: ConnectionTransferRates] = [:]

    mutating func reset() {
        previousTotals.removeAll()
        previousSampleAt = nil
        lastRates.removeAll()
    }

    mutating func update(
        items: [ConnectionTableItem],
        at now: Date = .now
    ) -> [ConnectionTableItem.ID: ConnectionTransferRates] {
        var nextTotals: [ConnectionTableItem.ID: (upload: UInt64, download: UInt64)] = [:]
        nextTotals.reserveCapacity(items.count)
        for item in items {
            nextTotals[item.id] = (item.connection.uploadTotal, item.connection.downloadTotal)
        }

        guard let prevAt = previousSampleAt else {
            previousTotals = nextTotals
            previousSampleAt = now
            lastRates = [:]
            return [:]
        }

        let elapsed = now.timeIntervalSince(prevAt)
        guard elapsed >= Self.minimumElapsedSeconds else {
            if elapsed < 0 {
                previousTotals = nextTotals
                previousSampleAt = now
                lastRates = [:]
            }
            return lastRates
        }

        guard elapsed <= Self.maximumElapsedSeconds else {
            previousTotals = nextTotals
            previousSampleAt = now
            lastRates = [:]
            return [:]
        }

        var rates: [ConnectionTableItem.ID: ConnectionTransferRates] = [:]
        rates.reserveCapacity(items.count)
        for item in items {
            guard let prev = previousTotals[item.id],
                  item.connection.uploadTotal >= prev.upload,
                  item.connection.downloadTotal >= prev.download
            else { continue }
            let upDelta = item.connection.uploadTotal - prev.upload
            let downDelta = item.connection.downloadTotal - prev.download
            let upRate = UInt64((Double(upDelta) / elapsed).rounded())
            let downRate = UInt64((Double(downDelta) / elapsed).rounded())
            rates[item.id] = ConnectionTransferRates(
                uploadBytesPerSecond: upRate,
                downloadBytesPerSecond: downRate
            )
        }

        previousTotals = nextTotals
        previousSampleAt = now
        lastRates = rates
        return rates
    }
}

/// Prevents connections that merely fell outside a truncated top-N telemetry
/// window from being falsely recorded into `RecentlyClosedConnectionBuffer`.
struct ConnectionTruncationGuard: Sendable {
    private static let maximumCarriedRankedOut = 512

    private struct IdentityKey: Hashable, Sendable {
        let transport: UInt8
        let destination: String
        let destinationPort: UInt16
        let startedAtUnixMilliseconds: UInt64
        let rule: String
        let rulePayload: String
        let proxyChain: String
        let sourceAppIdentifier: String
        let sourceAppPath: String

        init(_ connection: ConnectionTelemetry) {
            self.transport = connection.transport.rawValue
            self.destination = connection.destination
            self.destinationPort = connection.destinationPort
            self.startedAtUnixMilliseconds = connection.startedAtUnixMilliseconds
            self.rule = connection.rule
            self.rulePayload = connection.rulePayload
            self.proxyChain = connection.proxyChain
            self.sourceAppIdentifier = connection.sourceAppIdentifier
            self.sourceAppPath = connection.sourceAppPath
        }
    }

    private var previousActive: [ConnectionTelemetry] = []

    mutating func reset() {
        previousActive.removeAll()
    }

    mutating func seed(active: [ConnectionTelemetry]) {
        previousActive = active
    }

    mutating func record(
        active: [ConnectionTelemetry],
        isTruncated: Bool,
        into buffer: inout RecentlyClosedConnectionBuffer
    ) {
        var remainingActiveCounts: [IdentityKey: Int] = [:]
        remainingActiveCounts.reserveCapacity(active.count)
        for connection in active {
            remainingActiveCounts[IdentityKey(connection), default: 0] += 1
        }

        let cutoffBytes: UInt64 = isTruncated
            ? (active.map { $0.uploadTotal &+ $0.downloadTotal }.min() ?? 0)
            : 0

        var newlyClosed: [ConnectionTelemetry] = []
        var carriedRankedOut: [ConnectionTelemetry] = []

        for previous in previousActive {
            let key = IdentityKey(previous)
            if let count = remainingActiveCounts[key], count > 0 {
                remainingActiveCounts[key] = count - 1
            } else if isTruncated, (previous.uploadTotal &+ previous.downloadTotal) <= cutoffBytes {
                if carriedRankedOut.count < Self.maximumCarriedRankedOut {
                    carriedRankedOut.append(previous)
                }
            } else {
                newlyClosed.append(previous)
            }
        }

        previousActive = active + carriedRankedOut

        guard !newlyClosed.isEmpty else { return }
        let chunkSize = max(1, NetworkTelemetryCodec.maximumConnections)
        var startIndex = 0
        while startIndex < newlyClosed.count {
            let endIndex = min(startIndex + chunkSize, newlyClosed.count)
            buffer.record(active: Array(newlyClosed[startIndex..<endIndex]))
            buffer.record(active: [])
            startIndex = endIndex
        }
    }
}

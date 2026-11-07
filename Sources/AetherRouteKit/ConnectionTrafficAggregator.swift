import Foundation

/// Grouping dimensions for connection traffic aggregation and leaderboard views,
/// benchmarked against Surge 5 Process/Domain/Outbound views and Clash Verge Rev.
public enum ConnectionTrafficDimension: String, CaseIterable, Sendable, Equatable {
    case application
    case host
    case outbound
}

/// Aggregated traffic entry for a single application, destination host, or outbound hop.
public struct ConnectionTrafficEntry: Identifiable, Sendable, Equatable {
    public let id: String
    public let dimension: ConnectionTrafficDimension
    public let key: String
    public let displayName: String
    public let subtitle: String
    public let sourceAppIdentifier: String
    public let sourceAppPath: String
    public let connectionCount: Int
    public let uploadTotal: UInt64
    public let downloadTotal: UInt64
    public let latestStartedAtUnixMilliseconds: UInt64
    public let outletSummary: String
    public let sampleConnection: ConnectionTelemetry
    public let shareOfTotal: Double

    public var totalBytes: UInt64 {
        uploadTotal &+ downloadTotal
    }

    public init(
        id: String,
        dimension: ConnectionTrafficDimension,
        key: String,
        displayName: String,
        subtitle: String,
        sourceAppIdentifier: String,
        sourceAppPath: String,
        connectionCount: Int,
        uploadTotal: UInt64,
        downloadTotal: UInt64,
        latestStartedAtUnixMilliseconds: UInt64,
        outletSummary: String,
        sampleConnection: ConnectionTelemetry,
        shareOfTotal: Double
    ) {
        self.id = id
        self.dimension = dimension
        self.key = key
        self.displayName = displayName
        self.subtitle = subtitle
        self.sourceAppIdentifier = sourceAppIdentifier
        self.sourceAppPath = sourceAppPath
        self.connectionCount = connectionCount
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.latestStartedAtUnixMilliseconds = latestStartedAtUnixMilliseconds
        self.outletSummary = outletSummary
        self.sampleConnection = sampleConnection
        self.shareOfTotal = shareOfTotal
    }
}

/// Bounded summary of connection traffic across a chosen dimension.
public struct ConnectionTrafficSummary: Sendable, Equatable {
    public let dimension: ConnectionTrafficDimension
    public let entries: [ConnectionTrafficEntry]
    public let totalConnectionCount: Int
    public let totalUploadBytes: UInt64
    public let totalDownloadBytes: UInt64

    public var totalBytes: UInt64 {
        totalUploadBytes &+ totalDownloadBytes
    }

    public init(
        dimension: ConnectionTrafficDimension,
        entries: [ConnectionTrafficEntry],
        totalConnectionCount: Int,
        totalUploadBytes: UInt64,
        totalDownloadBytes: UInt64
    ) {
        self.dimension = dimension
        self.entries = entries
        self.totalConnectionCount = totalConnectionCount
        self.totalUploadBytes = totalUploadBytes
        self.totalDownloadBytes = totalDownloadBytes
    }
}

public enum ConnectionTrafficAggregator {
    /// Normalizes a destination string (`"API.ANTHROPIC.COM:443"`, `"[2606:4700::1]:53"`)
    /// into a lowercase host or bare IP literal (`"api.anthropic.com"`, `"2606:4700::1"`).
    public static func normalizedHost(from destination: String) -> String {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "unknown" }

        if trimmed.hasPrefix("[") {
            if let closingBracket = trimmed.firstIndex(of: "]") {
                let inner = trimmed[trimmed.index(after: trimmed.startIndex)..<closingBracket]
                let normalized = String(inner).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return normalized.isEmpty ? "unknown" : normalized
            }
        }

        // Unbracketed IPv6 literal has more than one colon; keep as-is.
        let colonCount = trimmed.reduce(into: 0) { count, ch in
            if ch == ":" { count += 1 }
        }
        if colonCount == 1, let colonIndex = trimmed.lastIndex(of: ":") {
            let portCandidate = trimmed[trimmed.index(after: colonIndex)...]
            if !portCandidate.isEmpty, portCandidate.allSatisfy(\.isNumber) {
                let hostPart = String(trimmed[..<colonIndex]).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return hostPart.isEmpty ? "unknown" : hostPart
            }
        }

        return trimmed.lowercased()
    }

    /// Extracts the terminal outbound hop from a proxy chain (`"AI Group → Tokyo 01"` -> `"Tokyo 01"`).
    public static func terminalOutbound(from proxyChain: String) -> String {
        let trimmed = proxyChain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "DIRECT" }
        let arrowParts = trimmed.components(separatedBy: "→")
        if let last = arrowParts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty {
            let asciiParts = last.components(separatedBy: "->")
            if let asciiLast = asciiParts.last?.trimmingCharacters(in: .whitespacesAndNewlines), !asciiLast.isEmpty {
                return asciiLast
            }
            return last
        }
        return trimmed
    }

    /// Extracts a human-readable application key and display name when no custom resolver is supplied.
    public static func defaultApplicationIdentity(for connection: ConnectionTelemetry) -> (key: String, name: String) {
        let identifier = connection.sourceAppIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        let path = connection.sourceAppPath.trimmingCharacters(in: .whitespacesAndNewlines)

        let displayName: String = {
            if !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                for component in url.pathComponents.reversed() where component.hasSuffix(".app") {
                    let bundleName = String(component.dropLast(4))
                    if !bundleName.isEmpty {
                        return bundleName
                    }
                }
                let lastComponent = url.lastPathComponent
                if !lastComponent.isEmpty {
                    return lastComponent
                }
            }
            if !identifier.isEmpty {
                if let lastToken = identifier.split(separator: ".").last, !lastToken.isEmpty {
                    return String(lastToken)
                }
                return identifier
            }
            return "System"
        }()

        let key = !identifier.isEmpty ? identifier : (!path.isEmpty ? path : "system")
        return (key, displayName)
    }

    /// Evaluates whether a connection matches a leaderboard drill-down filter.
    public static func matchesFilter(
        _ connection: ConnectionTelemetry,
        dimension: ConnectionTrafficDimension,
        key: String,
        appKey: ((ConnectionTelemetry) -> String)? = nil
    ) -> Bool {
        switch dimension {
        case .application:
            let resolvedKey = appKey?(connection) ?? defaultApplicationIdentity(for: connection).key
            return resolvedKey == key
        case .host:
            return normalizedHost(from: connection.destination) == key.lowercased()
        case .outbound:
            return terminalOutbound(from: connection.proxyChain) == key
        }
    }

    /// Aggregates a snapshot of connections along the requested dimension in a single `O(N)` pass.
    public static func summarize(
        connections: [ConnectionTelemetry],
        dimension: ConnectionTrafficDimension,
        limit: Int = 100,
        appKeyAndName: ((ConnectionTelemetry) -> (key: String, name: String))? = nil
    ) -> ConnectionTrafficSummary {
        guard !connections.isEmpty else {
            return ConnectionTrafficSummary(
                dimension: dimension,
                entries: [],
                totalConnectionCount: 0,
                totalUploadBytes: 0,
                totalDownloadBytes: 0
            )
        }

        struct Bucket {
            let key: String
            let displayName: String
            var primarySubtitle: String
            var distinctSubtitles: Set<String>
            var primaryOutlet: String
            var distinctOutlets: Set<String>
            let sourceAppIdentifier: String
            let sourceAppPath: String
            var connectionCount: Int
            var uploadTotal: UInt64
            var downloadTotal: UInt64
            var latestStartedAtUnixMilliseconds: UInt64
            let sampleConnection: ConnectionTelemetry
        }

        var buckets: [String: Bucket] = [:]
        buckets.reserveCapacity(min(connections.count, 128))

        var grandUpload: UInt64 = 0
        var grandDownload: UInt64 = 0

        for connection in connections {
            grandUpload &+= connection.uploadTotal
            grandDownload &+= connection.downloadTotal

            let key: String
            let displayName: String
            let subtitleCandidate: String
            let outletCandidate = terminalOutbound(from: connection.proxyChain)

            switch dimension {
            case .application:
                let resolved = appKeyAndName?(connection) ?? defaultApplicationIdentity(for: connection)
                key = resolved.key
                displayName = resolved.name
                subtitleCandidate = connection.sourceAppIdentifier.isEmpty
                    ? outletCandidate
                    : connection.sourceAppIdentifier
            case .host:
                let host = normalizedHost(from: connection.destination)
                key = host
                displayName = host
                let ruleLabel = connection.rulePayload.isEmpty
                    ? connection.rule
                    : "\(connection.rule) · \(connection.rulePayload)"
                subtitleCandidate = ruleLabel.isEmpty ? outletCandidate : ruleLabel
            case .outbound:
                let outbound = outletCandidate
                key = outbound
                displayName = outbound
                let chain = connection.proxyChain.trimmingCharacters(in: .whitespacesAndNewlines)
                subtitleCandidate = chain.isEmpty ? outbound : chain
            }

            if var existing = buckets[key] {
                existing.connectionCount += 1
                existing.uploadTotal &+= connection.uploadTotal
                existing.downloadTotal &+= connection.downloadTotal
                if connection.startedAtUnixMilliseconds > existing.latestStartedAtUnixMilliseconds {
                    existing.latestStartedAtUnixMilliseconds = connection.startedAtUnixMilliseconds
                }
                if !subtitleCandidate.isEmpty {
                    existing.distinctSubtitles.insert(subtitleCandidate)
                }
                if !outletCandidate.isEmpty {
                    existing.distinctOutlets.insert(outletCandidate)
                }
                buckets[key] = existing
            } else {
                buckets[key] = Bucket(
                    key: key,
                    displayName: displayName,
                    primarySubtitle: subtitleCandidate,
                    distinctSubtitles: subtitleCandidate.isEmpty ? [] : [subtitleCandidate],
                    primaryOutlet: outletCandidate,
                    distinctOutlets: outletCandidate.isEmpty ? [] : [outletCandidate],
                    sourceAppIdentifier: connection.sourceAppIdentifier,
                    sourceAppPath: connection.sourceAppPath,
                    connectionCount: 1,
                    uploadTotal: connection.uploadTotal,
                    downloadTotal: connection.downloadTotal,
                    latestStartedAtUnixMilliseconds: connection.startedAtUnixMilliseconds,
                    sampleConnection: connection
                )
            }
        }

        let grandTotalBytes = grandUpload &+ grandDownload
        let totalCount = connections.count
        let boundedLimit = max(1, limit)

        let sortedBuckets = buckets.values.sorted { lhs, rhs in
            let lhsBytes = lhs.uploadTotal &+ lhs.downloadTotal
            let rhsBytes = rhs.uploadTotal &+ rhs.downloadTotal
            if lhsBytes != rhsBytes {
                return lhsBytes > rhsBytes
            }
            if lhs.connectionCount != rhs.connectionCount {
                return lhs.connectionCount > rhs.connectionCount
            }
            if lhs.latestStartedAtUnixMilliseconds != rhs.latestStartedAtUnixMilliseconds {
                return lhs.latestStartedAtUnixMilliseconds > rhs.latestStartedAtUnixMilliseconds
            }
            return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
        }

        let entries: [ConnectionTrafficEntry] = sortedBuckets.prefix(boundedLimit).map { bucket in
            let entryBytes = bucket.uploadTotal &+ bucket.downloadTotal
            let share: Double
            if grandTotalBytes > 0 {
                share = Double(entryBytes) / Double(grandTotalBytes)
            } else if totalCount > 0 {
                share = Double(bucket.connectionCount) / Double(totalCount)
            } else {
                share = 0
            }

            let outletSummary: String
            if bucket.distinctOutlets.count <= 1 {
                outletSummary = bucket.primaryOutlet
            } else {
                outletSummary = "\(bucket.primaryOutlet) +\(bucket.distinctOutlets.count - 1)"
            }

            let subtitle: String
            if bucket.distinctSubtitles.count <= 1 || dimension == .application {
                subtitle = bucket.primarySubtitle
            } else {
                subtitle = "\(bucket.primarySubtitle) +\(bucket.distinctSubtitles.count - 1)"
            }

            return ConnectionTrafficEntry(
                id: "\(dimension.rawValue):\(bucket.key)",
                dimension: dimension,
                key: bucket.key,
                displayName: bucket.displayName,
                subtitle: subtitle,
                sourceAppIdentifier: bucket.sourceAppIdentifier,
                sourceAppPath: bucket.sourceAppPath,
                connectionCount: bucket.connectionCount,
                uploadTotal: bucket.uploadTotal,
                downloadTotal: bucket.downloadTotal,
                latestStartedAtUnixMilliseconds: bucket.latestStartedAtUnixMilliseconds,
                outletSummary: outletSummary,
                sampleConnection: bucket.sampleConnection,
                shareOfTotal: share
            )
        }

        return ConnectionTrafficSummary(
            dimension: dimension,
            entries: entries,
            totalConnectionCount: totalCount,
            totalUploadBytes: grandUpload,
            totalDownloadBytes: grandDownload
        )
    }
}

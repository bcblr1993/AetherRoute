import Darwin
import Foundation

/// Strict RFC 2544 / Clash Fake-IPv4 (`198.18.0.0/15`) matcher and normalizer.
public enum FakeIPAddressMatcher {
    /// Returns `true` iff `address` is a valid IPv4 literal inside `198.18.0.0/15`
    /// (`198.18.0.0` through `198.19.255.255`).
    public static func isFakeIP(_ address: String) -> Bool {
        normalizeFakeIP(address) != nil
    }

    /// Trims and validates an IPv4 address in `198.18.0.0/15`, returning its
    /// canonical dotted-quad representation, or `nil` if outside the pool or invalid.
    public static func normalizeFakeIP(_ address: String) -> String? {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var ipv4 = in_addr()
        guard trimmed.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 else {
            return nil
        }
        let isInPool = withUnsafeBytes(of: ipv4) { bytes -> Bool in
            bytes.count == 4 && bytes[0] == 198 && (bytes[1] & 0xFE) == 18
        }
        guard isInPool else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &ipv4, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
            return trimmed
        }
        let nullIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let utf8Bytes = buffer[..<nullIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: utf8Bytes, as: UTF8.self)
    }
}

public enum DNSRecentQueryType: String, CaseIterable, Codable, Equatable, Sendable {
    case a = "A"
    case aaaa = "AAAA"
    case https = "HTTPS"
    case ptr = "PTR"
}

public enum DNSRecentQueryKind: String, CaseIterable, Codable, Equatable, Sendable {
    case fakeIP
    case direct
    case rejected
    case failed
}

public enum DNSRecentQueryFilter: String, CaseIterable, Equatable, Sendable {
    case all
    case fakeIP
    case direct
    case rejectedOrFailed

    public func matches(_ record: DNSRecentQueryRecord) -> Bool {
        switch self {
        case .all:
            true
        case .fakeIP:
            record.kind == .fakeIP
        case .direct:
            record.kind == .direct
        case .rejectedOrFailed:
            record.kind == .rejected || record.kind == .failed
        }
    }
}

public enum DNSResolvedPolicyKind: String, Codable, Equatable, Sendable {
    case direct
    case reject
    case rejectDrop
}

public struct DNSRecentQueryRecord: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let domain: String
    public let queryType: DNSRecentQueryType
    public let resolvedValue: String
    public let kind: DNSRecentQueryKind
    public let upstreamLabel: String
    public let latencyMs: Int?
    public let sourceApp: String?
    public let matchedRuleSummary: String?
    public let matchedRouteTarget: String?

    public var resolvedPolicyKind: DNSResolvedPolicyKind? {
        switch resolvedValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DIRECT":
            return .direct
        case "REJECT":
            return .reject
        case "REJECT-DROP":
            return .rejectDrop
        default:
            return nil
        }
    }

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        domain: String,
        queryType: DNSRecentQueryType,
        resolvedValue: String,
        kind: DNSRecentQueryKind,
        upstreamLabel: String,
        latencyMs: Int? = nil,
        sourceApp: String? = nil,
        matchedRuleSummary: String? = nil,
        matchedRouteTarget: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.domain = domain
        self.queryType = queryType
        self.resolvedValue = resolvedValue
        self.kind = kind
        self.upstreamLabel = upstreamLabel
        self.latencyMs = latencyMs
        self.sourceApp = sourceApp
        self.matchedRuleSummary = matchedRuleSummary
        self.matchedRouteTarget = matchedRouteTarget
    }
}

public struct FakeIPReverseLookupMatch: Equatable, Sendable {
    public let fakeIP: String
    public let domain: String
    public let record: DNSRecentQueryRecord
    public let timestamp: Date

    public init(
        fakeIP: String,
        domain: String,
        record: DNSRecentQueryRecord,
        timestamp: Date
    ) {
        self.fakeIP = fakeIP
        self.domain = domain
        self.record = record
        self.timestamp = timestamp
    }
}

/// Bounded ring-buffer store of recent DNS queries and an O(1) Fake-IP (`198.18.0.0/15`)
/// reverse lookup index. Strictly capped to stay well inside AetherRoute's memory budget.
public struct DNSRecentQueryStore: Equatable, Sendable {
    public static let maxEntries: Int = 64
    public static let maxFakeIPMappings: Int = 256
    public static let maxInactiveConnectionKeys: Int = 256

    public let capacity: Int
    public private(set) var entries: [DNSRecentQueryRecord]
    private var fakeIPTable: [String: FakeIPReverseLookupMatch]
    private var activeConnectionKeys: Set<String>
    private var inactiveConnectionLRU: [String]
    private var inactiveConnectionKeySet: Set<String>
    private var suppressedFlowSignatures: Set<String>

    public init(capacity: Int = DNSRecentQueryStore.maxEntries) {
        self.capacity = min(max(capacity, 1), Self.maxEntries)
        self.entries = []
        self.fakeIPTable = [:]
        self.activeConnectionKeys = []
        self.inactiveConnectionLRU = []
        self.inactiveConnectionKeySet = []
        self.suppressedFlowSignatures = []
    }

    public var count: Int { entries.count }
    public var isEmpty: Bool { entries.isEmpty }
    public var fakeIPMappingCount: Int { fakeIPTable.count }

    public mutating func record(_ entry: DNSRecentQueryRecord) {
        entries.insert(entry, at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }

        if let normalizedFakeIP = FakeIPAddressMatcher.normalizeFakeIP(entry.resolvedValue),
           !entry.domain.isEmpty,
           !FakeIPAddressMatcher.isFakeIP(entry.domain) {
            registerFakeIPMapping(fakeIP: normalizedFakeIP, domain: entry.domain, record: entry)
        }
    }

    public mutating func registerFakeIPMapping(
        fakeIP: String,
        domain: String,
        record: DNSRecentQueryRecord
    ) {
        guard let normalizedIP = FakeIPAddressMatcher.normalizeFakeIP(fakeIP) else { return }
        let cleanDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanDomain.isEmpty, !FakeIPAddressMatcher.isFakeIP(cleanDomain) else { return }

        fakeIPTable[normalizedIP] = FakeIPReverseLookupMatch(
            fakeIP: normalizedIP,
            domain: cleanDomain,
            record: record,
            timestamp: record.timestamp
        )

        if fakeIPTable.count > Self.maxFakeIPMappings,
           let oldestKey = fakeIPTable.min(by: { $0.value.timestamp < $1.value.timestamp })?.key {
            fakeIPTable.removeValue(forKey: oldestKey)
        }
    }

    public func entries(matching filter: DNSRecentQueryFilter) -> [DNSRecentQueryRecord] {
        guard filter != .all else { return entries }
        return entries.filter { filter.matches($0) }
    }

    public func count(matching filter: DNSRecentQueryFilter) -> Int {
        guard filter != .all else { return entries.count }
        return entries.reduce(into: 0) { partial, record in
            if filter.matches(record) {
                partial += 1
            }
        }
    }

    /// O(1) Fake-IP reverse lookup against the bounded in-app mapping table.
    public func reverseLookup(fakeIP: String) -> FakeIPReverseLookupMatch? {
        guard let normalized = FakeIPAddressMatcher.normalizeFakeIP(fakeIP) else {
            return nil
        }
        return fakeIPTable[normalized]
    }

    public mutating func clear(suppressingActiveConnections connections: [ConnectionTelemetry] = []) {
        entries.removeAll(keepingCapacity: false)
        fakeIPTable.removeAll(keepingCapacity: false)
        suppressedFlowSignatures.formUnion(activeConnectionKeys)
        suppressedFlowSignatures.formUnion(inactiveConnectionKeySet)
        for connection in connections {
            if let key = Self.connectionDedupeKey(for: connection) {
                activeConnectionKeys.insert(key)
                suppressedFlowSignatures.insert(key)
            }
        }
        let inactiveSuppressed = suppressedFlowSignatures.subtracting(activeConnectionKeys)
        for key in inactiveSuppressed.sorted() where !inactiveConnectionKeySet.contains(key) {
            appendInactiveConnectionKey(key)
        }
        suppressedFlowSignatures = activeConnectionKeys.union(inactiveConnectionKeySet)
    }

    public mutating func clearAll() {
        clear()
    }

    /// Converts and records a `DNSLookupReport` produced by `DNSLookupInspector`,
    /// indexing any returned Fake-IP (`198.18.0.0/15`) addresses for O(1) reverse lookup.
    @discardableResult
    public mutating func recordLookupReport(
        _ report: DNSLookupReport,
        runtimePolicy: DNSRuntimePolicy? = nil,
        timestamp: Date = Date(),
        sourceApp: String? = nil
    ) -> DNSRecentQueryRecord {
        let fakeIPs = report.resolvedAddresses.compactMap { FakeIPAddressMatcher.normalizeFakeIP($0) }
        let isRejected: Bool = {
            guard let target = report.matchedRouteTarget?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() else {
                return false
            }
            return target == "REJECT" || target == "REJECT-DROP"
        }()

        let kind: DNSRecentQueryKind
        if isRejected {
            kind = .rejected
        } else if report.containsFakeIPAddress || !fakeIPs.isEmpty {
            kind = .fakeIP
        } else if report.resolvedAddresses.isEmpty && report.matchedCustomHostIP == nil {
            kind = .failed
        } else {
            kind = .direct
        }

        let queryType: DNSRecentQueryType = {
            if FakeIPAddressMatcher.isFakeIP(report.normalizedHost) {
                return .ptr
            }
            if !report.resolvedAddresses.isEmpty,
               report.resolvedAddresses.allSatisfy({ $0.contains(":") }) {
                return .aaaa
            }
            return .a
        }()

        let resolvedValue: String = {
            if isRejected {
                return report.matchedRouteTarget ?? "REJECT"
            }
            if let firstFakeIP = fakeIPs.first {
                return firstFakeIP
            }
            if let firstAddress = report.resolvedAddresses.first {
                return firstAddress
            }
            if let hostIP = report.matchedCustomHostIP {
                return hostIP
            }
            return ""
        }()

        let upstreamLabel: String = {
            if report.matchedCustomHostIP != nil {
                return "Hosts"
            }
            if isRejected {
                return "Rule Policy"
            }
            switch report.effectiveMode {
            case .fakeIP:
                return runtimePolicy?.resolutionMode == .fakeIP ? "Fake-IP (Policy)" : "Fake-IP"
            case .redirHost:
                return "Redir-Host"
            case .normal, .unsupported:
                return "System DNS"
            }
        }()

        let record = DNSRecentQueryRecord(
            timestamp: timestamp,
            domain: report.normalizedHost,
            queryType: queryType,
            resolvedValue: resolvedValue,
            kind: kind,
            upstreamLabel: upstreamLabel,
            latencyMs: report.latencyMilliseconds,
            sourceApp: sourceApp,
            matchedRuleSummary: report.matchedRuleSummary,
            matchedRouteTarget: report.matchedRouteTarget
        )

        self.record(record)
        for fakeIP in fakeIPs {
            registerFakeIPMapping(fakeIP: fakeIP, domain: report.normalizedHost, record: record)
        }
        return record
    }

    public static func connectionDedupeKey(for connection: ConnectionTelemetry) -> String? {
        let destination = DNSLookupInspector.normalizeHost(connection.destination)
            ?? connection.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !destination.isEmpty else { return nil }

        let payloadTrimmed = connection.rulePayload.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasMeasuredDNS = connection.dnsDurationMilliseconds != nil
        let hasFakeIP = FakeIPAddressMatcher.normalizeFakeIP(destination) != nil
            || FakeIPAddressMatcher.normalizeFakeIP(payloadTrimmed) != nil
        guard hasMeasuredDNS || hasFakeIP else { return nil }

        return "\(connection.startedAtUnixMilliseconds)|\(destination)|\(payloadTrimmed)|\(connection.sourceAppIdentifier)"
    }

    /// Ingests active `ConnectionTelemetry` snapshots into the recent DNS store and
    /// Fake-IP reverse lookup index without touching `Core/Engine` FFI. Deduplicates
    /// previously seen connections using active-set retention plus bounded LRU for
    /// closed flows so long-lived flows stay deduplicated past 256 flows.
    public mutating func ingestConnections(
        _ connections: [ConnectionTelemetry],
        runtimePolicy: DNSRuntimePolicy? = nil,
        now: Date = Date()
    ) {
        var currentActiveKeys: Set<String> = []
        currentActiveKeys.reserveCapacity(connections.count)

        for connection in connections {
            let destination = DNSLookupInspector.normalizeHost(connection.destination)
                ?? connection.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !destination.isEmpty else { continue }

            let payloadTrimmed = connection.rulePayload.trimmingCharacters(in: .whitespacesAndNewlines)
            let destFakeIP = FakeIPAddressMatcher.normalizeFakeIP(destination)
            let payloadFakeIP = FakeIPAddressMatcher.normalizeFakeIP(payloadTrimmed)

            let hasMeasuredDNS = connection.dnsDurationMilliseconds != nil
            let hasFakeIP = destFakeIP != nil || payloadFakeIP != nil
            guard hasMeasuredDNS || hasFakeIP else { continue }

            let dedupeKey = "\(connection.startedAtUnixMilliseconds)|\(destination)|\(payloadTrimmed)|\(connection.sourceAppIdentifier)"
            currentActiveKeys.insert(dedupeKey)

            let alreadySeen = activeConnectionKeys.contains(dedupeKey)
                || inactiveConnectionKeySet.contains(dedupeKey)
                || suppressedFlowSignatures.contains(dedupeKey)
            if inactiveConnectionKeySet.contains(dedupeKey) {
                removeInactiveConnectionKey(dedupeKey)
            }
            if alreadySeen {
                continue
            }

            let timestamp: Date = connection.startedAtUnixMilliseconds > 0
                ? Date(timeIntervalSince1970: Double(connection.startedAtUnixMilliseconds) / 1_000.0)
                : now

            let chainTrimmed = connection.proxyChain.trimmingCharacters(in: .whitespacesAndNewlines)
            let chainUpper = chainTrimmed.uppercased()
            let isRejected = chainUpper.contains("REJECT")
            let kind: DNSRecentQueryKind = if isRejected {
                .rejected
            } else if hasFakeIP {
                .fakeIP
            } else {
                .direct
            }

            let resolvedValue: String = if let payloadFakeIP {
                payloadFakeIP
            } else if let destFakeIP {
                destFakeIP
            } else if isRejected {
                chainUpper == "REJECT-DROP" ? "REJECT-DROP" : "REJECT"
            } else if !chainTrimmed.isEmpty {
                chainUpper == "DIRECT" ? "DIRECT" : chainTrimmed
            } else {
                "DIRECT"
            }

            let domain: String = {
                if destFakeIP != nil,
                   !payloadTrimmed.isEmpty,
                   !FakeIPAddressMatcher.isFakeIP(payloadTrimmed),
                   let normalizedPayload = DNSLookupInspector.normalizeHost(payloadTrimmed) {
                    return normalizedPayload
                }
                return destination
            }()

            let sourceApp = connection.sourceAppIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            let ruleSummary: String? = {
                let rule = connection.rule.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !rule.isEmpty else { return nil }
                return payloadTrimmed.isEmpty ? rule : "\(rule) \(payloadTrimmed)"
            }()

            let upstreamLabel: String = {
                if isRejected {
                    return "Rule Policy"
                }
                if kind == .fakeIP {
                    return "Fake-IP"
                }
                return "System DNS"
            }()

            let record = DNSRecentQueryRecord(
                timestamp: timestamp,
                domain: domain,
                queryType: destFakeIP != nil ? .ptr : .a,
                resolvedValue: resolvedValue,
                kind: kind,
                upstreamLabel: upstreamLabel,
                latencyMs: connection.dnsDurationMilliseconds.map(Int.init),
                sourceApp: sourceApp.isEmpty ? nil : sourceApp,
                matchedRuleSummary: ruleSummary,
                matchedRouteTarget: chainTrimmed.isEmpty ? nil : chainTrimmed
            )

            self.record(record)
            if let fakeIP = payloadFakeIP ?? destFakeIP {
                registerFakeIPMapping(fakeIP: fakeIP, domain: domain, record: record)
            }
        }

        let newlyClosed = activeConnectionKeys.subtracting(currentActiveKeys)
        if !newlyClosed.isEmpty {
            for closedKey in newlyClosed.sorted() {
                appendInactiveConnectionKey(closedKey)
            }
        }
        activeConnectionKeys = currentActiveKeys
    }

    private mutating func appendInactiveConnectionKey(_ key: String) {
        if inactiveConnectionKeySet.contains(key) {
            removeInactiveConnectionKey(key)
        }
        inactiveConnectionKeySet.insert(key)
        inactiveConnectionLRU.append(key)
        if inactiveConnectionLRU.count > Self.maxInactiveConnectionKeys {
            let overflow = inactiveConnectionLRU.count - Self.maxInactiveConnectionKeys
            for evicted in inactiveConnectionLRU.prefix(overflow) {
                inactiveConnectionKeySet.remove(evicted)
                suppressedFlowSignatures.remove(evicted)
            }
            inactiveConnectionLRU.removeFirst(overflow)
        }
    }

    private mutating func removeInactiveConnectionKey(_ key: String) {
        inactiveConnectionKeySet.remove(key)
        if let index = inactiveConnectionLRU.firstIndex(of: key) {
            inactiveConnectionLRU.remove(at: index)
        }
    }
}

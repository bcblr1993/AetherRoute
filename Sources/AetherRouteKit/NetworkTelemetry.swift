import Foundation

public enum NetworkTelemetryTransport: UInt8, Sendable, Equatable {
    case tcp = 1
    case udp = 2
}

public struct ConnectionTelemetry: Sendable, Equatable {
    public let transport: NetworkTelemetryTransport
    public let destination: String
    public let destinationPort: UInt16
    public let uploadTotal: UInt64
    public let downloadTotal: UInt64
    public let startedAtUnixMilliseconds: UInt64
    public let rule: String
    public let rulePayload: String
    public let proxyChain: String
    /// The originating app's signing identifier (transparent proxy only).
    /// Empty when the engine reported none or spoke `ART1`.
    public let sourceAppIdentifier: String
    /// The originating executable's path. Empty when unknown.
    public let sourceAppPath: String

    public init(
        transport: NetworkTelemetryTransport,
        destination: String,
        destinationPort: UInt16,
        uploadTotal: UInt64,
        downloadTotal: UInt64,
        startedAtUnixMilliseconds: UInt64,
        rule: String,
        rulePayload: String,
        proxyChain: String,
        sourceAppIdentifier: String = "",
        sourceAppPath: String = ""
    ) {
        self.transport = transport
        self.destination = destination
        self.destinationPort = destinationPort
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.startedAtUnixMilliseconds = startedAtUnixMilliseconds
        self.rule = rule
        self.rulePayload = rulePayload
        self.proxyChain = proxyChain
        self.sourceAppIdentifier = sourceAppIdentifier
        self.sourceAppPath = sourceAppPath
    }
}

/// Lifetime traffic of one source app through one proxy chain, as the engine
/// reports it in `ART3`: closed connections plus the current bytes of active
/// ones. It covers every connection, not just the listed ones, and only
/// grows while the engine runs.
public struct TrafficTotalTelemetry: Sendable, Equatable {
    public let sourceAppIdentifier: String
    public let sourceAppPath: String
    /// Hops joined with " → ", like `ConnectionTelemetry.proxyChain`.
    public let proxyChain: String
    public let uploadTotal: UInt64
    public let downloadTotal: UInt64

    public init(
        sourceAppIdentifier: String,
        sourceAppPath: String,
        proxyChain: String,
        uploadTotal: UInt64,
        downloadTotal: UInt64
    ) {
        self.sourceAppIdentifier = sourceAppIdentifier
        self.sourceAppPath = sourceAppPath
        self.proxyChain = proxyChain
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
    }
}

public struct NetworkTelemetrySnapshot: Sendable, Equatable {
    public let uploadBytesPerSecond: UInt64
    public let downloadBytesPerSecond: UInt64
    public let uploadTotal: UInt64
    public let downloadTotal: UInt64
    public let memoryBytes: UInt64
    public let connections: [ConnectionTelemetry]
    /// Per-(app, chain) lifetime totals, largest first. Empty from an engine
    /// that predates `ART3`; `reportsTrafficTotals` tells the two apart.
    public let trafficTotals: [TrafficTotalTelemetry]
    public let reportsTrafficTotals: Bool

    public init(
        uploadBytesPerSecond: UInt64,
        downloadBytesPerSecond: UInt64,
        uploadTotal: UInt64,
        downloadTotal: UInt64,
        memoryBytes: UInt64,
        connections: [ConnectionTelemetry],
        trafficTotals: [TrafficTotalTelemetry] = [],
        reportsTrafficTotals: Bool? = nil
    ) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.memoryBytes = memoryBytes
        self.connections = connections
        self.trafficTotals = trafficTotals
        self.reportsTrafficTotals = reportsTrafficTotals ?? !trafficTotals.isEmpty
    }

    public static let empty = NetworkTelemetrySnapshot(
        uploadBytesPerSecond: 0,
        downloadBytesPerSecond: 0,
        uploadTotal: 0,
        downloadTotal: 0,
        memoryBytes: 0,
        connections: []
    )
}

public enum NetworkTelemetryCodecError: Error, Sendable, Equatable {
    case malformed
    case tooLarge
    case invalidString
}

/// Binary codec shared by both providers and the host. It has no source
/// address, user identity, resolved-IP, or internal UUID fields.
///
/// `ART1` carries four strings per connection. `ART2` (1.3.0) appends the
/// originating app's signing identifier and executable path, each at most
/// `maximumSourceAppBytes`. `ART3` (1.4.0) is `ART2` followed by the
/// per-(app, chain) lifetime totals: a `UInt32` count, then per total two
/// `UInt64` counters, three `UInt32` lengths and the identifier, path and
/// chain strings. The decoder accepts all three, so a host and an engine from
/// different builds still agree.
public enum NetworkTelemetryCodec {
    public enum Version: Sendable {
        case v1
        case v2
        case v3
    }

    public static let maximumConnections = 128
    public static let maximumStringBytes = 1_024
    public static let maximumSourceAppBytes = 512
    public static let maximumMessageBytes = 1_048_576
    public static let maximumTrafficTotals = 256
    /// The encoder keeps room for the provider-message header around it.
    static let encodedBudgetBytes = maximumMessageBytes - 64

    private static let magic: [UInt8] = [0x41, 0x52, 0x54, 0x31]
    private static let magicV2: [UInt8] = [0x41, 0x52, 0x54, 0x32]
    private static let magicV3: [UInt8] = [0x41, 0x52, 0x54, 0x33]
    private static let trafficTotalHeaderBytes = 28
    private static let headerBytes = 48
    private static let recordHeaderBytes = 44
    private static let sourceAppHeaderBytes = 8

    public static func encode(
        _ snapshot: NetworkTelemetrySnapshot,
        version: Version? = nil
    ) throws -> Data {
        // By default a snapshot is written in the newest form that keeps
        // everything it holds.
        let version = version ?? (snapshot.reportsTrafficTotals ? .v3 : .v2)
        guard snapshot.connections.count <= maximumConnections else {
            throw NetworkTelemetryCodecError.tooLarge
        }
        let includesSourceApp = version != .v1
        var output = Data(switch version {
        case .v1: magic
        case .v2: magicV2
        case .v3: magicV3
        })
        for value in [
            snapshot.uploadBytesPerSecond,
            snapshot.downloadBytesPerSecond,
            snapshot.uploadTotal,
            snapshot.downloadTotal,
            snapshot.memoryBytes,
        ] {
            appendUInt64(value, to: &output)
        }
        appendUInt32(UInt32(snapshot.connections.count), to: &output)
        for connection in snapshot.connections {
            let destination = try stringData(connection.destination, allowsEmpty: false)
            let rule = try stringData(connection.rule, allowsEmpty: true)
            let payload = try stringData(connection.rulePayload, allowsEmpty: true)
            let chain = try stringData(connection.proxyChain, allowsEmpty: true)
            var strings = [destination, rule, payload, chain]
            if includesSourceApp {
                strings.append(try stringData(
                    connection.sourceAppIdentifier,
                    allowsEmpty: true,
                    maximumBytes: maximumSourceAppBytes
                ))
                strings.append(try stringData(
                    connection.sourceAppPath,
                    allowsEmpty: true,
                    maximumBytes: maximumSourceAppBytes
                ))
            }
            output.append(connection.transport.rawValue)
            output.append(0)
            appendUInt16(connection.destinationPort, to: &output)
            appendUInt64(connection.uploadTotal, to: &output)
            appendUInt64(connection.downloadTotal, to: &output)
            appendUInt64(connection.startedAtUnixMilliseconds, to: &output)
            for value in strings {
                appendUInt32(UInt32(value.count), to: &output)
            }
            for value in strings {
                output.append(value)
            }
            guard output.count <= encodedBudgetBytes else {
                throw NetworkTelemetryCodecError.tooLarge
            }
        }
        if version == .v3 {
            try appendTrafficTotals(snapshot.trafficTotals, to: &output)
        }
        return output
    }

    /// Largest first, as the engine sends them; totals that would not fit the
    /// budget are left out instead of failing the whole sample.
    private static func appendTrafficTotals(
        _ totals: [TrafficTotalTelemetry],
        to output: inout Data
    ) throws {
        let countOffset = output.count
        appendUInt32(0, to: &output)
        var count: UInt32 = 0
        for total in totals.prefix(maximumTrafficTotals) {
            let strings = [
                try stringData(
                    total.sourceAppIdentifier,
                    allowsEmpty: true,
                    maximumBytes: maximumSourceAppBytes
                ),
                try stringData(
                    total.sourceAppPath,
                    allowsEmpty: true,
                    maximumBytes: maximumSourceAppBytes
                ),
                try stringData(total.proxyChain, allowsEmpty: true),
            ]
            let recordBytes = trafficTotalHeaderBytes + strings.reduce(0) { $0 + $1.count }
            guard output.count + recordBytes <= encodedBudgetBytes else { break }
            appendUInt64(total.uploadTotal, to: &output)
            appendUInt64(total.downloadTotal, to: &output)
            for value in strings {
                appendUInt32(UInt32(value.count), to: &output)
            }
            for value in strings {
                output.append(value)
            }
            count += 1
        }
        let countBytes: [UInt8] = [
            UInt8((count >> 24) & 0xff),
            UInt8((count >> 16) & 0xff),
            UInt8((count >> 8) & 0xff),
            UInt8(count & 0xff),
        ]
        output.replaceSubrange(
            (output.startIndex + countOffset)..<(output.startIndex + countOffset + 4),
            with: countBytes
        )
    }

    public static func decode(_ data: Data) throws -> NetworkTelemetrySnapshot {
        guard
            (headerBytes...maximumMessageBytes).contains(data.count)
        else { throw NetworkTelemetryCodecError.tooLarge }
        let bytes = [UInt8](data)
        let header = Array(bytes[0..<4])
        guard header == magic || header == magicV2 || header == magicV3 else {
            throw NetworkTelemetryCodecError.malformed
        }
        let includesTrafficTotals = header == magicV3
        let includesSourceApp = header != magic
        let recordBytes = recordHeaderBytes
            + (includesSourceApp ? sourceAppHeaderBytes : 0)
        guard
            let uploadRate = readUInt64(bytes, at: 4),
            let downloadRate = readUInt64(bytes, at: 12),
            let uploadTotal = readUInt64(bytes, at: 20),
            let downloadTotal = readUInt64(bytes, at: 28),
            let memoryBytes = readUInt64(bytes, at: 36),
            let count = readUInt32(bytes, at: 44),
            count <= maximumConnections
        else { throw NetworkTelemetryCodecError.malformed }

        var offset = headerBytes
        var connections: [ConnectionTelemetry] = []
        connections.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard
                offset + recordBytes <= bytes.count,
                let transport = NetworkTelemetryTransport(rawValue: bytes[offset]),
                bytes[offset + 1] == 0,
                let port = readUInt16(bytes, at: offset + 2),
                let upload = readUInt64(bytes, at: offset + 4),
                let download = readUInt64(bytes, at: offset + 12),
                let started = readUInt64(bytes, at: offset + 20),
                let destinationLength = readUInt32(bytes, at: offset + 28),
                let ruleLength = readUInt32(bytes, at: offset + 32),
                let payloadLength = readUInt32(bytes, at: offset + 36),
                let chainLength = readUInt32(bytes, at: offset + 40)
            else { throw NetworkTelemetryCodecError.malformed }
            var appIdentifierLength: UInt32 = 0
            var appPathLength: UInt32 = 0
            if includesSourceApp {
                guard
                    let identifier = readUInt32(bytes, at: offset + 44),
                    let path = readUInt32(bytes, at: offset + 48)
                else { throw NetworkTelemetryCodecError.malformed }
                appIdentifierLength = identifier
                appPathLength = path
            }
            offset += recordBytes
            let destination = try readString(
                bytes,
                offset: &offset,
                length: destinationLength,
                allowsEmpty: false
            )
            let rule = try readString(
                bytes,
                offset: &offset,
                length: ruleLength,
                allowsEmpty: true
            )
            let payload = try readString(
                bytes,
                offset: &offset,
                length: payloadLength,
                allowsEmpty: true
            )
            let chain = try readString(
                bytes,
                offset: &offset,
                length: chainLength,
                allowsEmpty: true
            )
            let appIdentifier = try readString(
                bytes,
                offset: &offset,
                length: appIdentifierLength,
                allowsEmpty: true,
                maximumBytes: maximumSourceAppBytes
            )
            let appPath = try readString(
                bytes,
                offset: &offset,
                length: appPathLength,
                allowsEmpty: true,
                maximumBytes: maximumSourceAppBytes
            )
            connections.append(
                ConnectionTelemetry(
                    transport: transport,
                    destination: destination,
                    destinationPort: port,
                    uploadTotal: upload,
                    downloadTotal: download,
                    startedAtUnixMilliseconds: started,
                    rule: rule,
                    rulePayload: payload,
                    proxyChain: chain,
                    sourceAppIdentifier: appIdentifier,
                    sourceAppPath: appPath
                )
            )
        }
        var trafficTotals: [TrafficTotalTelemetry] = []
        if includesTrafficTotals {
            guard
                let totalCount = readUInt32(bytes, at: offset),
                totalCount <= maximumTrafficTotals
            else { throw NetworkTelemetryCodecError.malformed }
            offset += 4
            trafficTotals.reserveCapacity(Int(totalCount))
            for _ in 0..<totalCount {
                guard
                    offset + trafficTotalHeaderBytes <= bytes.count,
                    let upload = readUInt64(bytes, at: offset),
                    let download = readUInt64(bytes, at: offset + 8),
                    let identifierLength = readUInt32(bytes, at: offset + 16),
                    let pathLength = readUInt32(bytes, at: offset + 20),
                    let chainLength = readUInt32(bytes, at: offset + 24)
                else { throw NetworkTelemetryCodecError.malformed }
                offset += trafficTotalHeaderBytes
                let identifier = try readString(
                    bytes,
                    offset: &offset,
                    length: identifierLength,
                    allowsEmpty: true,
                    maximumBytes: maximumSourceAppBytes
                )
                let path = try readString(
                    bytes,
                    offset: &offset,
                    length: pathLength,
                    allowsEmpty: true,
                    maximumBytes: maximumSourceAppBytes
                )
                let chain = try readString(
                    bytes,
                    offset: &offset,
                    length: chainLength,
                    allowsEmpty: true
                )
                trafficTotals.append(TrafficTotalTelemetry(
                    sourceAppIdentifier: identifier,
                    sourceAppPath: path,
                    proxyChain: chain,
                    uploadTotal: upload,
                    downloadTotal: download
                ))
            }
        }
        guard offset == bytes.count else {
            throw NetworkTelemetryCodecError.malformed
        }
        return NetworkTelemetrySnapshot(
            uploadBytesPerSecond: uploadRate,
            downloadBytesPerSecond: downloadRate,
            uploadTotal: uploadTotal,
            downloadTotal: downloadTotal,
            memoryBytes: memoryBytes,
            connections: connections,
            trafficTotals: trafficTotals,
            reportsTrafficTotals: includesTrafficTotals
        )
    }

    private static func stringData(
        _ value: String,
        allowsEmpty: Bool,
        maximumBytes: Int = maximumStringBytes
    ) throws -> Data {
        guard
            let data = value.data(using: .utf8),
            data.count <= maximumBytes,
            (allowsEmpty || !data.isEmpty),
            !data.contains(0)
        else { throw NetworkTelemetryCodecError.invalidString }
        return data
    }

    private static func readString(
        _ bytes: [UInt8],
        offset: inout Int,
        length: UInt32,
        allowsEmpty: Bool,
        maximumBytes: Int = maximumStringBytes
    ) throws -> String {
        guard length <= maximumBytes else {
            throw NetworkTelemetryCodecError.tooLarge
        }
        let (end, overflow) = offset.addingReportingOverflow(Int(length))
        guard
            !overflow,
            end <= bytes.count,
            (allowsEmpty || length > 0),
            !bytes[offset..<end].contains(0),
            let value = String(bytes: bytes[offset..<end], encoding: .utf8)
        else { throw NetworkTelemetryCodecError.invalidString }
        offset = end
        return value
    }

    private static func appendUInt16(_ value: UInt16, to data: inout Data) {
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt32(_ value: UInt32, to data: inout Data) {
        data.append(UInt8((value >> 24) & 0xff))
        data.append(UInt8((value >> 16) & 0xff))
        data.append(UInt8((value >> 8) & 0xff))
        data.append(UInt8(value & 0xff))
    }

    private static func appendUInt64(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 56, through: 0, by: -8) {
            data.append(UInt8((value >> UInt64(shift)) & 0xff))
        }
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16? {
        guard offset >= 0, offset + 2 <= bytes.count else { return nil }
        return UInt16(bytes[offset]) << 8 | UInt16(bytes[offset + 1])
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        return (0..<8).reduce(UInt64(0)) { partial, index in
            (partial << 8) | UInt64(bytes[offset + index])
        }
    }
}

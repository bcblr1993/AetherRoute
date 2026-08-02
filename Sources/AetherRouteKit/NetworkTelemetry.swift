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

    public init(
        transport: NetworkTelemetryTransport,
        destination: String,
        destinationPort: UInt16,
        uploadTotal: UInt64,
        downloadTotal: UInt64,
        startedAtUnixMilliseconds: UInt64,
        rule: String,
        rulePayload: String,
        proxyChain: String
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
    }
}

public struct NetworkTelemetrySnapshot: Sendable, Equatable {
    public let uploadBytesPerSecond: UInt64
    public let downloadBytesPerSecond: UInt64
    public let uploadTotal: UInt64
    public let downloadTotal: UInt64
    public let memoryBytes: UInt64
    public let connections: [ConnectionTelemetry]

    public init(
        uploadBytesPerSecond: UInt64,
        downloadBytesPerSecond: UInt64,
        uploadTotal: UInt64,
        downloadTotal: UInt64,
        memoryBytes: UInt64,
        connections: [ConnectionTelemetry]
    ) {
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadTotal = uploadTotal
        self.downloadTotal = downloadTotal
        self.memoryBytes = memoryBytes
        self.connections = connections
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

/// Stable `ART1` binary codec shared by both providers and the host. It has no
/// source address, user identity, resolved-IP, or internal UUID fields.
public enum NetworkTelemetryCodec {
    public static let maximumConnections = 128
    public static let maximumStringBytes = 1_024
    public static let maximumMessageBytes = 1_048_576

    private static let magic: [UInt8] = [0x41, 0x52, 0x54, 0x31]
    private static let headerBytes = 48
    private static let recordHeaderBytes = 44

    public static func encode(_ snapshot: NetworkTelemetrySnapshot) throws -> Data {
        guard snapshot.connections.count <= maximumConnections else {
            throw NetworkTelemetryCodecError.tooLarge
        }
        var output = Data(magic)
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
            output.append(connection.transport.rawValue)
            output.append(0)
            appendUInt16(connection.destinationPort, to: &output)
            appendUInt64(connection.uploadTotal, to: &output)
            appendUInt64(connection.downloadTotal, to: &output)
            appendUInt64(connection.startedAtUnixMilliseconds, to: &output)
            for value in [destination, rule, payload, chain] {
                appendUInt32(UInt32(value.count), to: &output)
            }
            output.append(destination)
            output.append(rule)
            output.append(payload)
            output.append(chain)
            guard output.count <= maximumMessageBytes else {
                throw NetworkTelemetryCodecError.tooLarge
            }
        }
        return output
    }

    public static func decode(_ data: Data) throws -> NetworkTelemetrySnapshot {
        guard
            (headerBytes...maximumMessageBytes).contains(data.count)
        else { throw NetworkTelemetryCodecError.tooLarge }
        let bytes = [UInt8](data)
        guard
            Array(bytes[0..<4]) == magic,
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
                offset + recordHeaderBytes <= bytes.count,
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
            offset += recordHeaderBytes
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
                    proxyChain: chain
                )
            )
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
            connections: connections
        )
    }

    private static func stringData(
        _ value: String,
        allowsEmpty: Bool
    ) throws -> Data {
        guard
            let data = value.data(using: .utf8),
            data.count <= maximumStringBytes,
            (allowsEmpty || !data.isEmpty),
            !data.contains(0)
        else { throw NetworkTelemetryCodecError.invalidString }
        return data
    }

    private static func readString(
        _ bytes: [UInt8],
        offset: inout Int,
        length: UInt32,
        allowsEmpty: Bool
    ) throws -> String {
        guard length <= maximumStringBytes else {
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

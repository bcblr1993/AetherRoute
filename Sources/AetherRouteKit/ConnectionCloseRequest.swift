import Foundation

/// Which active connections a close request selects. Every case is expressed
/// in the privacy-scoped fields the host already receives in telemetry, so the
/// host never needs an internal connection identifier from the engine.
public enum ConnectionCloseRequest: Sendable, Equatable {
    /// Every active connection.
    case all
    /// The connections one local app opened. Empty strings select connections
    /// whose app is unknown.
    case sourceApp(signingIdentifier: String, executablePath: String)
    /// The connections that match one telemetry row.
    case connection(
        transport: NetworkTelemetryTransport,
        destination: String,
        port: UInt16,
        startedAtUnixMilliseconds: UInt64
    )
    /// The connections whose proxy chain passes through the named group or
    /// proxy, so that switching a group's member drops what still uses the
    /// old one.
    case proxyChainMember(String)
    /// The connections of any of several apps, each matched like
    /// `sourceApp`, in one request.
    case sourceApps([ConnectionCloseApp])

    /// The request that closes exactly the connections behind one telemetry
    /// row.
    public init(row connection: ConnectionTelemetry) {
        self = .connection(
            transport: connection.transport,
            destination: connection.destination,
            port: connection.destinationPort,
            startedAtUnixMilliseconds: connection.startedAtUnixMilliseconds
        )
    }

    /// As few requests as close every listed app: one `sourceApp` for a
    /// single app, otherwise `sourceApps` batches that each fit the engine's
    /// request bound. Duplicates are sent once.
    public static func closing(apps: [ConnectionCloseApp]) -> [ConnectionCloseRequest] {
        var seen = Set<ConnectionCloseApp>()
        let unique = apps.filter { seen.insert($0).inserted }
        if unique.count == 1, let app = unique.first {
            return [.sourceApp(
                signingIdentifier: app.signingIdentifier,
                executablePath: app.executablePath
            )]
        }
        var requests: [ConnectionCloseRequest] = []
        var batch: [ConnectionCloseApp] = []
        // Magic, kind and count.
        var batchBytes = 7
        for app in unique {
            let bytes = 4 + app.signingIdentifier.utf8.count + app.executablePath.utf8.count
            guard 7 + bytes <= ConnectionCloseRequestCodec.maximumBytes else { continue }
            if !batch.isEmpty,
               batchBytes + bytes > ConnectionCloseRequestCodec.maximumBytes
                || batch.count == ConnectionCloseRequestCodec.maximumApps {
                requests.append(.sourceApps(batch))
                batch = []
                batchBytes = 7
            }
            batch.append(app)
            batchBytes += bytes
        }
        if !batch.isEmpty { requests.append(.sourceApps(batch)) }
        return requests
    }

    /// The request that closes every connection of one app, as telemetry
    /// reports it.
    public init(appOf connection: ConnectionTelemetry) {
        self = .sourceApp(
            signingIdentifier: connection.sourceAppIdentifier,
            executablePath: connection.sourceAppPath
        )
    }
}

/// One app in a `sourceApps` close request.
public struct ConnectionCloseApp: Sendable, Hashable {
    public let signingIdentifier: String
    public let executablePath: String

    public init(signingIdentifier: String, executablePath: String) {
        self.signingIdentifier = signingIdentifier
        self.executablePath = executablePath
    }

    public init(of connection: ConnectionTelemetry) {
        self.init(
            signingIdentifier: connection.sourceAppIdentifier,
            executablePath: connection.sourceAppPath
        )
    }
}

public enum ConnectionCloseRequestError: Error, Sendable, Equatable {
    case malformed
    case tooLarge
}

/// The engine's `ARC1` wire format, shared by both providers. Integers are
/// big-endian like the telemetry the host reads; strings are a `UInt16`
/// length followed by UTF-8 bytes. The engine requires exact consumption and
/// rejects anything above `maximumBytes`.
public enum ConnectionCloseRequestCodec {
    public static let maximumBytes = 4_096
    /// The most apps one `sourceApps` request may name.
    public static let maximumApps = 64
    private static let magic: [UInt8] = [0x41, 0x52, 0x43, 0x31]

    public static func encode(_ request: ConnectionCloseRequest) throws -> Data {
        var output = Data(magic)
        switch request {
        case .all:
            output.append(0)
        case let .sourceApp(signingIdentifier, executablePath):
            output.append(1)
            try appendString(signingIdentifier, to: &output, allowsEmpty: true)
            try appendString(executablePath, to: &output, allowsEmpty: true)
        case let .connection(transport, destination, port, started):
            output.append(2)
            output.append(transport.rawValue)
            try appendString(destination, to: &output, allowsEmpty: false)
            output.append(UInt8(port >> 8))
            output.append(UInt8(port & 0xff))
            guard started <= UInt64(Int64.max) else {
                throw ConnectionCloseRequestError.malformed
            }
            for shift in stride(from: 56, through: 0, by: -8) {
                output.append(UInt8((started >> UInt64(shift)) & 0xff))
            }
        case let .proxyChainMember(name):
            output.append(3)
            try appendString(name, to: &output, allowsEmpty: false)
        case let .sourceApps(apps):
            guard (1...maximumApps).contains(apps.count) else {
                throw ConnectionCloseRequestError.malformed
            }
            output.append(4)
            output.append(UInt8(apps.count >> 8))
            output.append(UInt8(apps.count & 0xff))
            for app in apps {
                try appendString(app.signingIdentifier, to: &output, allowsEmpty: true)
                try appendString(app.executablePath, to: &output, allowsEmpty: true)
            }
        }
        guard output.count <= maximumBytes else {
            throw ConnectionCloseRequestError.tooLarge
        }
        return output
    }

    /// Accepts only what `encode` produces, so the provider can validate a
    /// request before it reaches the engine.
    public static func isValid(_ data: Data) -> Bool {
        guard (5...maximumBytes).contains(data.count) else { return false }
        let bytes = [UInt8](data)
        guard Array(bytes[0..<4]) == magic else { return false }
        var offset = 5
        func string(allowsEmpty: Bool) -> Bool {
            guard offset + 2 <= bytes.count else { return false }
            let length = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard
                allowsEmpty || length > 0,
                offset + length <= bytes.count,
                String(bytes: bytes[offset..<(offset + length)], encoding: .utf8) != nil
            else { return false }
            offset += length
            return true
        }
        switch bytes[4] {
        case 0:
            break
        case 1:
            guard string(allowsEmpty: true), string(allowsEmpty: true) else {
                return false
            }
        case 2:
            guard offset < bytes.count,
                  NetworkTelemetryTransport(rawValue: bytes[offset]) != nil
            else { return false }
            offset += 1
            guard string(allowsEmpty: false), offset + 10 <= bytes.count else {
                return false
            }
            offset += 10
        case 3:
            guard string(allowsEmpty: false) else { return false }
        case 4:
            guard offset + 2 <= bytes.count else { return false }
            let count = Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
            offset += 2
            guard (1...maximumApps).contains(count) else { return false }
            for _ in 0..<count {
                guard string(allowsEmpty: true), string(allowsEmpty: true) else {
                    return false
                }
            }
        default:
            return false
        }
        return offset == bytes.count
    }

    private static func appendString(
        _ value: String,
        to output: inout Data,
        allowsEmpty: Bool
    ) throws {
        let data = Data(value.utf8)
        guard
            allowsEmpty || !data.isEmpty,
            data.count <= Int(UInt16.max)
        else { throw ConnectionCloseRequestError.malformed }
        output.append(UInt8(data.count >> 8))
        output.append(UInt8(data.count & 0xff))
        output.append(data)
    }
}

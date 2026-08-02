import Foundation

public enum FlowTransport: UInt8, Sendable, Hashable {
    case tcp = 1
    case udp = 2
}

public enum FlowEndpointHost: Sendable, Hashable {
    case ipv4([UInt8])
    case ipv6([UInt8], scopeID: UInt32)
    case name(String)
}

public struct FlowEndpoint: Sendable, Hashable {
    public let host: FlowEndpointHost
    public let port: UInt16
    public let transport: FlowTransport

    public init(
        host: FlowEndpointHost,
        port: UInt16,
        transport: FlowTransport
    ) {
        self.host = Self.canonicalize(host)
        self.port = port
        self.transport = transport
    }

    /// DNS matching is defined over one canonical representation at the
    /// Swift/Rust boundary. ASCII case and a single root-label dot are not
    /// semantically significant, but leaving either in place could bypass a
    /// case-sensitive DOMAIN or DOMAIN-SUFFIX rule in the routing engine.
    private static func canonicalize(
        _ host: FlowEndpointHost
    ) -> FlowEndpointHost {
        guard case let .name(name) = host else { return host }

        var bytes = Array(name.utf8)
        for index in bytes.indices where (65...90).contains(bytes[index]) {
            bytes[index] += 32
        }
        if bytes.last == UInt8(ascii: "."),
           (bytes.count == 1 || bytes[bytes.count - 2] != UInt8(ascii: "."))
        {
            bytes.removeLast()
        }
        return .name(String(decoding: bytes, as: UTF8.self))
    }

    @discardableResult
    public func validated() throws -> FlowEndpoint {
        try FlowEndpointCodec.validate(self)
        return self
    }
}

public enum FlowEndpointCodecError: Error, Sendable, Equatable {
    case unsupportedVersion(UInt8)
    case unsupportedTransport(UInt8)
    case unsupportedHostKind(UInt8)
    case invalidPort
    case invalidIPv4Length(Int)
    case invalidIPv6Length(Int)
    case unexpectedScopeID(hostKind: UInt8, scopeID: UInt32)
    case invalidName
    case invalidPayloadLength
}

/// A compact, versioned representation for passing endpoints across a future
/// Swift/Rust boundary. This codec has no FFI dependency and is intentionally
/// strict so malformed native values never reach the protocol engine.
public enum FlowEndpointCodec {
    public static let version: UInt8 = 1
    public static let maximumNameBytes = 253
    private static let headerBytes = 11
    /// Hard allocation boundary for any encoded endpoint received over FFI.
    /// Validate this before copying a borrowed native buffer.
    public static let maximumEncodedBytes = headerBytes + maximumNameBytes

    public static func encode(_ endpoint: FlowEndpoint) throws -> Data {
        try validate(endpoint)

        let hostKind: UInt8
        let payload: [UInt8]
        let scopeID: UInt32
        switch endpoint.host {
        case let .ipv4(bytes):
            hostKind = 1
            payload = bytes
            scopeID = 0
        case let .ipv6(bytes, ipv6ScopeID):
            hostKind = 2
            payload = bytes
            scopeID = ipv6ScopeID
        case let .name(name):
            hostKind = 3
            payload = Array(name.utf8)
            scopeID = 0
        }

        let payloadLength = UInt16(payload.count)
        return Data([
            version,
            endpoint.transport.rawValue,
            hostKind,
            UInt8(endpoint.port >> 8),
            UInt8(endpoint.port & 0x00ff),
            UInt8((scopeID >> 24) & 0x000000ff),
            UInt8((scopeID >> 16) & 0x000000ff),
            UInt8((scopeID >> 8) & 0x000000ff),
            UInt8(scopeID & 0x000000ff),
            UInt8(payloadLength >> 8),
            UInt8(payloadLength & 0x00ff),
        ] + payload)
    }

    public static func decode(_ data: Data) throws -> FlowEndpoint {
        let bytes = Array(data)
        guard bytes.count >= headerBytes else {
            throw FlowEndpointCodecError.invalidPayloadLength
        }
        guard bytes[0] == version else {
            throw FlowEndpointCodecError.unsupportedVersion(bytes[0])
        }
        guard let transport = FlowTransport(rawValue: bytes[1]) else {
            throw FlowEndpointCodecError.unsupportedTransport(bytes[1])
        }

        let port = UInt16(bytes[3]) << 8 | UInt16(bytes[4])
        guard port != 0 else {
            throw FlowEndpointCodecError.invalidPort
        }
        let scopeID =
            UInt32(bytes[5]) << 24
            | UInt32(bytes[6]) << 16
            | UInt32(bytes[7]) << 8
            | UInt32(bytes[8])
        let payloadLength = Int(bytes[9]) << 8 | Int(bytes[10])
        guard bytes.count == headerBytes + payloadLength else {
            throw FlowEndpointCodecError.invalidPayloadLength
        }
        let payload = Array(bytes[headerBytes...])

        let host: FlowEndpointHost
        switch bytes[2] {
        case 1:
            guard scopeID == 0 else {
                throw FlowEndpointCodecError.unexpectedScopeID(
                    hostKind: bytes[2],
                    scopeID: scopeID
                )
            }
            guard payload.count == 4 else {
                throw FlowEndpointCodecError.invalidIPv4Length(payload.count)
            }
            host = .ipv4(payload)
        case 2:
            guard payload.count == 16 else {
                throw FlowEndpointCodecError.invalidIPv6Length(payload.count)
            }
            host = .ipv6(payload, scopeID: scopeID)
        case 3:
            guard scopeID == 0 else {
                throw FlowEndpointCodecError.unexpectedScopeID(
                    hostKind: bytes[2],
                    scopeID: scopeID
                )
            }
            guard
                !payload.isEmpty,
                payload.count <= maximumNameBytes,
                !payload.contains(0),
                let name = String(bytes: payload, encoding: .utf8)
            else {
                throw FlowEndpointCodecError.invalidName
            }
            host = .name(name)
        default:
            throw FlowEndpointCodecError.unsupportedHostKind(bytes[2])
        }

        let endpoint = FlowEndpoint(
            host: host,
            port: port,
            transport: transport
        )
        try validate(endpoint)
        return endpoint
    }

    public static func validate(_ endpoint: FlowEndpoint) throws {
        guard endpoint.port != 0 else {
            throw FlowEndpointCodecError.invalidPort
        }

        switch endpoint.host {
        case let .ipv4(bytes):
            guard bytes.count == 4 else {
                throw FlowEndpointCodecError.invalidIPv4Length(bytes.count)
            }
        case let .ipv6(bytes, _):
            guard bytes.count == 16 else {
                throw FlowEndpointCodecError.invalidIPv6Length(bytes.count)
            }
        case let .name(name):
            try validateName(name)
        }
    }

    private static func validateName(_ name: String) throws {
        let bytes = Array(name.utf8)
        guard
            !bytes.isEmpty,
            bytes.count <= maximumNameBytes,
            bytes.allSatisfy({ $0 < 0x80 })
        else {
            throw FlowEndpointCodecError.invalidName
        }

        let unqualified = name.last == "." ? name.dropLast() : name[...]
        guard !unqualified.isEmpty else {
            throw FlowEndpointCodecError.invalidName
        }
        let labels = unqualified.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        for label in labels {
            guard
                (1...63).contains(label.utf8.count),
                label.first != "-",
                label.last != "-",
                label.utf8.allSatisfy({ byte in
                    (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                        || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                        || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                        || byte == UInt8(ascii: "-")
                })
            else {
                throw FlowEndpointCodecError.invalidName
            }
        }
    }
}

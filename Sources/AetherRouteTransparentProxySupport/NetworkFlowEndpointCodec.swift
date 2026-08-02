import AetherRouteKit
import Darwin
import Foundation
import Network

public enum NetworkFlowEndpointCodecError: Error, Sendable, Equatable {
    case unsupportedEndpoint
    case invalidPort
    case invalidAddress
    case invalidScopeID(Int)
}

/// Lossless conversion between Network.framework endpoints and the versioned
/// Swift/Rust flow endpoint. IP endpoints use `sockaddr` so an IPv6 scope ID is
/// preserved exactly; DNS endpoints remain names for DOMAIN routing.
public enum NetworkFlowEndpointCodec {
    public static func decode(
        _ endpoint: Network.NWEndpoint,
        transport: FlowTransport
    ) throws -> FlowEndpoint {
        switch endpoint {
        case let .hostPort(host, port):
            return try decode(host: host, port: port.rawValue, transport: transport)
        case let .opaque(rawEndpoint):
            return try decode(rawEndpoint, transport: transport)
        case .service, .unix, .url:
            throw NetworkFlowEndpointCodecError.unsupportedEndpoint
        @unknown default:
            throw NetworkFlowEndpointCodecError.unsupportedEndpoint
        }
    }

    public static func encode(_ endpoint: FlowEndpoint) throws -> Network.NWEndpoint {
        let endpoint = try endpoint.validated()
        guard let port = Network.NWEndpoint.Port(rawValue: endpoint.port) else {
            throw NetworkFlowEndpointCodecError.invalidPort
        }

        switch endpoint.host {
        case let .name(name):
            return .hostPort(host: .name(name, nil), port: port)
        case let .ipv4(bytes):
            var socketAddress = sockaddr_in()
            socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            socketAddress.sin_family = sa_family_t(AF_INET)
            socketAddress.sin_port = endpoint.port.bigEndian
            withUnsafeMutableBytes(of: &socketAddress.sin_addr) { destination in
                destination.copyBytes(from: bytes)
            }
            return try makeOpaqueEndpoint(&socketAddress)
        case let .ipv6(bytes, scopeID):
            var socketAddress = sockaddr_in6()
            socketAddress.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            socketAddress.sin6_family = sa_family_t(AF_INET6)
            socketAddress.sin6_port = endpoint.port.bigEndian
            socketAddress.sin6_scope_id = scopeID
            withUnsafeMutableBytes(of: &socketAddress.sin6_addr) { destination in
                destination.copyBytes(from: bytes)
            }
            return try makeOpaqueEndpoint(&socketAddress)
        }
    }

    private static func decode(
        host: Network.NWEndpoint.Host,
        port: UInt16,
        transport: FlowTransport
    ) throws -> FlowEndpoint {
        guard port != 0 else {
            throw NetworkFlowEndpointCodecError.invalidPort
        }
        let endpointHost: FlowEndpointHost
        switch host {
        case let .ipv4(address):
            endpointHost = .ipv4(Array(address.rawValue))
        case let .ipv6(address):
            let interfaceIndex = address.interface?.index ?? 0
            guard let scopeID = UInt32(exactly: interfaceIndex) else {
                throw NetworkFlowEndpointCodecError.invalidScopeID(interfaceIndex)
            }
            endpointHost = .ipv6(Array(address.rawValue), scopeID: scopeID)
        case let .name(name, _):
            endpointHost = .name(name)
        @unknown default:
            throw NetworkFlowEndpointCodecError.unsupportedEndpoint
        }
        return try FlowEndpoint(
            host: endpointHost,
            port: port,
            transport: transport
        ).validated()
    }

    private static func decode(
        _ endpoint: nw_endpoint_t,
        transport: FlowTransport
    ) throws -> FlowEndpoint {
        switch nw_endpoint_get_type(endpoint) {
        case nw_endpoint_type_address:
            let address = nw_endpoint_get_address(endpoint)
            switch Int32(address.pointee.sa_family) {
            case AF_INET:
                let value = address.withMemoryRebound(
                    to: sockaddr_in.self,
                    capacity: 1
                ) { $0.pointee }
                return try FlowEndpoint(
                    host: .ipv4(withUnsafeBytes(of: value.sin_addr, Array.init)),
                    port: UInt16(bigEndian: value.sin_port),
                    transport: transport
                ).validated()
            case AF_INET6:
                let value = address.withMemoryRebound(
                    to: sockaddr_in6.self,
                    capacity: 1
                ) { $0.pointee }
                return try FlowEndpoint(
                    host: .ipv6(
                        withUnsafeBytes(of: value.sin6_addr, Array.init),
                        scopeID: value.sin6_scope_id
                    ),
                    port: UInt16(bigEndian: value.sin6_port),
                    transport: transport
                ).validated()
            default:
                throw NetworkFlowEndpointCodecError.invalidAddress
            }
        case nw_endpoint_type_host:
            let hostname = nw_endpoint_get_hostname(endpoint)
            return try FlowEndpoint(
                host: .name(String(cString: hostname)),
                port: nw_endpoint_get_port(endpoint),
                transport: transport
            ).validated()
        default:
            throw NetworkFlowEndpointCodecError.unsupportedEndpoint
        }
    }

    private static func makeOpaqueEndpoint<Address>(
        _ address: inout Address
    ) throws -> Network.NWEndpoint {
        let endpoint = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                nw_endpoint_create_address($0)
            }
        }
        return .opaque(endpoint)
    }
}

import AetherRouteKit
import Darwin
import Foundation
import Network

public struct TransparentProxyUpstreamExclusion: Equatable, Hashable, Sendable {
    public enum AddressFamily: Equatable, Hashable, Sendable {
        case ipv4
        case ipv6
    }

    public let address: String
    public let port: UInt16
    public let addressFamily: AddressFamily

    public init(address: String, port: UInt16, addressFamily: AddressFamily) {
        self.address = address
        self.port = port
        self.addressFamily = addressFamily
    }
}

public enum TransparentProxyUpstreamEndpointResolutionError:
    LocalizedError,
    Equatable,
    Sendable
{
    case invalidEndpoint(index: Int)
    case unresolvedEndpoint(index: Int)
    case tooManyResolvedAddresses

    public var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            "A proxy server endpoint in the active profile is invalid."
        case .unresolvedEndpoint:
            "A proxy server in the active profile could not be resolved."
        case .tooManyResolvedAddresses:
            "The active profile resolves to too many proxy server addresses."
        }
    }
}

/// Resolves only proxy-server sockets before transparent interception is
/// installed. The resulting exact IP+port rules prevent the provider's own
/// upstream connections from being captured recursively. Hostnames and
/// addresses stay in memory and must never be written to diagnostics.
public enum TransparentProxyUpstreamEndpointResolver {
    public static let maximumResolvedAddresses = 1_024

    public static func resolve(
        profileYAML: String
    ) throws -> [TransparentProxyUpstreamExclusion] {
        let endpoints = ProfileUpstreamEndpointInspector.inspect(
            yaml: profileYAML
        )
        var results: [TransparentProxyUpstreamExclusion] = []
        var seen: Set<TransparentProxyUpstreamExclusion> = []

        for (index, endpoint) in endpoints.enumerated() {
            let host = normalizedHost(endpoint.host)
            guard !host.isEmpty,
                  host.utf8.count <= 253,
                  !host.contains("\0"),
                  !host.contains("\n"),
                  !host.contains("\r")
            else {
                throw TransparentProxyUpstreamEndpointResolutionError
                    .invalidEndpoint(index: index)
            }

            let addresses: [(String, TransparentProxyUpstreamExclusion.AddressFamily)]
            if let ipv4 = IPv4Address(host) {
                addresses = [(ipv4.debugDescription, .ipv4)]
            } else if let ipv6 = IPv6Address(host) {
                addresses = [(ipv6.debugDescription, .ipv6)]
            } else {
                addresses = try resolveHost(host, index: index)
            }

            for (address, family) in addresses {
                let result = TransparentProxyUpstreamExclusion(
                    address: address,
                    port: endpoint.port,
                    addressFamily: family
                )
                if seen.insert(result).inserted {
                    results.append(result)
                    guard results.count <= maximumResolvedAddresses else {
                        throw TransparentProxyUpstreamEndpointResolutionError
                            .tooManyResolvedAddresses
                    }
                }
            }
        }
        return results
    }

    private static func normalizedHost(_ rawValue: String) -> String {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count >= 2, value.first == "[", value.last == "]" {
            return String(value.dropFirst().dropLast())
        }
        return value
    }

    private static func resolveHost(
        _ host: String,
        index: Int
    ) throws -> [(String, TransparentProxyUpstreamExclusion.AddressFamily)] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0,
              let first = result
        else {
            throw TransparentProxyUpstreamEndpointResolutionError
                .unresolvedEndpoint(index: index)
        }
        defer { freeaddrinfo(first) }

        var addresses: [(String, TransparentProxyUpstreamExclusion.AddressFamily)] = []
        var seen: Set<String> = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor?.pointee {
            if let value = numericAddress(entry), seen.insert(value.0).inserted {
                addresses.append(value)
            }
            cursor = entry.ai_next
        }
        guard !addresses.isEmpty else {
            throw TransparentProxyUpstreamEndpointResolutionError
                .unresolvedEndpoint(index: index)
        }
        return addresses
    }

    private static func numericAddress(
        _ entry: addrinfo
    ) -> (String, TransparentProxyUpstreamExclusion.AddressFamily)? {
        guard let socketAddress = entry.ai_addr else { return nil }
        switch Int32(entry.ai_family) {
        case AF_INET:
            var address = socketAddress.withMemoryRebound(
                to: sockaddr_in.self,
                capacity: 1
            ) { $0.pointee.sin_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET,
                &address,
                &buffer,
                socklen_t(INET_ADDRSTRLEN)
            ) != nil else { return nil }
            return (string(from: buffer), .ipv4)
        case AF_INET6:
            var address = socketAddress.withMemoryRebound(
                to: sockaddr_in6.self,
                capacity: 1
            ) { $0.pointee.sin6_addr }
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(
                AF_INET6,
                &address,
                &buffer,
                socklen_t(INET6_ADDRSTRLEN)
            ) != nil else { return nil }
            return (string(from: buffer), .ipv6)
        default:
            return nil
        }
    }

    private static func string(from buffer: [CChar]) -> String {
        let bytes = buffer.prefix(while: { $0 != 0 }).map {
            UInt8(bitPattern: $0)
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

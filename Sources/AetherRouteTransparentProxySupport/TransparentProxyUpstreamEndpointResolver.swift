#if canImport(AetherRouteKit)
import AetherRouteKit
#endif
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
    public static let defaultMaxResolutionDurationSeconds: TimeInterval = 3.5

    public typealias HostResolver = @Sendable (
        String,
        Int
    ) throws -> [(String, TransparentProxyUpstreamExclusion.AddressFamily)]

    private final class DNSResolutionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var outcomes: [
            String: Result<
                [(String, TransparentProxyUpstreamExclusion.AddressFamily)],
                TransparentProxyUpstreamEndpointResolutionError
            >
        ] = [:]

        func store(
            _ outcome: Result<
                [(String, TransparentProxyUpstreamExclusion.AddressFamily)],
                TransparentProxyUpstreamEndpointResolutionError
            >,
            forKey key: String
        ) {
            lock.lock()
            outcomes[key] = outcome
            lock.unlock()
        }

        func snapshot() -> [
            String: Result<
                [(String, TransparentProxyUpstreamExclusion.AddressFamily)],
                TransparentProxyUpstreamEndpointResolutionError
            >
        ] {
            lock.lock()
            defer { lock.unlock() }
            return outcomes
        }
    }

    public static func resolve(
        profileYAML: String,
        maxResolutionDurationSeconds: TimeInterval = defaultMaxResolutionDurationSeconds,
        hostResolver: HostResolver? = nil
    ) throws -> [TransparentProxyUpstreamExclusion] {
        let endpoints = ProfileUpstreamEndpointInspector.inspect(
            yaml: profileYAML
        )
        let hosts = ProfileHostsInspector.inspect(yaml: profileYAML)
        var resolvedHosts: [String: [(String, TransparentProxyUpstreamExclusion.AddressFamily)]] = [:]
        var preparedEndpoints: [(hostKey: String, port: UInt16, index: Int)] = []
        preparedEndpoints.reserveCapacity(endpoints.count)

        var pendingDNSHosts: [(hostKey: String, queryHost: String, firstIndex: Int)] = []
        var queuedHostKeys: Set<String> = []

        for (index, endpoint) in endpoints.enumerated() {
            var host = normalizedHost(endpoint.host)
            guard !host.isEmpty,
                  host.utf8.count <= 253,
                  !host.contains("\0"),
                  !host.contains("\n"),
                  !host.contains("\r")
            else {
                throw TransparentProxyUpstreamEndpointResolutionError
                    .invalidEndpoint(index: index)
            }

            host = normalizedHost(ProfileHostsInspector.resolveAlias(host, in: hosts))
            let hostKey = host.lowercased()
            preparedEndpoints.append((hostKey: hostKey, port: endpoint.port, index: index))

            if resolvedHosts[hostKey] != nil {
                continue
            } else if let ipv4 = IPv4Address(host) {
                resolvedHosts[hostKey] = [
                    (ipv4.debugDescription, TransparentProxyUpstreamExclusion.AddressFamily.ipv4)
                ]
            } else if let ipv6 = IPv6Address(host) {
                resolvedHosts[hostKey] = [
                    (ipv6.debugDescription, TransparentProxyUpstreamExclusion.AddressFamily.ipv6)
                ]
            } else if queuedHostKeys.insert(hostKey).inserted {
                pendingDNSHosts.append((hostKey: hostKey, queryHost: hostKey, firstIndex: index))
            }
        }

        var dnsOutcomes: [
            String: Result<
                [(String, TransparentProxyUpstreamExclusion.AddressFamily)],
                TransparentProxyUpstreamEndpointResolutionError
            >
        ] = [:]

        if !pendingDNSHosts.isEmpty {
            let resolver: HostResolver = hostResolver ?? { host, index in
                try resolveHost(host, index: index)
            }
            let box = DNSResolutionBox()
            let group = DispatchGroup()
            let queue = DispatchQueue(
                label: "com.aetherroute.transparent.endpoint-resolver",
                qos: .userInitiated,
                attributes: .concurrent
            )

            for item in pendingDNSHosts {
                group.enter()
                queue.async {
                    defer { group.leave() }
                    do {
                        let addresses = try resolver(item.queryHost, item.firstIndex)
                        box.store(.success(addresses), forKey: item.hostKey)
                    } catch let error as TransparentProxyUpstreamEndpointResolutionError {
                        box.store(.failure(error), forKey: item.hostKey)
                    } catch {
                        box.store(
                            .failure(.unresolvedEndpoint(index: item.firstIndex)),
                            forKey: item.hostKey
                        )
                    }
                }
            }

            let budget = max(maxResolutionDurationSeconds, 0.01)
            _ = group.wait(timeout: .now() + budget)
            dnsOutcomes = box.snapshot()
        }

        var results: [TransparentProxyUpstreamExclusion] = []
        var seen: Set<TransparentProxyUpstreamExclusion> = []
        var firstResolutionError: TransparentProxyUpstreamEndpointResolutionError?

        for prepared in preparedEndpoints {
            let addresses: [(String, TransparentProxyUpstreamExclusion.AddressFamily)]
            if let literalAddresses = resolvedHosts[prepared.hostKey] {
                addresses = literalAddresses
            } else if let outcome = dnsOutcomes[prepared.hostKey] {
                switch outcome {
                case let .success(resolved):
                    addresses = resolved
                case let .failure(error):
                    if firstResolutionError == nil {
                        firstResolutionError = error
                    }
                    continue
                }
            } else {
                if firstResolutionError == nil {
                    firstResolutionError = .unresolvedEndpoint(index: prepared.index)
                }
                continue
            }

            for (address, family) in addresses {
                let result = TransparentProxyUpstreamExclusion(
                    address: address,
                    port: prepared.port,
                    addressFamily: family
                )
                // Past the ceiling the rest are left to the self-identity
                // guard. Keeping the exclusions already resolved is safer than
                // failing the start or discarding every one of them.
                guard results.count < maximumResolvedAddresses else { break }
                if seen.insert(result).inserted {
                    results.append(result)
                }
            }
            if results.count >= maximumResolvedAddresses { break }
        }

        if results.isEmpty, let firstResolutionError {
            throw firstResolutionError
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
        let lowercasedHost = host.lowercased()
        if lowercasedHost == "invalid" || lowercasedHost.hasSuffix(".invalid") {
            throw TransparentProxyUpstreamEndpointResolutionError
                .unresolvedEndpoint(index: index)
        }
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
            if let value = numericAddress(entry),
               !isSyntheticFakeIPv4(value.0, family: value.1),
               seen.insert(value.0).inserted
            {
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

    /// Filters out synthetic Fake-IP benchmark range (`198.18.0.0/15`) returned
    /// by system DNS when an existing Fake-IP tunnel is active on the host.
    private static func isSyntheticFakeIPv4(
        _ address: String,
        family: TransparentProxyUpstreamExclusion.AddressFamily
    ) -> Bool {
        guard family == .ipv4 else { return false }
        return address.hasPrefix("198.18.") || address.hasPrefix("198.19.")
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

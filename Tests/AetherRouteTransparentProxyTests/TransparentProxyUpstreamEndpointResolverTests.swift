import AetherRouteKit
import AetherRouteTransparentProxySupport
import XCTest

final class TransparentProxyUpstreamEndpointResolverTests: XCTestCase {
    func testResolvesAndDeduplicatesLiteralServerSockets() throws {
        let yaml = """
        proxies:
          - {name: A, type: vless, server: 203.0.113.9, port: 443}
          - {name: B, type: vmess, server: 203.0.113.9, port: 443}
          - {name: C, type: hysteria2, server: "[2001:db8::9]", port: 8443}
        """

        XCTAssertEqual(
            try TransparentProxyUpstreamEndpointResolver.resolve(
                profileYAML: yaml
            ),
            [
                TransparentProxyUpstreamExclusion(
                    address: "203.0.113.9",
                    port: 443,
                    addressFamily: .ipv4
                ),
                TransparentProxyUpstreamExclusion(
                    address: "2001:db8::9",
                    port: 8443,
                    addressFamily: .ipv6
                ),
            ]
        )
    }

    func testRejectsMalformedServerWithoutDisclosingItInError() {
        let yaml = """
        proxies:
          - name: Bad
            type: vless
            server: invalid..server
            port: 443
        """

        XCTAssertThrowsError(
            try TransparentProxyUpstreamEndpointResolver.resolve(
                profileYAML: yaml
            )
        ) { error in
            XCTAssertFalse(String(reflecting: error).contains("invalid..server"))
        }
    }

    func testResolvesHostsAliasChainAndDirectIP() throws {
        let yaml = """
        hosts:
          'alias1.example.com': 'alias2.example.com'
          'alias2.example.com': '198.51.100.25'
          'direct.example.com': '203.0.113.88'

        proxies:
          - {name: P1, type: vless, server: alias1.example.com, port: 443}
          - {name: P2, type: trojan, server: direct.example.com, port: 8443}
        """

        let exclusions = try TransparentProxyUpstreamEndpointResolver.resolve(profileYAML: yaml)
        XCTAssertEqual(
            Set(exclusions),
            Set([
                TransparentProxyUpstreamExclusion(
                    address: "198.51.100.25",
                    port: 443,
                    addressFamily: .ipv4
                ),
                TransparentProxyUpstreamExclusion(
                    address: "203.0.113.88",
                    port: 8443,
                    addressFamily: .ipv4
                ),
            ])
        )
    }

    func testPartialUnresolvableEndpointsGracefullyKeepsValidExclusions() throws {
        let yaml = """
        proxies:
          - {name: Valid, type: vless, server: 203.0.113.10, port: 443}
          - {name: Dead, type: trojan, server: unresolvable-dead-domain-that-does-not-exist.example.invalid, port: 443}
        """

        let exclusions = try TransparentProxyUpstreamEndpointResolver.resolve(profileYAML: yaml)
        XCTAssertEqual(
            exclusions,
            [
                TransparentProxyUpstreamExclusion(
                    address: "203.0.113.10",
                    port: 443,
                    addressFamily: .ipv4
                )
            ]
        )
    }

    func testLargeSubscriptionKeepsExclusionsInsteadOfFailing() throws {
        let nodes = (0..<1_200).map { index in
            "  - {name: N\(index), type: trojan, server: 10.0.\(index / 256).\(index % 256), port: 443}"
        }
        let yaml = "proxies:\n" + nodes.joined(separator: "\n")

        let exclusions = try TransparentProxyUpstreamEndpointResolver.resolve(profileYAML: yaml)
        let expected = min(
            ProfileUpstreamEndpointInspector.maximumEndpoints,
            TransparentProxyUpstreamEndpointResolver.maximumResolvedAddresses
        )
        XCTAssertEqual(exclusions.count, expected)
        XCTAssertEqual(exclusions.first?.address, "10.0.0.0")
    }

    func testAllUnresolvableEndpointsStillThrow() {
        let yaml = """
        proxies:
          - {name: Dead, type: trojan, server: dead.example.invalid, port: 443}
        """

        XCTAssertThrowsError(
            try TransparentProxyUpstreamEndpointResolver.resolve(profileYAML: yaml)
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxyUpstreamEndpointResolutionError,
                .unresolvedEndpoint(index: 0)
            )
        }
    }
}

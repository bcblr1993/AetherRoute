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
            server: secret.invalid
            port: 443
        """

        XCTAssertThrowsError(
            try TransparentProxyUpstreamEndpointResolver.resolve(
                profileYAML: yaml
            )
        ) { error in
            XCTAssertFalse(String(reflecting: error).contains("secret.invalid"))
        }
    }
}

import AetherRouteKit
import XCTest

final class ProfileConfigurationSummaryTests: XCTestCase {
    func testUpstreamEndpointInspectorReadsBlockAndFlowProxyEntriesOnly() {
        let yaml = """
        proxies:
          - name: VLESS
            type: vless
            server: edge.example.com
            port: 443
          - {name: HY2, type: hysteria2, server: '2001:db8::8', port: 8443}
          - {name: DIRECT, type: direct}
          - {name: Invalid, type: vmess, server: invalid.example, port: 0}
        proxy-groups:
          - {name: Auto, type: url-test, proxies: [VLESS, HY2]}
        """

        XCTAssertEqual(
            ProfileUpstreamEndpointInspector.inspect(yaml: yaml),
            [
                ProfileUpstreamEndpoint(host: "edge.example.com", port: 443),
                ProfileUpstreamEndpoint(host: "2001:db8::8", port: 8443),
            ]
        )
    }

    func testInspectsBlockAndFlowConfigurationWithoutReturningSecrets() {
        let yaml = """
        dns:
          enable: true
          ipv6: true
          use-hosts: false
          respect-rules: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          fake-ip-filter:
            - '*.private.example'
            - secret-device.lan
          nameserver:
            - https://account-token@resolver.example/dns-query
            - tls://1.1.1.1:853
          fallback: [tcp://9.9.9.9:53]
          default-nameserver: [8.8.8.8]
          proxy-server-nameserver:
            - dhcp://en0
          nameserver-policy:
            '*.corp.example': udp://192.0.2.53
          fallback-filter:
            geoip: true
          edns-client-subnet:
            ipv4: 192.0.2.0/24
          listen:
            udp: 127.0.0.1:5353
        proxies:
          - name: Singapore
            type: vmess
            server: secret.example
            uuid: do-not-display
          - {name: "Tokyo, Edge", type: ss, password: do-not-display}
          - name: Custom
            type: future-protocol
            transport-options:
              type: must-not-replace-protocol
        proxy-groups:
          - name: Automatic
            type: url-test
            proxies:
              - Singapore
              - Tokyo, Edge
          - {name: Manual, type: select, proxies: [Singapore, DIRECT]}
        proxy-providers:
          Airport:
            type: http
            url: https://token@example.invalid/profile
          Local: {type: file, path: ./local.yaml}
        rule-providers:
          Privacy:
            type: http
        rules:
          - DOMAIN-SUFFIX,example.com,Automatic
          - "RULE-SET,Privacy,Manual"
          - IP-CIDR,198.51.100.0/24,DIRECT,no-resolve
          - MATCH,DIRECT
        """

        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)

        XCTAssertEqual(
            summary.dns,
            DNSConfigurationSummary(
                isPresent: true,
                isEnabled: true,
                allowsIPv6: true,
                usesHosts: false,
                respectsRules: true,
                mode: .fakeIP,
                nameserverCount: 2,
                fallbackCount: 1,
                defaultNameserverCount: 1,
                proxyNameserverCount: 1,
                nameserverPolicyCount: 1,
                fakeIPFilterCount: 2,
                upstreamTransports: [
                    .udp, .tcp, .dnsOverTLS, .dnsOverHTTPS, .dhcp,
                ],
                hasExplicitFakeIPRange: true,
                hasListener: true,
                hasFallbackFilter: true,
                hasEDNSClientSubnet: true
            )
        )

        XCTAssertEqual(
            summary.proxies,
            [
                .init(id: 0, name: "Singapore", protocolName: "vmess", recognition: .recognized),
                .init(id: 1, name: "Tokyo, Edge", protocolName: "ss", recognition: .recognized),
                .init(id: 2, name: "Custom", protocolName: "future-protocol", recognition: .requiresCoreValidation),
            ]
        )
        XCTAssertEqual(
            summary.proxyGroups,
            [
                .init(
                    id: 0,
                    name: "Automatic",
                    strategy: "url-test",
                    memberCount: 2,
                    members: ["Singapore", "Tokyo, Edge"]
                ),
                .init(
                    id: 1,
                    name: "Manual",
                    strategy: "select",
                    memberCount: 2,
                    members: ["Singapore", "DIRECT"]
                ),
            ]
        )
        XCTAssertEqual(
            summary.proxyProviders,
            [
                .init(id: 0, name: "Airport", sourceType: "http"),
                .init(id: 1, name: "Local", sourceType: "file"),
            ]
        )
        XCTAssertEqual(
            summary.ruleProviders,
            [.init(id: 0, name: "Privacy", sourceType: "http")]
        )
        XCTAssertEqual(
            summary.rules,
            [
                .init(id: 0, order: 1, kind: "DOMAIN-SUFFIX", criteria: "example.com", target: "Automatic"),
                .init(id: 1, order: 2, kind: "RULE-SET", criteria: "Privacy", target: "Manual"),
                .init(id: 2, order: 3, kind: "IP-CIDR", criteria: "198.51.100.0/24", target: "DIRECT"),
                .init(id: 3, order: 4, kind: "MATCH", criteria: nil, target: "DIRECT"),
            ]
        )
        XCTAssertFalse(String(describing: summary).contains("do-not-display"))
        XCTAssertFalse(String(describing: summary).contains("secret.example"))
        XCTAssertFalse(String(describing: summary).contains("token@"))
        XCTAssertFalse(String(describing: summary).contains("resolver.example"))
        XCTAssertFalse(String(describing: summary).contains("private.example"))
        XCTAssertFalse(String(describing: summary).contains("192.0.2"))
    }

    func testMarksIncompleteProxyAndHandlesEmptySections() {
        let summary = ProfileConfigurationInspector.inspect(
            yaml: """
            proxies:
              - name: Missing Type
              - {type: trojan}
            proxy-groups: []
            rules: []
            """
        )

        XCTAssertEqual(summary.proxies.count, 2)
        XCTAssertEqual(summary.proxies[0].recognition, .incomplete)
        XCTAssertEqual(summary.proxies[1].name, "Unnamed proxy")
        XCTAssertEqual(summary.proxies[1].recognition, .incomplete)
        XCTAssertTrue(summary.proxyGroups.isEmpty)
        XCTAssertTrue(summary.rules.isEmpty)
        XCTAssertEqual(summary.dns, DNSConfigurationSummary())
    }

    func testInspectsInlineDNSAndClassifiesUnsupportedModeAndTransport() {
        let summary = ProfileConfigurationInspector.inspect(
            yaml: """
            dns: {enable: true, ipv6: false, enhanced-mode: future-mode, nameserver: [quic://secret.example:853, 1.1.1.1], fake-ip-filter: ['*.lan'], nameserver-policy: {'+.example': https://dns.example/query}}
            proxies: []
            rules: []
            """
        )

        XCTAssertTrue(summary.dns.isPresent)
        XCTAssertTrue(summary.dns.isEnabled)
        XCTAssertFalse(summary.dns.allowsIPv6)
        XCTAssertEqual(summary.dns.mode, .unsupported)
        XCTAssertEqual(summary.dns.nameserverCount, 2)
        XCTAssertEqual(summary.dns.nameserverPolicyCount, 1)
        XCTAssertEqual(summary.dns.fakeIPFilterCount, 1)
        XCTAssertEqual(
            summary.dns.upstreamTransports,
            [.udp, .dnsOverHTTPS, .unsupported]
        )
        XCTAssertFalse(String(describing: summary).contains("secret.example"))
        XCTAssertFalse(String(describing: summary).contains("dns.example"))
    }

    func testBoundsEachDisplayedSection() {
        let proxies = (0..<650)
            .map { "  - {name: n\($0), type: direct}" }
            .joined(separator: "\n")
        let rules = (0..<650)
            .map { "  - DOMAIN,host\($0).invalid,DIRECT" }
            .joined(separator: "\n")
        let groups = (0..<650)
            .map { "  - {name: g\($0), type: select, proxies: [DIRECT]}" }
            .joined(separator: "\n")
        let proxyProviders = (0..<650)
            .map { "  p\($0): {type: http}" }
            .joined(separator: "\n")
        let ruleProviders = (0..<650)
            .map { "  r\($0): {type: http}" }
            .joined(separator: "\n")

        let summary = ProfileConfigurationInspector.inspect(
            yaml: """
            proxies:
            \(proxies)
            proxy-groups:
            \(groups)
            proxy-providers:
            \(proxyProviders)
            rule-providers:
            \(ruleProviders)
            rules:
            \(rules)
            """
        )

        XCTAssertEqual(
            summary.proxies.count,
            ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        )
        XCTAssertEqual(
            summary.rules.count,
            ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        )
        XCTAssertEqual(
            summary.proxyGroups.count,
            ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        )
        XCTAssertEqual(
            summary.proxyProviders.count,
            ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        )
        XCTAssertEqual(
            summary.ruleProviders.count,
            ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        )
        XCTAssertEqual(summary.proxyCount, 650)
        XCTAssertEqual(summary.proxyGroupCount, 650)
        XCTAssertEqual(summary.proxyProviderCount, 650)
        XCTAssertEqual(summary.ruleCount, 650)
        XCTAssertEqual(summary.ruleProviderCount, 650)
    }

    func testFindsRoutingResourceRequirementsBeyondDisplayLimit() {
        let ordinaryRules = (0..<600)
            .map { "  - DOMAIN,host\($0).invalid,DIRECT" }
            .joined(separator: "\n")
        let summary = ProfileConfigurationInspector.inspect(
            yaml: """
            rules:
            \(ordinaryRules)
              - GEOIP,CN,DIRECT,no-resolve
              - AND,((NETWORK,TCP),(GEOSITE,private)),DIRECT
            """
        )

        XCTAssertEqual(
            summary.rules.count,
            ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        )
        XCTAssertEqual(summary.ruleCount, 602)
        XCTAssertTrue(summary.requiresCountryMMDB)
        XCTAssertTrue(summary.requiresGeoSiteDatabase)
    }

    func testProfilesWithoutGeoRulesDoNotRequireRoutingDatabases() {
        let summary = ProfileConfigurationInspector.inspect(
            yaml: """
            rules:
              - DOMAIN-SUFFIX,geoip.example,DIRECT
              - IP-CIDR,192.0.2.0/24,DIRECT,no-resolve
              - MATCH,DIRECT
            """
        )

        XCTAssertFalse(summary.requiresCountryMMDB)
        XCTAssertFalse(summary.requiresGeoSiteDatabase)
    }

    /// The protocol core treats a missing top-level `ipv6` as `false`, and the
    /// tunnel must read it the same way before claiming the IPv6 route.
    func testProfileWithoutIPv6SwitchIsTreatedAsIPv4Only() {
        let summary = ProfileConfigurationInspector.inspect(
            yaml: """
            rules:
              - MATCH,DIRECT
            """
        )

        XCTAssertFalse(summary.allowsIPv6)
    }

    func testProfileIPv6SwitchIsParsed() {
        XCTAssertTrue(
            ProfileConfigurationInspector.inspect(
                yaml: """
                ipv6: true
                rules:
                  - MATCH,DIRECT
                """
            ).allowsIPv6
        )
        XCTAssertFalse(
            ProfileConfigurationInspector.inspect(
                yaml: """
                ipv6: false
                rules:
                  - MATCH,DIRECT
                """
            ).allowsIPv6
        )
    }
}

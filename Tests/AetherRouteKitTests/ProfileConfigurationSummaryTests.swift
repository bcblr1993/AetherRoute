import AetherRouteKit
import XCTest

final class ProfileConfigurationSummaryTests: XCTestCase {
    func testFoldedRuleLineEndingsDoNotCreateExtraParagraphs() {
        let lines = [
            "rules:",
            "  - DOMAIN,example.invalid,Selected",
            "    group",
            "  - DOMAIN,second.invalid,First",
            "",
            "    second",
        ]
        for separator in ["\n", "\r\n", "\r"] {
            let summary = ProfileConfigurationInspector.inspect(yaml: lines.joined(separator: separator))
            XCTAssertEqual(summary.rules.map(\.target), ["Selected group", "First\nsecond"])
        }
    }

    func testExportedIPv4AndIPv6FoldedYAMLMatchesJSON() throws {
        for (ipv6, criterion) in [(false, "IP-CIDR,203.0.113.123/32"), (true, "IP-CIDR6,2001:db8::123/128")] {
            let name = "Controlled test node with a long display name"
            let rule = "AND,((DST-PORT,62116),(\(criterion))),\(name)"
            let object: [String: Any] = [
                "ipv6": ipv6,
                "dns": ["enable": true, "nameserver": ["https://sentinel@resolver.invalid/dns-query"]],
                "proxies": [["name": name, "type": "socks5", "server": "node.invalid", "port": 62117]],
                "rules": [rule, "MATCH,DIRECT"],
            ]
            let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
            let yaml = """
            ipv6: \(ipv6)
            dns:
              enable: true
              nameserver:
              - https://sentinel@resolver.invalid/dns-query
            proxies:
            - name: \(name)
              type: socks5
              server: node.invalid
              port: 62117
            rules:
            - AND,((DST-PORT,62116),(\(criterion))),Controlled test node with a
              long display name
            - MATCH,DIRECT
            """
            let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
            XCTAssertEqual(summary, ProfileConfigurationInspector.inspect(yaml: json))
            XCTAssertEqual(summary.rules.first?.target, name)
            XCTAssertEqual(summary.dns.nameserverCount, 1)
            XCTAssertEqual(summary.allowsIPv6, ipv6)
            XCTAssertFalse(summary.requiresCountryMMDB)
            XCTAssertFalse(summary.requiresGeoSiteDatabase)
            XCTAssertEqual(ProfileUpstreamEndpointInspector.inspect(yaml: yaml), ProfileUpstreamEndpointInspector.inspect(yaml: json))
            for hidden in ["sentinel", "resolver.invalid", "node.invalid"] {
                XCTAssertFalse(String(describing: summary).contains(hidden))
            }
        }
    }

    func testIndentlessDNSListsStopAtSiblingFieldsAndSections() {
        let summary = ProfileConfigurationInspector.inspect(yaml: """
        dns:
          nameserver:
          - https://sentinel@resolver.invalid/dns-query
          - tls://1.1.1.1
          fallback:
            - tcp://9.9.9.9
          fake-ip-filter:
          - '*.private.invalid'
          default-nameserver:
          - 8.8.8.8
          proxy-server-nameserver:
          - dhcp://en0
          nameserver-policy:
            private.invalid: udp://192.0.2.53
          enable: false
          ipv6: true
        rules:
        - MATCH,DIRECT
        proxies:
        - {name: Direct, type: direct}
        """)
        XCTAssertEqual(summary.dns.nameserverCount, 2)
        XCTAssertEqual(summary.dns.fallbackCount, 1)
        XCTAssertEqual(summary.dns.fakeIPFilterCount, 1)
        XCTAssertEqual(summary.dns.defaultNameserverCount, 1)
        XCTAssertEqual(summary.dns.proxyNameserverCount, 1)
        XCTAssertEqual(summary.dns.nameserverPolicyCount, 1)
        XCTAssertEqual(summary.dns.upstreamTransports, [.udp, .tcp, .dnsOverTLS, .dnsOverHTTPS, .dhcp])
        XCTAssertFalse(summary.dns.isEnabled)
        XCTAssertTrue(summary.dns.allowsIPv6)
        XCTAssertEqual(summary.ruleCount, 1)
        XCTAssertEqual(summary.proxyCount, 1)
        for hidden in ["sentinel", "resolver.invalid", "private.invalid", "192.0.2.53"] {
            XCTAssertFalse(String(describing: summary).contains(hidden))
        }
    }

    func testFoldedQuotedRulesKeepCommentsInsideQuotesAndStopAtNextRule() {
        let summary = ProfileConfigurationInspector.inspect(yaml: """
        rules:
          - 'DOMAIN,example.invalid,Selected
            #1 group' # ordinary comment
          - "DOMAIN,second.invalid,Another
            #2 group"
          - MATCH,DIRECT
        dns:
          enable: true
          nameserver: [1.1.1.1]
        """)
        XCTAssertEqual(summary.rules.map(\.target), ["Selected #1 group", "Another #2 group", "DIRECT"])
        XCTAssertEqual(summary.rules.map(\.kind), ["DOMAIN", "DOMAIN", "MATCH"])
        XCTAssertEqual(summary.ruleCount, 3)
        XCTAssertTrue(summary.dns.isEnabled)
        XCTAssertEqual(summary.dns.nameserverCount, 1)
    }

    func testFoldedRulesPreserveParagraphsAndResourceDetectionBeyondDisplayLimit() {
        let ordinary = (0..<600).map { "  - DOMAIN,host\($0).invalid,DIRECT" }.joined(separator: "\n")
        let summary = ProfileConfigurationInspector.inspect(yaml: """
        rules:
          - DOMAIN,example.invalid,First

            second
          - DOMAIN,comment.invalid,Selected
            group
            # a comment must not become rule text
        \(ordinary)
          - AND,((NETWORK,TCP),
            (GEOIP,CN)),DIRECT
          - AND,((NETWORK,TCP),
            (GEOSITE,private)),DIRECT
        proxies:
          - {name: Direct, type: direct}
        """)
        XCTAssertEqual(summary.rules[0].target, "First\nsecond")
        XCTAssertEqual(summary.rules[1].target, "Selected group")
        XCTAssertEqual(summary.ruleCount, 604)
        XCTAssertEqual(summary.rules.count, 500)
        XCTAssertTrue(summary.requiresCountryMMDB)
        XCTAssertTrue(summary.requiresGeoSiteDatabase)
        XCTAssertEqual(summary.proxyCount, 1)
    }

    func testCompleteJSONMatchesBlockYAMLForSummaryAndActualUpstreams() throws {
        let json = #"""
        {
          "ipv6": true,
          "dns": {
            "enable": true, "ipv6": false, "use-hosts": false,
            "respect-rules": true, "enhanced-mode": "fake-ip",
            "fake-ip-range": "198.18.0.1/16", "fake-ip-filter": ["*.private.invalid"],
            "nameserver": ["https://sentinel-credential@resolver.invalid/dns-query", "tls://1.1.1.1:853"],
            "fallback": ["tcp://9.9.9.9:53"], "default-nameserver": ["8.8.8.8"],
            "proxy-server-nameserver": ["dhcp://en0"],
            "nameserver-policy": {"*.corp.invalid": "udp://192.0.2.53"},
            "listen": {"udp": "127.0.0.1:5353"}, "fallback-filter": {"geoip": true},
            "edns-client-subnet": {"ipv4": "192.0.2.0/24"}
          },
          "proxies": [
            {"name": "Edge, \"\u6771\" #1", "type": "socks5", "server": "edge.invalid", "port": 443, "password": "sentinel-credential",
             "transport-options": {"type": "must-not-replace", "server": "nested.invalid", "port": 1234}},
            {"name": "IPv6", "type": "vless", "server": "2001:db8::8", "port": "8443"},
            {"name": "DIRECT", "type": "direct"}
          ],
          "proxy-groups": [{"name": "Manual", "type": "select", "proxies": ["Edge, \"\u6771\" #1", "IPv6", "DIRECT"], "use": ["Remote"]}],
          "proxy-providers": {"Remote": {"type": "http", "url": "https://sentinel-credential@provider.invalid/sub"}},
          "rule-providers": {"Private": {"type": "file", "path": "./private.yaml"}},
          "rules": ["AND,((DST-PORT,62116),(IP-CIDR,203.0.113.123/32)),Manual", "GEOIP,CN,DIRECT,no-resolve", "GEOSITE,private,DIRECT", "MATCH,DIRECT"]
        }
        """#
        let yaml = """
        ipv6: true
        dns:
          enable: true
          ipv6: false
          use-hosts: false
          respect-rules: true
          enhanced-mode: fake-ip
          fake-ip-range: 198.18.0.1/16
          fake-ip-filter: ['*.private.invalid']
          nameserver: [https://sentinel-credential@resolver.invalid/dns-query, tls://1.1.1.1:853]
          fallback: [tcp://9.9.9.9:53]
          default-nameserver: [8.8.8.8]
          proxy-server-nameserver: [dhcp://en0]
          nameserver-policy: {'*.corp.invalid': udp://192.0.2.53}
          listen: {udp: 127.0.0.1:5353}
          fallback-filter: {geoip: true}
          edns-client-subnet: {ipv4: 192.0.2.0/24}
        proxies:
          - name: 'Edge, "東" #1'
            type: socks5
            server: edge.invalid
            port: 443
            password: sentinel-credential
            transport-options:
              type: must-not-replace
              server: nested.invalid
              port: 1234
          - {name: IPv6, type: vless, server: '2001:db8::8', port: '8443'}
          - {name: DIRECT, type: direct}
        proxy-groups:
          - name: Manual
            type: select
            proxies: ['Edge, "東" #1', IPv6, DIRECT]
            use: [Remote]
        proxy-providers:
          Remote: {type: http, url: 'https://sentinel-credential@provider.invalid/sub'}
        rule-providers:
          Private: {type: file, path: ./private.yaml}
        rules:
          - AND,((DST-PORT,62116),(IP-CIDR,203.0.113.123/32)),Manual
          - GEOIP,CN,DIRECT,no-resolve
          - GEOSITE,private,DIRECT
          - MATCH,DIRECT
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let compact = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
            encoding: .utf8
        ))
        let expected = ProfileConfigurationInspector.inspect(yaml: yaml)
        for document in [json, compact] {
            try ProfileImportValidator.validate(data: Data(document.utf8))
            let summary = ProfileConfigurationInspector.inspect(yaml: document)
            XCTAssertEqual(summary, expected)
            XCTAssertEqual(summary.proxyCount, 3)
            XCTAssertEqual(summary.ruleCount, 4)
            XCTAssertEqual(summary.proxyGroups.first?.memberCount, 4)
            XCTAssertTrue(summary.allowsIPv6)
            XCTAssertFalse(summary.dns.allowsIPv6)
            XCTAssertTrue(summary.requiresCountryMMDB)
            XCTAssertTrue(summary.requiresGeoSiteDatabase)
            XCTAssertEqual(summary.proxies.first?.name, "Edge, \"東\" #1")
            XCTAssertEqual(
                ProfileUpstreamEndpointInspector.inspect(yaml: document),
                [
                    ProfileUpstreamEndpoint(host: "edge.invalid", port: 443),
                    ProfileUpstreamEndpoint(host: "2001:db8::8", port: 8443),
                ]
            )
            for secret in ["sentinel-credential", "resolver.invalid", "private.invalid", "provider.invalid", "edge.invalid", "nested.invalid"] {
                XCTAssertFalse(String(describing: summary).contains(secret))
            }
        }
    }

    func testJSONUpstreamsRejectBooleanFloatingOutOfRangeAndNestedPorts() {
        let json = #"""
        {"proxies": [
          {"name":"Valid", "type":"socks5", "server":"valid.invalid", "port":443},
          {"name":"Valid string", "type":"socks5", "server":"string.invalid", "port":"8443"},
          {"server":"bool.invalid", "port":true},
          {"server":"false.invalid", "port":false},
          {"server":"decimal.invalid", "port":443.0},
          {"server":"fraction.invalid", "port":443.5},
          {"server":"exponent.invalid", "port":4.43e2},
          {"server":"zero.invalid", "port":0},
          {"server":"negative.invalid", "port":-1},
          {"server":"overflow.invalid", "port":65536},
          {"server":"string-decimal.invalid", "port":"443.0"},
          {"server":"null.invalid", "port":null},
          {"server":"outer.invalid", "ws-opts":{"server":"nested.invalid", "port":443}},
          {"server":"nested-port.invalid", "port":{"value":443}}
        ], "proxy-groups":[{"name":"Group", "server":"group.invalid", "port":443}],
           "proxy-providers":{"Remote":{"server":"provider.invalid", "port":443}},
           "dns":{"nameserver":["https://resolver.invalid/query"]}}
        """#
        XCTAssertEqual(
            ProfileUpstreamEndpointInspector.inspect(yaml: json),
            [
                ProfileUpstreamEndpoint(host: "valid.invalid", port: 443),
                ProfileUpstreamEndpoint(host: "string.invalid", port: 8443),
            ]
        )
        XCTAssertFalse(ProfileConfigurationInspector.inspect(yaml: json).allowsIPv6)
    }

    func testJSONDNSPolicyResolverListsAndEmptyOptionalFields() {
        let json = #"""
        {"dns":{"enable":true, "ipv6":true, "enhanced-mode":"redir-host",
          "nameserver":[], "listen":null, "fallback-filter":{}, "edns-client-subnet":null,
          "nameserver-policy":{"private.invalid":["tls://1.1.1.1", "https://resolver.invalid/query"], "local.invalid":"dhcp://en0"}},
         "proxies":[], "rules":["MATCH,DIRECT"]}
        """#
        let summary = ProfileConfigurationInspector.inspect(yaml: json)
        XCTAssertFalse(summary.allowsIPv6)
        XCTAssertEqual(summary.dns, DNSConfigurationSummary(
            isPresent: true,
            isEnabled: true,
            allowsIPv6: true,
            mode: .redirHost,
            nameserverPolicyCount: 2,
            upstreamTransports: [.dnsOverTLS, .dnsOverHTTPS, .dhcp]
        ))
        XCTAssertFalse(summary.requiresCountryMMDB)
        XCTAssertFalse(summary.requiresGeoSiteDatabase)
    }

    func testJSONRetainsCountsAndResourceRequirementsBeyondProjectionBounds() throws {
        let total = 650
        let document: [String: Any] = [
            "proxies": (0..<total).map { ["name": "Node \($0)", "type": "socks5", "server": "edge\($0).invalid", "port": "443"] },
            "proxy-groups": (0..<total).map { ["name": "Group \($0)", "type": "select", "proxies": $0 == 0 ? (0..<total).map { "Node \($0)" } : ["DIRECT"]] as [String: Any] },
            "proxy-providers": Dictionary(uniqueKeysWithValues: (0..<total).map { ("p\($0)", ["type": "http"]) }),
            "rule-providers": Dictionary(uniqueKeysWithValues: (0..<total).map { ("r\($0)", ["type": "file"]) }),
            "rules": (0..<total).map { "DOMAIN,host\($0).invalid,DIRECT" }
                + ["AND,((NETWORK,TCP),(GEOIP,CN)),DIRECT", "GEOSITE,private,DIRECT"],
        ]
        let json = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: document), encoding: .utf8
        ))
        let summary = ProfileConfigurationInspector.inspect(yaml: json)
        XCTAssertEqual(summary.proxyCount, total)
        XCTAssertEqual(summary.proxyGroupCount, total)
        XCTAssertEqual(summary.proxyProviderCount, total)
        XCTAssertEqual(summary.ruleProviderCount, total)
        XCTAssertEqual(summary.ruleCount, total + 2)
        let limit = ProfileConfigurationInspector.maximumDisplayedItemsPerSection
        XCTAssertEqual(summary.proxies.count, limit)
        XCTAssertEqual(summary.proxyGroups.count, limit)
        XCTAssertEqual(summary.proxyProviders.count, limit)
        XCTAssertEqual(summary.ruleProviders.count, limit)
        XCTAssertEqual(summary.rules.count, limit)
        XCTAssertEqual(summary.proxyGroups.first?.memberCount, total)
        XCTAssertEqual(summary.proxyGroups.first?.members.count, limit)
        XCTAssertEqual(ProfileUpstreamEndpointInspector.inspect(yaml: json).count, limit)
        XCTAssertTrue(summary.requiresCountryMMDB)
        XCTAssertTrue(summary.requiresGeoSiteDatabase)
    }

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
                // The summary knows the engine's own type list, so an unknown
                // type is unsupported rather than left for the core to decide.
                .init(id: 2, name: "Custom", protocolName: "future-protocol", recognition: .unsupported(.protocolType("future-protocol"))),
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
                .init(id: 2, order: 3, kind: "IP-CIDR", criteria: "198.51.100.0/24", target: "DIRECT", noResolve: true),
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
            dns: {enable: true, ipv6: false, enhanced-mode: future-mode, nameserver: [sdns://secret.example:853, 1.1.1.1], fake-ip-filter: ['*.lan'], nameserver-policy: {'+.example': https://dns.example/query}}
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

    func testRouteMatchEngineEvaluatesInOrderAndMatchesDomainSuffix() {
        let rules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "DOMAIN-SUFFIX", criteria: "baizhiedu.xin", target: "DIRECT"),
            RuleConfigurationSummary(id: 1, order: 2, kind: "DOMAIN-SUFFIX", criteria: "github.com", target: "PROXY"),
            RuleConfigurationSummary(id: 2, order: 3, kind: "MATCH", criteria: nil, target: "FALLBACK"),
        ]

        let result1 = RouteMatchEngine.evaluate(destination: "baizhiedu.xin", against: rules)
        XCTAssertNotNil(result1)
        XCTAssertEqual(result1?.order, 1)
        XCTAssertEqual(result1?.target, "DIRECT")

        let result2 = RouteMatchEngine.evaluate(destination: "https://api.github.com/v1/user", against: rules)
        XCTAssertNotNil(result2)
        XCTAssertEqual(result2?.order, 2)
        XCTAssertEqual(result2?.target, "PROXY")

        let result3 = RouteMatchEngine.evaluate(destination: "unknown-site.org", against: rules)
        XCTAssertNotNil(result3)
        XCTAssertEqual(result3?.order, 3)
        XCTAssertEqual(result3?.target, "FALLBACK")
    }

    func testRouteMatchEngineMatchesIPCIDRSubnets() {
        let rules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "IP-CIDR", criteria: "192.168.0.0/16", target: "DIRECT"),
            RuleConfigurationSummary(id: 1, order: 2, kind: "IP-CIDR", criteria: "10.0.0.0/8", target: "LOCAL"),
            RuleConfigurationSummary(id: 2, order: 3, kind: "MATCH", criteria: nil, target: "PROXY"),
        ]

        let res1 = RouteMatchEngine.evaluate(destination: "192.168.1.100", against: rules)
        XCTAssertEqual(res1?.order, 1)
        XCTAssertEqual(res1?.target, "DIRECT")

        let res2 = RouteMatchEngine.evaluate(destination: "10.1.2.3:8080", against: rules)
        XCTAssertEqual(res2?.order, 2)
        XCTAssertEqual(res2?.target, "LOCAL")

        let res3 = RouteMatchEngine.evaluate(destination: "8.8.8.8", against: rules)
        XCTAssertEqual(res3?.order, 3)
        XCTAssertEqual(res3?.target, "PROXY")
    }

    func testRouteMatchEngineMatchesDomainKeywordAndExactDomain() {
        let rules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "DOMAIN", criteria: "apple.com", target: "DIRECT"),
            RuleConfigurationSummary(id: 1, order: 2, kind: "DOMAIN-KEYWORD", criteria: "google", target: "GOOGLE_PROXY"),
            RuleConfigurationSummary(id: 2, order: 3, kind: "MATCH", criteria: nil, target: "FINAL"),
        ]

        let res1 = RouteMatchEngine.evaluate(destination: "apple.com", against: rules)
        XCTAssertEqual(res1?.order, 1)
        XCTAssertEqual(res1?.target, "DIRECT")

        // Subdomain should not match exact DOMAIN apple.com, but should fall through
        let res2 = RouteMatchEngine.evaluate(destination: "news.apple.com", against: rules)
        XCTAssertEqual(res2?.order, 3)
        XCTAssertEqual(res2?.target, "FINAL")

        let res3 = RouteMatchEngine.evaluate(destination: "www.google.com.hk", against: rules)
        XCTAssertEqual(res3?.order, 2)
        XCTAssertEqual(res3?.target, "GOOGLE_PROXY")
    }
    func testRoutePreviewStopsAtRulesRequiringRuntimeContext() {
        for kind in ["GEOIP", "GEOSITE", "RULE-SET", "SRC-IP-CIDR", "DST-PORT", "DOMAIN-REGEX", "AND"] {
            let rules = [
                RuleConfigurationSummary(id: 0, order: 1, kind: kind, criteria: "google", target: "DIRECT"),
                RuleConfigurationSummary(id: 1, order: 2, kind: "MATCH", criteria: nil, target: "PROXY"),
            ]
            XCTAssertEqual(RouteMatchEngine.assess(destination: "not-google.invalid", against: rules),
                           .indeterminate(ruleOrder: 1), kind)
        }
    }

    func testRoutePreviewIPv6AndFamilyBoundaries() {
        let rules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "IP-CIDR6", criteria: "2001:db8::/32", target: "DIRECT"),
            RuleConfigurationSummary(id: 1, order: 2, kind: "MATCH", criteria: nil, target: "PROXY"),
        ]
        for input in ["2001:db8::1", "2001:db8:0:0:0:0:0:1", "[2001:db8::1]", "https://[2001:db8::1]/path", "[2001:db8::1]:443"] {
            XCTAssertEqual(RouteMatchEngine.evaluate(destination: input, against: rules)?.target, "DIRECT", input)
        }
        for input in ["2001:db9::1", "192.168.1.1"] {
            XCTAssertEqual(RouteMatchEngine.evaluate(destination: input, against: rules)?.target, "PROXY", input)
        }
        XCTAssertEqual(RouteMatchEngine.assess(destination: "example.com", against: rules), .indeterminate(ruleOrder: 1))
        for prefix in [0, 1, 63, 64, 127, 128] {
            let rule = RuleConfigurationSummary(id: 0, order: 1, kind: "IP-CIDR6", criteria: "2001:db8::/\(prefix)", target: "DIRECT")
            XCTAssertNotNil(RouteMatchEngine.evaluate(destination: "2001:db8::", against: [rule]))
        }
    }

    func testRoutePreviewTruncationNeverClaimsDefaultDirect() {
        for count in [499, 500, 501] {
            let yaml = "rules:\n" + (1..<count).map { "  - DOMAIN,unused\($0).invalid,DIRECT\n" }.joined() + "  - MATCH,PROXY\n"
            let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
            let result = RouteMatchEngine.assess(destination: "example.com", against: summary.rules, totalRuleCount: summary.ruleCount)
            if count <= 500 {
                guard case let .matched(match) = result else { return XCTFail("Missing catch-all") }
                XCTAssertEqual(match.target, "PROXY")
            } else {
                XCTAssertEqual(result, .indeterminate(ruleOrder: nil))
            }
        }
    }

    func testRoutePreviewRejectsInvalidInputAndDoesNotInventCatchAll() {
        let malformed = RuleConfigurationSummary(id: 0, order: 1, kind: "UNKNOWN", criteria: nil, target: "DIRECT")
        XCTAssertEqual(RouteMatchEngine.assess(destination: "example.com", against: [malformed]), .indeterminate(ruleOrder: 1))
        for input in ["", "not a host", "https://user:password@example.com", "[not-an-ip]"] {
            XCTAssertEqual(RouteMatchEngine.assess(destination: input, against: []), .invalidDestination)
        }
        XCTAssertEqual(RouteMatchEngine.assess(destination: "example.com", against: []), .noMatch)
    }

    func testRoutePreviewSkipsNoResolveIPAndGeoIPRulesForDomainDestinations() {
        let yaml = """
        rules:
          - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
          - IP-CIDR6,fc00::/7,DIRECT,no-resolve
          - GEOIP,CN,DIRECT,no-resolve
          - DOMAIN-SUFFIX,openai.com,AI-Proxy
          - MATCH,Fallback
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
        XCTAssertTrue(summary.rules[0].noResolve)
        XCTAssertTrue(summary.rules[1].noResolve)
        XCTAssertTrue(summary.rules[2].noResolve)
        XCTAssertFalse(summary.rules[3].noResolve)

        // Domain destinations skip no-resolve IP/GEOIP rules and match downstream domain/catch-all rules
        XCTAssertEqual(
            RouteMatchEngine.evaluate(destination: "api.openai.com", against: summary.rules)?.target,
            "AI-Proxy"
        )
        XCTAssertEqual(
            RouteMatchEngine.evaluate(destination: "github.com", against: summary.rules)?.target,
            "Fallback"
        )
        // IP destinations still match IP-CIDR even when no-resolve is set
        XCTAssertEqual(
            RouteMatchEngine.evaluate(destination: "127.0.0.1", against: summary.rules)?.target,
            "DIRECT"
        )
        XCTAssertEqual(
            RouteMatchEngine.evaluate(destination: "fd00::1", against: summary.rules)?.target,
            "DIRECT"
        )
    }

    func testRoutePreviewEvaluatesGeoIPPrivateAndDstPortAndGeoSite() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Config/RoutingResources/GeoSite.dat")
        let geoSiteData = try Data(contentsOf: url)

        let rules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "GEOIP", criteria: "private", target: "DIRECT", noResolve: true),
            RuleConfigurationSummary(id: 1, order: 2, kind: "DST-PORT", criteria: "8443", target: "PORT-8443"),
            RuleConfigurationSummary(id: 2, order: 3, kind: "GEOSITE", criteria: "apple", target: "DIRECT"),
            RuleConfigurationSummary(id: 3, order: 4, kind: "GEOSITE", criteria: "openai", target: "AI-Proxy"),
            RuleConfigurationSummary(id: 4, order: 5, kind: "MATCH", criteria: nil, target: "Fallback"),
        ]

        // Private IPs match GEOIP,private
        for privateIP in ["127.0.0.1:443", "10.0.0.1:443", "172.16.0.1:443", "192.168.1.1:443", "169.254.1.1:443", "[::1]:443", "[fd00::1]:443", "[fe80::1]:443"] {
            let match = RouteMatchEngine.evaluate(destination: privateIP, against: rules, geoSiteData: geoSiteData)
            XCTAssertEqual(match?.order, 1, privateIP)
            XCTAssertEqual(match?.target, "DIRECT", privateIP)
        }

        // Public IP with port 443 skips GEOIP,private, skips DST-PORT 8443, skips GEOSITE, and hits MATCH
        let publicIPMatch = RouteMatchEngine.evaluate(destination: "8.8.8.8:443", against: rules, geoSiteData: geoSiteData)
        XCTAssertEqual(publicIPMatch?.order, 5)
        XCTAssertEqual(publicIPMatch?.target, "Fallback")

        // Explicit port 8443 matches DST-PORT,8443
        let portMatch = RouteMatchEngine.evaluate(destination: "example.com:8443", against: rules, geoSiteData: geoSiteData)
        XCTAssertEqual(portMatch?.order, 2)
        XCTAssertEqual(portMatch?.target, "PORT-8443")

        // HTTPS URL implies port 443, so it skips DST-PORT,8443 and evaluates GEOSITE
        let appleMatch = RouteMatchEngine.evaluate(destination: "https://www.apple.com/mac", against: rules, geoSiteData: geoSiteData)
        XCTAssertEqual(appleMatch?.order, 3)
        XCTAssertEqual(appleMatch?.target, "DIRECT")

        let openAIMatch = RouteMatchEngine.evaluate(destination: "https://api.openai.com/v1", against: rules, geoSiteData: geoSiteData)
        XCTAssertEqual(openAIMatch?.order, 4)
        XCTAssertEqual(openAIMatch?.target, "AI-Proxy")

        // Bare domain without port stops at DST-PORT,8443 as indeterminate
        XCTAssertEqual(
            RouteMatchEngine.assess(destination: "www.apple.com", against: rules, geoSiteData: geoSiteData),
            .indeterminate(ruleOrder: 2)
        )
    }

    func testFullProfileRuleActionCountsBeyondDisplayLimit() throws {
        let directLines = (0..<300).map { "DOMAIN,d\($0).invalid,DIRECT" }
        let proxyLines = (0..<250).map { "DOMAIN,p\($0).invalid,ProxyGroup" }
        let rejectLines = (0..<100).map { "DOMAIN,r\($0).invalid,REJECT" }
        let allRules = directLines + proxyLines + rejectLines

        let yaml = "rules:\n" + allRules.map { "  - \($0)" }.joined(separator: "\n")
        let jsonData = try JSONSerialization.data(withJSONObject: ["rules": allRules])
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))

        let yamlSummary = ProfileConfigurationInspector.inspect(yaml: yaml)
        let jsonSummary = ProfileConfigurationInspector.inspect(yaml: json)

        XCTAssertEqual(yamlSummary, jsonSummary)
        XCTAssertEqual(yamlSummary.rules.count, ProfileConfigurationInspector.maximumDisplayedItemsPerSection)
        XCTAssertEqual(yamlSummary.allRules.count, 650)
        XCTAssertEqual(yamlSummary.ruleCount, 650)
        XCTAssertEqual(yamlSummary.directRuleCount, 300)
        XCTAssertEqual(yamlSummary.proxyRuleCount, 250)
        XCTAssertEqual(yamlSummary.rejectRuleCount, 100)
    }

    func testAllRulesRetainedBeyondDisplayLimitAndEvaluatedByRouteMatchEngine() throws {
        var ruleLines = (0..<600).map { "DOMAIN,d\($0).invalid,DIRECT" }
        ruleLines.append("DOMAIN-SUFFIX,late-rule.example,LateProxy")
        ruleLines.append("MATCH,FinalFallback")

        let yaml = "rules:\n" + ruleLines.map { "  - \($0)" }.joined(separator: "\n")
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)

        XCTAssertEqual(summary.rules.count, ProfileConfigurationInspector.maximumDisplayedItemsPerSection)
        XCTAssertEqual(summary.allRules.count, 602)
        XCTAssertEqual(summary.ruleCount, 602)

        let lateMatch = RouteMatchEngine.evaluate(
            destination: "sub.late-rule.example",
            against: summary.allRules,
            totalRuleCount: summary.ruleCount
        )
        XCTAssertEqual(lateMatch?.order, 601)
        XCTAssertEqual(lateMatch?.target, "LateProxy")

        let fallbackMatch = RouteMatchEngine.evaluate(
            destination: "unmatched.example",
            against: summary.allRules,
            totalRuleCount: summary.ruleCount
        )
        XCTAssertEqual(fallbackMatch?.order, 602)
        XCTAssertEqual(fallbackMatch?.target, "FinalFallback")
    }

    func testRuleConfigurationSummaryCustomRuleOverrideMapping() {
        let suffixRule = RuleConfigurationSummary(
            id: 0,
            order: 1,
            kind: "DOMAIN-SUFFIX",
            criteria: "github.com",
            target: "DIRECT"
        )
        XCTAssertEqual(suffixRule.overrideCustomRuleKind, .domainSuffix)
        let customOverride = suffixRule.makeCustomRuleOverride(target: .proxy("AI-Group"))
        XCTAssertEqual(customOverride?.kind, .domainSuffix)
        XCTAssertEqual(customOverride?.value, "github.com")
        XCTAssertEqual(customOverride?.target, .proxy("AI-Group"))

        let portRule = RuleConfigurationSummary(
            id: 1,
            order: 2,
            kind: "DST-PORT",
            criteria: "8443",
            target: "DIRECT"
        )
        XCTAssertEqual(portRule.overrideCustomRuleKind, .dstPort)
        XCTAssertEqual(portRule.makeCustomRuleOverride(target: .reject)?.kind, .dstPort)

        let matchRule = RuleConfigurationSummary(
            id: 2,
            order: 3,
            kind: "MATCH",
            criteria: nil,
            target: "Proxy"
        )
        XCTAssertNil(matchRule.overrideCustomRuleKind)
        XCTAssertNil(matchRule.makeCustomRuleOverride(target: .direct))
    }

    func testProviderSummaryExtractsBehaviorFormatIntervalAndRuleSetTargetsInYAMLAndJSON() throws {
        let yaml = """
        rule-providers:
          Apple:
            type: http
            behavior: domain
            format: yaml
            interval: 86400
            url: https://example.com/apple.yaml
          RejectInline: {type: file, behavior: classical, format: text, interval: 3600, path: ./reject.list}
        rules:
          - RULE-SET,Apple,DIRECT
          - RULE-SET,Apple,Proxy
          - RULE-SET,RejectInline,REJECT
          - MATCH,Proxy
        """
        let yamlSummary = ProfileConfigurationInspector.inspect(yaml: yaml)
        XCTAssertEqual(yamlSummary.ruleProviders.count, 2)
        XCTAssertEqual(yamlSummary.ruleProviders[0].name, "Apple")
        XCTAssertEqual(yamlSummary.ruleProviders[0].sourceType, "http")
        XCTAssertEqual(yamlSummary.ruleProviders[0].behavior, "domain")
        XCTAssertEqual(yamlSummary.ruleProviders[0].format, "yaml")
        XCTAssertEqual(yamlSummary.ruleProviders[0].intervalSeconds, 86_400)
        XCTAssertEqual(yamlSummary.ruleProviders[0].referencedRuleCount, 2)
        XCTAssertEqual(yamlSummary.ruleProviders[0].referencedTargets, ["DIRECT", "Proxy"])

        XCTAssertEqual(yamlSummary.ruleProviders[1].name, "RejectInline")
        XCTAssertEqual(yamlSummary.ruleProviders[1].sourceType, "file")
        XCTAssertEqual(yamlSummary.ruleProviders[1].behavior, "classical")
        XCTAssertEqual(yamlSummary.ruleProviders[1].format, "text")
        XCTAssertEqual(yamlSummary.ruleProviders[1].intervalSeconds, 3_600)
        XCTAssertEqual(yamlSummary.ruleProviders[1].referencedRuleCount, 1)
        XCTAssertEqual(yamlSummary.ruleProviders[1].referencedTargets, ["REJECT"])

        let json = """
        {
          "rule-providers": {
            "OpenAI": {
              "type": "http",
              "behavior": "domain",
              "format": "mrs",
              "interval": 43200
            }
          },
          "rules": [
            "RULE-SET,OpenAI,AI-Group",
            "MATCH,DIRECT"
          ]
        }
        """
        let jsonSummary = ProfileConfigurationInspector.inspect(yaml: json)
        XCTAssertEqual(jsonSummary.ruleProviders.count, 1)
        XCTAssertEqual(jsonSummary.ruleProviders[0].name, "OpenAI")
        XCTAssertEqual(jsonSummary.ruleProviders[0].behavior, "domain")
        XCTAssertEqual(jsonSummary.ruleProviders[0].format, "mrs")
        XCTAssertEqual(jsonSummary.ruleProviders[0].intervalSeconds, 43_200)
        XCTAssertEqual(jsonSummary.ruleProviders[0].referencedRuleCount, 1)
        XCTAssertEqual(jsonSummary.ruleProviders[0].referencedTargets, ["AI-Group"])
    }

    func testConnectionRouteDecisionTraceInRuleGlobalAndDirectModes() {
        let yaml = """
        proxies:
          - {name: "HK Entry", type: ss, server: hk.example.com, port: 443, cipher: aes-128-gcm, password: p}
          - {name: "US Exit", type: vless, server: us.example.com, port: 443, uuid: 00000000-0000-0000-0000-000000000001, dialer-proxy: "HK Entry"}
        proxy-groups:
          - {name: "Proxy", type: select, proxies: ["US Exit", "DIRECT"]}
        rules:
          - DOMAIN-SUFFIX,internal.corp,DIRECT
          - DOMAIN-SUFFIX,openai.com,Proxy
          - MATCH,DIRECT
        """
        let customRules = [
            CustomRule(
                kind: .application,
                value: "com.apple.Terminal;/System/Applications/Utilities/Terminal.app",
                target: .direct,
                isEnabled: true
            ),
            CustomRule(
                kind: .domainSuffix,
                value: "github.com",
                target: .proxy("Proxy"),
                isEnabled: true
            ),
        ]
        let customHosts = [
            CustomHostMapping(domain: "*.openai.com", ip: "104.18.33.45", isEnabled: true),
        ]
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml, customRules: customRules)

        let connection = ConnectionTelemetry(
            transport: .tcp,
            destination: "api.openai.com",
            destinationPort: 443,
            uploadTotal: 1_024,
            downloadTotal: 4_096,
            startedAtUnixMilliseconds: 1_700_000_000_000,
            rule: "DomainSuffix",
            rulePayload: "openai.com",
            proxyChain: "Proxy → HK Entry → US Exit",
            sourceAppIdentifier: "com.Safari",
            sourceAppPath: "/Applications/Safari.app",
            dnsDurationMilliseconds: 14,
            connectDurationMilliseconds: 62
        )

        let trace = ConnectionRouteDecisionTrace.evaluate(
            connection: connection,
            routingMode: .rule,
            customHosts: customHosts,
            customRules: customRules,
            summary: summary
        )
        XCTAssertEqual(trace.steps.count, 6)
        XCTAssertEqual(trace.steps[0].stage, .routingMode)
        XCTAssertEqual(trace.steps[0].status, .passed)
        XCTAssertEqual(trace.steps[1].stage, .hostsResolution)
        XCTAssertEqual(trace.steps[1].status, .matched)
        XCTAssertEqual(trace.resolvedHostAlias, "104.18.33.45")
        XCTAssertEqual(trace.steps[2].stage, .applicationRule)
        XCTAssertEqual(trace.steps[2].status, .passed)
        XCTAssertEqual(trace.steps[3].stage, .customDestinationRule)
        XCTAssertEqual(trace.steps[3].status, .passed)
        XCTAssertEqual(trace.steps[4].stage, .profileRule)
        XCTAssertEqual(trace.steps[4].status, .matched)
        XCTAssertEqual(trace.matchedRuleOrder, 4)
        XCTAssertEqual(trace.steps[5].stage, .outboundChain)
        XCTAssertEqual(trace.steps[5].status, .matched)
        XCTAssertEqual(trace.outboundHops, ["Proxy", "HK Entry", "US Exit"])

        let globalTrace = ConnectionRouteDecisionTrace.evaluate(
            connection: connection,
            routingMode: .global,
            customHosts: customHosts,
            customRules: customRules,
            summary: summary
        )
        XCTAssertEqual(globalTrace.steps[0].stage, .routingMode)
        XCTAssertEqual(globalTrace.steps[0].status, .matched)
        XCTAssertEqual(globalTrace.steps[4].status, .skipped)
    }

    func testDNSLookupInspectorEvaluatesHostsFakeIPRouteAndAddresses() {
        let yaml = """
        dns:
          enable: true
          enhanced-mode: fake-ip
          respect-rules: true
          nameserver:
            - https://dns.alidns.com/dns-query
          proxy-server-nameserver:
            - https://1.1.1.1/dns-query
        rules:
          - DOMAIN-SUFFIX,dev.internal,DIRECT
          - DOMAIN-SUFFIX,openai.com,Proxy
          - MATCH,DIRECT
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
        let customHosts = [
            CustomHostMapping(domain: "*.dev.internal", ip: "10.10.20.30", isEnabled: true),
        ]

        let hostHitReport = DNSLookupInspector.evaluate(
            query: "https://api.dev.internal:8443/v1/health",
            summary: summary,
            customHosts: customHosts,
            resolvedAddresses: ["10.10.20.30"],
            latencyMilliseconds: 2
        )
        XCTAssertEqual(hostHitReport?.normalizedHost, "api.dev.internal")
        XCTAssertEqual(hostHitReport?.matchedCustomHostIP, "10.10.20.30")
        XCTAssertEqual(hostHitReport?.effectiveMode, .fakeIP)
        XCTAssertEqual(hostHitReport?.matchedRouteTarget, "DIRECT")
        XCTAssertFalse(hostHitReport?.containsFakeIPAddress ?? true)

        let fakeIPReport = DNSLookupInspector.evaluate(
            query: "chat.openai.com",
            summary: summary,
            customHosts: customHosts,
            resolvedAddresses: ["198.18.0.42"],
            latencyMilliseconds: 8
        )
        XCTAssertEqual(fakeIPReport?.normalizedHost, "chat.openai.com")
        XCTAssertNil(fakeIPReport?.matchedCustomHostIP)
        XCTAssertEqual(fakeIPReport?.matchedRouteTarget, "Proxy")
        XCTAssertEqual(fakeIPReport?.matchedRuleOrder, 2)
        XCTAssertTrue(fakeIPReport?.containsFakeIPAddress ?? false)

        XCTAssertTrue(DNSLookupInspector.isFakeIPAddress("198.18.0.1"))
        XCTAssertTrue(DNSLookupInspector.isFakeIPAddress("198.19.255.254"))
        XCTAssertFalse(DNSLookupInspector.isFakeIPAddress("198.20.0.1"))
        XCTAssertTrue(DNSLookupInspector.isFakeIPAddress("fc00::1234"))
        XCTAssertFalse(DNSLookupInspector.isFakeIPAddress("2606:4700:4700::1111"))
    }

    func testLoopbackAndRFC6761LocalhostAlwaysAssessAndTraceAsDirectAcrossAllModes() {
        let rules = [
            RuleConfigurationSummary(id: 0, order: 1, kind: "DOMAIN-SUFFIX", criteria: "localhost", target: "Proxy"),
            RuleConfigurationSummary(id: 1, order: 2, kind: "IP-CIDR", criteria: "127.0.0.0/8", target: "Proxy", noResolve: true),
            RuleConfigurationSummary(id: 2, order: 3, kind: "MATCH", criteria: nil, target: "Proxy"),
        ]
        for target in [
            "127.0.0.1:8080",
            "127.255.255.254",
            "[::1]:5173",
            "localhost:3000",
            "https://api.localhost:8443/v1/models",
        ] {
            let result = RouteMatchEngine.evaluate(
                destination: target,
                against: rules
            )
            XCTAssertEqual(
                result?.target,
                "DIRECT",
                "Loopback target \(target) must always evaluate as DIRECT even when profile rules point to Proxy"
            )
        }
    }

    func testConnectionTrafficAggregatorSummarizesByAppHostAndOutboundAndFilters() {
        let connections: [ConnectionTelemetry] = [
            ConnectionTelemetry(
                transport: .tcp,
                destination: "api.anthropic.com",
                destinationPort: 443,
                uploadTotal: 200_000,
                downloadTotal: 800_000,
                startedAtUnixMilliseconds: 1_000,
                rule: "DOMAIN-SUFFIX",
                rulePayload: "anthropic.com",
                proxyChain: "AI Group → Tokyo 01",
                sourceAppIdentifier: "com.anthropic.claudefordesktop",
                sourceAppPath: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
            ConnectionTelemetry(
                transport: .tcp,
                destination: "API.ANTHROPIC.COM:443",
                destinationPort: 443,
                uploadTotal: 100_000,
                downloadTotal: 400_000,
                startedAtUnixMilliseconds: 2_000,
                rule: "DOMAIN-SUFFIX",
                rulePayload: "anthropic.com",
                proxyChain: "AI Group → Tokyo 01",
                sourceAppIdentifier: "com.anthropic.claudefordesktop",
                sourceAppPath: "/Applications/Claude.app/Contents/MacOS/Claude"
            ),
            ConnectionTelemetry(
                transport: .udp,
                destination: "[2606:4700:4700::1111]:53",
                destinationPort: 53,
                uploadTotal: 50_000,
                downloadTotal: 450_000,
                startedAtUnixMilliseconds: 3_000,
                rule: "IP-CIDR6",
                rulePayload: "2606:4700::/32",
                proxyChain: "DIRECT",
                sourceAppIdentifier: "com.apple.Safari",
                sourceAppPath: "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app/Contents/MacOS/Safari"
            ),
        ]

        let byHost = ConnectionTrafficAggregator.summarize(
            connections: connections,
            dimension: .host,
            limit: 10
        )
        XCTAssertEqual(byHost.totalConnectionCount, 3)
        XCTAssertEqual(byHost.totalBytes, 2_000_000)
        XCTAssertEqual(byHost.entries.count, 2)
        XCTAssertEqual(byHost.entries[0].key, "api.anthropic.com")
        XCTAssertEqual(byHost.entries[0].connectionCount, 2)
        XCTAssertEqual(byHost.entries[0].totalBytes, 1_500_000)
        XCTAssertEqual(byHost.entries[0].shareOfTotal, 0.75, accuracy: 0.0001)
        XCTAssertEqual(byHost.entries[1].key, "2606:4700:4700::1111")
        XCTAssertEqual(byHost.entries[1].totalBytes, 500_000)
        XCTAssertEqual(byHost.entries[1].shareOfTotal, 0.25, accuracy: 0.0001)

        let byOutbound = ConnectionTrafficAggregator.summarize(
            connections: connections,
            dimension: .outbound,
            limit: 10
        )
        XCTAssertEqual(byOutbound.entries.map(\.key), ["Tokyo 01", "DIRECT"])
        XCTAssertEqual(byOutbound.entries[0].totalBytes, 1_500_000)
        XCTAssertEqual(byOutbound.entries[0].subtitle, "AI Group → Tokyo 01")

        let byApp = ConnectionTrafficAggregator.summarize(
            connections: connections,
            dimension: .application,
            limit: 10
        )
        XCTAssertEqual(byApp.entries.count, 2)
        XCTAssertEqual(byApp.entries[0].key, "com.anthropic.claudefordesktop")
        XCTAssertEqual(byApp.entries[0].displayName, "Claude")
        XCTAssertEqual(byApp.entries[0].totalBytes, 1_500_000)

        XCTAssertTrue(
            ConnectionTrafficAggregator.matchesFilter(
                connections[0],
                dimension: .host,
                key: "api.anthropic.com"
            )
        )
        XCTAssertFalse(
            ConnectionTrafficAggregator.matchesFilter(
                connections[2],
                dimension: .outbound,
                key: "Tokyo 01"
            )
        )
        XCTAssertTrue(
            ConnectionTrafficAggregator.matchesFilter(
                connections[2],
                dimension: .outbound,
                key: "DIRECT"
            )
        )
    }

    func testTerminalProxyEnvGeneratorSupportsAllShellDialectsAndPACScript() throws {
        let zshCmd = TerminalProxyEnvGenerator.shellCommand(
            dialect: .zshBash,
            host: "127.0.0.1",
            httpPort: 7890,
            socksPort: 7891
        )
        XCTAssertTrue(zshCmd.contains("export HTTP_PROXY=http://127.0.0.1:7890"))
        XCTAssertTrue(zshCmd.contains("export ALL_PROXY=socks5h://127.0.0.1:7891"))
        XCTAssertTrue(zshCmd.contains("export NO_PROXY=localhost,127.0.0.1,::1"))

        let fishCmd = TerminalProxyEnvGenerator.shellCommand(
            dialect: .fish,
            host: "127.0.0.1",
            httpPort: 7890,
            socksPort: 7891
        )
        XCTAssertTrue(fishCmd.contains("set -gx HTTP_PROXY http://127.0.0.1:7890"))
        XCTAssertTrue(fishCmd.contains("set -gx ALL_PROXY socks5h://127.0.0.1:7891"))
        XCTAssertTrue(fishCmd.contains("set -gx NO_PROXY localhost,127.0.0.1,::1"))

        let nuCmd = TerminalProxyEnvGenerator.shellCommand(
            dialect: .nushell,
            host: "127.0.0.1",
            httpPort: 7890,
            socksPort: 7891
        )
        XCTAssertTrue(nuCmd.contains("$env.HTTP_PROXY = \"http://127.0.0.1:7890\""))
        XCTAssertTrue(nuCmd.contains("$env.ALL_PROXY = \"socks5h://127.0.0.1:7891\""))

        let pwshCmd = TerminalProxyEnvGenerator.shellCommand(
            dialect: .powershell,
            host: "192.168.1.50",
            httpPort: 7890,
            socksPort: 7891
        )
        XCTAssertTrue(pwshCmd.contains("$env:HTTP_PROXY=\"http://192.168.1.50:7890\""))
        XCTAssertTrue(pwshCmd.contains("$env:NO_PROXY=\"localhost,127.0.0.1,::1,192.168.1.50\""))

        XCTAssertTrue(TerminalProxyEnvGenerator.unsetCommand(dialect: .zshBash).contains("unset HTTP_PROXY"))
        XCTAssertTrue(TerminalProxyEnvGenerator.unsetCommand(dialect: .fish).contains("set -e HTTP_PROXY"))
        XCTAssertTrue(TerminalProxyEnvGenerator.unsetCommand(dialect: .nushell).contains("hide-env -i"))
        XCTAssertTrue(TerminalProxyEnvGenerator.unsetCommand(dialect: .powershell).contains("Remove-Item Env:"))

        let pac = TerminalProxyEnvGenerator.pacScript(
            host: "127.0.0.1",
            httpPort: 7890,
            socksPort: 7891
        )
        XCTAssertTrue(pac.contains("function FindProxyForURL(url, host)"))
        XCTAssertTrue(pac.contains("isPlainHostName(host)"))
        XCTAssertTrue(pac.contains("127.0.0.0"))
        XCTAssertTrue(pac.contains("PROXY 127.0.0.1:7890; SOCKS5 127.0.0.1:7891; SOCKS 127.0.0.1:7891; DIRECT"))
    }

    func testNetworkDiagnosticDoctorEvaluatesHealthyDegradedAndFailedSnapshotsWithoutLeakingSecrets() {
        let healthySnapshot = NetworkDiagnosticInputSnapshot(
            isConnected: true,
            engineMode: "tun",
            routingMode: "rule",
            localProxyEnabled: true,
            localProxyPort: 7890,
            localProxyListening: true,
            loopbackBypassIntact: true,
            dnsEnhancedMode: "fake-ip",
            dnsResolvedCount: 2,
            dnsLatencyMilliseconds: 8,
            domesticLatencyMilliseconds: 24,
            proxyLatencyMilliseconds: 95,
            activeProfileNodeCount: 42,
            ruleProviderCount: 4,
            staleRuleProviderCount: 0
        )
        let healthyReport = NetworkDiagnosticDoctor.evaluate(
            snapshot: healthySnapshot,
            generatedAtUnixSeconds: 1_700_000_000
        )
        XCTAssertEqual(healthyReport.overallStatus, .passed)
        XCTAssertEqual(healthyReport.checks.count, 6)
        XCTAssertEqual(healthyReport.passedCount, 6)
        XCTAssertEqual(healthyReport.warningCount, 0)
        XCTAssertEqual(healthyReport.failedCount, 0)

        let markdown = healthyReport.formattedMarkdownReport()
        XCTAssertTrue(markdown.contains("# AetherRoute Network Diagnostic Report"))
        XCTAssertTrue(markdown.contains("local_proxy_listener: PASSED"))
        XCTAssertTrue(markdown.contains("loopback_direct_bypass: PASSED"))
        XCTAssertTrue(markdown.contains("proxy_outbound_connectivity: PASSED (95 ms)"))

        let degradedSnapshot = NetworkDiagnosticInputSnapshot(
            isConnected: true,
            engineMode: "transparent",
            routingMode: "global",
            localProxyEnabled: false,
            localProxyPort: 7890,
            localProxyListening: false,
            loopbackBypassIntact: true,
            dnsEnhancedMode: "redir-host",
            dnsResolvedCount: 1,
            dnsLatencyMilliseconds: 15,
            domesticLatencyMilliseconds: 40,
            proxyLatencyMilliseconds: nil,
            activeProfileNodeCount: 12,
            ruleProviderCount: 3,
            staleRuleProviderCount: 1
        )
        let degradedReport = NetworkDiagnosticDoctor.evaluate(
            snapshot: degradedSnapshot,
            generatedAtUnixSeconds: 1_700_000_100
        )
        XCTAssertEqual(degradedReport.overallStatus, .failed)
        XCTAssertEqual(degradedReport.failedCount, 1)
        XCTAssertEqual(degradedReport.warningCount, 1)
    }

}

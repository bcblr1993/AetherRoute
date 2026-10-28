import XCTest
@testable import AetherRouteKit

final class DomesticRoutingOptimizerTests: XCTestCase {

    func testOptimizeProfileWithoutDNS() throws {
        let input = """
        mode: rule
        log-level: warning
        proxies:
          - name: Sample Proxy
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: Proxy Group
            type: select
            proxies:
              - Sample Proxy
        rules:
          - MATCH,Proxy Group
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        XCTAssertTrue(output.contains("dns:"))
        XCTAssertTrue(output.contains("enable: true"))
        XCTAssertTrue(output.contains("enhanced-mode: fake-ip"))
        XCTAssertTrue(output.contains("fake-ip-range: 198.18.0.1/16"))
        XCTAssertTrue(output.contains("223.5.5.5"))
        XCTAssertTrue(output.contains("119.29.29.29"))
        XCTAssertTrue(output.contains("swcdn.apple.com"))
        XCTAssertTrue(output.contains("windowsupdate.com"))
        XCTAssertTrue(output.contains("alicdn.com"))
        XCTAssertTrue(output.contains("DOMAIN-SUFFIX,swcdn.apple.com,DIRECT"))
        XCTAssertTrue(output.contains("GEOIP,CN,DIRECT"))
        XCTAssertTrue(output.contains("MATCH,Proxy Group"))

        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testOptimizeProfileWithDisabledDNS() throws {
        let input = """
        mode: rule
        dns:
          enable: false
        proxies:
          - name: Sample Proxy
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: Proxy Group
            type: select
            proxies:
              - Sample Proxy
        rules:
          - MATCH,Proxy Group
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        XCTAssertTrue(output.contains("dns:"))
        XCTAssertTrue(output.contains("enable: true"))
        XCTAssertTrue(output.contains("enhanced-mode: fake-ip"))
        XCTAssertFalse(output.contains("enable: false"))

        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testOptimizeProfilePreservesExistingRulesAndInsertsFallbackBeforeMatch() {
        let input = """
        mode: rule
        proxies:
          - name: Direct Node
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: Final Group
            type: select
            proxies:
              - Direct Node
        rules:
          - DOMAIN-SUFFIX,google.com,Final Group
          - MATCH,Final Group
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        XCTAssertTrue(output.contains("DOMAIN-SUFFIX,google.com,Final Group"))
        XCTAssertTrue(output.contains("DOMAIN-SUFFIX,swcdn.apple.com,DIRECT"))
        XCTAssertTrue(output.contains("GEOIP,CN,DIRECT"))

        // Ensure GEOIP,CN,DIRECT appears before MATCH,Final Group
        let geoipRange = output.range(of: "- GEOIP,CN,DIRECT")!
        let matchRange = output.range(of: "- MATCH,Final Group")!
        XCTAssertTrue(geoipRange.lowerBound < matchRange.lowerBound)

        // Ensure DOMAIN-SUFFIX,google.com,Final Group appears before MATCH
        let googleRange = output.range(of: "- DOMAIN-SUFFIX,google.com,Final Group")!
        XCTAssertTrue(googleRange.lowerBound < matchRange.lowerBound)
    }

    func testOptimizationIsIdempotent() {
        let input = """
        mode: rule
        dns:
          enable: true
          enhanced-mode: fake-ip
          nameserver:
            - 114.114.114.114
        proxies:
          - name: Sample Proxy
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: Proxy Group
            type: select
            proxies:
              - Sample Proxy
        rules:
          - DOMAIN-KEYWORD,mycompany,DIRECT
          - MATCH,Proxy Group
        """

        let pass1 = DomesticRoutingOptimizer.optimizedProfile(for: input)
        let pass2 = DomesticRoutingOptimizer.optimizedProfile(for: pass1)

        XCTAssertEqual(pass1, pass2)
    }

    func testOptimizationPreservesProxiesAndProxyGroups() {
        let input = """
        proxies:
          - name: US Proxy 1
            type: vmess
            server: us1.example.com
            port: 443
            uuid: 00000000-0000-0000-0000-000000000001
            alterId: 0
            cipher: auto
          - name: HK Proxy 1
            type: vmess
            server: hk1.example.com
            port: 443
            uuid: 00000000-0000-0000-0000-000000000002
            alterId: 0
            cipher: auto
        proxy-groups:
          - name: Auto Select
            type: url-test
            proxies:
              - US Proxy 1
              - HK Proxy 1
            url: http://cp.cloudflare.com/generate_204
            interval: 300
        rules:
          - MATCH,Auto Select
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        XCTAssertTrue(output.contains("US Proxy 1"))
        XCTAssertTrue(output.contains("HK Proxy 1"))
        XCTAssertTrue(output.contains("Auto Select"))
        XCTAssertTrue(output.contains("url: http://cp.cloudflare.com/generate_204"))
        XCTAssertTrue(output.contains("interval: 300"))
    }

    func testOptimizeProfileWithLegacyAliases() throws {
        let input = """
        mode: rule
        mixed-port: 7890
        allow-lan: false
        log-level: info
        ipv6: false
        dns:
          nameserver-policy:
            "+.apple.com": "223.5.5.5"
            "geosite:apple": "223.5.5.5"
        Proxy:
          - name: SS-Proxy
            type: ss
            server: 1.2.3.4
            port: 443
            cipher: chacha20-ietf-poly1305
            password: secret
        Proxy Group:
          - name: SS-Group
            type: select
            proxies:
              - SS-Proxy
        Rule:
          - DOMAIN-SUFFIX,google.com,SS-Group
          - MATCH,SS-Group
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        // Must normalize section headers
        XCTAssertTrue(output.contains("proxies:\n  - name: SS-Proxy"))
        XCTAssertTrue(output.contains("proxy-groups:\n  - name: SS-Group"))
        XCTAssertTrue(output.contains("rules:\n"))

        // nameserver-policy must not contain geosite:
        XCTAssertFalse(output.contains("geosite:apple"))
        XCTAssertTrue(output.contains("'+.apple.com': 223.5.5.5"))

        // Rules must preserve custom and default rules
        XCTAssertTrue(output.contains("DOMAIN-SUFFIX,google.com,SS-Group"))
        XCTAssertTrue(output.contains("MATCH,SS-Group"))
        XCTAssertTrue(output.contains("GEOIP,CN,DIRECT"))
        XCTAssertTrue(output.contains("DOMAIN-SUFFIX,swcdn.apple.com,DIRECT"))

        // Must pass ProfileImportValidator
        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testDomesticOptimizationToggleState() {
        let original = DomesticRoutingOptimizer.isEnabled
        defer { DomesticRoutingOptimizer.setEnabled(original) }

        DomesticRoutingOptimizer.setEnabled(false)
        XCTAssertFalse(DomesticRoutingOptimizer.isEnabled)

        DomesticRoutingOptimizer.setEnabled(true)
        XCTAssertTrue(DomesticRoutingOptimizer.isEnabled)
    }

    func testOptimizeEmptyAndWhitespaceYAML() {
        XCTAssertEqual(DomesticRoutingOptimizer.optimizedProfile(for: ""), "")
        XCTAssertEqual(DomesticRoutingOptimizer.optimizedProfile(for: "   \n\n  \t  "), "   \n\n  \t  ")
    }

    func testOptimizeRulesWithInlineCommentsAndEmptyTokens() throws {
        let input = """
        mode: rule
        proxies:
          - name: S1
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: G1
            type: select
            proxies:
              - S1
        rules:
          - DOMAIN-SUFFIX,github.com,G1 # GitHub traffic
          - -
          - ''
          - ""
          - MATCH,G1 # Default route
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)
        XCTAssertTrue(output.contains("DOMAIN-SUFFIX,github.com,G1"))
        XCTAssertTrue(output.contains("MATCH,G1"))
        XCTAssertFalse(output.contains("# GitHub traffic"))
        XCTAssertFalse(output.contains("  - -"))
        XCTAssertFalse(output.contains("  - ''"))

        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testOptimizeProfileStripsInlineCommentsInDNSListsAndNormalizesPolicyArrays() throws {
        let input = """
        mode: rule
        dns:
          enable: true
          enhanced-mode: fake-ip
          nameserver:
            - 223.5.5.5 # 阿里DNS
            - 'https://dns.alidns.com/dns-query' # DoH
          fallback:
            - 8.8.8.8 # Google DNS
          fake-ip-filter:
            - '*.lan' # 局域网域名
            - '+.msftconnecttest.com' # Windows 连通性检查
          nameserver-policy:
            '+.internal.corp': [223.5.5.5, 119.29.29.29]
            'geosite:cn': [223.5.5.5, 119.29.29.29]
        proxies:
          - name: S1
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: G1
            type: select
            proxies:
              - S1
        rules:
          - MATCH,G1
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)
        XCTAssertFalse(output.contains("# 阿里DNS"))
        XCTAssertFalse(output.contains("# 局域网域名"))
        XCTAssertFalse(output.contains("''*.lan'"))
        XCTAssertTrue(output.contains("- '*.lan'"))
        XCTAssertTrue(output.contains("'+.internal.corp': ['223.5.5.5', '119.29.29.29']"))
        XCTAssertFalse(output.contains("geosite:cn"))

        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testOptimizeProfileKeepsEveryResolverInBlockStyleNameserverPolicy() throws {
        let input = """
        mode: rule
        dns:
          enable: true
          nameserver:
          - https://doh.pub/dns-query
          nameserver-policy:
            '+.internal.corp':
              - 223.5.5.5 # 阿里
              - https://dns.alidns.com/dns-query#DIRECT
            '+.single.corp': 119.29.29.29
        proxies:
          - name: S1
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: G1
            type: select
            proxies:
              - S1
        rules:
          - MATCH,G1
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        XCTAssertTrue(output.contains(
            "'+.internal.corp': ['223.5.5.5', 'https://dns.alidns.com/dns-query#DIRECT']"
        ))
        XCTAssertTrue(output.contains("'+.single.corp': 119.29.29.29"))
        // An indentless list item must stay a nameserver, not become a key.
        XCTAssertTrue(output.contains("- https://doh.pub/dns-query"))
        XCTAssertFalse(output.contains("# 阿里"))

        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testOptimizeProfileInjectsWeChatAndTencentDomesticDNSAndDirectRules() throws {
        let input = """
        mode: rule
        dns:
          enable: true
          nameserver:
            - 8.8.8.8
          nameserver-policy:
            '+.qq.com': 8.8.8.8
            '+.weixin.com': 1.1.1.1
        proxies:
          - name: S1
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: G1
            type: select
            proxies:
              - S1
        rules:
          - MATCH,G1
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)

        // Tencent / WeChat domains must be pinned to domestic DNS in nameserver-policy
        XCTAssertTrue(output.contains("'+.qq.com': 119.29.29.29"))
        XCTAssertTrue(output.contains("'+.weixin.com': 119.29.29.29"))
        XCTAssertTrue(output.contains("'+.wechat.com': 119.29.29.29"))
        XCTAssertTrue(output.contains("'+.tencent.com': 119.29.29.29"))
        XCTAssertTrue(output.contains("'+.qcloud.com': 119.29.29.29"))
        XCTAssertFalse(output.contains("'+.qq.com': 8.8.8.8"))
        XCTAssertFalse(output.contains("'+.weixin.com': 1.1.1.1"))

        // Fake-IP filter and high-priority bypass rules must cover WeChat mini-program, bridge, and payment domains
        XCTAssertTrue(output.contains("- '*.servicewechat.com'"))
        XCTAssertTrue(output.contains("- '*.weixinbridge.com'"))
        XCTAssertTrue(output.contains("- '*.tenpay.com'"))
        XCTAssertTrue(output.contains("- DOMAIN-SUFFIX,servicewechat.com,DIRECT"))
        XCTAssertTrue(output.contains("- DOMAIN-SUFFIX,weixinbridge.com,DIRECT"))
        XCTAssertTrue(output.contains("- DOMAIN-SUFFIX,tenpay.com,DIRECT"))

        try ProfileImportValidator.validate(data: Data(output.utf8))
    }
}

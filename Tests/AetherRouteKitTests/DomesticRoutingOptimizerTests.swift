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

    func testLoopbackProtectionRulesPrecedeCustomApplicationRulesAndIncludeRFC6761FakeIPFilters() throws {
        let input = """
        mode: rule
        dns:
          enable: true
          enhanced-mode: fake-ip
          nameserver:
            - 223.5.5.5
        proxies:
          - name: S1
            type: socks5
            server: 198.51.100.10
            port: 1080
        proxy-groups:
          - name: G1
            type: select
            proxies:
              - S1
        rules:
          - MATCH,G1
        """

        let appRule = CustomRule(
            kind: .application,
            value: "com.openai.chat;/Applications/ChatGPT.app",
            target: .proxy("G1")
        )
        let appRuleString = appRule.toClashRuleString()
        let output = DomesticRoutingOptimizer.optimizedProfile(
            for: input,
            customRules: [appRule]
        )

        XCTAssertTrue(output.contains("- '+.localhost'"))
        XCTAssertTrue(output.contains("- '+.local'"))

        let expectedLoopbackRules = [
            "- DOMAIN,localhost,DIRECT",
            "- DOMAIN-SUFFIX,localhost,DIRECT",
            "- IP-CIDR,127.0.0.0/8,DIRECT,no-resolve",
            "- IP-CIDR6,::1/128,DIRECT,no-resolve",
        ]
        let appRuleRange = try XCTUnwrap(output.range(of: "- \(appRuleString)"))
        for loopbackRule in expectedLoopbackRules {
            let loopbackRange = try XCTUnwrap(
                output.range(of: loopbackRule),
                "Missing mandatory loopback rule \(loopbackRule)"
            )
            XCTAssertLessThan(
                loopbackRange.lowerBound,
                appRuleRange.lowerBound,
                "Loopback protection rule \(loopbackRule) must precede custom application rule \(appRuleString)"
            )
        }

        let disabledDomesticWithAppOutput = DomesticRoutingOptimizer.optimizedProfile(
            for: input,
            customRules: [appRule],
            enableDomesticDirect: false
        )
        XCTAssertNoThrow(try ProviderLaunchSnapshot(
            profileYAML: disabledDomesticWithAppOutput,
            routingMode: .rule,
            bypassPolicy: .empty,
            dnsPolicy: .inherited,
            proxySelections: [:],
            routingResources: [:]
        ))

        let disabledDomesticOutput = DomesticRoutingOptimizer.optimizedProfile(
            for: input,
            enableDomesticDirect: false
        )
        for loopbackRule in expectedLoopbackRules {
            XCTAssertTrue(
                disabledDomesticOutput.contains(loopbackRule),
                "Loopback rule \(loopbackRule) must still be injected when enableDomesticDirect is false"
            )
        }
        try ProfileImportValidator.validate(data: Data(disabledDomesticOutput.utf8))
    }

    func testOptimizeProfileExpandsACL4SSRRuleSetsAndStripsRuleProviders() throws {
        let input = """
        mode: rule
        proxies:
          - name: "HK-01"
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: "Proxy"
            type: select
            proxies: [HK-01, DIRECT]
          - name: "MicrosoftGroup"
            type: select
            proxies: [DIRECT, Proxy]
          - name: "AppleGroup"
            type: select
            proxies: [DIRECT, Proxy]
          - name: "TelegramGroup"
            type: select
            proxies: [Proxy, DIRECT]
          - name: "AdsGroup"
            type: select
            proxies: [REJECT, DIRECT]
        rule-providers:
          Microsoft:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Microsoft.list"
            path: ./ruleset/Microsoft.yaml
            format: text
          Apple:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Apple.list"
            path: ./ruleset/Apple.yaml
            format: text
          Telegram:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/Telegram.list"
            path: ./ruleset/Telegram.yaml
            format: text
          BanAD:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/BanAD.list"
            path: ./ruleset/BanAD.yaml
            format: text
          LocalAreaNetwork:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/ACL4SSR/ACL4SSR/master/Clash/LocalAreaNetwork.list"
            path: ./ruleset/LocalAreaNetwork.yaml
            format: text
        rules:
          - 'RULE-SET,LocalAreaNetwork,DIRECT'
          - 'RULE-SET,BanAD,AdsGroup'
          - 'RULE-SET,Microsoft,MicrosoftGroup'
          - 'RULE-SET,Apple,AppleGroup'
          - 'RULE-SET,Telegram,TelegramGroup'
          - 'RULE-SET,UnknownProvider,Proxy'
          - 'MATCH,Proxy'
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)
        XCTAssertFalse(output.contains("rule-providers:"), "rule-providers section must be stripped from runtime profile")
        XCTAssertFalse(output.contains("RULE-SET,"), "RULE-SET lines must be expanded or dropped")
        XCTAssertTrue(output.contains("- GEOSITE,microsoft,MicrosoftGroup"))
        XCTAssertTrue(output.contains("- GEOSITE,apple,AppleGroup"))
        XCTAssertTrue(output.contains("- GEOSITE,telegram,TelegramGroup"))
        XCTAssertTrue(output.contains("- GEOSITE,category-ads-all,AdsGroup"))
        XCTAssertTrue(output.contains("- IP-CIDR,192.168.0.0/16,DIRECT,no-resolve"))
        XCTAssertTrue(output.contains("- MATCH,Proxy"))
        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    func testOptimizeProfilePreservesCustomInlineAndFileRuleProvidersAndExpandsLoyalsoldierRuleSets() throws {
        let input = """
        mode: rule
        proxies:
          - name: "HK-01"
            type: socks5
            server: 127.0.0.1
            port: 1080
        proxy-groups:
          - name: "Proxy"
            type: select
            proxies: [HK-01, DIRECT]
          - name: "AIGroup"
            type: select
            proxies: [Proxy, DIRECT]
        rule-providers:
          custom-inline:
            type: inline
            behavior: domain
            payload:
              - 'custom-internal.corp'
              - 'dashboard.local'
          gemini:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gemini.txt"
            path: ./ruleset/gemini.yaml
            format: text
          tldnotcn:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt"
            path: ./ruleset/tldnotcn.yaml
            format: text
          cncidr:
            type: http
            behavior: classical
            url: "https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt"
            path: ./ruleset/cncidr.yaml
            format: text
        rules:
          - 'RULE-SET,custom-inline,DIRECT'
          - 'RULE-SET,gemini,AIGroup'
          - 'RULE-SET,tldnotcn,Proxy'
          - 'RULE-SET,cncidr,DIRECT,no-resolve'
          - 'MATCH,Proxy'
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(for: input)
        // custom-inline must be preserved!
        XCTAssertTrue(output.contains("rule-providers:"), "Safe inline rule-provider must be preserved")
        XCTAssertTrue(output.contains("custom-inline:"), "custom-inline provider must be preserved")
        XCTAssertTrue(output.contains("type: inline"), "type: inline must be preserved")
        XCTAssertTrue(output.contains("behavior: domain"), "behavior: domain must be preserved")
        XCTAssertTrue(output.contains("- 'custom-internal.corp'"), "payload items must be preserved")
        XCTAssertTrue(output.contains("- RULE-SET,custom-inline,DIRECT"), "RULE-SET for custom-inline must be preserved")

        // Loyalsoldier HTTP providers must be expanded and stripped from rule-providers:
        XCTAssertFalse(output.contains("gemini:"), "HTTP provider gemini must be stripped")
        XCTAssertFalse(output.contains("tldnotcn:"), "HTTP provider tldnotcn must be stripped")
        XCTAssertFalse(output.contains("cncidr:"), "HTTP provider cncidr must be stripped")

        // Expansions:
        XCTAssertTrue(output.contains("- GEOSITE,google-gemini,AIGroup"))
        XCTAssertTrue(output.contains("- GEOSITE,geolocation-!cn,Proxy"))
        XCTAssertTrue(output.contains("- GEOIP,CN,DIRECT,no-resolve"))
        try ProfileImportValidator.validate(data: Data(output.utf8))
    }
}

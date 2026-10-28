import Foundation
import XCTest
@testable import AetherRouteKit

final class RecoveryAndSubscriptionCompatibilityTests: XCTestCase {
    func testDirectHealthProbePrioritizesDomesticReachableAppleEndpointFirst() {
        let directURLs = NetworkRecoveryHealthPolicy.probeURLs(forTargetGroup: "DIRECT")
        XCTAssertFalse(directURLs.isEmpty)
        XCTAssertEqual(
            directURLs.first?.absoluteString,
            "https://www.apple.com/library/test/success.html",
            "DIRECT recovery probe must test Apple's domestic-reachable endpoint first to avoid 6s timeouts in Mainland China"
        )

        let proxyURLs = NetworkRecoveryHealthPolicy.probeURLs(forTargetGroup: "PROXY")
        XCTAssertEqual(
            proxyURLs.first?.absoluteString,
            "https://www.google.com/generate_204"
        )
    }

    func testPhysicalUplinkAcceptsRoutableInterfaceWithoutLinkDictionaryWhenNotExplicitlyInactive() {
        XCTAssertTrue(
            PhysicalUplinkDetector.isCandidateLinkEligible(
                explicitLinkActive: nil,
                hasRoutablePhysicalAddresses: true
            )
        )
        XCTAssertTrue(
            PhysicalUplinkDetector.isCandidateLinkEligible(
                explicitLinkActive: true,
                hasRoutablePhysicalAddresses: true
            )
        )
        XCTAssertFalse(
            PhysicalUplinkDetector.isCandidateLinkEligible(
                explicitLinkActive: false,
                hasRoutablePhysicalAddresses: true
            )
        )
        XCTAssertFalse(
            PhysicalUplinkDetector.isCandidateLinkEligible(
                explicitLinkActive: nil,
                hasRoutablePhysicalAddresses: false
            )
        )
    }

    func testProxyGroupExpandsIncludeAllAndRegexFiltersInYAMLAndJSON() {
        let yaml = """
        proxies:
          - {name: "🇭🇰 香港 IEPL 01", type: vless, server: hk1.example.com, port: 443}
          - {name: "🇭🇰 香港 IEPL 02 [倍率x2]", type: vless, server: hk2.example.com, port: 443}
          - {name: "🇺🇸 美国 GIA 01", type: trojan, server: us1.example.com, port: 443}
          - {name: "剩余流量：88%", type: ss, server: 127.0.0.1, port: 8388}
        proxy-groups:
          - name: 自动选择
            type: url-test
            include-all: true
            exclude-filter: "剩余流量|过期"
          - name: 香港专线
            type: select
            include-all-proxies: true
            filter: "香港|HK"
            exclude-filter: "倍率"
            proxies:
              - DIRECT
        rules:
          - MATCH,自动选择
        """

        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
        XCTAssertEqual(summary.proxyGroups.count, 2)
        XCTAssertEqual(
            summary.proxyGroups[0].members,
            ["🇭🇰 香港 IEPL 01", "🇭🇰 香港 IEPL 02 [倍率x2]", "🇺🇸 美国 GIA 01"]
        )
        XCTAssertEqual(summary.proxyGroups[0].memberCount, 3)
        XCTAssertEqual(
            summary.proxyGroups[1].members,
            ["DIRECT", "🇭🇰 香港 IEPL 01"]
        )
        XCTAssertEqual(summary.proxyGroups[1].memberCount, 2)
    }

    func testLargeSubscriptionReloadPayloadCompressesAndWeChatDNSIsPinnedToDomesticResolver() throws {
        let rawYAML = """
        mode: rule
        dns:
          enable: true
          nameserver:
            - 8.8.8.8
          nameserver-policy:
            '+.qq.com': 8.8.8.8
        proxies:
          - {name: "Node-1", type: socks5, server: 127.0.0.1, port: 1080}
        proxy-groups:
          - {name: "G1", type: select, proxies: ["Node-1"]}
        rules:
          - MATCH,G1
        """
        var remoteRules: [String] = []
        remoteRules.reserveCapacity(15_000)
        for idx in 1...15_000 {
            remoteRules.append("DOMAIN-SUFFIX,domain-\(idx).example.org,G1")
        }

        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: rawYAML,
            remoteRules: remoteRules
        )
        XCTAssertTrue(optimized.contains("'+.qq.com': 119.29.29.29"))
        XCTAssertTrue(optimized.contains("'+.weixin.com': 119.29.29.29"))
        XCTAssertTrue(optimized.contains("'+.wechat.com': 119.29.29.29"))
        XCTAssertTrue(optimized.contains("- DOMAIN-SUFFIX,servicewechat.com,DIRECT"))
        XCTAssertGreaterThan(optimized.utf8.count, ReloadProfilePayloadCodec.maximumPayloadBytes)

        let payload = ReloadProfilePayload(
            profileYAML: optimized,
            routingMode: .rule,
            bypassPolicy: .empty,
            dnsPolicy: .inherited,
            proxySelections: ["G1": "Node-1"]
        )
        let encoded = try ReloadProfilePayloadCodec.encode(payload)
        XCTAssertLessThanOrEqual(encoded.count, ReloadProfilePayloadCodec.maximumPayloadBytes)
        let decoded = try ReloadProfilePayloadCodec.decode(encoded)
        XCTAssertEqual(decoded, payload)
    }
}

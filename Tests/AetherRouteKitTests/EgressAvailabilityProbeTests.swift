import AetherRouteKit
import Foundation
import XCTest

final class EgressAvailabilityProbeTests: XCTestCase {
    func testMaskedIPv4AndIPv6() {
        let ipv4 = EgressIdentity(
            ip: "103.152.112.45",
            countryCode: "JP",
            countryName: "Japan",
            city: "Tokyo",
            asn: "AS2497",
            organization: "IIJ Internet Initiative Japan",
            ipType: .isp,
            purity: EgressPurityAssessment(level: .clean, score: 92)
        )
        XCTAssertEqual(ipv4.maskedIP, "103.152.***.**")

        let ipv6 = EgressIdentity(
            ip: "2001:db8:85a3:0:0:8a2e:370:7334",
            countryCode: "US",
            countryName: "United States",
            city: "San Jose",
            asn: "AS7922",
            organization: "Comcast Cable",
            ipType: .residential,
            purity: EgressPurityAssessment(level: .clean, score: 96)
        )
        XCTAssertEqual(ipv6.maskedIP, "2001:db8:****:****")

        let empty = EgressIdentity(
            ip: "",
            countryCode: nil,
            countryName: nil,
            city: nil,
            asn: nil,
            organization: nil,
            ipType: .unknown,
            purity: EgressPurityAssessment(level: .moderate, score: 60)
        )
        XCTAssertEqual(empty.maskedIP, "***")
    }

    func testCountryFlagGeneration() {
        XCTAssertEqual(EgressIdentity.flag(forCountryCode: "JP"), "🇯🇵")
        XCTAssertEqual(EgressIdentity.flag(forCountryCode: "us"), "🇺🇸")
        XCTAssertEqual(EgressIdentity.flag(forCountryCode: "HK"), "🇭🇰")
        XCTAssertEqual(EgressIdentity.flag(forCountryCode: nil), "🌐")
        XCTAssertEqual(EgressIdentity.flag(forCountryCode: "INVALID"), "🌐")
    }

    func testIPTypeAndPurityClassification() {
        XCTAssertEqual(
            EgressClassifier.classifyIPType(
                asn: "AS13335",
                organization: "Cloudflare, Inc.",
                isHosting: true
            ),
            .datacenter
        )
        XCTAssertEqual(
            EgressClassifier.classifyIPType(
                asn: "AS7922",
                organization: "Comcast Cable Communications, LLC",
                isHosting: false
            ),
            .residential
        )
        XCTAssertEqual(
            EgressClassifier.classifyIPType(
                asn: "AS4713",
                organization: "NTT Communications Corporation",
                isHosting: false
            ),
            .isp
        )
        XCTAssertEqual(
            EgressClassifier.classifyIPType(
                asn: nil,
                organization: nil,
                isHosting: false
            ),
            .unknown
        )

        let clean = EgressClassifier.assessPurity(
            ipType: .residential,
            isProxy: false,
            isHosting: false,
            isVPN: false
        )
        XCTAssertEqual(clean.level, .clean)
        XCTAssertGreaterThanOrEqual(clean.score, 80)
        XCTAssertLessThanOrEqual(clean.score, 100)

        let moderate = EgressClassifier.assessPurity(
            ipType: .datacenter,
            isProxy: false,
            isHosting: true,
            isVPN: false
        )
        XCTAssertEqual(moderate.level, .moderate)
        XCTAssertGreaterThanOrEqual(moderate.score, 50)
        XCTAssertLessThan(moderate.score, 80)

        let elevated = EgressClassifier.assessPurity(
            ipType: .datacenter,
            isProxy: true,
            isHosting: true,
            isVPN: true
        )
        XCTAssertEqual(elevated.level, .elevated)
        XCTAssertLessThan(elevated.score, 50)
        XCTAssertGreaterThanOrEqual(elevated.score, 0)
    }

    func testIdentityJSONParsing() throws {
        let json = """
        {
          "ip": "203.0.113.42",
          "country_code": "JP",
          "country": "Japan",
          "city": "Tokyo",
          "asn": "AS16509",
          "org": "Amazon.com, Inc.",
          "hosting": true
        }
        """
        let identity = try XCTUnwrap(EgressIdentityParser.parse(data: Data(json.utf8)))
        XCTAssertEqual(identity.ip, "203.0.113.42")
        XCTAssertEqual(identity.countryCode, "JP")
        XCTAssertEqual(identity.countryName, "Japan")
        XCTAssertEqual(identity.city, "Tokyo")
        XCTAssertEqual(identity.asn, "AS16509")
        XCTAssertEqual(identity.organization, "Amazon.com, Inc.")
        XCTAssertEqual(identity.ipType, .datacenter)
        XCTAssertEqual(identity.flag, "🇯🇵")

        XCTAssertNil(EgressIdentityParser.parse(data: Data("not-json".utf8)))
    }

    func testServiceAvailabilityClassification() {
        // ChatGPT
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .chatGPT,
                statusCode: 401,
                headers: [:],
                body: #"{"error":{"code":"invalid_api_key"}}"#
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .chatGPT,
                statusCode: 403,
                headers: [:],
                body: #"{"error":{"code":"unsupported_country_region_territory"}}"#
            ),
            .unavailable(detail: "Region blocked")
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .chatGPT,
                statusCode: 403,
                headers: ["cf-mitigated": "challenge"],
                body: "Just a moment..."
            ),
            .limited(detail: "Challenge")
        )

        // Claude
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .claude,
                statusCode: 200,
                headers: [:],
                body: "<html>Claude</html>"
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .claude,
                statusCode: 403,
                headers: [:],
                body: "app-unavailable-in-region"
            ),
            .unavailable(detail: "Region blocked")
        )

        // Gemini
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .gemini,
                statusCode: 200,
                headers: [:],
                body: "<html>Gemini</html>"
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .gemini,
                statusCode: 200,
                headers: [:],
                body: "Gemini isn't currently supported in your country"
            ),
            .unavailable(detail: "Region blocked")
        )

        // GitHub Copilot
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .githubCopilot,
                statusCode: 401,
                headers: [:],
                body: #"{"message":"Requires authentication"}"#
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .githubCopilot,
                statusCode: 451,
                headers: [:],
                body: "Unavailable for legal reasons"
            ),
            .unavailable(detail: "Region blocked")
        )

        // Netflix
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .netflix,
                statusCode: 200,
                headers: [:],
                body: "<html>Netflix</html>"
            ),
            .available(detail: "Full")
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .netflix,
                statusCode: 404,
                headers: [:],
                body: "Not Found"
            ),
            .limited(detail: "Originals only")
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .netflix,
                statusCode: 403,
                headers: [:],
                body: "Forbidden"
            ),
            .unavailable(detail: "Blocked")
        )

        // Disney+
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .disneyPlus,
                statusCode: 200,
                headers: [:],
                body: "<html>Disney+</html>"
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .disneyPlus,
                statusCode: 451,
                headers: [:],
                body: "Unavailable"
            ),
            .unavailable(detail: "Region blocked")
        )

        // YouTube
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .youtube,
                statusCode: 200,
                headers: [:],
                body: "<html>YouTube Premium</html>"
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .youtube,
                statusCode: 200,
                headers: [:],
                body: "YouTube Premium is not available in your country"
            ),
            .limited(detail: "No Premium")
        )

        // TikTok
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .tiktok,
                statusCode: 200,
                headers: [:],
                body: "<html>TikTok</html>"
            ),
            .available(detail: nil)
        )
        XCTAssertEqual(
            EgressServiceProbeClassifier.classify(
                service: .tiktok,
                statusCode: 403,
                headers: [:],
                body: "Access Denied"
            ),
            .unavailable(detail: "Region blocked")
        )
    }

    func testAIRestrictedAndAIAvailableDetection() {
        let allAvailableAI: [EgressServiceProbeResult] = [
            .init(service: .chatGPT, status: .available(detail: nil), latencyMilliseconds: 120),
            .init(service: .claude, status: .available(detail: nil), latencyMilliseconds: 140),
            .init(service: .gemini, status: .available(detail: nil), latencyMilliseconds: 110),
            .init(service: .githubCopilot, status: .available(detail: nil), latencyMilliseconds: 95),
        ]

        // HK node is AI-restricted even if services aren't all marked unavailable yet
        let hkIdentity = EgressIdentity(
            ip: "103.152.10.20",
            countryCode: "HK",
            countryName: "Hong Kong",
            city: "Hong Kong",
            asn: "AS4515",
            organization: "PCCW",
            ipType: .isp,
            purity: .init(level: .clean, score: 88)
        )
        let hkReport = EgressProbeReport(
            nodeName: "HK-01",
            checkedAt: Date(),
            identity: hkIdentity,
            services: allAvailableAI
        )
        XCTAssertTrue(hkReport.isAIRestricted)
        XCTAssertFalse(hkReport.isAIAvailable)

        // US node with >=2 AI services unavailable is AI-restricted
        let usIdentity = EgressIdentity(
            ip: "198.51.100.10",
            countryCode: "US",
            countryName: "United States",
            city: "Los Angeles",
            asn: "AS14061",
            organization: "DigitalOcean",
            ipType: .datacenter,
            purity: .init(level: .moderate, score: 62)
        )
        let blockedReport = EgressProbeReport(
            nodeName: "US-Blocked",
            checkedAt: Date(),
            identity: usIdentity,
            services: [
                .init(service: .chatGPT, status: .unavailable(detail: "Region blocked"), latencyMilliseconds: 100),
                .init(service: .claude, status: .unavailable(detail: "Blocked"), latencyMilliseconds: 100),
                .init(service: .gemini, status: .available(detail: nil), latencyMilliseconds: 100),
                .init(service: .githubCopilot, status: .available(detail: nil), latencyMilliseconds: 100),
            ]
        )
        XCTAssertTrue(blockedReport.isAIRestricted)
        XCTAssertFalse(blockedReport.isAIAvailable)

        // JP node with all 4 AI services available is AI-available
        let jpIdentity = EgressIdentity(
            ip: "203.0.113.5",
            countryCode: "JP",
            countryName: "Japan",
            city: "Tokyo",
            asn: "AS2497",
            organization: "IIJ",
            ipType: .isp,
            purity: .init(level: .clean, score: 90)
        )
        let jpReport = EgressProbeReport(
            nodeName: "JP-01",
            checkedAt: Date(),
            identity: jpIdentity,
            services: allAvailableAI
        )
        XCTAssertFalse(jpReport.isAIRestricted)
        XCTAssertTrue(jpReport.isAIAvailable)
        XCTAssertEqual(jpReport.availableAICount, 4)
    }

    func testConcurrentProbeExecutionAndTimeoutClamping() async {
        let probe = EgressAvailabilityProbe(
            timeoutSeconds: 12.0, // must clamp to <= 6.0
            transport: { request in
                let url = try XCTUnwrap(request.url)
                let host = url.host ?? ""
                if host.contains("ipwho.is") || host.contains("ipapi") || host.contains("ipinfo") {
                    let body = """
                    {"ip":"198.51.100.77","country_code":"JP","country":"Japan","city":"Tokyo","asn":"AS2497","org":"IIJ"}
                    """
                    let response = HTTPURLResponse(
                        url: url,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (Data(body.utf8), response)
                }
                if host.contains("tiktok") {
                    throw URLError(.timedOut)
                }
                if host.contains("netflix") {
                    let response = HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil)!
                    return (Data("Not Found".utf8), response)
                }
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("<html>OK</html>".utf8), response)
            }
        )

        XCTAssertLessThanOrEqual(probe.timeoutSeconds, 6.0)

        let report = await probe.run(nodeName: "Tokyo-01")
        XCTAssertEqual(report.nodeName, "Tokyo-01")
        XCTAssertEqual(report.identity?.ip, "198.51.100.77")
        XCTAssertEqual(report.identity?.countryCode, "JP")
        XCTAssertEqual(report.services.count, 8)
        XCTAssertEqual(report.aiServices.count, 4)
        XCTAssertEqual(report.streamingServices.count, 4)
        XCTAssertEqual(
            report.services.first(where: { $0.service == .netflix })?.status,
            .limited(detail: "Originals only")
        )
        XCTAssertEqual(
            report.services.first(where: { $0.service == .tiktok })?.status,
            .unknown
        )
        XCTAssertTrue(report.isAIAvailable)
        XCTAssertFalse(report.isAIRestricted)
    }

    func testCacheBoundedTo64Entries() {
        var cache = EgressProbeCache(capacity: 64)
        let baseDate = Date()

        for index in 1...70 {
            let node = "Node-\(index)"
            let isAI = index % 2 == 0
            let report = EgressProbeReport(
                nodeName: node,
                checkedAt: baseDate.addingTimeInterval(TimeInterval(index)),
                identity: EgressIdentity(
                    ip: "198.51.100.\(index)",
                    countryCode: isAI ? "JP" : "HK",
                    countryName: isAI ? "Japan" : "Hong Kong",
                    city: nil,
                    asn: nil,
                    organization: nil,
                    ipType: .unknown,
                    purity: .init(level: .clean, score: 85)
                ),
                services: [
                    .init(service: .chatGPT, status: isAI ? .available(detail: nil) : .unavailable(detail: "Blocked"), latencyMilliseconds: 80),
                    .init(service: .claude, status: isAI ? .available(detail: nil) : .unavailable(detail: "Blocked"), latencyMilliseconds: 80),
                    .init(service: .gemini, status: .available(detail: nil), latencyMilliseconds: 80),
                    .init(service: .githubCopilot, status: .available(detail: nil), latencyMilliseconds: 80),
                ]
            )
            cache.store(report, forNode: node)
        }

        XCTAssertEqual(cache.count, 64)
        // First 6 nodes (1..6) were evicted
        XCTAssertNil(cache.report(forNode: "Node-1"))
        XCTAssertNil(cache.report(forNode: "Node-6"))
        // Nodes 7..70 remain
        XCTAssertNotNil(cache.report(forNode: "Node-7"))
        XCTAssertNotNil(cache.report(forNode: "Node-70"))
        // AI available set contains only even nodes in 7..70
        XCTAssertTrue(cache.aiAvailableNodeNames.contains("Node-70"))
        XCTAssertFalse(cache.aiAvailableNodeNames.contains("Node-69"))
    }

    func testProxyConfigurationDictionary() {
        let config = EgressProxyConfiguration(httpHost: "127.0.0.1", httpPort: 7890)
        let dict = config.connectionProxyDictionary
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPEnable as String] as? Int, 1)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPPort as String] as? Int, 7890)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSEnable as String] as? Int, 1)
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSProxy as String] as? String, "127.0.0.1")
        XCTAssertEqual(dict[kCFNetworkProxiesHTTPSPort as String] as? Int, 7890)
    }
}

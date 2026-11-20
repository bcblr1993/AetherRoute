import Foundation
import XCTest
@testable import AetherRouteKit

final class DNSRecentQueryAndFakeIPLookupTests: XCTestCase {
    func testFakeIPAddressMatcherValidatesRFC2544Boundaries() {
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("198.17.255.255"))
        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("198.18.0.0"))
        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("198.18.0.1"))
        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("198.18.255.255"))
        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("198.19.0.0"))
        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("198.19.255.254"))
        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("198.19.255.255"))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("198.20.0.0"))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("198.20.0.1"))

        XCTAssertTrue(FakeIPAddressMatcher.isFakeIP("  198.18.4.20  "))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("1.1.1.1"))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("192.168.1.1"))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("example.com"))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP(""))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("198.18.0.256"))
        XCTAssertFalse(FakeIPAddressMatcher.isFakeIP("fc00::1"))
    }

    func testRingBufferCapsAt64EntriesAndEvictsOldest() {
        XCTAssertEqual(DNSRecentQueryStore.maxEntries, 64)
        var store = DNSRecentQueryStore()
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)

        for index in 0..<100 {
            store.record(
                DNSRecentQueryRecord(
                    timestamp: baseDate.addingTimeInterval(TimeInterval(index)),
                    domain: "host-\(index).example.com",
                    queryType: .a,
                    resolvedValue: "93.184.216.\(index % 250)",
                    kind: .direct,
                    upstreamLabel: "System DNS",
                    latencyMs: 12
                )
            )
        }

        XCTAssertEqual(store.count, 64)
        XCTAssertEqual(store.entries.count, 64)
        XCTAssertEqual(store.entries.first?.domain, "host-99.example.com")
        XCTAssertEqual(store.entries.last?.domain, "host-36.example.com")
        XCTAssertFalse(store.entries.contains { $0.domain == "host-0.example.com" })
        XCTAssertFalse(store.entries.contains { $0.domain == "host-35.example.com" })
    }

    func testFilterModesReturnMatchingSubsets() {
        var store = DNSRecentQueryStore()
        let now = Date(timeIntervalSince1970: 1_700_000_100)

        store.record(DNSRecentQueryRecord(
            timestamp: now,
            domain: "api.openai.com",
            queryType: .a,
            resolvedValue: "198.18.0.11",
            kind: .fakeIP,
            upstreamLabel: "Fake-IP",
            latencyMs: 1
        ))
        store.record(DNSRecentQueryRecord(
            timestamp: now.addingTimeInterval(1),
            domain: "apple.com",
            queryType: .https,
            resolvedValue: "17.253.144.10",
            kind: .direct,
            upstreamLabel: "System DNS",
            latencyMs: 18
        ))
        store.record(DNSRecentQueryRecord(
            timestamp: now.addingTimeInterval(2),
            domain: "ads.tracker.example",
            queryType: .a,
            resolvedValue: "REJECT",
            kind: .rejected,
            upstreamLabel: "Rule Policy",
            latencyMs: 0
        ))
        store.record(DNSRecentQueryRecord(
            timestamp: now.addingTimeInterval(3),
            domain: "nxdomain.invalid",
            queryType: .aaaa,
            resolvedValue: "",
            kind: .failed,
            upstreamLabel: "System DNS",
            latencyMs: 42
        ))

        XCTAssertEqual(store.entries(matching: .all).count, 4)
        XCTAssertEqual(store.entries(matching: .fakeIP).map(\.domain), ["api.openai.com"])
        XCTAssertEqual(store.entries(matching: .direct).map(\.domain), ["apple.com"])
        XCTAssertEqual(
            store.entries(matching: .rejectedOrFailed).map(\.domain),
            ["nxdomain.invalid", "ads.tracker.example"]
        )
        XCTAssertEqual(store.count(matching: .rejectedOrFailed), 2)
    }

    func testFakeIPReverseLookupHitMissUpdateAndClearAll() {
        var store = DNSRecentQueryStore()
        let t1 = Date(timeIntervalSince1970: 1_700_000_200)
        let t2 = t1.addingTimeInterval(30)

        let firstRecord = DNSRecentQueryRecord(
            timestamp: t1,
            domain: "github.com",
            queryType: .a,
            resolvedValue: "198.18.0.42",
            kind: .fakeIP,
            upstreamLabel: "Fake-IP",
            latencyMs: 2,
            sourceApp: "com.apple.Terminal"
        )
        store.record(firstRecord)

        let hit = store.reverseLookup(fakeIP: "198.18.0.42")
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.fakeIP, "198.18.0.42")
        XCTAssertEqual(hit?.domain, "github.com")
        XCTAssertEqual(hit?.record, firstRecord)
        XCTAssertEqual(hit?.timestamp, t1)

        // Miss for unmapped Fake-IP and non-Fake-IP
        XCTAssertNil(store.reverseLookup(fakeIP: "198.18.9.99"))
        XCTAssertNil(store.reverseLookup(fakeIP: "8.8.8.8"))

        // Newer mapping for same Fake-IP overwrites cleanly
        let secondRecord = DNSRecentQueryRecord(
            timestamp: t2,
            domain: "api.github.com",
            queryType: .a,
            resolvedValue: "198.18.0.42",
            kind: .fakeIP,
            upstreamLabel: "Fake-IP",
            latencyMs: 1
        )
        store.record(secondRecord)

        let updatedHit = store.reverseLookup(fakeIP: " 198.18.0.42 ")
        XCTAssertEqual(updatedHit?.domain, "api.github.com")
        XCTAssertEqual(updatedHit?.timestamp, t2)
        XCTAssertEqual(updatedHit?.record, secondRecord)

        // clearAll removes both ring buffer entries and reverse lookup index
        store.clearAll()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
        XCTAssertEqual(store.fakeIPMappingCount, 0)
        XCTAssertNil(store.reverseLookup(fakeIP: "198.18.0.42"))
    }

    func testRecordLookupReportIntegratesWithDNSLookupReportAndRuntimePolicy() {
        var store = DNSRecentQueryStore()
        let timestamp = Date(timeIntervalSince1970: 1_700_000_300)

        let fakeIPReport = DNSLookupReport(
            query: "claude.ai",
            normalizedHost: "claude.ai",
            matchedCustomHostIP: nil,
            effectiveMode: .fakeIP,
            respectsRules: true,
            matchedRouteTarget: "PROXY",
            matchedRuleOrder: 12,
            matchedRuleSummary: "DOMAIN-SUFFIX claude.ai",
            resolvedAddresses: ["198.18.1.25"],
            containsFakeIPAddress: true,
            latencyMilliseconds: 3
        )
        let recorded = store.recordLookupReport(
            fakeIPReport,
            runtimePolicy: DNSRuntimePolicy(resolutionMode: .fakeIP),
            timestamp: timestamp
        )

        XCTAssertEqual(recorded.domain, "claude.ai")
        XCTAssertEqual(recorded.kind, .fakeIP)
        XCTAssertEqual(recorded.resolvedValue, "198.18.1.25")
        XCTAssertEqual(recorded.latencyMs, 3)
        XCTAssertEqual(recorded.matchedRuleSummary, "DOMAIN-SUFFIX claude.ai")
        XCTAssertEqual(recorded.matchedRouteTarget, "PROXY")
        XCTAssertEqual(store.reverseLookup(fakeIP: "198.18.1.25")?.domain, "claude.ai")

        let rejectedReport = DNSLookupReport(
            query: "ad.doubleclick.net",
            normalizedHost: "ad.doubleclick.net",
            matchedCustomHostIP: nil,
            effectiveMode: .normal,
            respectsRules: true,
            matchedRouteTarget: "REJECT",
            matchedRuleOrder: 4,
            matchedRuleSummary: "DOMAIN-SUFFIX doubleclick.net",
            resolvedAddresses: [],
            containsFakeIPAddress: false,
            latencyMilliseconds: 1
        )
        let rejected = store.recordLookupReport(rejectedReport, timestamp: timestamp.addingTimeInterval(1))
        XCTAssertEqual(rejected.kind, .rejected)

        let failedReport = DNSLookupReport(
            query: "does-not-exist.invalid",
            normalizedHost: "does-not-exist.invalid",
            matchedCustomHostIP: nil,
            effectiveMode: .normal,
            respectsRules: false,
            matchedRouteTarget: "DIRECT",
            matchedRuleOrder: 99,
            matchedRuleSummary: "MATCH",
            resolvedAddresses: [],
            containsFakeIPAddress: false,
            latencyMilliseconds: 55
        )
        let failed = store.recordLookupReport(failedReport, timestamp: timestamp.addingTimeInterval(2))
        XCTAssertEqual(failed.kind, .failed)
    }

    func testIngestConnectionsPopulatesStoreAndDeduplicates() {
        var store = DNSRecentQueryStore()
        let connection = ConnectionTelemetry(
            transport: .tcp,
            destination: "api.anthropic.com",
            destinationPort: 443,
            uploadTotal: 1024,
            downloadTotal: 4096,
            startedAtUnixMilliseconds: 1_700_000_500_000,
            rule: "DOMAIN-SUFFIX",
            rulePayload: "198.18.2.15",
            proxyChain: "Proxy → SG-01",
            sourceAppIdentifier: "com.anthropic.claudefordesktop",
            sourceAppPath: "/Applications/Claude.app",
            dnsDurationMilliseconds: 4,
            connectDurationMilliseconds: 32
        )

        store.ingestConnections(
            [connection],
            runtimePolicy: DNSRuntimePolicy(resolutionMode: .fakeIP)
        )
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entries.first?.domain, "api.anthropic.com")
        XCTAssertEqual(store.entries.first?.kind, .fakeIP)
        XCTAssertEqual(store.entries.first?.sourceApp, "com.anthropic.claudefordesktop")
        XCTAssertEqual(store.entries.first?.latencyMs, 4)
        XCTAssertEqual(store.reverseLookup(fakeIP: "198.18.2.15")?.domain, "api.anthropic.com")

        // Ingesting the same active connection snapshot again must not duplicate the entry
        store.ingestConnections(
            [connection],
            runtimePolicy: DNSRuntimePolicy(resolutionMode: .fakeIP)
        )
        XCTAssertEqual(store.count, 1)
    }
}

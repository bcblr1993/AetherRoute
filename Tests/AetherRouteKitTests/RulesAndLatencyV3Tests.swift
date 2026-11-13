import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class RulesAndLatencyV3Tests: XCTestCase {
    // MARK: - P0-4: Managed ASN.mmdb & Customizable Mirror URLs

    func testASNMMDBResourceKindAndRequirementsDetection() throws {
        XCTAssertEqual(RoutingResourceKind.asnMMDB.fileName, "ASN.mmdb")
        XCTAssertEqual(RoutingResourceKind.asnMMDB.maximumBytes, 64 * 1_024 * 1_024)

        let yamlWithIPASN = """
        proxies:
          - name: NodeA
            type: ss
            server: 1.2.3.4
            port: 8388
            cipher: aes-128-gcm
            password: secret
        rules:
          - IP-ASN,13335,DIRECT,no-resolve
          - MATCH,NodeA
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: yamlWithIPASN)
        XCTAssertTrue(summary.requiredRoutingResources.contains(.asnMMDB))
        XCTAssertFalse(summary.requiredRoutingResources.contains(.countryMMDB))

        let yamlWithCompositeASN = """
        proxies:
          - name: NodeA
            type: ss
            server: 1.2.3.4
            port: 8388
            cipher: aes-128-gcm
            password: secret
        rules:
          - AND,((NETWORK,UDP),(IP-ASN,15169)),REJECT
          - MATCH,NodeA
        """
        let compositeSummary = ProfileConfigurationInspector.inspect(yaml: yamlWithCompositeASN)
        XCTAssertTrue(compositeSummary.requiredRoutingResources.contains(.asnMMDB))
    }

    func testASNMMDBValidationAndStagingIntoAppGroupRuntimeDirectories() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-asn-staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = RoutingResourceStore(applicationSupportDirectory: tempRoot)
        let validASNData = Self.makeValidMMDB(marker: 0x7A)
        let invalidData = Data("not a maxmind mmdb file".utf8)

        XCTAssertThrowsError(
            try store.installUserProvided(data: invalidData, kind: .asnMMDB)
        )

        let record = try store.installUserProvided(data: validASNData, kind: .asnMMDB)
        XCTAssertEqual(record.kind, .asnMMDB)
        XCTAssertEqual(store.status(for: .asnMMDB), .ready(record))

        let runtimeDir = tempRoot.appendingPathComponent("Runtime", isDirectory: true)
        let yaml = """
        proxies:
          - name: NodeA
            type: ss
            server: 1.2.3.4
            port: 8388
            cipher: aes-128-gcm
            password: secret
        rules:
          - IP-ASN,13335,DIRECT,no-resolve
          - MATCH,NodeA
        """
        let stagedKinds = try store.prepareRuntimeResources(for: yaml)
        XCTAssertEqual(stagedKinds, [.asnMMDB])

        let stagedTopLevel = runtimeDir.appendingPathComponent("ASN.mmdb")
        let stagedFlowCore = runtimeDir
            .appendingPathComponent("FlowCore", isDirectory: true)
            .appendingPathComponent("ASN.mmdb")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedTopLevel.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedFlowCore.path))
        XCTAssertEqual(try Data(contentsOf: stagedTopLevel), validASNData)
        XCTAssertEqual(try Data(contentsOf: stagedFlowCore), validASNData)
    }

    func testCustomizableMirrorURLsPersistenceAndDownloadResolution() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("aether-mirror-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let store = RoutingResourceStore(applicationSupportDirectory: tempRoot)

        // Default maintained descriptor exists for .asnMMDB
        let defaultDescriptor = try RoutingResourceRemoteDescriptor.maintainedDefault(for: .asnMMDB)
        XCTAssertEqual(defaultDescriptor.kind, .asnMMDB)
        XCTAssertEqual(defaultDescriptor.resourceURL.scheme, "https")

        // Reject insecure HTTP mirror URLs
        XCTAssertThrowsError(
            try store.setCustomMirrorURLs(
                for: .asnMMDB,
                resourceURL: URL(string: "http://insecure.example.com/ASN.mmdb")!
            )
        )

        let mirrorResourceURL = URL(string: "https://mirror.example.com/geoip/GeoLite2-ASN.mmdb")!
        let mirrorChecksumURL = URL(string: "https://mirror.example.com/geoip/GeoLite2-ASN.mmdb.sha256sum")!
        try store.setCustomMirrorURLs(
            for: .asnMMDB,
            resourceURL: mirrorResourceURL,
            checksumURL: mirrorChecksumURL
        )

        let resolved = try RoutingResourceRemoteDescriptor.resolved(for: .asnMMDB, in: store)
        XCTAssertEqual(resolved.resourceURL, mirrorResourceURL)
        XCTAssertEqual(resolved.checksumURL, mirrorChecksumURL)

        let validData = Self.makeValidMMDB(marker: 0x3C)
        let sha256 = SHA256.hash(data: validData)
            .map { String(format: "%02x", $0) }
            .joined()

        let requestedURLs = LockedBox<[URL]>([])
        let client = RoutingResourceDownloadClient { url, _ in
            requestedURLs.append(url)
            if url == mirrorChecksumURL {
                return RoutingResourceHTTPResponse(
                    data: Data("\(sha256)  GeoLite2-ASN.mmdb\n".utf8),
                    statusCode: 200,
                    finalURL: url
                )
            }
            if url == mirrorResourceURL {
                return RoutingResourceHTTPResponse(
                    data: validData,
                    statusCode: 200,
                    finalURL: url
                )
            }
            return RoutingResourceHTTPResponse(data: Data(), statusCode: 404, finalURL: url)
        }

        let yaml = """
        rules:
          - IP-ASN,13335,DIRECT,no-resolve
          - MATCH,PROXY
        """
        let installed = try await client.ensureRequiredResources(for: yaml, in: store)
        XCTAssertEqual(installed, [.asnMMDB])
        XCTAssertEqual(requestedURLs.value, [mirrorChecksumURL, mirrorResourceURL])
        if case let .ready(record) = store.status(for: .asnMMDB) {
            XCTAssertEqual(record.sha256, sha256)
        } else {
            XCTFail("Expected .asnMMDB to be .ready after mirror download")
        }

        try store.clearCustomMirrorURLs(for: .asnMMDB)
        let reset = try RoutingResourceRemoteDescriptor.resolved(for: .asnMMDB, in: store)
        XCTAssertEqual(reset.resourceURL, defaultDescriptor.resourceURL)
    }

    // MARK: - P0-4: CustomRuleKind Parity & Block QUIC Preset

    func testExpandedCustomRuleKindsParsingValidationAndClashEmission() throws {
        // PROCESS-PATH
        let procPath = try CustomRule.parse("PROCESS-PATH,/usr/bin/curl,ProxyNode")
        XCTAssertEqual(procPath.kind, .processPath)
        XCTAssertEqual(procPath.value, "/usr/bin/curl")
        XCTAssertEqual(procPath.toClashRuleString(), "PROCESS-PATH,/usr/bin/curl,ProxyNode")
        XCTAssertTrue(CustomRuleValidator.validate(kind: .processPath, value: "/opt/homebrew/bin/node", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .processPath, value: "curl", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .processPath, value: "/", target: .direct).isValid)

        // PROCESS-NAME
        let procName = try CustomRule.parse("PROCESS-NAME,ssh,DIRECT")
        XCTAssertEqual(procName.kind, .processName)
        XCTAssertEqual(procName.value, "ssh")
        XCTAssertEqual(procName.toClashRuleString(), "PROCESS-NAME,ssh,DIRECT")
        XCTAssertTrue(CustomRuleValidator.validate(kind: .processName, value: "Google Chrome Helper", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .processName, value: "/usr/bin/ssh", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .processName, value: "   ", target: .direct).isValid)

        // IP-ASN + no-resolve
        let ipASN = try CustomRule.parse("IP-ASN,13335,DIRECT,no-resolve")
        XCTAssertEqual(ipASN.kind, .ipASN)
        XCTAssertEqual(ipASN.value, "13335")
        XCTAssertTrue(ipASN.noResolve)
        XCTAssertEqual(ipASN.toClashRuleString(), "IP-ASN,13335,DIRECT,no-resolve")
        XCTAssertTrue(CustomRuleValidator.validate(kind: .ipASN, value: "AS15169", target: .proxy("Proxy")).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .ipASN, value: "0", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .ipASN, value: "Cloudflare", target: .direct).isValid)

        // DOMAIN-REGEX (including comma inside quantifier)
        let regexRule = try CustomRule.parse(#"DOMAIN-REGEX,^api-\d{1,3}\.example\.com$,ProxyNode"#)
        XCTAssertEqual(regexRule.kind, .domainRegex)
        XCTAssertEqual(regexRule.value, #"^api-\d{1,3}\.example\.com$"#)
        XCTAssertEqual(regexRule.toClashRuleString(), #"DOMAIN-REGEX,^api-\d{1,3}\.example\.com$,ProxyNode"#)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .domainRegex, value: "[unclosed(", target: .direct).isValid)

        // DOMAIN-WILDCARD
        let wildcardRule = try CustomRule.parse("DOMAIN-WILDCARD,*.dev.local,DIRECT")
        XCTAssertEqual(wildcardRule.kind, .domainWildcard)
        XCTAssertEqual(wildcardRule.value, "*.dev.local")
        XCTAssertEqual(wildcardRule.toClashRuleString(), "DOMAIN-WILDCARD,*.dev.local,DIRECT")
        XCTAssertTrue(CustomRuleValidator.validate(kind: .domainWildcard, value: "api-?.example.com", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .domainWildcard, value: "bad host/*.com", target: .direct).isValid)

        // NETWORK (TCP/UDP)
        let netRule = try CustomRule.parse("NETWORK,udp,REJECT")
        XCTAssertEqual(netRule.kind, .network)
        XCTAssertEqual(netRule.value, "UDP")
        XCTAssertEqual(netRule.toClashRuleString(), "NETWORK,UDP,REJECT")
        XCTAssertTrue(CustomRuleValidator.validate(kind: .network, value: "TCP", target: .direct).isValid)
        XCTAssertFalse(CustomRuleValidator.validate(kind: .network, value: "QUIC", target: .reject).isValid)

        // Block QUIC (UDP 443) preset & batch two-token IP-ASN no-resolve
        let quicPreset = CustomRule.blockQUICPreset()
        XCTAssertEqual(quicPreset.target, .reject)
        XCTAssertEqual(quicPreset.toClashRuleString(), "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT")
        let reparsedQuic = try CustomRule.parse(quicPreset.toClashRuleString())
        XCTAssertEqual(reparsedQuic.toClashRuleString(), "AND,((NETWORK,UDP),(DST-PORT,443)),REJECT")

        let batch = CustomRule.parseBatchReport(
            """
            IP-ASN,13335
            PROCESS-NAME,curl
            """,
            defaultTarget: .direct
        )
        XCTAssertEqual(batch.rules.count, 2)
        XCTAssertTrue(batch.rules[0].noResolve)
        XCTAssertEqual(batch.rules[0].toClashRuleString(), "IP-ASN,13335,DIRECT,no-resolve")
        XCTAssertEqual(batch.rules[1].toClashRuleString(), "PROCESS-NAME,curl,DIRECT")
    }

    // MARK: - P1-2: Per-Node Latency Ring Buffer, Jitter, Loss Rate & Failover Ranking

    func testLatencyIndexRingBufferJitterAndLossRate() {
        var index = ProxyLatencyIndex()
        index.beginRun(groups: [(name: "Auto", members: ["NodeA", "NodeB"])])

        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // Push 26 samples for NodeA so ring buffer bounds to maxHistoryCount == 24
        XCTAssertEqual(ProxyLatencyIndex.maxHistoryCount, 24)
        for i in 0..<26 {
            let timestamp = base.addingTimeInterval(Double(i))
            if i == 25 {
                index.merge(member: "NodeA", measurement: .timedOut, at: timestamp)
            } else {
                index.merge(member: "NodeA", measurement: .verified(UInt32(10 + i)), at: timestamp)
            }
        }

        let historyA = index.history(for: "NodeA")
        XCTAssertEqual(historyA.count, 24)
        // Oldest two (i = 0 => 10ms, i = 1 => 11ms) must have been evicted
        XCTAssertEqual(historyA.first?.latencyMilliseconds, 12)
        XCTAssertNil(historyA.last?.latencyMilliseconds)

        let statsA = index.stats(for: "NodeA")
        // 1 timeout out of 24 retained samples
        XCTAssertEqual(statsA.lossRate, 1.0 / 24.0, accuracy: 0.0001)
        // Consecutive deltas among 12..34 are all 1ms => jitter == 1ms
        XCTAssertEqual(statsA.jitterMilliseconds, 1)

        // NodeB with alternating spikes & timeouts: [20, 120, nil, 30, 150, nil]
        let seqB: [UInt32?] = [20, 120, nil, 30, 150, nil]
        for (offset, value) in seqB.enumerated() {
            let m: ProxyLatencyMeasurement = value.map { .verified($0) } ?? .timedOut
            index.merge(member: "NodeB", measurement: m, at: base.addingTimeInterval(Double(offset)))
        }
        let statsB = index.stats(for: "NodeB")
        XCTAssertEqual(statsB.lossRate, 2.0 / 6.0, accuracy: 0.0001)
        // Deltas between consecutive successful samples: |120-20|=100, |30-120|=90, |150-30|=120 -> avg 103
        XCTAssertEqual(statsB.jitterMilliseconds, 103)

        // Clearing active group measurements for UI "testing" spinner MUST preserve ring-buffer history
        index.clear(group: "Auto")
        XCTAssertNil(index.measurement(for: "NodeA", in: "Auto"))
        XCTAssertEqual(index.history(for: "NodeA").count, 24)
        XCTAssertEqual(index.stats(for: "NodeB").jitterMilliseconds, 103)
    }

    func testFailoverPolicyPenalizesHighLossAndHighJitterNodes() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)

        // NodeLowRTTButFlaky: current RTT 40ms, 50% packet loss, high jitter (80ms)
        let flakyStats = ProxyLatencyStats(
            samples: [
                ProxyLatencySample(latencyMilliseconds: 20, testedAt: base),
                ProxyLatencySample(latencyMilliseconds: nil, testedAt: base.addingTimeInterval(1)),
                ProxyLatencySample(latencyMilliseconds: 100, testedAt: base.addingTimeInterval(2)),
                ProxyLatencySample(latencyMilliseconds: nil, testedAt: base.addingTimeInterval(3)),
            ],
            jitterMilliseconds: 80,
            lossRate: 0.5,
            averageLatencyMilliseconds: 60
        )

        // NodeSteady: current RTT 85ms, 0% packet loss, 4ms jitter
        let steadyStats = ProxyLatencyStats(
            samples: [
                ProxyLatencySample(latencyMilliseconds: 82, testedAt: base),
                ProxyLatencySample(latencyMilliseconds: 86, testedAt: base.addingTimeInterval(1)),
                ProxyLatencySample(latencyMilliseconds: 85, testedAt: base.addingTimeInterval(2)),
            ],
            jitterMilliseconds: 3,
            lossRate: 0.0,
            averageLatencyMilliseconds: 84
        )

        let ordered = ProxyFailoverPolicy.orderedCandidates(
            ["NodeLowRTTButFlaky", "NodeSteady"],
            preferred: nil,
            latencyByMember: [
                "NodeLowRTTButFlaky": 40,
                "NodeSteady": 85,
            ],
            statsByMember: [
                "NodeLowRTTButFlaky": flakyStats,
                "NodeSteady": steadyStats,
            ]
        )
        XCTAssertEqual(ordered, ["NodeSteady", "NodeLowRTTButFlaky"])

        // Preferred failover node stays first when explicitly pinned
        let orderedWithPreferred = ProxyFailoverPolicy.orderedCandidates(
            ["NodeLowRTTButFlaky", "NodeSteady"],
            preferred: "NodeLowRTTButFlaky",
            latencyByMember: [
                "NodeLowRTTButFlaky": 40,
                "NodeSteady": 85,
            ],
            statsByMember: [
                "NodeLowRTTButFlaky": flakyStats,
                "NodeSteady": steadyStats,
            ]
        )
        XCTAssertEqual(orderedWithPreferred, ["NodeLowRTTButFlaky", "NodeSteady"])
    }

    // MARK: - Helpers

    private static func makeValidMMDB(marker: UInt8) -> Data {
        var data = Data(repeating: marker, count: 1_536)
        let signature = Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
        data.replaceSubrange((data.count - signature.count)..<data.count, with: signature)
        return data
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ initial: Value) {
        storage = initial
    }

    var value: Value {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append<Element>(_ element: Element) where Value == [Element] {
        lock.lock()
        defer { lock.unlock() }
        storage.append(element)
    }
}

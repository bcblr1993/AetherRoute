import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

/// Pre-fix (RED) unit & Kit behavioral contracts for the v3.1.3 macOS UI & Kit audit.
/// Every test here asserts the post-fix contract and MUST fail on untouched v3.1.2 code
/// while leaving all pre-existing v3.1.2 tests green.
final class MacV313UIAuditKitTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(
            "MacV313UIAuditKitTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    // MARK: - MENU-02: LocalProxySettings + TerminalProxyEnvGenerator system-proxy guard parity

    func testMENU02_TerminalProxyEnvGeneratorAllowsSystemProxyWhenLocalPortDisabledAndLANOff() throws {
        let systemProxyOnly = LocalProxySettings(
            isEnabled: false,
            httpPort: 17_890,
            socksPort: 17_891,
            allowLAN: false,
            setAsSystemProxy: true
        )

        // Base method already allows setAsSystemProxy == true; dialect & PAC generators must match.
        let baseCommand = try systemProxyOnly.shellEnvironmentCommand()
        XCTAssertTrue(baseCommand.contains("127.0.0.1:17890"))

        for dialect in TerminalShellDialect.allCases {
            let cmd = try systemProxyOnly.shellEnvironmentCommand(dialect: dialect)
            XCTAssertTrue(
                cmd.contains("127.0.0.1:17890"),
                "Expected dialect \(dialect.rawValue) command when setAsSystemProxy is true"
            )
            XCTAssertTrue(
                cmd.contains("127.0.0.1:17891"),
                "Expected SOCKS port in dialect \(dialect.rawValue) command"
            )
        }

        let pac = try systemProxyOnly.pacScript()
        XCTAssertTrue(pac.contains("PROXY 127.0.0.1:17890"))
        XCTAssertTrue(pac.contains("SOCKS5 127.0.0.1:17891"))

        // Negative control: all flags false must still throw .disabled.
        let fullyDisabled = LocalProxySettings()
        XCTAssertThrowsError(try fullyDisabled.shellEnvironmentCommand(dialect: .zshBash)) { error in
            XCTAssertEqual(error as? LocalProxySettingsError, .disabled)
        }
        XCTAssertThrowsError(try fullyDisabled.pacScript()) { error in
            XCTAssertEqual(error as? LocalProxySettingsError, .disabled)
        }
    }

    // MARK: - MENU-18 / SYS-10: Missing LocalizedError conformance on AppAutomationPreferencesError

    func testMENU18_SYS10_AppAutomationPreferencesErrorConformsToLocalizedError() {
        let errors: [AppAutomationPreferencesError] = [
            .unsupportedVersion,
            .duplicateShortcut,
            .invalidNetworkRule,
            .tooManyNetworkRules,
        ]

        for error in errors {
            let localized = (error as Error) as? any LocalizedError
            XCTAssertNotNil(
                localized,
                "SYS-10 / MENU-18: AppAutomationPreferencesError.\(error) must conform to LocalizedError so Settings alerts do not display raw NSError code strings."
            )
            XCTAssertFalse(
                (localized?.errorDescription ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "AppAutomationPreferencesError.\(error) must provide a non-empty errorDescription."
            )
        }
    }

    // MARK: - PROF-03: ProfileCatalogStore concurrent read-modify-write serialization

    func testPROF03_ProfileCatalogStoreSerializesConcurrentMutationsWithoutDataLoss() async throws {
        let keyStore = InMemoryProfileKeyStore(
            keys: [EncryptedProfileCodec.defaultKeyID: Data(repeating: 0x5A, count: 32)]
        )
        let store = ProfileCatalogStore(directoryURL: tempDir, keyStore: keyStore)
        let workerCount = 16

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<workerCount {
                group.addTask {
                    let yaml = """
                    proxies:
                      - name: edge-\(index)
                        type: trojan
                        server: edge-\(index).example.com
                        port: 443
                        password: secret-\(index)
                    """
                    _ = try store.addValidated(
                        data: Data(yaml.utf8),
                        suggestedName: "Concurrent Profile \(index)"
                    )
                }
            }
            try await group.waitForAll()
        }

        let catalog = try store.loadOrMigrate()
        XCTAssertEqual(
            catalog.profiles.count,
            workerCount,
            "PROF-03: ProfileCatalogStore must synchronize read-modify-write mutations so concurrent add/update calls do not silently overwrite profiles."
        )
    }

    // MARK: - PROF-07: Cloud sync fails closed when iCloud storage is unavailable

    @MainActor
    func testPROF07_ProfileCloudSyncFailsClosedWithCloudUnavailableError() async throws {
        final class UnavailableCloudKVStore: CloudKeyValueStoring, @unchecked Sendable {
            func synchronize() -> Bool { false }
            func data(forKey defaultName: String) -> Data? { nil }
            func set(_ value: Any?, forKey defaultName: String) {}
        }

        let kvStore = UnavailableCloudKVStore()
        let keyStore = InMemoryProfileKeyStore()
        let catalogStore = ProfileCatalogStore(directoryURL: tempDir, keyStore: keyStore)
        let yaml = "proxies:\n  - {name: Edge-1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: secret}\n"
        _ = try catalogStore.addValidated(data: Data(yaml.utf8), suggestedName: "Local Profile")

        let manager = ProfileCloudSyncManager(
            kvStore: kvStore,
            keyStore: keyStore,
            catalogStore: catalogStore,
            deviceIdentifier: "mac-cloud-check",
            deviceName: "Mac Cloud Check"
        )
        manager.isCloudSyncEnabled = true

        do {
            _ = try await manager.sync()
            XCTFail("PROF-07: sync() must throw CloudSyncError.cloudUnavailable when cloud KVS/iCloud identity is unavailable")
        } catch let error as CloudSyncError {
            XCTAssertEqual(error, .cloudUnavailable)
        }
        XCTAssertFalse(manager.isSyncing)

        do {
            _ = try await manager.forcePullFromCloud()
            XCTFail("PROF-07: forcePullFromCloud() must throw CloudSyncError.cloudUnavailable when iCloud storage is unavailable")
        } catch let error as CloudSyncError {
            XCTAssertEqual(error, .cloudUnavailable)
        }
        XCTAssertFalse(manager.isSyncing)

        do {
            _ = try await manager.forcePushToCloud()
            XCTFail("PROF-07: forcePushToCloud() must throw CloudSyncError.cloudUnavailable when iCloud storage is unavailable")
        } catch let error as CloudSyncError {
            XCTAssertEqual(error, .cloudUnavailable)
        }
        XCTAssertFalse(manager.isSyncing)
    }

    // MARK: - PROF-09: ProxyProviderEngine redacts URLs & query tokens in lastError

    func testPROF09_ProxyProviderEngineRedactsSensitiveURLCredentialsAndTokensInLastError() async throws {
        let storageDir = tempDir.appendingPathComponent("ProxyProviders", isDirectory: true)
        let secretURL = URL(string: "https://provider.example.com/api/v1/subscribe?token=TOKEN_XYZ_987654&flag=clash")!

        let engine = ProxyProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                throw NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorCannotConnectToHost,
                    userInfo: [
                        NSURLErrorFailingURLStringErrorKey: requestURL.absoluteString,
                        NSLocalizedDescriptionKey: "Connection failed to \(requestURL.absoluteString)",
                    ]
                )
            }
        )

        let metadata = ProxyProviderMetadata(name: "SecretSub", url: secretURL)
        try await engine.addProvider(metadata)

        do {
            _ = try await engine.fetchAndStage(id: metadata.id, force: true)
            XCTFail("Expected fetchAndStage to throw simulated network error")
        } catch {
            // Expected failure
        }

        let stored = await engine.provider(id: metadata.id)
        let lastError = try XCTUnwrap(stored?.lastError)
        XCTAssertFalse(
            lastError.contains("TOKEN_XYZ_987654"),
            "PROF-09: ProxyProviderMetadata.lastError leaked raw query token: \(lastError)"
        )
        XCTAssertFalse(
            lastError.contains("flag=clash"),
            "PROF-09: ProxyProviderMetadata.lastError leaked query string: \(lastError)"
        )
    }

    // MARK: - RULE-03: RouteMatchEngine evaluates past deterministic non-matching structured AND

    func testRULE03_RouteMatchEngineSkipsDefiniteNonMatchingBlockQUICANDRule() {
        // Explicit TCP/HTTP port 80 destination cannot satisfy (DST-PORT,443) in Block QUIC preset
        // AND,((NETWORK,UDP),(DST-PORT,443)),REJECT, while preserving .indeterminate for opaque AND rules.
        let rules = [
            RuleConfigurationSummary(
                id: 0,
                order: 1,
                kind: "AND",
                criteria: "((NETWORK,UDP),(DST-PORT,443))",
                target: "REJECT",
                isCustom: true
            ),
            RuleConfigurationSummary(
                id: 1,
                order: 2,
                kind: "DOMAIN-SUFFIX",
                criteria: "openai.com",
                target: "PROXY"
            ),
            RuleConfigurationSummary(
                id: 2,
                order: 3,
                kind: "MATCH",
                criteria: nil,
                target: "DIRECT"
            ),
        ]

        let assessment = RouteMatchEngine.assess(destination: "api.openai.com:80", against: rules)
        guard case let .matched(result) = assessment else {
            return XCTFail(
                "RULE-03: Expected api.openai.com:80 to evaluate past structured Block QUIC AND rule to rule #2 (PROXY), got \(assessment)"
            )
        }
        XCTAssertEqual(result.order, 2)
        XCTAssertEqual(result.target, "PROXY")
    }

    // MARK: - RULE-08: DomesticRoutingOptimizer respects Domestic & LAN scenario preset target != DIRECT

    func testRULE08_DomesticRoutingOptimizerRespectsCustomDomesticScenarioPresetTarget() {
        let baseYAML = """
        mode: rule
        proxies:
          - {name: CNEdge, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: secret}
          - {name: GlobalEdge, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: secret}
        proxy-groups:
          - {name: CNProxy, type: select, proxies: [CNEdge]}
          - {name: Proxy, type: select, proxies: [GlobalEdge]}
        rules:
          - MATCH,Proxy
        """

        let presets = [
            ScenarioRulePresetState(id: .domesticAndLANBoost, isEnabled: true, target: .group("CNProxy")),
        ]
        let override = ProfileOverride(scenarioPresets: presets)
        let compiled = ProfileOverrideCompiler.apply(override, to: baseYAML)
        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: compiled.yaml,
            enableDomesticDirect: true
        )

        let rules = optimized
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.hasPrefix("- ") }

        guard let customGeoSiteIdx = rules.firstIndex(of: "- GEOSITE,cn,CNProxy") else {
            return XCTFail("Expected compiled GEOSITE,cn,CNProxy rule in optimized YAML:\n\(optimized)")
        }
        if let directGeoSiteIdx = rules.firstIndex(of: "- GEOSITE,cn,DIRECT") {
            XCTAssertLessThan(
                customGeoSiteIdx,
                directGeoSiteIdx,
                "RULE-08: User-configured Domestic & LAN preset target (CNProxy) must take precedence over DomesticRoutingOptimizer's highPriorityBypassRules (GEOSITE,cn,DIRECT)."
            )
        }

        if let customGeoIPPrivateIdx = rules.firstIndex(of: "- GEOIP,private,CNProxy,no-resolve"),
           let directPrivateIdx = rules.firstIndex(of: "- IP-CIDR,192.168.0.0/16,DIRECT,no-resolve") {
            XCTAssertLessThan(
                customGeoIPPrivateIdx,
                directPrivateIdx,
                "RULE-08: Custom Domestic & LAN preset target must precede highPriorityBypassRules RFC1918 DIRECT bypasses."
            )
        }
    }

    // MARK: - CONNDNS-07: DNSRecentQueryStore direct-bypass kind & chain deduplication

    func testCONNDNS07_DNSRecentQueryStoreAvoidsFalseFakeIPLabelAndDuplicateChain() throws {
        var store = DNSRecentQueryStore()
        let directConnection = ConnectionTelemetry(
            transport: .tcp,
            destination: "baidu.com",
            destinationPort: 443,
            uploadTotal: 256,
            downloadTotal: 1_024,
            startedAtUnixMilliseconds: 1_700_000_600_000,
            rule: "DOMAIN-SUFFIX",
            rulePayload: "baidu.com",
            proxyChain: "DIRECT",
            dnsDurationMilliseconds: 5,
            connectDurationMilliseconds: 12
        )

        store.ingestConnections(
            [directConnection],
            runtimePolicy: DNSRuntimePolicy(resolutionMode: .fakeIP)
        )

        let entry = try XCTUnwrap(store.entries.first)
        XCTAssertNotEqual(
            entry.kind,
            .fakeIP,
            "CONNDNS-07: Bypassed DIRECT flow without any 198.18.0.0/15 Fake-IP address must not be labeled .fakeIP."
        )
        XCTAssertNotEqual(
            entry.resolvedValue,
            entry.upstreamLabel,
            "CONNDNS-07: DNSRecentQueryRecord must not duplicate proxyChain across both resolvedValue and upstreamLabel."
        )
    }

    // MARK: - CONNDNS-10: ProfileOverrideCompiler ensures use-hosts: true when active customHosts exist

    func testCONNDNS10_ProfileOverrideCompilerEnablesUseHostsWhenActiveCustomHostsPresent() {
        let yamlWithUseHostsFalse = """
        dns:
          enable: true
          use-hosts: false
          enhanced-mode: fake-ip
          nameserver:
            - 223.5.5.5
        proxies:
          - {name: Edge-1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: secret}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [Edge-1]}
        rules:
          - MATCH,Proxy
        """

        let override = ProfileOverride(
            customHosts: [
                CustomHostMapping(domain: "api.internal.example", ip: "203.0.113.42", isEnabled: true),
            ]
        )

        let compiled = ProfileOverrideCompiler.apply(override, to: yamlWithUseHostsFalse)
        let summary = ProfileConfigurationInspector.inspect(yaml: compiled.yaml)

        XCTAssertTrue(
            summary.dns.usesHosts,
            "CONNDNS-10: Applying active customHosts overrides must enable `dns.use-hosts: true` instead of leaving `use-hosts: false` silently ignoring custom host mappings."
        )
        XCTAssertTrue(compiled.yaml.contains("api.internal.example"))
        XCTAssertTrue(compiled.yaml.contains("203.0.113.42"))
    }

    // MARK: - MENU-19: PortableProfileArchiveError binds formatters to AppLocalizationLocaleBridge

    func testMENU19_PortableProfileArchiveErrorRespectsAppLocalizationLocaleBridge() {
        let previousLocale = AppLocalizationLocaleBridge.currentLocale
        defer { AppLocalizationLocaleBridge.register { previousLocale } }

        AppLocalizationLocaleBridge.register { Locale(identifier: "ar_EG@numbers=arab") }
        let arabicDesc = PortableProfileArchiveError.weakPassword(8).errorDescription ?? ""
        XCTAssertTrue(
            arabicDesc.contains("٨"),
            "MENU-19: PortableProfileArchiveError must bind String(format:locale:) to AppLocalizationLocaleBridge.currentLocale, got: \(arabicDesc)"
        )

        AppLocalizationLocaleBridge.register { Locale(identifier: "en_US") }
        let englishDesc = PortableProfileArchiveError.weakPassword(8).errorDescription ?? ""
        XCTAssertTrue(
            englishDesc.contains("8"),
            "MENU-19: PortableProfileArchiveError must update when AppLocalizationLocaleBridge changes, got: \(englishDesc)"
        )
    }

    // MARK: - PROXY-10: ProxyLatencyState.resultsByMember & O(1) ProxyLatencyReading.resolve

    func testPROXY10_ProxyLatencyStateBuildsResultsByMemberAndResolvesReadings() {
        var index = ProxyLatencyIndex()
        index.beginRun(
            groups: [("Balanced", ["NodeA", "NodeB", "NodeC", "NodeA"])],
            testURL: "https://cp.cloudflare.com/generate_204"
        )
        index.merge(member: "NodeA", measurement: .verified(42))
        index.merge(member: "NodeB", measurement: .timedOut)

        let state = index.state(for: "Balanced")
        XCTAssertEqual(state.resultsByMember["NodeA"]?.delayMilliseconds, 42)
        XCTAssertNotNil(state.resultsByMember["NodeB"])
        XCTAssertNil(state.resultsByMember["NodeB"]?.delayMilliseconds)
        XCTAssertNil(state.resultsByMember["NodeC"])

        XCTAssertEqual(
            ProxyLatencyReading.resolve(member: "NodeA", state: state, isTesting: true),
            .responded(42)
        )
        XCTAssertEqual(
            ProxyLatencyReading.resolve(member: "NodeB", state: state, isTesting: true),
            .timedOut
        )
        XCTAssertEqual(
            ProxyLatencyReading.resolve(member: "NodeC", state: state, isTesting: true),
            .testing
        )
        XCTAssertEqual(
            ProxyLatencyReading.resolve(member: "NodeC", state: state, isTesting: false),
            .untested
        )
        XCTAssertEqual(
            ProxyLatencyReading.resolve(
                member: "NodeA",
                resultsByMember: state.resultsByMember,
                isTesting: false
            ),
            .responded(42)
        )
    }

    // MARK: - RULE-03: RouteMatchEngine evaluates PROCESS-NAME, PROCESS-PATH, NETWORK, DOMAIN-WILDCARD, DOMAIN-REGEX, IP-ASN

    func testRULE03_RouteMatchEngineEvaluatesNewlySupportedRuleKindsAndRespectsNoResolve() {
        let fallbackRule = RuleConfigurationSummary(
            id: 99,
            order: 99,
            kind: "MATCH",
            criteria: nil,
            target: "DIRECT"
        )

        // 1. PROCESS-NAME (matches basename from processName or processPath, skips mismatch/absent)
        let procNameRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "PROCESS-NAME", criteria: "curl", target: "PROXY", isCustom: true),
            fallbackRule,
        ]
        if case let .matched(hit) = RouteMatchEngine.assess(destination: "example.com:443", against: procNameRules, processPath: "/usr/bin/curl") {
            XCTAssertEqual(hit.order, 1)
            XCTAssertEqual(hit.target, "PROXY")
        } else {
            XCTFail("Expected PROCESS-NAME rule to match processPath basename")
        }
        if case let .matched(miss) = RouteMatchEngine.assess(destination: "example.com:443", against: procNameRules, processName: "Safari") {
            XCTAssertEqual(miss.order, 99)
        } else {
            XCTFail("Expected PROCESS-NAME mismatch to continue to MATCH rule")
        }

        // 2. PROCESS-PATH (matches exact path, skips basename mismatch, returns .indeterminate when only processName matches basename)
        let procPathRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "PROCESS-PATH", criteria: "/usr/bin/curl", target: "PROXY", isCustom: true),
            fallbackRule,
        ]
        if case let .matched(hit) = RouteMatchEngine.assess(destination: "example.com:443", against: procPathRules, processPath: "/usr/bin/curl") {
            XCTAssertEqual(hit.order, 1)
        } else {
            XCTFail("Expected PROCESS-PATH exact match")
        }
        if case let .matched(diffPath) = RouteMatchEngine.assess(destination: "example.com:443", against: procPathRules, processPath: "/opt/bin/curl") {
            XCTAssertEqual(diffPath.order, 99)
        } else {
            XCTFail("Expected mismatched PROCESS-PATH to skip to fallback")
        }
        XCTAssertEqual(
            RouteMatchEngine.assess(destination: "example.com:443", against: procPathRules, processName: "curl"),
            .indeterminate(ruleOrder: 1)
        )

        // 3. NETWORK (explicit network parameter or scheme transport)
        let networkRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "NETWORK", criteria: "UDP", target: "REJECT", isCustom: true),
            fallbackRule,
        ]
        if case let .matched(udpHit) = RouteMatchEngine.assess(destination: "udp://1.1.1.1:53", against: networkRules) {
            XCTAssertEqual(udpHit.order, 1)
            XCTAssertEqual(udpHit.target, "REJECT")
        } else {
            XCTFail("Expected udp:// scheme to satisfy NETWORK,UDP")
        }
        if case let .matched(tcpSkip) = RouteMatchEngine.assess(destination: "example.com:443", against: networkRules, network: "tcp") {
            XCTAssertEqual(tcpSkip.order, 99)
        } else {
            XCTFail("Expected tcp network to skip NETWORK,UDP")
        }
        XCTAssertEqual(
            RouteMatchEngine.assess(destination: "example.com:443", against: networkRules),
            .indeterminate(ruleOrder: 1)
        )

        // 4. DOMAIN-WILDCARD
        let wildcardRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "DOMAIN-WILDCARD", criteria: "*.corp.?.example", target: "PROXY", isCustom: true),
            fallbackRule,
        ]
        if case let .matched(wcHit) = RouteMatchEngine.assess(destination: "api.corp.a.example:443", against: wildcardRules) {
            XCTAssertEqual(wcHit.order, 1)
        } else {
            XCTFail("Expected DOMAIN-WILDCARD match")
        }
        if case let .matched(wcSkip) = RouteMatchEngine.assess(destination: "api.corp.ab.example:443", against: wildcardRules) {
            XCTAssertEqual(wcSkip.order, 99)
        } else {
            XCTFail("Expected DOMAIN-WILDCARD single-char '?' mismatch to skip")
        }

        // 5. DOMAIN-REGEX (requires regex metacharacters; opaque criteria stays .indeterminate)
        let regexRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "DOMAIN-REGEX", criteria: #"^api-[0-9]+\.example\.com$"#, target: "PROXY", isCustom: true),
            fallbackRule,
        ]
        if case let .matched(rxHit) = RouteMatchEngine.assess(destination: "api-42.example.com:443", against: regexRules) {
            XCTAssertEqual(rxHit.order, 1)
        } else {
            XCTFail("Expected DOMAIN-REGEX match")
        }
        if case let .matched(rxSkip) = RouteMatchEngine.assess(destination: "web.example.com:443", against: regexRules) {
            XCTAssertEqual(rxSkip.order, 99)
        } else {
            XCTFail("Expected DOMAIN-REGEX mismatch to skip")
        }
        let opaqueRegexRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "DOMAIN-REGEX", criteria: "google", target: "PROXY", isCustom: true),
            fallbackRule,
        ]
        XCTAssertEqual(
            RouteMatchEngine.assess(destination: "mail.google.com:443", against: opaqueRegexRules),
            .indeterminate(ruleOrder: 1)
        )

        // 6. IP-ASN (respects noResolve on hostnames and asnLookup on IPs)
        let asnNoResolveRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "IP-ASN", criteria: "13335", target: "PROXY", isCustom: true, noResolve: true),
            fallbackRule,
        ]
        if case let .matched(domainSkip) = RouteMatchEngine.assess(destination: "example.com:443", against: asnNoResolveRules) {
            XCTAssertEqual(domainSkip.order, 99)
        } else {
            XCTFail("Expected IP-ASN with noResolve=true to skip unresolved hostname")
        }
        if case let .matched(asnHit) = RouteMatchEngine.assess(
            destination: "1.1.1.1:443",
            against: asnNoResolveRules,
            asnLookup: { $0 == "1.1.1.1" ? "AS13335" : nil }
        ) {
            XCTAssertEqual(asnHit.order, 1)
        } else {
            XCTFail("Expected IP-ASN lookup match")
        }
        let asnResolveRules = [
            RuleConfigurationSummary(id: 1, order: 1, kind: "IP-ASN", criteria: "13335", target: "PROXY", isCustom: true, noResolve: false),
            fallbackRule,
        ]
        XCTAssertEqual(
            RouteMatchEngine.assess(destination: "example.com:443", against: asnResolveRules),
            .indeterminate(ruleOrder: 1)
        )
    }

    // MARK: - RULE-11: Structured CustomRuleValidationIssue + Parse/Store error descriptions

    func testRULE11_StructuredCustomRuleValidationIssuesAndErrors() {
        XCTAssertNil(CustomRuleValidator.validateIssue(kind: .domain, value: "api.example.com", target: .direct))
        XCTAssertEqual(
            CustomRuleValidator.validateIssue(kind: .domain, value: "   ", target: .direct),
            .emptyCriteria
        )
        XCTAssertEqual(
            CustomRuleValidator.validateIssue(kind: .domain, value: "bad host", target: .direct),
            .domainForbiddenCharacters
        )
        XCTAssertEqual(
            CustomRuleValidator.validateIssue(kind: .ipCIDR, value: "10.0.0.1/24", target: .direct),
            .ipv4CIDRHostBitsNonZero("10.0.0.0", 24)
        )
        XCTAssertEqual(
            CustomRuleValidator.validateIssue(kind: .network, value: "ICMP", target: .reject),
            .networkInvalid
        )
        XCTAssertEqual(
            CustomRuleValidator.validateIssue(kind: .processPath, value: "curl", target: .direct),
            .processPathFormat
        )
        XCTAssertFalse(CustomRuleStoreError.tooManyRules(550).localizedDescription.isEmpty)
        XCTAssertFalse(CustomRuleParseError.insufficientComponents.localizedDescription.isEmpty)
    }

    // MARK: - CONNDNS-07: DNSRecentQueryStore deduplicates active flows beyond 256 entries

    func testCONNDNS07_DNSRecentQueryStoreRetainsActiveFlowDeduplicationPast256() {
        var store = DNSRecentQueryStore()
        let activeConnections: [ConnectionTelemetry] = (0..<300).map { index in
            ConnectionTelemetry(
                transport: .tcp,
                destination: "host-\(index).example.com",
                destinationPort: 443,
                uploadTotal: 100,
                downloadTotal: 200,
                startedAtUnixMilliseconds: 1_700_000_000_000 + UInt64(index),
                rule: "DOMAIN-SUFFIX",
                rulePayload: "example.com",
                proxyChain: "DIRECT",
                dnsDurationMilliseconds: 4,
                connectDurationMilliseconds: 10
            )
        }

        store.ingestConnections(activeConnections, runtimePolicy: DNSRuntimePolicy(resolutionMode: .fakeIP))
        XCTAssertEqual(store.count, DNSRecentQueryStore.maxEntries)
        let entriesAfterFirstTick = store.entries

        // On tick 2, all 300 flows remain active: index 0..43 must NOT be evicted from activeConnectionKeys
        // and re-logged as fresh queries.
        store.ingestConnections(activeConnections, runtimePolicy: DNSRuntimePolicy(resolutionMode: .fakeIP))
        XCTAssertEqual(
            store.entries,
            entriesAfterFirstTick,
            "CONNDNS-07: Long-lived active connections beyond 256 flows must remain deduplicated across telemetry ticks."
        )
    }

    // MARK: - CONNDNS-08: DNSRecentQueryStore.clear(suppressingActiveConnections:) prevents bounce-back

    func testCONNDNS08_DNSRecentQueryStoreSuppressesClearedActiveFlows() {
        var store = DNSRecentQueryStore()
        let activeFlow = ConnectionTelemetry(
            transport: .tcp,
            destination: "active.example.com",
            destinationPort: 443,
            uploadTotal: 64,
            downloadTotal: 128,
            startedAtUnixMilliseconds: 1_700_000_100_000,
            rule: "DOMAIN",
            rulePayload: "active.example.com",
            proxyChain: "DIRECT",
            dnsDurationMilliseconds: 3,
            connectDurationMilliseconds: 8
        )
        let newFlow = ConnectionTelemetry(
            transport: .tcp,
            destination: "fresh.example.com",
            destinationPort: 443,
            uploadTotal: 64,
            downloadTotal: 128,
            startedAtUnixMilliseconds: 1_700_000_200_000,
            rule: "DOMAIN",
            rulePayload: "fresh.example.com",
            proxyChain: "DIRECT",
            dnsDurationMilliseconds: 5,
            connectDurationMilliseconds: 9
        )

        store.ingestConnections([activeFlow])
        XCTAssertEqual(store.count, 1)

        store.clear(suppressingActiveConnections: [activeFlow])
        XCTAssertTrue(store.isEmpty)

        // Same active flow arriving on the next tick stays suppressed; a newly started flow is recorded.
        store.ingestConnections([activeFlow])
        XCTAssertTrue(store.isEmpty, "CONNDNS-08: Suppressed active flow bounced back after clear.")

        store.ingestConnections([activeFlow, newFlow])
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.entries.first?.domain, "fresh.example.com")
    }

    // MARK: - CONNDNS-17: DNSRecentQueryRecord classifies policy tokens while preserving raw resolvedValue

    func testCONNDNS17_DNSRecentQueryRecordResolvedPolicyKind() {
        let direct = DNSRecentQueryRecord(
            domain: "baidu.com",
            queryType: .a,
            resolvedValue: "DIRECT",
            kind: .direct,
            upstreamLabel: "System DNS"
        )
        let reject = DNSRecentQueryRecord(
            domain: "ads.example.com",
            queryType: .a,
            resolvedValue: "REJECT",
            kind: .rejected,
            upstreamLabel: "Rule Policy"
        )
        let rejectDrop = DNSRecentQueryRecord(
            domain: "quic.example.com",
            queryType: .a,
            resolvedValue: "REJECT-DROP",
            kind: .rejected,
            upstreamLabel: "Rule Policy"
        )
        let literalIP = DNSRecentQueryRecord(
            domain: "api.openai.com",
            queryType: .a,
            resolvedValue: "198.18.0.12",
            kind: .fakeIP,
            upstreamLabel: "Fake-IP"
        )

        XCTAssertEqual(direct.resolvedPolicyKind, .direct)
        XCTAssertEqual(direct.resolvedValue, "DIRECT")
        XCTAssertEqual(reject.resolvedPolicyKind, .reject)
        XCTAssertEqual(rejectDrop.resolvedPolicyKind, .rejectDrop)
        XCTAssertNil(literalIP.resolvedPolicyKind)
        XCTAssertEqual(literalIP.resolvedValue, "198.18.0.12")
    }
}

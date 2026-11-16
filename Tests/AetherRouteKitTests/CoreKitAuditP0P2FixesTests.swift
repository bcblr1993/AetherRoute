import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class CoreKitAuditP0P2FixesTests: XCTestCase {
    private final class MockSystemProxyExecutor: SystemProxyCommandExecuting, @unchecked Sendable {
        var activeServices: [String] = ["Wi-Fi"]
        var webState: [String: (Bool, String, Int)] = [:]
        var secureState: [String: (Bool, String, Int)] = [:]
        var socksState: [String: (Bool, String, Int)] = [:]
        var bypassState: [String: [String]] = [:]
        var failCommandForService: (command: String, service: String)?
        var commandsExecuted: [[String]] = []

        func run(executablePath: String, arguments: [String]) throws -> SystemProxyCommandOutput {
            commandsExecuted.append(arguments)
            let cmd = arguments.first ?? ""
            if cmd == "-listallnetworkservices" {
                let body = (["An asterisk (*) denotes that a network service is disabled."] + activeServices)
                    .joined(separator: "\n")
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: body, standardError: "")
            }
            guard arguments.count >= 2 else {
                return SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "missing service")
            }
            let service = arguments[1]
            if let fail = failCommandForService, fail.command == cmd, fail.service == service {
                return SystemProxyCommandOutput(exitCode: 4, standardOutput: "", standardError: "injected error")
            }
            if !activeServices.contains(service) {
                return SystemProxyCommandOutput(exitCode: 4, standardOutput: "", standardError: "\(service) is not a recognized network service")
            }

            func format(_ state: (Bool, String, Int)) -> String {
                "Enabled: \(state.0 ? "Yes" : "No")\nServer: \(state.1)\nPort: \(state.2)\n"
            }

            switch cmd {
            case "-getwebproxy":
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: format(webState[service] ?? (false, "", 0)), standardError: "")
            case "-getsecurewebproxy":
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: format(secureState[service] ?? (false, "", 0)), standardError: "")
            case "-getsocksfirewallproxy":
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: format(socksState[service] ?? (false, "", 0)), standardError: "")
            case "-getproxybypassdomains":
                let domains = bypassState[service] ?? []
                let out = domains.isEmpty ? "There aren't any bypass domains set on \(service).\n" : domains.joined(separator: "\n")
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: out, standardError: "")
            case "-setwebproxy":
                let prev = webState[service] ?? (false, "", 0)
                webState[service] = (prev.0, arguments[2], Int(arguments[3]) ?? 0)
            case "-setwebproxystate":
                let prev = webState[service] ?? (false, "", 0)
                webState[service] = (arguments[2].lowercased() == "on", prev.1, prev.2)
            case "-setsecurewebproxy":
                let prev = secureState[service] ?? (false, "", 0)
                secureState[service] = (prev.0, arguments[2], Int(arguments[3]) ?? 0)
            case "-setsecurewebproxystate":
                let prev = secureState[service] ?? (false, "", 0)
                secureState[service] = (arguments[2].lowercased() == "on", prev.1, prev.2)
            case "-setsocksfirewallproxy":
                let prev = socksState[service] ?? (false, "", 0)
                socksState[service] = (prev.0, arguments[2], Int(arguments[3]) ?? 0)
            case "-setsocksfirewallproxystate":
                let prev = socksState[service] ?? (false, "", 0)
                socksState[service] = (arguments[2].lowercased() == "on", prev.1, prev.2)
            case "-setproxybypassdomains":
                let domains = Array(arguments.dropFirst(2))
                bypassState[service] = domains == ["Empty"] ? [] : domains
            default:
                return SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "unknown")
            }
            return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    // MARK: - 1. CloudSync Catalog Reconciliation, Canonical URL & Rule Merge

    func testCloudSyncReconcilePreservesMergedSpecAndCanonicalURLMatchesRootAndPorts() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoreKitAudit-Catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }

        let keyStore = InMemoryProfileKeyStore()
        let store = ProfileCatalogStore(directoryURL: dir, keyStore: keyStore)
        let profileID = UUID()
        let srcID = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)
        let yaml = """
        proxies:
          - {name: Edge, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: secret}
        """

        let localCatalog = ProfileCatalog(
            activeProfileID: profileID,
            profiles: [
                ManagedProfile(
                    id: profileID,
                    profile: ActiveProfile(name: "Merged Local", yaml: yaml, importedAt: t1),
                    updatedAt: t1,
                    mergedSpec: nil
                ),
            ]
        )
        _ = try store.reconcileCloudSync(localCatalog)

        let expectedSpec = MergedProfileSpec(sourceProfileIDs: [srcID], prefixSourceName: false, deduplicateByServerPort: true)
        let remoteCatalog = ProfileCatalog(
            activeProfileID: profileID,
            profiles: [
                ManagedProfile(
                    id: profileID,
                    profile: ActiveProfile(name: "Merged Remote", yaml: yaml, importedAt: t2),
                    updatedAt: t2,
                    mergedSpec: expectedSpec
                ),
            ]
        )
        let reconciled = try store.reconcileCloudSync(remoteCatalog)
        XCTAssertEqual(reconciled.profiles.first?.mergedSpec, expectedSpec)

        let urlA = URL(string: "https://sub.example.com:443/#frag")!
        let urlB = URL(string: "HTTPS://SUB.EXAMPLE.COM")!
        XCTAssertEqual(ProfileCatalogStore.canonicalSubscriptionURL(urlA), ProfileCatalogStore.canonicalSubscriptionURL(urlB))

        let pathA = URL(string: "https://sub.example.com:443/api/sub/#frag")!
        let pathB = URL(string: "https://sub.example.com/api/sub")!
        XCTAssertEqual(ProfileCatalogStore.canonicalSubscriptionURL(pathA), ProfileCatalogStore.canonicalSubscriptionURL(pathB))
    }

    func testUserRuleSyncMergeDedupPrefersNewerModifiedAtAcrossDifferentIDs() {
        let olderID = UUID()
        let newerID = UUID()
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_001_000)

        let localRule = CustomRule(id: olderID, kind: .domainSuffix, value: "example.com", target: .direct)
        let remoteRule = CustomRule(id: newerID, kind: .domainSuffix, value: "example.com", target: .proxy("HK-01"))

        let merged = UserRuleSyncMerge.merge(
            local: [localRule],
            localMetadata: RuleSyncMetadata(modifiedAt: [olderID.uuidString: t1]),
            remote: [remoteRule],
            remoteMetadata: RuleSyncMetadata(modifiedAt: [newerID.uuidString: t2]),
            dedupKey: { "\($0.kind.rawValue)|\($0.value.lowercased())" },
            isValid: { _ in true },
            limit: 512
        )

        XCTAssertEqual(merged.rules.count, 1)
        XCTAssertEqual(merged.rules.first?.id, newerID)
        XCTAssertEqual(merged.rules.first?.target, .proxy("HK-01"))
    }

    // MARK: - 2. External Control URL Scheme & Duplicate Parameters

    func testExternalLinkParserEnforcesAllowControlActionsBeforeInvalidActionAndRejectsDuplicateSwitchProfileParams() throws {
        for raw in [
            "aetherroute://connect/extra",
            "aetherroute://disconnect#frag",
            "aetherroute://mode?mode=direct",
            "aetherroute://profile?name=Work",
        ] {
            let url = try XCTUnwrap(URL(string: raw))
            XCTAssertThrowsError(try ExternalSubscriptionLinkParser.parseAction(url, allowControlActions: false)) { error in
                XCTAssertEqual(error as? ExternalSubscriptionLinkError, .controlActionsDisabled, raw)
            }
        }

        for duplicate in [
            "aetherroute://switch-profile?name=Alpha&name=Beta",
            "aetherroute://switch-profile?id=11111111-1111-1111-1111-111111111111&id=22222222-2222-2222-2222-222222222222",
        ] {
            let url = try XCTUnwrap(URL(string: duplicate))
            XCTAssertThrowsError(try ExternalSubscriptionLinkParser.parseAction(url, allowControlActions: true)) { error in
                XCTAssertEqual(error as? ExternalSubscriptionLinkError, .invalidParameters, duplicate)
            }
        }
    }

    // MARK: - 3. SystemProxyConfigurator Vanished Interface & Partial Rollback

    func testSystemProxyConfiguratorSkipsVanishedServiceDuringRestoreAndRollsBackPartialApply() throws {
        let suite = "CoreKitAudit-SysProxy-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let executor = MockSystemProxyExecutor()
        executor.activeServices = ["USB 10/100/1000 LAN", "Wi-Fi"]
        executor.webState["Wi-Fi"] = (true, "10.0.0.5", 8080)
        executor.bypassState["Wi-Fi"] = ["corp.local"]

        let configurator = SystemProxyConfigurator(executor: executor, defaults: defaults)
        try configurator.apply(settings: LocalProxySettings(httpPort: 17890, socksPort: 17891, setAsSystemProxy: true))
        XCTAssertTrue(configurator.hasPendingBackup)

        // Unplug USB dongle before restore
        executor.activeServices = ["Wi-Fi"]
        try configurator.restorePendingIfNeeded()
        XCTAssertFalse(configurator.hasPendingBackup)
        XCTAssertEqual(executor.webState["Wi-Fi"]?.0, true)
        XCTAssertEqual(executor.webState["Wi-Fi"]?.1, "10.0.0.5")
        XCTAssertEqual(executor.webState["Wi-Fi"]?.2, 8080)

        // Partial apply failure on second service must roll back Wi-Fi
        executor.activeServices = ["Wi-Fi", "USB 10/100/1000 LAN"]
        executor.failCommandForService = ("-setsocksfirewallproxy", "USB 10/100/1000 LAN")
        XCTAssertThrowsError(
            try configurator.apply(settings: LocalProxySettings(httpPort: 17890, socksPort: 17891, setAsSystemProxy: true))
        )
        XCTAssertEqual(executor.webState["Wi-Fi"]?.0, true)
        XCTAssertEqual(executor.webState["Wi-Fi"]?.1, "10.0.0.5")
        XCTAssertEqual(executor.webState["Wi-Fi"]?.2, 8080)
        XCTAssertEqual(executor.bypassState["Wi-Fi"], ["corp.local"])
    }

    // MARK: - 4. RouteSimulator Depth Cap & Codec Decode Bounds

    func testRouteSimulationCapsLogicalRecursionAndCodecRejectsOutOfBoundsTraceRoute() throws {
        var expr = "(DOMAIN,deep.example.com)"
        for _ in 0..<20 {
            expr = "(AND,\(expr),(NETWORK,tcp))"
        }
        let innerCriteria = String(expr.dropFirst("(AND,".count).dropLast())
        let yaml = """
        proxies:
          - {name: P1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [P1]}
        rules:
          - AND,\(innerCriteria),PROXY
          - MATCH,DIRECT
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
        let result = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "deep.example.com", port: 443, network: .tcp),
            routingMode: .rule,
            profileYAML: yaml,
            summary: summary
        )
        XCTAssertEqual(result.matchedRuleKind, "MATCH")
        XCTAssertEqual(result.targetOutbound, "DIRECT")

        for badRequest in [
            RouteTraceRequest(host: "   ", port: 443),
            RouteTraceRequest(host: "example.com", port: 0),
            RouteTraceRequest(host: "example.com", port: 70_000),
        ] {
            let encoded = try ProxySelectionProviderMessageCodec.encode(request: .traceRoute(badRequest))
            XCTAssertThrowsError(try ProxySelectionProviderMessageCodec.decodeRequest(encoded)) { error in
                XCTAssertEqual(error as? ProxySelectionProviderMessageError, .malformed)
            }
        }
    }

    // MARK: - 5. DomesticRoutingOptimizer Clean Hygiene, Preamble, DNS Preservation & Flow Policy

    func testDomesticRoutingOptimizerRemovesThirdPartyLiteralsAndPreservesPreambleDNSAndUserPolicy() throws {
        let input = """
        ---
        mode: rule
        dns:
          enable: true
          prefer-h3: true
          direct-nameserver:
            - 223.6.6.6
          fallback-filter:
            domain:
              - '+.example.org'
            geosite:
              - gfw
          nameserver-policy: {"'+.corp.a,+.corp.b'": ['223.5.5.5', '119.29.29.29'], '+.apple.com': 'https://dns.alidns.com/dns-query'}
        proxies:
          - {name: S1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: G1, type: select, proxies: [S1]}
        rules:
          - MATCH,G1
        """

        let output = DomesticRoutingOptimizer.optimizedProfile(
            for: input,
            providerBaseDirectoryURL: nil
        )
        XCTAssertFalse(output.contains("baizhiedu.xin"))
        XCTAssertFalse(output.contains("82.157.10.147"))
        XCTAssertFalse(output.contains("headscale"))

        let docMarkerIdx = try XCTUnwrap(output.range(of: "---")?.lowerBound)
        let dnsIdx = try XCTUnwrap(output.range(of: "dns:")?.lowerBound)
        XCTAssertLessThan(docMarkerIdx, dnsIdx, "--- preamble must remain before dns:")

        XCTAssertTrue(output.contains("prefer-h3: true"), "Unrecognized Mihomo DNS scalar key must survive:\n\(output)")
        XCTAssertTrue(output.contains("direct-nameserver:"), "direct-nameserver list must survive:\n\(output)")
        XCTAssertTrue(output.contains("223.6.6.6"))
        XCTAssertTrue(output.contains("+.example.org"), "fallback-filter.domain must survive:\n\(output)")
        XCTAssertTrue(output.contains("'+.corp.a,+.corp.b': ['223.5.5.5', '119.29.29.29']"), "Quote/bracket flow nameserver-policy must survive:\n\(output)")
        XCTAssertTrue(output.contains("'+.apple.com': https://dns.alidns.com/dns-query"), "Explicit user encrypted domestic DoH policy must not be overwritten:\n\(output)")
        try ProfileImportValidator.validate(data: Data(output.utf8))
    }

    // MARK: - 6. ProfileConfigurationSummary & ProfileOverrideCompiler

    func testProfileSummaryProvidersLongRegexNoticesBlockPolicyAndInvalidRegex() {
        let longFilter = String(repeating: "HK|", count: 60) + "JP" // > 180 chars
        let yaml = """
        dns:
          enable: true
          nameserver-policy:
            '+.example.cn':
              - https://doh.pub/dns-query
              - 223.5.5.5
            'geosite:test': ['tls://dns.alidns.com', '119.29.29.29']
        proxies:
          - {name: "剩余流量：100 GB", type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: a}
          - {name: "HK 01", type: ss, server: 1.1.1.2, port: 443, cipher: aes-128-gcm, password: a}
          - {name: "JP 01", type: ss, server: 1.1.1.3, port: 443, cipher: aes-128-gcm, password: a}
          - {name: "US 01", type: ss, server: 1.1.1.4, port: 443, cipher: aes-128-gcm, password: a}
        proxy-groups:
          - name: ProvidersAll
            type: select
            include-all-providers: true
            filter: "\(longFilter)"
          - name: BadRegex
            type: select
            include-all: true
            filter: "[unclosed"
        rules:
          - MATCH,ProvidersAll
        """

        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
        XCTAssertEqual(summary.dns.nameserverPolicyCount, 2)
        XCTAssertTrue(summary.dns.upstreamTransports.contains(.dnsOverHTTPS))
        XCTAssertTrue(summary.dns.upstreamTransports.contains(.dnsOverTLS))

        let providersGroup = summary.proxyGroups.first { $0.name == "ProvidersAll" }
        XCTAssertEqual(providersGroup?.members, ["HK 01", "JP 01"])

        let badRegexGroup = summary.proxyGroups.first { $0.name == "BadRegex" }
        XCTAssertFalse(badRegexGroup?.members.contains("剩余流量：100 GB") ?? true)
        XCTAssertFalse(summary.compatibility.limitedOptions.isEmpty)
    }

    func testProfileOverrideCompilerPreservesIncludeAllWithoutInjectingProxies() throws {
        let yaml = """
        proxies:
          - {name: "HK 01", type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: a}
          - {name: "Expired 2026", type: ss, server: 1.1.1.2, port: 443, cipher: aes-128-gcm, password: a}
        proxy-groups:
          - {name: AutoAll, type: url-test, include-all: true, url: 'http://www.gstatic.com/generate_204', interval: 300}
        rules:
          - MATCH,AutoAll
        """
        let override = try ProfileOverride(hiddenNodeKeywords: ["Expired"]).validated()
        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        XCTAssertTrue(result.hiddenNodes.contains("Expired 2026"))
        XCTAssertTrue(result.yaml.contains("include-all: true"))
        XCTAssertTrue(result.yaml.contains("exclude-filter:"))
        XCTAssertFalse(result.yaml.contains("proxies: []"))
    }

    // MARK: - 7. SubscriptionPayloadNormalizer Indentation & VMess AEAD

    func testSubscriptionNormalizerIndentationAndVMessAEAD() throws {
        let indentedYAML = """
        proxies:
          - name: TestNode
            type: ss
            server: example.com
            port: 443
            cipher: aes-128-gcm
            password: pass
        proxy-groups:
          - name: PROXY
            type: select
            proxies:
              - TestNode
        rules:
          - MATCH,PROXY
        """
        let topLevelWithUI = "external-ui: /tmp/ui\n" + indentedYAML
        let stripped = try SubscriptionPayloadNormalizer.normalize(Data(topLevelWithUI.utf8))
        let strippedText = String(decoding: stripped, as: UTF8.self)
        XCTAssertFalse(strippedText.contains("external-ui:"))

        let nestedUIName = """
        dns:
          enable: true
          external-ui-name: keep-nested
        """ + "\n" + indentedYAML
        let keptNested = try SubscriptionPayloadNormalizer.normalize(Data(nestedUIName.utf8))
        XCTAssertTrue(String(decoding: keptNested, as: UTF8.self).contains("  external-ui-name: keep-nested"))

        let nestedForbidden = """
        dns:
          enable: true
          external-ui: nested-forbidden
        """ + "\n" + indentedYAML
        XCTAssertThrowsError(try SubscriptionPayloadNormalizer.normalize(Data(nestedForbidden.utf8))) { error in
            XCTAssertEqual(error as? ProfileImportError, .forbiddenExecutableKey("external-ui"))
        }

        let vmessAEAD = "vmess://11111111-2222-3333-4444-555555555555@example.com:443?type=ws&path=%2Fws&host=cdn.example.com&security=tls&sni=cdn.example.com#AEAD-Node"
        let normalizedVMess = try SubscriptionPayloadNormalizer.normalize(Data(vmessAEAD.utf8))
        let vmessText = String(decoding: normalizedVMess, as: UTF8.self)
        let vmessSummary = ProfileConfigurationInspector.inspect(yaml: vmessText)
        XCTAssertEqual(vmessSummary.proxies.first?.name, "AEAD-Node")
        XCTAssertTrue(vmessText.contains("type: 'vmess'"))
        XCTAssertTrue(vmessText.contains("server: 'example.com'"))
        XCTAssertTrue(vmessText.contains("port: 443"))
    }

    // MARK: - 8. DNSRuntimePolicy, SystemResolverPrecedence & NetworkRecoveryCoordinator

    func testDNSRuntimePolicyStorePreservesValidPoliciesAndRedirHostDefault() throws {
        let redirDefault = DNSRuntimePolicy.packetTunnelCompatibilityDefault(
            for: DNSConfigurationSummary(isPresent: true, isEnabled: true, allowsIPv6: true, mode: .redirHost)
        )
        XCTAssertEqual(redirDefault, DNSRuntimePolicy(ipv6: .disabled))

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoreKitAudit-DNSPolicy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let url = dir.appendingPathComponent("dns-runtime-policy.v1.json")
        let goodDigest = ProxySelectionStore.profileDigest(yaml: "profile-a")
        let corruptPayload: [String: Any] = [
            "formatVersion": 2,
            "policies": [
                goodDigest: ["resolutionMode": 1, "ipv6": 0, "respectsRules": -1],
                "bad-digest": ["resolutionMode": 1, "ipv6": 0, "respectsRules": -1],
            ],
            "profileOrder": [goodDigest, "bad-digest"],
        ]
        try JSONSerialization.data(withJSONObject: corruptPayload).write(to: url)

        let store = DNSRuntimePolicyStore(directoryURL: dir)
        try store.save(DNSRuntimePolicy(resolutionMode: .normal, ipv6: .enabled), forProfileYAML: "profile-b")
        XCTAssertEqual(
            try store.loadIfPresent(forProfileYAML: "profile-a"),
            DNSRuntimePolicy(resolutionMode: .fakeIP, ipv6: .disabled)
        )
    }

    func testSystemResolverPrecedenceDetectsIndexZeroPreemption() {
        let preempted = SystemResolverPrecedence(
            primaryServers: ["100.100.100.100", "198.18.0.2"],
            tunnelServers: ["198.18.0.2"]
        )
        XCTAssertTrue(preempted.isPreempted)

        let notPreempted = SystemResolverPrecedence(
            primaryServers: ["198.18.0.2", "100.100.100.100"],
            tunnelServers: ["198.18.0.2"]
        )
        XCTAssertFalse(notPreempted.isPreempted)

        let unavailable = SystemResolverPrecedence(primaryServers: [], tunnelServers: ["198.18.0.2"])
        XCTAssertFalse(unavailable.isPreempted)
    }

    func testNetworkRecoveryCoordinatorWakeBackoffSupersedeAndObserverQueue() {
        let queueKey = DispatchSpecificKey<UInt8>()
        let queue = DispatchQueue(label: "test.recovery.queue")
        queue.setSpecific(key: queueKey, value: 1)

        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            var starts: [String] = []
            var observerOffQueueCount = 0
            var wakeAttempts = 0
            var didFulfillFirstWakeVerify = false

            func recordPerform(_ entry: String, isWake: Bool) -> Int {
                lock.withLock {
                    if isWake { wakeAttempts += 1 }
                    starts.append(entry)
                    return wakeAttempts
                }
            }

            func recordOffQueue() {
                lock.withLock { observerOffQueueCount += 1 }
            }

            func consumeFirstWakeBackoffTrigger() -> Bool {
                lock.withLock {
                    guard wakeAttempts == 1, !didFulfillFirstWakeVerify else { return false }
                    didFulfillFirstWakeVerify = true
                    return true
                }
            }

            func snapshot() -> (starts: [String], offQueue: Int) {
                lock.withLock { (starts, observerOffQueueCount) }
            }
        }

        let recorder = Recorder()
        let firstBackoffEntered = expectation(description: "first attempt failed into backoff")
        let supersededStarted = expectation(description: "appMessage superseded stale wake")

        let coordinator = NetworkRecoveryCoordinator(
            delays: [0, 5.0],
            debounce: 0,
            queue: queue,
            perform: { reason, attempt in
                _ = recorder.recordPerform("\(reason):\(attempt)", isWake: reason == "wake")
                if reason == "appMessage" {
                    supersededStarted.fulfill()
                }
            },
            verify: {
                if DispatchQueue.getSpecific(key: queueKey) != 1 {
                    recorder.recordOffQueue()
                }
                if recorder.consumeFirstWakeBackoffTrigger() {
                    firstBackoffEntered.fulfill()
                    return false
                }
                return true
            },
            observer: { _ in
                if DispatchQueue.getSpecific(key: queueKey) != 1 {
                    recorder.recordOffQueue()
                }
            }
        )

        coordinator.trigger(reason: "wake")
        wait(for: [firstBackoffEntered], timeout: 2.0)
        // Wait briefly so coordinator advances to attempt 1 delay (pending 5.0s timer)
        Thread.sleep(forTimeInterval: 0.05)

        coordinator.trigger(reason: "appMessage", supersedes: true)
        wait(for: [supersededStarted], timeout: 2.0)
        coordinator.cancel(reason: "testDone")
        coordinator.waitForQuiescence()

        let recorded = recorder.snapshot()
        XCTAssertTrue(recorded.starts.contains("appMessage:0"))
        XCTAssertEqual(recorded.offQueue, 0)
    }

    // MARK: - 9. CloudSync Idempotency, MMDB Lookup, IPC Trace & Reconnect After Cancel

    @MainActor
    func testCloudSyncSteadyStateIdempotencyDoesNotRewriteKVSOrPostSpuriousNotifications() async throws {
        final class CountingKVS: CloudKeyValueStoring, @unchecked Sendable {
            private let lock = NSLock()
            private var storage: [String: Data] = [:]
            var setCountByKey: [String: Int] = [:]

            func synchronize() -> Bool { true }

            func data(forKey defaultName: String) -> Data? {
                lock.withLock { storage[defaultName] }
            }

            func set(_ value: Any?, forKey defaultName: String) {
                lock.withLock {
                    storage[defaultName] = value as? Data
                    setCountByKey[defaultName, default: 0] += 1
                }
            }

            func resetCounters() {
                lock.withLock { setCountByKey.removeAll() }
            }

            func totalSetCalls() -> Int {
                lock.withLock { setCountByKey.values.reduce(0, +) }
            }
        }

        let kvs = CountingKVS()
        let keyStore = InMemoryProfileKeyStore()
        _ = try keyStore.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)

        let macDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreKitAudit-CloudSync-Mac-\(UUID().uuidString)", isDirectory: true)
        let iosDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreKitAudit-CloudSync-iOS-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: iosDir, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: macDir)
            try? FileManager.default.removeItem(at: iosDir)
        }

        let yaml = "proxies:\n  - {name: Edge-1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}\n"
        let macCatalog = ProfileCatalogStore(directoryURL: macDir, keyStore: keyStore)
        let managed = ManagedProfile(profile: ActiveProfile(name: "Sync Profile", yaml: yaml))
        try macCatalog.replaceCatalog(ProfileCatalog(activeProfileID: managed.id, profiles: [managed]))

        let macRuleEngine = RuleProviderEngine(directoryURL: macDir.appendingPathComponent("RuleProviders"))
        try await macRuleEngine.registerProvider(
            RuleProviderMetadata(
                name: "WorkBlock",
                url: URL(string: "https://example.com/rules.yaml")!,
                behavior: .domain,
                format: .yaml,
                defaultTarget: "REJECT"
            )
        )
        let macCustomRuleStore = CustomRuleStore(directoryURL: macDir)
        try macCustomRuleStore.save([
            CustomRule(kind: .domainSuffix, value: "internal.test", target: .direct)
        ])

        let macManager = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: macCatalog,
            ruleProviderEngine: macRuleEngine,
            deviceIdentifier: "mac-1",
            deviceName: "Mac"
        )
        macManager.isCloudSyncEnabled = true
        _ = try await macManager.forcePushToCloud()

        let iosCatalog = ProfileCatalogStore(directoryURL: iosDir, keyStore: keyStore)
        let iosRuleEngine = RuleProviderEngine(directoryURL: iosDir.appendingPathComponent("RuleProviders"))
        let iosManager = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: keyStore,
            catalogStore: iosCatalog,
            ruleProviderEngine: iosRuleEngine,
            deviceIdentifier: "ios-1",
            deviceName: "iOS"
        )
        iosManager.isCloudSyncEnabled = true
        _ = try await iosManager.sync()
        XCTAssertEqual(try iosCatalog.loadOrMigrate().profiles.map(\.profile.name), ["Sync Profile"])

        // Steady-state sync must write zero KVS keys and emit zero update notifications
        final class NotificationCounter: @unchecked Sendable {
            private let lock = NSLock()
            var count = 0
            func bump() { lock.withLock { count += 1 } }
            func snapshot() -> Int { lock.withLock { count } }
        }
        let notifications = NotificationCounter()
        let center = NotificationCenter.default
        let tokens = [
            Notification.Name.aetherRouteCloudSyncDidUpdateProfiles,
            Notification.Name.aetherRouteCloudSyncDidUpdateUserRules,
            Notification.Name.aetherRouteCloudSyncDidUpdateRuleProviders,
        ].map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { _ in
                notifications.bump()
            }
        }
        defer { tokens.forEach(center.removeObserver) }

        kvs.resetCounters()
        _ = try await macManager.sync()
        _ = try await iosManager.sync()
        XCTAssertEqual(kvs.totalSetCalls(), 0, "Steady-state sync must not rewrite encrypted blobs: \(kvs.setCountByKey)")
        XCTAssertEqual(notifications.snapshot(), 0, "Steady-state sync must not emit update notifications")
    }

    func testMMDBLookupReaderAndRouteSimulationGeoIPAndASNLookup() {
        func mmdbString(_ value: String) -> Data {
            let bytes = Array(value.utf8)
            precondition(bytes.count < 29)
            return Data([UInt8((2 << 5) | bytes.count)]) + Data(bytes)
        }

        func mmdbUInt32(_ value: UInt32) -> Data {
            var big = value.bigEndian
            let raw = Data(bytes: &big, count: 4)
            return Data([UInt8((6 << 5) | 4)]) + raw
        }

        func mmdbUInt16(_ value: UInt16) -> Data {
            var big = value.bigEndian
            let raw = Data(bytes: &big, count: 2)
            return Data([UInt8((5 << 5) | 2)]) + raw
        }

        func mmdbMap(_ pairs: [(String, Data)]) -> Data {
            precondition(pairs.count < 29)
            var out = Data([UInt8(pairs.count), 0]) // extended type 7 => 7-7 = 0
            for (k, v) in pairs {
                out += mmdbString(k)
                out += v
            }
            return out
        }

        func makeSingleEntryIPv4MMDB(recordData: Data) -> Data {
            let nodeCount = 1
            // Search tree: left (MSB=0) -> data offset 0 => nodeCount + 16 = 17; right (MSB=1) -> not found (nodeCount = 1)
            var searchTree = Data()
            var left = UInt32(nodeCount + 16).bigEndian
            var right = UInt32(nodeCount).bigEndian
            searchTree.append(Data(bytes: &left, count: 4))
            searchTree.append(Data(bytes: &right, count: 4))

            let separator = Data(repeating: 0, count: 16)
            let marker = Data([0xab, 0xcd, 0xef] + Array("MaxMind.com".utf8))
            let metadata = mmdbMap([
                ("node_count", mmdbUInt32(UInt32(nodeCount))),
                ("record_size", mmdbUInt16(32)),
                ("ip_version", mmdbUInt16(4)),
            ])
            return searchTree + separator + recordData + marker + metadata
        }

        let countryMMDB = makeSingleEntryIPv4MMDB(
            recordData: mmdbMap([("country", mmdbMap([("iso_code", mmdbString("JP"))]))])
        )
        let asnMMDB = makeSingleEntryIPv4MMDB(
            recordData: mmdbMap([("autonomous_system_number", mmdbUInt32(2516))])
        )

        let yaml = """
        proxies:
          - {name: JapanEdge, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [JapanEdge]}
        rules:
          - IP-ASN,2516,PROXY
          - GEOIP,JP,PROXY
          - MATCH,DIRECT
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)

        let asnResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "edge.example.jp", ip: nil, port: 443, resolvedAddresses: ["8.8.8.8"]),
            routingMode: .rule,
            profileYAML: yaml,
            summary: summary,
            asnMMDBData: asnMMDB
        )
        XCTAssertEqual(asnResult.matchedRuleKind, "IP-ASN")
        XCTAssertEqual(asnResult.matchedRuleCriteria, "2516")
        XCTAssertEqual(asnResult.targetOutbound, "PROXY")

        let geoResult = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "edge.example.jp", ip: nil, port: 443, resolvedAddresses: ["8.8.8.8"]),
            routingMode: .rule,
            profileYAML: yaml,
            summary: summary,
            countryMMDBData: countryMMDB
        )
        XCTAssertEqual(geoResult.matchedRuleKind, "GEOIP")
        XCTAssertEqual(geoResult.matchedRuleCriteria, "JP")
        XCTAssertEqual(geoResult.targetOutbound, "PROXY")
    }

    func testRouteTraceRequestResolvedAddressesCustomHostsAndIPCRoundTrip() throws {
        let traceRequest = RouteTraceRequest(
            host: "svc.internal",
            ip: nil,
            port: 8443,
            network: .tcp,
            processPath: nil,
            resolvedAddresses: ["203.0.113.10"],
            customHosts: [CustomHostMapping(domain: "svc.internal", ip: "10.99.0.1", isEnabled: true)]
        )
        let encodedTrace = try ProxySelectionProviderMessageCodec.encode(request: .traceRoute(traceRequest))
        let decodedTrace = try ProxySelectionProviderMessageCodec.decodeRequest(encodedTrace)
        XCTAssertEqual(decodedTrace, .traceRoute(traceRequest))

        let reloadPayload = ReloadProfilePayload(
            profileYAML: "proxies: []\n",
            routingMode: .rule,
            bypassPolicy: .empty,
            dnsPolicy: .inherited,
            proxySelections: [:],
            diagnosticLogLevel: .verbose
        )
        let encodedReload = try ProxySelectionProviderMessageCodec.encode(
            request: .reloadProfile(try JSONEncoder().encode(reloadPayload))
        )
        if case let .reloadProfile(data)? = try? ProxySelectionProviderMessageCodec.decodeRequest(encodedReload) {
            let decodedReload = try JSONDecoder().decode(ReloadProfilePayload.self, from: try XCTUnwrap(data))
            XCTAssertEqual(decodedReload.diagnosticLogLevel, DiagnosticLogLevel.verbose)
        } else {
            XCTFail("Expected reloadProfile round-trip")
        }

        let yaml = """
        proxies:
          - {name: P1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [P1]}
        rules:
          - IP-CIDR,10.99.0.0/16,DIRECT,no-resolve
          - IP-CIDR,203.0.113.0/24,PROXY,no-resolve
          - IP-CIDR,203.0.113.0/24,PROXY
          - MATCH,PROXY
        """
        let summary = ProfileConfigurationInspector.inspect(yaml: yaml)

        // Custom host mapping overrides IP locally, matching no-resolve rule
        let hostHit = RouteSimulationInspector.evaluate(
            request: traceRequest,
            routingMode: .rule,
            profileYAML: yaml,
            summary: summary
        )
        XCTAssertEqual(hostHit.targetOutbound, "DIRECT")
        XCTAssertEqual(hostHit.resolvedHostAlias, "10.99.0.1")

        // Without custom host, resolvedAddresses skip no-resolve rule #2 and hit resolving rule #3
        let dnsHit = RouteSimulationInspector.evaluate(
            request: RouteTraceRequest(host: "api.public.example", port: 443, resolvedAddresses: ["203.0.113.10"]),
            routingMode: .rule,
            profileYAML: yaml,
            summary: summary
        )
        XCTAssertEqual(dnsHit.matchedRuleKind, "IP-CIDR")
        XCTAssertEqual(dnsHit.matchedRuleOrder, 3)
        XCTAssertEqual(dnsHit.targetOutbound, "PROXY")
    }

    func testEffectivePacketTunnelAllowsIPv6TopLevelAndWithoutExplicitDNSIPv6() {
        let topLevelOnlyYAML = """
        ipv6: true
        dns:
          enable: true
          enhanced-mode: fake-ip
        proxies:
          - {name: P1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [P1]}
        rules:
          - MATCH,PROXY
        """
        let topSummary = ProfileConfigurationInspector.inspect(yaml: topLevelOnlyYAML)
        XCTAssertTrue(topSummary.allowsIPv6)
        XCTAssertFalse(topSummary.dns.hasExplicitIPv6)
        XCTAssertTrue(
            DNSRuntimePolicy.inherited.effectivePacketTunnelAllowsIPv6(
                for: topSummary.dns,
                profileAllowsIPv6: topSummary.allowsIPv6
            )
        )

        let explicitFalseYAML = """
        ipv6: true
        dns:
          enable: true
          ipv6: false
          enhanced-mode: fake-ip
        proxies:
          - {name: P1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [P1]}
        rules:
          - MATCH,PROXY
        """
        let falseSummary = ProfileConfigurationInspector.inspect(yaml: explicitFalseYAML)
        XCTAssertTrue(falseSummary.dns.hasExplicitIPv6)
        XCTAssertFalse(falseSummary.dns.allowsIPv6)
        XCTAssertFalse(
            DNSRuntimePolicy.inherited.effectivePacketTunnelAllowsIPv6(
                for: falseSummary.dns,
                profileAllowsIPv6: falseSummary.allowsIPv6
            )
        )
    }

    @MainActor
    func testNetworkEngineReconnectCoordinatorAllowsImmediateRerunAfterCancel() async throws {
        let coordinator = NetworkEngineReconnectCoordinator()
        var cancelledWaitContinuation: CheckedContinuation<Bool, Never>?
        let waitEntered = expectation(description: "first reconnect entered async wait")

        let firstTask = Task { @MainActor in
            try await coordinator.run(
                stop: { true },
                prepare: { _ in },
                start: {},
                waitUntilConnected: {
                    await withCheckedContinuation { continuation in
                        cancelledWaitContinuation = continuation
                        waitEntered.fulfill()
                    }
                }
            )
        }

        await fulfillment(of: [waitEntered], timeout: 2.0)
        coordinator.cancel()

        // Immediately start a second reconnect before firstTask unwinds waitUntilConnected
        let outcome = try await coordinator.run(
            stop: { true },
            prepare: { _ in },
            start: {},
            waitUntilConnected: { true }
        )
        XCTAssertEqual(outcome, .switched)

        cancelledWaitContinuation?.resume(returning: true)
        do {
            _ = try await firstTask.value
            XCTFail("Cancelled first reconnect must throw CancellationError")
        } catch is CancellationError {}
    }
}

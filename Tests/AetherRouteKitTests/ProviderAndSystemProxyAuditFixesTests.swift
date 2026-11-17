import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class ProviderAndSystemProxyAuditFixesTests: XCTestCase {
    private var tempDir: URL!
    private var storageDir: URL!
    private var proxyStorageDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProviderAndSystemProxyAuditFixes-\(UUID().uuidString)", isDirectory: true)
        storageDir = tempDir.appendingPathComponent("RuleProviders", isDirectory: true)
        proxyStorageDir = tempDir.appendingPathComponent("ProxyProviders", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proxyStorageDir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private actor AsyncFetchGate {
        private var enteredContinuation: CheckedContinuation<Void, Never>?
        private var didEnter = false
        private var releaseContinuation: CheckedContinuation<Void, Never>?
        private var released = false

        func waitForFetchToStart() async {
            if didEnter { return }
            await withCheckedContinuation { continuation in
                enteredContinuation = continuation
            }
        }

        func pauseInsideFetch() async {
            didEnter = true
            enteredContinuation?.resume()
            enteredContinuation = nil
            if released { return }
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
            }
        }

        func releaseFetch() {
            released = true
            releaseContinuation?.resume()
            releaseContinuation = nil
        }
    }

    private final class MockNetworkSetupExecutor: SystemProxyCommandExecuting, @unchecked Sendable {
        private let lock = NSLock()
        /// Active names appear verbatim; disabled names are stored with a leading `*`
        /// (matching `/usr/sbin/networksetup -listallnetworkservices`).
        var rawServiceLines: [String] = ["Wi-Fi", "Ethernet"]
        var webState: [String: (enabled: Bool, server: String, port: Int)] = [:]
        var secureState: [String: (enabled: Bool, server: String, port: Int)] = [:]
        var socksState: [String: (enabled: Bool, server: String, port: Int)] = [:]
        var bypassState: [String: [String]] = [:]
        var failCommandForService: (command: String, service: String)?
        var executedCommands: [[String]] = []

        private func hasService(named service: String) -> Bool {
            rawServiceLines.contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                let normalized = trimmed.hasPrefix("*")
                    ? String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                    : trimmed
                return normalized == service
            }
        }

        func run(executablePath: String, arguments: [String]) throws -> SystemProxyCommandOutput {
            lock.lock()
            defer { lock.unlock() }
            executedCommands.append(arguments)
            let cmd = arguments.first ?? ""
            if cmd == "-listallnetworkservices" {
                let body = (["An asterisk (*) denotes that a network service is disabled."] + rawServiceLines)
                    .joined(separator: "\n")
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: body, standardError: "")
            }
            guard arguments.count >= 2 else {
                return SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "missing service")
            }
            let service = arguments[1]
            if let fail = failCommandForService, fail.command == cmd, fail.service == service {
                return SystemProxyCommandOutput(exitCode: 4, standardOutput: "", standardError: "injected error for \(service)")
            }
            guard hasService(named: service) else {
                return SystemProxyCommandOutput(
                    exitCode: 4,
                    standardOutput: "",
                    standardError: "\(service) is not a recognized network service"
                )
            }

            func format(_ state: (enabled: Bool, server: String, port: Int)) -> String {
                "Enabled: \(state.enabled ? "Yes" : "No")\nServer: \(state.server)\nPort: \(state.port)\n"
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
                let out = domains.isEmpty
                    ? "There aren't any bypass domains set on \(service).\n"
                    : domains.joined(separator: "\n") + "\n"
                return SystemProxyCommandOutput(exitCode: 0, standardOutput: out, standardError: "")
            case "-setwebproxy":
                let prev = webState[service] ?? (false, "", 0)
                webState[service] = (prev.enabled, arguments[2], Int(arguments[3]) ?? 0)
            case "-setwebproxystate":
                let prev = webState[service] ?? (false, "", 0)
                webState[service] = (arguments[2].lowercased() == "on", prev.server, prev.port)
            case "-setsecurewebproxy":
                let prev = secureState[service] ?? (false, "", 0)
                secureState[service] = (prev.enabled, arguments[2], Int(arguments[3]) ?? 0)
            case "-setsecurewebproxystate":
                let prev = secureState[service] ?? (false, "", 0)
                secureState[service] = (arguments[2].lowercased() == "on", prev.server, prev.port)
            case "-setsocksfirewallproxy":
                let prev = socksState[service] ?? (false, "", 0)
                socksState[service] = (prev.enabled, arguments[2], Int(arguments[3]) ?? 0)
            case "-setsocksfirewallproxystate":
                let prev = socksState[service] ?? (false, "", 0)
                socksState[service] = (arguments[2].lowercased() == "on", prev.server, prev.port)
            case "-setproxybypassdomains":
                let domains = Array(arguments.dropFirst(2))
                bypassState[service] = domains == ["Empty"] ? [] : domains
            default:
                return SystemProxyCommandOutput(exitCode: 1, standardOutput: "", standardError: "unknown command \(cmd)")
            }
            return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    // MARK: - Issue 1: Subscription Rule Providers Must Not Pollute Global Custom Rule Providers or Change Targets/Order

    func testStageProvidersDoesNotPolluteGlobalRulesOrOverrideRuleSetTargetAndOrder() async throws {
        let engine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let payload = "+.internal.example.com\n"
                return (Data(payload.utf8), response)
            }
        )

        let profile1YAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HK-1, DIRECT]}
        rule-providers:
          internal:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/internal.txt
            path: ./ruleset/internal.txt
            interval: 86400
        rules:
          - DOMAIN-SUFFIX,corp-override.example,PROXY
          - RULE-SET,internal,DIRECT
          - MATCH,PROXY
        """

        let profile2YAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HK-1, DIRECT]}
        rules:
          - MATCH,DIRECT
        """

        let staged = await engine.stageProviders(inProfileYAML: profile1YAML, force: true)
        XCTAssertEqual(staged.count, 1)
        XCTAssertEqual(staged.first?.name, "internal")

        let profile1Staged = await engine.stagedProviders(inProfileYAML: profile1YAML)
        XCTAssertEqual(profile1Staged.map(\.name), ["internal"])
        let profile2Staged = await engine.stagedProviders(inProfileYAML: profile2YAML)
        XCTAssertTrue(profile2Staged.isEmpty)

        let globalProviders = await engine.allProviders()
        XCTAssertTrue(
            globalProviders.isEmpty,
            "Staging subscription rule-providers must not register them into global custom rule providers: \(globalProviders)"
        )

        let globalRemoteRules = await engine.compileActiveRules()
        XCTAssertTrue(
            globalRemoteRules.isEmpty,
            "Staging subscription rule-providers must not inject global PROXY-targeted rules: \(globalRemoteRules)"
        )

        let cloudPayload = await engine.exportCloudSyncPayload(deviceIdentifier: "test-device")
        if let cloudPayload,
           let decoded = try? JSONDecoder().decode(RuleProviderSyncPayload.self, from: cloudPayload) {
            XCTAssertTrue(decoded.providers.isEmpty, "Profile-staged providers must not enter global iCloud rule provider sync")
        }

        let optimizedProfile1 = DomesticRoutingOptimizer.optimizedProfile(
            for: profile1YAML,
            remoteRules: globalRemoteRules,
            enableDomesticDirect: false,
            providerBaseDirectoryURL: tempDir
        )
        XCTAssertFalse(
            optimizedProfile1.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"),
            "Subscription RULE-SET,internal,DIRECT must not be shadowed by an injected PROXY rule:\n\(optimizedProfile1)"
        )
        XCTAssertTrue(optimizedProfile1.contains("RULE-SET,internal,DIRECT"))
        let overrideIdx = try XCTUnwrap(optimizedProfile1.range(of: "DOMAIN-SUFFIX,corp-override.example,PROXY"))
        let ruleSetIdx = try XCTUnwrap(optimizedProfile1.range(of: "RULE-SET,internal,DIRECT"))
        XCTAssertLessThan(overrideIdx.lowerBound, ruleSetIdx.lowerBound)

        let optimizedProfile2 = DomesticRoutingOptimizer.optimizedProfile(
            for: profile2YAML,
            remoteRules: globalRemoteRules,
            enableDomesticDirect: false,
            providerBaseDirectoryURL: tempDir
        )
        XCTAssertFalse(
            optimizedProfile2.contains("internal.example.com"),
            "Switching to another profile must not leak staged rule-providers from the previous profile:\n\(optimizedProfile2)"
        )
    }

    func testLegacyPollutedProvidersJSONMigratesWhilePreservingUserGlobalRuleProviders() async throws {
        let profile1YAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HK-1, DIRECT]}
        rule-providers:
          internal:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/internal.txt
            path: ./ruleset/internal.txt
            interval: 86400
          geosite-cn:
            type: http
            behavior: domain
            format: mrs
            url: https://rules.example.com/geosite-cn.mrs
            path: ./ruleset/geosite-cn.mrs
            interval: 86400
        rules:
          - DOMAIN-SUFFIX,corp-override.example,PROXY
          - RULE-SET,internal,DIRECT
          - MATCH,PROXY
        """

        let pollutedID = UUID()
        let pollutedMrsID = UUID()
        let userAdsID = UUID()
        let userAIProxyID = UUID()
        let userMirrorID = UUID()
        let userSameNameRejectID = UUID()

        let now = Date()
        let legacyGlobalList: [RuleProviderMetadata] = [
            RuleProviderMetadata(
                id: pollutedID,
                name: "internal",
                url: URL(string: "https://rules.example.com/internal.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: now,
                ruleCount: 1
            ),
            RuleProviderMetadata(
                id: pollutedMrsID,
                name: "geosite-cn",
                url: URL(string: "https://rules.example.com/geosite-cn.mrs")!,
                behavior: .domain,
                format: .mrs,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: now,
                ruleCount: 0
            ),
            RuleProviderMetadata(
                id: userAdsID,
                name: "User-Ads",
                url: URL(string: "https://rules.example.com/ads.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "REJECT",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: now,
                ruleCount: 1
            ),
            RuleProviderMetadata(
                id: userAIProxyID,
                name: "User-AI-Proxy",
                url: URL(string: "https://rules.example.com/ai.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: now,
                ruleCount: 1
            ),
            RuleProviderMetadata(
                id: userMirrorID,
                name: "My-Internal-Mirror",
                url: URL(string: "https://rules.example.com/internal.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: now,
                ruleCount: 1
            ),
            RuleProviderMetadata(
                id: userSameNameRejectID,
                name: "internal",
                url: URL(string: "https://rules.example.com/internal-custom.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "REJECT",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: now,
                ruleCount: 1
            ),
        ]
        try JSONEncoder().encode(legacyGlobalList)
            .write(to: storageDir.appendingPathComponent("providers.json"), options: [.atomic])

        // Also seed a duplicate empty staged-profile-providers entry as seen when upgrading after an un-migrated run.
        let duplicateStagedID = UUID()
        let staleStagedList = [
            RuleProviderMetadata(
                id: duplicateStagedID,
                name: "internal",
                url: URL(string: "https://rules.example.com/internal.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: nil,
                ruleCount: 0
            )
        ]
        try JSONEncoder().encode(staleStagedList)
            .write(to: storageDir.appendingPathComponent("staged-profile-providers.json"), options: [.atomic])

        try Data("+.internal.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(pollutedID.uuidString).dat"), options: [.atomic])
        try Data([0x4D, 0x52, 0x53, 0x01])
            .write(to: storageDir.appendingPathComponent("\(pollutedMrsID.uuidString).dat"), options: [.atomic])
        try Data("+.ads.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(userAdsID.uuidString).dat"), options: [.atomic])
        try Data("+.openai.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(userAIProxyID.uuidString).dat"), options: [.atomic])
        try Data("+.mirror.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(userMirrorID.uuidString).dat"), options: [.atomic])
        try Data("+.block-custom.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(userSameNameRejectID.uuidString).dat"), options: [.atomic])

        // Seed legacy unhashed staged files from v3.0.1
        for subDir in ["providers/rules", "Runtime/providers/rules", "Runtime/FlowCore/providers/rules"] {
            let dir = tempDir.appendingPathComponent(subDir, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data("+.internal.example.com\n".utf8)
                .write(to: dir.appendingPathComponent("internal.txt"), options: [.atomic])
        }

        let engine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { _ in
                XCTFail("Offline legacy upgrade migration must not require network access")
                throw URLError(.cannotConnectToHost)
            }
        )

        let staged = await engine.stagedProviders(inProfileYAML: profile1YAML)
        XCTAssertEqual(Set(staged.map(\.name)), ["internal", "geosite-cn"])
        XCTAssertEqual(staged.first(where: { $0.name == "internal" })?.ruleCount, 1)

        let globalProviders = await engine.allProviders()
        XCTAssertEqual(
            Set(globalProviders.map(\.id)),
            [userAdsID, userAIProxyID, userMirrorID, userSameNameRejectID],
            "Migration must remove polluted subscription providers while keeping every genuine user global provider"
        )

        let activeRules = await engine.compileActiveRules()
        XCTAssertFalse(
            activeRules.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"),
            "Migrated subscription provider rule leaked into compileActiveRules(): \(activeRules)"
        )
        XCTAssertTrue(activeRules.contains("DOMAIN-SUFFIX,ads.example.com,REJECT"))
        XCTAssertTrue(activeRules.contains("DOMAIN-SUFFIX,openai.example.com,PROXY"))
        XCTAssertTrue(activeRules.contains("DOMAIN-SUFFIX,mirror.example.com,PROXY"))
        XCTAssertTrue(activeRules.contains("DOMAIN-SUFFIX,block-custom.example.com,REJECT"))

        let optimizedProfile1 = DomesticRoutingOptimizer.optimizedProfile(
            for: profile1YAML,
            remoteRules: activeRules,
            enableDomesticDirect: false,
            providerBaseDirectoryURL: tempDir
        )
        XCTAssertFalse(
            optimizedProfile1.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"),
            "Upgrade must not emit PROXY rule ahead of RULE-SET,internal,DIRECT:\n\(optimizedProfile1)"
        )
        XCTAssertTrue(optimizedProfile1.contains("RULE-SET,internal,DIRECT"))
        let expectedHashedInternal = RuleProviderEngine.sanitizedProviderFileName(name: "internal", format: .text)
        XCTAssertTrue(optimizedProfile1.contains("./providers/rules/\(expectedHashedInternal)"), optimizedProfile1)
        for subDir in ["providers/rules", "Runtime/providers/rules", "Runtime/FlowCore/providers/rules"] {
            let dir = tempDir.appendingPathComponent(subDir, isDirectory: true)
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(expectedHashedInternal).path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("internal.txt").path))
        }

        let compilerResult = ProfileOverrideCompiler.apply(
            nil,
            externalRuleProviders: globalProviders,
            ruleProviderCacheDirectoryURL: storageDir,
            to: profile1YAML
        )
        XCTAssertFalse(compilerResult.yaml.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"))
        XCTAssertTrue(compilerResult.yaml.contains("DOMAIN-SUFFIX,ads.example.com,REJECT"))

        // Stale v3.0.1 iCloud sync payload containing pollutedID must not resurrect it.
        let staleCloudData = try JSONEncoder().encode(
            RuleProviderSyncPayload(
                deviceIdentifier: "old-mac",
                providers: [legacyGlobalList[0], legacyGlobalList[2]]
            )
        )
        let mergeOutcome = await engine.mergeCloudSyncPayloadOutcome(staleCloudData)
        XCTAssertFalse(mergeOutcome.providers.contains(where: { $0.id == pollutedID }))
        XCTAssertFalse(mergeOutcome.matchesRemote)

        // Explicitly registered v3.0.2+ user provider with identical (name, url, target) must remain protected.
        let explicitID = UUID()
        let explicitUserProvider = RuleProviderMetadata(
            id: explicitID,
            name: "internal",
            url: URL(string: "https://rules.example.com/internal.txt")!,
            behavior: .domain,
            format: .text,
            defaultTarget: "PROXY",
            intervalSeconds: 86_400
        )
        try await engine.registerProvider(explicitUserProvider)
        let restartedEngine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if requestURL.path.hasSuffix(".mrs") {
                    return (Data([0x4D, 0x52, 0x53, 0x01]), response)
                }
                return (Data("+.internal.example.com\n".utf8), response)
            }
        )
        _ = await restartedEngine.stagedProviders(inProfileYAML: profile1YAML)
        _ = await restartedEngine.stageProviders(inProfileYAML: profile1YAML, force: false)
        let afterExplicit = await restartedEngine.allProviders()
        XCTAssertTrue(
            afterExplicit.contains(where: { $0.id == explicitID }),
            "User-registered global rule provider was mistakenly pruned by migration"
        )
    }

    func testLegacyPollutedProvidersJSONBareOfflineCompileWithoutStageCallDoesNotPreemptDirectRule() async throws {
        let profile1YAML = """
        mixed-port: 7890
        proxies:
          - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HK-1, DIRECT]}
        rule-providers:
          internal:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/internal.txt
            path: ./ruleset/internal.txt
            interval: 86400
        rules:
          - RULE-SET,internal,DIRECT
          - MATCH,PROXY
        """

        let pollutedID = UUID()
        let userGlobalID = UUID()
        let legacyList = [
            RuleProviderMetadata(
                id: pollutedID,
                name: "internal",
                url: URL(string: "https://rules.example.com/internal.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: Date(),
                ruleCount: 1
            ),
            RuleProviderMetadata(
                id: userGlobalID,
                name: "User-Global",
                url: URL(string: "https://rules.example.com/global.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: Date(),
                ruleCount: 1
            ),
        ]
        try JSONEncoder().encode(legacyList)
            .write(to: storageDir.appendingPathComponent("providers.json"), options: [.atomic])
        try Data("+.internal.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(pollutedID.uuidString).dat"), options: [.atomic])
        try Data("+.global.example.com\n".utf8)
            .write(to: storageDir.appendingPathComponent("\(userGlobalID.uuidString).dat"), options: [.atomic])
        let legacyRulesDir = tempDir.appendingPathComponent("providers/rules", isDirectory: true)
        try FileManager.default.createDirectory(at: legacyRulesDir, withIntermediateDirectories: true)
        try Data("+.internal.example.com\n".utf8)
            .write(to: legacyRulesDir.appendingPathComponent("internal.txt"), options: [.atomic])

        let engine = RuleProviderEngine(directoryURL: storageDir, stagingBaseURL: tempDir)
        let remoteRules = await engine.compileActiveRules()
        let globalProviders = await engine.allProviders()

        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: profile1YAML,
            remoteRules: remoteRules,
            enableDomesticDirect: false,
            providerBaseDirectoryURL: tempDir
        )
        XCTAssertFalse(
            optimized.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"),
            "Bare offline compile leaked polluted PROXY rule ahead of RULE-SET,internal,DIRECT:\n\(optimized)"
        )
        XCTAssertTrue(optimized.contains("DOMAIN-SUFFIX,global.example.com,PROXY"), optimized)
        XCTAssertTrue(optimized.contains("RULE-SET,internal,DIRECT"), optimized)

        let compiled = ProfileOverrideCompiler.apply(
            nil,
            externalRuleProviders: globalProviders,
            ruleProviderCacheDirectoryURL: storageDir,
            to: profile1YAML
        )
        XCTAssertFalse(
            compiled.yaml.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"),
            "ProfileOverrideCompiler leaked polluted PROXY rule:\n\(compiled.yaml)"
        )
        XCTAssertTrue(compiled.yaml.contains("DOMAIN-SUFFIX,global.example.com,PROXY"), compiled.yaml)
    }

    // MARK: - Issue 2: Out-of-Bounds Provider Refresh Intervals Must Not Crash

    func testOutOfBoundsProviderIntervalsDoNotCrashAndFallbackSafely() async throws {
        let ruleEngine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("+.example.com\n".utf8), response)
            }
        )
        let proxyEngine = ProxyProviderEngine(
            directoryURL: proxyStorageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let yaml = "proxies:\n  - {name: Node1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n"
                return (Data(yaml.utf8), response)
            }
        )

        let invalidRuleYAML = """
        rule-providers:
          neg-rule:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/neg.txt
            interval: -1
          huge-rule:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/huge.txt
            interval: 4294967296
        rules:
          - RULE-SET,neg-rule,DIRECT
          - RULE-SET,huge-rule,DIRECT
          - MATCH,DIRECT
        """

        let stagedRules = await ruleEngine.stageProviders(inProfileYAML: invalidRuleYAML, force: true)
        XCTAssertEqual(stagedRules.count, 2)
        XCTAssertEqual(stagedRules.first(where: { $0.name == "neg-rule" })?.intervalSeconds, 86_400)
        XCTAssertEqual(stagedRules.first(where: { $0.name == "huge-rule" })?.intervalSeconds, 86_400)

        // Also verify updating an existing provider with valid interval ignores an out-of-range update
        // without crashing on `UInt32(4294967296)`.
        let validThenInvalidRuleYAML = """
        rule-providers:
          existing-rule:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/existing.txt
            interval: 3600
        rules:
          - RULE-SET,existing-rule,DIRECT
          - MATCH,DIRECT
        """
        _ = await ruleEngine.stageProviders(inProfileYAML: validThenInvalidRuleYAML, force: true)
        let updatedHugeRuleYAML = """
        rule-providers:
          existing-rule:
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/existing.txt
            interval: 4294967296
        rules:
          - RULE-SET,existing-rule,DIRECT
          - MATCH,DIRECT
        """
        let restaged = await ruleEngine.stageProviders(inProfileYAML: updatedHugeRuleYAML, force: true)
        XCTAssertEqual(restaged.first?.intervalSeconds, 3_600)

        let invalidProxyYAML = """
        proxy-providers:
          neg-proxy:
            type: http
            url: https://sub.example.com/neg.yaml
            interval: -1
          huge-proxy:
            type: http
            url: https://sub.example.com/huge.yaml
            interval: 4294967296
        proxy-groups:
          - {name: Proxy, type: select, use: [neg-proxy, huge-proxy]}
        rules:
          - MATCH,Proxy
        """
        let stagedProxies = await proxyEngine.stageProviders(inProfileYAML: invalidProxyYAML, force: true)
        XCTAssertEqual(stagedProxies.count, 2)
        XCTAssertEqual(stagedProxies.first(where: { $0.name == "neg-proxy" })?.intervalSeconds, 3_600)
        XCTAssertEqual(stagedProxies.first(where: { $0.name == "huge-proxy" })?.intervalSeconds, 3_600)
    }

    // MARK: - Issue 3: Disabled Network Services Must Still Be Restored or Retain Pending Backup

    func testSystemProxyRestoreRecoversDisabledNetworkServiceOrRetainsBackupOnFailure() throws {
        // Subcase A: Disabled service (*Ethernet) still exists and networksetup succeeds on it -> must restore!
        do {
            let suite = "SysProxyDisabledRestore.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let executor = MockNetworkSetupExecutor()
            executor.rawServiceLines = ["Wi-Fi", "Ethernet"]
            executor.webState["Ethernet"] = (false, "", 0)
            executor.bypassState["Ethernet"] = []

            let configurator = SystemProxyConfigurator(executor: executor, defaults: defaults)
            try configurator.apply(settings: LocalProxySettings(httpPort: 17890, socksPort: 17891, setAsSystemProxy: true))
            XCTAssertTrue(configurator.hasPendingBackup)
            XCTAssertTrue(executor.webState["Ethernet"]?.enabled == true)
            XCTAssertEqual(executor.webState["Ethernet"]?.port, 17890)

            // User disables Ethernet before app exits / restores
            executor.rawServiceLines = ["Wi-Fi", "*Ethernet"]
            try configurator.restorePendingIfNeeded()

            XCTAssertFalse(configurator.hasPendingBackup)
            XCTAssertEqual(executor.webState["Wi-Fi"]?.enabled, false)
            XCTAssertEqual(executor.webState["Ethernet"]?.enabled, false)
            XCTAssertEqual(executor.secureState["Ethernet"]?.enabled, false)
            XCTAssertEqual(executor.socksState["Ethernet"]?.enabled, false)
            XCTAssertTrue(
                executor.executedCommands.contains { $0 == ["-setwebproxystate", "Ethernet", "off"] },
                "Disabled service must still receive proxy restore commands"
            )
        }

        // Subcase B: Disabled service fails restore command -> backup must be retained and retried cleanly later
        do {
            let suite = "SysProxyDisabledRetry.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let executor = MockNetworkSetupExecutor()
            executor.rawServiceLines = ["Wi-Fi", "Ethernet"]
            let configurator = SystemProxyConfigurator(executor: executor, defaults: defaults)
            try configurator.apply(settings: LocalProxySettings(httpPort: 17890, socksPort: 17891, setAsSystemProxy: true))

            executor.rawServiceLines = ["Wi-Fi", "*Ethernet"]
            executor.failCommandForService = ("-setwebproxystate", "Ethernet")

            XCTAssertThrowsError(try configurator.restorePendingIfNeeded())
            XCTAssertTrue(
                configurator.hasPendingBackup,
                "Backup for failed disabled service must NOT be deleted"
            )
            XCTAssertEqual(executor.webState["Wi-Fi"]?.enabled, false)
            XCTAssertEqual(executor.webState["Ethernet"]?.enabled, true)

            // Re-enable / clear error -> retry succeeds and clears backup
            executor.failCommandForService = nil
            executor.rawServiceLines = ["Wi-Fi", "Ethernet"]
            try configurator.restorePendingIfNeeded()
            XCTAssertFalse(configurator.hasPendingBackup)
            XCTAssertEqual(executor.webState["Ethernet"]?.enabled, false)
        }

        // Subcase C: Truly vanished service (removed USB adapter absent from -listallnetworkservices) is skipped cleanly
        do {
            let suite = "SysProxyVanished.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }

            let executor = MockNetworkSetupExecutor()
            executor.rawServiceLines = ["Wi-Fi", "USB LAN"]
            let configurator = SystemProxyConfigurator(executor: executor, defaults: defaults)
            try configurator.apply(settings: LocalProxySettings(httpPort: 17890, socksPort: 17891, setAsSystemProxy: true))

            executor.rawServiceLines = ["Wi-Fi"]
            try configurator.restorePendingIfNeeded()
            XCTAssertFalse(configurator.hasPendingBackup)
            XCTAssertEqual(executor.webState["Wi-Fi"]?.enabled, false)
        }
    }

    // MARK: - Issue 4: Mid-Flight Removal or Edit Must Not Be Overwritten After `await`

    func testProviderRefreshReentrancyDoesNotResurrectDeletedOrClobberEditedState() async throws {
        // Subcase A: RuleProviderEngine 200 deleted while awaiting download
        do {
            let gate = AsyncFetchGate()
            let engine = RuleProviderEngine(
                directoryURL: storageDir,
                stagingBaseURL: tempDir,
                httpFetcher: { requestURL in
                    await gate.pauseInsideFetch()
                    let response = HTTPURLResponse(
                        url: requestURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["ETag": "\"v2\""]
                    )!
                    return (Data("+.resurrected.example\n".utf8), response)
                }
            )
            let id = UUID()
            let provider = RuleProviderMetadata(
                id: id,
                name: "ToDelete",
                url: URL(string: "https://rules.example.com/delete.txt")!,
                behavior: .domain,
                format: .text
            )
            try await engine.registerProvider(provider)

            let refreshTask = Task { try await engine.forceRefresh(id: id) }
            await gate.waitForFetchToStart()
            await engine.removeProvider(id: id)
            await gate.releaseFetch()

            do {
                _ = try await refreshTask.value
                XCTFail("Expected forceRefresh on deleted rule provider to throw")
            } catch let error as RuleProviderError {
                XCTAssertEqual(error, .providerNotFound)
            }
            let fetched = await engine.provider(id: id)
            XCTAssertNil(fetched)
            let remaining = await engine.allProviders()
            XCTAssertTrue(remaining.isEmpty)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storageDir.appendingPathComponent("\(id.uuidString).dat").path))
            let stagedURL = await engine.stagedRuleFileURL(name: "ToDelete", format: .text)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        }

        // Subcase B: RuleProviderEngine 304 Not Modified deleted while awaiting response
        do {
            let gate = AsyncFetchGate()
            let dir = tempDir.appendingPathComponent("RuleProviders304", isDirectory: true)
            let engine = RuleProviderEngine(
                directoryURL: dir,
                stagingBaseURL: tempDir,
                httpFetcher: { requestURL in
                    await gate.pauseInsideFetch()
                    let response = HTTPURLResponse(url: requestURL, statusCode: 304, httpVersion: nil, headerFields: nil)!
                    return (Data(), response)
                }
            )
            let id = UUID()
            try await engine.registerProvider(RuleProviderMetadata(
                id: id,
                name: "ToDelete304",
                url: URL(string: "https://rules.example.com/304.txt")!
            ))
            let updateTask = Task { try await engine.updateIfNeeded(id: id) }
            await gate.waitForFetchToStart()
            await engine.removeProvider(id: id)
            await gate.releaseFetch()

            do {
                _ = try await updateTask.value
                XCTFail("Expected updateIfNeeded (304) on deleted provider to throw")
            } catch let error as RuleProviderError {
                XCTAssertEqual(error, .providerNotFound)
            }
            let remaining = await engine.allProviders()
            XCTAssertTrue(remaining.isEmpty)
        }

        // Subcase C: RuleProviderEngine toggled & edited (non-URL fields) during await must keep new fields
        do {
            let gate = AsyncFetchGate()
            let dir = tempDir.appendingPathComponent("RuleProvidersEdit", isDirectory: true)
            let engine = RuleProviderEngine(
                directoryURL: dir,
                stagingBaseURL: tempDir,
                httpFetcher: { requestURL in
                    await gate.pauseInsideFetch()
                    let response = HTTPURLResponse(
                        url: requestURL,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: ["ETag": "\"edited-etag\""]
                    )!
                    return (Data("+.kept.example\n+.kept2.example\n".utf8), response)
                }
            )
            let id = UUID()
            let original = RuleProviderMetadata(
                id: id,
                name: "EditableRule",
                url: URL(string: "https://rules.example.com/editable.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "PROXY",
                isEnabled: true,
                intervalSeconds: 86_400
            )
            try await engine.registerProvider(original)

            let refreshTask = Task { try await engine.forceRefresh(id: id) }
            await gate.waitForFetchToStart()
            _ = await engine.toggleProvider(id: id)
            let modifiedSnapshot = await engine.provider(id: id)
            var modified = try XCTUnwrap(modifiedSnapshot)
            modified.defaultTarget = "DIRECT"
            modified.intervalSeconds = 7_200
            modified.name = "EditableRuleRenamed"
            await engine.updateProviderMetadata(modified)
            await gate.releaseFetch()

            let count = try await refreshTask.value
            XCTAssertEqual(count, 2)
            let latestSnapshot = await engine.provider(id: id)
            let latest = try XCTUnwrap(latestSnapshot)
            XCTAssertFalse(latest.isEnabled, "Toggle during refresh must not be overwritten")
            XCTAssertEqual(latest.defaultTarget, "DIRECT")
            XCTAssertEqual(latest.intervalSeconds, 7_200)
            XCTAssertEqual(latest.name, "EditableRuleRenamed")
            XCTAssertEqual(latest.ruleCount, 2)
            XCTAssertEqual(latest.etag, "\"edited-etag\"")
        }

        // Subcase D: RuleProviderEngine URL changed during await must discard stale response
        do {
            let gate = AsyncFetchGate()
            let dir = tempDir.appendingPathComponent("RuleProvidersURLChanged", isDirectory: true)
            let urlA = URL(string: "https://rules.example.com/a.txt")!
            let urlB = URL(string: "https://rules.example.com/b.txt")!
            let engine = RuleProviderEngine(
                directoryURL: dir,
                stagingBaseURL: tempDir,
                httpFetcher: { requestURL in
                    if requestURL == urlA {
                        await gate.pauseInsideFetch()
                        let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                        return (Data("+.stale-a.example\n".utf8), response)
                    }
                    let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (Data("+.fresh-b.example\n".utf8), response)
                }
            )
            let id = UUID()
            try await engine.registerProvider(RuleProviderMetadata(id: id, name: "URLSwap", url: urlA))
            let staleTask = Task { try await engine.forceRefresh(id: id) }
            await gate.waitForFetchToStart()

            try await engine.registerProvider(RuleProviderMetadata(id: id, name: "URLSwap", url: urlB))
            _ = try await engine.forceRefresh(id: id)
            await gate.releaseFetch()

            do {
                _ = try await staleTask.value
                XCTFail("Stale fetch for superseded URL A must not overwrite URL B")
            } catch is CancellationError {
                // expected
            }
            let currentSnapshot = await engine.provider(id: id)
            let current = try XCTUnwrap(currentSnapshot)
            XCTAssertEqual(current.url, urlB)
            let loadedRules = try await engine.loadRules(for: id)
            XCTAssertEqual(loadedRules.map(\.payload), ["fresh-b.example"])
        }

        // Subcase E: ProxyProviderEngine 200 and download-error deleted while awaiting must not resurrect
        for simulateNetworkError in [false, true] {
            let gate = AsyncFetchGate()
            let dir = tempDir.appendingPathComponent("ProxyProvidersDelete-\(simulateNetworkError)", isDirectory: true)
            let engine = ProxyProviderEngine(
                directoryURL: dir,
                stagingBaseURL: tempDir,
                httpFetcher: { requestURL in
                    await gate.pauseInsideFetch()
                    if simulateNetworkError {
                        throw URLError(.timedOut)
                    }
                    let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    let yaml = "proxies:\n  - {name: Ghost, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n"
                    return (Data(yaml.utf8), response)
                }
            )
            let id = UUID()
            let name = "GhostPool-\(simulateNetworkError)"
            try await engine.addProvider(ProxyProviderMetadata(
                id: id,
                name: name,
                url: URL(string: "https://sub.example.com/ghost.yaml")!
            ))
            let fetchTask = Task { try await engine.fetchAndStage(id: id) }
            await gate.waitForFetchToStart()
            await engine.removeProvider(id: id)
            await gate.releaseFetch()

            do {
                _ = try await fetchTask.value
                XCTFail("Expected fetchAndStage on deleted proxy provider to throw")
            } catch let error as ProxyProviderError {
                XCTAssertEqual(error, .providerNotFound)
            }
            let all = await engine.allProviders()
            XCTAssertTrue(all.isEmpty, "Deleted proxy provider must not be resurrected (simulateError=\(simulateNetworkError))")
            let stagedURL = await engine.stagedProxyFileURL(name: name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stagedURL.path))
        }
    }

    // MARK: - Issue 5: Unique Provider Staged File Names Without Punctuation or Case Collisions

    func testProviderSanitizedFileNamesNeverCollideAcrossPunctuationOrCase() async throws {
        let rSlash = RuleProviderEngine.sanitizedProviderFileName(name: "Ads/A", format: .text)
        let rSpace = RuleProviderEngine.sanitizedProviderFileName(name: "Ads A", format: .text)
        let rDash = RuleProviderEngine.sanitizedProviderFileName(name: "Ads-A", format: .text)
        let rUpper = RuleProviderEngine.sanitizedProviderFileName(name: "Ads", format: .text)
        let rLower = RuleProviderEngine.sanitizedProviderFileName(name: "ads", format: .text)
        XCTAssertEqual(Set([rSlash, rSpace, rDash, rUpper, rLower]).count, 5, "Rule provider filenames must never collide: \([rSlash, rSpace, rDash, rUpper, rLower])")

        let pSlash = ProxyProviderEngine.sanitizedProviderFileName(name: "Pool/A")
        let pSpace = ProxyProviderEngine.sanitizedProviderFileName(name: "Pool A")
        let pDash = ProxyProviderEngine.sanitizedProviderFileName(name: "Pool-A")
        let pUpper = ProxyProviderEngine.sanitizedProviderFileName(name: "Pool")
        let pLower = ProxyProviderEngine.sanitizedProviderFileName(name: "pool")
        XCTAssertEqual(Set([pSlash, pSpace, pDash, pUpper, pLower]).count, 5, "Proxy provider filenames must never collide: \([pSlash, pSpace, pDash, pUpper, pLower])")

        let slashRuleURL = URL(string: "https://rules.example.com/slash.txt")!
        let spaceRuleURL = URL(string: "https://rules.example.com/space.txt")!
        let ruleEngine = RuleProviderEngine(
            directoryURL: storageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if requestURL == slashRuleURL {
                    return (Data("+.slash.example\n".utf8), response)
                }
                if requestURL == spaceRuleURL {
                    return (Data("+.space.example\n".utf8), response)
                }
                throw URLError(.fileDoesNotExist)
            }
        )

        let slashPoolURL = URL(string: "https://sub.example.com/pool-slash.yaml")!
        let spacePoolURL = URL(string: "https://sub.example.com/pool-space.yaml")!
        let slashPoolYAML = "proxies:\n  - {name: SlashNode, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n"
        let spacePoolYAML = "proxies:\n  - {name: SpaceNode, type: ss, server: 5.6.7.8, port: 443, cipher: aes-128-gcm, password: p}\n"
        let proxyEngine = ProxyProviderEngine(
            directoryURL: proxyStorageDir,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                if requestURL == slashPoolURL {
                    return (Data(slashPoolYAML.utf8), response)
                }
                if requestURL == spacePoolURL {
                    return (Data(spacePoolYAML.utf8), response)
                }
                throw URLError(.fileDoesNotExist)
            }
        )

        let profileYAML = """
        mixed-port: 7890
        proxy-providers:
          "Pool/A":
            type: http
            url: https://sub.example.com/pool-slash.yaml
            interval: 3600
          "Pool A":
            type: http
            url: https://sub.example.com/pool-space.yaml
            interval: 3600
        proxy-groups:
          - {name: Proxy, type: select, use: ["Pool/A", "Pool A"]}
        rule-providers:
          "Ads/A":
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/slash.txt
            interval: 86400
          "Ads A":
            type: http
            behavior: domain
            format: text
            url: https://rules.example.com/space.txt
            interval: 86400
        rules:
          - RULE-SET,Ads/A,DIRECT
          - RULE-SET,Ads A,REJECT
          - MATCH,Proxy
        """

        _ = await ruleEngine.stageProviders(inProfileYAML: profileYAML, force: true)
        let stagedProxies = await proxyEngine.stageProviders(inProfileYAML: profileYAML, force: true)
        XCTAssertEqual(stagedProxies.count, 2)

        let stagedRuleSlash = await ruleEngine.stagedRuleFileURL(name: "Ads/A", format: .text)
        let stagedRuleSpace = await ruleEngine.stagedRuleFileURL(name: "Ads A", format: .text)
        XCTAssertNotEqual(stagedRuleSlash, stagedRuleSpace)
        XCTAssertEqual(try String(contentsOf: stagedRuleSlash, encoding: .utf8), "+.slash.example\n")
        XCTAssertEqual(try String(contentsOf: stagedRuleSpace, encoding: .utf8), "+.space.example\n")

        let stagedProxySlash = await proxyEngine.stagedProxyFileURL(name: "Pool/A")
        let stagedProxySpace = await proxyEngine.stagedProxyFileURL(name: "Pool A")
        XCTAssertNotEqual(stagedProxySlash, stagedProxySpace)
        XCTAssertEqual(try String(contentsOf: stagedProxySlash, encoding: .utf8), slashPoolYAML)
        XCTAssertEqual(try String(contentsOf: stagedProxySpace, encoding: .utf8), spacePoolYAML)

        let optimized = DomesticRoutingOptimizer.optimizedProfile(
            for: profileYAML,
            enableDomesticDirect: false,
            providerBaseDirectoryURL: tempDir
        )
        XCTAssertTrue(optimized.contains("./providers/rules/\(rSlash)"), optimized)
        XCTAssertTrue(optimized.contains("./providers/rules/\(rSpace)"), optimized)
        XCTAssertTrue(optimized.contains("./providers/proxies/\(pSlash)"), optimized)
        XCTAssertTrue(optimized.contains("./providers/proxies/\(pSpace)"), optimized)

        // Removing "Pool A" must not delete "Pool/A"'s staged snapshot
        let spaceProxyID = try XCTUnwrap(stagedProxies.first(where: { $0.name == "Pool A" })?.id)
        await proxyEngine.removeProvider(id: spaceProxyID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stagedProxySlash.path))
    }
}

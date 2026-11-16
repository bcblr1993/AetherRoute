import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class RuleProviderAndCloudSyncFixTests: XCTestCase {
    private final class InMemoryKVS: CloudKeyValueStoring, @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String: Data] = [:]

        func synchronize() -> Bool { true }

        func data(forKey defaultName: String) -> Data? {
            lock.withLock { storage[defaultName] }
        }

        func set(_ value: Any?, forKey defaultName: String) {
            lock.withLock { storage[defaultName] = value as? Data }
        }
    }

    // MARK: - 1. ProfileOverrideCompiler Dialer-Proxy Directed-Graph Cycle Detection

    func testProfileOverrideCompilerStripsTwoNodeYAMLProxyDialerCycle() {
        let yaml = """
        proxies:
          - {name: ProxyA, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: ProxyB}
          - {name: ProxyB, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: ProxyA}
        proxy-groups:
          - {name: Select, type: select, proxies: [ProxyA, ProxyB]}
        rules:
          - MATCH,Select
        """

        let result = ProfileOverrideCompiler.apply(nil, to: yaml)
        XCTAssertTrue(result.yaml.contains("ProxyA") && result.yaml.contains("ProxyB"))
        XCTAssertFalse(
            hasDialerEdge(from: "ProxyA", to: "ProxyB", in: result.yaml)
                && hasDialerEdge(from: "ProxyB", to: "ProxyA", in: result.yaml),
            "2-node cycle ProxyA <-> ProxyB must have at least one dialer-proxy edge stripped:\n\(result.yaml)"
        )
    }

    func testProfileOverrideCompilerStripsThreeNodeYAMLProxyDialerCycle() {
        let yaml = """
        proxies:
          - {name: NodeA, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: NodeB}
          - {name: NodeB, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: NodeC}
          - {name: NodeC, type: ss, server: 3.3.3.3, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: NodeA}
        proxy-groups:
          - {name: Select, type: select, proxies: [NodeA, NodeB, NodeC]}
        rules:
          - MATCH,Select
        """

        let result = ProfileOverrideCompiler.apply(nil, to: yaml)
        let edges = [
            hasDialerEdge(from: "NodeA", to: "NodeB", in: result.yaml),
            hasDialerEdge(from: "NodeB", to: "NodeC", in: result.yaml),
            hasDialerEdge(from: "NodeC", to: "NodeA", in: result.yaml),
        ].filter { $0 }.count
        XCTAssertLessThan(edges, 3, "3-node cycle A->B->C->A must be broken by stripping a closing dialer-proxy edge:\n\(result.yaml)")
    }

    func testProfileOverrideCompilerStripsDialerCycleThroughProxyGroupIndirection() {
        let yaml = """
        proxies:
          - {name: Entry, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
          - {name: Exit, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: RelayGroup, type: select, proxies: [Entry]}
        rules:
          - MATCH,RelayGroup
        """
        let override = ProfileOverride(
            chainedProxies: [
                ChainedProxyOverride(
                    name: "ChainLoop",
                    dialerProxy: "RelayGroup",
                    target: .existingNode(name: "Exit"),
                    parentGroup: "RelayGroup"
                )
            ]
        )

        let result = ProfileOverrideCompiler.apply(override, to: yaml)
        XCTAssertFalse(
            hasDialerEdge(from: "ChainLoop", to: "RelayGroup", in: result.yaml),
            "ChainLoop -> RelayGroup -> ChainLoop forms a closed cycle and must strip dialer-proxy:\n\(result.yaml)"
        )
    }

    func testProfileOverrideCompilerStripsTwoAndThreeNodeChainedProxyOverrideCycles() {
        let yaml = """
        proxies:
          - {name: Leaf1, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
          - {name: Leaf2, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: p}
          - {name: Leaf3, type: ss, server: 3.3.3.3, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: Select, type: select, proxies: [Leaf1, Leaf2, Leaf3]}
        rules:
          - MATCH,Select
        """

        let twoNodeOverride = ProfileOverride(
            chainedProxies: [
                ChainedProxyOverride(name: "ChainA", dialerProxy: "ChainB", target: .existingNode(name: "Leaf1")),
                ChainedProxyOverride(name: "ChainB", dialerProxy: "ChainA", target: .existingNode(name: "Leaf2")),
            ]
        )
        let twoResult = ProfileOverrideCompiler.apply(twoNodeOverride, to: yaml)
        XCTAssertTrue(twoResult.yaml.contains("ChainA") && twoResult.yaml.contains("ChainB"))
        XCTAssertFalse(
            hasDialerEdge(from: "ChainA", to: "ChainB", in: twoResult.yaml)
                && hasDialerEdge(from: "ChainB", to: "ChainA", in: twoResult.yaml),
            "2-node chained override cycle ChainA <-> ChainB must strip cyclic dialer-proxy:\n\(twoResult.yaml)"
        )

        let threeNodeOverride = ProfileOverride(
            chainedProxies: [
                ChainedProxyOverride(name: "HopA", dialerProxy: "HopB", target: .existingNode(name: "Leaf1")),
                ChainedProxyOverride(name: "HopB", dialerProxy: "HopC", target: .existingNode(name: "Leaf2")),
                ChainedProxyOverride(name: "HopC", dialerProxy: "HopA", target: .existingNode(name: "Leaf3")),
            ]
        )
        let threeResult = ProfileOverrideCompiler.apply(threeNodeOverride, to: yaml)
        let edges = [
            hasDialerEdge(from: "HopA", to: "HopB", in: threeResult.yaml),
            hasDialerEdge(from: "HopB", to: "HopC", in: threeResult.yaml),
            hasDialerEdge(from: "HopC", to: "HopA", in: threeResult.yaml),
        ].filter { $0 }.count
        XCTAssertTrue(threeResult.yaml.contains("HopA") && threeResult.yaml.contains("HopB") && threeResult.yaml.contains("HopC"))
        XCTAssertLessThan(edges, 3, "3-node chained override cycle HopA->HopB->HopC->HopA must be broken:\n\(threeResult.yaml)")
    }

    // MARK: - 2. RuleProviderEngine & ProxyProviderEngine URL Validation

    func testRuleProviderEngineAllowsLoopbackAndPrivateHTTPURLsAndBlocksFileScheme() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("rule-url-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = RuleProviderEngine(directoryURL: tempDir)

        for allowed in [
            "http://127.0.0.1:8080/rules.yaml",
            "https://127.0.0.1:8443/rules.yaml",
            "http://localhost:3000/rules.txt",
            "http://192.168.1.50:8080/rules.yaml",
            "http://10.0.0.2/rules.txt",
        ] {
            let meta = RuleProviderMetadata(name: allowed, url: URL(string: allowed)!)
            do {
                try await engine.registerProvider(meta)
            } catch {
                XCTFail("Expected local/private URL \(allowed) to succeed, got \(error)")
            }
        }

        let fileMeta = RuleProviderMetadata(name: "local-file", url: URL(string: "file:///tmp/rules.txt")!)
        do {
            try await engine.registerProvider(fileMeta)
            XCTFail("Expected file:// URL to be rejected")
        } catch let error as RuleProviderError {
            XCTAssertEqual(error, .insecureScheme)
        }
    }

    func testProxyProviderEngineAllowsLoopbackAndPrivateHTTPURLsAndBlocksFileScheme() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxy-url-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let engine = ProxyProviderEngine(directoryURL: tempDir)

        for allowed in [
            "http://127.0.0.1:8080/proxies.yaml",
            "https://127.0.0.1:8443/proxies.yaml",
            "http://localhost:9000/proxies.yaml",
            "http://172.16.10.5/proxies.yaml",
        ] {
            let meta = ProxyProviderMetadata(name: allowed, url: URL(string: allowed)!)
            do {
                try await engine.addProvider(meta)
            } catch {
                XCTFail("Expected local/private URL \(allowed) to succeed, got \(error)")
            }
        }

        for rejected in ["file:///tmp/proxies.yaml", "http://example.com/proxies.yaml"] {
            let meta = ProxyProviderMetadata(name: rejected, url: URL(string: rejected)!)
            do {
                try await engine.addProvider(meta)
                XCTFail("Expected \(rejected) to be rejected")
            } catch let error as ProxyProviderError {
                XCTAssertEqual(error, .insecureScheme)
            }
        }
    }

    // MARK: - 3. ProfileCloudSyncManager Cross-Platform Key & Payload Compatibility

    @MainActor
    func testMacOSSyncMigratesLegacyMasterKeyAndImportsBareProfileCatalog() async throws {
        let kvs = InMemoryKVS()
        let iosKeys = InMemoryProfileKeyStore()
        let macKeys = InMemoryProfileKeyStore()
        let macDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mac-legacy-sync-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: macDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: macDir) }

        let legacyKey = try iosKeys.loadOrCreateKey(keyID: ProfileCloudSyncManager.cloudSyncKeyID)
        let profile = ActiveProfile(
            name: "Shared iOS Sub",
            yaml: "proxies:\n  - {name: Edge, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}\n"
        )
        let managed = ManagedProfile(profile: profile)
        let bareCatalog = ProfileCatalog(
            activeProfileID: managed.id,
            profiles: [managed]
        )
        let plaintext = try JSONEncoder().encode(bareCatalog)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: legacyKey))
        let combined = sealed.combined!
        let digest = SHA256.hash(data: combined).map { String(format: "%02x", $0) }.joined()
        let payload = CloudSyncPayload(
            updatedAtUnixMilliseconds: 1_700_000_000_000,
            deviceIdentifier: "ios-legacy-device",
            encryptedData: combined,
            sha256: digest
        )
        kvs.set(try JSONEncoder().encode(payload), forKey: CloudSyncPayload.storageKey)
        let legacyMasterKeyStorageKey = "aetherroute.cloud_sync.master_key.v1"
        kvs.set(legacyKey, forKey: legacyMasterKeyStorageKey)

        let store = ProfileCatalogStore(directoryURL: macDir, keyStore: macKeys)
        let manager = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: macKeys,
            catalogStore: store,
            deviceIdentifier: "mac-receiver",
            deviceName: "Mac Receiver"
        )
        manager.isCloudSyncEnabled = true

        let synced = try await manager.sync()
        XCTAssertTrue(synced)
        let loaded = try store.loadOrMigrate()
        XCTAssertEqual(loaded.profiles.map(\.profile.name), ["Shared iOS Sub"])
        // Without a writable Keychain import API in `ProfileKeyStoring`, the legacy key remains
        // intact while pushing updates keeps using the authenticated legacy key so peers can read it.
        XCTAssertEqual(kvs.data(forKey: legacyMasterKeyStorageKey), legacyKey)

        let pushed = try await manager.forcePushToCloud()
        XCTAssertTrue(pushed)
        let pushedRaw = try XCTUnwrap(kvs.data(forKey: CloudSyncPayload.storageKey))
        let pushedEnvelope = try JSONDecoder().decode(CloudSyncPayload.self, from: pushedRaw)
        let pushedBox = try AES.GCM.SealedBox(combined: pushedEnvelope.encryptedData)
        let pushedPlain = try AES.GCM.open(pushedBox, using: SymmetricKey(data: legacyKey))
        let pushedCatalog = try JSONDecoder().decode(CloudSyncCatalogPayload.self, from: pushedPlain)
        XCTAssertEqual(pushedCatalog.catalog.profiles.map(\.profile.name), ["Shared iOS Sub"])

        // Once iCloud Keychain delivers `cloudSyncKeyID`, pulling retires the legacy plaintext KVS key.
        let syncedMacKeys = InMemoryProfileKeyStore(keys: [ProfileCloudSyncManager.cloudSyncKeyID: legacyKey])
        let syncedManager = ProfileCloudSyncManager(
            kvStore: kvs,
            keyStore: syncedMacKeys,
            catalogStore: store,
            deviceIdentifier: "mac-synced-receiver",
            deviceName: "Mac Synced Receiver"
        )
        syncedManager.isCloudSyncEnabled = true
        _ = try await syncedManager.forcePullFromCloud()
        XCTAssertNil(kvs.data(forKey: legacyMasterKeyStorageKey))
        XCTAssertEqual(CloudSyncPayload.storageKey, "aetherroute.profile_catalog.sync.v1")
        XCTAssertEqual(CloudSyncPayload.userRulesStorageKey, "aetherroute.user_rules.sync.v1")
        XCTAssertEqual(RuleProviderSyncPayload.storageKey, "aetherroute.rule_providers.sync.v1")
    }

    // MARK: - 4. Cached External RuleProvider Injection & Available Proxy Names

    func testProfileOverrideCompilerInjectsCachedRuleProviderRulesAsHighPriority() throws {
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("compiler-rp-cache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let enabledProvider = RuleProviderMetadata(
            name: "CustomBlocklist",
            url: URL(string: "https://rules.example.com/block.yaml")!,
            behavior: .domain,
            format: .yaml,
            defaultTarget: "REJECT",
            isEnabled: true
        )
        let disabledProvider = RuleProviderMetadata(
            name: "DisabledList",
            url: URL(string: "https://rules.example.com/disabled.yaml")!,
            behavior: .domain,
            format: .yaml,
            defaultTarget: "DIRECT",
            isEnabled: false
        )

        let enabledYAML = """
        payload:
          - '+.ads.example.com'
          - 'tracker.example.org'
        """
        try enabledYAML.write(
            to: cacheDir.appendingPathComponent("\(enabledProvider.id.uuidString).dat"),
            atomically: true,
            encoding: .utf8
        )
        try "payload:\n  - 'should-not-appear.example.com'\n".write(
            to: cacheDir.appendingPathComponent("\(disabledProvider.id.uuidString).dat"),
            atomically: true,
            encoding: .utf8
        )

        let profileYAML = """
        proxies:
          - {name: Edge, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [Edge]}
        rules:
          - DOMAIN-SUFFIX,example.com,Proxy
          - MATCH,Proxy
        """

        let result = ProfileOverrideCompiler.apply(
            nil,
            externalRuleProviders: [enabledProvider, disabledProvider],
            ruleProviderCacheDirectoryURL: cacheDir,
            to: profileYAML
        )
        let rules = result.yaml
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- DOMAIN") || $0.hasPrefix("- MATCH") }
        let adsIdx = try XCTUnwrap(rules.firstIndex { $0.contains("DOMAIN-SUFFIX,ads.example.com,REJECT") })
        let trackerIdx = try XCTUnwrap(rules.firstIndex { $0.contains("DOMAIN,tracker.example.org,REJECT") })
        let profileRuleIdx = try XCTUnwrap(rules.firstIndex { $0.contains("DOMAIN-SUFFIX,example.com,Proxy") })
        let matchIdx = try XCTUnwrap(rules.firstIndex { $0.contains("MATCH,Proxy") })
        XCTAssertLessThan(adsIdx, profileRuleIdx)
        XCTAssertLessThan(trackerIdx, matchIdx)
        XCTAssertFalse(result.yaml.contains("should-not-appear.example.com"))
    }

    func testProfileOverrideCompilerAvailableProxyNamesIncludesOverridesAndProviders() {
        let yaml = """
        proxies:
          - {name: BaseNode, type: ss, server: 1.1.1.1, port: 443, cipher: aes-128-gcm, password: p}
          - {name: HiddenNotice, type: ss, server: 2.2.2.2, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [BaseNode, HiddenNotice]}
        rules:
          - MATCH,Proxy
        """
        let profileOverride = ProfileOverride(
            hiddenNodeKeywords: ["Notice"],
            chainedProxies: [
                ChainedProxyOverride(name: "ChainRelay", dialerProxy: "BaseNode", target: .existingNode(name: "BaseNode"))
            ]
        )
        let globalOverride = ProfileOverride(
            chainedProxies: [
                ChainedProxyOverride(name: "GlobalRelay", dialerProxy: "BaseNode", target: .existingNode(name: "BaseNode"))
            ]
        )

        let available = ProfileOverrideCompiler.availableProxyNames(
            in: yaml,
            proxyOverride: profileOverride,
            globalOverride: globalOverride,
            additionalProviderNodes: ["MergedSubNode", "BaseNode"]
        )
        XCTAssertTrue(available.contains("BaseNode"))
        XCTAssertTrue(available.contains("ChainRelay"))
        XCTAssertTrue(available.contains("GlobalRelay"))
        XCTAssertTrue(available.contains("MergedSubNode"))
        XCTAssertFalse(available.contains("HiddenNotice"))
    }

    // MARK: - 5. CustomRule / ApplicationRuleMatch Bundle & Process Basename Matching

    func testApplicationRuleMatchesBundlePathAndSandboxedProcessBasename() throws {
        let chromeRule = try XCTUnwrap(CustomRule.application(
            bundleIdentifier: "com.google.Chrome",
            bundlePath: "/Applications/Google Chrome.app",
            displayName: "Google Chrome",
            target: .proxy("Proxy")
        ))

        // Exact bundle ID and helper ID
        XCTAssertTrue(chromeRule.matchesApplication(
            signingIdentifier: "com.google.Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ))
        XCTAssertTrue(chromeRule.matchesApplication(
            signingIdentifier: "com.google.Chrome.helper.renderer",
            executablePath: nil
        ))
        // Sandbox proc_pidpath limit: executablePath nil/unavailable, only process basename reported
        XCTAssertTrue(chromeRule.matchesApplication(
            signingIdentifier: nil,
            executablePath: nil,
            processName: "Google Chrome"
        ))
        // AppTranslocation or firmlink path
        XCTAssertTrue(chromeRule.matchesApplication(
            signingIdentifier: nil,
            executablePath: "/System/Volumes/Data/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ))
        // Unrelated app must NOT falsely match
        XCTAssertFalse(chromeRule.matchesApplication(
            signingIdentifier: "com.google.ChromeX",
            executablePath: "/Applications/Google ChromeX.app/Contents/MacOS/Google ChromeX",
            processName: "Google ChromeX"
        ))

        // Unsigned wrapper app with distinct executable basename
        let unsignedWrapper = try XCTUnwrap(CustomRule.application(
            bundleIdentifier: nil,
            bundlePath: "/Applications/MyWrapper.app",
            displayName: "MyWrapper",
            target: .direct
        ))
        XCTAssertTrue(unsignedWrapper.matchesApplication(
            signingIdentifier: nil,
            executablePath: nil,
            processName: "MyWrapper",
            bundleExecutableName: "WrapperCore"
        ))
        XCTAssertTrue(unsignedWrapper.matchesApplication(
            signingIdentifier: nil,
            executablePath: nil,
            processName: "WrapperCore",
            bundleExecutableName: "WrapperCore"
        ))
        XCTAssertFalse(unsignedWrapper.matchesApplication(
            signingIdentifier: nil,
            executablePath: "/usr/bin/curl",
            processName: "curl",
            bundleExecutableName: "WrapperCore"
        ))
    }

    // MARK: - Helpers

    private func hasDialerEdge(from proxyName: String, to dialerName: String, in yaml: String) -> Bool {
        let block = blockForProxy(proxyName, in: yaml)
        return block.contains("dialer-proxy: \(dialerName)")
            || block.contains("dialer-proxy: \"\(dialerName)\"")
            || block.contains("dialer-proxy: '\(dialerName)'")
    }

    private func blockForProxy(_ name: String, in yaml: String) -> String {
        let lines = yaml.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let idx = lines.firstIndex(where: {
            $0.contains("name: \(name),")
                || $0.contains("name: \"\(name)\"")
                || $0.contains("name: '\(name)'")
                || $0.trimmingCharacters(in: .whitespaces).hasSuffix("name: \(name)")
        }) else {
            return ""
        }
        var block = [lines[idx]]
        if lines[idx].contains("{") {
            return lines[idx]
        }
        for line in lines[(idx + 1)...] {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- ") || (!line.hasPrefix("    ") && !trimmed.isEmpty) {
                break
            }
            block.append(line)
        }
        return block.joined(separator: "\n")
    }
}

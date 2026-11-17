import AetherRouteKit
import Combine
import Darwin
import Foundation
import Network
import NetworkExtension

// MARK: - Standalone Compilation Shims (UI-owned types excluded from standalone target)

@MainActor
final class MenuBarTrafficController {
    static let shared = MenuBarTrafficController()
    var isEnabled = false
    var onEnabledChanged: ((Bool) -> Void)?
    func reset() {}
    func updateTelemetry(upload: UInt64, download: UInt64) {}
}

enum UIResponsivenessProbe {
    static var shouldDeferLiveTelemetryTick: Bool { false }
}

@MainActor
final class AppWindowManager {
    static let shared = AppWindowManager()
    func showMainWindow() {}
}

extension AetherNodeProfileCompilerError {
    var localizedAppDescription: String { errorDescription ?? localizedDescription }
}

extension Error {
    var overrideMessage: String { localizedDescription }
}

extension Notification.Name {
    static let aetherRouteNavigateToSection = Notification.Name("AetherRoute.NavigateToSection")
}

extension AppLocalization {
    static func inline(_ english: String, chinese: String) -> String {
        english
    }
}

// MARK: - Minimal Test Harness

private struct TestFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw TestFailure(message: message)
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

private final class MockNetworkSetupExecutor: SystemProxyCommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    var invocations: [(args: [String], onMainThread: Bool)] = []
    var artificialDelaySeconds: TimeInterval = 0

    func run(executablePath: String, arguments: [String]) throws -> SystemProxyCommandOutput {
        if artificialDelaySeconds > 0 {
            Thread.sleep(forTimeInterval: artificialDelaySeconds)
        }
        let isMain = Thread.isMainThread
        lock.lock()
        invocations.append((arguments, isMain))
        lock.unlock()

        if arguments == ["-listallnetworkservices"] {
            return SystemProxyCommandOutput(
                exitCode: 0,
                standardOutput: "An asterisk (*) denotes that a network service is disabled.\nWi-Fi\n",
                standardError: ""
            )
        }
        if arguments.first == "-getwebproxy"
            || arguments.first == "-getsecurewebproxy"
            || arguments.first == "-getsocksfirewallproxy" {
            return SystemProxyCommandOutput(
                exitCode: 0,
                standardOutput: "Enabled: No\nServer: \nPort: 0\n",
                standardError: ""
            )
        }
        if arguments.first == "-getproxybypassdomains" {
            return SystemProxyCommandOutput(
                exitCode: 0,
                standardOutput: "*.local\n169.254/16\n",
                standardError: ""
            )
        }
        return SystemProxyCommandOutput(exitCode: 0, standardOutput: "", standardError: "")
    }

    var recordedInvocations: [(args: [String], onMainThread: Bool)] {
        lock.lock()
        defer { lock.unlock() }
        return invocations
    }
}

private final class LoopbackTCPServer: @unchecked Sendable {
    let port: UInt16
    private let listenFD: Int32
    private let acceptQueue = DispatchQueue(label: "com.aetherroute.test.loopback-server")
    private let state = LockedBox<(running: Bool, acceptedCount: Int)>((true, 0))

    init(sendGreeting: String? = nil) throws {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw TestFailure(message: "Failed to allocate loopback socket")
        }
        var reuse: Int32 = 1
        Darwin.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0, Darwin.listen(fd, 16) == 0 else {
            Darwin.close(fd)
            throw TestFailure(message: "Failed to bind loopback server")
        }

        var boundAddr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let sockNameResult = withUnsafeMutablePointer(to: &boundAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(fd, $0, &len)
            }
        }
        guard sockNameResult == 0 else {
            Darwin.close(fd)
            throw TestFailure(message: "Failed to read bound port")
        }

        self.listenFD = fd
        self.port = UInt16(bigEndian: boundAddr.sin_port)

        acceptQueue.async { [weak self] in
            guard let self else { return }
            while true {
                let running = self.state.withLock { $0.running }
                if !running { break }
                var peer = sockaddr_in()
                var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(self.listenFD, $0, &peerLen)
                    }
                }
                if clientFD < 0 { break }
                self.state.withLock { $0.acceptedCount += 1 }
                if let sendGreeting {
                    let bytes = Array(sendGreeting.utf8)
                    _ = bytes.withUnsafeBytes { Darwin.send(clientFD, $0.baseAddress, $0.count, 0) }
                    usleep(100_000)
                }
                Darwin.close(clientFD)
            }
        }
    }

    var acceptedCount: Int {
        state.withLock { $0.acceptedCount }
    }

    func stop() {
        state.withLock { $0.running = false }
        Darwin.close(listenFD)
    }
}

private func connectToLoopbackPort(_ port: Int) -> Int32? {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }

    var tv = timeval(tv_sec: 2, tv_usec: 0)
    Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    addr.sin_port = UInt16(port).bigEndian

    let connected = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
        }
    }
    guard connected else {
        Darwin.close(fd)
        return nil
    }
    return fd
}

private func sendRawTCPRequest(port: Int, payload: String) -> String? {
    guard let fd = connectToLoopbackPort(port) else { return nil }
    defer { Darwin.close(fd) }

    let bytes = Array(payload.utf8)
    _ = bytes.withUnsafeBytes { ptr in
        Darwin.send(fd, ptr.baseAddress, ptr.count, 0)
    }

    var buffer = [UInt8](repeating: 0, count: 4096)
    let readCount = Darwin.recv(fd, &buffer, buffer.count, 0)
    if readCount < 0 { return nil }
    if readCount == 0 { return "" }
    return String(decoding: buffer.prefix(readCount), as: UTF8.self)
}

@MainActor
private func waitForPortListening(_ port: Int) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(2))
    while clock.now < deadline {
        let ready = await Task.detached {
            if let fd = connectToLoopbackPort(port) {
                Darwin.close(fd)
                return true
            }
            return false
        }.value
        if ready { return }
        try? await Task.sleep(for: .milliseconds(20))
    }
    throw TestFailure(message: "Timed out waiting for listener on port \(port)")
}

@MainActor
private func makeTestTunnel(
    reviewState: String? = "disconnected",
    extraEnvironment: [String: String] = [:],
    executor: SystemProxyCommandExecuting? = nil,
    ruleProviderEngine: RuleProviderEngine = .shared,
    proxyProviderEngine: ProxyProviderEngine = .shared
) -> (tunnel: TunnelManager, defaults: UserDefaults, suiteName: String) {
    let suiteName = "com.aetherroute.macfunc.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    var env = extraEnvironment
    if let reviewState {
        env["AETHERROUTE_UI_REVIEW"] = reviewState
        env["AETHERROUTE_UI_REVIEW_PRIVACY"] = "accepted"
    }
    let configurator = SystemProxyConfigurator(
        executor: executor ?? MockNetworkSetupExecutor(),
        defaults: defaults
    )
    let tunnel = TunnelManager(
        environment: env,
        privacyConsentStore: PrivacyConsentStore(defaults: defaults),
        routingModePreferenceStore: RoutingModePreferenceStore(defaults: defaults),
        connectionIntentStore: ConnectionIntentStore(defaults: defaults),
        systemProxyConfigurator: configurator,
        userDefaults: defaults,
        ruleProviderEngine: ruleProviderEngine,
        proxyProviderEngine: proxyProviderEngine
    )
    return (tunnel, defaults, suiteName)
}

private func cleanupDefaults(_ suiteName: String) {
    UserDefaults.standard.removePersistentDomain(forName: suiteName)
}

// MARK: - Test Suite

@main
enum MacFuncLifecycleAndV3FixTests {
    static func main() async {
        let tests: [(String, @MainActor () async throws -> Void)] = [
            ("testProxyLatencyStoreIsolationAndPublishing", testProxyLatencyStoreIsolationAndPublishing),
            ("testDNSRuntimePolicyCompatibilityDefaultUsesRawYAML", testDNSRuntimePolicyCompatibilityDefaultUsesRawYAML),
            ("testHandleExternalURLRejectsControlCommands", testHandleExternalURLRejectsControlCommands),
            ("testHandleIncomingSwitchProfileAllowedWhenConnected", testHandleIncomingSwitchProfileAllowedWhenConnected),
            ("testAppAutomationSwitchProfileWhileConnectedAndLastEvaluatedGuard", testAppAutomationSwitchProfileWhileConnectedAndLastEvaluatedGuard),
            ("testSystemProxyConfiguratorRunsOffMainActorAndTerminationWaits", testSystemProxyConfiguratorRunsOffMainActorAndTerminationWaits),
            ("testTraceRouteCarriesCustomHostsAndNonFakeAddresses", testTraceRouteCarriesCustomHostsAndNonFakeAddresses),
            ("testWaitForConnectionToSettleExitsPromptlyOnDisconnectedAndDisconnecting", testWaitForConnectionToSettleExitsPromptlyOnDisconnectedAndDisconnecting),
            ("testVerifyConnectionReadinessAttemptIDPreventsStaleTaskClobbering", testVerifyConnectionReadinessAttemptIDPreventsStaleTaskClobbering),
            ("testClearProxySelectionRuntimeStatePreventsStaleDeferRemoval", testClearProxySelectionRuntimeStatePreventsStaleDeferRemoval),
            ("testMeasureVerifiedLatencyCancelledDoesNotFallbackToReachability", testMeasureVerifiedLatencyCancelledDoesNotFallbackToReachability),
            ("testProbeTCPLatencyCancelsPromptlyOnTaskCancel", testProbeTCPLatencyCancelsPromptlyOnTaskCancel),
            ("testPreCancelledProbeDirectMemberAndTCPLatencyDoNotTrap", testPreCancelledProbeDirectMemberAndTCPLatencyDoNotTrap),
            ("testPerformAutomaticReconnectDoesNotRearmWhenTransitionedToFailed", testPerformAutomaticReconnectDoesNotRearmWhenTransitionedToFailed),
            ("testSetEnabledFalseWithNilManagerDoesNotTouchNEVPNManager", testSetEnabledFalseWithNilManagerDoesNotTouchNEVPNManager),
            ("testCreateAndRebuildMergedProfileEnforceUpdatingGuard", testCreateAndRebuildMergedProfileEnforceUpdatingGuard),
            ("testLANProxyLoopbackAndSelfPortSecurityRules", testLANProxyLoopbackAndSelfPortSecurityRules),
            ("testLANProxyRejectsSelfListeningPortLoopLiveAndAllowsLocalTarget", testLANProxyRejectsSelfListeningPortLoopLiveAndAllowsLocalTarget),
            ("testRefreshAllExternalProvidersKeepsGlobalCustomRulesIsolated", testRefreshAllExternalProvidersKeepsGlobalCustomRulesIsolated),
            ("testUpgradeWithLegacyPollutedProvidersJSONInCatalogCleansGlobalRulesAndPreservesUserProviders", testUpgradeWithLegacyPollutedProvidersJSONInCatalogCleansGlobalRulesAndPreservesUserProviders),
        ]

        var passed = 0
        var failures: [(String, String)] = []

        for (name, body) in tests {
            do {
                try await body()
                passed += 1
                print("PASS: \(name)")
            } catch {
                failures.append((name, "\(error)"))
                print("FAIL: \(name) -> \(error)")
            }
        }

        print("MacFuncLifecycleAndV3FixTests summary: \(passed)/\(tests.count) passed, \(failures.count) failed")
        if !failures.isEmpty {
            Darwin.exit(1)
        }
    }

    @MainActor
    private static func testProxyLatencyStoreIsolationAndPublishing() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel()
        defer { cleanupDefaults(suiteName) }

        let store: ProxyLatencyStore = tunnel.latencyStore
        var tunnelChangeCount = 0
        var storeChangeCount = 0
        let c1 = tunnel.objectWillChange.sink { _ in tunnelChangeCount += 1 }
        let c2 = store.objectWillChange.sink { _ in storeChangeCount += 1 }
        defer {
            c1.cancel()
            c2.cancel()
        }

        let groupName = "Balanced"
        let state = ProxyLatencyState(
            results: [ProxyLatencyResult(member: "Singapore Edge", delayMilliseconds: 42)]
        )
        tunnel.proxyLatencies[groupName] = state
        // Assigning equal state must be a no-op
        tunnel.proxyLatencies[groupName] = state
        tunnel.proxyLatencyRequests.insert(groupName)
        tunnel.memberLatencyRequests.insert("\(groupName):Singapore Edge")
        tunnel.latencyMeasuredAt[groupName] = ["Singapore Edge": Date()]

        try expect(
            tunnelChangeCount == 0,
            "Latency updates fired TunnelManager.objectWillChange \(tunnelChangeCount) time(s); Contract 1 requires 0."
        )
        try expect(
            storeChangeCount == 4,
            "Expected ProxyLatencyStore.objectWillChange to fire 4 times (ignoring duplicate no-op write), got \(storeChangeCount)"
        )
    }

    @MainActor
    private static func testDNSRuntimePolicyCompatibilityDefaultUsesRawYAML() async throws {
        let uniqueYAML = """
        # unique-test-\(UUID().uuidString)
        proxies:
          - {name: DirectNode, type: direct}
        proxy-groups:
          - {name: Proxy, type: select, proxies: [DirectNode]}
        rules:
          - MATCH,Proxy
        """
        let profile = ActiveProfile(
            name: "NoDNS",
            yaml: uniqueYAML,
            importedAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
        let managed = ManagedProfile(profile: profile)
        let catalog = ProfileCatalog(activeProfileID: managed.id, profiles: [managed])
        let projection = ProfileCatalogProjectionBuilder.production(
            catalog,
            customRules: [],
            remoteRules: [],
            enableDomesticDirect: true,
            loadSavedDNSPolicy: { _ in nil }
        )
        try expect(
            projection.dnsPolicy == DNSRuntimePolicy(resolutionMode: .fakeIP, ipv6: .disabled),
            "Expected raw YAML compatibility default (fakeIP, ipv6: .disabled), got \(projection.dnsPolicy)"
        )
    }

    @MainActor
    private static func testHandleExternalURLRejectsControlCommands() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel()
        defer { cleanupDefaults(suiteName) }

        let initialProfileID = tunnel.activeProfileID
        try expect(tunnel.profiles.count >= 2, "Expected at least 2 review profiles")
        let secondProfile = tunnel.profiles[1]

        tunnel.handleExternalURL(URL(string: "aetherroute://mode?mode=direct")!)
        tunnel.handleExternalURL(URL(string: "aetherroute://profile?name=\(secondProfile.profile.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!)
        tunnel.handleExternalURL(URL(string: "aetherroute://connect")!)
        try await Task.sleep(for: .milliseconds(40))

        try expect(tunnel.routingMode == .rule, "handleExternalURL mutated routingMode to \(tunnel.routingMode)")
        try expect(tunnel.activeProfileID == initialProfileID, "handleExternalURL switched profile illegally")
        try expect(tunnel.state == .disconnected, "handleExternalURL triggered connect illegally (state=\(tunnel.state))")
        try expect(tunnel.externalSubscriptionLinkError != nil, "handleExternalURL did not reject control command with an error")
    }

    @MainActor
    private static func testHandleIncomingSwitchProfileAllowedWhenConnected() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connected")
        defer { cleanupDefaults(suiteName) }

        tunnel.setControlURLSchemeEnabled(true)
        let initialProfileID = tunnel.activeProfileID
        try expect(tunnel.profiles.count >= 2, "Expected >= 2 profiles")
        let target = tunnel.profiles[1]

        try expect(tunnel.canActivateProfile, "canActivateProfile should be true when connected")

        let encodedName = target.profile.name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        let url = URL(string: "aetherroute://switch-profile?name=\(encodedName)")!
        tunnel.handleIncomingExternalURL(url)
        try await Task.sleep(for: .milliseconds(60))

        try expect(
            tunnel.activeProfileID != initialProfileID && tunnel.activeProfileID == target.id,
            "handleIncomingExternalURL switch-profile failed while connected (activeProfileID=\(String(describing: tunnel.activeProfileID)))"
        )
    }

    @MainActor
    private static func testAppAutomationSwitchProfileWhileConnectedAndLastEvaluatedGuard() async throws {
        let (tunnel, defaults, suiteName) = makeTestTunnel(reviewState: "connecting")
        defer { cleanupDefaults(suiteName) }

        try expect(tunnel.profiles.count >= 2, "Expected >= 2 profiles")
        let targetID = tunnel.profiles[1].id
        let envSnapshot = NetworkEnvironmentSnapshot(
            interfaceName: "en0",
            isEthernet: false,
            wifiSSID: "OfficeWiFi",
            gatewayAddress: nil
        )

        let automationStore = NetworkAutomationPreferenceStore(defaults: defaults)
        var prefs = NetworkAutomationPreferences(isEnabled: true)
        prefs.rules = [
            NetworkAutomationRule(
                isEnabled: true,
                triggerKind: .wifiSSID,
                matchValue: "OfficeWiFi",
                action: .switchProfile(targetID)
            ),
        ]
        try automationStore.save(prefs)

        let distribution = IndependentDistributionController()
        let automation = AppAutomationController(
            tunnel: tunnel,
            distribution: distribution,
            environment: ["AETHERROUTE_UI_REVIEW": "connecting"],
            userDefaults: defaults,
            notificationCenter: nil
        )

        // While `.connecting`, `canActivateProfile == false`: automation must skip AND must NOT stamp `lastEvaluatedEnvironment`!
        automation.evaluateNetworkAutomationIfNeeded(force: false, environmentOverride: envSnapshot)
        try expect(
            automation.lastEvaluatedEnvironment == nil,
            "lastEvaluatedEnvironment was stamped even though readiness guard blocked switchProfile"
        )

        // Transition to `.connected`: `canActivateProfile` is now `true`, so non-forced poll must fire `.switchProfile`!
        tunnel.state = .connected
        automation.evaluateNetworkAutomationIfNeeded(force: false, environmentOverride: envSnapshot)
        try await Task.sleep(for: .milliseconds(60))

        try expect(
            tunnel.activeProfileID == targetID,
            "AppAutomationController did not switch profile while connected after readiness guard passed"
        )
        try expect(
            automation.lastEvaluatedEnvironment == envSnapshot,
            "lastEvaluatedEnvironment was not updated after readiness guard succeeded"
        )
    }

    @MainActor
    private static func testSystemProxyConfiguratorRunsOffMainActorAndTerminationWaits() async throws {
        let mock = MockNetworkSetupExecutor()
        mock.artificialDelaySeconds = 0.05
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "disconnected", executor: mock)
        defer { cleanupDefaults(suiteName) }

        // Test SystemProxyWorkCoordinator off-@MainActor + completion + restoreAndWait directly using TunnelManager's configurator
        let settings = LocalProxySettings(
            isEnabled: true,
            httpPort: 17_890,
            socksPort: 17_891,
            allowLAN: false,
            setAsSystemProxy: true
        )
        tunnel.localProxySettings = settings
        let expectedResult = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            tunnel.systemProxyCoordinator.enqueueApply(
                settings: settings,
                configurator: tunnel.systemProxyConfigurator
            ) { error in
                cont.resume(returning: error == nil)
            }
        }
        try expect(expectedResult, "SystemProxyWorkCoordinator apply failed with mock executor")
        try expect(
            tunnel.systemProxyConfigurator.hasPendingBackup,
            "Expected SystemProxyConfigurator to record pending backup"
        )
        try expect(
            tunnel.requiresDisconnectBeforeApplicationTermination,
            "requiresDisconnectBeforeApplicationTermination must return true while System Proxy backup is active"
        )

        let invocations = mock.recordedInvocations
        try expect(!invocations.isEmpty, "Expected networksetup invocations")
        try expect(
            invocations.allSatisfy { !$0.onMainThread },
            "SystemProxyConfigurator ran networksetup on MainActor instead of background worker queue"
        )

        let restoreErr = await tunnel.systemProxyCoordinator.restoreAndWait(
            configurator: tunnel.systemProxyConfigurator
        )
        try expect(restoreErr == nil, "SystemProxy restore failed")
        try expect(
            !tunnel.systemProxyConfigurator.hasPendingBackup,
            "Pending System Proxy backup remained after restoreAndWait"
        )
        let afterRestore = mock.recordedInvocations
        try expect(
            afterRestore.allSatisfy { !$0.onMainThread },
            "SystemProxy restore ran on MainActor"
        )
    }

    @MainActor
    private static func testTraceRouteCarriesCustomHostsAndNonFakeAddresses() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "disconnected")
        defer { cleanupDefaults(suiteName) }

        let yaml = """
        proxies:
          - {name: DirectProxy, type: direct}
        proxy-groups:
          - {name: Auto, type: select, proxies: [DirectProxy]}
        rules:
          - IP-CIDR,93.184.216.34/32,Auto,no-resolve
          - MATCH,DIRECT
        """
        let profile = ActiveProfile(
            name: "TraceTest",
            yaml: yaml,
            importedAt: .now,
            overrides: ProfileOverride(
                customHosts: [CustomHostMapping(domain: "example.com", ip: "93.184.216.34")]
            )
        )
        let managed = ManagedProfile(profile: profile)
        tunnel.installReviewProfileCatalog(ProfileCatalog(activeProfileID: managed.id, profiles: [managed]))

        // Pre-supplied Fake-IP address must be filtered out; non-FakeIP + customHosts must reach simulation/request
        let request = RouteTraceRequest(
            host: "example.com",
            port: 443,
            network: .tcp,
            resolvedAddresses: ["198.18.0.10", "93.184.216.34"]
        )
        let result = await tunnel.traceRoute(request)
        try expect(!result.isFakeIP, "Fake-IP address leaked into RouteTraceResult")
        try expect(
            result.dnsAddresses == ["93.184.216.34"] || result.resolvedHostAlias == "93.184.216.34",
            "Expected non-fake IP / custom host resolution to propagate cleanly"
        )
    }

    @MainActor
    private static func testWaitForConnectionToSettleExitsPromptlyOnDisconnectedAndDisconnecting() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connecting")
        defer { cleanupDefaults(suiteName) }

        let transitionTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            tunnel.state = .disconnected
        }
        defer { transitionTask.cancel() }

        let clock = ContinuousClock()
        let start = clock.now
        let settled = await tunnel.waitForConnectionToSettle(timeout: .seconds(4))
        let elapsed = clock.now - start

        try expect(!settled, "waitForConnectionToSettle must return false on .disconnected")
        try expect(
            elapsed < .milliseconds(750),
            "waitForConnectionToSettle lingered (\(elapsed)) on .disconnected"
        )

        tunnel.state = .connecting
        let t2 = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(40))
            tunnel.state = .disconnecting
        }
        defer { t2.cancel() }

        let s2 = clock.now
        let settled2 = await tunnel.waitForConnectionToSettle(timeout: .seconds(4))
        let e2 = clock.now - s2
        try expect(!settled2 && e2 < .milliseconds(750), "waitForConnectionToSettle did not exit promptly on .disconnecting")
    }

    @MainActor
    private static func testVerifyConnectionReadinessAttemptIDPreventsStaleTaskClobbering() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connected")
        defer { cleanupDefaults(suiteName) }

        let sharedConnectionID = UUID()
        tunnel.providerConnectionID = sharedConnectionID
        let sentinelTask = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(10))
        }
        let newerAttemptID = UUID()
        tunnel.connectionReadinessTask = sentinelTask
        tunnel.connectionReadinessAttemptID = newerAttemptID
        tunnel.connectionQuality = .verified

        // Run a stale verifyConnectionReadiness using a different attemptID while cancelled
        let staleAttemptID = UUID()
        let staleTask = Task { @MainActor in
            await tunnel.verifyConnectionReadiness(
                groups: [],
                connectionID: sharedConnectionID,
                attemptID: staleAttemptID
            )
        }
        await staleTask.value

        try expect(
            tunnel.connectionReadinessTask != nil && tunnel.connectionReadinessAttemptID == newerAttemptID,
            "Stale verifyConnectionReadiness defer clobbered a newer task on the same connectionID"
        )
        try expect(
            tunnel.connectionQuality == .verified,
            "Stale readiness task mutated connectionQuality"
        )
        sentinelTask.cancel()
        tunnel.connectionReadinessTask = nil
        tunnel.connectionReadinessAttemptID = nil
    }

    @MainActor
    private static func testClearProxySelectionRuntimeStatePreventsStaleDeferRemoval() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connected")
        defer { cleanupDefaults(suiteName) }

        let groupName = "Balanced"
        let firstTask = Task { @MainActor in
            await tunnel.testProxyLatency(group: groupName)
        }
        try await Task.sleep(for: .milliseconds(25))
        try expect(tunnel.proxyLatencyRequests.contains(groupName), "Expected first latency test to mark request active")

        tunnel.clearProxySelectionRuntimeState()
        tunnel.proxyLatencyRequests.insert(groupName)

        await firstTask.value

        try expect(
            tunnel.proxyLatencyRequests.contains(groupName),
            "Cancelled/reset first latency run defer removed the new run's request flag from proxyLatencyRequests"
        )
    }

    @MainActor
    private static func testMeasureVerifiedLatencyCancelledDoesNotFallbackToReachability() async throws {
        let server = try LoopbackTCPServer()
        defer { server.stop() }

        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connected")
        defer { cleanupDefaults(suiteName) }

        let yaml = """
        proxies:
          - {name: LocalEcho, type: trojan, server: 127.0.0.1, port: \(server.port)}
        proxy-groups:
          - {name: LoopGroup, type: select, proxies: [LocalEcho]}
        rules:
          - MATCH,LoopGroup
        """
        let profile = ActiveProfile(
            name: "LoopProfile",
            yaml: yaml,
            importedAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
        let managed = ManagedProfile(profile: profile)
        tunnel.installReviewProfileCatalog(ProfileCatalog(activeProfileID: managed.id, profiles: [managed]))

        let reachabilityTask = Task { @MainActor in
            await tunnel.measureReachability(members: ["LocalEcho"], runToken: tunnel.currentLatencyRunToken)
        }
        reachabilityTask.cancel()
        await reachabilityTask.value

        try expect(
            server.acceptedCount == 0,
            "Cancelled latency check opened \(server.acceptedCount) fallback TCP socket(s) to loopback server"
        )
    }

    @MainActor
    private static func testProbeTCPLatencyCancelsPromptlyOnTaskCancel() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "disconnected")
        defer { cleanupDefaults(suiteName) }

        let yaml = """
        proxies:
          - {name: BlackholeNode, type: trojan, server: 192.0.2.1, port: 443}
        proxy-groups:
          - {name: LoopGroup, type: select, proxies: [BlackholeNode]}
        rules:
          - MATCH,LoopGroup
        """
        let profile = ActiveProfile(
            name: "Blackhole",
            yaml: yaml,
            importedAt: Date(timeIntervalSince1970: 1_775_000_000)
        )
        let managed = ManagedProfile(profile: profile)
        tunnel.installReviewProfileCatalog(ProfileCatalog(activeProfileID: managed.id, profiles: [managed]))

        let clock = ContinuousClock()
        let start = clock.now
        let task = Task { @MainActor in
            await tunnel.measureReachability(members: ["BlackholeNode"], runToken: tunnel.currentLatencyRunToken)
        }
        try await Task.sleep(for: .milliseconds(30))
        task.cancel()
        await task.value
        let elapsed = clock.now - start

        try expect(
            elapsed < .milliseconds(500),
            "Cancelled TCP reachability probe waited \(elapsed) instead of cancelling immediately"
        )
    }

    private static func testPreCancelledProbeDirectMemberAndTCPLatencyDoNotTrap() async throws {
        let server = try LoopbackTCPServer()
        defer { server.stop() }
        let endpoints: [String: ProfileUpstreamEndpoint] = [
            "Echo": ProfileUpstreamEndpoint(host: "127.0.0.1", port: server.port),
        ]

        // Pre-cancelled Task executing `probeTCPLatency` and `probeDirectMemberLatency` must not trap
        // libdispatch by cancelling a suspended DispatchSourceTimer prior to `resume()`.
        for _ in 0..<5 {
            let directTask = Task {
                await TunnelManager.probeDirectMemberLatency(
                    member: "Echo",
                    endpoints: endpoints,
                    excludingVirtualInterfaces: false
                )
            }
            directTask.cancel()
            let directResult = await directTask.value
            try expect(directResult == .timedOut, "Expected .timedOut for cancelled probeDirectMemberLatency, got \(directResult)")

            let tcpTask = Task {
                await TunnelManager.probeTCPLatency(
                    host: "127.0.0.1",
                    port: server.port,
                    timeoutMilliseconds: 2_000,
                    excludingVirtualInterfaces: false
                )
            }
            tcpTask.cancel()
            let tcpResult = await tcpTask.value
            try expect(tcpResult == nil, "Expected nil for cancelled probeTCPLatency, got \(String(describing: tcpResult))")
        }
    }

    @MainActor
    private static func testPerformAutomaticReconnectDoesNotRearmWhenTransitionedToFailed() async throws {
        // Test the case where `state == .recovering`, `performAutomaticReconnect` calls `setEnabled(true, isAutomaticReconnect: true)`
        // and the tunnel enters `.failed(...)`: `performAutomaticReconnect` MUST NOT call `scheduleAutomaticReconnect()` over `.failed`.
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "recovering")
        defer { cleanupDefaults(suiteName) }

        tunnel.hasAcceptedPrivacyDisclosure = true
        tunnel.userIntendsToConnect = true
        tunnel.isNetworkSetupRequired = true
        tunnel.automaticReconnectAttempt = 0
        tunnel.automaticReconnectTask = nil

        // Simulate state becoming .failed inside connect attempt
        tunnel.state = .failed("Configuration invalid")
        await tunnel.performAutomaticReconnect(attempt: 0)

        try expect(
            tunnel.automaticReconnectTask == nil && tunnel.automaticReconnectAttempt == 0,
            "performAutomaticReconnect re-armed automatic reconnect even though state == .failed"
        )
    }

    @MainActor
    private static func testSetEnabledFalseWithNilManagerDoesNotTouchNEVPNManager() async throws {
        // Construct non-review TunnelManager without triggering `prepare()` or real OS VPN state
        let (tunnel, defaults, suiteName) = makeTestTunnel(reviewState: nil)
        defer {
            LANProxyServerController.shared.stop()
            cleanupDefaults(suiteName)
        }

        PrivacyConsentStore(defaults: defaults).acceptCurrentDisclosure()
        tunnel.hasAcceptedPrivacyDisclosure = true
        tunnel.state = .connecting
        tunnel.userIntendsToConnect = true
        try expect(tunnel.manager == nil, "Expected test tunnel manager to start nil")

        await tunnel.setEnabled(false)

        try expect(tunnel.manager == nil, "setEnabled(false) unexpectedly loaded/created a NEVPNManager when manager was nil")
        try expect(tunnel.state == .disconnected, "setEnabled(false) with nil manager left state at \(tunnel.state) instead of .disconnected")
        try expect(!tunnel.userIntendsToConnect, "setEnabled(false) did not clear userIntendsToConnect")
    }

    @MainActor
    private static func testCreateAndRebuildMergedProfileEnforceUpdatingGuard() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connecting")
        defer { cleanupDefaults(suiteName) }

        let p1 = tunnel.profiles[0].id
        let p2 = tunnel.profiles[1].id
        let spec = MergedProfileSpec(sourceProfileIDs: [p1, p2])
        let createdWhileConnecting = await tunnel.createMergedProfile(name: "TestMerged", spec: spec)
        try expect(!createdWhileConnecting, "createMergedProfile must fail while state == .connecting")

        tunnel.state = .disconnected
        tunnel.clearProfileMessage()
        tunnel.isUpdatingProfiles = true
        let createdWhileUpdating = await tunnel.createMergedProfile(name: "TestMerged2", spec: spec)
        try expect(!createdWhileUpdating, "createMergedProfile must return false when isUpdatingProfiles == true")
        try expect(
            tunnel.profileMessage == nil,
            "createMergedProfile bypassed !isUpdatingProfiles guard and executed body (message=\(String(describing: tunnel.profileMessage)))"
        )

        let rebuiltWhileUpdating = await tunnel.rebuildMergedProfile(id: p1)
        try expect(!rebuiltWhileUpdating, "rebuildMergedProfile must return false when isUpdatingProfiles == true")
    }

    @MainActor
    private static func testLANProxyLoopbackAndSelfPortSecurityRules() async throws {
        let selfPorts: Set<Int> = [7_890, 7_891]
        let localIPs: Set<String> = ["192.168.1.25", "127.0.0.1", "::1"]

        // Self-listening port loop must ALWAYS be rejected (even for loopback client)
        try expect(
            LANProxySession.shouldRejectOutboundTarget(
                host: "127.0.0.1", port: 7_890, clientIsLoopback: true, selfPorts: selfPorts, localAddresses: localIPs
            ),
            "Failed to reject self-listening loopback HTTP port loop"
        )
        try expect(
            LANProxySession.shouldRejectOutboundTarget(
                host: "192.168.1.25", port: 7_891, clientIsLoopback: false, selfPorts: selfPorts, localAddresses: localIPs
            ),
            "Failed to reject self-listening LAN SOCKS port loop"
        )

        // External LAN client MUST NOT access host's loopback services
        for host in ["127.0.0.1", "127.0.1.5", "::1", "[::1]", "[::ffff:127.0.0.1]", "0.0.0.0", "localhost", "app.localhost."] {
            try expect(
                LANProxySession.shouldRejectOutboundTarget(
                    host: host, port: 6_379, clientIsLoopback: false, selfPorts: selfPorts, localAddresses: localIPs
                ),
                "Failed to block non-loopback client accessing loopback host \(host)"
            )
        }

        // Loopback client accessing non-self loopback service MUST remain allowed (`Tests/AllowLAN/run.sh`)
        try expect(
            !LANProxySession.shouldRejectOutboundTarget(
                host: "127.0.0.1", port: 8_888, clientIsLoopback: true, selfPorts: selfPorts, localAddresses: localIPs
            ),
            "Blocked legitimate loopback client -> local service test traffic"
        )

        // External LAN client accessing external internet IP MUST remain allowed
        try expect(
            !LANProxySession.shouldRejectOutboundTarget(
                host: "93.184.216.34", port: 443, clientIsLoopback: false, selfPorts: selfPorts, localAddresses: localIPs
            ),
            "Wrongly blocked normal outbound target from LAN client"
        )
    }

    @MainActor
    private static func testLANProxyRejectsSelfListeningPortLoopLiveAndAllowsLocalTarget() async throws {
        let localEcho = try LoopbackTCPServer(sendGreeting: "HELLO\n")
        defer { localEcho.stop() }

        let controller = LANProxyServerController.shared
        let httpPort = 27_890
        let socksPort = 27_891
        let settings = LocalProxySettings(
            isEnabled: true,
            httpPort: httpPort,
            socksPort: socksPort,
            allowLAN: false,
            setAsSystemProxy: false,
            systemProxyBypassDomains: []
        )
        controller.updateConfiguration(settings: settings, allowStandaloneLoopback: true)
        defer { controller.stop() }

        try await waitForPortListening(httpPort)

        // 1. Self-listening port loop must be actively accepted & closed (EOF ""), not 200 or timeout
        let selfLoopResponse = await Task.detached {
            sendRawTCPRequest(
                port: httpPort,
                payload: "CONNECT 127.0.0.1:\(httpPort) HTTP/1.1\r\nHost: 127.0.0.1:\(httpPort)\r\n\r\n"
            )
        }.value
        try expect(
            selfLoopResponse == "",
            "Expected EOF rejection for self-listening port \(httpPort), got \(String(describing: selfLoopResponse))"
        )

        // 2. Non-self local echo port from loopback client must still succeed
        let okResponse = await Task.detached {
            sendRawTCPRequest(
                port: httpPort,
                payload: "CONNECT 127.0.0.1:\(localEcho.port) HTTP/1.1\r\nHost: 127.0.0.1:\(localEcho.port)\r\n\r\n"
            )
        }.value
        try expect(
            (okResponse ?? "").contains("200 Connection Established"),
            "LANProxyServer failed to connect loopback client to local test port \(localEcho.port); got \(String(describing: okResponse))"
        )
    }

    @MainActor
    private static func testRefreshAllExternalProvidersKeepsGlobalCustomRulesIsolated() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFuncExternalProviders-\(UUID().uuidString)", isDirectory: true)
        let ruleStorage = tempDir.appendingPathComponent("RuleProviders", isDirectory: true)
        let proxyStorage = tempDir.appendingPathComponent("ProxyProviders", isDirectory: true)
        try FileManager.default.createDirectory(at: ruleStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proxyStorage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let ruleEngine = RuleProviderEngine(
            directoryURL: ruleStorage,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (Data("+.internal.example.com\n".utf8), response)
            }
        )
        let proxyEngine = ProxyProviderEngine(
            directoryURL: proxyStorage,
            stagingBaseURL: tempDir,
            httpFetcher: { requestURL in
                let response = HTTPURLResponse(url: requestURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
                let yaml = "proxies:\n  - {name: PoolNode, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}\n"
                return (Data(yaml.utf8), response)
            }
        )

        let (tunnel, _, suiteName) = makeTestTunnel(
            reviewState: "disconnected",
            ruleProviderEngine: ruleEngine,
            proxyProviderEngine: proxyEngine
        )
        defer { cleanupDefaults(suiteName) }

        let profileWithRuleProvider = ActiveProfile(
            name: "CorpProfile",
            yaml: """
            mixed-port: 7890
            proxies:
              - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
            proxy-providers:
              corp-pool:
                type: http
                url: https://sub.example.com/corp-pool.yaml
                interval: 3600
            proxy-groups:
              - {name: PROXY, type: select, proxies: [HK-1, DIRECT], use: [corp-pool]}
            rule-providers:
              internal:
                type: http
                behavior: domain
                format: text
                url: https://rules.example.com/internal.txt
                interval: 86400
            rules:
              - RULE-SET,internal,DIRECT
              - MATCH,PROXY
            """
        )
        tunnel.activeProfile = profileWithRuleProvider

        let refreshed = await tunnel.refreshAllExternalProviders()
        try expect(refreshed.rules.count == 1 && refreshed.rules.first?.name == "internal", "Expected staged rule provider 'internal' in refreshAllExternalProviders return value")
        try expect(refreshed.proxies.count == 1 && refreshed.proxies.first?.name == "corp-pool", "Expected staged proxy provider 'corp-pool'")
        try expect(
            tunnel.customRuleProviders.isEmpty,
            "Subscription rule-providers polluted tunnel.customRuleProviders: \(tunnel.customRuleProviders)"
        )
        try expect(
            tunnel.compiledRemoteRulesCache.isEmpty,
            "Subscription rule-providers polluted tunnel.compiledRemoteRulesCache: \(tunnel.compiledRemoteRulesCache)"
        )

        // Switching to a second profile without providers must scope loadAllExternalProviders() to active profile
        tunnel.activeProfile = ActiveProfile(
            name: "CleanProfile",
            yaml: """
            proxies:
              - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
            proxy-groups:
              - {name: PROXY, type: select, proxies: [HK-1, DIRECT]}
            rules:
              - MATCH,DIRECT
            """
        )
        let loadedClean = await tunnel.loadAllExternalProviders()
        try expect(
            loadedClean.rules.isEmpty && loadedClean.proxies.isEmpty,
            "loadAllExternalProviders leaked providers from previous profile: \(loadedClean)"
        )
    }

    @MainActor
    private static func testUpgradeWithLegacyPollutedProvidersJSONInCatalogCleansGlobalRulesAndPreservesUserProviders() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFuncLegacyUpgrade-\(UUID().uuidString)", isDirectory: true)
        let ruleStorage = tempDir.appendingPathComponent("RuleProviders", isDirectory: true)
        let proxyStorage = tempDir.appendingPathComponent("ProxyProviders", isDirectory: true)
        try FileManager.default.createDirectory(at: ruleStorage, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: proxyStorage, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let pollutedID = UUID()
        let userCustomID = UUID()
        let legacyProviders = [
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
                id: userCustomID,
                name: "User-Custom-Rules",
                url: URL(string: "https://rules.example.com/user.txt")!,
                behavior: .domain,
                format: .text,
                defaultTarget: "REJECT",
                isEnabled: true,
                intervalSeconds: 86_400,
                lastUpdatedAt: Date(),
                ruleCount: 1
            ),
        ]
        try JSONEncoder().encode(legacyProviders)
            .write(to: ruleStorage.appendingPathComponent("providers.json"), options: [.atomic])
        try Data("+.internal.example.com\n".utf8)
            .write(to: ruleStorage.appendingPathComponent("\(pollutedID.uuidString).dat"), options: [.atomic])
        try Data("+.custom.example.com\n".utf8)
            .write(to: ruleStorage.appendingPathComponent("\(userCustomID.uuidString).dat"), options: [.atomic])

        let ruleEngine = RuleProviderEngine(directoryURL: ruleStorage, stagingBaseURL: tempDir)
        let proxyEngine = ProxyProviderEngine(directoryURL: proxyStorage, stagingBaseURL: tempDir)
        let (tunnel, _, suiteName) = makeTestTunnel(
            reviewState: "disconnected",
            ruleProviderEngine: ruleEngine,
            proxyProviderEngine: proxyEngine
        )
        defer { cleanupDefaults(suiteName) }

        let profile1 = ActiveProfile(
            name: "CorpProfile",
            yaml: """
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
                interval: 86400
            rules:
              - RULE-SET,internal,DIRECT
              - MATCH,PROXY
            """
        )
        let profile2 = ActiveProfile(
            name: "CleanProfile",
            yaml: """
            mixed-port: 7890
            proxies:
              - {name: HK-1, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: pass}
            proxy-groups:
              - {name: PROXY, type: select, proxies: [HK-1, DIRECT]}
            rules:
              - MATCH,DIRECT
            """
        )
        tunnel.profiles = [ManagedProfile(profile: profile1), ManagedProfile(profile: profile2)]
        tunnel.activeProfile = profile2

        await tunnel.reloadCustomRuleProvidersFromEngine()

        try expect(
            tunnel.customRuleProviders.map(\.id) == [userCustomID],
            "Expected legacy polluted provider pruned while preserving User-Custom-Rules, got: \(tunnel.customRuleProviders)"
        )
        try expect(
            !tunnel.compiledRemoteRulesCache.contains("DOMAIN-SUFFIX,internal.example.com,PROXY"),
            "Legacy polluted rule leaked into compiledRemoteRulesCache: \(tunnel.compiledRemoteRulesCache)"
        )
        try expect(
            tunnel.compiledRemoteRulesCache.contains("DOMAIN-SUFFIX,custom.example.com,REJECT"),
            "Genuine User-Custom-Rules was dropped from compiledRemoteRulesCache: \(tunnel.compiledRemoteRulesCache)"
        )

        tunnel.activeProfile = profile1
        let optimizedProfile1 = DomesticRoutingOptimizer.optimizedProfile(
            for: profile1.yaml,
            remoteRules: tunnel.compiledRemoteRulesCache,
            enableDomesticDirect: false,
            providerBaseDirectoryURL: tempDir
        )
        try expect(
            !optimizedProfile1.contains("DOMAIN-SUFFIX,internal.example.com,PROXY")
                && optimizedProfile1.contains("RULE-SET,internal,DIRECT"),
            "Upgraded profile1 still shadows RULE-SET,internal,DIRECT:\n\(optimizedProfile1)"
        )
    }
}

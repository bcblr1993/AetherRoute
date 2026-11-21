import AetherRouteKit
import Combine
import Darwin
import Foundation
import Network
import NetworkExtension
import SwiftUI

// MARK: - Standalone Compilation Shims (UI-owned types excluded from standalone target)

enum AetherVisual {
    static let portalLight = Color.blue
    static let portalMid = Color.blue
    static let sMicro: CGFloat = 2
    static let s1: CGFloat = 4
    static let sCompact: CGFloat = 6
    static let s2: CGFloat = 8
    static let sRow: CGFloat = 10
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let badgeRadius: CGFloat = 4
    static let controlRadius: CGFloat = 6
    static let cardRadius: CGFloat = 10
    static let panelFill = Color(nsColor: .quaternarySystemFill)
    static let cardFill = Color(nsColor: .tertiarySystemFill)
    static let cardStroke = Color(nsColor: .separatorColor)
    static func tintFill(_ tint: Color) -> Color { tint.opacity(0.14) }
    static func tintWash(_ tint: Color) -> Color { tint.opacity(0.10) }
}

struct AetherReadableTint: ShapeStyle {
    let color: Color
    func resolve(in environment: EnvironmentValues) -> Color { color }
}

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
            ("testSystemProxyUnmountedInRecoveringDisconnectedAndPortConflict", testSystemProxyUnmountedInRecoveringDisconnectedAndPortConflict),
            ("testGlobalOverrideDialerCycleAndBypassDomainsAcrossAllPaths", testGlobalOverrideDialerCycleAndBypassDomainsAcrossAllPaths),
            ("testActivateProfilePreflightProtectsActiveConnectionAndCopyTerminalCommand", testActivateProfilePreflightProtectsActiveConnectionAndCopyTerminalCommand),
            ("testLiveReloadStagesRoutingResourcesBeforeReloadActiveProfile", testLiveReloadStagesRoutingResourcesBeforeReloadActiveProfile),
            ("testRouteDataPlaneTCPProbeUsesPureTCPHTTP11AndTimesOutPromptly", testRouteDataPlaneTCPProbeUsesPureTCPHTTP11AndTimesOutPromptly),
            ("testTunnelManagerQuietnessSuppressesNoopObjectWillChangeBroadcasts", testTunnelManagerQuietnessSuppressesNoopObjectWillChangeBroadcasts),
            ("testLoadDiagnosticLogLinesFallsBackToCachedExtensionLogWhenDisconnected", testLoadDiagnosticLogLinesFallsBackToCachedExtensionLogWhenDisconnected),
            ("testProfileSubscriptionDirectBypassTimeoutEnablesFastFailover", testProfileSubscriptionDirectBypassTimeoutEnablesFastFailover),
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

        // 1. Unauthenticated external URL (missing token) must stage pending confirmation rather than mutating immediately
        let untrustedURL = URL(string: "aetherroute://switch-profile?name=\(encodedName)")!
        tunnel.handleIncomingExternalURL(untrustedURL)
        try await Task.sleep(for: .milliseconds(30))
        try expect(
            tunnel.activeProfileID == initialProfileID,
            "Tokenless external control URL mutated activeProfileID without user confirmation"
        )
        try expect(
            tunnel.pendingControlURLRequest != nil,
            "Expected pendingControlURLRequest for tokenless external control URL"
        )
        tunnel.cancelPendingControlURLAction()
        try expect(tunnel.pendingControlURLRequest == nil, "Expected cancelPendingControlURLAction to clear pending request")

        // 2. Wrong token must be rejected outright without staging confirmation
        let badTokenURL = URL(string: "aetherroute://switch-profile?name=\(encodedName)&token=forged-token")!
        tunnel.handleIncomingExternalURL(badTokenURL)
        try expect(tunnel.pendingControlURLRequest == nil, "Forged token must not stage confirmation")
        try expect(tunnel.externalSubscriptionLinkError != nil, "Forged token must report an error")

        // 3. Valid secret token executes immediately while connected
        let validURL = URL(string: "aetherroute://switch-profile?name=\(encodedName)&token=\(tunnel.controlURLSchemeToken)")!
        tunnel.handleIncomingExternalURL(validURL)
        try await Task.sleep(for: .milliseconds(60))

        try expect(
            tunnel.activeProfileID != initialProfileID && tunnel.activeProfileID == target.id,
            "Authenticated handleIncomingExternalURL switch-profile failed while connected (activeProfileID=\(String(describing: tunnel.activeProfileID)))"
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
        controller.updateConfiguration(
            settings: settings,
            isTunnelConnected: true,
            allowStandaloneLoopback: true
        )
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

    @MainActor
    private static func testSystemProxyUnmountedInRecoveringDisconnectedAndPortConflict() async throws {
        let mock = MockNetworkSetupExecutor()
        // Non-UIReview TunnelManager so real SystemProxy state transitions run against MockNetworkSetupExecutor
        let suiteName = "com.aetherroute.macfunc.sysproxy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { cleanupDefaults(suiteName) }
        PrivacyConsentStore(defaults: defaults).acceptCurrentDisclosure()

        let configurator = SystemProxyConfigurator(executor: mock, defaults: defaults)
        let tunnel = TunnelManager(
            environment: [:],
            privacyConsentStore: PrivacyConsentStore(defaults: defaults),
            routingModePreferenceStore: RoutingModePreferenceStore(defaults: defaults),
            connectionIntentStore: ConnectionIntentStore(defaults: defaults),
            systemProxyConfigurator: configurator,
            userDefaults: defaults
        )
        defer { LANProxyServerController.shared.stop() }

        // 1. While disconnected, enabling System Proxy must NOT call `-setwebproxy` or mark isSystemProxyActive = true
        mock.invocations.removeAll()
        tunnel.setSystemProxyEnabled(true)
        try await Task.sleep(for: .milliseconds(40))
        try expect(!tunnel.isSystemProxyActive, "isSystemProxyActive became true while disconnected")
        let setCallsWhileDisconnected = mock.recordedInvocations.filter { $0.args.first == "-setwebproxy" }
        try expect(
            setCallsWhileDisconnected.isEmpty,
            "System Proxy was mounted while disconnected: \(setCallsWhileDisconnected)"
        )

        // 2. When state becomes .connected (TUN mode), System Proxy mounts; entering .recovering MUST immediately unmount it!
        tunnel.networkEngineMode = .tun
        tunnel.localProxySettings = LocalProxySettings(
            isEnabled: true,
            httpPort: 28_890,
            socksPort: 28_891,
            allowLAN: false,
            setAsSystemProxy: true
        )
        tunnel.state = .connected
        try await Task.sleep(for: .milliseconds(60))
        try expect(tunnel.isSystemProxyActive, "Expected System Proxy to activate upon .connected")

        tunnel.state = .recovering
        try await Task.sleep(for: .milliseconds(60))
        try expect(!tunnel.isSystemProxyActive, "System Proxy remained active during .recovering blackhole window")

        // 3. Port conflict (EADDRINUSE) on LANProxyServerController must roll back System Proxy and surface warning
        let blocker = try LoopbackTCPServer()
        defer { blocker.stop() }
        let conflictPort = Int(blocker.port)
        tunnel.networkEngineMode = .transparent
        tunnel.localProxySettings = LocalProxySettings(
            isEnabled: true,
            httpPort: conflictPort,
            socksPort: conflictPort,
            allowLAN: false,
            setAsSystemProxy: true
        )
        tunnel.state = .connected
        try await Task.sleep(for: .milliseconds(120))
        try expect(!tunnel.isSystemProxyActive, "System Proxy remained active despite EADDRINUSE port conflict")
        try expect(
            (tunnel.localProxySettingsMessage ?? "").contains("\(conflictPort)"),
            "Expected port conflict warning mentioning port \(conflictPort), got \(String(describing: tunnel.localProxySettingsMessage))"
        )

        // 4. AllowLAN must NOT listen on 0.0.0.0 while disconnected/connecting/recovering; only while .connected!
        tunnel.state = .disconnected
        tunnel.networkEngineMode = .tun
        tunnel.updateLocalProxySettings(allowWhileConnected: true) {
            $0.isEnabled = true
            $0.httpPort = 28_920
            $0.socksPort = 28_921
            $0.allowLAN = true
            $0.setAsSystemProxy = false
        }
        try expect(
            !LANProxyServerController.shared.isRunning,
            "AllowLAN started listening on 0.0.0.0 while tunnel was .disconnected (bare leak)"
        )
        try expect(
            !(tunnel.localProxySettingsMessage ?? "").isEmpty
                && tunnel.localProxySettingsMessage != AppLocalization.string("LAN shared proxy is active."),
            "AllowLAN message claimed active while tunnel was disconnected: \(String(describing: tunnel.localProxySettingsMessage))"
        )

        tunnel.state = .connected
        try await Task.sleep(for: .milliseconds(60))
        try expect(
            LANProxyServerController.shared.isRunning && !LANProxyServerController.shared.isLoopbackOnly,
            "Expected AllowLAN 0.0.0.0 listener to start upon .connected"
        )

        tunnel.state = .recovering
        try await Task.sleep(for: .milliseconds(40))
        try expect(
            !LANProxyServerController.shared.isRunning,
            "AllowLAN 0.0.0.0 listener remained active during .recovering bare-leak window"
        )

        tunnel.state = .connected
        try await Task.sleep(for: .milliseconds(60))
        try expect(
            LANProxyServerController.shared.isRunning,
            "Expected AllowLAN 0.0.0.0 listener to resume after recovering -> .connected"
        )

        tunnel.state = .disconnected
        try await Task.sleep(for: .milliseconds(40))
        try expect(
            !LANProxyServerController.shared.isRunning,
            "AllowLAN 0.0.0.0 listener remained active after .disconnected"
        )
    }

    @MainActor
    private static func testGlobalOverrideDialerCycleAndBypassDomainsAcrossAllPaths() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "disconnected")
        defer { cleanupDefaults(suiteName) }

        // Raw subscription YAML with NO per-profile overrides, containing a 2-node dialer-proxy cycle!
        let cyclicYAML = """
        proxies:
          - {name: HopA, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: HopB}
          - {name: HopB, type: ss, server: 5.6.7.8, port: 443, cipher: aes-128-gcm, password: p, dialer-proxy: HopA}
          - {name: CleanHK, type: ss, server: 9.9.9.9, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HopA, HopB, CleanHK]}
        rules:
          - MATCH,PROXY
        """
        let rawProfile = ActiveProfile(name: "CyclicSub", yaml: cyclicYAML, importedAt: .now, overrides: nil)
        let managed = ManagedProfile(profile: rawProfile)

        let globalOverride = ProfileOverride(
            groups: [CustomProxyGroup(name: "GlobalHK", includeKeywords: ["HK"], groupKind: .select, parentGroup: "PROXY")],
            customHosts: [CustomHostMapping(domain: "intranet.corp", ip: "10.20.30.40")]
        )
        tunnel.setGlobalProfileOverrideForTesting(globalOverride)
        tunnel.bypassPolicy = try BypassPolicy(rules: [BypassRule.parse("*.bypass-only.example")])
        tunnel.installReviewProfileCatalog(ProfileCatalog(activeProfileID: managed.id, profiles: [managed]))
        tunnel.refreshActiveProfileSummary()

        let compiled = tunnel.effectiveProfileYAML(for: rawProfile)
        try expect(
            !compiled.contains("dialer-proxy: HopB") || !compiled.contains("dialer-proxy: HopA"),
            "Original subscription dialer-proxy cycle was NOT stripped when per-profile overrides == nil:\n\(compiled)"
        )
        try expect(
            compiled.contains("GlobalHK"),
            "Global override group GlobalHK missing from effectiveProfileYAML:\n\(compiled)"
        )
        try expect(
            tunnel.activeProfileSummary?.proxyGroups.contains(where: { $0.name == "GlobalHK" }) == true,
            "Global override group GlobalHK missing from activeProfileSummary"
        )

        // Production projection must also apply globalOverride + cycle stripping
        let projection = ProfileCatalogProjectionBuilder.production(
            ProfileCatalog(activeProfileID: managed.id, profiles: [managed]),
            globalOverride: globalOverride,
            bypassPolicy: tunnel.bypassPolicy,
            enableDomesticDirect: false
        )
        try expect(
            projection.summary?.proxyGroups.contains(where: { $0.name == "GlobalHK" }) == true,
            "Global override group GlobalHK missing from ProfileCatalogProjectionBuilder.production"
        )

        // Bypass domain must route DIRECT even in TUN mode & traceRoute, and global customHosts must apply in traceRoute
        let bypassTrace = await tunnel.traceRoute(RouteTraceRequest(host: "api.bypass-only.example", port: 443, network: .tcp))
        try expect(
            bypassTrace.targetOutbound == "DIRECT",
            "Expected bypassPolicy domain *.bypass-only.example to route DIRECT, got \(bypassTrace.targetOutbound)"
        )
        let hostTrace = await tunnel.traceRoute(RouteTraceRequest(host: "intranet.corp", port: 443, network: .tcp))
        try expect(
            hostTrace.resolvedHostAlias == "10.20.30.40" || hostTrace.dnsAddresses.contains("10.20.30.40"),
            "Expected globalOverride customHosts intranet.corp -> 10.20.30.40 in traceRoute, got alias=\(String(describing: hostTrace.resolvedHostAlias))"
        )
    }

    @MainActor
    private static func testActivateProfilePreflightProtectsActiveConnectionAndCopyTerminalCommand() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: "connected")
        defer { cleanupDefaults(suiteName) }

        let initialID = tunnel.activeProfileID
        // Non-existent profile UUID must fail preflight without disconnecting active tunnel
        await tunnel.activateProfile(id: UUID())
        try expect(tunnel.state == .connected, "activateProfile(unknownID) tore down healthy connected tunnel")
        try expect(tunnel.activeProfileID == initialID, "activateProfile(unknownID) mutated activeProfileID")
        try expect(tunnel.profileMessageIsError, "Expected error message on failed preflight")

        // Terminal proxy copy command must be enabled in Transparent Proxy mode when local proxy / System Proxy is enabled
        tunnel.networkEngineMode = .transparent
        tunnel.localProxySettings = LocalProxySettings(isEnabled: true, httpPort: 7890, socksPort: 7891, allowLAN: false)
        try expect(
            tunnel.canCopyTerminalProxyCommand,
            "canCopyTerminalProxyCommand was false in transparent mode despite localProxySettings.isEnabled == true"
        )
    }

    @MainActor
    private static func testLiveReloadStagesRoutingResourcesBeforeReloadActiveProfile() async throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("MacFuncReloadStage-\(UUID().uuidString)", isDirectory: true)
        let supportDir = tempRoot.appendingPathComponent("Support", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let countryMMDB = Data(repeating: 0x42, count: 2_048)
            + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
            + Data(repeating: 0x21, count: 64)
        let asnMMDB = Data(repeating: 0x45, count: 2_048)
            + Data([0xAB, 0xCD, 0xEF]) + Data("MaxMind.com".utf8)
            + Data(repeating: 0x22, count: 64)
        let geoSiteDat = Data([
            0x0A, 0x07, 0x0A, 0x05, 0x61, 0x70, 0x70, 0x6C, 0x65, // "apple"
            0x0A, 0x04, 0x0A, 0x02, 0x63, 0x6E,                   // "cn"
            0x0A, 0x09, 0x0A, 0x07, 0x70, 0x72, 0x69, 0x76, 0x61, 0x74, 0x65 // "private"
        ])
        let store = RoutingResourceStore(applicationSupportDirectory: supportDir)
        _ = try store.installUserProvided(data: countryMMDB, kind: .countryMMDB)
        _ = try store.installUserProvided(data: asnMMDB, kind: .asnMMDB)
        _ = try store.installUserProvided(data: geoSiteDat, kind: .geoSite)

        let suiteName = "com.aetherroute.macfunc.reloadstage.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { cleanupDefaults(suiteName) }
        PrivacyConsentStore(defaults: defaults).acceptCurrentDisclosure()

        let tunnel = TunnelManager(
            environment: ["AETHERROUTE_UI_REVIEW_STATE": "connected"],
            privacyConsentStore: PrivacyConsentStore(defaults: defaults),
            routingModePreferenceStore: RoutingModePreferenceStore(defaults: defaults),
            connectionIntentStore: ConnectionIntentStore(defaults: defaults),
            systemProxyConfigurator: SystemProxyConfigurator(executor: MockNetworkSetupExecutor(), defaults: defaults),
            userDefaults: defaults,
            routingResourceStoreFactory: {
                RoutingResourceStore(applicationSupportDirectory: supportDir)
            }
        )

        let yamlWithGeoAndASN = """
        proxies:
          - {name: HK-01, type: ss, server: 1.2.3.4, port: 443, cipher: aes-128-gcm, password: p}
        proxy-groups:
          - {name: PROXY, type: select, proxies: [HK-01, DIRECT]}
        rules:
          - GEOIP,CN,DIRECT,no-resolve
          - IP-ASN,13335,PROXY,no-resolve
          - MATCH,PROXY
        """
        let profile = ActiveProfile(name: "ReloadStageTest", yaml: yamlWithGeoAndASN, importedAt: .now)
        let managed = ManagedProfile(profile: profile)
        tunnel.installReviewProfileCatalog(ProfileCatalog(activeProfileID: managed.id, profiles: [managed]))

        let prepared = try await tunnel.prepareReloadProfilePayload(
            for: profile,
            requestedMode: .rule
        )
        try expect(
            prepared.routingResources[.countryMMDB] == countryMMDB,
            "prepareReloadProfilePayload dropped Country.mmdb from routingResources"
        )
        try expect(
            prepared.routingResources[.asnMMDB] == asnMMDB,
            "prepareReloadProfilePayload dropped ASN.mmdb from routingResources"
        )

        let recordedState = LockedBox<(
            events: [String],
            installedDigests: [RoutingResourceKind: String],
            stagedPayloads: [RoutingResourceKind: Data]
        )>(([], [:], [:]))

        let client = ProxySelectionProviderClient { rawRequest in
            let request = try ProxySelectionProviderMessageCodec.decodeRequest(rawRequest)
            switch request {
            case .installedRoutingResourceDigests:
                let digests = recordedState.withLock { state -> [RoutingResourceKind: String] in
                    state.events.append("digests")
                    return state.installedDigests
                }
                return try ProxySelectionProviderMessageCodec.encode(
                    response: .routingResourceDigests(digests)
                )
            case let .stageRoutingResourceChunk(chunk):
                recordedState.withLock { state in
                    state.events.append("stage:\(chunk.kind.rawValue):\(chunk.chunkIndex + 1)/\(chunk.totalChunks)")
                    var buffer = state.stagedPayloads[chunk.kind] ?? Data()
                    buffer.append(chunk.data)
                    state.stagedPayloads[chunk.kind] = buffer
                    if chunk.chunkIndex + 1 == chunk.totalChunks {
                        state.installedDigests[chunk.kind] = chunk.expectedSHA256
                    }
                }
                return try ProxySelectionProviderMessageCodec.encode(
                    response: .routingResourceChunkStaged
                )
            case .reloadProfile:
                recordedState.withLock { state in
                    state.events.append("reload")
                }
                return try ProxySelectionProviderMessageCodec.encode(
                    response: .profileReloaded
                )
            default:
                return try ProxySelectionProviderMessageCodec.encode(
                    response: .failure(.invalidRequest)
                )
            }
        }

        // First hot reload: must query digests, stage BOTH Country.mmdb & ASN.mmdb BEFORE .reloadProfile!
        try await tunnel.reloadActiveProfileStagingResources(prepared, via: client)
        let firstSnapshot = recordedState.withLock { $0 }
        try expect(
            firstSnapshot.events.first == "digests" && firstSnapshot.events.last == "reload",
            "Expected digests -> stage chunks -> reload order, got \(firstSnapshot.events)"
        )
        try expect(
            firstSnapshot.stagedPayloads[.countryMMDB] == countryMMDB
                && firstSnapshot.stagedPayloads[.asnMMDB] == asnMMDB,
            "Expected Country.mmdb and ASN.mmdb bytes staged before reload"
        )

        // Second hot reload with identical SHA-256 digests: must skip staging chunks and go straight digests -> reload!
        recordedState.withLock { $0.events.removeAll() }
        try await tunnel.reloadActiveProfileStagingResources(prepared, via: client)
        let secondEvents = recordedState.withLock { $0.events }
        try expect(
            secondEvents == ["digests", "reload"],
            "Expected unchanged resources to skip chunk transfer on second reload, got \(secondEvents)"
        )
    }

    @MainActor
    private static func testRouteDataPlaneTCPProbeUsesPureTCPHTTP11AndTimesOutPromptly() async throws {
        // Bind loopback TCP HTTP/1.1 responder that captures raw request headers.
        let listenFD = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw TestFailure(message: "Failed to create probe test socket")
        }
        defer { Darwin.close(listenFD) }
        var reuse: Int32 = 1
        Darwin.setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listenFD, 8) == 0 else {
            throw TestFailure(message: "Failed to bind/listen probe test socket")
        }
        var actualAddr = sockaddr_in()
        var actualLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &actualAddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listenFD, $0, &actualLen)
            }
        }
        let port = Int(UInt16(bigEndian: actualAddr.sin_port))
        let requestTextBox = LockedBox<String>("")

        let serverTask = Task.detached {
            for attempt in 0..<2 {
                var peer = sockaddr_in()
                var peerLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFD = withUnsafeMutablePointer(to: &peer) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        Darwin.accept(listenFD, $0, &peerLen)
                    }
                }
                guard clientFD >= 0 else { break }
                if attempt == 0 {
                    var buf = [UInt8](repeating: 0, count: 2048)
                    let n = Darwin.recv(clientFD, &buf, buf.count, 0)
                    if n > 0 {
                        let req = String(decoding: buf.prefix(n), as: UTF8.self)
                        requestTextBox.withLock { $0 = req }
                    }
                    let response = Array("HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
                    _ = response.withUnsafeBytes { Darwin.send(clientFD, $0.baseAddress, $0.count, 0) }
                    Darwin.close(clientFD)
                } else {
                    // Second connection intentionally hangs silently to verify bounded timeout.
                    try? await Task.sleep(for: .milliseconds(900))
                    Darwin.close(clientFD)
                }
            }
        }
        defer { serverTask.cancel() }

        let probeURL = URL(string: "http://127.0.0.1:\(port)/generate_204?aetherroute=test")!
        let status = try await TunnelManager.RouteDataPlaneTCPProbe.statusCode(url: probeURL, timeout: 2.0)
        try expect(status == 204, "Expected HTTP 204 from TCP probe, got \(status)")
        let rawRequest = requestTextBox.withLock { $0 }
        try expect(
            rawRequest.contains("GET /generate_204?aetherroute=test HTTP/1.1\r\n"),
            "Expected HTTP/1.1 request line, got: \(rawRequest)"
        )
        try expect(
            rawRequest.localizedCaseInsensitiveContains("Connection: close\r\n"),
            "Pure TCP probe must send Connection: close (not keep-alive/HTTP3), got: \(rawRequest)"
        )

        let timeoutStart = ContinuousClock.now
        var timedOut = false
        do {
            _ = try await TunnelManager.RouteDataPlaneTCPProbe.statusCode(url: probeURL, timeout: 0.25)
        } catch {
            timedOut = true
        }
        let timeoutElapsed = timeoutStart.duration(to: .now)
        try expect(timedOut, "Silent socket must trigger timeout error")
        try expect(timeoutElapsed < .seconds(1), "Probe timeout took too long: \(timeoutElapsed)")
    }

    @MainActor
    private static func testTunnelManagerQuietnessSuppressesNoopObjectWillChangeBroadcasts() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel()
        defer { cleanupDefaults(suiteName) }

        var emissions = 0
        let cancellable = tunnel.objectWillChange.sink { _ in
            emissions += 1
        }
        defer { cancellable.cancel() }

        tunnel.setConnectionQuality(.verified)
        try expect(emissions == 1, "Initial transition unknown -> verified should emit once (got \(emissions))")

        tunnel.setConnectionQuality(.verified)
        try expect(emissions == 1, "Repeated .verified must NOT emit objectWillChange or update @Published checkedAt (got \(emissions))")

        tunnel.updateAutomaticRouteRecoveryPresentation()
        try expect(emissions == 1, "No-op updateAutomaticRouteRecoveryPresentation must NOT emit objectWillChange (got \(emissions))")
    }

    @MainActor
    private static func testLoadDiagnosticLogLinesFallsBackToCachedExtensionLogWhenDisconnected() async throws {
        let (tunnel, _, suiteName) = makeTestTunnel(reviewState: nil)
        defer { cleanupDefaults(suiteName) }

        tunnel.cachedExtensionDiagnosticLog = (
            process: "tunnel",
            text: "2026-11-18T10:00:00.000Z L [tunnel] stage=startTunnel success\n"
        )
        let lines = await tunnel.loadDiagnosticLogLines()
        try expect(
            lines.contains(where: { $0.process == "tunnel" && $0.message.contains("stage=startTunnel success") }),
            "Disconnected View Logs must include cached extension diagnostic log lines, got \(lines.count) lines"
        )
    }

    @MainActor
    private static func testProfileSubscriptionDirectBypassTimeoutEnablesFastFailover() async throws {
        try expect(
            ProfileSubscriptionClient.directBypassRequestTimeout <= 8,
            "Direct subscription probe timeout must be <= 8s for fast proxy failover, got \(ProfileSubscriptionClient.directBypassRequestTimeout)"
        )
    }
}

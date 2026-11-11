import Foundation
import XCTest
@testable import AetherRouteKit

final class AppLifecycleAndPagesFixesTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func appSource(_ fileName: String) throws -> String {
        let url = repoRoot
            .appendingPathComponent("Sources/AetherRouteApp")
            .appendingPathComponent(fileName)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func functionBody(named signaturePrefix: String, in source: String) -> String? {
        guard let startRange = source.range(of: signaturePrefix) else {
            return nil
        }
        guard let openBrace = source[startRange.upperBound...].firstIndex(of: "{") else {
            return nil
        }
        var depth = 1
        var index = source.index(after: openBrace)
        while index < source.endIndex, depth > 0 {
            let ch = source[index]
            if ch == "{" {
                depth += 1
            } else if ch == "}" {
                depth -= 1
            }
            if depth > 0 {
                index = source.index(after: index)
            }
        }
        guard depth == 0 else { return nil }
        return String(source[source.index(after: openBrace)..<index])
    }

    // MARK: - Task 1: Connected Subscription Live Reload, Background Loop, Inactive Refresh & Error Persistence

    func testTask1SubscriptionLiveUpdateBackgroundScheduleAndImportedAtPreservation() throws {
        let profilesExt = try appSource("TunnelManager+Profiles.swift")
        let tunnelManager = try appSource("TunnelManager.swift")
        let contentView = try appSource("ContentView.swift")
        let profilesPage = try appSource("ProfilesPageView.swift")

        // 1. Background subscription update loop must be owned by TunnelManager, NOT ContentView's view-scoped .task
        XCTAssertFalse(
            contentView.contains(".task { await tunnel.runSubscriptionUpdateLoop() }"),
            "runSubscriptionUpdateLoop must not live in ContentView's view-scoped .task (which cancels when closing the main window)"
        )
        XCTAssertTrue(
            tunnelManager.contains("subscriptionUpdateSchedule"),
            "TunnelManager must own a persistent background subscriptionUpdateSchedule Task"
        )

        // 2. runSubscriptionUpdateLoop must run in both .disconnected and .connected states (skipping transitional states)
        let loopBody = try XCTUnwrap(
            functionBody(named: "func runSubscriptionUpdateLoop()", in: profilesExt),
            "runSubscriptionUpdateLoop() must exist in TunnelManager+Profiles.swift"
        )
        XCTAssertFalse(
            loopBody.contains("if state == .disconnected {"),
            "runSubscriptionUpdateLoop must not restrict automatic updates solely to .disconnected"
        )
        XCTAssertTrue(
            profilesExt.contains("shouldRunAutomaticSubscriptionCheck") || loopBody.contains(".connected"),
            "Automatic subscription updates must execute when connected as well as disconnected"
        )

        // 3. Manual & automatic subscription refresh must support arbitrary profile IDs while connected and hot-reload active profile
        XCTAssertTrue(
            profilesExt.contains("func refreshSubscription(id: UUID"),
            "TunnelManager+Profiles.swift must support refreshing an individual subscription by UUID"
        )
        XCTAssertTrue(
            profilesExt.contains("func refreshAllSubscriptions()"),
            "TunnelManager+Profiles.swift must support refreshing all subscriptions"
        )
        let refreshByIDBody = try XCTUnwrap(
            functionBody(named: "func refreshSubscription(id: UUID", in: profilesExt)
                ?? functionBody(named: "func refreshSubscription(\n        id: UUID", in: profilesExt)
        )
        XCTAssertFalse(
            refreshByIDBody.contains("guard ensurePrivacyConsent(), canModifyProfiles,"),
            "Subscription refresh must not be blocked by canModifyProfiles (!isEnabled) while connected"
        )
        XCTAssertTrue(
            refreshByIDBody.contains("reloadActiveProfile"),
            "Refreshing the currently active subscription while connected must hot-reload the running tunnel via reloadActiveProfile"
        )
        XCTAssertTrue(
            refreshByIDBody.contains("importedAt: profile.importedAt"),
            "Refreshing an updated subscription must preserve profile.importedAt instead of resetting it to Date.now"
        )

        // Verify ActiveProfile preserves original importedAt date across YAML replacement
        let originalImportDate = Date(timeIntervalSince1970: 1_700_000_000)
        let sub = try ProfileSubscription(
            url: try XCTUnwrap(URL(string: "https://profiles.example/sub.yaml"))
        )
        let updatedProfile = ActiveProfile(
            name: "Test Sub",
            yaml: "proxies:\n  - { name: HK-01, type: trojan, server: hk.example, port: 443, password: test }\n",
            importedAt: originalImportDate,
            subscription: sub
        )
        XCTAssertEqual(updatedProfile.importedAt, originalImportDate)

        // 4. Persistent subscription update error tracking & ProfilesPageView UI affordances
        XCTAssertTrue(
            tunnelManager.contains("subscriptionUpdateErrors"),
            "TunnelManager must persist per-profile subscription update errors so background failures surface on cards"
        )
        XCTAssertTrue(
            profilesPage.contains("profiles-update-all-subscriptions"),
            "ProfilesPageView must expose a top-bar Update All Subscriptions action"
        )
        XCTAssertFalse(
            profilesPage.contains("if isActive && isSubscription {"),
            "ManagedProfileRow must allow updating inactive subscriptions too, not only isActive && isSubscription"
        )
        XCTAssertTrue(
            profilesPage.contains("subscriptionUpdateErrors"),
            "ProfilesPageView must surface persisted subscription update error status on the profile row"
        )
    }

    // MARK: - Task 2: Global / Direct Mode Sync, 5000ms UI Latency Timeout & Unified Delay Preference

    func testTask2GlobalDirectModeConsistencyTimeoutAndUnifiedDelaySetting() throws {
        let tunnelManager = try appSource("TunnelManager.swift")
        let lifecycle = try appSource("TunnelManager+ConnectionLifecycle.swift")
        let customRules = try appSource("TunnelManager+CustomRules.swift")
        let contentView = try appSource("ContentView.swift")
        let connectionsPage = try appSource("ConnectionsPageView.swift")
        let appMain = try appSource("AetherRouteApp.swift")

        // 1. UI latency timeout default raised from 3_000 to 5_000 ms
        XCTAssertTrue(
            tunnelManager.contains("uiLatencyTimeoutMilliseconds: UInt32 = 5_000"),
            "TunnelManager.uiLatencyTimeoutMilliseconds must default to 5_000 ms"
        )

        // 2. Unified delay toggle in Settings › Advanced using exact shared key "aetherroute.latency.unifiedDelayEnabled"
        XCTAssertTrue(
            tunnelManager.contains("\"aetherroute.latency.unifiedDelayEnabled\"")
                || appMain.contains("\"aetherroute.latency.unifiedDelayEnabled\""),
            "Unified delay setting must persist under UserDefaults key \"aetherroute.latency.unifiedDelayEnabled\""
        )
        XCTAssertTrue(
            appMain.contains("unified-delay-toggle"),
            "Settings must expose the unified delay toggle in the Advanced section"
        )

        // 3. GLOBAL selector binding must not depend on 64-member groupsToVerify and must sync on reloadCustomRulesLive()
        let setRoutingBody = try XCTUnwrap(
            functionBody(named: "func setRoutingMode(_ mode: RoutingMode)", in: tunnelManager)
        )
        XCTAssertFalse(
            setRoutingBody.contains("groupsToVerify(summary: summary).first"),
            "setRoutingMode(.global) must not use groupsToVerify (which drops groups > 64 members)"
        )
        XCTAssertFalse(
            setRoutingBody.contains("readinessVerifiedConnectionID == connectionID"),
            "setRoutingMode(.global) must bind GLOBAL even before or independent of readinessVerifiedConnectionID"
        )

        let reloadRulesBody = try XCTUnwrap(
            functionBody(named: "func reloadCustomRulesLive()", in: customRules)
        )
        XCTAssertTrue(
            reloadRulesBody.contains("GLOBAL") || reloadRulesBody.contains("syncGlobalSelector"),
            "reloadCustomRulesLive() must re-sync the GLOBAL selector so it never falls back to DIRECT after live reload"
        )

        let readinessBody = try XCTUnwrap(
            functionBody(named: "func verifyConnectionReadiness(", in: lifecycle)
        )
        XCTAssertTrue(
            readinessBody.contains("GLOBAL") || readinessBody.contains("syncGlobalSelector"),
            "verifyConnectionReadiness must synchronize the GLOBAL selector to the user's global outbound target"
        )

        // 4. Direct & Global outlet presentation across Overview, Connections SessionBar, and MenuBarContent
        XCTAssertTrue(
            contentView.contains(".direct") && contentView.contains(".global"),
            "ContentView (ActiveOutlet / OverviewExitRow / ConnectionHero) must distinguish .direct and .global routing modes"
        )
        XCTAssertFalse(
            connectionsPage.contains("tunnel.proxySelections.values.compactMap(\\.selectedMember).first"),
            "SessionBar.outlet must not pick an arbitrary dictionary value ignoring routingMode"
        )
        XCTAssertTrue(
            appMain.contains("effectiveMenuRoutingMode") || appMain.contains("routingMode == .direct"),
            "MenuBarContent must distinguish .direct (direct outbound) and .global (global exit selector) modes"
        )
    }

    // MARK: - Task 3 & Task 4 Behavioral Helper Execution (TelemetryRateSampler, ConnectionLiveRateTracker, ConnectionTruncationGuard)

    func testTask3AndTask4BehavioralHelpersViaCompiledAppModule() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("aetherroute-app-pages-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let productsDir = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let sdkProcess = Process()
        let sdkPipe = Pipe()
        sdkProcess.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        sdkProcess.arguments = ["--sdk", "macosx", "--show-sdk-path"]
        sdkProcess.standardOutput = sdkPipe
        try sdkProcess.run()
        sdkProcess.waitUntilExit()
        let sdkPath = String(
            data: sdkPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let harnessURL = tempDir.appendingPathComponent("harness.swift")
        let binaryURL = tempDir.appendingPathComponent("harness-bin")
        let connectionTableItemURL = repoRoot.appendingPathComponent("Sources/AetherRouteApp/ConnectionTableItem.swift")

        let harnessCode = """
        import AetherRouteKit
        import Foundation

        @main
        enum BehavioralHarness {
            static func check(_ condition: Bool, _ message: String) throws {
                if !condition {
                    fputs("FAIL: \\(message)\\n", stderr)
                    exit(1)
                }
            }

            static func makeConn(
                host: String,
                up: UInt64,
                down: UInt64,
                startedAt: UInt64 = 1_000
            ) -> ConnectionTelemetry {
                ConnectionTelemetry(
                    transport: .tcp,
                    destination: host,
                    destinationPort: 443,
                    uploadTotal: up,
                    downloadTotal: down,
                    startedAtUnixMilliseconds: startedAt,
                    rule: "MATCH",
                    rulePayload: "",
                    proxyChain: "Proxy -> HK-01"
                )
            }

            static func main() throws {
                // 1. TelemetryRateSampler: eliminates 3-second 2/3 frame drop using monotonic byte deltas
                var sampler = TelemetryRateSampler()
                let t0 = Date(timeIntervalSince1970: 1_000)
                let s0 = NetworkTelemetrySnapshot(
                    uploadBytesPerSecond: 1_200,
                    downloadBytesPerSecond: 8_400,
                    uploadTotal: 10_000,
                    downloadTotal: 50_000,
                    memoryBytes: 1_024,
                    connections: []
                )
                let r0 = sampler.resolve(snapshot: s0, at: t0)
                try check(
                    r0.uploadBytesPerSecond == 1_200 && r0.downloadBytesPerSecond == 8_400,
                    "First sample must fall back to snapshot instantaneous speed"
                )

                // 3 seconds later: 3 MB downloaded across the 3s interval, even if engine 1s blip was 0
                let t1 = t0.addingTimeInterval(3.0)
                let s1 = NetworkTelemetrySnapshot(
                    uploadBytesPerSecond: 0,
                    downloadBytesPerSecond: 0,
                    uploadTotal: 10_000 + 300_000,
                    downloadTotal: 50_000 + 3_000_000,
                    memoryBytes: 1_024,
                    connections: []
                )
                let r1 = sampler.resolve(snapshot: s1, at: t1)
                try check(
                    r1.uploadBytesPerSecond == 100_000 && r1.downloadBytesPerSecond == 1_000_000,
                    "3-second interval must compute exact delta/elapsed (100 KB/s up, 1 MB/s down), got \\(r1.uploadBytesPerSecond), \\(r1.downloadBytesPerSecond)"
                )

                // Tunnel restart / counter reset to lower totals must fall back cleanly without underflow
                let t2 = t1.addingTimeInterval(1.0)
                let sReset = NetworkTelemetrySnapshot(
                    uploadBytesPerSecond: 512,
                    downloadBytesPerSecond: 4_096,
                    uploadTotal: 512,
                    downloadTotal: 4_096,
                    memoryBytes: 1_024,
                    connections: []
                )
                let rReset = sampler.resolve(snapshot: sReset, at: t2)
                try check(
                    rReset.uploadBytesPerSecond == 512 && rReset.downloadBytesPerSecond == 4_096,
                    "Counter reset must fall back to snapshot rate without negative/overflow spike"
                )

                // Abnormal zero/negative elapsed time must fall back cleanly
                let rZeroDt = sampler.resolve(snapshot: sReset, at: t2)
                try check(
                    rZeroDt.uploadBytesPerSecond == 512 && rZeroDt.downloadBytesPerSecond == 4_096,
                    "Zero elapsed seconds must fall back safely"
                )

                // 2. Per-connection live rate tracking
                var connRateTracker = ConnectionLiveRateTracker()
                let items0 = ConnectionTableItem.identify([
                    makeConn(host: "video.example", up: 1_000, down: 10_000),
                    makeConn(host: "chat.example", up: 500, down: 500),
                ])
                let rates0 = connRateTracker.update(items: items0, at: t0)
                try check(rates0.isEmpty, "Initial connection sample has no prior delta")

                let items1 = ConnectionTableItem.identify([
                    makeConn(host: "video.example", up: 5_000, down: 2_010_000),
                    makeConn(host: "chat.example", up: 500, down: 500),
                ])
                let rates1 = connRateTracker.update(items: items1, at: t0.addingTimeInterval(2.0))
                let videoRate = rates1[items1[0].id]
                let chatRate = rates1[items1[1].id]
                try check(
                    videoRate?.uploadBytesPerSecond == 2_000 && videoRate?.downloadBytesPerSecond == 1_000_000,
                    "Per-connection rate must equal byte delta / elapsed seconds"
                )
                try check(
                    (chatRate?.totalBytesPerSecond ?? 0) == 0,
                    "Idle connection must report 0 live rate"
                )

                // 3. ConnectionTruncationGuard: ranked-out connections must NOT pollute recentlyClosed
                var buffer = RecentlyClosedConnectionBuffer()
                var guardState = ConnectionTruncationGuard()
                let highClosed = makeConn(host: "closed-high.example", up: 0, down: 900_000, startedAt: 1)
                let stillOpenHigh = makeConn(host: "open-high.example", up: 0, down: 800_000, startedAt: 2)
                let rankedOutLow = makeConn(host: "ranked-out-low.example", up: 0, down: 1_000, startedAt: 3)

                // Poll 1: 3 connections under limit 250 (not truncated)
                guardState.record(
                    active: [highClosed, stillOpenHigh, rankedOutLow],
                    isTruncated: false,
                    into: &buffer
                )
                try check(buffer.connections.isEmpty, "No closed connections on initial sample")

                // Poll 2: Window switches to background limit 2 (truncated!), cutoff is 500_000.
                // - highClosed (900_000 > 500_000) disappeared -> genuinely closed!
                // - rankedOutLow (1_000 <= 500_000) disappeared -> merely ranked out of truncated top-2 window!
                let newcomer = makeConn(host: "newcomer.example", up: 0, down: 500_000, startedAt: 4)
                guardState.record(
                    active: [stillOpenHigh, newcomer],
                    isTruncated: true,
                    into: &buffer
                )
                let closedHosts = Set(buffer.connections.map(\\.destination))
                try check(
                    closedHosts.contains("closed-high.example"),
                    "Connection above truncation cutoff that vanished must be recorded as closed"
                )
                try check(
                    !closedHosts.contains("ranked-out-low.example"),
                    "Connection at or below truncation cutoff must NOT be falsely recorded as recently closed"
                )
            }
        }
        """
        try harnessCode.write(to: harnessURL, atomically: true, encoding: .utf8)

        let compile = Process()
        let errPipe = Pipe()
        compile.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        var args = ["--sdk", "macosx", "swiftc", "-swift-version", "6", "-warnings-as-errors", "-parse-as-library"]
        if !sdkPath.isEmpty {
            args += ["-sdk", sdkPath]
        }
        args += [
            "-F", productsDir.path,
            "-I", productsDir.path,
            "-Xlinker", "-rpath", "-Xlinker", productsDir.path,
            "-framework", "AetherRouteKit",
            connectionTableItemURL.path,
            harnessURL.path,
            "-o", binaryURL.path,
        ]
        compile.arguments = args
        compile.standardError = errPipe
        try compile.run()
        compile.waitUntilExit()
        let compileErrors = String(
            data: errPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            compile.terminationStatus,
            0,
            "Compiling ConnectionTableItem behavioral helpers failed:\n\(compileErrors)"
        )
        guard compile.terminationStatus == 0 else { return }

        let run = Process()
        let runErr = Pipe()
        run.executableURL = binaryURL
        run.standardError = runErr
        try run.run()
        run.waitUntilExit()
        let runtimeErrors = String(
            data: runErr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(
            run.terminationStatus,
            0,
            "Behavioral helper harness failed:\n\(runtimeErrors)"
        )
    }

    // MARK: - Task 4: Dynamic Connection Limit, Per-Row Menus, App Rule Close & No .prefix(8)

    func testTask4DynamicConnectionLimitContextMenusAppRuleCloseAndNoPrefix8() throws {
        let tunnelManager = try appSource("TunnelManager.swift")
        let telemetryExt = try appSource("TunnelManager+Telemetry.swift")
        let connectionsPage = try appSource("ConnectionsPageView.swift")
        let rulesPage = try appSource("RulesPageView.swift")

        // 1. Dynamic connection limit: 250 on Connections page, 64 in background/other pages
        XCTAssertTrue(
            tunnelManager.contains("250") && tunnelManager.contains("64"),
            "TunnelManager must define 250 limit for active Connections page and 64 limit for background/other pages"
        )
        XCTAssertTrue(
            telemetryExt.contains("effectiveTelemetryConnectionLimit"),
            "refreshTelemetry() must request effectiveTelemetryConnectionLimit dynamically"
        )

        // 2. Remove .prefix(8) group truncation in ConnectionsPageView (both places) and RulesPageView
        XCTAssertFalse(
            connectionsPage.contains(".prefix(8)"),
            "ConnectionsPageView must not truncate proxy group targets to .prefix(8)"
        )
        let ruleOverrideTargetsBody = try XCTUnwrap(
            functionBody(named: "private func ruleOverrideTargets(", in: rulesPage)
        )
        XCTAssertFalse(
            ruleOverrideTargetsBody.contains(".prefix(8)") || rulesPage.contains("proxyGroups.prefix(8)"),
            "RulesPageView must not truncate ruleOverrideTargets to .prefix(8)"
        )

        // 3. setApplicationRule in ConnectionsPageView must close existing connections of the app
        let appMenuBody = try XCTUnwrap(
            functionBody(named: "private func appContextMenu(", in: connectionsPage)
        )
        XCTAssertTrue(
            appMenuBody.contains("let saved = await tunnel.setApplicationRule")
                && appMenuBody.contains("closeConnections(of: app)"),
            "Setting an app rule from ConnectionsView.appContextMenu must immediately close existing connections of that app"
        )
        XCTAssertTrue(
            connectionsPage.contains("closeInspectorAppConnections"),
            "Setting an app rule from ConnectionInspector must also immediately close existing connections of that app"
        )

        // 4. Leaderboard right-click group close & per-row quick close
        XCTAssertTrue(
            connectionsPage.contains("closeGroupConnections"),
            "Leaderboard (by host / by outbound) must support closing all connections in the right-clicked group"
        )
        XCTAssertTrue(
            connectionsPage.contains("connectionRowContextMenu"),
            "All columns of the connection table must share the full row context menu"
        )
    }

    // MARK: - Task 5: Domestic Routing Optimization Bidirectional Parity & Live Reload

    func testTask5DomesticOptimizationProjectionParityAndLiveToggle() throws {
        let tunnelManager = try appSource("TunnelManager.swift")
        let profilesExt = try appSource("TunnelManager+Profiles.swift")
        let customRulesExt = try appSource("TunnelManager+CustomRules.swift")

        // 1. Verify AetherRouteKit optimizer + inspector parity across both edge cases:
        //    Case A: customRules is EMPTY and enableDomesticDirect == true
        //    Case B: customRules is NON-EMPTY and enableDomesticDirect == false
        let sampleYAML = """
        proxies:
          - { name: SG-01, type: trojan, server: sg.example.com, port: 443, password: secret }
        proxy-groups:
          - name: Proxy
            type: select
            proxies: [SG-01, DIRECT]
        rules:
          - MATCH,Proxy
        """

        let optimizedWhenEnabledNoCustom = DomesticRoutingOptimizer.optimizedProfile(
            for: sampleYAML,
            customRules: [],
            remoteRules: [],
            enableDomesticDirect: true
        )
        let summaryEnabledNoCustom = ProfileConfigurationInspector.inspect(
            yaml: optimizedWhenEnabledNoCustom,
            customRules: [],
            remoteRules: []
        )
        let rawSummary = ProfileConfigurationInspector.inspect(yaml: sampleYAML)
        XCTAssertGreaterThan(
            summaryEnabledNoCustom.directRuleCount,
            rawSummary.directRuleCount,
            "When domestic optimization is enabled with zero custom rules, summary must include injected domestic DIRECT rules"
        )

        let customRule = try XCTUnwrap(
            CustomRule(kind: .domainSuffix, value: "openai.com", target: .proxy("Proxy"))
        )
        let optimizedWhenDisabledWithCustom = DomesticRoutingOptimizer.optimizedProfile(
            for: sampleYAML,
            customRules: [customRule],
            remoteRules: [],
            enableDomesticDirect: false
        )
        let summaryDisabledWithCustom = ProfileConfigurationInspector.inspect(
            yaml: optimizedWhenDisabledWithCustom,
            customRules: [customRule],
            remoteRules: []
        )
        XCTAssertEqual(
            summaryDisabledWithCustom.directRuleCount,
            4,
            "When domestic optimization is disabled with custom rules present, only mandatory loopback rules (4) may remain — no CN domestic DIRECT rules"
        )
        XCTAssertLessThan(
            summaryDisabledWithCustom.directRuleCount,
            summaryEnabledNoCustom.directRuleCount,
            "Disabled domestic optimization must not inject domestic CN direct rules"
        )

        // 2. Source wiring checks across all 4 TunnelManager entry points
        let projectionBody = try XCTUnwrap(
            functionBody(named: "static func production(", in: tunnelManager)
        )
        XCTAssertTrue(
            projectionBody.contains("DomesticRoutingOptimizer.optimizedProfile")
                && projectionBody.contains("enableDomesticDirect:"),
            "ProfileCatalogProjectionBuilder.production must pass runtimeYAML through DomesticRoutingOptimizer with explicit enableDomesticDirect"
        )

        let installBody = try XCTUnwrap(
            functionBody(named: "func installProfileProjection(", in: profilesExt)
        )
        XCTAssertTrue(
            installBody.contains("enableDomesticDirect: isDomesticOptimizationEnabled"),
            "installProfileProjection must always honor isDomesticOptimizationEnabled"
        )
        XCTAssertFalse(
            installBody.contains("(!customRules.isEmpty || !compiledRemoteRulesCache.isEmpty)"),
            "installProfileProjection must not skip DomesticRoutingOptimizer when customRules is empty"
        )

        let refreshSummaryBody = try XCTUnwrap(
            functionBody(named: "func refreshActiveProfileSummary()", in: customRulesExt)
        )
        XCTAssertTrue(
            refreshSummaryBody.contains("enableDomesticDirect: isDomesticOptimizationEnabled"),
            "refreshActiveProfileSummary must pass enableDomesticDirect: isDomesticOptimizationEnabled"
        )

        let toggleBody = try XCTUnwrap(
            functionBody(named: "func setDomesticOptimizationEnabled(", in: tunnelManager)
        )
        XCTAssertTrue(
            toggleBody.contains("refreshActiveProfileSummary()")
                && toggleBody.contains("reloadCustomRulesLive()"),
            "setDomesticOptimizationEnabled must immediately refresh activeProfileSummary and live-reload when connected"
        )
    }

    // MARK: - Cross-Module Glue Integration

    func testCrossModuleGlueIntegration() async throws {
        let latencyExt = try appSource("TunnelManager+Latency.swift")
        let telemetryExt = try appSource("TunnelManager+Telemetry.swift")
        let tunnelManager = try appSource("TunnelManager.swift")
        let contentView = try appSource("ContentView.swift")
        let profilesPage = try appSource("ProfilesPageView.swift")
        let connectionsPage = try appSource("ConnectionsPageView.swift")

        // 1. Unified delay preference wired into client.displayLatency
        XCTAssertTrue(
            latencyExt.contains("unifiedDelay: LatencyTestPreferences.isUnifiedDelayEnabled"),
            "TunnelManager+Latency must forward LatencyTestPreferences.isUnifiedDelayEnabled to client.displayLatency"
        )

        // 2. Native activeGroupLeaves merged into automaticGroupLeaves
        XCTAssertTrue(
            telemetryExt.contains("snapshot.activeGroupLeaves"),
            "TunnelManager.publishTelemetry must merge snapshot.activeGroupLeaves into automaticGroupLeaves"
        )

        // 3. Pseudo-node SubscriptionUsage fallback on missing Subscription-Userinfo header
        let yamlWithNotice = """
        proxies:
          - { name: "剩余流量：154.92 GB", type: ss, server: 198.51.100.1, port: 443, cipher: aes-128-gcm, password: secret }
          - { name: "套餐到期：2028-05-01", type: ss, server: 198.51.100.2, port: 443, cipher: aes-128-gcm, password: secret }
          - { name: "JP Tokyo 01", type: ss, server: 198.51.100.3, port: 443, cipher: aes-128-gcm, password: secret }
        proxy-groups:
          - name: Proxy
            type: select
            proxies:
              - "剩余流量：154.92 GB"
              - "套餐到期：2028-05-01"
              - "JP Tokyo 01"
        rules:
          - MATCH,Proxy
        """
        let checkedAt = Date(timeIntervalSince1970: 1_780_000_000)
        let subURL = try XCTUnwrap(URL(string: "https://sub.example.test/api"))
        let client = ProfileSubscriptionClient(
            transport: { request in
                ProfileSubscriptionHTTPResponse(
                    data: Data(yamlWithNotice.utf8),
                    statusCode: 200,
                    finalURL: request.url,
                    headers: [:]
                )
            },
            now: { checkedAt }
        )
        let sub = try ProfileSubscription(url: subURL)
        let refreshResult = try await client.fetch(sub)
        guard case let .updated(_, metadata, _) = refreshResult else {
            return XCTFail("Expected .updated subscription result")
        }
        let fallbackUsage: SubscriptionUsage = try XCTUnwrap(
            metadata.usage,
            "When HTTP Subscription-Userinfo header is absent, fetch must fall back to notice pseudo-node usage"
        )
        XCTAssertNotNil(fallbackUsage.remainingBytes)
        XCTAssertNotNil(fallbackUsage.expiresAt)
        XCTAssertTrue(
            profilesPage.contains("SubscriptionUsage.fallback(from: summary")
                && profilesPage.contains("let remaining = usage.remainingBytes"),
            "ProfilesPageView must fall back to SubscriptionUsage.fallback and format remainingBytes when totalBytes is nil"
        )
        XCTAssertTrue(
            contentView.contains("subscriptionUsage: tunnel.effectiveActiveSubscriptionUsage"),
            "Overview TrafficCard must receive effectiveActiveSubscriptionUsage fallback"
        )

        // 4. totalActiveConnections wired into sidebar badge, Overview, Connections page & truncation guard
        XCTAssertTrue(
            contentView.contains("telemetry.snapshot.totalActiveConnections"),
            "Sidebar badge and Overview live connections must use snapshot.totalActiveConnections"
        )
        XCTAssertTrue(
            connectionsPage.contains("telemetry.snapshot.totalActiveConnections"),
            "Connections page count & footer must use snapshot.totalActiveConnections"
        )
        XCTAssertTrue(
            tunnelManager.contains("snapshot.totalActiveConnections > snapshot.connections.count"),
            "NetworkTelemetryViewModel.update must treat wire-clamped snapshots (totalActiveConnections > connections.count) as truncated"
        )
    }
}

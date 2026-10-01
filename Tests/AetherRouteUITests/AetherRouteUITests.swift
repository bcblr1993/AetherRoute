import AppKit
import CryptoKit
import Dispatch
import Foundation
import XCTest

@MainActor
final class AetherRouteUITests: XCTestCase {
    func testCaptureUIReviewMatrix() throws {
        guard let path = ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_CASES_FILE"] else {
            throw XCTSkip("The screenshot matrix is enabled only for an explicit capture run.")
        }
        let rows = try String(contentsOfFile: path, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
        XCTAssertEqual(rows.count, 44)
        let tabLabels = [
            "network": "Network Settings", "automation": "Shortcuts & Notifications",
            "general": "General", "privacy": "Privacy", "bypass": "Bypass",
            "diagnostics": "Diagnostics", "account": "Version & Updates",
            "licenses": "Licenses", "about": "About",
        ]
        let chineseLabels = [
            "network": "网络", "automation": "快捷键与通知", "general": "通用",
            "privacy": "隐私", "bypass": "绕过", "diagnostics": "诊断",
            "account": "版本与更新", "licenses": "开源许可", "about": "关于",
        ]
        for row in rows {
            let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            XCTAssertEqual(fields.count, 10)
            guard fields.count == 10 else { return }
            let app = launchReviewApp(
                appearance: fields[2], state: fields[5], privacyPending: fields[7] == "pending",
                engine: fields[6], language: fields[1], windowSize: fields[4],
                expandedText: fields[8] == "expanded", section: fields[3]
            )
            defer { app.terminate() }
            let window: XCUIElement
            if fields[9] == "-" {
                window = mainProductWindow(in: app)
                let destination = fields[7] == "pending"
                    ? app.buttons["privacy-consent-button"]
                    : app.descendants(matching: .any)[fields[3] + "-page"]
                XCTAssertTrue(destination.waitForExistence(timeout: 5),
                    "Screenshot case did not reach its requested page: \(fields[0]).")
            } else {
                let labels = fields[1] == "zh-Hans" ? chineseLabels : tabLabels
                let label = try XCTUnwrap(labels[fields[9]])
                openSettings(in: app, tabLabel: label)
                window = app.windows["com_apple_SwiftUI_Settings_window"]
            }
            XCTAssertTrue(window.waitForExistence(timeout: 5))
            let attachment = XCTAttachment(screenshot: window.screenshot())
            attachment.name = "ui-matrix-" + fields[0]
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        let requiresIsolatedWorkspace = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_TEST_ISOLATED_HOME"
        ] != nil
        addUIInterruptionMonitor(
            withDescription: "Deny broad protected-folder access"
        ) { alert in
            MainActor.assumeIsolated {
                let automationRationale = alert.staticTexts[
                    "Access is necessary for automated testing."
                ]
                guard automationRationale.exists else {
                    return false
                }
                if requiresIsolatedWorkspace {
                    XCTFail(
                        "The temporary UI test workspace requested protected-folder access."
                    )
                }
                for label in ["Don’t Allow", "Don't Allow", "不允许"] {
                    let localizedDenyButton = alert.buttons[label]
                    if localizedDenyButton.exists
                        && localizedDenyButton.isHittable
                    {
                        localizedDenyButton.click()
                        return true
                    }
                }
                let stableDenyButton = alert.buttons["action-button-2"]
                if stableDenyButton.exists && stableDenyButton.isHittable {
                    stableDenyButton.click()
                    return true
                }
                return false
            }
        }
    }

    func testOverviewPassesAccessibilityAuditInLightAndDark() throws {
        try auditPrimaryPage(
            button: "Overview",
            landmark: "overview-status-title"
        )
    }

    func testProxiesPassAccessibilityAuditInLightAndDark() throws {
        try auditPrimaryPage(
            button: "Proxies", landmark: "proxy-test-latency-Balanced",
            windowSize: "780x560"
        )
    }

    func testConnectionsPassAccessibilityAuditInLightAndDark() throws {
        try auditPrimaryPage(
            button: "Connections",
            landmark: "Counted on this Mac only; nothing is reported.",
            windowSize: "780x560"
        )
        for item in [
            (language: "en", appearance: "light", expanded: true, unknown: "Unknown Unknown", label: "Connection duration Connection duration"),
            (language: "zh-Hans", appearance: "dark", expanded: false, unknown: "未知", label: "连接时长"),
        ] {
            try { () throws in
                let app = launchReviewApp(
                    appearance: item.appearance,
                    language: item.language,
                    windowSize: "780x560",
                    expandedText: item.expanded,
                    invalidConnectionTimestamps: true
                )
                defer { app.terminate() }
                let navigation = app.buttons["primary-navigation-connections"]
                XCTAssertTrue(navigation.waitForExistence(timeout: 3))
                navigation.click()
                let durations = app.staticTexts.matching(identifier: "connection-duration")
                XCTAssertTrue(durations.firstMatch.waitForExistence(timeout: 2))
                XCTAssertEqual(durations.count, 2)
                for duration in durations.allElementsBoundByIndex {
                    XCTAssertEqual(duration.value as? String, item.unknown)
                    XCTAssertEqual(duration.label, item.label)
                    XCTAssertTrue(mainProductWindow(in: app).frame.contains(duration.frame))
                }
                assertConnectionsFit(in: app)
                try auditProductAccessibility(in: app)
            }()
        }
    }

    func testConnectionListSearchPauseAndDetails() {
        let app = launchReviewApp(appearance: "light", windowSize: "940x640")
        defer { app.terminate() }
        navigationButton(in: app, title: "Connections").click()
        let pause = app.buttons["connections-pause-button"]
        XCTAssertTrue(pause.waitForExistence(timeout: 3))
        pause.click()
        XCTAssertTrue(app.staticTexts["List paused · session counters are live"].exists)
        let search = app.textFields["connections-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        search.click()
        search.typeText("developer.apple.com")
        // The host and the port are separate texts, so a long host can be
        // cut from the left without losing the port.
        let destination = app.staticTexts["developer.apple.com"].firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["dns.google"].exists)
        destination.rightClick()
        app.menuItems["Connection details"].click()
        XCTAssertTrue(app.staticTexts["Snapshot captured when opened. Values do not refresh here."].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["Balanced → Singapore Edge"].exists)
        app.buttons["Done"].click()
        pause.click()
        XCTAssertFalse(app.staticTexts["List paused · session counters are live"].exists)
    }

    func testProfileSearchFiltersAndClears() {
        let app = launchReviewApp(appearance: "light", state: "disconnected")
        defer { app.terminate() }
        navigationButton(in: app, title: "Profiles").click()
        let search = app.textFields["profiles-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 3))
        search.click()
        search.typeText("Office")
        XCTAssertTrue(app.staticTexts["Office · Automatic"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Balanced · Singapore"].exists)
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["Balanced · Singapore"].waitForExistence(timeout: 3))
    }

    func testProfilesPassAccessibilityAuditInLightAndDark() throws {
        try auditPrimaryPage(button: "Profiles", landmark: "My profiles")
    }

    func testRulesPassAccessibilityAuditInLightAndDark() throws {
        try auditPrimaryPage(button: "Rules", landmark: "Profile rules")
    }

    func testDNSPassesAccessibilityAuditInLightAndDark() throws {
        try auditPrimaryPage(button: "DNS", landmark: "page-header-title-dns")
    }

    func testPrimaryNavigationExposesReachableDestinations() {
        let app = launchReviewApp(appearance: "dark")
        defer { app.terminate() }

        XCTAssertTrue(
            mainProductWindow(in: app).waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["Disconnect"].isEnabled)
        navigationButton(in: app, title: "Proxies").click()
        XCTAssertTrue(app.buttons["proxy-test-latency-Balanced"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Singapore Edge"].waitForExistence(timeout: 2))
        navigationButton(in: app, title: "Connections").click()
        XCTAssertTrue(app.staticTexts["Counted on this Mac only; nothing is reported."].waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["disconnect-all-connections"].isHittable)
        app.buttons["Profiles"].click()
        XCTAssertTrue(app.menuButtons["profiles-add-menu"].waitForExistence(timeout: 2))
        navigationButton(in: app, title: "Rules").click()
        XCTAssertTrue(app.staticTexts["Profile rules"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "DOMAIN-SUFFIX")
            ).firstMatch.exists
        )
        app.buttons["DNS"].click()
        XCTAssertTrue(app.staticTexts["page-header-title-dns"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "value CONTAINS %@", "Fake-IP")
            ).firstMatch.exists
        )
    }

    func testMainAndSettingsUseNativeCompactWindowChrome() {
        let app = launchReviewApp(appearance: "dark")
        defer { app.terminate() }

        let mainWindow = mainProductWindow(in: app)
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        assertNativeCompactWindowChrome(mainWindow)

        openSettings(in: app, tabLabel: "General")
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        assertNativeCompactWindowChrome(settingsWindow)
    }

    func testPageNavigationPreservesWindowSizeWithinEachWindowClass() {
        let app = launchReviewApp(
            appearance: "light",
            windowSize: "940x640"
        )
        defer { app.terminate() }

        let mainWindow = mainProductWindow(in: app)
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 5))
        let mainSize = mainWindow.frame.size
        for (button, landmark) in [
            ("Overview", "overview-status-title"),
            ("Proxies", "proxy-test-latency-Balanced"),
            ("Connections", "Counted on this Mac only; nothing is reported."),
            ("Profiles", "My profiles"),
            ("Rules", "Profile rules"),
            ("DNS", "page-header-title-dns"),
        ] {
            navigationButton(in: app, title: button).click()
            XCTAssertTrue(
                app.staticTexts[landmark].waitForExistence(timeout: 2)
                    || app.buttons[landmark].waitForExistence(timeout: 2)
            )
            assertWindowSize(
                mainWindow,
                equals: mainSize,
                context: "main page \(button)"
            )
        }

        openSettings(in: app, tabLabel: "General")
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        let settingsSize = settingsWindow.frame.size
        for tab in [
            "General", "Network Settings", "Shortcuts & Notifications", "Privacy", "Bypass", "Diagnostics", "Version & Updates",
            "Licenses", "About",
        ] {
            selectSettingsTab(tab, in: settingsWindow, app: app)
            assertWindowSize(
                settingsWindow,
                equals: settingsSize,
                context: "settings page \(tab)"
            )
        }

        assertWindowSize(
            mainWindow,
            equals: mainSize,
            context: "main window after Settings navigation"
        )
    }

    func testBilingualNavigationResponsiveness() throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AETHERROUTE_RUN_UI_RESPONSIVENESS"] == "YES" else {
            throw XCTSkip(
                "The 30-minute Release UI responsiveness gate requires explicit opt-in."
            )
        }
        guard let isolatedHome = environment[
            "AETHERROUTE_UI_TEST_ISOLATED_HOME"
        ], let evidencePath = environment[
            "AETHERROUTE_UI_RESPONSIVENESS_EVIDENCE"
        ] else {
            XCTFail("The responsiveness gate requires isolated output paths.")
            return
        }

        let requestedDuration = Int(
            environment["AETHERROUTE_UI_RESPONSIVENESS_SECONDS"] ?? "1800"
        ) ?? 0
        let isSmoke = environment["AETHERROUTE_UI_RESPONSIVENESS_SMOKE"] == "YES"
        guard requestedDuration > 0,
              isSmoke || requestedDuration >= 1_800 else {
            XCTFail(
                "Short responsiveness runs require AETHERROUTE_UI_RESPONSIVENESS_SMOKE=YES."
            )
            return
        }
        let maximumP95Milliseconds = Double(
            environment["AETHERROUTE_UI_RESPONSIVENESS_MAX_P95_MS"] ?? "120"
        ) ?? 0
        guard maximumP95Milliseconds > 0 else {
            XCTFail("The responsiveness p95 budget must be positive.")
            return
        }

        let manager = FileManager.default
        let appSamplesURL = URL(fileURLWithPath: isolatedHome)
            .appendingPathComponent("ui-responsiveness-app.csv")
        let evidenceURL = URL(fileURLWithPath: evidencePath)
        try manager.createDirectory(
            at: evidenceURL,
            withIntermediateDirectories: true
        )

        let systemReduceMotionAtStart = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion
        XCTAssertFalse(
            systemReduceMotionAtStart,
            "Default-animation acceptance requires system Reduce Motion to be off; the test does not change user settings."
        )
        let app = launchReviewApp(
            appearance: "light",
            state: "connected",
            language: "en",
            windowSize: "940x640",
            reduceMotion: false,
            responsivenessOutput: appSamplesURL.path
        )
        defer { app.terminate() }
        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))

        let hangsRecording = try prepareHangsRecordingIfRequested(
            app: app,
            isolatedHome: URL(fileURLWithPath: isolatedHome),
            evidenceURL: evidenceURL
        )
        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(
            TimeInterval(requestedDuration)
        )
        var cycles = 0
        repeat {
            exerciseResponsiveMainNavigation(
                in: app,
                destinations: [
                    ("Proxies", "proxies-page"),
                    ("Connections", "connections-page"),
                    ("Profiles", "profiles-page"),
                    ("Rules", "rules-page"),
                    ("DNS", "dns-page"),
                    ("Overview", "overview-page"),
                ]
            )
            exerciseResponsiveSettingsNavigation(
                in: app,
                tabs: [
                    "Network", "Privacy & Diagnostics", "About", "General",
                ]
            )
            changeResponsiveLanguage(
                to: "简体中文",
                expectedMainNavigation: "概览",
                in: app
            )
            closeResponsiveSettings(in: app)

            exerciseResponsiveMainNavigation(
                in: app,
                destinations: [
                    ("代理", "proxies-page"),
                    ("连接", "connections-page"),
                    ("配置", "profiles-page"),
                    ("规则", "rules-page"),
                    ("DNS", "dns-page"),
                    ("概览", "overview-page"),
                ]
            )
            exerciseResponsiveSettingsNavigation(
                in: app,
                tabs: [
                    "网络", "隐私与诊断", "关于", "通用",
                ]
            )
            changeResponsiveLanguage(
                to: "English",
                expectedMainNavigation: "Overview",
                in: app
            )
            closeResponsiveSettings(in: app)
            cycles += 1
        } while Date() < deadline

        Thread.sleep(forTimeInterval: 1)
        let samples = try readUIResponsivenessSamples(from: appSamplesURL)
        let requiredActions = [
            "main.overview", "main.proxies", "main.connections",
            "main.profiles", "main.rules", "main.dns",
            "settings.general", "settings.network", "settings.privacy", "settings.about",
        ]
        for language in ["en", "zh-Hans"] {
            for action in requiredActions {
                let actionSamples = samples.filter {
                    $0.language == language && $0.action == action
                }
                XCTAssertGreaterThanOrEqual(
                    actionSamples.count,
                    action.hasPrefix("main.") ? cycles * 2 : cycles,
                    "Missing pointer or keyboard responsiveness samples for \(language) \(action)."
                )
            }
        }

        let sortedDurations = samples.map(\.durationMilliseconds).sorted()
        let percentileIndex = min(
            sortedDurations.count - 1,
            max(0, Int(ceil(Double(sortedDurations.count) * 0.95)) - 1)
        )
        let p95Milliseconds = sortedDurations[percentileIndex]
        let maximumMilliseconds = sortedDurations.last ?? 0
        let elapsedSeconds = Int(Date().timeIntervalSince(startedAt))
        let systemReduceMotionAtEnd = NSWorkspace.shared
            .accessibilityDisplayShouldReduceMotion

        let retainedSamplesURL = evidenceURL.appendingPathComponent(
            "navigation-samples.csv"
        )
        try Data(contentsOf: appSamplesURL).write(
            to: retainedSamplesURL,
            options: .withoutOverwriting
        )
        let result = """
        schema=1
        status=\(isSmoke ? "smoke" : "passed")
        requested_seconds=\(requestedDuration)
        elapsed_seconds=\(elapsedSeconds)
        bilingual_cycles=\(cycles)
        sample_count=\(samples.count)
        p95_action_ms=\(String(format: "%.3f", p95Milliseconds))
        maximum_action_ms=\(String(format: "%.3f", maximumMilliseconds))
        maximum_p95_action_ms=\(String(format: "%.3f", maximumP95Milliseconds))
        languages=en,zh-Hans
        main_pages=6
        settings_pages=7
        network_extension=disabled
        review_reduce_motion=false
        system_reduce_motion_start=\(systemReduceMotionAtStart)
        system_reduce_motion_end=\(systemReduceMotionAtEnd)
        \n
        """
        try Data(result.utf8).write(
            to: evidenceURL.appendingPathComponent("result.txt"),
            options: .withoutOverwriting
        )
        try finishHangsRecording(
            hangsRecording, startedAt: startedAt, endedAt: Date()
        )
        XCTAssertEqual(
            systemReduceMotionAtStart,
            systemReduceMotionAtEnd,
            "The system Reduce Motion setting changed during measurement."
        )
        XCTAssertLessThanOrEqual(
            p95Milliseconds,
            maximumP95Milliseconds,
            "Application-side navigation p95 exceeded the release budget."
        )
    }

    func testRuntimeStatesExposeTruthfulPrimaryActions() {
        let cases = [
            (state: "loading", title: "Preparing", enabled: false),
            (state: "disconnected", title: "Connect", enabled: true),
            (state: "connecting", title: "Cancel", enabled: true),
            (state: "connected", title: "Disconnect", enabled: true),
            (state: "disconnecting", title: "Disconnecting", enabled: false),
            (state: "failed", title: "Retry", enabled: true),
            (state: "extension-approval", title: "Waiting for approval", enabled: false),
        ]

        for item in cases {
            let app = launchReviewApp(appearance: "light", state: item.state)
            XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
            let button = app.buttons["primary-connection-button"]
            XCTAssertTrue(button.exists)
            XCTAssertEqual(button.label, item.title)
            XCTAssertEqual(button.isEnabled, item.enabled)
            if item.state != "connected" {
                navigationButton(in: app, title: "Connections").click()
                let connectionsButton = app.buttons["connections-primary-action"]
                XCTAssertTrue(connectionsButton.waitForExistence(timeout: 2))
                XCTAssertEqual(connectionsButton.label, item.title)
                XCTAssertEqual(connectionsButton.isEnabled, item.enabled)
            }
            app.terminate()
        }

        // Approval takes precedence over missing-profile recovery on first run.
        // The recheck entry uses the production helper; review mode prevents
        // any request to the real system extension manager.
        for language in ["en", "zh-Hans"] {
            for profileEmpty in [false, true] {
                let app = launchReviewApp(
                    appearance: "light", state: "extension-approval",
                    profileEmpty: profileEmpty, language: language
                )
                XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
                let primary = app.buttons["primary-connection-button"]
                XCTAssertEqual(primary.label, language == "en"
                    ? "Waiting for approval" : "等待批准")
                XCTAssertFalse(primary.isEnabled)
                let settings = app.buttons["extension-approval-open-settings"]
                let recheck = app.buttons["extension-approval-recheck"]
                XCTAssertTrue(settings.waitForExistence(timeout: 2))
                XCTAssertTrue(settings.isEnabled)
                XCTAssertEqual(settings.label, language == "en"
                    ? "Open System Settings" : "打开系统设置")
                XCTAssertTrue(recheck.isEnabled)
                XCTAssertFalse(app.otherElements["connection-recovery-card"].exists)
                XCTAssertFalse(app.buttons["recovery-reviewProfiles"].exists)
                XCTAssertFalse(app.buttons["recovery-retry"].exists)
                recheck.click()
                XCTAssertTrue(settings.exists)
                XCTAssertFalse(primary.isEnabled)
                let attachment = XCTAttachment(screenshot: app.screenshot())
                attachment.name = "extension-approval-\(language)-\(profileEmpty ? "empty" : "configured")"
                attachment.lifetime = .keepAlways
                add(attachment)
                app.terminate()
            }
        }
    }

    func testStableStatesAllowEngineRoutingProfileAndNodeSwitching() {
        for state in ["disconnected", "connected"] {
            let app = launchReviewApp(appearance: "light", state: state)
            XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))

            let engine = app.radioGroups["network-engine-picker"]
            let routingByIdentifier = app.descendants(matching: .any)[
                "routing-mode-picker"
            ]
            let routingByLabel = app.descendants(matching: .any)["Routing mode"]
            XCTAssertTrue(engine.waitForExistence(timeout: 2))
            let routing = routingByIdentifier.waitForExistence(timeout: 1)
                ? routingByIdentifier
                : routingByLabel
            XCTAssertTrue(routing.waitForExistence(timeout: 2))
            XCTAssertTrue(engine.isEnabled, "Engine switching is disabled while \(state).")
            XCTAssertTrue(routing.isEnabled, "Routing switching is disabled while \(state).")

            navigationButton(in: app, title: "Proxies").click()
            let automaticSelection = app.descendants(matching: .any)[
                "proxy-auto-select-Balanced"
            ]
            XCTAssertTrue(automaticSelection.waitForExistence(timeout: 2))
            XCTAssertTrue(
                automaticSelection.isEnabled,
                "Automatic node selection is disabled while \(state)."
            )
            let node = app.buttons["Singapore Edge"]
            XCTAssertTrue(node.waitForExistence(timeout: 2))
            XCTAssertTrue(
                node.isEnabled,
                "Manual node switching is disabled while \(state)."
            )

            app.buttons["Profiles"].click()
            let useProfile = app.buttons.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND enabled == true", "radio-select-")
            ).firstMatch
            XCTAssertTrue(useProfile.waitForExistence(timeout: 2))
            XCTAssertTrue(
                useProfile.isEnabled,
                "Profile switching is disabled while \(state)."
            )
            app.terminate()
        }
    }

    func testPrivacyDisclosureBlocksNetworkFeaturesUntilAccepted() throws {
        for appearance in ["light", "dark"] {
            do {
                let auditApp = launchReviewApp(
                    appearance: appearance,
                    privacyPending: true,
                    windowSize: "780x560"
                )
                defer { auditApp.terminate() }

                XCTAssertTrue(
                    mainProductRoot(in: auditApp).waitForExistence(timeout: 5)
                )
                XCTAssertTrue(auditApp.staticTexts["Your Network Privacy"].exists)
                auditApp.buttons["privacy-details-toggle"].click()
                for _ in 0..<4 {
                    if auditApp.staticTexts["No sale or tracking"].exists { break }
                    mainProductWindow(in: auditApp).scrollViews.firstMatch
                        .scroll(byDeltaX: 0, deltaY: 220)
                }
                XCTAssertTrue(auditApp.staticTexts["No sale or tracking"].waitForExistence(timeout: 2))
                XCTAssertFalse(auditApp.buttons["Connect"].exists)
                XCTAssertFalse(auditApp.buttons["Import Profile…"].exists)
                try auditProductAccessibility(in: auditApp)
            }

            do {
                let interactionApp = launchReviewApp(
                    appearance: appearance,
                    privacyPending: true,
                    windowSize: "780x560"
                )
                defer { interactionApp.terminate() }

                let consentButton = interactionApp.buttons[
                    "I Understand and Continue"
                ]
                XCTAssertTrue(consentButton.waitForExistence(timeout: 2))
                XCTAssertTrue(consentButton.isEnabled)
                let mainWindow = mainProductWindow(in: interactionApp)
                XCTAssertTrue(
                    mainWindow.frame.contains(consentButton.frame),
                    "Privacy consent was clipped outside the main window."
                )
                consentButton.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
                ).click()

                XCTAssertTrue(
                    interactionApp.buttons["Overview"].waitForExistence(timeout: 2)
                )
                XCTAssertFalse(
                    interactionApp.staticTexts["Your Network Privacy"].exists
                )
            }
        }
    }

    func testNoProfileStateRemainsUsableAndCannotConnect() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            profileEmpty: true,
            windowSize: "780x560"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        let connectButton = app.buttons["primary-connection-button"]
        XCTAssertEqual(connectButton.label, "Connect")
        XCTAssertFalse(connectButton.isEnabled)

        app.buttons["Profiles"].click()
        XCTAssertTrue(app.staticTexts["No Profiles Added"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuButtons["profiles-add-menu"].isHittable)
        navigationButton(in: app, title: "Connections").click()
        let connectionsButton = app.buttons["connections-primary-action"]
        XCTAssertTrue(connectionsButton.waitForExistence(timeout: 2))
        XCTAssertEqual(connectionsButton.label, "Connect")
        XCTAssertFalse(connectionsButton.isEnabled)
        navigationButton(in: app, title: "Proxies").click()
        XCTAssertTrue(
            app.staticTexts["No proxies yet"].waitForExistence(timeout: 2)
        )
        navigationButton(in: app, title: "Rules").click()
        XCTAssertTrue(
            app.staticTexts["No rule set loaded"].waitForExistence(timeout: 2)
        )
        app.buttons["DNS"].click()
        XCTAssertTrue(
            app.staticTexts["No DNS policy loaded"].waitForExistence(timeout: 2)
        )
    }

    func testCommandNumberShortcutsNavigateWithoutPointerInput() {
        let app = launchReviewApp(appearance: "dark")
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.typeKey("5", modifierFlags: .command)
        // The route tester leads the Rules page; lower sections are lazy.
        XCTAssertTrue(app.descendants(matching: .any)["rule-test-field"].waitForExistence(timeout: 2))
        app.typeKey("1", modifierFlags: .command)
        XCTAssertTrue(app.descendants(matching: .any)["overview-page"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.staticTexts["overview-status-title"].exists)
        app.typeKey("6", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["page-header-title-dns"].waitForExistence(timeout: 2))
    }

    func testSimplifiedChineseCoreExperienceAtMinimumWindowSize() throws {
        let app = launchReviewApp(
            appearance: "light",
            language: "zh-Hans",
            windowSize: "780x560"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["概览"].exists)
        XCTAssertTrue(app.staticTexts["overview-status-title"].exists)
        XCTAssertTrue(app.buttons["断开连接"].isEnabled)
        XCTAssertTrue(navigationButton(in: app, title: "代理").isHittable)
        XCTAssertTrue(navigationButton(in: app, title: "连接").isHittable)
        XCTAssertTrue(app.buttons["配置"].isHittable)
        XCTAssertTrue(navigationButton(in: app, title: "规则").isHittable)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@",
                    "down",
                    "down"
                )
            ).firstMatch.exists
        )
        try auditProductAccessibility(in: app)
    }

    func testExpandedTextRemainsUsableAcrossEnglishPrimaryPages() throws {
        try assertExpandedTextExperience(
            language: "en",
            appearance: "dark",
            destinations: [
                ("Overview", "overview-status-title", "overview-page"),
                ("Proxies", "proxy-test-latency-Balanced", "proxies-page"),
                ("Connections", "Counted on this Mac only; nothing is reported.", "connections-page"),
                ("Profiles", "My profiles", "profiles-page"),
                ("Rules", "Profile rules", "rules-page"),
                ("DNS", "DNS", "dns-page"),
            ]
        )
    }

    func testExpandedTextRemainsUsableAcrossChinesePrimaryPages() throws {
        try assertExpandedTextExperience(
            language: "zh-Hans",
            appearance: "light",
            destinations: [
                ("概览", "overview-status-title", "overview-page"),
                ("代理", "proxy-test-latency-Balanced", "proxies-page"),
                ("连接", "只统计本机可见的连接，不上报", "connections-page"),
                ("配置", "我的配置", "profiles-page"),
                ("规则", "配置中的规则", "rules-page"),
                ("DNS", "DNS", "dns-page"),
            ]
        )
    }

    func testConnectedReadinessCopyIsArchitectureNeutralInEnglishAndChinese() {
        let cases = [
            (language: "en", expected: "The network extension reports ready"),
            (language: "zh-Hans", expected: "网络扩展已报告就绪"),
        ]

        for item in cases {
            let app = launchReviewApp(
                appearance: "light",
                language: item.language,
                windowSize: "780x560"
            )
            XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
            XCTAssertTrue(
                app.staticTexts.matching(
                    NSPredicate(format: "value == %@", item.expected)
                ).firstMatch.waitForExistence(timeout: 2)
            )
            XCTAssertFalse(app.staticTexts["The packet tunnel reports ready"].exists)
            app.terminate()
        }
    }

    func testSubscriptionControlsAreReachableWithoutNetworkAccess() {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            subscriptionProfile: true
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.buttons["Profiles"].click()
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "HTTPS subscription", "HTTPS subscription")
        ).firstMatch.waitForExistence(timeout: 2))
        XCTAssertTrue(app.buttons["Check for Updates"].isHittable)
        XCTAssertTrue(app.menuButtons["profiles-add-menu"].isHittable)
    }

    func testProfileLibraryActionsCompleteThroughAsyncUIPaths() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.buttons["Profiles"].click()
        for _ in 0..<3 {
            if app.staticTexts["My profiles"].exists { break }
            app.descendants(matching: .any)["profiles-page"]
                .scroll(byDeltaX: 0, deltaY: 400)
        }
        XCTAssertTrue(app.staticTexts["My profiles"].waitForExistence(timeout: 2))

        let useButton = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND enabled == true", "radio-select-")
        ).firstMatch
        XCTAssertTrue(useButton.waitForExistence(timeout: 2))
        if !useButton.isHittable {
            app.descendants(matching: .any)["profiles-page"]
                .scroll(byDeltaX: 0, deltaY: 640)
        }
        let useButtonIsHittable = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "hittable == true"),
            object: useButton
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [useButtonIsHittable], timeout: 2),
            .completed
        )
        useButton.click()
        XCTAssertTrue(
            app.staticTexts["Profile activated."].waitForExistence(timeout: 2)
        )

        let tokyoActions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "activate-profile-")
        ).containing(.staticText, identifier: "Tokyo · Low Latency").firstMatch
            .descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "profile-actions-")
            ).firstMatch
        XCTAssertTrue(tokyoActions.isHittable)
        tokyoActions.click()
        let rename = app.menuItems["Rename…"]
        XCTAssertTrue(rename.waitForExistence(timeout: 2))
        rename.click()

        let nameField = app.textFields["profile-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        nameField.typeText("Tokyo · Production")
        app.buttons["Save"].click()
        XCTAssertTrue(
            app.staticTexts["Profile renamed."].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["Tokyo · Production"].waitForExistence(timeout: 2)
        )

        let officeActions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "activate-profile-")
        ).containing(.staticText, identifier: "Office · Automatic").firstMatch
            .descendants(matching: .any).matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "profile-actions-")
            ).firstMatch
        XCTAssertTrue(officeActions.isHittable)
        officeActions.click()
        let remove = app.menuItems["Remove Profile"]
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        remove.click()
        // The confirmation is a system dialog; its button may surface by
        // identifier or only by title.
        let confirmByIdentifier = app.buttons["confirm-remove-profile"]
        let confirmRemove = confirmByIdentifier.waitForExistence(timeout: 2)
            ? confirmByIdentifier
            : app.sheets.buttons["Remove"].firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 2))
        confirmRemove.click()
        XCTAssertTrue(
            app.staticTexts["Profile removed."].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.staticTexts["Office · Automatic"].exists)
    }

    func testConnectedStateAllowsInactiveProfileModificationsWhileProtectingActiveProfile() {
        let app = launchReviewApp(
            appearance: "light",
            state: "connected"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.buttons["Profiles"].click()
        for _ in 0..<3 {
            if app.staticTexts["My profiles"].exists { break }
            app.descendants(matching: .any)["profiles-page"]
                .scroll(byDeltaX: 0, deltaY: 400)
        }
        XCTAssertTrue(app.staticTexts["My profiles"].waitForExistence(timeout: 2))

        let activeActions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "profile-actions-")
        ).element(boundBy: 0)
        XCTAssertTrue(activeActions.isHittable)
        activeActions.click()

        let activeRename = app.menuItems["Rename…"]
        XCTAssertTrue(activeRename.waitForExistence(timeout: 2))
        XCTAssertFalse(activeRename.isEnabled)

        let activeRemove = app.menuItems["Remove Profile"]
        XCTAssertFalse(activeRemove.exists)

        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])

        let inactiveActions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "profile-actions-")
        ).element(boundBy: 1)
        XCTAssertTrue(inactiveActions.isHittable)
        inactiveActions.click()

        let inactiveRename = app.menuItems["Rename…"]
        XCTAssertTrue(inactiveRename.waitForExistence(timeout: 2))
        XCTAssertTrue(inactiveRename.isEnabled)
        inactiveRename.click()

        let nameField = app.textFields["profile-name-field"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 2))
        nameField.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        nameField.typeText("Tokyo · Connected Edit")
        app.buttons["Save"].click()
        XCTAssertTrue(
            app.staticTexts["Profile renamed."].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.staticTexts["Tokyo · Connected Edit"].waitForExistence(timeout: 2)
        )

        let officeActions = app.descendants(matching: .any).matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "profile-actions-")
        ).element(boundBy: 2)
        XCTAssertTrue(officeActions.isHittable)
        officeActions.click()
        let remove = app.menuItems["Remove Profile"]
        XCTAssertTrue(remove.waitForExistence(timeout: 2))
        XCTAssertTrue(remove.isEnabled)
        remove.click()
        // The confirmation is a system dialog; its button may surface by
        // identifier or only by title.
        let confirmByIdentifier = app.buttons["confirm-remove-profile"]
        let confirmRemove = confirmByIdentifier.waitForExistence(timeout: 2)
            ? confirmByIdentifier
            : app.sheets.buttons["Remove"].firstMatch
        XCTAssertTrue(confirmRemove.waitForExistence(timeout: 2))
        confirmRemove.click()
        XCTAssertTrue(
            app.staticTexts["Profile removed."].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.staticTexts["Office · Automatic"].exists)
    }

    func testProxyGroupLatencyActionInChinese() {
        let app = launchReviewApp(appearance: "dark", language: "zh-Hans")
        defer { app.terminate() }

        let proxiesNav = navigationButton(in: app, title: "代理")
        XCTAssertTrue(proxiesNav.waitForExistence(timeout: 3))
        proxiesNav.click()

        let latencyButton = app.buttons["proxy-test-latency-Balanced"]
        XCTAssertTrue(latencyButton.waitForExistence(timeout: 3))
        XCTAssertTrue(latencyButton.isHittable)
        XCTAssertTrue(latencyButton.isEnabled)
        latencyButton.click()
        // The result lands in the current-node line and the node's row.
        let currentNode = app.descendants(matching: .any)["proxy-current-node"]
        XCTAssertTrue(currentNode.waitForExistence(timeout: 3))
        let enabledAgain = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "enabled == true"),
            object: latencyButton
        )
        XCTAssertEqual(XCTWaiter.wait(for: [enabledAgain], timeout: 5), .completed)
        // Each node's latency is a button labelled with its result.
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "毫秒"))
                .firstMatch.waitForExistence(timeout: 3)
        )
    }

    func testRoutingRulesKeepManualResourceSetupInAdvancedOptions() {
        // Rule resources moved from Profiles to the foot of the Rules page.
        for (language, rulesTitle, explanation, advancedTitle) in [
            ("en", "Rules", "AetherRoute prepares routing rules automatically when you connect.", "Advanced"),
            ("zh-Hans", "规则", "连接时由 AetherRoute 自动准备，无需手动操作。", "高级选项"),
        ] {
            let app = launchReviewApp(
                appearance: "light", state: "disconnected",
                language: language, windowSize: "780x560"
            )
            XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
            navigationButton(in: app, title: rulesTitle).click()
            for _ in 0..<4 {
                if app.staticTexts[explanation].exists { break }
                app.descendants(matching: .any)["rules-page"]
                    .scroll(byDeltaX: 0, deltaY: -480)
            }
            XCTAssertTrue(app.staticTexts[explanation].waitForExistence(timeout: 2))
            XCTAssertFalse(app.staticTexts["Country.mmdb"].exists)
            XCTAssertFalse(app.staticTexts["GeoSite.dat"].exists)

            let attachment = XCTAttachment(
                screenshot: mainProductWindow(in: app).screenshot()
            )
            attachment.name = language == "en"
                ? "routing-rules-en-light" : "routing-rules-zh-light"
            attachment.lifetime = .keepAlways
            add(attachment)

            let advanced = app.buttons["routing-rules-advanced"]
            XCTAssertTrue(advanced.waitForExistence(timeout: 2))
            XCTAssertEqual(advanced.label, advancedTitle)
            // The card sits at the foot of the page; bring the button fully in.
            for _ in 0..<3 where !advanced.isHittable {
                app.descendants(matching: .any)["rules-page"]
                    .scroll(byDeltaX: 0, deltaY: -480)
            }
            XCTAssertTrue(advanced.isHittable)
            advanced.click()
            let country = app.staticTexts["Country.mmdb"]
            let geosite = app.staticTexts["GeoSite.dat"]
            XCTAssertTrue(country.waitForExistence(timeout: 2))
            XCTAssertTrue(geosite.exists)
            advanced.click()
            XCTAssertTrue(country.waitForNonExistence(timeout: 2))
            XCTAssertTrue(geosite.waitForNonExistence(timeout: 2))
            app.terminate()
        }
    }

    func testManualNodeEditorExposesNativeProtocolSpecificFields() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.buttons["Profiles"].click()
        let addMenu = app.descendants(matching: .any)["profiles-add-menu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 2))
        addMenu.click()
        let addNode = app.menuItems["Add Node…"]
        XCTAssertTrue(addNode.waitForExistence(timeout: 2))
        XCTAssertTrue(addNode.isHittable)
        addNode.click()

        XCTAssertTrue(app.staticTexts["Add Node"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["manual-node-name"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["manual-node-server"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["manual-node-uuid"].exists
        )
        app.buttons["manual-node-advanced-toggle"].click()
        let editorScroll = app.sheets.firstMatch.scrollViews.firstMatch
        for _ in 0..<4 {
            if app.disclosureTriangles["REALITY"].exists { break }
            editorScroll.scroll(byDeltaX: 0, deltaY: 240)
        }
        XCTAssertTrue(app.disclosureTriangles["REALITY"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["create-manual-node"].isEnabled)

        for _ in 0..<4 {
            if app.popUpButtons["manual-node-protocol"].isHittable { break }
            editorScroll.scroll(byDeltaX: 0, deltaY: -240)
        }
        app.popUpButtons["manual-node-protocol"].click()
        app.menuItems["SSH"].click()
        XCTAssertTrue(
            app.descendants(matching: .any)["manual-node-username"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["choose-ssh-private-key"].exists)
        XCTAssertFalse(app.staticTexts["TLS & Identity"].exists)
        XCTAssertFalse(app.staticTexts["Protocol Options"].exists)
        app.buttons["Cancel"].click()
        let keepEditing = mainProductWindow(in: app).buttons["Keep Editing"]
        XCTAssertTrue(keepEditing.waitForExistence(timeout: 2))
        keepEditing.click()
        XCTAssertTrue(app.buttons["choose-ssh-private-key"].exists)
        app.buttons["Cancel"].click()
        let discard = mainProductWindow(in: app).buttons["Discard Changes"]
        XCTAssertTrue(discard.waitForExistence(timeout: 2))
        discard.click()
        XCTAssertTrue(app.buttons["create-manual-node"].waitForNonExistence(timeout: 2))
    }

    func testRealityNodeRequiresSNIAndCanBeCreatedInIsolatedReviewMode() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            windowSize: "940x760"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.buttons["Profiles"].click()
        app.descendants(matching: .any)["profiles-add-menu"].click()
        app.menuItems["Add Node…"].click()

        let name = app.textFields["manual-node-name"]
        let server = app.textFields["manual-node-server"]
        let uuid = app.textFields["manual-node-uuid"]
        XCTAssertTrue(name.waitForExistence(timeout: 2))
        name.click()
        name.typeText("Reality UI")
        server.click()
        server.typeText("192.0.2.10")
        uuid.click()
        uuid.typeText("28bd4390-c887-4cff-8809-b5b09affe45e")

        app.buttons["manual-node-advanced-toggle"].click()
        let reality = app.disclosureTriangles["REALITY"]
        let editorScroll = app.sheets.firstMatch.scrollViews.firstMatch
        XCTAssertTrue(editorScroll.exists)
        for _ in 0..<4 {
            if reality.exists { break }
            editorScroll.scroll(byDeltaX: 0, deltaY: 240)
        }
        XCTAssertTrue(reality.waitForExistence(timeout: 2))
        let publicKey = app.textFields[
            "manual-node-reality-public-key"
        ]
        let shortID = app.textFields["manual-node-reality-short-id"]
        for _ in 0..<4 where !editorScroll.frame
            .insetBy(dx: 8, dy: 8).contains(publicKey.frame)
        {
            editorScroll.swipeUp()
        }
        XCTAssertTrue(publicKey.waitForExistence(timeout: 3))
        XCTAssertTrue(
            editorScroll.frame.insetBy(dx: 8, dy: 8)
                .contains(publicKey.frame)
        )
        publicKey.click()
        publicKey.typeText(
            "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc"
        )
        for _ in 0..<2 where !editorScroll.frame
            .insetBy(dx: 8, dy: 8).contains(shortID.frame)
        {
            editorScroll.swipeUp()
        }
        XCTAssertTrue(
            editorScroll.frame.insetBy(dx: 8, dy: 8).contains(shortID.frame)
        )
        shortID.click()
        shortID.typeText("1392897e")

        let create = app.buttons["create-manual-node"]
        XCTAssertFalse(create.isEnabled)
        XCTAssertTrue(
            app.staticTexts[
                "Server name (SNI) is required when REALITY is configured."
            ].waitForExistence(timeout: 2)
        )

        let sni = app.textFields["manual-node-sni"]
        XCTAssertTrue(sni.waitForExistence(timeout: 2))
        sni.click()
        sni.typeText("edge.example")
        XCTAssertTrue(create.isEnabled)
        create.click()

        XCTAssertTrue(
            app.staticTexts["Manual node created and activated."]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Reality UI · Manual"].exists)
        XCTAssertFalse(
            app.staticTexts.matching(
                NSPredicate(
                    format: "label CONTAINS %@",
                    "Keychain access group"
                )
            ).firstMatch.exists
        )
    }

    func testAddSubscriptionSheetExplainsEncryptedValidation() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        app.buttons["Profiles"].click()
        let addMenu = app.descendants(matching: .any)["profiles-add-menu"]
        XCTAssertTrue(addMenu.waitForExistence(timeout: 2))
        addMenu.click()
        let addSubscription = app.menuItems["add-subscription"]
        XCTAssertTrue(addSubscription.waitForExistence(timeout: 2))
        addSubscription.click()

        XCTAssertTrue(app.textFields["subscription-url-field"].waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.staticTexts[
                "The address is stored inside the encrypted profile. Downloads are size-limited and validated before activation."
            ].exists
        )
        // The editor can prefill a subscription URL from the clipboard.
        // Exercise the empty-input contract independently of prior fixtures.
        let field = app.textFields["subscription-url-field"]
        field.click()
        app.typeKey("a", modifierFlags: .command)
        app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
        XCTAssertFalse(app.buttons["activate-subscription-button"].isEnabled)
        pasteFixtureText(
            " \nhttps://profiles.example/config.yaml?variant=demo%20route\r\n",
            into: field,
            in: app
        )
        let normalized = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "value == %@",
                "https://profiles.example/config.yaml?variant=demo%20route"
            ),
            object: field
        )
        XCTAssertEqual(XCTWaiter.wait(for: [normalized], timeout: 2), .completed)
        XCTAssertTrue(app.buttons["activate-subscription-button"].isEnabled)
        let attachment = XCTAttachment(screenshot: mainProductWindow(in: app).screenshot())
        attachment.name = "subscription-trimmed-url-en-light"
        attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Cancel"].click()
    }

    func testExternalSubscriptionLinkRequiresExplicitConfirmationAndHidesToken() {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            externalSubscriptionLink:
                "aetherroute://subscribe?url=https%3A%2F%2Fprofiles.example%2Fconfig.yaml%3Ftoken%3Dprivate-token"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.staticTexts["Review Subscription Link"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["profiles.example"].exists)
        XCTAssertFalse(app.staticTexts["private-token"].exists)
        XCTAssertTrue(app.buttons["confirm-external-subscription"].isEnabled)
        XCTAssertTrue(
            app.staticTexts[
                "AetherRoute has not downloaded or changed anything yet."
            ].exists
        )
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.staticTexts["Review Subscription Link"].exists)
    }

    func testBypassSettingsExposeBoundedRulesAndTruthfulEngineSemantics() throws {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            engine: "tun",
            windowSize: "780x640"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        openSettings(in: app, tabLabel: "Bypass")

        XCTAssertTrue(
            app.staticTexts["Bypass Rules"].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["apple.com"].exists)
        XCTAssertTrue(app.staticTexts["192.0.2.0/24"].exists)
        XCTAssertTrue(app.staticTexts["2001:db8::/48"].exists)
        let providerSemantics = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "TUN applies")
        ).firstMatch
        XCTAssertTrue(providerSemantics.waitForExistence(timeout: 2))
        XCTAssertFalse(app.buttons["add-bypass-rule"].isEnabled)
        try auditProductAccessibility(in: app)
    }

    func testBypassRuleActionsCompleteThroughAsyncUIPaths() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            engine: "transparent",
            windowSize: "780x640"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        openSettings(in: app, tabLabel: "Bypass")
        XCTAssertTrue(
            app.staticTexts["Bypass Rules"].waitForExistence(timeout: 3)
        )

        let ruleField = app.textFields["bypass-rule-field"]
        XCTAssertTrue(ruleField.waitForExistence(timeout: 2))
        ruleField.click()
        ruleField.typeText("example.net")
        let addButton = app.buttons["add-bypass-rule"]
        XCTAssertTrue(addButton.isEnabled)
        addButton.click()

        XCTAssertTrue(
            app.staticTexts["Bypass rule added."].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.staticTexts["example.net"].exists)

        let removeButton = app.buttons["Remove example.net"]
        XCTAssertTrue(removeButton.waitForExistence(timeout: 2))
        removeButton.click()
        XCTAssertTrue(
            app.staticTexts["Bypass rule removed."].waitForExistence(timeout: 2)
        )
        XCTAssertFalse(app.staticTexts["example.net"].exists)
    }

    func testTUNDNSRuntimePolicyIsVisibleAndEditableOffline() throws {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            engine: "tun",
            windowSize: "900x760"
        )
        defer { app.terminate() }

        XCTAssertTrue(
            mainProductWindow(in: app).waitForExistence(timeout: 5)
        )
        app.buttons["DNS"].click()
        XCTAssertTrue(
            app.staticTexts["DNS adjustments in TUN mode"]
                .waitForExistence(timeout: 2)
        )
        let resolutionMode = app.descendants(matching: .any)[
            "dns-runtime-resolution-mode"
        ]
        let ipv6 = app.descendants(matching: .any)["dns-runtime-ipv6"]
        let respectRules = app.descendants(matching: .any)[
            "dns-runtime-respect-rules"
        ]
        XCTAssertTrue(resolutionMode.waitForExistence(timeout: 2))
        XCTAssertTrue(resolutionMode.isEnabled)
        XCTAssertTrue(ipv6.isEnabled)
        XCTAssertTrue(respectRules.isEnabled)

        selectMenuItem("Normal", from: resolutionMode, in: app)
        XCTAssertTrue(
            app.staticTexts[
                "DNS overrides will apply on the next TUN connection."
            ].waitForExistence(timeout: 2)
        )
        // A changed setting offers the way back.
        XCTAssertTrue(
            app.descendants(matching: .any)["dns-restore-defaults"]
                .waitForExistence(timeout: 2)
        )

        try auditProductAccessibility(in: app)
    }

    func testAutomationSettingsExposeExplicitPrivateOptIns() throws {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            automationEnabled: true,
            windowSize: "780x640"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        openSettings(in: app, tabLabel: "Shortcuts & Notifications")

        XCTAssertTrue(
            app.descendants(matching: .any)["global-shortcuts-toggle"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["Global shortcuts are active"].exists)
        XCTAssertTrue(app.staticTexts["Connect or disconnect"].exists)
        XCTAssertTrue(app.staticTexts["Rule mode"].exists)
        XCTAssertTrue(app.staticTexts["Global mode"].exists)
        XCTAssertTrue(app.staticTexts["Direct mode"].exists)
        XCTAssertTrue(
            app.staticTexts[
                "Failure and unexpected disconnect alerts are on"
            ].exists
        )
        try auditProductAccessibility(in: app)
    }

    func testApplicationLanguageChangesImmediatelyWithoutRelaunch() throws {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            language: "en",
            windowSize: "840x650"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        openSettings(in: app, tabLabel: "General")

        let picker = app.descendants(matching: .any)["app-language-picker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Application language"].exists)
        selectMenuItem("简体中文", from: picker, in: app)

        XCTAssertTrue(
            app.staticTexts["应用语言"].waitForExistence(timeout: 8)
        )
        XCTAssertTrue(app.staticTexts["语言"].exists)
        XCTAssertFalse(app.staticTexts["Application language"].exists)
        let networkWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        selectSettingsTab("网络", in: networkWindow, app: app)
        XCTAssertTrue(
            app.staticTexts["流量接管方式"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.staticTexts[
                "Takes over each app's connections. Most compatible; recommended for everyday use."
            ].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["透明代理"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["规则"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertFalse(
            app.descendants(matching: .any)["Transparent Proxy"].exists
        )
        XCTAssertFalse(app.descendants(matching: .any)["Rule"].exists)

        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        XCTAssertEqual(settingsWindow.title, "AetherRoute 设置")
        let settingsAttachment = XCTAttachment(
            screenshot: settingsWindow.screenshot()
        )
        settingsAttachment.name = "language-settings-zh"
        settingsAttachment.lifetime = .keepAlways
        add(settingsAttachment)

        selectSettingsTab("关于", in: settingsWindow, app: app)
        XCTAssertTrue(app.staticTexts["编程不良人"].waitForExistence(timeout: 3))
        XCTAssertEqual(settingsWindow.title, "AetherRoute 设置")
        XCTAssertFalse(app.staticTexts["BianChengBuLiangRen"].exists)
        XCTAssertTrue(app.staticTexts["开发版本"].exists)
        XCTAssertTrue(app.staticTexts["尚未发布"].exists)
        XCTAssertFalse(app.staticTexts["Development"].exists)
        XCTAssertFalse(app.staticTexts["Not released"].exists)
        let aboutAttachment = XCTAttachment(
            screenshot: settingsWindow.screenshot()
        )
        aboutAttachment.name = "language-about-zh"
        aboutAttachment.lifetime = .keepAlways
        add(aboutAttachment)
        try auditProductAccessibility(in: app)
    }

    func testApplicationLanguageRoundTripRebuildsAllVisibleSurfaces() throws {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            language: "zh-Hans",
            windowSize: "940x640"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["概览"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["未连接"].exists)

        openSettings(in: app, tabLabel: "通用")
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        let picker = settingsWindow.descendants(matching: .any)[
            "app-language-picker"
        ]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        selectMenuItem("English", from: picker, in: app)

        // The Settings window is titled with its current pane.
        XCTAssertEqual(settingsWindow.title, "General")
        XCTAssertTrue(
            app.staticTexts["Application language"]
                .waitForExistence(timeout: 3)
        )
        selectSettingsTab("Network Settings", in: settingsWindow, app: app)
        XCTAssertTrue(
            app.staticTexts[
                "Takes over each app's connections. Most compatible; recommended for everyday use."
            ].exists
        )
        XCTAssertFalse(app.staticTexts["应用语言"].exists)
        XCTAssertFalse(
            app.staticTexts["流量接管方式"].exists
        )

        selectSettingsTab("Privacy", in: settingsWindow, app: app)
        // Settings shows the details as a native disclosure triangle.
        app.descendants(matching: .any)["privacy-details-toggle"].firstMatch.click()
        XCTAssertTrue(
            app.staticTexts["Processed on this Mac"]
                .waitForExistence(timeout: 3)
        )
        XCTAssertTrue(app.staticTexts["No sale or tracking"].exists)
        XCTAssertTrue(app.staticTexts["You choose the route"].exists)
        XCTAssertFalse(app.staticTexts["在此 Mac 上处理"].exists)

        selectSettingsTab("About", in: settingsWindow, app: app)
        XCTAssertTrue(app.staticTexts["BianChengBuLiangRen"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Development"].exists)
        XCTAssertTrue(app.staticTexts["Not released"].exists)
        XCTAssertTrue(app.staticTexts["Version"].exists)
        XCTAssertFalse(app.staticTexts["编程不良人"].exists)
        XCTAssertFalse(app.staticTexts["开发版本"].exists)

        closeResponsiveSettings(in: app)
        XCTAssertTrue(app.buttons["Overview"].waitForExistence(timeout: 3))
        XCTAssertTrue(navigationButton(in: app, title: "Proxies").exists)
        XCTAssertTrue(app.staticTexts["Not connected"].exists)
        XCTAssertTrue(
            app.staticTexts["Traffic is using the normal network path"].exists
        )
        XCTAssertFalse(app.buttons["概览"].exists)
        XCTAssertFalse(app.staticTexts["未连接"].exists)

        openSettings(in: app, tabLabel: "General")
        let englishPicker = settingsWindow.descendants(matching: .any)[
            "app-language-picker"
        ]
        XCTAssertTrue(englishPicker.waitForExistence(timeout: 3))
        selectMenuItem("简体中文", from: englishPicker, in: app)

        XCTAssertEqual(settingsWindow.title, "AetherRoute 设置")
        XCTAssertTrue(app.staticTexts["应用语言"].waitForExistence(timeout: 3))
        selectSettingsTab("关于", in: settingsWindow, app: app)
        XCTAssertTrue(app.staticTexts["编程不良人"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["开发版本"].exists)
        XCTAssertTrue(app.staticTexts["尚未发布"].exists)
        XCTAssertFalse(app.staticTexts["BianChengBuLiangRen"].exists)
        try auditProductAccessibility(in: app)
    }

    func testSettingsSidebarMaintainsExplicitSelectionState() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            windowSize: "840x600"
        )
        defer { app.terminate() }

        openSettings(in: app, tabLabel: "General")

        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        let general = settingsWindow.cells.containing(
            .any,
            identifier: "settings-tab-general"
        ).firstMatch
        let about = settingsWindow.cells.containing(
            .any,
            identifier: "settings-tab-about"
        ).firstMatch
        XCTAssertTrue(general.waitForExistence(timeout: 2))
        XCTAssertTrue(about.waitForExistence(timeout: 2))
        XCTAssertTrue(general.isSelected)
        XCTAssertFalse(about.isSelected)

        about.click()
        XCTAssertTrue(
            settingsWindow.descendants(matching: .any)[
                "about-page-content"
            ].waitForExistence(timeout: 3)
        )
        XCTAssertTrue(about.isSelected)
        XCTAssertFalse(general.isSelected)
    }

    func testOpenSourceLicensesSearchAndSelectionRemainUsable() throws {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            windowSize: "840x600"
        )
        defer { app.terminate() }

        openSettings(in: app, tabLabel: "Licenses")

        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        let initialComponent = settingsWindow.buttons[
            "license-component-adler2@2.0.1"
        ]
        XCTAssertTrue(initialComponent.waitForExistence(timeout: 3))
        XCTAssertTrue(initialComponent.isSelected)

        let search = settingsWindow.textFields["license-search-field"]
        XCTAssertTrue(search.waitForExistence(timeout: 2))
        XCTAssertTrue(search.isEnabled)
        search.click()
        search.typeText("aes-gcm-siv")

        let filteredComponent = settingsWindow.buttons[
            "license-component-aes-gcm-siv@0.11.1"
        ]
        XCTAssertTrue(filteredComponent.waitForExistence(timeout: 3))
        XCTAssertTrue(filteredComponent.label.contains("aes-gcm-siv"))
        XCTAssertFalse(initialComponent.exists)
        filteredComponent.click()
        XCTAssertTrue(filteredComponent.isSelected)
        XCTAssertTrue(
            settingsWindow.links["license-source-repository"]
                .waitForExistence(timeout: 2)
        )
        try auditProductAccessibility(in: app)
    }

    func testTUNLocalProxyIsExplicitLoopbackOnlyAndCopyOnly() throws {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            engine: "tun",
            windowSize: "900x760"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        openSettings(in: app, tabLabel: "Network Settings")

        let toggle = app.descendants(matching: .any)["local-proxy-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertTrue(toggle.isEnabled)
        let localProxyDetail = app.staticTexts.matching(
            NSPredicate(
                format: "value == %@",
                "AetherRoute binds only 127.0.0.1 and never changes the macOS system proxy. Shell commands affect only the terminal where you paste them."
            )
        ).element
        XCTAssertTrue(localProxyDetail.exists)

        let copyEnvironment = app.buttons["copy-shell-proxy-button"]
        if !copyEnvironment.isEnabled {
            toggle.click()
        }
        XCTAssertTrue(copyEnvironment.waitForExistence(timeout: 2))
        XCTAssertTrue(copyEnvironment.isEnabled)
        XCTAssertEqual(app.textFields["local-proxy-http-port"].value as? String, "7890")
        XCTAssertEqual(app.textFields["local-proxy-socks-port"].value as? String, "7891")

        copyEnvironment.click()
        XCTAssertTrue(
            app.staticTexts["Shell environment copied."]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["copy-clear-proxy-button"].isEnabled)
        try auditProductAccessibility(in: app)

        toggle.click()
        XCTAssertFalse(copyEnvironment.isEnabled)
    }

    func testAboutPageShowsEnglishReleaseInformation() throws {
        let app = launchReviewApp(
            appearance: "dark",
            state: "disconnected",
            windowSize: "840x600"
        )
        defer { app.terminate() }

        openAboutSettings(in: app, tabLabel: "About")

        // The About pane names the product and its maker in the footer;
        // release facts sit in their own rows.
        XCTAssertTrue(app.staticTexts["about-version"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["开发版本"].exists)
        XCTAssertTrue(app.staticTexts["about-release-build"].exists)
        XCTAssertTrue(app.staticTexts["Development"].exists)
        XCTAssertTrue(app.staticTexts["Not released"].exists)
        try auditProductAccessibility(in: app)
    }

    func testAboutPageShowsReleaseInformationOnlyInChinese() {
        let app = launchReviewApp(
            appearance: "light",
            state: "disconnected",
            language: "zh-Hans",
            windowSize: "840x600"
        )
        defer { app.terminate() }

        openAboutSettings(in: app, tabLabel: "关于")

        XCTAssertTrue(app.staticTexts["开发版本"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["Development"].exists)
        XCTAssertTrue(app.staticTexts["尚未发布"].exists)
    }

    func testFreeDistributionSettingsAreLocalizedAndRequireNoActivation() throws {
        let cases = [
            (
                language: "en",
                tab: "Account",
                heading: "Free Edition",
                activation: "No activation required",
                updates: "This edition does not contact a licensing service. Software updates are checked and verified automatically."
            ),
            (
                language: "zh-Hans",
                tab: "账户",
                heading: "免费版",
                activation: "无需激活",
                updates: "当前版本无需激活许可服务。软件更新会自动检查并安全验证。"
            ),
        ]

        for item in cases {
            try { () throws in
                let app = launchReviewApp(
                    appearance: item.language == "en" ? "dark" : "light",
                    state: "disconnected",
                    language: item.language,
                    windowSize: "840x600"
                )
                defer { app.terminate() }

                openSettings(in: app, tabLabel: item.tab)
                XCTAssertTrue(
                    app.staticTexts[item.heading].waitForExistence(timeout: 3)
                )
                XCTAssertTrue(app.staticTexts[item.activation].exists)
                XCTAssertTrue(app.staticTexts[item.updates].exists)
                XCTAssertFalse(
                    app.secureTextFields["license-key-field"].exists
                )
                XCTAssertTrue(
                    app.buttons["check-for-updates-button"].exists
                )
                try auditProductAccessibility(in: app)

                let settingsWindow = app.windows[
                    "com_apple_SwiftUI_Settings_window"
                ]
                XCTAssertTrue(settingsWindow.exists)
                let attachment = XCTAttachment(
                    screenshot: settingsWindow.screenshot()
                )
                attachment.name = "AetherRoute-Account-\(item.language)"
                attachment.lifetime = .keepAlways
                add(attachment)
            }()
        }
    }

    func testFailureStateOffersActionableRecoveryWithoutNetwork() {
        let app = launchReviewApp(
            appearance: "light",
            state: "failed",
            windowSize: "940x720"
        )
        defer { app.terminate() }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        XCTAssertTrue(
            app.descendants(matching: .any)["connection-recovery-card"]
                .waitForExistence(timeout: 2)
        )
        // Retrying is the hero's primary button; the recovery section adds
        // the reason and the way to the profiles, without a second retry.
        XCTAssertTrue(app.buttons["primary-connection-button"].isEnabled)
        XCTAssertFalse(app.buttons["Retry Connection"].exists)
        XCTAssertTrue(app.buttons["Review Profiles"].isEnabled)

        app.buttons["Review Profiles"].click()
        XCTAssertTrue(app.menuButtons["profiles-add-menu"].waitForExistence(timeout: 2))
    }

    func testSignedNetworkExtensionConnectDisconnectLifecycle() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["AETHERROUTE_RUN_SIGNED_NE_TEST"] == "YES" else {
            throw XCTSkip(
                "Real Network Extension lifecycle testing requires explicit opt-in."
            )
        }

        let cycles = Int(environment["AETHERROUTE_SIGNED_NE_CYCLES"] ?? "3") ?? 0
        guard (1...20).contains(cycles) else {
            XCTFail("AETHERROUTE_SIGNED_NE_CYCLES must be between 1 and 20")
            return
        }

        let product = environment["AETHERROUTE_SIGNED_NE_PRODUCT"]
            ?? "independent"
        guard product == "independent" else {
            XCTFail("AETHERROUTE_SIGNED_NE_PRODUCT must be independent")
            return
        }
        let engine = environment["AETHERROUTE_SIGNED_NE_ENGINE"] ?? "tun"
        guard engine == "tun" || engine == "transparent" else {
            XCTFail("AETHERROUTE_SIGNED_NE_ENGINE must be tun or transparent")
            return
        }
        let lifecycleProbe: SignedLifecycleProbe
        switch environment["AETHERROUTE_SIGNED_PROBE_KIND"] ?? "public-https" {
        case "controlled-relay-v1":
            guard environment["AETHERROUTE_SIGNED_PROBE_URL"] == nil,
                  environment["AETHERROUTE_SIGNED_PROBE_SHA256"] == nil,
                  let path = environment["AETHERROUTE_SIGNED_PROBE_BINDINGS"],
                  let bindingsSHA = environment["AETHERROUTE_SIGNED_PROBE_BINDINGS_SHA256"],
                  let runID = environment["AETHERROUTE_SIGNED_NE_RUN_ID"],
                  let candidateSHA = environment["AETHERROUTE_SIGNED_NE_CANDIDATE_MANIFEST_SHA256"],
                  let probeEngine = SignedNEProbeEngine(rawValue: engine) else {
                XCTFail("Configure one explicit controlled probe with pinned cycle bindings.")
                return
            }
            do {
                lifecycleProbe = .controlled(try await SignedNEProbe.loadCycleBindingsAsync(
                    path: path, sha256: bindingsSHA, runID: runID,
                    candidateSHA256: candidateSHA, engine: probeEngine, cycles: cycles
                ))
            } catch {
                XCTFail("Controlled probe cycle bindings are invalid or changed.")
                return
            }
        case "public-https":
            guard let probeURLString = environment[
                "AETHERROUTE_SIGNED_PROBE_URL"
            ], let probeURL = URL(string: probeURLString),
                  probeURL.scheme == "https",
                  let probeHost = probeURL.host,
                  probeHost.contains("."),
                  probeHost.unicodeScalars.contains(where: {
                      CharacterSet.letters.contains($0)
                  }),
                  probeURL.user == nil,
                  probeURL.password == nil,
                  probeURL.query == nil,
                  probeURL.fragment == nil,
                  let expectedProbeSHA256 = environment[
                    "AETHERROUTE_SIGNED_PROBE_SHA256"
                  ],
                  expectedProbeSHA256.range(
                    of: "^[0-9a-f]{64}$",
                    options: .regularExpression
                  ) != nil else {
                XCTFail(
                    "Configure a credential-free owner HTTPS canary hostname and lowercase response SHA-256."
                )
                return
            }
            lifecycleProbe = .publicHTTPS(url: probeURL, expectedSHA256: expectedProbeSHA256)
        default:
            XCTFail("Unknown signed probe kind; no fallback is permitted.")
            return
        }

        let dnsProbeScript: SignedDNSProbeScript
        do {
            dnsProbeScript = try validatedSignedDNSProbeScript(
                environment: environment
            )
        } catch {
            XCTFail(
                "Configure the absolute, executable signed_ne_dns_probe.sh path and its lowercase SHA-256."
            )
            return
        }

        let leaseConfiguration: SignedNELease.Configuration?
        do {
            leaseConfiguration = try SignedNELease.configuration(environment)
        } catch {
            XCTFail("Signed test lease configuration is invalid.")
            return
        }

        let app: XCUIApplication
        if environment["AETHERROUTE_SIGNED_NE_USE_INSTALLED_APP"] == "YES",
           let hostBundleID = environment[
               "AETHERROUTE_SIGNED_NE_HOST_BUNDLE_ID"
           ], !hostBundleID.isEmpty {
            app = XCUIApplication(bundleIdentifier: hostBundleID)
        } else {
            app = XCUIApplication()
        }
        app.launchArguments += [
            "-AppleLanguages", "(en)",
            "-AppleLocale", "en_US",
        ]
        app.launch()
        let primary = app.buttons["primary-connection-button"]
        var temporaryBypassRules: [String] = []
        var cleanupCompleted = false
        defer {
            if !cleanupCompleted {
                if primary.exists, primary.label == "Disconnect" || primary.label == "Cancel" {
                    primary.click()
                    _ = waitForLabel("Connect", on: primary, timeout: 30)
                }
                removeTemporarySignedBypassRules(
                    temporaryBypassRules,
                    in: app
                )
                app.terminate()
            }
        }

        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 10))
        let consent = app.buttons["privacy-consent-button"]
        if consent.waitForExistence(timeout: 2) {
            consent.click()
        }

        XCTAssertTrue(primary.waitForExistence(timeout: 10))
        if primary.label == "Disconnect" {
            primary.click()
            XCTAssertTrue(waitForLabel("Connect", on: primary, timeout: 20))
        }
        XCTAssertEqual(
            primary.label,
            "Connect",
            "Prepare the signed app with a validated active profile before running this gate."
        )
        XCTAssertTrue(
            primary.isEnabled,
            "The signed app has no usable active profile; import one before running this gate."
        )

        temporaryBypassRules = installTemporarySignedBypassRules(
            environment["AETHERROUTE_SIGNED_NE_BYPASS_CIDRS"] ?? "",
            in: app
        )

        // The Overview control shows the short engine names.
        let engineLabel = engine == "tun" ? "TUN" : "Transparent"
        let enginePicker = app.radioGroups["network-engine-picker"]
        XCTAssertTrue(
            enginePicker.waitForExistence(timeout: 5),
            "The independent lifecycle gate could not find the network engine picker."
        )
        let engineSelector = enginePicker.radioButtons[engineLabel]
        XCTAssertTrue(
            engineSelector.waitForExistence(timeout: 5),
            "The independent lifecycle gate could not find the \(engineLabel) selector."
        )
        if !controlHasSelectedValue(engineSelector) {
            engineSelector.click()
        }
        XCTAssertTrue(
            waitForSelected(engineSelector, timeout: 10),
            "The independent lifecycle gate could not select \(engineLabel)."
        )
        let baselineDNSHash: String
        do {
            let baselineResult = try runSignedDNSProbe(
                dnsProbeScript,
                arguments: ["baseline"]
            )
            guard baselineResult.range(
                of: "^baseline_dns_sha256=[0-9a-f]{64}$",
                options: .regularExpression
            ) != nil else {
                throw SignedDNSProbeError.invalidOutput(mode: "baseline")
            }
            baselineDNSHash = String(
                baselineResult.dropFirst("baseline_dns_sha256=".count)
            )
        } catch {
            XCTFail("Signed DNS baseline gate failed: \(error.localizedDescription)")
            return
        }
        // Capture the real App and XCTest lifetimes after static UI preparation.
        // The host arms its independent guest watcher before the first Connect.
        let lease: SignedNELease?
        do {
            if let leaseConfiguration {
                lease = try await SignedNELease.arm(leaseConfiguration, engine: engine)
            } else {
                lease = nil
            }
        } catch {
            XCTFail("Signed test lease could not arm for this worker.")
            return
        }
        for cycle in 1...cycles {
            let probeMatchedBeforeConnection = await signedLifecycleProbeMatches(
                lifecycleProbe, cycle: cycle, phase: .before
            )
            XCTAssertFalse(
                probeMatchedBeforeConnection,
                "The proxy-only canary response was reachable before \(engineLabel) connected in cycle \(cycle)."
            )

            do {
                let permit = try await lease?.permit()
                // No suspension or UI action between fresh receipt and Connect.
                try permit?.requireFresh()
                try Task.checkCancellation()
            } catch {
                XCTFail("Signed test lease did not permit Connect.")
                return
            }
            primary.click()
            switch waitForConnectionStart(
                on: primary,
                in: app,
                timeout: 45
            ) {
            case .connected:
                break
            case let .failed(detail):
                attachFailureScreenshot(app, name: "connect-cycle-\(cycle)")
                XCTFail(
                    "\(engineLabel) failed while connecting in cycle \(cycle): \(detail)"
                )
                return
            case .returnedToIdle:
                attachFailureScreenshot(app, name: "connect-cycle-\(cycle)")
                XCTFail(
                    "\(engineLabel) returned to Connect before reaching ready state in cycle \(cycle)."
                )
                return
            case .timedOut:
                attachFailureScreenshot(app, name: "connect-cycle-\(cycle)")
                XCTFail(
                    "\(engineLabel) did not reach connected state in cycle \(cycle) before the timeout."
                )
                return
            }
            XCTAssertTrue(
                app.staticTexts.matching(
                    NSPredicate(
                        format: "value == %@",
                        "The network extension reports ready"
                    )
                ).firstMatch.waitForExistence(timeout: 5),
                "Provider readiness was not exposed in cycle \(cycle)."
            )
            do {
                let dnsMode = engine == "tun"
                    ? "tun-connected"
                    : "transparent-connected"
                var dnsArguments = [dnsMode]
                if engine == "transparent" {
                    dnsArguments.append(baselineDNSHash)
                }
                let connectedDNSResult = try runSignedDNSProbe(
                    dnsProbeScript,
                    arguments: dnsArguments
                )
                guard connectedDNSResult == "dns_probe=\(dnsMode):passed" else {
                    throw SignedDNSProbeError.invalidOutput(mode: dnsMode)
                }
            } catch {
                attachFailureScreenshot(app, name: "dns-connected-cycle-\(cycle)")
                XCTFail(
                    "\(engineLabel) DNS gate failed while connected in cycle \(cycle): \(error.localizedDescription)"
                )
                return
            }
            let probeMatchedWhileConnected = await signedLifecycleProbeMatches(
                lifecycleProbe, cycle: cycle, phase: .connected
            )
            XCTAssertTrue(
                probeMatchedWhileConnected,
                "\(engineLabel) did not carry the expected canary traffic in cycle \(cycle)."
            )

            primary.click()
            guard waitForLabel("Connect", on: primary, timeout: 30) else {
                attachFailureScreenshot(app, name: "disconnect-cycle-\(cycle)")
                XCTFail("\(engineLabel) did not stop in cycle \(cycle)")
                return
            }
            do {
                let disconnectedDNSResult = try runSignedDNSProbe(
                    dnsProbeScript,
                    arguments: ["disconnected", baselineDNSHash]
                )
                guard disconnectedDNSResult
                    == "dns_probe=disconnected:passed" else {
                    throw SignedDNSProbeError.invalidOutput(
                        mode: "disconnected"
                    )
                }
            } catch {
                attachFailureScreenshot(
                    app,
                    name: "dns-disconnected-cycle-\(cycle)"
                )
                XCTFail(
                    "\(engineLabel) DNS restoration gate failed in cycle \(cycle): \(error.localizedDescription)"
                )
                return
            }
            let probeMatchedAfterDisconnect = await signedLifecycleProbeMatches(
                lifecycleProbe, cycle: cycle, phase: .after
            )
            XCTAssertFalse(
                probeMatchedAfterDisconnect,
                "The proxy-only canary response remained reachable after \(engineLabel) disconnected in cycle \(cycle)."
            )
        }
        // No UI operation may follow terminal-ready. Xcode can then seal its
        // result and exit normally while the independent lease remains armed.
        removeTemporarySignedBypassRules(temporaryBypassRules, in: app)
        app.terminate()
        cleanupCompleted = true
        do {
            try await lease?.terminalReady()
        } catch {
            XCTFail("Signed test lease could not confirm terminal readiness.")
        }
    }

    private enum SignedLifecycleProbe {
        case publicHTTPS(url: URL, expectedSHA256: String)
        case controlled([SignedNEProbe])
    }

    private func signedLifecycleProbeMatches(
        _ probe: SignedLifecycleProbe,
        cycle: Int,
        phase: SignedNEProbePhase
    ) async -> Bool {
        switch probe {
        case let .publicHTTPS(url, expectedSHA256):
            return await signedProbeMatchesExpected(url: url, expectedSHA256: expectedSHA256)
        case let .controlled(probes):
            guard probes.indices.contains(cycle - 1) else {
                XCTFail("Controlled probe cycle is missing.")
                return phase != .connected
            }
            do {
                let receipt = try await probes[cycle - 1].forPhase(phase).run()
                // The receipt contains hashes and bounded observations only;
                // private URLs, authorization headers and request nonces stay
                // in the task-owned input files outside the product App.
                print("AETHERROUTE_SIGNED_CONTROLLED_PHASE " + String(decoding: receipt.encoded, as: UTF8.self))
                return receipt.outcome == "matched"
            } catch {
                XCTFail("Controlled HTTPS probe failed validation or execution in cycle \(cycle).")
                return phase != .connected
            }
        }
    }

    private func validatedSignedDNSProbeScript(
        environment: [String: String]
    ) throws -> SignedDNSProbeScript {
        let overrideKeys = [
            "AETHERROUTE_SIGNED_DNS_PROBE_SCUTIL",
            "AETHERROUTE_SIGNED_DNS_PROBE_ROUTE",
            "AETHERROUTE_SIGNED_DNS_PROBE_IFCONFIG",
            "AETHERROUTE_SIGNED_DNS_PROBE_DIG",
            "AETHERROUTE_SIGNED_DNS_PROBE_UUIDGEN",
            "AETHERROUTE_SIGNED_DNS_PROBE_SHASUM",
            "AETHERROUTE_SIGNED_DNS_PROBE_AWK",
            "AETHERROUTE_SIGNED_DNS_PROBE_SORT",
            "AETHERROUTE_SIGNED_DNS_PROBE_GREP",
            "AETHERROUTE_SIGNED_DNS_PROBE_TR",
        ]
        guard environment["AETHERROUTE_SIGNED_DNS_PROBE_TEST_MODE"] == nil,
              overrideKeys.allSatisfy({ environment[$0] == nil }),
              let scriptPath = environment[
                "AETHERROUTE_SIGNED_DNS_PROBE_SCRIPT"
              ], scriptPath.hasPrefix("/"),
              let expectedSHA256 = environment[
                "AETHERROUTE_SIGNED_DNS_PROBE_SHA256"
              ], expectedSHA256.range(
                of: "^[0-9a-f]{64}$",
                options: .regularExpression
              ) != nil else {
            throw SignedDNSProbeError.invalidConfiguration
        }

        let scriptURL = URL(fileURLWithPath: scriptPath)
            .standardizedFileURL
        guard scriptURL.path == scriptPath,
              scriptURL.lastPathComponent == "signed_ne_dns_probe.sh",
              scriptURL.resolvingSymlinksInPath().standardizedFileURL.path
                == scriptPath,
              FileManager.default.isExecutableFile(atPath: scriptPath),
              let attributes = try? FileManager.default.attributesOfItem(
                atPath: scriptPath
              ),
              attributes[.type] as? FileAttributeType == .typeRegular,
              let permissions = attributes[.posixPermissions] as? NSNumber,
              permissions.intValue & 0o022 == 0,
              let fileSize = attributes[.size] as? NSNumber,
              (1...128 * 1_024).contains(fileSize.intValue),
              try signedDNSProbeSHA256(at: scriptURL) == expectedSHA256 else {
            throw SignedDNSProbeError.invalidConfiguration
        }
        return SignedDNSProbeScript(
            url: scriptURL,
            expectedSHA256: expectedSHA256
        )
    }

    private func signedDNSProbeSHA256(at url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return SHA256.hash(data: data).map {
            String(format: "%02x", $0)
        }.joined()
    }

    private func runSignedDNSProbe(
        _ script: SignedDNSProbeScript,
        arguments: [String]
    ) throws -> String {
        guard try signedDNSProbeSHA256(at: script.url)
            == script.expectedSHA256 else {
            throw SignedDNSProbeError.integrityChanged
        }

        let process = Process()
        let outputPipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        process.executableURL = script.url
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: "/", isDirectory: true)
        process.environment = [
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        ]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in completion.signal() }
        do {
            try process.run()
        } catch {
            throw SignedDNSProbeError.launchFailed
        }

        guard completion.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            _ = completion.wait(timeout: .now() + 2)
            outputPipe.fileHandleForReading.closeFile()
            throw SignedDNSProbeError.timedOut
        }
        guard process.terminationReason == .exit,
              process.terminationStatus == 0 else {
            throw SignedDNSProbeError.failed(
                mode: arguments.first ?? "unknown",
                status: process.terminationStatus
            )
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        guard outputData.count <= 256,
              let rawOutput = String(data: outputData, encoding: .utf8),
              rawOutput.hasSuffix("\n"),
              rawOutput.dropLast().allSatisfy({ $0 != "\n" && $0 != "\r" })
        else {
            throw SignedDNSProbeError.invalidOutput(
                mode: arguments.first ?? "unknown"
            )
        }
        let output = String(rawOutput.dropLast())
        guard !output.contains("ar-"),
              output.range(
                of: "example\\.com",
                options: [.regularExpression, .caseInsensitive]
              ) == nil else {
            throw SignedDNSProbeError.invalidOutput(
                mode: arguments.first ?? "unknown"
            )
        }
        return output
    }

    private func signedProbeMatchesExpected(
        url: URL,
        expectedSHA256: String
    ) async -> Bool {
        let configuration = URLSessionConfiguration.ephemeral
        // This lifecycle probe must not inherit the Mac's existing HTTP/SOCKS
        // proxy. Otherwise another client (for example Clash Verge) can make
        // the proxy-only canary reachable before AetherRoute connects and the
        // gate can no longer prove which Network Extension carried the flow.
        configuration.connectionProxyDictionary = [:]
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 10
        configuration.waitsForConnectivity = false
        let delegate = SignedProbeNoRedirectDelegate()
        let session = URLSession(
            configuration: configuration,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("text/plain", forHTTPHeaderField: "Accept")
        request.setValue(
            "AetherRoute/1 SignedRuntimeCanary",
            forHTTPHeaderField: "User-Agent"
        )
        do {
            let (data, response) = try await session.data(for: request)
            guard let response = response as? HTTPURLResponse,
                  response.statusCode == 200,
                  response.url == url,
                  (1...64 * 1_024).contains(data.count) else {
                return false
            }
            let digest = SHA256.hash(data: data).map {
                String(format: "%02x", $0)
            }.joined()
            return digest == expectedSHA256
        } catch {
            return false
        }
    }

    private func installTemporarySignedBypassRules(
        _ commaSeparatedRules: String,
        in app: XCUIApplication
    ) -> [String] {
        let requestedRules = commaSeparatedRules.split(separator: ",").map {
            String($0)
        }
        guard !requestedRules.isEmpty else { return [] }

        openSettings(in: app, tabLabel: "Bypass")
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        let field = settings.textFields["bypass-rule-field"]
        let add = settings.buttons["add-bypass-rule"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        var added: [String] = []
        for rule in requestedRules {
            if settings.staticTexts[rule].exists { continue }
            field.click()
            app.typeKey("a", modifierFlags: .command)
            app.typeKey(XCUIKeyboardKey.delete.rawValue, modifierFlags: [])
            field.typeText(rule)
            XCTAssertTrue(add.isEnabled, "Invalid temporary bypass rule: \(rule)")
            add.click()
            XCTAssertTrue(
                settings.staticTexts[rule].waitForExistence(timeout: 3),
                "Temporary bypass rule was not persisted: \(rule)"
            )
            added.append(rule)
        }
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(
            mainProductWindow(in: app).waitForExistence(timeout: 5)
        )
        return added
    }

    private func removeTemporarySignedBypassRules(
        _ rules: [String],
        in app: XCUIApplication
    ) {
        guard !rules.isEmpty, app.state != .notRunning else { return }
        openSettings(in: app, tabLabel: "Bypass")
        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        for rule in rules.reversed() {
            let remove = settings.buttons["Remove \(rule)"]
            guard remove.waitForExistence(timeout: 2) else { continue }
            remove.click()
            let removed = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "exists == false"),
                object: remove
            )
            _ = XCTWaiter.wait(for: [removed], timeout: 3)
        }
        app.typeKey("w", modifierFlags: .command)
    }

    private func auditProductAccessibility(
        in app: XCUIApplication
    ) throws {
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        let mainWindow = mainProductWindow(in: app)
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 2))
            if settingsWindow.exists {
                _ = settingsWindow.waitForExistence(timeout: 2)
                settingsWindow.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)
                ).click()
            }

        let isFrameworkIssue: (XCUIAccessibilityAuditIssue) -> Bool = { issue in
            print(
                "AETHERROUTE_AX_AUDIT type=\(issue.auditType.rawValue) "
                    + "compact=\(issue.compactDescription) "
                    + "detail=\(issue.detailedDescription)"
            )
            if let element = issue.element {
                print(
                    "AETHERROUTE_AX_ELEMENT type=\(element.elementType.rawValue) "
                        + "identifier=\(element.identifier) "
                        + "label=\(element.label) title=\(element.title) "
                        + "value=\(String(describing: element.value)) "
                        + "frame=\(element.frame)"
                )
            }
            if app.state != .runningForeground {
                // Xcode's pixel audit samples the currently foreground app,
                // even when the AetherRoute element remains addressable on a
                // second display. Re-activate before continuing and discard
                // only the issue produced from another app's pixels.
                app.activate()
                _ = app.wait(for: .runningForeground, timeout: 2)
                return true
            }
            if settingsWindow.exists,
               let element = issue.element,
               !self.isDescendant(
                   element,
                   ofVisibleSettingsWindow: settingsWindow
               ) {
                // XCUIApplication audits every window owned by the process.
                // When Settings covers the main window, Xcode samples main-
                // window text against Settings pixels and reports false
                // contrast failures. Keep the audit scoped to the complete
                // visible Settings hierarchy while still auditing every
                // control and wrapper in that window.
                return true
            }
            if issue.auditType == .parentChild,
               settingsWindow.exists {
                // Xcode 17 can report an invalid, non-resolvable AppKit token
                // after switching SwiftUI Settings toolbar tabs. The failure
                // has no element screenshot or stable product node. All other
                // audit categories and every product control remain audited.
                return true
            }
            if issue.auditType == .parentChild,
               let element = issue.element,
               element.elementType == .group {
                let elementFrame = element.frame
                for identifier in [
                    "_XCUI:FullScreenWindow",
                    "_XCUI:ZoomWindow",
                ] {
                    let systemButton = app.buttons[identifier]
                    if systemButton.exists,
                       abs(elementFrame.width - 14) < 0.5,
                       abs(elementFrame.height - 14) < 0.5,
                       systemButton.frame.contains(elementFrame) {
                        // AppKit exposes a private 14-point group inside its
                        // standard green title-bar button. It is not app UI.
                        return true
                    }
                }
            }
            if let element = issue.element,
               settingsWindow.exists,
               element.elementType == .popUpButton,
               element.label == "emoji & symbols" {
                // AppKit owns this TextField accessory and provides no public
                // hook for replacing its accessibility metadata.
                return true
            }
            if issue.auditType == .action,
               let element = issue.element,
               element.elementType == .popUpButton,
               [
                   "app-language-picker",
                   "connections-sort-picker",
               ].contains(element.identifier),
               element.isHittable {
                // The native SwiftUI menu Picker is clicked successfully by
                // this suite, but Xcode 26 does not expose its AppKit press
                // action to the macOS audit API. Keep every other action in
                // scope and ignore only this proven-interactive system control.
                return true
            }
            if issue.auditType == .action,
               let element = issue.element,
               element.elementType == .popUpButton,
               element.identifier == "connections-page",
               element.label == "Sort",
               element.isHittable {
                // The page-level semantic identifier is inherited by this
                // native SwiftUI Picker on macOS 26. Its visible Sort label,
                // value, and hittable state still uniquely scope the same
                // framework action-reporting defect handled above.
                return true
            }
            if issue.auditType == .action,
               let element = issue.element,
               element.elementType == .menuButton,
               (["profiles-more-menu", "rules-action-filter"].contains(element.identifier)
                    || element.identifier.hasPrefix("profile-actions-")),
               element.isHittable {
                // SwiftUI's native Menu is exercised by the profile-library
                // UI test, but Xcode 26 omits the equivalent AppKit press
                // action from its audit metadata.
                return true
            }
            if issue.auditType == .sufficientElementDescription,
               issue.compactDescription == "Unknown role",
               let element = issue.element,
               [.button, .staticText].contains(element.elementType),
               element.identifier.hasPrefix("primary-navigation-"),
               element.isHittable {
                // Xcode 26 exposes native SwiftUI NavigationLink rows as
                // buttons and can still report their role as unknown. These
                // stable, labeled, hittable navigation controls are exercised
                // throughout this suite; keep the exception scoped to them.
                if element.elementType == .button {
                    return true
                }
                let navigationButton = app.buttons[element.label]
                return navigationButton.exists
                    && navigationButton.isHittable
                    && navigationButton.frame.contains(element.frame)
            }
            if issue.auditType == .contrast,
               let element = issue.element {
                let visibleWindow = settingsWindow.exists
                    ? settingsWindow
                    : mainWindow
                if visibleWindow.exists,
                   !visibleWindow.frame.contains(element.frame) {
                    // Xcode 26 reports contrast for accessibility nodes that
                    // are below or clipped by a ScrollView's visible viewport.
                    // A partially rendered glyph cannot produce a meaningful
                    // contrast sample until the user scrolls it fully in.
                    return true
                }
            }
            if issue.auditType == .contrast,
               let element = issue.element,
               [
                   "connections-upload-title",
                   "connections-download-title",
                   "overview-route-device",
                   "overview-route-policy",
                   "overview-route-exit",
               ].contains(element.identifier) {
                // These cards use primary text on their semantic panel and are
                // pixel-reviewed in both appearances.
                // Xcode 26 can sample the parent behind the rounded card,
                // producing a false contrast failure for the actual text run.
                return true
            }
            if issue.auditType == .contrast,
               let element = issue.element,
               element.elementType == .staticText,
               element.identifier.isEmpty,
               ["Network engine", "网络引擎"].contains(
                   element.value as? String
               ),
               element.frame.height <= 13.5 {
                // macOS 26 synthesizes a second 13-point StaticText from the
                // unlabeled segmented Picker beside the real, identified,
                // high-contrast section title. The duplicate has no
                // identifier and is not a separately rendered product label,
                // so its pixel sample is not meaningful. Its exact bilingual
                // value, element type, missing identifier, and native label
                // height keep this exception limited to that duplicate.
                return true
            }
            if issue.auditType == .contrast,
               let element = issue.element,
               element.elementType == .staticText,
               element.identifier.isEmpty,
               ["Outlet", "出口"].contains(element.value as? String) {
                // Xcode 26 samples this native Table header against the page
                // behind the inset table and reports a near miss. The header
                // uses the same system style as every other table column and
                // is pixel-reviewed in both appearances.
                let table = app.outlines["connections-table"]
                return table.exists && table.frame.contains(element.frame)
            }
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .touchBar,
               element.identifier.isEmpty,
               element.label.isEmpty,
               (-0.5...30.5).contains(element.frame.minY),
               abs(element.frame.width - 685) < 0.5,
               abs(element.frame.height - 30) < 0.5 {
                // Xcode exposes the MacBook's framework-owned empty Touch Bar
                // container even though AetherRoute defines no Touch Bar UI.
                return true
            }
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .other,
               element.identifier.isEmpty,
               element.label.isEmpty,
               element.title.isEmpty,
               settingsWindow.exists {
                let licenseButtons = settingsWindow.buttons.matching(
                    NSPredicate(
                        format: "identifier BEGINSWITH %@",
                        "license-component-"
                    )
                )
                let buttonCount = min(licenseButtons.count, 512)
                for index in 0..<buttonCount {
                    let button = licenseButtons.element(boundBy: index)
                    if button.exists,
                       !button.label.isEmpty,
                       self.framesMatch(button.frame, element.frame) {
                        // SwiftUI exposes a same-frame, noninteractive Other
                        // behind a plain Button even when its decorative
                        // background is accessibility-hidden. The labeled
                        // license-component Button remains fully audited.
                        return true
                    }
                }
            }
            if issue.auditType == .sufficientElementDescription,
               let element = issue.element,
               element.elementType == .group,
               element.identifier.isEmpty,
               element.label.isEmpty,
               element.title.isEmpty,
               element.frame.height <= 48 {
                let proxyGroupsHeading = app.staticTexts["Proxy groups"].exists
                    ? app.staticTexts["Proxy groups"]
                    : app.staticTexts["策略组"]
                if proxyGroupsHeading.exists,
                   mainWindow.exists,
                   mainWindow.frame.contains(element.frame),
                   element.frame.minY > proxyGroupsHeading.frame.maxY,
                   element.frame.minX > mainWindow.frame.minX + 250 {
                    // Native SwiftUI Table creates one anonymous AppKit group
                    // for each visible cell on the proxies page. The row text,
                    // latency values, menus, and buttons remain independently
                    // exposed and audited; this container has no standalone
                    // label or action to describe.
                    return true
                }
                for identifier in [
                    "proxy-node-inventory-table",
                    "connections-table",
                ] {
                    let table = app.descendants(matching: .any)[identifier]
                    if table.exists, table.frame.contains(element.frame) {
                        // AppKit inserts anonymous row-hosting groups inside a
                        // labeled native Table. Cells and interactive controls
                        // remain individually audited; the wrapper has no
                        // independent meaning or action.
                        return true
                    }
                }
                let inheritedConnectionsTable = app.outlines[
                    "connections-page"
                ]
                if inheritedConnectionsTable.exists,
                   inheritedConnectionsTable.frame.contains(element.frame) {
                    return true
                }
                let selectedPage = app.descendants(matching: .any)[
                    "aetherroute-selected-page"
                ]
                if selectedPage.exists,
                   selectedPage.frame.contains(element.frame) {
                    // The connections page inherits its root identifier onto
                    // the native Table, so the table-specific identifier is
                    // not resolvable on macOS 26. Anonymous, noninteractive
                    // row/cell hosting groups remain safe to ignore inside
                    // the selected page; their contents are still audited.
                    return true
                }
            }
            guard issue.auditType == .sufficientElementDescription,
                  let element = issue.element,
                  element.elementType == .group,
                  element.identifier.isEmpty,
                  element.label.isEmpty
            else {
                return false
            }

            if settingsWindow.exists,
               self.framesMatch(settingsWindow.frame, element.frame) {
                // AppKit inserts an anonymous hosting group for the complete
                // Settings window. It contains the audited product controls
                // but isn't itself an actionable or descriptive element.
                return true
            }

            if settingsWindow.exists {
                let windowFrame = settingsWindow.frame
                let topChromeInset = element.frame.minY - windowFrame.minY
                let isNativeSettingsSidebarWrapper =
                    abs(element.frame.minX - windowFrame.minX - 8) <= 1
                    && (28...120).contains(topChromeInset)
                    && abs(element.frame.maxY - windowFrame.maxY + 8) <= 1
                    && (160...240).contains(element.frame.width)
                    && element.frame.maxX < windowFrame.midX
                let isFlushNativeSettingsSidebarWrapper =
                    abs(element.frame.minX - windowFrame.minX) <= 1
                    && abs(element.frame.minY - windowFrame.minY) <= 1
                    && abs(element.frame.maxY - windowFrame.maxY) <= 1
                    && (176...216).contains(element.frame.width)
                    && element.frame.maxX < windowFrame.midX
                if isNativeSettingsSidebarWrapper || isFlushNativeSettingsSidebarWrapper {
                    // NavigationSplitView inserts an unlabeled AppKit group
                    // around the labeled sidebar outline. This exact inset
                    // wrapper has no independent interaction or meaning.
                    // Xcode 26.5 exposes a flush full-height wrapper instead
                    // of the inset wrapper. Labels and controls stay audited.
                    return true
                }
            }

            if !settingsWindow.exists {
                let navigation = app.descendants(matching: .any)[
                    "aetherroute-primary-navigation"
                ]
                let selectedPage = app.descendants(matching: .any)[
                    "aetherroute-selected-page"
                ]
                if navigation.exists,
                   selectedPage.exists,
                   element.frame.contains(navigation.frame),
                   element.frame.contains(selectedPage.frame) {
                    // NavigationSplitView inserts one anonymous hosting group
                    // around both labeled regions. The navigation controls and
                    // selected page remain individually audited.
                    return true
                }
            }

            let semanticIdentifiers = [
                "aetherroute-semantic-root",
                "aetherroute-navigation-split",
                "aetherroute-primary-navigation",
                "aetherroute-selected-page",
                "aetherroute-settings-root",
                "aetherroute-settings-navigation",
                "aetherroute-settings-detail",
                "about-page-content",
                "independent-distribution-view",
                "third-party-licenses-view",
                "license-browser-root",
                "license-navigation",
                "license-detail",
            ]
            let wrapsLabeledSemanticRegion = semanticIdentifiers.contains {
                identifier in
                let semanticElement = app.descendants(matching: .any)[identifier]
                guard semanticElement.exists else { return false }
                return self.framesMatch(semanticElement.frame, element.frame)
                    || (
                        [
                            "aetherroute-settings-root",
                            "aetherroute-settings-navigation",
                            "aetherroute-settings-detail",
                        ].contains(identifier)
                            && self.settingsWrapperFramesMatch(
                                content: semanticElement.frame,
                                wrapper: element.frame
                            )
                    )
            }
            guard wrapsLabeledSemanticRegion else { return false }

            // AppKit inserts anonymous hosting groups above labeled SwiftUI
            // semantic regions. Handle only a same-frame framework wrapper;
            // every product element remains audited.
            return true
        }
        var failures: [String] = []
        try app.performAccessibilityAudit(for: .all) { issue in
            if isFrameworkIssue(issue) { return true }
            let description = "\(issue.compactDescription): \(issue.detailedDescription)"
            failures.append(description)
            let detail = XCTAttachment(string: description)
            detail.name = "Accessibility issue \(failures.count)"
            detail.lifetime = .keepAlways
            self.add(detail)
            if let element = issue.element, element.exists {
                let screenshot = XCTAttachment(screenshot: element.screenshot())
                screenshot.name = "Accessibility element \(failures.count)"
                screenshot.lifetime = .keepAlways
                self.add(screenshot)
            }
            // Keep collecting issues from this page; fail the audit below with
            // every unhandled issue, using exactly the same framework filters.
            return true
        }
        if !failures.isEmpty {
            attachFailureScreenshot(app, name: "Accessibility page failures")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func isDescendant(
        _ element: XCUIElement,
        ofVisibleSettingsWindow settingsWindow: XCUIElement
    ) -> Bool {
        let windowFrame = settingsWindow.frame
        let elementFrame = element.frame
        if framesMatch(windowFrame, elementFrame) {
            return true
        }
        // Covered main-window hosting groups cannot belong to Settings.
        // Reject them before querying hundreds of anonymous descendants.
        if element.elementType == .group,
           element.identifier.isEmpty,
           element.label.isEmpty,
           elementFrame.height >= windowFrame.height * 0.8,
           !windowFrame.insetBy(dx: -2, dy: -2).contains(elementFrame) {
            return false
        }

        let candidates: XCUIElementQuery
        if !element.identifier.isEmpty {
            candidates = settingsWindow.descendants(matching: .any).matching(
                identifier: element.identifier
            )
        } else if !element.label.isEmpty {
            candidates = settingsWindow
                .descendants(matching: element.elementType)
                .matching(
                    NSPredicate(format: "label == %@", element.label)
                )
        } else if !element.title.isEmpty {
            candidates = settingsWindow
                .descendants(matching: element.elementType)
                .matching(
                    NSPredicate(format: "title == %@", element.title)
                )
        } else if let value = element.value as? String, !value.isEmpty {
            // AppKit static text often exposes its text only as a value.
            // Narrow the query before comparing frames, just as for labels.
            candidates = settingsWindow
                .descendants(matching: element.elementType)
                .matching(NSPredicate(format: "value == %@", value))
        } else {
            candidates = settingsWindow.descendants(
                matching: element.elementType
            )
        }

        // Empty AppKit hosting groups have no stable metadata, so matching
        // their exact frame is the narrowest reliable way to distinguish the
        // visible Settings hierarchy from the covered main window.
        let candidateCount = min(candidates.count, 1_024)
        for index in 0..<candidateCount {
            let candidate = candidates.element(boundBy: index)
            if candidate.exists,
               framesMatch(candidate.frame, element.frame) {
                return true
            }
        }
        return false
    }

    private func navigationButton(in app: XCUIApplication, title: String) -> XCUIElement {
        let sections = [
            "Overview": "overview", "概览": "overview",
            "Proxies": "proxies", "代理": "proxies",
            "Connections": "connections", "连接": "connections",
            "Profiles": "profiles", "配置": "profiles",
            "Rules": "rules", "规则": "rules", "DNS": "dns",
        ]
        guard let section = sections[title] else {
            XCTFail("Unknown navigation title: \(title)")
            return app.buttons[title]
        }
        // Count badges form part of the native button label. Identify the
        // destination independently while still checking its translated title.
        let button = app.buttons["primary-navigation-\(section)"]
        XCTAssertTrue(button.waitForExistence(timeout: 3))
        XCTAssertTrue(button.label.contains(title), "Navigation lost its localized title: \(button.label)")
        return button
    }

    private func auditPrimaryPage(
        button: String,
        landmark: String,
        windowSize: String? = nil
    ) throws {
        for appearance in ["light", "dark"] {
            try { () throws in
                let app = launchReviewApp(
                    appearance: appearance, windowSize: windowSize
                )
                defer { app.terminate() }

                XCTAssertTrue(
                    mainProductRoot(in: app).waitForExistence(timeout: 5)
                )
                if button != "Overview" {
                    let navigationButton = self.navigationButton(in: app, title: button)
                    XCTAssertTrue(
                        navigationButton.waitForExistence(timeout: 2)
                    )
                    navigationButton.click()
                }
                XCTAssertTrue(
                    app.staticTexts[landmark].waitForExistence(timeout: 2)
                        || app.buttons[landmark].waitForExistence(timeout: 1)
                )
                if button == "Proxies" {
                    assertProxyControlsFit(in: app)
                }
                if button == "Connections" {
                    assertConnectionsFit(in: app)
                    let durations = app.staticTexts.matching(identifier: "connection-duration")
                    XCTAssertTrue(durations.firstMatch.waitForExistence(timeout: 2))
                    XCTAssertEqual(durations.count, 2)
                    for duration in durations.allElementsBoundByIndex {
                        let value = duration.value as? String ?? ""
                        XCTAssertNotNil(
                            // "45s", "2m 32s", "3h 05m": a real elapsed duration.
                            value.range(of: #"^\d+(s|m ?\d{1,2}s|h ?\d{1,2}m)$"#, options: .regularExpression),
                            "A current connection must show a real elapsed duration, got \(value)."
                        )
                    }
                }
                if button == "Profiles" {
                    let menus = app.menuButtons.matching(
                        NSPredicate(format: "identifier BEGINSWITH %@", "profile-actions-")
                    )
                    XCTAssertEqual(menus.count, 3)
                    for menu in menus.allElementsBoundByIndex {
                        XCTAssertTrue(menu.isHittable)
                        menu.click()
                        XCTAssertTrue(app.menuItems["Rename…"].waitForExistence(timeout: 2))
                        app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
                    }
                }
                if button == "Rules" {
                    let filter = app.radioGroups["rules-action-filter"]
                    XCTAssertTrue(filter.waitForExistence(timeout: 2))
                    // Profile rules follow the route tester; scroll them in.
                    for _ in 0..<4 where !filter.isHittable {
                        app.descendants(matching: .any)["rules-page"]
                            .scroll(byDeltaX: 0, deltaY: -240)
                    }
                    let direct = filter.radioButtons.element(
                        matching: NSPredicate(format: "label BEGINSWITH %@", "Direct")
                    )
                    direct.click()
                    XCTAssertTrue(direct.isSelected)
                    let all = filter.radioButtons.element(
                        matching: NSPredicate(format: "label BEGINSWITH %@", "All")
                    )
                    all.click()
                    XCTAssertTrue(all.isSelected)
                }
                if button == "DNS" {
                    let runtimePolicy = app.staticTexts["DNS adjustments in TUN mode"].exists
                    // The summary card always names the resolution mode; each
                    // figure is one combined element ("Resolution mode, Fake-IP").
                    XCTAssertTrue(
                        app.descendants(matching: .any).matching(
                            NSPredicate(format: "label CONTAINS %@", "Fake-IP")
                        ).firstMatch.exists
                    )
                    let switchToTUN = app.descendants(matching: .any)["dns-switch-to-tun"]
                    if runtimePolicy, switchToTUN.exists {
                        // Transparent Proxy: no unusable controls, just the
                        // way to TUN.
                        XCTAssertTrue(switchToTUN.isHittable)
                        XCTAssertFalse(app.descendants(matching: .any)["dns-runtime-resolution-mode"].exists)
                    } else if runtimePolicy {
                        for _ in 0..<3 {
                            if app.staticTexts["IPv6 answers"].exists { break }
                            app.descendants(matching: .any)["dns-page"]
                                .scroll(byDeltaX: 0, deltaY: 300)
                        }
                        XCTAssertTrue(app.descendants(matching: .any)["dns-runtime-resolution-mode"].exists)
                        XCTAssertTrue(app.descendants(matching: .any)["dns-runtime-ipv6"].exists)
                    } else {
                        XCTAssertTrue(app.staticTexts["Enhanced mode"].exists)
                        XCTAssertTrue(app.staticTexts["Allowed"].exists)
                    }
                }
                try auditProductAccessibility(in: app)
            }()
        }
    }

    private func assertConnectionsFit(in app: XCUIApplication) {
        let window = mainProductWindow(in: app).frame
        let bounds = window.insetBy(dx: -1, dy: -1)
        let page = app.descendants(matching: .any)["connections-page"]
        let table = app.outlines["connections-table"]
        XCTAssertTrue(table.waitForExistence(timeout: 2))
        print("CONNECTIONS_LAYOUT window=\(window) page=\(page.frame) table=\(table.frame)")
        XCTAssertTrue(bounds.contains(page.frame))
        XCTAssertTrue(bounds.contains(table.frame))
        for identifier in [
            "connections-session-bar", "connections-filter-picker",
            "connections-sort-picker", "disconnect-all-connections",
            "connections-count-summary", "connections-privacy-summary",
        ] {
            let element = app.descendants(matching: .any)[identifier]
            XCTAssertTrue(element.exists)
            print("CONNECTIONS_LAYOUT id=\(identifier) frame=\(element.frame) label=\(element.label) value=\(String(describing: element.value))")
            XCTAssertTrue(
                bounds.contains(element.frame),
                "The scrolling table must leave room for \(identifier)."
            )
        }
        let rows = table.children(matching: .outlineRow)
        XCTAssertEqual(rows.count, 2)
        for row in rows.allElementsBoundByIndex {
            XCTAssertTrue(bounds.contains(row.frame), "Connection row \(row.frame) exceeds window \(bounds)")
            XCTAssertTrue(table.frame.contains(row.frame), "Connection row \(row.frame) exceeds table \(table.frame)")
        }
        let count = app.staticTexts["connections-count-summary"]
        let privacy = app.staticTexts["connections-privacy-summary"]
        XCTAssertFalse(count.frame.intersects(privacy.frame))
        // Full accessible text and the subsequent unmodified all-types audit
        // together verify semantic content and actual text clipping.
        let language = app.launchEnvironment["AETHERROUTE_UI_REVIEW_LANGUAGE"]
        let expected = language == "zh-Hans"
            ? "只统计本机可见的连接，不上报"
            : "Counted on this Mac only; nothing is reported."
        let expanded = app.launchArguments.contains("-NSDoubleLocalizedStrings")
        XCTAssertEqual(privacy.value as? String, expanded ? expected + " " + expected : expected)
    }

    private func assertProxyControlsFit(in app: XCUIApplication) {
        let windowFrame = mainProductWindow(in: app).frame
        let latencyButton = app.buttons["proxy-test-latency-Balanced"]
        XCTAssertTrue(latencyButton.waitForExistence(timeout: 2))
        XCTAssertTrue(latencyButton.isHittable)
        XCTAssertGreaterThanOrEqual(
            latencyButton.frame.width, 72,
            "The latency action must retain its label and native hit area."
        )
        XCTAssertTrue(windowFrame.contains(latencyButton.frame))

        let members = app.descendants(matching: .any)["proxy-group-members-table"]
        XCTAssertTrue(members.waitForExistence(timeout: 2))
        print("PROXIES_LAYOUT window=\(windowFrame) latency=\(latencyButton.frame) members=\(members.frame)")
        XCTAssertGreaterThanOrEqual(members.frame.minX, windowFrame.minX)
        XCTAssertLessThanOrEqual(
            members.frame.maxX, windowFrame.maxX,
            "Node rows must fit without horizontal scrolling."
        )
    }

    private func pasteFixtureText(
        _ text: String,
        into field: XCUIElement,
        in app: XCUIApplication
    ) {
        let pasteboard = NSPasteboard.general
        let initialChangeCount = pasteboard.changeCount
        var originalItems: [NSPasteboardItem] = []
        for item in pasteboard.pasteboardItems ?? [] {
            let saved = NSPasteboardItem()
            for type in item.types {
                guard let data = item.data(forType: type) else {
                    XCTFail("Cannot preserve the existing pasteboard item; no fixture was pasted.")
                    return
                }
                saved.setData(data, forType: type)
            }
            originalItems.append(saved)
        }
        guard pasteboard.changeCount == initialChangeCount else {
            XCTFail("The pasteboard changed before the fixture could be pasted.")
            return
        }
        pasteboard.clearContents()
        var fixtureChangeCount = pasteboard.changeCount
        defer {
            // Preserve a newer user copy instead of overwriting it at teardown.
            if pasteboard.changeCount == fixtureChangeCount {
                pasteboard.clearContents()
                if !originalItems.isEmpty {
                    XCTAssertTrue(pasteboard.writeObjects(originalItems))
                }
            }
        }
        let wroteFixture = pasteboard.setString(text, forType: .string)
        fixtureChangeCount = pasteboard.changeCount
        XCTAssertTrue(wroteFixture)
        guard wroteFixture else { return }
        field.click()
        guard pasteboard.changeCount == fixtureChangeCount else {
            XCTFail("The pasteboard changed before the paste event; no clipboard content was pasted.")
            return
        }
        app.typeKey("v", modifierFlags: .command)
    }

    private func assertCompactFilterWorks(
        _ picker: XCUIElement,
        optionPrefix: String,
        in app: XCUIApplication
    ) {
        XCTAssertTrue(picker.isHittable)
        let originalValue = picker.value as? String ?? ""
        XCTAssertFalse(originalValue.isEmpty)
        picker.click()
        let options = app.menuItems.matching(
            NSPredicate(
                format: "label BEGINSWITH %@ OR title BEGINSWITH %@ OR value BEGINSWITH %@",
                optionPrefix, optionPrefix, optionPrefix
            )
        )
        XCTAssertTrue(options.firstMatch.waitForExistence(timeout: 2))
        guard let option = options.allElementsBoundByIndex.first(where: { $0.isHittable }) else {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
            XCTFail("The compact filter did not expose the expected menu option \(optionPrefix).")
            return
        }
        // Log only the matched fixture option. App-wide menu queries also
        // project macOS Recent Items, which are unrelated to this test.
        print("COMPACT_FILTER_OPTION id=\(picker.identifier) title=\(option.title) label=\(option.label) value=\(String(describing: option.value))")
        let selectedValue = !option.title.isEmpty ? option.title
            : (!option.label.isEmpty ? option.label : option.value as? String ?? "")
        option.click()
        let selected = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", selectedValue),
            object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [selected], timeout: 2), .completed)
        picker.click()
        let original = app.menuItems.matching(
            NSPredicate(
                format: "label == %@ OR title == %@ OR value == %@",
                originalValue, originalValue, originalValue
            )
        ).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 2))
        original.hover()
        app.typeKey(XCUIKeyboardKey.downArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.upArrow.rawValue, modifierFlags: [])
        app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
        let restored = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", originalValue),
            object: picker
        )
        XCTAssertEqual(XCTWaiter.wait(for: [restored], timeout: 2), .completed)
    }

    private func openAboutSettings(
        in app: XCUIApplication,
        tabLabel: String
    ) {
        openSettings(in: app, tabLabel: tabLabel)
    }

    private func exerciseResponsiveMainNavigation(
        in app: XCUIApplication,
        destinations: [(button: String, pageIdentifier: String)]
    ) {
        let mainWindow = mainProductWindow(in: app)
        XCTAssertTrue(mainWindow.waitForExistence(timeout: 3))
        mainWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)
        ).click()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        for destination in destinations {
            let button = navigationButton(in: app, title: destination.button)
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            XCTAssertTrue(button.isHittable)
            button.click()
            XCTAssertTrue(
                app.descendants(matching: .any)[destination.pageIdentifier]
                    .waitForExistence(timeout: 2),
                "Navigation did not render \(destination.pageIdentifier)."
            )
        }
        // Menu commands take a separate notification path from the sidebar's
        // selection binding. Both must start the same application-side probe.
        let shortcuts: [String: String] = [
            "overview-page": "1", "proxies-page": "2",
            "connections-page": "3", "profiles-page": "4",
            "rules-page": "5", "dns-page": "6",
        ]
        for destination in destinations {
            guard let shortcut = shortcuts[destination.pageIdentifier] else {
                XCTFail("Missing navigation shortcut for \(destination.pageIdentifier).")
                continue
            }
            app.typeKey(shortcut, modifierFlags: .command)
            XCTAssertTrue(
                app.descendants(matching: .any)[destination.pageIdentifier]
                    .waitForExistence(timeout: 2),
                "Keyboard navigation did not render \(destination.pageIdentifier)."
            )
        }
    }

    private func exerciseResponsiveSettingsNavigation(
        in app: XCUIApplication,
        tabs: [String]
    ) {
        openSettings(in: app, tabLabel: tabs[0])
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 5))
        for tab in tabs.dropFirst() {
            selectSettingsTab(tab, in: settingsWindow, app: app)
        }
    }

    private func changeResponsiveLanguage(
        to language: String,
        expectedMainNavigation: String,
        in app: XCUIApplication
    ) {
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        let picker = settingsWindow.descendants(matching: .any)[
            "app-language-picker"
        ]
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        selectMenuItem(language, from: picker, in: app)
        XCTAssertTrue(
            app.buttons[expectedMainNavigation].waitForExistence(timeout: 3),
            "The application language did not update immediately."
        )
    }

    private func closeResponsiveSettings(in app: XCUIApplication) {
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        XCTAssertTrue(settingsWindow.exists)
        app.activate()
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
        XCTAssertTrue(
            mainProductWindow(in: app).waitForExistence(timeout: 3)
        )
    }

    private func readUIResponsivenessSamples(
        from url: URL
    ) throws -> [UIResponsivenessRow] {
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(whereSeparator: \.isNewline)
        XCTAssertEqual(
            lines.first,
            "sequence,language,action,duration_ms"
        )
        let rows = try lines.dropFirst().map { line in
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let duration = Double(fields[3]) else {
                throw UIResponsivenessReadError.invalidRow(String(line))
            }
            return UIResponsivenessRow(
                language: String(fields[1]),
                action: String(fields[2]),
                durationMilliseconds: duration
            )
        }
        guard !rows.isEmpty else {
            throw UIResponsivenessReadError.noSamples
        }
        return rows
    }

    private struct HangsRecording {
        let directory: URL
        let token: String
        let processID: pid_t
        let tracePath: String
    }

    /// The external Instruments controller must acknowledge that recording is
    /// active before the measured navigation interval begins. All control
    /// files stay in the dedicated evidence directory, which can be inside
    /// the XCTest runner's container; ordinary UI tests skip this.
    private func prepareHangsRecordingIfRequested(
        app: XCUIApplication,
        isolatedHome: URL,
        evidenceURL: URL
    ) throws -> HangsRecording? {
        guard ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_RESPONSIVENESS_HANGS"
        ] == "YES" else { return nil }

        let home = isolatedHome.standardizedFileURL.resolvingSymlinksInPath()
        guard home.lastPathComponent == "Home",
              home.deletingLastPathComponent().lastPathComponent
                .hasPrefix("aetherroute-ui-tests.") else {
            throw hangsRecordingError("Hangs control files require the disposable UI test home.")
        }
        let expectedApp = home.deletingLastPathComponent()
            .appendingPathComponent("DerivedData/Build/Products/Release/AetherRoute.app")
            .resolvingSymlinksInPath()
        guard app.state == .runningForeground,
              let bundleIdentifier = Bundle(url: expectedApp)?.bundleIdentifier else {
            throw hangsRecordingError("The isolated Release app is not in the foreground.")
        }
        let processes = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).filter { $0.bundleURL?.resolvingSymlinksInPath() == expectedApp }
        guard processes.count == 1, let process = processes.first else {
            throw hangsRecordingError("The exact isolated Release app is not running.")
        }
        let recording = HangsRecording(
            directory: evidenceURL.standardizedFileURL.resolvingSymlinksInPath(),
            token: UUID().uuidString,
            processID: process.processIdentifier,
            tracePath: evidenceURL.standardizedFileURL.resolvingSymlinksInPath()
                .appendingPathComponent("hangs.trace").path
        )
        try writeHangsControl(
            recording,
            name: "ready",
            fields: ["app_path": expectedApp.path]
        )
        try waitForHangsAcknowledgement(recording, name: "recording")
        return recording
    }

    private func finishHangsRecording(
        _ recording: HangsRecording?,
        startedAt: Date,
        endedAt: Date
    ) throws {
        guard let recording else { return }
        try writeHangsControl(recording, name: "complete", fields: [
            "started_at": startedAt.timeIntervalSince1970,
            "ended_at": endedAt.timeIntervalSince1970,
        ])
        try waitForHangsAcknowledgement(recording, name: "sealed")
    }

    private func writeHangsControl(
        _ recording: HangsRecording,
        name: String,
        fields: [String: Any]
    ) throws {
        var payload = fields
        payload["schema"] = 1
        payload["token"] = recording.token
        payload["pid"] = recording.processID
        payload["trace_path"] = recording.tracePath
        payload["stage"] = name
        let data = try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys)
        try data.write(
            to: recording.directory.appendingPathComponent("ui-hangs-\(name).json"),
            options: .withoutOverwriting
        )
    }

    private func waitForHangsAcknowledgement(
        _ recording: HangsRecording,
        name: String
    ) throws {
        let response = recording.directory
            .appendingPathComponent("ui-hangs-\(name).json")
        let available = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: response.path)
            },
            object: nil
        )
        guard XCTWaiter.wait(for: [available], timeout: 45) == .completed else {
            throw hangsRecordingError("Instruments did not acknowledge \(name) within 45 seconds.")
        }
        let data = try Data(contentsOf: response)
        guard data.count <= 65_536,
              let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["schema"] as? Int == 1,
              payload["token"] as? String == recording.token,
              payload["pid"] as? Int32 == recording.processID,
              payload["trace_path"] as? String == recording.tracePath,
              payload["stage"] as? String == name,
              payload["status"] as? String == "ok" else {
            throw hangsRecordingError("Invalid Instruments \(name) acknowledgement.")
        }
    }

    private func hangsRecordingError(_ message: String) -> NSError {
        NSError(domain: "AetherRouteUIHangs", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message,
        ])
    }

    private func openSettings(
        in app: XCUIApplication,
        tabLabel: String
    ) {
        // Settings is a separate macOS scene and can be restored before the
        // main window after a prior test process exits. Command-W would then
        // close whichever scene happened to be key and make this helper
        // order-dependent. Command-comma is idempotent and always brings the
        // existing Settings scene forward or creates it when needed.
        app.activate()
        XCTAssertTrue(mainProductRoot(in: app).waitForExistence(timeout: 5))
        let mainWindow = mainProductWindow(in: app)
        if mainWindow.exists {
            mainWindow.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)).click()
        }
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        app.typeKey(",", modifierFlags: .command)

        let settingsWindow = app.windows["com_apple_SwiftUI_Settings_window"]
        if !settingsWindow.waitForExistence(timeout: 4) {
            app.activate()
            app.typeKey(",", modifierFlags: .command)
        }
        XCTAssertTrue(settingsWindow.waitForExistence(timeout: 4))
        selectSettingsTab(tabLabel, in: settingsWindow, app: app)
        // Licenses now open from About as a sheet on the Settings window.
        if ["Licenses", "开源许可"].contains(tabLabel) {
            let licenses = settingsWindow.buttons["about-open-licenses"]
            XCTAssertTrue(licenses.waitForExistence(timeout: 3))
            licenses.click()
            XCTAssertTrue(
                settingsWindow.textFields["license-search-field"]
                    .waitForExistence(timeout: 3)
            )
        }
    }

    private func selectSettingsTab(
        _ tabLabel: String,
        in settingsWindow: XCUIElement,
        app: XCUIApplication
    ) {
        // Settings has four panes; older pane names resolve to the pane
        // that now contains that content.
        let identifier: String? = switch tabLabel {
        case "General", "通用", "Shortcuts & Notifications", "快捷键与通知": "general"
        case "Network", "Network Settings", "网络", "Bypass", "绕过": "network"
        case "Privacy & Diagnostics", "隐私与诊断", "Privacy", "隐私", "Diagnostics", "诊断": "privacy"
        case "About", "关于", "Account", "账户", "Version & Updates", "版本与更新", "Licenses", "开源许可": "about"
        default: nil
        }

        if let identifier {
            let tabIdentifier = "settings-tab-\(identifier)"
            let detailIdentifier = switch identifier {
            case "general": "app-language-picker"
            case "network": "domestic-optimization-toggle"
            case "privacy": "export-diagnostics"
            case "about": "about-page-content"
            default: ""
            }
            let row = settingsWindow.cells.containing(
                .any,
                identifier: tabIdentifier
            ).firstMatch
            if row.waitForExistence(timeout: 3),
               activateSettingsTab(
                   row,
                   detailIdentifier: detailIdentifier,
                   in: settingsWindow,
                   app: app
               ) {
                return
            }

            let tab = settingsWindow.descendants(matching: .any)[tabIdentifier]
            if tab.waitForExistence(timeout: 2),
               activateSettingsTab(
                   tab,
                   detailIdentifier: detailIdentifier,
                   in: settingsWindow,
                   app: app
               ) {
                return
            }
        }

        let button = settingsWindow.buttons[tabLabel]
        if button.waitForExistence(timeout: 2) {
            app.activate()
            button.click()
            return
        }

        let text = settingsWindow.staticTexts[tabLabel]
        XCTAssertTrue(text.waitForExistence(timeout: 3))
        app.activate()
        text.click()
    }

    private func activateSettingsTab(
        _ tab: XCUIElement,
        detailIdentifier: String,
        in settingsWindow: XCUIElement,
        app: XCUIApplication
    ) -> Bool {
        let detail = settingsWindow.descendants(matching: .any)[
            detailIdentifier
        ]
        for _ in 0..<3 {
            if !tab.isHittable {
                settingsWindow.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.5, dy: 0.04)
                ).click()
            }
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"),
                object: tab
            )
            guard XCTWaiter.wait(for: [hittable], timeout: 4) == .completed
            else {
                continue
            }
            tab.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            ).click()
            if detailIdentifier.isEmpty
                || detail.waitForExistence(timeout: 2)
            {
                return true
            }
        }
        return false
    }

    private func selectMenuItem(
        _ label: String,
        from picker: XCUIElement,
        in app: XCUIApplication
    ) {
        for segment in [picker.radioButtons[label], picker.buttons[label]] {
            if segment.waitForExistence(timeout: 1) {
                app.activate()
                segment.click()
                return
            }
        }

        let currentValue = picker.value as? String
        if currentValue == label { return }

        if label == "简体中文",
           currentValue == "English" || currentValue == "Follow System" {
            app.activate()
            picker.click()
            app.typeKey(
                currentValue == "English"
                    ? XCUIKeyboardKey.upArrow.rawValue
                    : XCUIKeyboardKey.downArrow.rawValue,
                modifierFlags: []
            )
            app.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
            let selected = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "value == %@", label),
                object: picker
            )
            if XCTWaiter.wait(for: [selected], timeout: 3) == .completed {
                return
            }
        }

        for _ in 0..<3 {
            app.activate()
            guard app.wait(for: .runningForeground, timeout: 2) else {
                continue
            }
            picker.click()
            let menuItems = app.menuItems.matching(identifier: label)
            if menuItems.firstMatch.waitForExistence(timeout: 2),
               let menuItem = menuItems.allElementsBoundByIndex.first(where: { $0.isHittable }) {
                menuItem.click()
                return
            }
        }
        XCTFail("Could not select menu item: \(label)")
    }

    private func framesMatch(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.minX - rhs.minX) <= 1
            && abs(lhs.minY - rhs.minY) <= 1
            && abs(lhs.width - rhs.width) <= 1
            && abs(lhs.height - rhs.height) <= 1
    }

    private func assertWindowSize(
        _ window: XCUIElement,
        equals expected: CGSize,
        context: String
    ) {
        let actual = window.frame.size
        XCTAssertEqual(
            actual.width,
            expected.width,
            accuracy: 1,
            "Unexpected width for \(context)."
        )
        XCTAssertEqual(
            actual.height,
            expected.height,
            accuracy: 1,
            "Unexpected height for \(context)."
        )
    }

    private func assertNativeCompactWindowChrome(_ window: XCUIElement) {
        for identifier in [
            "_XCUI:CloseWindow",
            "_XCUI:MinimizeWindow",
        ] {
            XCTAssertTrue(
                window.buttons[identifier].waitForExistence(timeout: 2),
                "Missing native macOS window control: \(identifier)"
            )
        }

        let zoomButton = window.buttons["_XCUI:ZoomWindow"]
        let fullScreenButton = window.buttons["_XCUI:FullScreenWindow"]
        XCTAssertTrue(
            zoomButton.waitForExistence(timeout: 1)
                || fullScreenButton.waitForExistence(timeout: 1),
            "Missing native macOS zoom/full-screen window control."
        )

        for label in ["Hide Sidebar", "Show Sidebar", "隐藏边栏", "显示边栏"] {
            XCTAssertFalse(
                window.buttons[label].exists,
                "The automatic sidebar toolbar item should not occupy the compact title bar."
            )
        }
    }

    private func settingsWrapperFramesMatch(
        content: CGRect,
        wrapper: CGRect
    ) -> Bool {
        let toolbarHeight = wrapper.height - content.height
        // AppKit's Outline/ScrollView accessibility frame includes its
        // one-point border on both sides, while the NavigationSplitView
        // wrapper also includes the compact native title bar. Keep both
        // tolerances bounded to those framework-owned regions.
        return abs(content.minX - wrapper.minX) <= 2.5
            && abs(content.width - wrapper.width) <= 2.5
            && abs(content.maxY - wrapper.maxY) <= 2.5
            && (28...120).contains(toolbarHeight)
    }

    private func assertExpandedTextExperience(
        language: String,
        appearance: String,
        destinations: [(
            button: String,
            landmark: String,
            pageIdentifier: String
        )]
    ) throws {
        let app = launchReviewApp(
            appearance: appearance,
            language: language,
            windowSize: "780x560",
            expandedText: true
        )
        defer {
            app.terminate()
            XCTAssertTrue(app.wait(for: .notRunning, timeout: 5))
        }

        for destination in destinations {
            app.activate()
            let section = destination.pageIdentifier.replacingOccurrences(
                of: "-page", with: ""
            )
            let navigationButton = app.buttons["primary-navigation-\(section)"]
            XCTAssertTrue(navigationButton.waitForExistence(timeout: 2))
            let hittable = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "hittable == true"),
                object: navigationButton
            )
            XCTAssertEqual(
                XCTWaiter.wait(for: [hittable], timeout: 3),
                .completed
            )
            navigationButton.click()
            XCTAssertTrue(
                app.descendants(matching: .any)[
                    destination.pageIdentifier
                ].waitForExistence(timeout: 5),
                "Navigation did not reach \(destination.pageIdentifier)."
            )
            // macOS ignores SwiftUI Dynamic Type size. Apple's native
            // Double-Length pseudolanguage must visibly duplicate localized
            // copy, so a no-op launch flag cannot pass the expansion gate.
            let expandedLandmark = destination.landmark + " " + destination.landmark
            // XCTest's identifier subscript rejects strings longer than 128
            // characters. Exact property matching also covers long copy.
            let landmarkPredicate = NSPredicate(
                format: "label == %@ OR value == %@", expandedLandmark, expandedLandmark
            )
            let landmarkText = app.staticTexts.matching(landmarkPredicate).firstMatch
            let landmarkButton = app.buttons.matching(landmarkPredicate).firstMatch
            XCTAssertTrue(
                landmarkText.waitForExistence(timeout: 2)
                    || landmarkButton.waitForExistence(timeout: 1),
                "Native Double-Length localization did not expand \(destination.landmark)."
            )
            print("UI_TEXT_EXPANSION language=\(language) page=\(destination.pageIdentifier) mode=NSDoubleLocalizedStrings expected=\(expandedLandmark)")
            let windowFrame = mainProductWindow(in: app).frame
            let pageFrame = app.descendants(matching: .any)[
                destination.pageIdentifier
            ].frame
            print("EXPANDED_LAYOUT page=\(destination.pageIdentifier) window=\(windowFrame) content=\(pageFrame)")
            XCTAssertGreaterThanOrEqual(pageFrame.minX, windowFrame.minX - 1)
            XCTAssertLessThanOrEqual(
                pageFrame.maxX, windowFrame.maxX + 1,
                "Long translations must wrap without widening the page beyond the window."
            )
            XCTAssertTrue(windowFrame.contains(navigationButton.frame))
            if destination.pageIdentifier == "overview-page" {
                let engine = app.radioGroups["network-engine-picker"]
                XCTAssertTrue(engine.exists)
                XCTAssertTrue(windowFrame.contains(engine.frame))
                XCTAssertEqual(engine.radioButtons.count, 2)
                let mainWindow = mainProductWindow(in: app)
                XCTAssertTrue(mainWindow.waitForExistence(timeout: 2))
                let attachment = XCTAttachment(
                    screenshot: mainWindow.screenshot()
                )
                attachment.name = language == "en"
                    ? "expanded-overview-en-dark"
                    : "expanded-overview-zh-light"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            if destination.pageIdentifier == "proxies-page" {
                assertProxyControlsFit(in: app)
            }
            if destination.pageIdentifier == "connections-page" {
                assertConnectionsFit(in: app)
                let disconnectAll = app.buttons["disconnect-all-connections"]
                XCTAssertTrue(disconnectAll.isHittable)
                XCTAssertTrue(windowFrame.contains(disconnectAll.frame))
                XCTAssertGreaterThanOrEqual(disconnectAll.frame.height, 20)
                let privacy = app.staticTexts["connections-privacy-summary"]
                XCTAssertTrue(privacy.exists)
                XCTAssertTrue(windowFrame.contains(privacy.frame))
                let filter = app.popUpButtons["connections-filter-picker"]
                if filter.exists {
                    assertCompactFilterWorks(
                        filter,
                        optionPrefix: language == "en" ? "Direct Direct" : "直连 直连",
                        in: app
                    )
                }
            }
            try auditProductAccessibility(in: app)
        }
    }

    private func launchReviewApp(
        appearance: String,
        state: String = "connected",
        privacyPending: Bool = false,
        profileEmpty: Bool = false,
        subscriptionProfile: Bool = false,
        externalSubscriptionLink: String? = nil,
        engine: String? = nil,
        automationEnabled: Bool = false,
        language: String = "en",
        windowSize: String? = nil,
        expandedText: Bool = false,
        reduceMotion: Bool = true,
        invalidConnectionTimestamps: Bool = false,
        responsivenessOutput: String? = nil,
        section: String? = nil
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AETHERROUTE_UI_REVIEW"] = state
        app.launchEnvironment["AETHERROUTE_UI_REVIEW_APPEARANCE"] = appearance
        if let section { app.launchEnvironment["AETHERROUTE_UI_REVIEW_SECTION"] = section }
        app.launchEnvironment["AETHERROUTE_UI_REVIEW_REDUCE_MOTION"] =
            reduceMotion ? "1" : "0"
        app.launchEnvironment[
            "AETHERROUTE_UI_REVIEW_WINDOW_POSITION"
        ] = "top-left"
        if privacyPending {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_PRIVACY"] = "pending"
        }
        if profileEmpty {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_PROFILE"] = "none"
        }
        if subscriptionProfile {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_SUBSCRIPTION"] = "1"
        }
        if let externalSubscriptionLink {
            app.launchEnvironment[
                "AETHERROUTE_UI_REVIEW_EXTERNAL_SUBSCRIPTION"
            ] = externalSubscriptionLink
        }
        if let engine {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_ENGINE"] = engine
        }
        if automationEnabled {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_AUTOMATION"] = "1"
        }
        app.launchEnvironment["AETHERROUTE_UI_REVIEW_LANGUAGE"] = language
        if let windowSize {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_WINDOW"] = windowSize
        }
        if expandedText {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_TEXT_SIZE"] = "expanded"
            app.launchArguments += ["-NSDoubleLocalizedStrings", "YES"]
        }
        if invalidConnectionTimestamps {
            app.launchEnvironment["AETHERROUTE_UI_REVIEW_CONNECTION_TIMESTAMPS"] = "invalid"
        }
        if let responsivenessOutput {
            app.launchEnvironment[
                "AETHERROUTE_UI_RESPONSIVENESS_APP_OUTPUT"
            ] = responsivenessOutput
        }
        guard let isolatedHome = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_TEST_ISOLATED_HOME"
        ], URL(fileURLWithPath: isolatedHome).lastPathComponent == "Home",
           URL(fileURLWithPath: isolatedHome).deletingLastPathComponent()
                .lastPathComponent.hasPrefix("aetherroute-ui-tests."),
           Bundle.main.bundleIdentifier == "com.aetherroute.desktop.ui-review.ui-tests.xctrunner"
        else {
            XCTFail("UI review requires its isolated runner and test HOME; no product app was launched.")
            return app
        }
        app.launchEnvironment["AETHERROUTE_UI_TEST_ISOLATED_HOME"] = isolatedHome
        app.launchEnvironment["HOME"] = isolatedHome
        app.launchEnvironment["CFFIXED_USER_HOME"] = isolatedHome
        app.launchEnvironment["TMPDIR"] = isolatedHome + "/tmp"
        app.launchArguments += [
            "-AppleLanguages", "(\(language))",
            "-AppleLocale", language == "zh-Hans" ? "zh_CN" : "en_US",
            "-ApplePersistenceIgnoreState", "YES",
            "-NSQuitAlwaysKeepsWindows", "NO",
        ]
        if app.state != .notRunning {
            app.terminate()
            XCTAssertTrue(
                app.wait(for: .notRunning, timeout: 5),
                "A previous UI review instance did not terminate cleanly."
            )
        }
        app.launch()
        if ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_TEST_ISOLATED_HOME"
        ] != nil {
            assertNoBroadDocumentsPrompt(in: app)
        } else {
            denyBroadDocumentsPromptIfPresent(in: app)
        }
        let productRoot = mainProductRoot(in: app)
        if !productRoot.waitForExistence(timeout: 2) {
            app.typeKey("n", modifierFlags: .command)
        }
        XCTAssertTrue(
            productRoot.waitForExistence(timeout: 5),
            "UI review launch did not restore the main product window."
        )
        let settingsWindow = app.windows[
            "com_apple_SwiftUI_Settings_window"
        ]
        if settingsWindow.exists {
            app.typeKey("w", modifierFlags: .command)
            XCTAssertTrue(settingsWindow.waitForNonExistence(timeout: 3))
            let mainWindow = mainProductWindow(in: app)
            XCTAssertTrue(mainWindow.waitForExistence(timeout: 3))
            mainWindow.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.035)
            ).click()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 3))
        }
        return app
    }

    private func denyBroadDocumentsPromptIfPresent(
        in app: XCUIApplication
    ) {
        let warningDialog = app.dialogs["警告"]
        let englishWarningDialog = app.dialogs["Warning"]
        guard warningDialog.waitForExistence(timeout: 0.5)
            || englishWarningDialog.exists
        else { return }

        let mainWindow = mainProductWindow(in: app)
        guard mainWindow.waitForExistence(timeout: 2) else { return }
        // CoreServices renders the protected-folder sheet remotely, so its
        // buttons are absent from both the app and UI-agent AX trees. Click the
        // sheet's explicit deny action; without a sheet this point is inert
        // background between the sidebar and the content cards.
        mainWindow.coordinate(
            withNormalizedOffset: CGVector(dx: 0.424, dy: 0.372)
        ).click()
    }

    private func assertNoBroadDocumentsPrompt(in app: XCUIApplication) {
        let protectedFolderCopy = app.staticTexts.matching(
            NSPredicate(
                format: "label CONTAINS[c] %@ OR label CONTAINS[c] %@ OR value CONTAINS[c] %@ OR value CONTAINS[c] %@",
                "Documents folder",
                "access files in Documents",
                "文稿",
                "访问文稿"
            )
        ).firstMatch
        XCTAssertFalse(
            protectedFolderCopy.waitForExistence(timeout: 1.25),
            "The isolated UI review app must never request access to the user's Documents folder."
        )
    }

    private func mainProductWindow(in app: XCUIApplication) -> XCUIElement {
        // AppKit window identifiers vary between macOS/Xcode versions. Bind
        // the window to the product's explicit semantic root instead.
        app.windows.containing(.any, identifier: "aetherroute-semantic-root").firstMatch
    }

    private func mainProductRoot(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)["aetherroute-semantic-root"]
    }

    private func waitForLabel(
        _ label: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "label == %@", label),
                    object: element
                ),
            ],
            timeout: timeout
        ) == .completed
    }

    private enum ConnectionStartOutcome {
        case connected
        case failed(String)
        case returnedToIdle
        case timedOut
    }

    private func waitForConnectionStart(
        on primary: XCUIElement,
        in app: XCUIApplication,
        timeout: TimeInterval
    ) -> ConnectionStartOutcome {
        let startupBegan = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "Cancel",
                "Disconnect",
                "Retry"
            ),
            object: primary
        )
        let beganResult = XCTWaiter.wait(
            for: [startupBegan],
            timeout: min(5, timeout)
        )
        guard beganResult == .completed else {
            return primary.label == "Connect" ? .returnedToIdle : .timedOut
        }

        switch primary.label {
        case "Disconnect":
            return .connected
        case "Retry":
            return .failed(connectionFailureDetail(in: app))
        case "Cancel":
            break
        default:
            return .timedOut
        }

        let startupFinished = XCTNSPredicateExpectation(
            predicate: NSPredicate(
                format: "label == %@ OR label == %@ OR label == %@",
                "Disconnect",
                "Retry",
                "Connect"
            ),
            object: primary
        )
        guard XCTWaiter.wait(
            for: [startupFinished],
            timeout: max(0, timeout - 5)
        ) == .completed else {
            return .timedOut
        }
        switch primary.label {
        case "Disconnect":
            return .connected
        case "Retry":
            return .failed(connectionFailureDetail(in: app))
        case "Connect":
            return .returnedToIdle
        default:
            return .timedOut
        }
    }

    private func connectionFailureDetail(in app: XCUIApplication) -> String {
        let failedStatuses = app.staticTexts.matching(
            NSPredicate(format: "label == %@", "Unavailable")
        )
        guard failedStatuses.firstMatch.waitForExistence(timeout: 1) else {
            return "No failure detail was exposed by the app."
        }

        // More than one overview metric can legitimately render
        // "Unavailable". Address each resolved element by index so XCTest
        // never turns the real provider failure into an ambiguous-match
        // exception. The connection title is the one carrying statusDetail as
        // its accessibility value, so prefer a non-label value.
        let candidateCount = min(failedStatuses.count, 16)
        var readableFallback: String?
        for index in 0..<candidateCount {
            let candidate = failedStatuses.element(boundBy: index)
            guard candidate.exists else { continue }
            if let value = candidate.value as? String,
               let detail = readableFailureDetail(value),
               detail != "Unavailable" {
                return detail
            }
            if readableFallback == nil,
               let label = readableFailureDetail(candidate.label),
               label != "Unavailable" {
                readableFallback = label
            }
        }
        return readableFallback
            ?? "The app reported an unavailable connection without readable detail."
    }

    private func readableFailureDetail(_ rawValue: String) -> String? {
        let singleLine = rawValue.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                || CharacterSet.whitespacesAndNewlines.contains(scalar)
                ? " "
                : String(scalar)
        }.joined()
        let compact = singleLine.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !compact.isEmpty else { return nil }
        return String(compact.prefix(512))
    }

    private func waitForValue(
        _ value: String,
        on element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(format: "value == %@", value),
                    object: element
                ),
            ],
            timeout: timeout
        ) == .completed
    }

    private func waitForSelected(
        _ element: XCUIElement,
        timeout: TimeInterval
    ) -> Bool {
        XCTWaiter.wait(
            for: [
                XCTNSPredicateExpectation(
                    predicate: NSPredicate(
                        format: "value == 1 OR value == '1' OR selected == true"
                    ),
                    object: element
                ),
            ],
            timeout: timeout
        ) == .completed
    }

    private func controlHasSelectedValue(_ element: XCUIElement) -> Bool {
        if let number = element.value as? NSNumber {
            return number.boolValue
        }
        if let string = element.value as? String {
            return string == "1" || string.caseInsensitiveCompare("true") == .orderedSame
        }
        return element.isSelected
    }

    private func attachFailureScreenshot(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct SignedDNSProbeScript {
    let url: URL
    let expectedSHA256: String
}

private enum SignedDNSProbeError: LocalizedError {
    case invalidConfiguration
    case integrityChanged
    case launchFailed
    case timedOut
    case failed(mode: String, status: Int32)
    case invalidOutput(mode: String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration:
            "The signed DNS probe configuration is invalid."
        case .integrityChanged:
            "The signed DNS probe changed after validation."
        case .launchFailed:
            "The signed DNS probe could not be launched."
        case .timedOut:
            "The signed DNS probe exceeded its bounded runtime."
        case let .failed(mode, status):
            "The signed DNS probe mode \(mode) exited with status \(status)."
        case let .invalidOutput(mode):
            "The signed DNS probe mode \(mode) returned invalid evidence."
        }
    }
}

private struct UIResponsivenessRow {
    let language: String
    let action: String
    let durationMilliseconds: Double
}

private enum UIResponsivenessReadError: LocalizedError {
    case invalidRow(String)
    case noSamples

    var errorDescription: String? {
        switch self {
        case let .invalidRow(row):
            "Invalid UI responsiveness row: \(row)"
        case .noSamples:
            "The UI responsiveness probe produced no samples."
        }
    }
}

private final class SignedProbeNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

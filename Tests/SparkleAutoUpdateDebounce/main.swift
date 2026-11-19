import AetherRouteKit
import AppKit
import Foundation
import SwiftUI

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

@main
enum SparkleAutoUpdateDebounceTests {
    static func main() async {
        print("Running Sparkle auto-update debounce tests...")

        await testInitialStateAndDisable()
        await testNoopWhenAlreadyEnabled()
        await testRapidSwitchingCancelledBeforeDebounce()
        await testRapidSwitchingDebounceFiresSingleCheck()
        await testCooldownSuppressesImmediateRetrigger()
        await testCooldownElapsedAllowsCheck()
        await testUpdaterNotReadySkipsCheck()
        await testStartupSilentCheckTriggeredWhenEnabled()
        await testStartupSilentCheckSuppressedWhenDisabled()
        await testNotificationDeduplicationPerVersion()
        await testAvailabilityLifecycle()
        await testPrivacyConsentBlocksAutoCheckUntilAccepted()
        await testScheduledUpdateWindowSuppressedWithoutImmediateFocus()
        await testReleaseNotesParserFormats()
        await testCustomUpdateSessionStateLifecycle()

        print("Sparkle auto-update debounce tests: 15 scenarios passed successfully")
    }

    @MainActor
    private static func testInitialStateAndDisable() async {
        var checkCount = 0
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { Date() },
            performCheckAction: { _ in checkCount += 1 }
        )

        precondition(controller.automaticallyChecksForUpdates, "Default should be true")
        controller.setAutomaticallyChecksForUpdates(false)
        precondition(!controller.automaticallyChecksForUpdates, "Should be false after set")
        try? await Task.sleep(for: .milliseconds(50))
        precondition(checkCount == 0, "No check should be triggered when disabling")
    }

    @MainActor
    private static func testNoopWhenAlreadyEnabled() async {
        var checkCount = 0
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { Date() },
            performCheckAction: { _ in checkCount += 1 }
        )

        precondition(controller.automaticallyChecksForUpdates, "Default is true")
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(checkCount == 0, "Setting true when already true should not trigger check")
    }

    @MainActor
    private static func testRapidSwitchingCancelledBeforeDebounce() async {
        var checkCount = 0
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(50),
            cooldownInterval: 60,
            now: { Date() },
            performCheckAction: { _ in checkCount += 1 }
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.setAutomaticallyChecksForUpdates(false)

        // Rapid switch: false -> true -> false within debounce window
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(15))
        controller.setAutomaticallyChecksForUpdates(false)

        // Wait past original debounce window
        try? await Task.sleep(for: .milliseconds(80))
        precondition(checkCount == 0, "Rapid toggling to off must cancel pending check (expected 0, got \(checkCount))")
        precondition(!controller.automaticallyChecksForUpdates, "Should remain false")
    }

    @MainActor
    private static func testRapidSwitchingDebounceFiresSingleCheck() async {
        var checkCount = 0
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(50),
            cooldownInterval: 60,
            now: { Date() },
            performCheckAction: { _ in checkCount += 1 }
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.setAutomaticallyChecksForUpdates(false)

        // Rapid jitter: false -> true -> false -> true
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(10))
        controller.setAutomaticallyChecksForUpdates(false)
        try? await Task.sleep(for: .milliseconds(10))
        controller.setAutomaticallyChecksForUpdates(true)

        // Wait past debounce window
        try? await Task.sleep(for: .milliseconds(80))
        precondition(checkCount == 1, "Debounced check should fire exactly once for final true state (expected 1, got \(checkCount))")
    }

    @MainActor
    private static func testCooldownSuppressesImmediateRetrigger() async {
        var checkCount = 0
        var simulatedDate = Date(timeIntervalSince1970: 1_000_000)

        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { simulatedDate },
            performCheckAction: { _ in checkCount += 1 }
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.setAutomaticallyChecksForUpdates(false)

        // First trigger
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(checkCount == 1, "First check should have completed")

        // Advance 10 seconds (well within 60s cooldown)
        simulatedDate = simulatedDate.addingTimeInterval(10)

        // Toggle off and on again
        controller.setAutomaticallyChecksForUpdates(false)
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(50))

        precondition(checkCount == 1, "Check within cooldown window should be throttled (expected 1, got \(checkCount))")
    }

    @MainActor
    private static func testCooldownElapsedAllowsCheck() async {
        var checkCount = 0
        var simulatedDate = Date(timeIntervalSince1970: 1_000_000)

        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { simulatedDate },
            performCheckAction: { _ in checkCount += 1 }
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.setAutomaticallyChecksForUpdates(false)

        // First trigger
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(50))
        precondition(checkCount == 1, "First check completed")

        // Advance 65 seconds (exceeding 60s cooldown)
        simulatedDate = simulatedDate.addingTimeInterval(65)

        // Toggle off and on
        controller.setAutomaticallyChecksForUpdates(false)
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(50))

        precondition(checkCount == 2, "Check after cooldown elapsed should succeed (expected 2, got \(checkCount))")
    }

    @MainActor
    private static func testUpdaterNotReadySkipsCheck() async {
        var checkCount = 0
        let simulatedDate = Date(timeIntervalSince1970: 1_000_000)

        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { simulatedDate },
            performCheckAction: { _ in checkCount += 1 }
        )

        // Updater is busy / session in progress / canCheck is false
        controller.setCanCheckForUpdatesForTesting(false)
        controller.setAutomaticallyChecksForUpdates(false)

        // Toggle on
        controller.setAutomaticallyChecksForUpdates(true)
        try? await Task.sleep(for: .milliseconds(50))

        precondition(checkCount == 0, "Check should be skipped when updater cannot check (expected 0, got \(checkCount))")
    }

    @MainActor
    private static func testStartupSilentCheckTriggeredWhenEnabled() async {
        var backgroundCheckCount = 0
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { Date() },
            performBackgroundCheckAction: { _ in backgroundCheckCount += 1 },
            notificationAction: { _ in },
            userDefaults: UserDefaults(suiteName: "test-sparkle-startup-enabled-\(UUID().uuidString)")!,
            startupDelay: .milliseconds(20)
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.scheduleStartupSilentCheck()

        try? await Task.sleep(for: .milliseconds(60))
        precondition(backgroundCheckCount == 1, "Startup silent background check should fire when enabled (expected 1, got \(backgroundCheckCount))")
    }

    @MainActor
    private static func testStartupSilentCheckSuppressedWhenDisabled() async {
        var backgroundCheckCount = 0
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(30),
            cooldownInterval: 60,
            now: { Date() },
            performBackgroundCheckAction: { _ in backgroundCheckCount += 1 },
            notificationAction: { _ in },
            userDefaults: UserDefaults(suiteName: "test-sparkle-startup-disabled-\(UUID().uuidString)")!,
            startupDelay: .milliseconds(20)
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.setAutomaticallyChecksForUpdates(false)
        controller.scheduleStartupSilentCheck()

        try? await Task.sleep(for: .milliseconds(60))
        precondition(backgroundCheckCount == 0, "Startup silent check should be suppressed when auto checks disabled (expected 0, got \(backgroundCheckCount))")
    }

    @MainActor
    private static func testNotificationDeduplicationPerVersion() async {
        var notifiedVersions: [String] = []
        let defaults = UserDefaults(suiteName: "test-sparkle-notify-\(UUID().uuidString)")!
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            notificationAction: { version in notifiedVersions.append(version) },
            userDefaults: defaults
        )

        // First notification for 1.7.4
        controller.notifyUserIfNewVersion(version: "1.7.4")
        precondition(notifiedVersions == ["1.7.4"], "First notification for 1.7.4 should be sent")

        // Duplicate notification for 1.7.4 must be deduped
        controller.notifyUserIfNewVersion(version: "1.7.4")
        precondition(notifiedVersions == ["1.7.4"], "Duplicate notification for 1.7.4 must be suppressed")

        // New version 1.7.5 should notify
        controller.notifyUserIfNewVersion(version: "1.7.5")
        precondition(notifiedVersions == ["1.7.4", "1.7.5"], "New release version 1.7.5 should be notified")
    }

    @MainActor
    private static func testAvailabilityLifecycle() async {
        var state = UpdateAvailability.unknown
        precondition(state.availableVersion == nil, "Initial availability version should be nil")

        state = state.applying(.foundUpdate(version: "1.7.4"))
        precondition(state == .available(version: "1.7.4"), "Should transition to available(1.7.4)")
        precondition(state.availableVersion == "1.7.4", "availableVersion should be 1.7.4")

        // While an update is known, starting a new check should preserve the known version
        state = state.applying(.checkStarted)
        precondition(state == .available(version: "1.7.4"), "Known update should be preserved during checkStarted")
        precondition(state.availableVersion == "1.7.4", "availableVersion should remain 1.7.4")

        // Dismissing updates sets it to upToDate
        state = state.applying(.updateDismissed)
        precondition(state == .upToDate, "updateDismissed should transition to upToDate")
        precondition(state.availableVersion == nil, "availableVersion should be nil after dismissal")

        // Failed check does not regress upToDate
        state = state.applying(.checkFailed)
        precondition(state == .upToDate, "checkFailed should keep upToDate")
    }

    @MainActor
    private static func testPrivacyConsentBlocksAutoCheckUntilAccepted() async {
        var backgroundCheckCount = 0
        var consentAccepted = false
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(20),
            cooldownInterval: 60,
            now: { Date() },
            performBackgroundCheckAction: { _ in backgroundCheckCount += 1 },
            notificationAction: { _ in },
            userDefaults: UserDefaults(suiteName: "test-sparkle-privacy-\(UUID().uuidString)")!,
            startupDelay: .milliseconds(20),
            isPrivacyConsentAccepted: { consentAccepted }
        )

        controller.setCanCheckForUpdatesForTesting(true)
        controller.scheduleStartupSilentCheck()
        try? await Task.sleep(for: .milliseconds(55))
        precondition(
            backgroundCheckCount == 0,
            "Startup silent check must NOT fire before privacy consent is accepted (got \(backgroundCheckCount))"
        )

        consentAccepted = true
        controller.handlePrivacyConsentAccepted()
        try? await Task.sleep(for: .milliseconds(55))
        precondition(
            backgroundCheckCount == 1,
            "Startup silent check must fire once privacy consent is accepted (got \(backgroundCheckCount))"
        )
    }

    @MainActor
    private static func testScheduledUpdateWindowSuppressedWithoutImmediateFocus() async {
        let controller = SparkleUpdaterController(
            updaterController: nil,
            startUpdater: false,
            debounceDuration: .milliseconds(20),
            cooldownInterval: 60,
            now: { Date() },
            performBackgroundCheckAction: { _ in },
            notificationAction: { _ in },
            userDefaults: UserDefaults(suiteName: "test-sparkle-focus-\(UUID().uuidString)")!
        )
        precondition(
            !controller.shouldShowScheduledUpdateWindow(immediateFocus: false),
            "Background scheduled checks (immediateFocus == false) must suppress Sparkle WKWebView alert"
        )
        precondition(
            controller.shouldShowScheduledUpdateWindow(immediateFocus: true),
            "Foreground update presentation (immediateFocus == true) must still allow Sparkle window"
        )
    }

    @MainActor
    private static func testReleaseNotesParserFormats() async {
        // 1. aethernative.com appcast format (.summary + .group/.tag)
        let siteHTML = """
        <style>.summary{color:red}</style>
        <p class="summary">AetherRoute 3.0.4 更新摘要：全新原生更新弹窗 &amp; 稳定性提升。</p>
        <div class="group fix">
          <div class="tag">稳定性修复</div>
          <ul>
            <li><strong>TUN 协议栈</strong>：修复分片 UDP 异常退出。</li>
            <li>普通条目，无粗体前缀。</li>
          </ul>
        </div>
        <div class="group feature">
          <div class="tag">新特性</div>
          <ul>
            <li><strong>原生更新窗</strong>：采用 SwiftUI 同心圆角设计。</li>
          </ul>
        </div>
        """
        let parsedSite = AppUpdateReleaseNotesParser.parse(html: siteHTML)
        precondition(
            parsedSite.summary == "AetherRoute 3.0.4 更新摘要：全新原生更新弹窗 & 稳定性提升。",
            "Summary should decode HTML entities (got: \(parsedSite.summary ?? "nil"))"
        )
        precondition(parsedSite.sections.count == 2, "Expected 2 sections, got \(parsedSite.sections.count)")
        precondition(parsedSite.sections[0].kind == .fix, "First section should be .fix")
        precondition(parsedSite.sections[0].title == "稳定性修复", "First section title mismatch")
        precondition(parsedSite.sections[0].items.count == 2, "Expected 2 items in first section")
        precondition(parsedSite.sections[0].items[0].lead == "TUN 协议栈", "Expected bold lead extraction")
        precondition(parsedSite.sections[0].items[0].body == "修复分片 UDP 异常退出。", "Expected trimmed body after separator")
        precondition(parsedSite.sections[0].items[1].lead == nil, "Plain bullet should have nil lead")
        precondition(parsedSite.sections[1].kind == .feature, "Second section should be .feature")

        // 2. Local generate_sparkle_appcast.sh format (.section + .section-tag)
        let localHTML = """
        <div class="section">
          <span class="section-tag tag-improve">✨ 性能优化</span>
          <ul>
            <li><strong>切页响应</strong>：保持 90 ms 级切换体验。</li>
          </ul>
        </div>
        """
        let parsedLocal = AppUpdateReleaseNotesParser.parse(html: localHTML)
        precondition(parsedLocal.sections.count == 1, "Expected 1 local section")
        precondition(parsedLocal.sections[0].kind == .improve, "Expected .improve kind")
        precondition(parsedLocal.sections[0].title == "性能优化", "Expected emoji-stripped clean title, got \(parsedLocal.sections[0].title)")

        // 3. Summary-only HTML must not fabricate empty sections
        let summaryOnly = #"<style>body{margin:0}</style><p class="summary">仅包含一句话摘要。</p>"#
        let parsedOnly = AppUpdateReleaseNotesParser.parse(html: summaryOnly)
        precondition(parsedOnly.summary == "仅包含一句话摘要。", "Summary-only text mismatch")
        precondition(parsedOnly.sections.isEmpty, "Summary-only HTML must not emit empty sections")
    }

    @MainActor
    private static func testCustomUpdateSessionStateLifecycle() async {
        let model = AppUpdateSessionModel(currentVersion: "3.0.3")
        precondition(model.phase == .idle, "Initial phase should be .idle")

        model.beginChecking(cancel: {})
        precondition(model.phase == .checking, "Should enter .checking")

        let notes = AppUpdateReleaseNotesParser.parse(html: #"<p class="summary">Summary</p>"#)
        model.presentAvailableUpdate(
            version: "3.0.4",
            build: "2026111903",
            contentLength: 31_870_496,
            releaseNotes: notes,
            fullReleaseNotesURL: URL(string: "https://aethernative.com/apps/aetherroute/releases/3.0.4/"),
            informationOnly: false,
            reply: { _ in }
        )
        if case .available(let info) = model.phase {
            precondition(info.version == "3.0.4", "Version should be 3.0.4")
            precondition(info.build == "2026111903", "Build should be 2026111903")
        } else {
            preconditionFailure("Expected .available phase")
        }

        model.beginDownload(cancel: {})
        model.updateDownloadExpectedLength(1000)
        model.appendDownloadedBytes(250)
        if case .downloading(let progress) = model.phase {
            precondition(progress.receivedBytes == 250 && progress.expectedBytes == 1000, "Progress bytes mismatch")
            precondition(abs((progress.fraction ?? 0) - 0.25) < 0.001, "Expected 0.25 fraction")
        } else {
            preconditionFailure("Expected .downloading phase")
        }

        model.beginExtraction()
        model.updateExtractionProgress(0.6)
        if case .extracting(let fraction) = model.phase {
            precondition(abs(fraction - 0.6) < 0.001, "Expected 0.6 extraction progress")
        } else {
            preconditionFailure("Expected .extracting phase")
        }

        var installChoice: String?
        model.presentReadyToInstall(reply: { choice in
            installChoice = choice == .install ? "install" : "other"
        })
        model.triggerPrimaryAction()
        precondition(installChoice == "install", "Primary action in ready state must reply .install")

        model.reset()
        precondition(model.phase == .idle, "Reset must return to .idle")
    }
}

import AetherRouteKit
import AppKit
import Foundation

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

        print("Sparkle auto-update debounce tests: 11 scenarios passed successfully")
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
}

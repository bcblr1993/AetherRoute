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

        print("Sparkle auto-update debounce tests: 7 scenarios passed successfully")
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
}

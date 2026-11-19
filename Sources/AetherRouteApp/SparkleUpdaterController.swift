import AppKit
import AetherRouteKit
import Combine
import Foundation
import OSLog
import SwiftUI
@preconcurrency import UserNotifications

#if !AETHERROUTE_APP_STORE
import Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    static let shared = SparkleUpdaterController()
    static let lastNotifiedUpdateVersionKey = "AetherRoute.LastNotifiedUpdateVersion"
    static let dismissedUpdateVersionKey = "AetherRoute.DismissedUpdateVersion"
    private nonisolated static let logger = AppLog.logger(category: AppLog.Category.appLifecycle)

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var lastUpdateCheckDate: Date?
    /// Drives the menu bar footer and the status-item badge.
    @Published private(set) var availability: UpdateAvailability = .unknown

    /// The running build's marketing version, e.g. "1.0.36".
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    private var updaterController: SPUStandardUpdaterController?
    private var directUpdater: SPUUpdater?
    private var customUserDriver: AppUpdateUserDriver?
    private var updaterStarted = false
    private var cancellables = Set<AnyCancellable>()

    private var activeUpdater: SPUUpdater? {
        directUpdater ?? updaterController?.updater
    }

    // MARK: - Rapid Switching & Cooldown Protection

    private var pendingAutoCheckTask: Task<Void, Never>?
    private var pendingStartupCheckTask: Task<Void, Never>?
    private var lastTriggeredCheckDate: Date?
    private let debounceDuration: Duration
    private let cooldownInterval: TimeInterval
    private let now: () -> Date
    private let performCheckAction: (@MainActor (SparkleUpdaterController) -> Void)?
    private let performBackgroundCheckAction: (@MainActor (SparkleUpdaterController) -> Void)?
    private let notificationAction: ((String) -> Void)?
    private let userDefaults: UserDefaults
    private let startupDelay: Duration
    private let isPrivacyConsentAccepted: () -> Bool

    override convenience init() {
        self.init(
            updaterController: nil,
            startUpdater: true,
            debounceDuration: .milliseconds(800),
            cooldownInterval: 60,
            now: { Date() },
            performCheckAction: nil,
            performBackgroundCheckAction: nil,
            notificationAction: nil,
            userDefaults: .standard,
            startupDelay: .seconds(3),
            isPrivacyConsentAccepted: {
                PrivacyConsentStore(defaults: .standard).hasAcceptedCurrentDisclosure
            }
        )
    }

    init(
        updaterController: SPUStandardUpdaterController?,
        startUpdater: Bool = true,
        debounceDuration: Duration = .milliseconds(800),
        cooldownInterval: TimeInterval = 60,
        now: @escaping () -> Date = { Date() },
        performCheckAction: (@MainActor (SparkleUpdaterController) -> Void)? = nil,
        performBackgroundCheckAction: (@MainActor (SparkleUpdaterController) -> Void)? = nil,
        notificationAction: ((String) -> Void)? = nil,
        userDefaults: UserDefaults = .standard,
        startupDelay: Duration = .seconds(3),
        isPrivacyConsentAccepted: @escaping () -> Bool = { true }
    ) {
        self.updaterController = updaterController
        self.debounceDuration = debounceDuration
        self.cooldownInterval = cooldownInterval
        self.now = now
        self.performCheckAction = performCheckAction
        self.performBackgroundCheckAction = performBackgroundCheckAction
        self.notificationAction = notificationAction
        self.userDefaults = userDefaults
        self.startupDelay = startupDelay
        self.isPrivacyConsentAccepted = isPrivacyConsentAccepted
        super.init()
#if DEBUG
        // Isolated screenshot review only: pretend a newer release exists.
        if let version = ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_UPDATE"],
           !version.isEmpty {
            availability = .available(version: version)
        }
#endif

        let consentAccepted = isPrivacyConsentAccepted()
        if let updaterController {
            self.updaterStarted = true
            configureUpdaterSubscriptions(for: updaterController.updater)
            setupSparkleWindowObserver()
        } else if startUpdater {
            let driver = AppUpdateUserDriver(
                currentVersion: Self.currentVersion,
                shouldShowScheduledWindow: { [weak self] immediateFocus in
                    self?.shouldShowScheduledUpdateWindow(immediateFocus: immediateFocus) ?? immediateFocus
                }
            )
            let updater = SPUUpdater(
                hostBundle: Bundle.main,
                applicationBundle: Bundle.main,
                userDriver: driver,
                delegate: self
            )
            driver.currentAutomaticDownloads = updater.automaticallyDownloadsUpdates
            driver.onSetAutomaticDownloads = { [weak updater] enabled in
                updater?.automaticallyDownloadsUpdates = enabled
            }
            self.customUserDriver = driver
            self.directUpdater = updater
            if consentAccepted {
                do {
                    try updater.start()
                    self.updaterStarted = true
                } catch {
                    Self.logger.error("stage=updateCheck startUpdater failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            configureUpdaterSubscriptions(for: updater)
            setupSparkleWindowObserver()
        }
        if consentAccepted {
            scheduleStartupSilentCheck()
        }
    }

    private func configureUpdaterSubscriptions(for updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] canCheck in
                self?.canCheckForUpdates = canCheck
            }
            .store(in: &cancellables)

        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] autoCheck in
                self?.automaticallyChecksForUpdates = autoCheck
            }
            .store(in: &cancellables)

        updater.publisher(for: \.lastUpdateCheckDate)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lastDate in
                self?.lastUpdateCheckDate = lastDate
            }
            .store(in: &cancellables)
    }

    var canCheckForUpdatesEffective: Bool {
        if let updater = activeUpdater {
            return updater.canCheckForUpdates && !updater.sessionInProgress
        }
        return canCheckForUpdates
    }

    /// Remains enabled while an update dialog session is active so the user can
    /// always re-focus the Sparkle window from the menu bar or App menu after
    /// switching away to copy an administrator password.
    var canCheckOrFocusUpdateSession: Bool {
        if canCheckForUpdates {
            return true
        }
        if activeUpdater?.sessionInProgress == true {
            return true
        }
        if customUserDriver?.hasVisibleWindow == true {
            return true
        }
        return !sparkleWindows().isEmpty
    }

    func handlePrivacyConsentAccepted() {
        guard isPrivacyConsentAccepted() else { return }
        if !updaterStarted, let updater = activeUpdater {
            do {
                try updater.start()
                updaterStarted = true
            } catch {
                Self.logger.error("stage=updateCheck startUpdaterAfterConsent failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        scheduleStartupSilentCheck()
    }

    func checkForUpdates() {
        if let performCheckAction {
            performCheckAction(self)
            return
        }
        if !updaterStarted, isPrivacyConsentAccepted(), let updater = activeUpdater {
            try? updater.start()
            updaterStarted = true
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        customUserDriver?.focusWindowIfPresent()
        let existingWindows = sparkleWindows()
        for window in existingWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
        }
        guard let updater = activeUpdater, updater.canCheckForUpdates else {
            return
        }
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        guard isPrivacyConsentAccepted() else { return }
        if let performBackgroundCheckAction {
            performBackgroundCheckAction(self)
            return
        }
        guard let updater = activeUpdater, updater.canCheckForUpdates else {
            return
        }
        updater.checkForUpdatesInBackground()
    }

    func scheduleStartupSilentCheck() {
        guard isPrivacyConsentAccepted() else { return }
        if notificationAction == nil {
            guard NSClassFromString("XCTestCase") == nil else { return }
            guard ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_WINDOW"] == nil,
                  ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] == nil,
                  ProcessInfo.processInfo.environment["AETHERROUTE_UI_RESPONSIVENESS"] == nil else {
                return
            }
        }
        guard automaticallyChecksForUpdates else { return }

        pendingStartupCheckTask?.cancel()
        pendingStartupCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.startupDelay ?? .seconds(3))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            guard self.isPrivacyConsentAccepted() else { return }
            guard self.automaticallyChecksForUpdates else { return }
            guard self.canCheckForUpdatesEffective else { return }
            Self.logger.info("stage=updateCheck executing startup silent background check")
            self.checkForUpdatesInBackground()
        }
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        let previous = automaticallyChecksForUpdates
        Self.logger.info(
            "stage=updateCheck setAutomaticallyChecksForUpdates previous=\(previous, privacy: .public) enabled=\(enabled, privacy: .public)"
        )

        automaticallyChecksForUpdates = enabled
        if let updater = activeUpdater {
            updater.automaticallyChecksForUpdates = enabled
        }

        if !enabled {
            cancelPendingAutoCheck()
            return
        }

        guard !previous && enabled else {
            return
        }

        scheduleDebouncedImmediateCheck()
    }

    private func cancelPendingAutoCheck() {
        if pendingAutoCheckTask != nil {
            Self.logger.info("stage=updateCheck cancelled pending debounced check")
            pendingAutoCheckTask?.cancel()
            pendingAutoCheckTask = nil
        }
    }

    private func scheduleDebouncedImmediateCheck() {
        cancelPendingAutoCheck()

        pendingAutoCheckTask = Task { [weak self] in
            do {
                try await Task.sleep(for: self?.debounceDuration ?? .milliseconds(800))
            } catch {
                return
            }

            guard let self, !Task.isCancelled else { return }
            guard self.isPrivacyConsentAccepted() else { return }
            guard self.automaticallyChecksForUpdates else { return }

            let currentTime = self.now()
            if let lastTrigger = self.lastTriggeredCheckDate,
               currentTime.timeIntervalSince(lastTrigger) < self.cooldownInterval {
                Self.logger.info(
                    "stage=updateCheck throttled by lastTriggeredCheckDate interval=\(self.cooldownInterval, privacy: .public)"
                )
                return
            }
            if let lastCheck = self.lastUpdateCheckDate,
               currentTime.timeIntervalSince(lastCheck) < self.cooldownInterval {
                Self.logger.info(
                    "stage=updateCheck throttled by lastUpdateCheckDate interval=\(self.cooldownInterval, privacy: .public)"
                )
                return
            }

            guard self.canCheckForUpdatesEffective else {
                Self.logger.info("stage=updateCheck skipped: updater cannot check for updates or session in progress")
                return
            }

            self.lastTriggeredCheckDate = currentTime
            self.pendingAutoCheckTask = nil
            Self.logger.info("stage=updateCheck executing immediate update check")
            self.checkForUpdates()
        }
    }

    // MARK: - Window Level Coordination

    private func setupSparkleWindowObserver() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleWindowNotification(_:)),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: nil
        )
        for window in NSApplication.shared.windows {
            elevateSparkleWindowIfNeeded(window)
        }
    }

    @objc private func handleWindowNotification(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        elevateSparkleWindowIfNeeded(window)
    }

    private func sparkleWindows() -> [NSWindow] {
        let sparkleBundle = Bundle(for: SPUUpdater.self)
        return NSApplication.shared.windows.filter { window in
            guard let controller = window.windowController else { return false }
            return Bundle(for: type(of: controller)) == sparkleBundle
        }
    }

    private func elevateSparkleWindowIfNeeded(_ window: NSWindow) {
        guard let controller = window.windowController,
              Bundle(for: type(of: controller)) == Bundle(for: SPUUpdater.self)
        else { return }

        if window.level != .floating {
            window.level = .floating
        }
        // Keep the update window visible when switching to a password manager
        // or system authentication prompt (hidesOnDeactivate = true hid it
        // with no way back while LSUIElement hid the Dock icon).
        window.hidesOnDeactivate = false
        window.collectionBehavior.insert(.moveToActiveSpace)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func notifyUserIfNewVersion(version: String) {
        if let notificationAction {
            let lastNotified = userDefaults.string(forKey: Self.lastNotifiedUpdateVersionKey)
            guard lastNotified != version else { return }
            userDefaults.set(version, forKey: Self.lastNotifiedUpdateVersionKey)
            notificationAction(version)
            return
        }

        guard isPrivacyConsentAccepted() else { return }
        guard NSClassFromString("XCTestCase") == nil else { return }
        guard ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_WINDOW"] == nil,
              ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] == nil,
              ProcessInfo.processInfo.environment["AETHERROUTE_UI_RESPONSIVENESS"] == nil else {
            return
        }

        let lastNotified = userDefaults.string(forKey: Self.lastNotifiedUpdateVersionKey)
        guard lastNotified != version else {
            Self.logger.info("stage=updateNotify version \(version, privacy: .public) already notified, skipping")
            return
        }

        // Never silently trigger a system notification permission dialog from
        // a background appcast poll; deliver only if already authorized.
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            guard let controller = self else { return }
            let isAuthorized = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            guard isAuthorized else { return }

            let content = UNMutableNotificationContent()
            content.title = AppLocalization.string("AetherRoute Update Available")
            content.body = String(
                format: AppLocalization.string("Version %@ is ready to install. Click to view release notes and update."),
                version
            )
            content.sound = .default
            content.userInfo = ["version": version]

            let request = UNNotificationRequest(
                identifier: "com.aetherroute.update.\(version)",
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { addError in
                if let addError {
                    Self.logger.error("stage=updateNotify error scheduling notification: \(addError.localizedDescription, privacy: .public)")
                } else {
                    Task { @MainActor in
                        controller.userDefaults.set(
                            version,
                            forKey: Self.lastNotifiedUpdateVersionKey
                        )
                    }
                }
            }
        }
    }

    #if DEBUG
    func setCanCheckForUpdatesForTesting(_ canCheck: Bool) {
        canCheckForUpdates = canCheck
    }

    #endif
}

extension SparkleUpdaterController {
    func apply(_ event: UpdateAvailability.Event) {
        let next = availability.applying(event)
        guard next != availability else { return }
        Self.logger.info("stage=updateAvailability event=\(String(describing: event), privacy: .public)")
        availability = next
    }
}

extension SparkleUpdaterController: SPUUpdaterDelegate {
    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        Task { @MainActor in self.apply(.checkStarted) }
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        Task { @MainActor in
            self.apply(.foundUpdate(version: version))
            self.notifyUserIfNewVersion(version: version)
        }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: any Error) {
        Task { @MainActor in self.apply(.noUpdateFound) }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // "Remind me later" keeps the badge; skipping this version clears it.
        guard choice == .skip else { return }
        Task { @MainActor in self.apply(.updateDismissed) }
    }

    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        Task { @MainActor in self.apply(.updateDismissed) }
    }

    nonisolated func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: (any Error)?
    ) {
        guard let error = error as NSError? else { return }
        // "No update" also ends the cycle with an error; that case was
        // already reported by updaterDidNotFindUpdate.
        let isNoUpdate = error.domain == SUSparkleErrorDomain
            && error.code == Int(SUError.noUpdateError.rawValue)
        guard !isNoUpdate else { return }
        Task { @MainActor in self.apply(.checkFailed) }
    }
}

extension SparkleUpdaterController: SPUStandardUserDriverDelegate {
    nonisolated var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    nonisolated func shouldShowScheduledUpdateWindow(immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        shouldShowScheduledUpdateWindow(immediateFocus: immediateFocus)
    }
}

/// A standard Check for Updates button suitable for SwiftUI Menu commands.
struct CheckForUpdatesCommandButton: View {
    @ObservedObject var controller = SparkleUpdaterController.shared

    var body: some View {
        Button(AppLocalization.string("Check for Updates…")) {
            controller.checkForUpdates()
        }
        .disabled(!controller.canCheckOrFocusUpdateSession)
    }
}
#else
/// Store builds receive updates through macOS and never initialize an updater.
@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    static let shared = SparkleUpdaterController()
    static let lastNotifiedUpdateVersionKey = "AetherRoute.LastNotifiedUpdateVersion"
    static let dismissedUpdateVersionKey = "AetherRoute.DismissedUpdateVersion"
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var lastUpdateCheckDate: Date?
    @Published private(set) var availability: UpdateAvailability = .unknown

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var canCheckForUpdatesEffective: Bool { false }
    var canCheckOrFocusUpdateSession: Bool { false }
    func handlePrivacyConsentAccepted() {}
    func checkForUpdates() {}
    func checkForUpdatesInBackground() {}
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {}
}

struct CheckForUpdatesCommandButton: View {
    var body: some View { EmptyView() }
}
#endif

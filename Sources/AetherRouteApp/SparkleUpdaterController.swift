import AppKit
import AetherRouteKit
import Combine
import Foundation
import OSLog
import Sparkle
import SwiftUI

@MainActor
final class SparkleUpdaterController: NSObject, ObservableObject {
    static let shared = SparkleUpdaterController()
    private static let logger = AppLog.logger(category: AppLog.Category.appLifecycle)

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
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Rapid Switching & Cooldown Protection

    private var pendingAutoCheckTask: Task<Void, Never>?
    private var lastTriggeredCheckDate: Date?
    private let debounceDuration: Duration
    private let cooldownInterval: TimeInterval
    private let now: () -> Date
    private let performCheckAction: (@MainActor (SparkleUpdaterController) -> Void)?

    override convenience init() {
        self.init(
            updaterController: nil,
            startUpdater: true,
            debounceDuration: .milliseconds(800),
            cooldownInterval: 60,
            now: { Date() },
            performCheckAction: nil
        )
    }

    init(
        updaterController: SPUStandardUpdaterController?,
        startUpdater: Bool = true,
        debounceDuration: Duration = .milliseconds(800),
        cooldownInterval: TimeInterval = 60,
        now: @escaping () -> Date = { Date() },
        performCheckAction: (@MainActor (SparkleUpdaterController) -> Void)? = nil
    ) {
        self.updaterController = updaterController
        self.debounceDuration = debounceDuration
        self.cooldownInterval = cooldownInterval
        self.now = now
        self.performCheckAction = performCheckAction
        super.init()
#if DEBUG
        // Isolated screenshot review only: pretend a newer release exists.
        if let version = ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_UPDATE"],
           !version.isEmpty {
            availability = .available(version: version)
        }
#endif

        if let updaterController {
            configureUpdaterSubscriptions(for: updaterController.updater)
            setupSparkleWindowObserver()
        } else if startUpdater {
            let controller = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: self,
                userDriverDelegate: self
            )
            self.updaterController = controller
            configureUpdaterSubscriptions(for: controller.updater)
            setupSparkleWindowObserver()
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
        if let updater = updaterController?.updater {
            return updater.canCheckForUpdates && !updater.sessionInProgress
        }
        return canCheckForUpdates
    }

    func checkForUpdates() {
        if let performCheckAction {
            performCheckAction(self)
            return
        }
        guard let updater = updaterController?.updater, updater.canCheckForUpdates else {
            return
        }
        updater.checkForUpdates()
    }

    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        let previous = automaticallyChecksForUpdates
        Self.logger.info(
            "stage=updateCheck setAutomaticallyChecksForUpdates previous=\(previous, privacy: .public) enabled=\(enabled, privacy: .public)"
        )

        automaticallyChecksForUpdates = enabled
        if let updater = updaterController?.updater {
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

    private func elevateSparkleWindowIfNeeded(_ window: NSWindow) {
        guard window.level != .floating,
              let controller = window.windowController,
              Bundle(for: type(of: controller)) == Bundle(for: SPUUpdater.self)
        else { return }

        window.level = .floating
        window.hidesOnDeactivate = true
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
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
        Task { @MainActor in self.apply(.foundUpdate(version: version)) }
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
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        true
    }
}

/// A standard Check for Updates button suitable for SwiftUI Menu commands.
struct CheckForUpdatesCommandButton: View {
    @ObservedObject var controller = SparkleUpdaterController.shared

    var body: some View {
        Button(AppLocalization.string("Check for Updates…")) {
            controller.checkForUpdates()
        }
        .disabled(!controller.canCheckForUpdates)
    }
}

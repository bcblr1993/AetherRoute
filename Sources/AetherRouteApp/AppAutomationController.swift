import AppKit
import AetherRouteKit
import Carbon.HIToolbox
import Combine
import Foundation
import UserNotifications

enum NotificationPermissionState: Equatable {
    case notRequested
    case authorized
    case denied
    case unavailable
}

enum GlobalShortcutRegistrationState: Equatable {
    case disabled
    case active
    case conflict(String)
}

@MainActor
final class AppAutomationController: ObservableObject {
    @Published private(set) var shortcutPreferences: GlobalShortcutPreferences
    @Published private(set) var shortcutState: GlobalShortcutRegistrationState = .disabled
    @Published private(set) var shortcutMessage: String?
    @Published private(set) var networkAutomationPreferences: NetworkAutomationPreferences
    @Published private(set) var currentNetworkEnvironment: NetworkEnvironmentSnapshot?
    @Published private(set) var networkAutomationMessage: String?
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var notificationPermission: NotificationPermissionState
    @Published private(set) var subscriptionNotificationsEnabled: Bool
    @Published private(set) var proxySwitchNotificationsEnabled: Bool

    private static let notificationsPreferenceKey =
        "AetherRoute.ConnectionNotificationsEnabled"
    private static let subscriptionNotificationsPreferenceKey =
        "AetherRoute.SubscriptionNotificationsEnabled"
    private static let proxySwitchNotificationsPreferenceKey =
        "AetherRoute.ProxySwitchNotificationsEnabled"
    private static let proxySwitchNotificationIdentifier =
        "AetherRoute.ProxySwitch"
    private static let subscriptionAlertHistoryKey =
        "AetherRoute.SubscriptionAlertLastSent"
    private static let subscriptionNotificationIdentifier =
        "AetherRoute.SubscriptionAttention"
    /// The same alert for the same profile is repeated at most once a day.
    private static let subscriptionAlertInterval: TimeInterval = 24 * 60 * 60
    private static let notificationIdentifier =
        "AetherRoute.ConnectionAttention"

    private let tunnel: TunnelManager
    private let distribution: IndependentDistributionController
    private let shortcutStore: AppAutomationPreferenceStore
    private let networkAutomationStore: NetworkAutomationPreferenceStore
    private let userDefaults: UserDefaults
    private let notificationCenter: UNUserNotificationCenter
    private let isUIReviewMode: Bool
    private var hotKeyRegistrar: GlobalHotKeyRegistrar?
    private var stateObservation: AnyCancellable?
    private var licenseAccessObservation: AnyCancellable?
    private var privacyObservation: AnyCancellable?
    private var subscriptionObservation: AnyCancellable?
    private var proxySwitchObservation: AnyCancellable?
    private var licenseRefreshTask: Task<Void, Never>?
    private var networkEnvironmentTask: Task<Void, Never>?
    private var lastEvaluatedEnvironment: NetworkEnvironmentSnapshot?
    private var previousTunnelState: TunnelManager.State

    init(
        tunnel: TunnelManager,
        distribution: IndependentDistributionController,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard,
        notificationCenter: UNUserNotificationCenter = .current()
    ) {
        self.tunnel = tunnel
        self.distribution = distribution
        self.userDefaults = userDefaults
        self.notificationCenter = notificationCenter
        shortcutStore = AppAutomationPreferenceStore(defaults: userDefaults)
        networkAutomationStore = NetworkAutomationPreferenceStore(defaults: userDefaults)
#if AETHERROUTE_PERFORMANCE_MEASUREMENT
        isUIReviewMode = environment["AETHERROUTE_UI_REVIEW"] != nil
            || environment["AETHERROUTE_PERFORMANCE_MEASUREMENT"] != nil
#elseif DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        isUIReviewMode = environment["AETHERROUTE_UI_REVIEW"] != nil
#else
        isUIReviewMode = false
#endif
        previousTunnelState = tunnel.state

        if isUIReviewMode,
           environment["AETHERROUTE_UI_REVIEW_AUTOMATION"] == "1" {
            shortcutPreferences = GlobalShortcutPreferences(isEnabled: true)
            networkAutomationPreferences = NetworkAutomationPreferences()
            notificationsEnabled = true
            notificationPermission = .authorized
            shortcutState = .active
            subscriptionNotificationsEnabled = false
            proxySwitchNotificationsEnabled = false
        } else {
            shortcutPreferences = shortcutStore.load()
            networkAutomationPreferences = networkAutomationStore.load()
            notificationsEnabled = userDefaults.bool(
                forKey: Self.notificationsPreferenceKey
            )
            notificationPermission = .notRequested
            subscriptionNotificationsEnabled = userDefaults.bool(
                forKey: Self.subscriptionNotificationsPreferenceKey
            )
            proxySwitchNotificationsEnabled = userDefaults.bool(
                forKey: Self.proxySwitchNotificationsPreferenceKey
            )
        }

        // Every subscription refresh replaces the active profile, so its usage
        // is re-checked whenever the provider reports new numbers.
        subscriptionObservation = tunnel.$activeProfile
            .combineLatest(tunnel.$activeProfileSummary)
            .map { profile, summary -> SubscriptionUsage? in
                if let usage = profile?.subscription?.usage {
                    return usage
                }
                guard let profile, let summary else { return nil }
                let reportedAt = profile.subscription?.lastUpdatedAt
                    ?? profile.subscription?.lastCheckedAt
                    ?? profile.importedAt
                return SubscriptionUsage.fallback(from: summary, reportedAt: reportedAt)
            }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] usage in
                self?.notifyIfSubscriptionNeedsAttention(usage)
            }
        proxySwitchObservation = tunnel.proxySwitchEvents
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.notifyProxySwitch(event)
            }
        stateObservation = tunnel.$state
            .dropFirst()
            .sink { [weak self] state in
                self?.handleTunnelStateChange(state)
            }
        licenseAccessObservation = distribution.$connectionAccess
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak tunnel] access in
                tunnel?.setDistributionConnectionAccess(access)
            }
        privacyObservation = tunnel.$hasAcceptedPrivacyDisclosure
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isAccepted in
                if isAccepted {
                    self?.startLicenseRefreshLoopIfNeeded()
                } else {
                    self?.licenseRefreshTask?.cancel()
                    self?.licenseRefreshTask = nil
                }
            }

        guard !isUIReviewMode else { return }
        applyGlobalShortcuts()
        refreshCurrentNetworkEnvironment()
        updateNetworkEnvironmentMonitoring()
        Task { await refreshNotificationAuthorization() }
    }

    deinit {
        licenseRefreshTask?.cancel()
        networkEnvironmentTask?.cancel()
    }

    func setGlobalShortcutsEnabled(_ isEnabled: Bool) {
        var updated = shortcutPreferences
        updated.isEnabled = isEnabled
        persistAndApply(updated)
    }

    func assignShortcut(
        _ key: GlobalShortcutKey,
        to action: GlobalShortcutAction
    ) {
        var updated = shortcutPreferences
        updated.assign(key, to: action)
        persistAndApply(updated)
    }

    func refreshCurrentNetworkEnvironment() {
        guard !isUIReviewMode else { return }
        currentNetworkEnvironment = PhysicalUplinkDetector.currentNetworkEnvironment()
    }

    func setNetworkAutomationEnabled(_ isEnabled: Bool) {
        var updated = networkAutomationPreferences
        updated.isEnabled = isEnabled
        persistAndApplyNetworkAutomation(updated, evaluateImmediately: isEnabled)
    }

    @discardableResult
    func addOrUpdateNetworkRule(_ rule: NetworkAutomationRule) -> Bool {
        do {
            let validatedRule = try rule.validated()
            var updated = networkAutomationPreferences
            if let existingIndex = updated.rules.firstIndex(where: { $0.id == validatedRule.id }) {
                updated.rules[existingIndex] = validatedRule
            } else {
                updated.rules.append(validatedRule)
            }
            return persistAndApplyNetworkAutomation(updated, evaluateImmediately: true)
        } catch {
            networkAutomationMessage = error.localizedDescription
            return false
        }
    }

    func removeNetworkRule(id: UUID) {
        var updated = networkAutomationPreferences
        updated.rules.removeAll { $0.id == id }
        persistAndApplyNetworkAutomation(updated, evaluateImmediately: false)
    }

    func setNetworkRuleEnabled(id: UUID, isEnabled: Bool) {
        var updated = networkAutomationPreferences
        guard let index = updated.rules.firstIndex(where: { $0.id == id }) else { return }
        updated.rules[index].isEnabled = isEnabled
        persistAndApplyNetworkAutomation(updated, evaluateImmediately: isEnabled)
    }

    @discardableResult
    private func persistAndApplyNetworkAutomation(
        _ preferences: NetworkAutomationPreferences,
        evaluateImmediately: Bool
    ) -> Bool {
        do {
            let validated = try preferences.validated()
            try networkAutomationStore.save(validated)
            networkAutomationPreferences = validated
            networkAutomationMessage = nil
            updateNetworkEnvironmentMonitoring()
            if evaluateImmediately {
                evaluateNetworkAutomationIfNeeded(force: true)
            }
            return true
        } catch {
            networkAutomationMessage = error.localizedDescription
            return false
        }
    }

    private func updateNetworkEnvironmentMonitoring() {
        networkEnvironmentTask?.cancel()
        networkEnvironmentTask = nil
        guard !isUIReviewMode, networkAutomationPreferences.isEnabled else { return }
        networkEnvironmentTask = Task { [weak self] in
            guard let self else { return }
            self.evaluateNetworkAutomationIfNeeded(force: false)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(10))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                self.evaluateNetworkAutomationIfNeeded(force: false)
            }
        }
    }

    private func evaluateNetworkAutomationIfNeeded(force: Bool) {
        guard !isUIReviewMode else { return }
        let snapshot = PhysicalUplinkDetector.currentNetworkEnvironment()
        currentNetworkEnvironment = snapshot
        guard networkAutomationPreferences.isEnabled, let snapshot else { return }
        if !force, lastEvaluatedEnvironment == snapshot {
            return
        }
        lastEvaluatedEnvironment = snapshot
        guard let action = networkAutomationPreferences.matchedAction(for: snapshot) else {
            return
        }
        switch action {
        case let .setRoutingMode(mode):
            guard tunnel.routingMode != mode, tunnel.canChangeRoutingMode else { return }
            Task { await tunnel.setRoutingMode(mode) }
        case .connect:
            guard !tunnel.isEnabled, tunnel.canPerformPrimaryAction else { return }
            Task { await tunnel.setEnabled(true) }
        case .disconnect:
            guard tunnel.isEnabled, tunnel.canPerformPrimaryAction else { return }
            Task { await tunnel.setEnabled(false) }
        }
    }

    /// Optional, off by default: permission is only requested when the
    /// person turns this on.
    func setSubscriptionNotificationsEnabled(_ isEnabled: Bool) async {
        guard !isUIReviewMode else {
            subscriptionNotificationsEnabled = isEnabled
            return
        }
        if !isEnabled {
            subscriptionNotificationsEnabled = false
            userDefaults.set(false, forKey: Self.subscriptionNotificationsPreferenceKey)
            notificationCenter.removePendingNotificationRequests(
                withIdentifiers: [Self.subscriptionNotificationIdentifier]
            )
            return
        }
        let granted: Bool
        do {
            granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound]
            )
            notificationPermission = granted ? .authorized : .denied
        } catch {
            granted = false
            notificationPermission = .unavailable
        }
        subscriptionNotificationsEnabled = granted
        userDefaults.set(granted, forKey: Self.subscriptionNotificationsPreferenceKey)
        if granted {
            notifyIfSubscriptionNeedsAttention(tunnel.effectiveActiveSubscriptionUsage)
        }
    }

    /// Optional, off by default, like subscription alerts.
    func setProxySwitchNotificationsEnabled(_ isEnabled: Bool) async {
        guard !isUIReviewMode else {
            proxySwitchNotificationsEnabled = isEnabled
            return
        }
        if !isEnabled {
            proxySwitchNotificationsEnabled = false
            userDefaults.set(false, forKey: Self.proxySwitchNotificationsPreferenceKey)
            notificationCenter.removeDeliveredNotifications(
                withIdentifiers: [Self.proxySwitchNotificationIdentifier]
            )
            return
        }
        let granted: Bool
        do {
            granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound]
            )
            notificationPermission = granted ? .authorized : .denied
        } catch {
            granted = false
            notificationPermission = .unavailable
        }
        proxySwitchNotificationsEnabled = granted
        userDefaults.set(granted, forKey: Self.proxySwitchNotificationsPreferenceKey)
    }

    /// No node, group or profile names, as with every other alert: the
    /// Proxies page shows the details. Skipped while the app is in front,
    /// where the page already says what happened.
    private func notifyProxySwitch(_ event: ProxySwitchEvent) {
        guard proxySwitchNotificationsEnabled, !isUIReviewMode,
              notificationPermission == .authorized,
              !NSApplication.shared.isActive else { return }
        let content = UNMutableNotificationContent()
        switch event.reason {
        case .unresponsive:
            content.title = AppLocalization.string("Switched to a working node")
            content.body = AppLocalization.string("The node in use stopped answering. Open AetherRoute to see which node took over.")
        case .preferredRecovered:
            content.title = AppLocalization.string("Back on your preferred node")
            content.body = AppLocalization.string("Your preferred node answers again and carries traffic once more.")
        }
        // One entry in Notification Center, replaced by the next switch.
        notificationCenter.add(UNNotificationRequest(
            identifier: Self.proxySwitchNotificationIdentifier,
            content: content,
            trigger: nil
        ))
    }

    private func notifyIfSubscriptionNeedsAttention(_ usage: SubscriptionUsage?) {
        guard subscriptionNotificationsEnabled, !isUIReviewMode,
              let profileID = tunnel.activeProfileID else { return }
        let alert = SubscriptionUsageAlert.evaluate(usage, now: .now)
        let kind: String
        let title: String
        switch alert {
        case .none: return
        case .low:
            kind = "low"
            title = AppLocalization.string("Subscription traffic is running low")
        case .expiring:
            kind = "expiring"
            title = AppLocalization.string("Subscription expires soon")
        case .exhausted:
            kind = "exhausted"
            title = AppLocalization.string("Subscription traffic is used up")
        case .expired:
            kind = "expired"
            title = AppLocalization.string("Subscription has expired")
        }
        var history = userDefaults.dictionary(forKey: Self.subscriptionAlertHistoryKey)
            as? [String: Double] ?? [:]
        let key = "\(profileID.uuidString)|\(kind)"
        let now = Date.now.timeIntervalSince1970
        if let last = history[key], now - last < Self.subscriptionAlertInterval { return }
        history[key] = now
        // Keep the record small: drop entries older than a week.
        history = history.filter { now - $0.value < 7 * 24 * 60 * 60 }
        userDefaults.set(history, forKey: Self.subscriptionAlertHistoryKey)

        // Like connection alerts, no profile name or traffic figures.
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = AppLocalization.string("Open AetherRoute to see your subscription details.")
        content.sound = .default
        notificationCenter.add(UNNotificationRequest(
            identifier: Self.subscriptionNotificationIdentifier,
            content: content,
            trigger: nil
        ))
    }

    func setNotificationsEnabled(_ isEnabled: Bool) async {
        guard !isUIReviewMode else {
            notificationsEnabled = isEnabled
            notificationPermission = isEnabled ? .authorized : .notRequested
            return
        }

        if !isEnabled {
            notificationsEnabled = false
            userDefaults.set(false, forKey: Self.notificationsPreferenceKey)
            notificationCenter.removePendingNotificationRequests(
                withIdentifiers: [Self.notificationIdentifier]
            )
            await refreshNotificationAuthorization()
            return
        }

        do {
            let granted = try await notificationCenter.requestAuthorization(
                options: [.alert, .sound]
            )
            notificationsEnabled = granted
            notificationPermission = granted ? .authorized : .denied
            userDefaults.set(granted, forKey: Self.notificationsPreferenceKey)
        } catch {
            notificationsEnabled = false
            notificationPermission = .unavailable
            userDefaults.set(false, forKey: Self.notificationsPreferenceKey)
        }
    }

    private func persistAndApply(_ preferences: GlobalShortcutPreferences) {
        do {
            try shortcutStore.save(preferences)
            shortcutPreferences = preferences
            shortcutMessage = nil
            applyGlobalShortcuts()
        } catch {
            shortcutMessage = AppLocalization.string(
                "The shortcut settings could not be saved."
            )
        }
    }

    private func applyGlobalShortcuts() {
        hotKeyRegistrar?.unregisterAll()
        hotKeyRegistrar = nil

        guard shortcutPreferences.isEnabled else {
            shortcutState = .disabled
            return
        }

        let registrar = GlobalHotKeyRegistrar { [weak self] action in
            self?.performShortcut(action)
        }
        if let failedKey = registrar.register(shortcutPreferences) {
            shortcutState = .conflict(failedKey.displayTitle)
            return
        }
        hotKeyRegistrar = registrar
        shortcutState = .active
    }

    private func performShortcut(_ action: GlobalShortcutAction) {
        shortcutMessage = nil
        switch action {
        case .toggleConnection:
            guard tunnel.canPerformPrimaryAction else {
                shortcutMessage = AppLocalization.string(
                    "The connection is busy or not ready."
                )
                return
            }
            Task { await tunnel.setEnabled(!tunnel.isEnabled) }
        case .routingRule:
            selectRoutingMode(.rule)
        case .routingGlobal:
            selectRoutingMode(.global)
        case .routingDirect:
            selectRoutingMode(.direct)
        }
    }

    private func selectRoutingMode(_ mode: RoutingMode) {
        guard tunnel.canChangeRoutingMode else {
            shortcutMessage = AppLocalization.string(
                "The routing mode is temporarily unavailable."
            )
            return
        }
        Task { await tunnel.setRoutingMode(mode) }
    }

    private func refreshNotificationAuthorization() async {
        let settings = await notificationCenter.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            notificationPermission = .authorized
        case .denied:
            notificationPermission = .denied
            if notificationsEnabled {
                notificationsEnabled = false
                userDefaults.set(false, forKey: Self.notificationsPreferenceKey)
            }
        case .notDetermined:
            notificationPermission = .notRequested
        @unknown default:
            notificationPermission = .unavailable
        }
    }

    private func startLicenseRefreshLoopIfNeeded() {
        guard distribution.isConfigured, licenseRefreshTask == nil else {
            return
        }
        licenseRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.distribution.refreshLicense()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(86_400))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.distribution.refreshLicense()
            }
        }
    }

    private func handleTunnelStateChange(_ state: TunnelManager.State) {
        defer { previousTunnelState = state }
        guard notificationsEnabled,
              notificationPermission == .authorized,
              !NSApplication.shared.isActive else {
            return
        }

        switch state {
        case .failed:
            deliverNotification(
                title: AppLocalization.string("AetherRoute needs attention"),
                body: AppLocalization.string(
                    "The connection could not continue. Open AetherRoute to review the recovery steps."
                )
            )
        case .disconnected where previousTunnelState == .connected || previousTunnelState == .recovering:
            deliverNotification(
                title: AppLocalization.string("AetherRoute disconnected"),
                body: AppLocalization.string(
                    "Traffic has returned to the normal network path."
                )
            )
        default:
            break
        }
    }

    private func deliverNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: Self.notificationIdentifier,
            content: content,
            trigger: nil
        )
        notificationCenter.add(request)
    }
}

@MainActor
private final class GlobalHotKeyRegistrar {
    private static let signature: OSType = 0x4145_5448 // AETH

    private let actionHandler: (GlobalShortcutAction) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef] = []
    private var actionsByIdentifier: [UInt32: GlobalShortcutAction] = [:]

    init(actionHandler: @escaping (GlobalShortcutAction) -> Void) {
        self.actionHandler = actionHandler
    }

    /// Returns the first key the system refused to register.
    func register(
        _ preferences: GlobalShortcutPreferences
    ) -> GlobalShortcutKey? {
        unregisterAll()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let installStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            aetherRouteGlobalHotKeyHandler,
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard installStatus == noErr else {
            return preferences[.toggleConnection]
        }

        for (offset, action) in GlobalShortcutAction.allCases.enumerated() {
            let identifier = UInt32(offset + 1)
            let key = preferences[action]
            var reference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                key.carbonKeyCode,
                key.carbonModifiers,
                EventHotKeyID(
                    signature: Self.signature,
                    id: identifier
                ),
                GetApplicationEventTarget(),
                0,
                &reference
            )
            guard status == noErr, let reference else {
                unregisterAll()
                return key
            }
            hotKeys.append(reference)
            actionsByIdentifier[identifier] = action
        }
        return nil
    }

    func unregisterAll() {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys.removeAll(keepingCapacity: false)
        actionsByIdentifier.removeAll(keepingCapacity: false)
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    func receive(identifier: UInt32) {
        guard let action = actionsByIdentifier[identifier] else { return }
        actionHandler(action)
    }
}

private func aetherRouteGlobalHotKeyHandler(
    _: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }
    var identifier = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &identifier
    )
    guard status == noErr else { return status }

    let address = UInt(bitPattern: userData)
    Task { @MainActor in
        guard let pointer = UnsafeMutableRawPointer(bitPattern: address) else {
            return
        }
        Unmanaged<GlobalHotKeyRegistrar>
            .fromOpaque(pointer)
            .takeUnretainedValue()
            .receive(identifier: identifier.id)
    }
    return noErr
}

private extension GlobalShortcutKey {
    var carbonKeyCode: UInt32 {
        let code: Int = switch self {
        case .controlOptionC, .controlShiftC: kVK_ANSI_C
        case .controlOptionP, .controlShiftP: kVK_ANSI_P
        case .controlOptionSpace, .controlShiftSpace: kVK_Space
        case .controlOptionR: kVK_ANSI_R
        case .controlOptionG: kVK_ANSI_G
        case .controlOptionD: kVK_ANSI_D
        case .controlOption1: kVK_ANSI_1
        case .controlOption2: kVK_ANSI_2
        case .controlOption3: kVK_ANSI_3
        }
        return UInt32(code)
    }

    var carbonModifiers: UInt32 {
        switch self {
        case .controlShiftC, .controlShiftP, .controlShiftSpace:
            UInt32(controlKey | shiftKey)
        default:
            UInt32(controlKey | optionKey)
        }
    }
}

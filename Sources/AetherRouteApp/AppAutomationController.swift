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
    @Published private(set) var notificationsEnabled: Bool
    @Published private(set) var notificationPermission: NotificationPermissionState

    private static let notificationsPreferenceKey =
        "AetherRoute.ConnectionNotificationsEnabled"
    private static let notificationIdentifier =
        "AetherRoute.ConnectionAttention"

    private let tunnel: TunnelManager
    private let distribution: IndependentDistributionController
    private let shortcutStore: AppAutomationPreferenceStore
    private let userDefaults: UserDefaults
    private let notificationCenter: UNUserNotificationCenter
    private let isUIReviewMode: Bool
    private var hotKeyRegistrar: GlobalHotKeyRegistrar?
    private var stateObservation: AnyCancellable?
    private var licenseAccessObservation: AnyCancellable?
    private var privacyObservation: AnyCancellable?
    private var licenseRefreshTask: Task<Void, Never>?
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
            notificationsEnabled = true
            notificationPermission = .authorized
            shortcutState = .active
        } else {
            shortcutPreferences = shortcutStore.load()
            notificationsEnabled = userDefaults.bool(
                forKey: Self.notificationsPreferenceKey
            )
            notificationPermission = .notRequested
        }

        stateObservation = tunnel.$state
            .dropFirst()
            .sink { [weak self] state in
                self?.handleTunnelStateChange(state)
            }
        licenseAccessObservation = distribution.$connectionAccess
            .removeDuplicates()
            .sink { [weak tunnel] access in
                tunnel?.setDistributionConnectionAccess(access)
            }
        privacyObservation = tunnel.$hasAcceptedPrivacyDisclosure
            .removeDuplicates()
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
        Task { await refreshNotificationAuthorization() }
    }

    deinit {
        licenseRefreshTask?.cancel()
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
                "Disconnect before changing the routing mode."
            )
            return
        }
        tunnel.routingMode = mode
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
        case .disconnected where previousTunnelState == .connected:
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

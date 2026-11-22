import AppKit
import AetherRouteKit
import Darwin
import OSLog
import SwiftUI
@preconcurrency import UserNotifications

@MainActor
final class AetherRouteApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSUserInterfaceValidations, UNUserNotificationCenterDelegate {
    private static let lifecycleLogger = AppLog.logger(category: AppLog.Category.appLifecycle)

    var tunnel: TunnelManager?
    private var terminationReplyPending = false
    private var signalTerminationPending = false
    private var terminationSignalSource: (any DispatchSourceSignal)?

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppDockVisibilityController.shared.apply()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDockVisibilityController.shared.apply(force: true)
        DispatchQueue.main.async {
            AppDockVisibilityController.shared.apply(force: true)
        }
        installTerminationSignalSource()
        installQuitAppleEventHandler()
        UNUserNotificationCenter.current().delegate = self
        Task { @MainActor [weak self] in
            await self?.tunnel?.prepare()
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let identifier = response.notification.request.identifier
        defer { completionHandler() }
        DispatchQueue.main.async {
            if identifier.hasPrefix("com.aetherroute.update.") {
                NSApplication.shared.activate(ignoringOtherApps: true)
                #if !AETHERROUTE_APP_STORE
                SparkleUpdaterController.shared.checkForUpdates()
                #endif
            } else {
                AppWindowManager.shared.showMainWindow()
            }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            tunnel?.handleIncomingExternalURL(url)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        AppDockVisibilityController.shared.apply(force: true)
        if !flag {
            AppWindowManager.shared.showMainWindow()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
        return true
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        AppWindowManager.shared.isTerminating = true
        Self.lifecycleLogger.info(
            "stage=applicationTermination source=AppKit requested pending=\(self.terminationReplyPending, privacy: .public)"
        )
        guard !terminationReplyPending, let tunnel else {
            return terminationReplyPending ? .terminateLater : .terminateNow
        }
        guard tunnel.requiresDisconnectBeforeApplicationTermination else {
            return .terminateNow
        }

        terminationReplyPending = true
        tunnel.prepareForApplicationTermination()
        Task { @MainActor [weak self, weak sender] in
            guard let self else { return }
            let disconnected = await tunnel
                .disconnectForApplicationTermination()
            self.terminationReplyPending = false
            if !disconnected {
                tunnel.isApplicationTerminating = false
                tunnel.resumeAfterCancelledApplicationTermination()
                AppWindowManager.shared.isTerminating = false
            }
            (sender ?? NSApplication.shared).reply(toApplicationShouldTerminate: disconnected)
        }
        return .terminateLater
    }

    @objc func terminate(_ sender: Any?) {
        guard !terminationReplyPending && !signalTerminationPending else {
            Self.lifecycleLogger.info(
                "stage=applicationTermination terminateAction ignored reason=pending"
            )
            return
        }
        NSApplication.shared.terminate(sender)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Self.lifecycleLogger.info("stage=applicationTermination willTerminate")
        terminationSignalSource?.cancel()
        terminationSignalSource = nil
        tunnel?.prepareForApplicationTermination()
        tunnel = nil
    }

    @objc func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        true
    }

    @objc func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        true
    }

    private func installQuitAppleEventHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleQuitAppleEvent(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEQuitApplication)
        )
        Self.lifecycleLogger.info(
            "stage=applicationTermination quitAppleEventHandler armed"
        )
    }

    @objc func handleQuitAppleEvent(
        _ event: NSAppleEventDescriptor,
        withReplyEvent replyEvent: NSAppleEventDescriptor
    ) {
        guard !terminationReplyPending && !signalTerminationPending else {
            Self.lifecycleLogger.info(
                "stage=applicationTermination quitAppleEvent ignored reason=pending"
            )
            return
        }
        Self.lifecycleLogger.info(
            "stage=applicationTermination quitAppleEvent received"
        )
        tunnel?.prepareForApplicationTermination()
        NSApplication.shared.terminate(nil)
    }

    private func installTerminationSignalSource() {
        guard terminationSignalSource == nil else { return }

        // applicationShouldTerminate(_:) is invoked for AppKit termination,
        // not for the default Unix SIGTERM disposition. Keep the signal
        // handler async-signal-safe by asking Dispatch to monitor SIGTERM,
        // then re-enter the existing AppKit termination path on the main
        // queue so NetworkExtension can restore routes and DNS before exit.
        Darwin.signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(
            signal: SIGTERM,
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                await self?.handleTerminationSignal()
            }
        }
        source.resume()
        terminationSignalSource = source
        Self.lifecycleLogger.info(
            "stage=applicationTermination signal=SIGTERM armed"
        )
    }

    private func handleTerminationSignal() async {
        guard !signalTerminationPending else {
            Self.lifecycleLogger.info(
                "stage=applicationTermination signal=SIGTERM ignored reason=pending"
            )
            return
        }
        signalTerminationPending = true
        AppWindowManager.shared.isTerminating = true
        Self.lifecycleLogger.info(
            "stage=applicationTermination signal=SIGTERM received"
        )
        tunnel?.prepareForApplicationTermination()

        let disconnected = if let tunnel {
            await tunnel.disconnectForApplicationTermination()
        } else {
            true
        }
        guard disconnected else {
            signalTerminationPending = false
            tunnel?.isApplicationTerminating = false
            AppWindowManager.shared.isTerminating = false
            Self.lifecycleLogger.fault(
                "stage=applicationTermination signal=SIGTERM cancelled reason=networkRecoveryFailed"
            )
            return
        }

        Self.lifecycleLogger.info(
            "stage=applicationTermination signal=SIGTERM exit"
        )
        Darwin.exit(EXIT_SUCCESS)
    }
}

/// Quit requested from a SwiftUI control. Never call `terminate` from a
/// main-queue block or a main-actor task: while connected,
/// `applicationShouldTerminate` answers `.terminateLater` and AppKit waits in
/// a nested run loop for the disconnect to reply, but that reply is itself
/// main-actor work queued behind the block that is still running, so the app
/// never quits. A run-loop perform leaves the main queue free.
@MainActor
enum AppTermination {
    static func request() {
        NSApp.perform(
            #selector(NSApplication.terminate(_:)),
            with: nil,
            afterDelay: 0
        )
    }
}

struct WindowChromeSynchronizer: NSViewRepresentable {
    let title: String
    let showsTitle: Bool
    var isMainWindow: Bool = false
    /// The main window keeps SwiftUI's own toolbar: the page title, page
    /// actions, search and the sidebar button sit in the Liquid Glass
    /// toolbar (1.5.2). Settings keeps the compact title bar, as System
    /// Settings does.
    var usesNativeToolbar: Bool = false

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.update(title: title, showsTitle: showsTitle, isMainWindow: isMainWindow, usesNativeToolbar: usesNativeToolbar)
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.update(title: title, showsTitle: showsTitle, isMainWindow: isMainWindow, usesNativeToolbar: usesNativeToolbar)
    }
}

final class WindowChromeView: NSView {
    private static let automaticSidebarToggleIdentifier =
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"

    private var expectedTitle = ""
    private var showsWindowTitle = true
    private var isMainWindow = false
    private var usesNativeToolbar = false
    private var chromeUpdateScheduled = false
    nonisolated(unsafe) private weak var observedWindow: NSWindow?
    nonisolated(unsafe) private var titleObservation: NSKeyValueObservation?
    private let visibilityCoordinator = WindowVisibilityCoordinator()

    func update(title: String, showsTitle: Bool, isMainWindow: Bool = false, usesNativeToolbar: Bool = false) {
        expectedTitle = title
        showsWindowTitle = showsTitle
        self.isMainWindow = isMainWindow
        self.usesNativeToolbar = usesNativeToolbar
        scheduleApplyWindowChrome()
        if isMainWindow, let window {
            AppWindowManager.shared.registerMainWindow(window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        visibilityCoordinator.stopObserving()
        observedWindow = window
        visibilityCoordinator.observe(window)
        if isMainWindow, let window {
            AppWindowManager.shared.registerMainWindow(window)
        }
        titleObservation = window?.observe(\.title, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.applyWindowChrome()
            }
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toolbarWillAddItem(_:)),
            name: NSToolbar.willAddItemNotification,
            object: window?.toolbar
        )
        scheduleApplyWindowChrome()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applyWindowChrome()
            self?.visibilityCoordinator.recoverIfNeeded()
        }
    }

    private func scheduleApplyWindowChrome() {
        guard !chromeUpdateScheduled else { return }
        chromeUpdateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.chromeUpdateScheduled = false
            self.applyWindowChrome()
        }
    }

    @objc
    private func toolbarWillAddItem(_ notification: Notification) {
        guard let item = notification.userInfo?["item"] as? NSToolbarItem,
              item.itemIdentifier.rawValue ==
              Self.automaticSidebarToggleIdentifier else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applyWindowChrome()
        }
    }

    private func applyWindowChrome() {
        guard let window = observedWindow ?? window else { return }
        // SwiftUI owns the title and toolbar of a window that uses them.
        guard !usesNativeToolbar else { return }
        if window.title != expectedTitle {
            window.title = expectedTitle
        }
        if !window.titlebarAppearsTransparent {
            window.titlebarAppearsTransparent = true
        }
        let targetVisibility: NSWindow.TitleVisibility = showsWindowTitle ? .visible : .hidden
        if window.titleVisibility != targetVisibility {
            window.titleVisibility = targetVisibility
        }

        guard let toolbar = window.toolbar else { return }
        if toolbar.isVisible {
            toolbar.isVisible = false
        }
        while let index = toolbar.items.firstIndex(where: {
            $0.itemIdentifier.rawValue ==
                Self.automaticSidebarToggleIdentifier
        }) {
            toolbar.removeItem(at: index)
        }
    }

    nonisolated private func stopObservingWindow() {
        NotificationCenter.default.removeObserver(self)
        titleObservation?.invalidate()
        titleObservation = nil
        observedWindow = nil
    }

    deinit {
        stopObservingWindow()
    }
}

@MainActor
private enum NavigationShortcutMonitor {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            event in
            let modifiers = event.modifierFlags.intersection(
                .deviceIndependentFlagsMask
            )
            guard modifiers == .command,
                  let keyWindow = NSApp.keyWindow,
                  AppWindowManager.isMainWindowCandidate(keyWindow),
                  keyWindow.attachedSheet == nil,
                  !(keyWindow.firstResponder is NSTextView),
                  let key = event.charactersIgnoringModifiers,
                  let section = section(for: key)
            else { return event }
            NotificationCenter.default.post(
                name: .aetherRouteNavigateToSection,
                object: section.rawValue
            )
            return nil
        }
    }

    private static func section(for key: String) -> AppSection? {
        switch key {
        case "1": return .overview
        case "2": return .proxies
        case "3": return .connections
        case "4": return .profiles
        case "5": return .rules
        case "6": return .dns
        default: return nil
        }
    }
}

@main
struct AetherRouteApp: App {
    @NSApplicationDelegateAdaptor(AetherRouteApplicationDelegate.self)
    private var applicationDelegate
    @StateObject private var language: AppLanguageController
    @StateObject private var appearance: AppAppearanceController
    @StateObject private var dockVisibility: AppDockVisibilityController
    private let menuBarIconController: AppMenuBarIconController
    private let menuBarTrafficController: MenuBarTrafficController
    @StateObject private var startup: AppStartupController
    @StateObject private var tunnel: TunnelManager
    @StateObject private var automation: AppAutomationController
    @StateObject private var distribution:
        IndependentDistributionController
    @StateObject private var runtimeEnvironment:
        AppRuntimeEnvironmentController
    @ObservedObject private var updater = SparkleUpdaterController.shared

    init() {
        NavigationShortcutMonitor.install()
        _appearance = StateObject(wrappedValue: AppAppearanceController())
        let dockVisibility = AppDockVisibilityController.shared
        _dockVisibility = StateObject(wrappedValue: dockVisibility)
        menuBarIconController = AppMenuBarIconController.shared
        menuBarTrafficController = MenuBarTrafficController.shared
        _startup = StateObject(wrappedValue: AppStartupController.shared)
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] != nil {
            // MenuBarExtra can cause XCTest to observe a newly launched app as
            // background-only before SwiftUI has restored the main window.
            // UI review builds must be an ordinary foreground app so the test
            // runner can attach without relying on Dock or Finder activation.
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate()
        }
        switch ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_APPEARANCE"
        ] {
        case "dark":
            NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light":
            NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default:
            break
        }
#endif
        let language = AppLanguageController()
        let tunnel = TunnelManager()
        let distribution = IndependentDistributionController()
        distribution.loadLocalReceipt()
        _language = StateObject(wrappedValue: language)
        _tunnel = StateObject(wrappedValue: tunnel)
        _distribution = StateObject(wrappedValue: distribution)
        _automation = StateObject(
            wrappedValue: AppAutomationController(
                tunnel: tunnel,
                distribution: distribution
            )
        )
        _runtimeEnvironment = StateObject(
            wrappedValue: AppRuntimeEnvironmentController(tunnel: tunnel)
        )
        applicationDelegate.tunnel = tunnel
    }

    var body: some Scene {
        mainWindow

        MenuBarExtra {
            MenuBarContent(telemetry: tunnel.telemetryViewModel)
                .environmentObject(tunnel)
                .environmentObject(language)
                .environment(\.locale, language.locale)
                .id(language.preference)
        } label: {
            MenuBarStatusItemView(
                iconController: menuBarIconController,
                trafficController: menuBarTrafficController,
                isConnected: tunnel.isConnected,
                hasUpdate: updater.availability.availableVersion != nil
            )
            .equatable()
            .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appearance)
                .environmentObject(dockVisibility)
                .environmentObject(menuBarIconController)
                .environmentObject(menuBarTrafficController)
                .environmentObject(startup)
                .environmentObject(tunnel)
                .environmentObject(automation)
                .environmentObject(distribution)
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
    }

    private var isMenuPanelReview: Bool {
#if DEBUG
        ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PANEL"] == "1"
            && ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] != nil
#else
        false
#endif
    }

    private var mainWindow: some Scene {
        Window(productDisplayName, id: "main") {
            MainWindowRootHost {
                Group {
#if DEBUG
                    if isMenuPanelReview {
                        // Render the actual popover in an isolated review window so
                        // UI tools can exercise it without touching the host tunnel.
                        MenuBarContent(telemetry: tunnel.telemetryViewModel)
                            .preferredColorScheme(ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_APPEARANCE"] == "dark" ? .dark : .light)
                            .fixedSize(horizontal: true, vertical: true)
                    } else {
                        ContentView()
                    }
#else
                    ContentView()
#endif
                }
            }
            .environmentObject(tunnel)
            .environmentObject(runtimeEnvironment)
            .environmentObject(language)
            .environment(\.locale, language.locale)
        }
        .defaultSize(
            width: isMenuPanelReview ? AetherVisual.popoverWidth : AetherVisual.windowWidth,
            height: isMenuPanelReview ? 440 : AetherVisual.windowHeight
        )
        .windowResizability(isMenuPanelReview ? .contentSize : .contentMinSize)
        // A compact glass toolbar holding only the sidebar button (1.5.2);
        // each page draws its title and actions in its own header, aligned
        // with its content, and scrolls beneath the glass.
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommandButton()
#if AETHERROUTE_INDEPENDENT
                UninstallCommandButton()
#endif
            }
            CommandMenu(AppLocalization.string("Tunnel")) {
                Button(tunnel.primaryActionTitle) {
                    Task {
                        await tunnel.setEnabled(!tunnel.isEnabled)
                    }
                }
                .disabled(!tunnel.canPerformPrimaryAction)
                .keyboardShortcut("k", modifiers: .command)

                Button(AppLocalization.string("Reconnect")) {
                    Task {
                        await tunnel.reconnect()
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(!tunnel.isConnected)

                Divider()

                Menu(AppLocalization.string("Routing Mode")) {
                    Button(AppLocalization.string("Rule")) {
                        Task { await tunnel.setRoutingMode(.rule) }
                    }
                    .keyboardShortcut("1", modifiers: [.command, .option])

                    Button(AppLocalization.string("Global")) {
                        Task { await tunnel.setRoutingMode(.global) }
                    }
                    .keyboardShortcut("2", modifiers: [.command, .option])

                    Button(AppLocalization.string("Direct")) {
                        Task { await tunnel.setRoutingMode(.direct) }
                    }
                    .keyboardShortcut("3", modifiers: [.command, .option])
                }
                .disabled(!tunnel.canChangeRoutingMode)

#if !AETHERROUTE_APP_STORE
                Divider()

                Button(AppLocalization.string("Check for Updates…")) {
                    SparkleUpdaterController.shared.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
#endif
            }
            CommandMenu(AppLocalization.string("Navigate")) {
                Button(AppLocalization.string("Command Palette…")) {
                    AppWindowManager.shared.showMainWindow()
                    NotificationCenter.default.post(name: .aetherRouteToggleCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                ForEach(AppSection.allCases) { section in
                    Button(section.title) {
                        AppWindowManager.shared.showMainWindow()
                        NotificationCenter.default.post(
                            name: .aetherRouteNavigateToSection,
                            object: section.rawValue
                        )
                    }
                    .keyboardShortcut(
                        section.keyboardShortcut,
                        modifiers: .command
                    )
                }
                Divider()
                Button(AppLocalization.string("Previous proxy node")) {
                    Task {
                        await tunnel.cycleManualProxySelection(.previous)
                    }
                }
                .keyboardShortcut(
                    .leftArrow,
                    modifiers: [.command, .option]
                )
                .disabled(!tunnel.canCycleManualProxySelection)

                Button(AppLocalization.string("Next proxy node")) {
                    Task {
                        await tunnel.cycleManualProxySelection(.next)
                    }
                }
                .keyboardShortcut(
                    .rightArrow,
                    modifiers: [.command, .option]
                )
                .disabled(!tunnel.canCycleManualProxySelection)
            }

            CommandMenu(AppLocalization.string("Proxy")) {
                Button(AppLocalization.string("Copy Terminal Export Command")) {
                    guard let command = try? tunnel.localProxySettings
                        .shellEnvironmentCommand() else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])
                .disabled(!tunnel.canCopyTerminalProxyCommand)

                Button(AppLocalization.string("Copy Terminal Unset Command")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        LocalProxySettings.clearShellEnvironmentCommand,
                        forType: .string
                    )
                }
                .keyboardShortcut("u", modifiers: [.command, .control])
            }
        }
    }

    private var menuBarIcon: String {
        menuBarIconController.currentSymbol(isConnected: tunnel.isConnected)
    }

    /// The menu bar shows no text, so connection state has to reach VoiceOver
    /// through the accessibility label instead. It reuses the same status
    /// wording as the window rather than inventing a second vocabulary.
    private var menuBarAccessibilityLabel: String {
        let base = "\(productDisplayName) · \(tunnel.statusTitle)"
        guard updater.availability.availableVersion != nil else { return base }
        return "\(base) · \(AppLocalization.string("Update available"))"
    }

    private var productDisplayName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? "AetherRoute"
    }

}

private struct MenuBarVisibilitySynchronizer: NSViewRepresentable {
    let onVisibilityChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MenuBarVisibilityTrackerView {
        let view = MenuBarVisibilityTrackerView()
        view.onVisibilityChanged = onVisibilityChanged
        return view
    }

    func updateNSView(_ nsView: MenuBarVisibilityTrackerView, context: Context) {
        nsView.onVisibilityChanged = onVisibilityChanged
    }
}

private final class MenuBarVisibilityTrackerView: NSView {
    var onVisibilityChanged: ((Bool) -> Void)?
    private weak var observedWindow: NSWindow?
    private var lastNotifiedVisibility: Bool?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObserving()
        guard let window else {
            notifyVisibility(false)
            return
        }
        observedWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkVisibility),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkVisibility),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(checkVisibility),
            name: NSWindow.didResignKeyNotification,
            object: window
        )
        checkVisibility()
    }

    @objc private func checkVisibility() {
        guard let window = observedWindow ?? window else {
            notifyVisibility(false)
            return
        }
        let isVisible = window.isVisible && window.occlusionState.contains(.visible)
        notifyVisibility(isVisible)
    }

    private func notifyVisibility(_ isVisible: Bool) {
        guard lastNotifiedVisibility != isVisible else { return }
        lastNotifiedVisibility = isVisible
        onVisibilityChanged?(isVisible)
    }

    private func stopObserving() {
        NotificationCenter.default.removeObserver(self)
        observedWindow = nil
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

private struct MenuBarContent: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var language: AppLanguageController
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingNodes = false
    @State private var selectedGroupName: String?
    @State private var mainPaneHeight: CGFloat = AetherVisual.menuNodePaneDefaultHeight
    @State private var isMenuVisible = false
    @State private var copiedMessage: String?
    @State private var copyFeedbackTask: Task<Void, Never>?
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(spacing: 0) {
            if tunnel.hasAcceptedPrivacyDisclosure && !tunnel.isNetworkSetupRequired {
                readyContent
                    .task { await tunnel.prepare() }
            } else {
                privacyRequiredContent
            }
        }
        .frame(width: AetherVisual.popoverWidth)
        .background {
            MenuBarVisibilitySynchronizer { isVisible in
                isMenuVisible = isVisible
                tunnel.setRealtimeTelemetryPreferred(isVisible, for: "menubar")
                if !isVisible {
                    showingNodes = false
                }
            }
        }
        // The menu bar window is already system glass; only Reduce
        // Transparency needs an opaque ground.
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .onChange(of: tunnel.activeProfile?.yaml) { _, _ in showingNodes = false }
        .onChange(of: tunnel.activeProfileID) { _, _ in
            showingNodes = false
            selectedGroupName = nil
        }
        .onChange(of: tunnel.activeProfileOverrides) { _, _ in
            // Reset selected group when profileOverrides change.
            showingNodes = false
            selectedGroupName = nil
        }
#if DEBUG
        .task {
            // Isolated screenshot review only: open the node list on launch.
            if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PANEL_NODES"] == "1" {
                try? await Task.sleep(for: .milliseconds(500))
                showingNodes = true
            }
        }
#endif
        .onAppear {
            AppWindowManager.shared.openWindowAction = { [openWindow] in
                openWindow(id: "main")
            }
        }
        .onDisappear {
            tunnel.setRealtimeTelemetryPreferred(false, for: "menubar")
            copyFeedbackTask?.cancel()
            copyFeedbackTask = nil
            showingNodes = false
        }
    }

    /// Laid out like a Control Center module: state and the switch first,
    /// then live traffic, then one glass group for the exit and the modes;
    /// terminal helpers and app commands live in the overflow menu. Opening
    /// node selection slides into a fixed-height sub-pane so the popover
    /// geometry stays steady.
    private var readyContent: some View {
        ZStack {
            if showingNodes, !selectableMenuGroups.isEmpty {
                MenuNodeSelectorPane(
                    groups: selectableMenuGroups,
                    selectedGroupName: $selectedGroupName,
                    onClose: {
                        withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                            showingNodes = false
                        }
                    }
                )
                .padding(AetherVisual.s4)
                .frame(height: max(AetherVisual.menuNodePaneMinHeight, mainPaneHeight))
                .transition(nodePaneTransition)
            } else {
                mainControlCenterContent
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.height
                    } action: { newHeight in
                        if !showingNodes, newHeight > 0 {
                            mainPaneHeight = newHeight
                        }
                    }
                    .transition(mainPaneTransition)
            }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: showingNodes)
    }

    private var nodePaneTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .trailing).combined(with: .opacity)
            )
    }

    private var mainPaneTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .leading).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    private var mainControlCenterContent: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            header

            if tunnel.isConnected {
                // Overview's live traffic in miniature: the same legend dots
                // and one shared-scale graph, so both draw the same curve.
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    HStack(spacing: AetherVisual.s3) {
                        MenuLiveTrafficMetric(title: "Download", dot: .cyan, metric: .download, telemetry: telemetry, isLive: isMenuVisible)
                        MenuLiveTrafficMetric(title: "Upload", dot: .purple, metric: .upload, telemetry: telemetry, isLive: isMenuVisible)
                        MenuLiveTrafficMetric(title: "Connections", dot: nil, metric: .connections, telemetry: telemetry, isLive: isMenuVisible)
                    }
                    MenuTrafficGraph(model: telemetry, isLive: isMenuVisible)
                    MenuMemoryFooter(telemetry: telemetry, isLive: isMenuVisible)
                }
                .padding(AetherVisual.s3)
                .menuPopoverCard(cornerRadius: Self.groupRadius)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // The switch is disabled in these cases; say why and where to go
            // instead of leaving a dead end.
            if tunnel.profiles.isEmpty {
                menuNotice(
                    symbol: "doc.badge.plus",
                    tint: .secondary,
                    title: AppLocalization.string("No profile yet"),
                    detail: AppLocalization.string("Import a profile or add a subscription to connect."),
                    action: AppLocalization.string("Add Profile"),
                    section: .profiles
                )
                .accessibilityIdentifier("menu-no-profile")
            } else if !tunnel.distributionConnectionAccess.permitsNewConnection {
                menuNotice(
                    symbol: "key.fill",
                    tint: .orange,
                    title: AppLocalization.string("License required"),
                    detail: tunnel.statusDetail,
                    action: AppLocalization.string("Open Settings"),
                    settingsTab: "about"
                )
                .accessibilityIdentifier("menu-license-notice")
            } else if isFailed {
                menuNotice(
                    symbol: "exclamationmark.triangle.fill",
                    tint: .red,
                    title: AppLocalization.string("Could not connect"),
                    detail: tunnel.statusDetail,
                    action: AppLocalization.string("Details"),
                    section: .overview
                )
                .accessibilityIdentifier("menu-connection-failure")
            } else if let notice = subscriptionNotice {
                menuNotice(
                    symbol: notice.alert.isSevere
                        ? "exclamationmark.octagon.fill"
                        : "exclamationmark.triangle.fill",
                    tint: notice.alert.isSevere ? .red : .orange,
                    title: notice.title,
                    detail: notice.detail,
                    action: AppLocalization.string("Profiles"),
                    section: .profiles
                )
                .accessibilityIdentifier("menu-subscription-notice")
            }

            routeGroup

            if let routingMessage = tunnel.routingModeMessage {
                Label(
                    routingMessage,
                    systemImage: tunnel.routingModeMessageIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    tunnel.routingModeMessageIsError
                        ? AnyShapeStyle(AetherReadableTint(color: .orange))
                        : AnyShapeStyle(AetherVisual.secondaryText)
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("menu-routing-mode-message")
            }

            if let engineMessage = tunnel.networkEngineMessage {
                HStack(alignment: .top, spacing: AetherVisual.s2) {
                    Label(
                        engineMessage,
                        systemImage: tunnel.networkEngineMessageIsError
                            ? "exclamationmark.triangle.fill"
                            : "info.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        tunnel.networkEngineMessageIsError
                            ? AnyShapeStyle(AetherReadableTint(color: .orange))
                            : AnyShapeStyle(AetherVisual.secondaryText)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    if tunnel.networkEngineBlockedNeedsSetup {
                        Spacer(minLength: AetherVisual.s1)
                        Button(AppLocalization.string("Network Setup…")) {
                            AppWindowManager.shared.showMainWindow()
                        }
                        .buttonStyle(.aetherGlassCapsule)
                    }
                }
                .accessibilityIdentifier("menu-network-engine-message")
            }

            footer
        }
        .padding(AetherVisual.s4)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: tunnel.isConnected)
    }

    /// The active subscription running out or ended, worded for the panel.
    private var subscriptionNotice: (alert: SubscriptionUsageAlert, title: String, detail: String)? {
        guard let usage = tunnel.effectiveActiveSubscriptionUsage else { return nil }
        let alert = SubscriptionUsageAlert.evaluate(usage, now: .now)
        let title: String
        switch alert {
        case .none: return nil
        case .low: title = AppLocalization.string("Subscription traffic is running low")
        case .expiring: title = AppLocalization.string("Subscription expires soon")
        case .exhausted: title = AppLocalization.string("Subscription traffic is used up")
        case .expired: title = AppLocalization.string("Subscription has expired")
        }
        return (alert, title, SubscriptionUsageLine.summary(usage, alert: alert, now: .now))
    }

    private static let groupRadius = AetherVisual.compactPanelRadius
    private static let rowTileSize = AetherVisual.rowTileSize

    /// One line of guidance in the panel's own style: symbol, what is wrong,
    /// and a link to the page that fixes it.
    private func menuNotice(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        action: String,
        section: AppSection? = nil,
        settingsTab: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: AetherVisual.s2) {
            Image(systemName: symbol)
                .foregroundStyle(
                    tint == .secondary
                        ? AnyShapeStyle(AetherVisual.secondaryText)
                        : AnyShapeStyle(AetherReadableTint(color: tint))
                )
                .frame(width: AetherVisual.s5)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AetherVisual.s2)
            Button(action) {
                if let settingsTab {
                    AppWindowManager.shared.requestSettingsTab(settingsTab)
                    openSettings()
                } else if let section {
                    NotificationCenter.default.post(
                        name: .aetherRouteNavigateToSection,
                        object: section.rawValue
                    )
                    AppWindowManager.shared.showMainWindow()
                }
            }
            .buttonStyle(.aetherGlassCapsule)
        }
        .padding(AetherVisual.s3)
        .menuPopoverCard(cornerRadius: Self.groupRadius)
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: AetherVisual.s3) {
            ConnectionMedallion(phase: ConnectionMedallion.Phase(tunnel: tunnel), size: 40)
                .padding(AetherVisual.s1)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(tunnel.compactStatusTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isFailed ? AnyShapeStyle(AetherReadableTint(color: .red)) : AnyShapeStyle(Color.primary))
                    .contentTransition(.opacity)
                    .animation(AetherVisual.animation(AetherVisual.quickFade), value: tunnel.compactStatusTitle)
                headerSubtitle
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: AetherVisual.s2)
            // Drawn rather than a native Toggle: the panel never activates
            // the app, and AppKit draws a native switch grey there even
            // when it is on.
            ConnectionSwitch(identifier: "menu-connection-toggle", isCompact: true)
        }
    }

    @ViewBuilder
    private var headerSubtitle: some View {
        if tunnel.isConnected, let since = tunnel.connectedSince {
            if isMenuVisible {
                TimelineView(.periodic(from: since, by: 60)) { context in
                    Text(
                        AppLocalization.format(
                            "Connected for %@",
                            AppLocalization.duration(context.date.timeIntervalSince(since))
                        )
                    )
                }
            } else {
                Text(
                    AppLocalization.format(
                        "Connected for %@",
                        AppLocalization.duration(Date.now.timeIntervalSince(since))
                    )
                )
            }
        } else {
            Text(verbatim: "AetherRoute")
        }
    }

    /// The exit and the two modes in one glass group, rows as in System
    /// Settings.
    private var routeGroup: some View {
        let isAllowLANDisabled = !tunnel.canModifyLocalProxySettings
            || (tunnel.isConnected && tunnel.networkEngineMode == .tun)
        return VStack(spacing: 0) {
            if tunnel.effectiveRoutingMode == .direct, tunnel.activeProfileSummary != nil {
                directExitRow
                rowDivider
            } else if let group = activeMenuExitGroup {
                exitRow(group)
                rowDivider
            }
            panelRow(symbol: "arrow.triangle.branch", tint: .orange, title: AppLocalization.string("Routing mode"), help: .routingMode) {
                RoutingModeSegmentedControl(
                    selection: Binding(
                        get: { tunnel.effectiveRoutingMode },
                        set: { mode in Task { await tunnel.setRoutingMode(mode) } }
                    ),
                    isEnabled: tunnel.canChangeRoutingMode,
                    marksSelection: true
                )
                .frame(width: 168)
            }
#if AETHERROUTE_INDEPENDENT
            rowDivider
            panelRow(
                symbol: tunnel.networkEngineMode == .tun ? "bolt.shield.fill" : "shield.fill",
                tint: .blue,
                // "Network engine" left no room for the control in English.
                title: AppLocalization.string("Engine (menu bar panel row)"),
                help: .networkEngine
            ) {
                NetworkEngineSegmentedControl(
                    selection: networkEngineBinding,
                    isEnabled: tunnel.canChangeNetworkEngine,
                    marksSelection: true,
                    usesShortTitles: true
                )
                // "Transparent" and the selection dot need 184 pt in English; the
                // trailing edges still line up with the routing control above.
                .frame(width: 184)
            }
            rowDivider
            panelRow(
                symbol: "network",
                tint: .teal,
                title: AppLocalization.string("Allow LAN"),
                help: .allowLAN
            ) {
                Toggle(
                    AppLocalization.string("Allow LAN"),
                    isOn: Binding(
                        get: { tunnel.localProxySettings.allowLAN },
                        set: { enabled in
                            withAnimation(AetherVisual.animation(AetherVisual.disclosure)) {
                                tunnel.setLocalProxyAllowLAN(enabled)
                            }
                        }
                    )
                )
                .toggleStyle(MenuPopoverSwitchToggleStyle())
                .labelsHidden()
                .disabled(isAllowLANDisabled)
                .accessibilityIdentifier("menu-allow-lan-toggle")
            }
            if tunnel.isConnected && tunnel.networkEngineMode == .tun {
                Text(AppLocalization.string("Disconnect TUN mode to change Allow LAN."))
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.bottom, AetherVisual.s2)
            }
            if let proxyMessage = tunnel.localProxySettingsMessage {
                Text(verbatim: proxyMessage)
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.bottom, AetherVisual.s2)
                    .accessibilityIdentifier("menu-local-proxy-message")
            }
            if tunnel.localProxySettings.allowLAN {
                MenuBarLANAddressBanner(tunnel: tunnel)
            }
#endif
        }
        .menuPopoverCard(cornerRadius: Self.groupRadius)
        .animation(AetherVisual.animation(AetherVisual.disclosure), value: tunnel.localProxySettings.allowLAN)
        .onChange(of: tunnel.effectiveRoutingMode) { _, mode in
            if mode == .direct {
                showingNodes = false
            }
        }
    }

    private var rowDivider: some View {
        Divider().padding(.leading, AetherVisual.s3 + Self.rowTileSize + AetherVisual.s2)
    }

    private func panelRow<Trailing: View>(
        symbol: String,
        tint: Color,
        title: String,
        help: HelpTopic,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: AetherVisual.s2) {
            AetherIconTile(symbol: symbol, color: tint, size: Self.rowTileSize)
            Text(title)
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
            AetherHelpButton(topic: help)
                .controlSize(.small)
            Spacer(minLength: AetherVisual.s2)
            trailing()
        }
        .frame(minHeight: AetherVisual.compactRowHeight)
        .padding(.horizontal, AetherVisual.s3)
    }

    private var directExitRow: some View {
        HStack(spacing: AetherVisual.s2) {
            AetherIconTile(symbol: "bolt.fill", color: .green, size: Self.rowTileSize)
            Text(verbatim: AppLocalization.string("Direct outbound (no proxy)"))
            .font(.body.weight(.medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: AetherVisual.compactRowHeight)
        .padding(.horizontal, AetherVisual.s3)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menu-direct-outlet-row")
    }

    private func exitRow(_ group: ProxyGroupConfigurationSummary) -> some View {
        let member: String? = if group.name == "GLOBAL" {
            tunnel.proxySelections["GLOBAL"]?.selectedMember
                ?? tunnel.activeProfileSummary.flatMap { TunnelManager.resolvedGlobalTargetMember(in: $0) }
        } else {
            tunnel.proxySelections[group.name]?.selectedMember
        }
        let resolvedLeaf = member.map { tunnel.resolvedLeafNode(from: $0) }
        let leaf = (resolvedLeaf != member) ? resolvedLeaf : nil
        return Button {
            selectedGroupName = group.name
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                showingNodes = true
            }
        } label: {
            HStack(spacing: AetherVisual.s2) {
                AetherIconTile(symbol: "globe", color: .indigo, size: Self.rowTileSize)
                MenuSelectedNodeTitle(
                    member: member,
                    leaf: leaf
                )
                if let member {
                    MenuExitRowLatencyLeaf(
                        groupName: group.name,
                        member: member,
                        latencyStore: tunnel.latencyStore,
                        tunnel: tunnel
                    )
                }
                AetherDisclosureChevron(isExpanded: showingNodes)
            }
            .frame(minHeight: AetherVisual.compactRowHeight)
            .padding(.horizontal, AetherVisual.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.aetherPressable)
        .help(Text(verbatim: member ?? AppLocalization.string("Select Node")))
        .accessibilityIdentifier("menu-proxy-node-selector")
        .task(id: "\(group.name):\(tunnel.isConnected):\(tunnel.effectiveRoutingMode.rawValue):\(isMenuVisible)") {
            guard isMenuVisible else { return }
            if group.name == "GLOBAL" {
                tunnel.seedGlobalSelectionIfNeeded()
            }
            await tunnel.refreshProxySelection(group: group.name)
            await tunnel.refreshProxyLatencyIfNeeded(group: group.name)
        }
    }

    /// Two equal actions and the overflow menu. The version lives in that
    /// menu; an available update gets its own row above the actions.
    private var footer: some View {
        VStack(spacing: AetherVisual.s2) {
#if !AETHERROUTE_APP_STORE
            MenuUpdateStatus(updater: SparkleUpdaterController.shared)
#endif
            if let copiedMessage {
                Label(copiedMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(AetherReadableTint(color: .green))
                    .transition(.opacity)
            }
            footerActions
        }
        .font(.callout)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: copiedMessage)
    }

    private var footerActions: some View {
        HStack(spacing: AetherVisual.s2) {
            Button {
                AppWindowManager.shared.showMainWindow()
            } label: {
                Text(AppLocalization.string("Open AetherRoute"))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.aetherGlassCapsule)
            if tunnel.effectiveRoutingMode != .direct, let group = activeMenuExitGroup {
                MenuGroupSpeedTestButton(
                    groupName: group.name,
                    latencyStore: tunnel.latencyStore,
                    fillsWidth: true,
                    isDisabled: group.members.isEmpty,
                    accessibilityIdentifier: "menu-proxy-speedtest-button",
                    action: {
                        Task { await tunnel.testProxyLatency(group: group.name) }
                    }
                )
            }
            Menu {
                Text(verbatim: "AetherRoute \(SparkleUpdaterController.currentVersion)")
                Divider()
                Button(AppLocalization.string("Copy Proxy Command"), systemImage: "terminal") {
                    copy(terminalProxyCommand)
                }
                .disabled(!tunnel.canCopyTerminalProxyCommand)
                .accessibilityIdentifier("copy-terminal-proxy-button")
                Menu {
                    ForEach(TerminalShellDialect.allCases) { dialect in
                        Button(dialect.displayTitle) {
                            copy(terminalProxyCommand(for: dialect))
                        }
                    }
                    Divider()
                    Button(AppLocalization.string("Copy PAC Script")) {
                        copy(terminalPACScript)
                    }
                } label: {
                    Label(AppLocalization.string("Other Shells & PAC"), systemImage: "chevron.left.forwardslash.chevron.right")
                }
                .disabled(!tunnel.canCopyTerminalProxyCommand)
                .accessibilityIdentifier("menu-other-shells-pac")
#if AETHERROUTE_INDEPENDENT
                if !tunnel.canCopyTerminalProxyCommand {
                    Text(AppLocalization.string("Turn on the local proxy in Settings › Network."))
                }
#endif
                Button(AppLocalization.string("Copy Clear Command"), systemImage: "terminal.fill") {
                    copy(LocalProxySettings.clearShellEnvironmentCommand)
                }
                .accessibilityIdentifier("clear-terminal-proxy-button")
#if !AETHERROUTE_APP_STORE
                Divider()
                Button(AppLocalization.string("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath") {
                    SparkleUpdaterController.shared.checkForUpdates()
                }
                .disabled(!SparkleUpdaterController.shared.canCheckOrFocusUpdateSession)
#endif
                Divider()
                Button(AppLocalization.string("Quit"), systemImage: "power") {
                    AppTermination.request()
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .menuIndicator(.hidden)
            .buttonStyle(.aetherGlassCapsule)
            .fixedSize()
            .accessibilityLabel(AppLocalization.string("More"))
        }
    }

    private var terminalProxyCommand: String {
        terminalProxyCommand(for: .zshBash)
    }

    private func terminalProxyCommand(for dialect: TerminalShellDialect) -> String {
        (try? tunnel.localProxySettings.shellEnvironmentCommand(dialect: dialect))
            ?? TerminalProxyEnvGenerator.shellCommand(
                dialect: dialect,
                host: "127.0.0.1",
                httpPort: tunnel.localProxySettings.httpPort,
                socksPort: tunnel.localProxySettings.socksPort
            )
    }

    private var terminalPACScript: String {
        let host = tunnel.localProxySettings.allowLAN
            ? LANProxyServerController.shared.currentLANIP
            : "127.0.0.1"
        return (try? tunnel.localProxySettings.pacScript(host: host))
            ?? TerminalProxyEnvGenerator.pacScript(
                host: host,
                httpPort: tunnel.localProxySettings.httpPort,
                socksPort: tunnel.localProxySettings.socksPort
            )
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedMessage = AppLocalization.string("Copied")
        copyFeedbackTask?.cancel()
        copyFeedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            copiedMessage = nil
        }
    }

    private var isWorking: Bool {
        if tunnel.isSwitchingNetworkEngine { return true }
        switch tunnel.state {
        case .connecting, .recovering, .disconnecting: return true
        default: return false
        }
    }

    private var isFailed: Bool {
        if case .failed = tunnel.state { return true }
        return false
    }

    private var activeMenuExitGroup: ProxyGroupConfigurationSummary? {
        switch tunnel.effectiveRoutingMode {
        case .direct:
            return nil
        case .global:
            return tunnel.menuGlobalProxyGroup
        case .rule:
            return primaryGroup
        }
    }

    private var primaryGroup: ProxyGroupConfigurationSummary? {
        tunnel.resolvedPrimaryRoutingGroup()
    }

    private var selectableMenuGroups: [ProxyGroupConfigurationSummary] {
        switch tunnel.effectiveRoutingMode {
        case .direct:
            return []
        case .global:
            return [tunnel.menuGlobalProxyGroup].compactMap { $0 }
        case .rule:
            let profileGroups = (tunnel.activeProfileSummary?.proxyGroups ?? [])
                .filter { $0.name != "GLOBAL" }
            guard let primary = primaryGroup else { return profileGroups }
            return [primary] + profileGroups.filter { $0.name != primary.name }
        }
    }

#if AETHERROUTE_INDEPENDENT
    private var networkEngineBinding: Binding<NetworkEngineMode> {
        Binding(
            get: { tunnel.networkEngineMode },
            set: { mode in
                Task { await tunnel.setNetworkEngineMode(mode) }
            }
        )
    }
#endif

    private var privacyRequiredContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AetherVisual.s3) {
                AetherRouteBrandTile(size: AetherVisual.sheetIconSize)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(tunnel.hasAcceptedPrivacyDisclosure
                        ? AppLocalization.string("Network setup required")
                        : AppLocalization.string("Privacy review required"))
                        .font(.headline)
                    Text(AppLocalization.string("Connection controls are locked"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                Spacer()
            }
            .padding(AetherVisual.s4)

            Divider()

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                Text(tunnel.hasAcceptedPrivacyDisclosure
                    ? AppLocalization.string("Finish granting the network permissions in the main window before connecting.")
                    : AppLocalization.string("Review how profiles, network traffic, and DNS requests are handled before AetherRoute creates a network extension configuration."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openMainWindow()
                } label: {
                    Label(
                        tunnel.hasAcceptedPrivacyDisclosure
                            ? AppLocalization.string("Continue Setup")
                            : AppLocalization.string("Review Network Privacy"),
                        systemImage: "lock.shield"
                    )
                        .frame(maxWidth: .infinity)
                }
                .aetherButton(prominent: true)
                .controlSize(.large)
                .accessibilityIdentifier("menu-privacy-review-button")
            }
            .padding(AetherVisual.s4)

            Divider()

            HStack {
                Spacer()
                Button(AppLocalization.string("Quit")) {
                    AppTermination.request()
                }
            }
            .buttonStyle(.borderless)
            .padding(AetherVisual.s4)
        }
    }

    private func openMainWindow() {
        AppWindowManager.shared.showMainWindow()
    }
}

private struct MenuPopoverSwitchToggleStyle: ToggleStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        Button {
            withAnimation(AetherVisual.animation(AetherVisual.switchToggle)) {
                configuration.isOn.toggle()
            }
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule()
                    .fill(configuration.isOn ? Color.green : AetherVisual.neutralFill)
                    .frame(width: 32, height: 18)
                Circle()
                    .fill(Color.white)
                    .frame(width: 14, height: 14)
                    .padding(AetherVisual.sMicro)
            }
            .opacity(isEnabled ? 1 : 0.45)
            .animation(reduceMotion ? nil : AetherVisual.animation(AetherVisual.switchToggle), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(
            configuration.isOn
                ? AppLocalization.string("On")
                : AppLocalization.string("Off")
        )
    }
}

private struct MenuBarLANAddressBanner: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject private var lanController = LANProxyServerController.shared

    var body: some View {
        let lanIP = lanController.currentLANIP
        let port = tunnel.localProxySettings.httpPort
        let canReachOverLAN = tunnel.isConnected && lanIP != "127.0.0.1"
        let failureMessage = lanController.statusFailure.map {
            tunnel.localizedLANProxyStatusFailure($0)
        } ?? lanController.statusMessage
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            if let errorMessage = failureMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(AetherReadableTint(color: .orange))
                    .fixedSize(horizontal: false, vertical: true)
            } else if canReachOverLAN {
                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .foregroundStyle(AetherReadableTint(color: .teal))
                        .font(.callout)
                        .accessibilityHidden(true)
                    Text(verbatim: "\(lanIP):\(port)")
                        .font(.callout.monospaced().weight(.semibold))
                    Spacer()
                    LanCopyGuideButton(
                        guideText: tunnel.localProxySettings.localizedLANConfigurationGuide(lanIP: lanIP),
                        isPopover: true
                    )
                }
                Text(AppLocalization.string("Other devices on this Wi-Fi can connect to this proxy."))
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
            } else {
                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: "network.slash")
                        .foregroundStyle(AetherVisual.secondaryText)
                        .font(.callout)
                        .accessibilityHidden(true)
                    Text(
                        tunnel.isConnected
                            ? AppLocalization.string("No active Wi-Fi or Ethernet address detected yet.")
                            : AppLocalization.string("LAN sharing is ready and activates when connected.")
                    )
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .background(AetherVisual.tintWash(.teal), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
        .padding(.horizontal, AetherVisual.s2)
        .padding(.bottom, AetherVisual.s2)
        .transition(AetherVisual.insertion)
        .clipped()
    }
}

private struct LanCopyGuideButton: View {
    let guideText: String
    var isPopover: Bool = false
    var accessibilityIdentifier: String = "menu-copy-lan-guide-button"

    var body: some View {
        let button = AetherCopyButton(
            title: Text(AppLocalization.string("Copy Guide")),
            systemImage: "doc.on.doc",
            copiedTitle: Text(AppLocalization.string("Copied")),
            action: {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(guideText, forType: .string)
                return true
            }
        )
        .font(.caption.weight(.medium))

        Group {
            if isPopover {
                button.buttonStyle(.aetherGlassCapsule)
            } else {
                button
                    .aetherButton()
                    .controlSize(.small)
            }
        }
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MenuNodeLatency: View {
    let status: ProxyLatencyStatus
    var confidence: ProxyLatencyConfidence = .reachability

    var body: some View {
        HStack(spacing: AetherVisual.sMicro) {
            Text(title)
                .font(.caption2.monospacedDigit().weight(.medium))
                .foregroundStyle(foregroundStyle)
                .fixedSize()

            if status.isMeasured, confidence == .verified {
                Image(systemName: confidence.symbol)
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, AetherVisual.sCompact)
        .padding(.vertical, AetherVisual.sMicro)
        .background(pillBackground, in: Capsule())
        .help(status.isMeasured ? confidence.localizedHint : title)
    }

    private var foregroundStyle: AnyShapeStyle {
        status.tint == .secondary
            ? AnyShapeStyle(AetherVisual.secondaryText)
            : AnyShapeStyle(AetherReadableTint(color: status.tint))
    }

    private var pillBackground: Color {
        status.tint == .secondary
            ? AetherVisual.neutralFill
            : AetherVisual.tintFill(status.tint)
    }

    private var title: String {
        status.localizedTitle
    }
}

private struct MenuNodeSelectorPane: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let groups: [ProxyGroupConfigurationSummary]
    @Binding var selectedGroupName: String?
    let onClose: () -> Void
    @State private var orderedMembers: [String] = []
    @State private var selecting = false
    @State private var searchText = ""

    private var activeGroup: ProxyGroupConfigurationSummary {
        if let selectedGroupName,
           let matched = groups.first(where: { $0.name == selectedGroupName }) {
            return matched
        }
        return groups[0]
    }

    private var selectedMember: String? {
        if activeGroup.name == "GLOBAL" {
            return tunnel.proxySelections["GLOBAL"]?.selectedMember
                ?? tunnel.activeProfileSummary.flatMap { TunnelManager.resolvedGlobalTargetMember(in: $0) }
        }
        return tunnel.proxySelections[activeGroup.name]?.selectedMember
    }

    private var proxySummaryByName: [String: ProxyConfigurationSummary] {
        Dictionary(
            (tunnel.activeProfileSummary?.proxies ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var unsupported: Set<String> {
        Set((tunnel.activeProfileSummary?.proxies ?? [])
            .filter { !$0.recognition.isSelectable }.map(\.name))
    }

    private var filteredMembers: [String] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return orderedMembers }
        return orderedMembers.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        let group = activeGroup
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s2) {
                Button(action: onClose) {
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.semibold))
                        Text(AppLocalization.string("Back"))
                    }
                }
                .buttonStyle(.aetherGlassCapsule)
                .accessibilityIdentifier("menu-node-back-button")

                Text(verbatim: groups.count > 1 ? AppLocalization.string("Select Node") : group.name)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)

                MenuGroupSpeedTestButton(
                    groupName: group.name,
                    latencyStore: tunnel.latencyStore,
                    fillsWidth: false,
                    isDisabled: group.members.isEmpty,
                    accessibilityIdentifier: "menu-node-speedtest-button",
                    action: {
                        Task { await tunnel.testProxyLatency(group: group.name) }
                    }
                )
            }

            if groups.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: AetherVisual.sCompact) {
                        ForEach(groups) { candidate in
                            let isSelectedGroup = candidate.name == group.name
                            Button {
                                withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                                    selectedGroupName = candidate.name
                                }
                            } label: {
                                Text(verbatim: candidate.name)
                                    .font(.caption.weight(isSelectedGroup ? .semibold : .medium))
                                    .foregroundStyle(isSelectedGroup ? Color.accentColor : Color.primary)
                                    .padding(.horizontal, AetherVisual.pillHorizontalPadding)
                                    .padding(.vertical, AetherVisual.pillVerticalPadding)
                                    .background(
                                        isSelectedGroup ? AetherVisual.selectionFill : AetherVisual.neutralFill,
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule()
                                            .strokeBorder(
                                                isSelectedGroup ? Color.accentColor : AetherVisual.cardStroke,
                                                lineWidth: 0.5
                                            )
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("menu-group-chip-\(candidate.name)")
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                if orderedMembers.count > Self.searchThreshold {
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "magnifyingglass")
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                        TextField(AppLocalization.string("Search nodes"), text: $searchText)
                            .textFieldStyle(.plain)
                            .font(.subheadline)
                            .onExitCommand { searchText = "" }
                            .accessibilityLabel(AppLocalization.string("Search nodes"))
                            .accessibilityIdentifier("menu-node-search-field")
                        if !searchText.isEmpty {
                            Button {
                                searchText = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.subheadline)
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(AppLocalization.string("Clear"))
                        }
                    }
                    .padding(.horizontal, AetherVisual.s2)
                    .padding(.vertical, AetherVisual.sCompact)
                    .background(
                        AetherVisual.subtleFill,
                        in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                    )
                }

                if orderedMembers.isEmpty {
                    Text(AppLocalization.string("No nodes available"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if filteredMembers.isEmpty {
                    Text(AppLocalization.string("No matching nodes"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    let summariesByName = proxySummaryByName
                    let unsupportedSet = unsupported
                    let currentSelected = selectedMember
                    let isRequestPending = tunnel.proxySelectionRequests.contains(group.name)
                    let isSelectStrategy = group.strategy.lowercased() == "select"
                    let isFastestLocked = group.name != "GLOBAL" && tunnel.proxySelectionMode(for: group.name) == .fastest
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredMembers, id: \.self) { member in
                                let proxy = summariesByName[member]
                                let isMemberUnsupported = unsupportedSet.contains(member)
                                MenuNodeRow(
                                    groupName: group.name,
                                    member: member,
                                    protocolName: proxy?.protocolName,
                                    transportName: proxy?.transportName,
                                    isSelected: member == currentSelected,
                                    isUnsupported: isMemberUnsupported,
                                    latencyStore: tunnel.latencyStore,
                                    tunnel: tunnel
                                ) {
                                    if member == currentSelected {
                                        onClose()
                                        return
                                    }
                                    selecting = true
                                    Task {
                                        if group.name == "GLOBAL" {
                                            await tunnel.selectGlobalOutlet(member)
                                        } else {
                                            await tunnel.selectProxy(group: group.name, member: member)
                                        }
                                        selecting = false
                                    }
                                }
                                .disabled(selecting || isRequestPending
                                    || !isSelectStrategy || isMemberUnsupported
                                    || isFastestLocked)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .padding(AetherVisual.s2)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .menuPopoverCard(cornerRadius: AetherVisual.compactPanelRadius)

            if group.strategy.lowercased() != "select" {
                Text(AppLocalization.string("This group is automatically managed by latency tests."))
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            } else if group.name != "GLOBAL", tunnel.proxySelectionMode(for: group.name) == .fastest {
                Text(AppLocalization.string("Manual selection is paused while Fastest mode picks the lowest-latency node."))
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let message = tunnel.proxySelectionMessages[group.name] {
                Text(verbatim: message)
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(2)
                    .accessibilityIdentifier("menu-node-message")
            }
        }
        .task(id: group.name) {
            if group.name == "GLOBAL" {
                tunnel.seedGlobalSelectionIfNeeded()
            }
            updateOrder(for: group)
            await tunnel.refreshProxySelection(group: group.name)
            guard !Task.isCancelled else { return }
            updateOrder(for: group)
            if tunnel.isConnected {
                await tunnel.refreshProxyLatencyIfNeeded(group: group.name)
                guard !Task.isCancelled else { return }
                updateOrder(for: group)
            }
        }
    }

    private static let searchThreshold = 6

    private func updateOrder(for group: ProxyGroupConfigurationSummary) {
        let baseMembers = group.name == "GLOBAL"
            ? group.members
            : (tunnel.proxySelections[group.name]?.members ?? group.members)
        orderedMembers = MenuProxyNodeOrder.sorted(members: baseMembers)
    }
}


/// The current version beside the menu's "···" button. When Sparkle has
/// found a newer release it becomes a tappable "New version" pill that stays
/// until the update is installed or skipped, so "Remind me later" does not
/// lose it.
private struct MenuUpdateStatus: View {
    @ObservedObject var updater: SparkleUpdaterController
    @State private var isPulsing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch updater.availability {
            case let .available(version):
                Button {
                    updater.checkForUpdates()
                } label: {
                    // A solid accent row with white text: a tinted pill read
                    // as blue-on-gray on dark menus and the dot faded out.
                    HStack(spacing: AetherVisual.sCompact) {
                        Circle()
                            .fill(Color.white)
                            .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                            .opacity(isPulsing ? 0.6 : 1)
                            .accessibilityHidden(true)
                        Text(AppLocalization.format("New version %@", version))
                            .font(.callout.weight(.semibold))
                        Spacer(minLength: AetherVisual.s2)
                        Image(systemName: "arrow.down.circle.fill")
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.vertical, AetherVisual.s2)
                    .background(Color.accentColor, in: Capsule())
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("View and install the update"))
                .accessibilityIdentifier("menu-update-available")
                .onAppear {
                    guard !reduceMotion else {
                        isPulsing = false
                        return
                    }
                    withAnimation(AetherVisual.animation(AetherVisual.attentionPulse)) {
                        isPulsing = true
                    }
                }
                .onChange(of: reduceMotion) { _, reduce in
                    if reduce {
                        isPulsing = false
                    } else {
                        withAnimation(AetherVisual.animation(AetherVisual.attentionPulse)) {
                            isPulsing = true
                        }
                    }
                }
                .onDisappear {
                    isPulsing = false
                }
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
            case .checking, .unknown, .upToDate:
                // The version is in the overflow menu; nothing to say here.
                EmptyView()
            }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: updater.availability)
    }
}

/// The selected exit in the menu bar. When the selection is itself a group
/// (for example "Auto"), the node that group is really using leads and the
/// group follows as context, matching the Overview hero.
private struct MenuSelectedNodeTitle: View {
    let member: String?
    let leaf: String?

    var body: some View {
        let shown = leaf ?? member
        AetherRegionCode(name: shown ?? "")
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.sCompact) {
            Text(verbatim: shown ?? AppLocalization.string("Select Node"))
                .font(.body.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if leaf != nil, let member {
                Text(verbatim: "· \(member)")
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentTransition(.opacity)
    }
}

/// One node in the menu bar list, styled like a Control Center menu row:
/// no fill at rest, a highlight under the pointer, and a check for the
/// current choice.
private struct MenuNodeRow: View {
    static let height: CGFloat = 32

    let groupName: String
    let member: String
    var protocolName: String? = nil
    var transportName: String? = nil
    let isSelected: Bool
    let isUnsupported: Bool
    let latencyStore: ProxyLatencyStore
    let tunnel: TunnelManager
    let action: () -> Void
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack(spacing: AetherVisual.s2) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(isSelected ? 1 : 0)
                    .frame(width: AetherVisual.s3)
                    .accessibilityHidden(true)
                AetherRegionCode(name: member)
                Text(verbatim: member)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let protocolName {
                    AetherProtocolBadge(type: protocolName, transport: transportName)
                }
                MenuNodeRowLatencyLeaf(
                    groupName: groupName,
                    member: member,
                    isUnsupported: isUnsupported,
                    latencyStore: latencyStore,
                    tunnel: tunnel
                )
            }
            .padding(.horizontal, AetherVisual.s2)
            .frame(height: Self.height)
            .opacity(isEnabled ? 1 : 0.45)
            .background(
                isHovered && isEnabled ? AetherVisual.hoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.aetherPressable)
        .onHover { isHovered = $0 }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
        .help(Text(verbatim: member))
        .accessibilityIdentifier("menu-node-\(member)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct MenuExitRowLatencyLeaf: View {
    let groupName: String
    let member: String
    @ObservedObject var latencyStore: ProxyLatencyStore
    let tunnel: TunnelManager

    var body: some View {
        let _ = latencyStore.proxyLatencies[groupName]
        let _ = latencyStore.proxyLatencyRequests.contains(groupName)
        let _ = latencyStore.memberLatencyRequests
        let resolvedLatency = tunnel.resolvedOutletLatencyStatus(
            groupName: groupName,
            selectedMember: member
        )
        MenuNodeLatency(
            status: resolvedLatency.status,
            confidence: resolvedLatency.confidence
        )
    }
}

private struct MenuNodeRowLatencyLeaf: View {
    let groupName: String
    let member: String
    let isUnsupported: Bool
    @ObservedObject var latencyStore: ProxyLatencyStore
    let tunnel: TunnelManager

    var body: some View {
        let _ = latencyStore.proxyLatencies[groupName]
        let _ = latencyStore.proxyLatencyRequests.contains(groupName)
        let _ = latencyStore.memberLatencyRequests
        let resolved: (status: ProxyLatencyStatus, confidence: ProxyLatencyConfidence) = isUnsupported
            ? (.timedOut, tunnel.latencyConfidence(group: groupName, member: member))
            : tunnel.resolvedOutletLatencyStatus(groupName: groupName, selectedMember: member)
        MenuNodeLatency(
            status: resolved.status,
            confidence: resolved.confidence
        )
    }
}

private struct MenuGroupSpeedTestButton: View {
    let groupName: String
    @ObservedObject var latencyStore: ProxyLatencyStore
    let fillsWidth: Bool
    var isDisabled: Bool = false
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        let isTesting = latencyStore.proxyLatencyRequests.contains(groupName)
        Button(action: action) {
            HStack(spacing: AetherVisual.s1) {
                if isTesting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "bolt.fill")
                }
                Text(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
                    .lineLimit(1)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
        }
        .buttonStyle(.aetherGlassCapsule)
        .disabled(isTesting || isDisabled)
        .help(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
        .accessibilityLabel(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private extension View {
    /// Nested cards inside `MenuBarExtra` sit directly on the system glass
    /// popover; using `cardFill` + a hairline border avoids glass-on-glass blur.
    func menuPopoverCard(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        return background(AetherVisual.cardFill, in: shape)
            .overlay {
                shape.strokeBorder(AetherVisual.panelStroke, lineWidth: 0.5)
            }
    }
}

private enum MenuLiveTrafficMetricKind {
    case download
    case upload
    case connections
    case coreMemory
    case appMemory
}

private struct MenuLiveTrafficMetric: View {
    let title: String.LocalizationValue
    /// The graph's colour for this series, as in Overview's legend.
    let dot: Color?
    let metric: MenuLiveTrafficMetricKind
    let telemetry: NetworkTelemetryViewModel
    var isLive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.sCompact) {
                if let dot {
                    Circle().fill(dot).frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                }
                Text(AppLocalization.string(title))
            }
            .font(.caption2)
            .foregroundStyle(AetherVisual.secondaryText)
            if isLive {
                MenuLiveTrafficValue(metric: metric, telemetry: telemetry)
            } else {
                MenuStaticTrafficValue(metric: metric, snapshot: telemetry.snapshot)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private struct MenuLiveTrafficValue: View {
    let metric: MenuLiveTrafficMetricKind
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        Text(value)
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
            .aetherLiveValue()
    }

    private var value: String {
        switch metric {
        case .download:
            return formattedRate(telemetry.snapshot.downloadBytesPerSecond)
        case .upload:
            return formattedRate(telemetry.snapshot.uploadBytesPerSecond)
        case .connections:
            return String(telemetry.snapshot.totalActiveConnections)
        case .coreMemory:
            let bytes = telemetry.snapshot.memoryBytes
            return bytes > 0 ? formattedBytes(bytes) : "—"
        case .appMemory:
            let bytes = telemetry.appMemoryBytes
            return bytes > 0 ? formattedBytes(bytes) : "—"
        }
    }
}

/// Overview's live traffic graph at panel size: the same 30-second window
/// trailing the clock by one sampling period, samples placed by time, and
/// download and upload on one shared scale. Without the shared scale a small
/// upload filled its own sparkline and looked like a spike. It animates only
/// while the panel is open; closed, it rests on the last 30 seconds.
private struct MenuTrafficGraph: View {
    let model: NetworkTelemetryViewModel
    let isLive: Bool

    var body: some View {
        Group {
            if isLive {
                MenuLiveTrafficGraph(model: model)
            } else {
                MenuPausedTrafficGraph(history: model.history)
            }
        }
        .accessibilityIdentifier("menu-traffic-graph")
    }
}

private struct MenuLiveTrafficGraph: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Like Overview's graph, the waveform is its own observing leaf, and only
    /// mounts while `isMenuVisible` is true so a closed popover never wakes on ticks.
    @ObservedObject var model: NetworkTelemetryViewModel

    private static let frameInterval: TimeInterval = 1.0 / 12
    private static let entryLag = TimeInterval(
        TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds
    )

    var body: some View {
        let lastSample = model.history.samples.last?.date
        let scaleSamples = model.history.visible(at: windowEnd(at: .now))
        VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
            Text(MenuPausedTrafficGraph.peakRate(scaleSamples).map {
                AppLocalization.format("Peak %@", $0)
            } ?? " ")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(AetherVisual.secondaryText)
            .aetherLiveValue()

            TimelineView(
                .animation(
                    minimumInterval: Self.frameInterval,
                    paused: reduceMotion || !model.history.hasActiveTraffic
                )
            ) { context in
                let now = windowEnd(at: context.date, lastSample: lastSample)
                let samples = model.history.visible(at: now)
                AetherTrafficMiniGraph(
                    downloadSamples: samples.map(\.download),
                    uploadSamples: samples.map(\.upload),
                    samplePositions: samples.map { TrafficHistory.position(of: $0, at: now) },
                    height: 36
                )
            }
        }
    }

    private func windowEnd(at date: Date, lastSample _: Date? = nil) -> Date {
        date.addingTimeInterval(-Self.entryLag)
    }
}

private struct MenuPausedTrafficGraph: View {
    let history: TrafficHistory

    var body: some View {
        let anchor = history.samples.last?.date ?? .now
        let samples = history.visible(at: anchor)
        VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
            Text(Self.peakRate(samples).map {
                AppLocalization.format("Peak %@", $0)
            } ?? " ")
            .font(.caption2.monospacedDigit())
            .foregroundStyle(AetherVisual.secondaryText)
            .aetherLiveValue()

            AetherTrafficMiniGraph(
                downloadSamples: samples.map(\.download),
                uploadSamples: samples.map(\.upload),
                samplePositions: samples.map { TrafficHistory.position(of: $0, at: anchor) },
                height: 36
            )
        }
    }

    static func peakRate(_ samples: [TrafficHistory.Sample]) -> String? {
        let peak = samples.map { max($0.download, $0.upload) }.max() ?? 0
        guard samples.count > 1, peak >= 1 else { return nil }
        return formattedRate(UInt64(peak))
    }
}

private struct MenuStaticTrafficValue: View {
    let metric: MenuLiveTrafficMetricKind
    let snapshot: NetworkTelemetrySnapshot
    var appMemoryBytes: UInt64 = 0

    var body: some View {
        Text(value)
            .font(.caption.monospacedDigit().weight(.semibold))
            .lineLimit(1)
    }

    private var value: String {
        switch metric {
        case .download:
            return formattedRate(snapshot.downloadBytesPerSecond)
        case .upload:
            return formattedRate(snapshot.uploadBytesPerSecond)
        case .connections:
            return String(snapshot.totalActiveConnections)
        case .coreMemory:
            let bytes = snapshot.memoryBytes
            return bytes > 0 ? formattedBytes(bytes) : "—"
        case .appMemory:
            return appMemoryBytes > 0 ? formattedBytes(appMemoryBytes) : "—"
        }
    }
}

private struct MenuMemoryFooter: View {
    let telemetry: NetworkTelemetryViewModel
    var isLive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            MenuMemoryProportionBar(model: telemetry, isLive: isLive)
            HStack(spacing: AetherVisual.s2) {
                HStack(spacing: AetherVisual.s1) {
                    Circle()
                        .fill(Color.mint)
                        .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                    Text(AppLocalization.string("Core memory"))
                    if isLive {
                        MenuLiveTrafficValue(metric: .coreMemory, telemetry: telemetry)
                            .foregroundStyle(.primary)
                    } else {
                        MenuStaticTrafficValue(metric: .coreMemory, snapshot: telemetry.snapshot)
                            .foregroundStyle(.primary)
                    }
                }
                Spacer(minLength: AetherVisual.s2)
                HStack(spacing: AetherVisual.s1) {
                    Circle()
                        .fill(Color.indigo)
                        .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                    Text(AppLocalization.string("App memory"))
                    if isLive {
                        MenuLiveTrafficValue(metric: .appMemory, telemetry: telemetry)
                            .foregroundStyle(.primary)
                    } else {
                        MenuStaticTrafficValue(
                            metric: .appMemory,
                            snapshot: telemetry.snapshot,
                            appMemoryBytes: telemetry.appMemoryBytes
                        )
                        .foregroundStyle(.primary)
                    }
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(AetherVisual.secondaryText)
            .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("menu-memory-summary")
    }
}

private struct MenuMemoryProportionBar: View {
    let model: NetworkTelemetryViewModel
    let isLive: Bool

    var body: some View {
        if isLive {
            MenuLiveMemoryProportionBar(model: model)
        } else {
            MenuMemoryProportionCanvas(
                coreBytes: model.snapshot.memoryBytes,
                appBytes: model.appMemoryBytes
            )
        }
    }
}

private struct MenuLiveMemoryProportionBar: View {
    @ObservedObject var model: NetworkTelemetryViewModel

    var body: some View {
        MenuMemoryProportionCanvas(
            coreBytes: model.snapshot.memoryBytes,
            appBytes: model.appMemoryBytes
        )
    }
}

private struct MenuMemoryProportionCanvas: View {
    let coreBytes: UInt64
    let appBytes: UInt64

    var body: some View {
        let total = coreBytes + appBytes
        let coreShare: CGFloat = total > 0 ? CGFloat(Double(coreBytes) / Double(total)) : 0
        let appShare: CGFloat = total > 0 ? CGFloat(Double(appBytes) / Double(total)) : 0

        Canvas { context, size in
            guard total > 0 else { return }
            let coreWidth = max(coreBytes > 0 ? 4 : 0, size.width * coreShare)
            let gap = coreWidth > 0 && appBytes > 0 ? AetherVisual.sMicro : 0
            if coreWidth > 0 {
                context.fill(
                    Path(CGRect(x: 0, y: 0, width: min(size.width, coreWidth), height: size.height)),
                    with: .color(.mint)
                )
            }
            let appStart = min(size.width, coreWidth + gap)
            let remaining = max(0, size.width - appStart)
            let appWidth = min(remaining, max(appBytes > 0 ? 4 : 0, size.width * appShare))
            if appWidth > 0 {
                context.fill(
                    Path(CGRect(x: appStart, y: 0, width: appWidth, height: size.height)),
                    with: .color(.indigo)
                )
            }
        }
        .frame(height: AetherVisual.s1)
        .background(AetherVisual.neutralFill, in: Capsule())
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }
}


/// Four panes, like System Settings. Earlier builds had nine; several held
/// one or two controls, and three of them described the app itself.
private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case network
    case privacy
    case about

    var id: Self { self }

    /// Old pane names still arrive from in-app links ("Diagnose", "Manage
    /// bypass rules") and review launch arguments; each maps to the pane
    /// that now contains it.
    static func resolve(_ raw: String) -> SettingsTab? {
        switch raw {
        case "general", "automation": .general
        case "network", "bypass", "advanced": .network
        case "privacy", "diagnostics": .privacy
        case "about", "account", "licenses": .about
        default: nil
        }
    }

    var titleString: String {
        switch self {
        case .general: AppLocalization.string("General")
        case .network: AppLocalization.string("Network")
        case .privacy: AppLocalization.string("Privacy & Diagnostics")
        case .about: AppLocalization.string("About")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape.fill"
        case .network: "network"
        case .privacy: "hand.raised.fill"
        case .about: "info"
        }
    }

    /// One tile colour per pane, as in System Settings.
    var tileColor: Color {
        switch self {
        case .general: .gray
        case .network: .blue
        case .privacy: .indigo
        case .about: .teal
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var automation: AppAutomationController
    @EnvironmentObject private var distribution:
        IndependentDistributionController
    @EnvironmentObject private var language: AppLanguageController
    @EnvironmentObject private var appearance: AppAppearanceController
    @EnvironmentObject private var dockVisibility: AppDockVisibilityController
    @EnvironmentObject private var menuBarIconController: AppMenuBarIconController
    @EnvironmentObject private var menuBarTrafficController: MenuBarTrafficController
    @EnvironmentObject private var startup: AppStartupController
    @State private var localProxyCopyMessage: String?
    @State private var localProxyCopyResetTask: Task<Void, Never>?
    @State private var localProxyValidationError: String?
    @State private var selectedShellDialect: TerminalShellDialect = .zshBash
    @State private var selectedTab: SettingsTab?
    @State private var hoveredTab: SettingsTab?
    @StateObject private var diagnosticsModalState = SupportDiagnosticsPresentationState()
    @State private var isEngineSetupPresented = false
    @State private var isConfirmingTokenRegeneration = false
    @State private var tokenRotatedFeedback = false
    @State private var tokenRotatedResetTask: Task<Void, Never>?

    init() {
        let pendingTab = AppWindowManager.shared.consumePendingSettingsTab()
            .flatMap(SettingsTab.resolve)
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        let requestedTab = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_SETTINGS_TAB"
        ].flatMap(SettingsTab.resolve)
        _selectedTab = State(initialValue: requestedTab ?? pendingTab ?? .general)
#else
        _selectedTab = State(initialValue: pendingTab ?? .general)
#endif
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                // Same row style as the main window's sidebar: a colour tile,
                // body text, and the system's own selection highlight.
                ForEach(SettingsTab.allCases) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                    HStack(spacing: AetherVisual.sRow) {
                        AetherIconTile(symbol: tab.symbol, color: tab.tileColor)
                        Text(tab.titleString)
                            .font(.body.weight(.medium))
                            .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, AetherVisual.sMicro)
                    .padding(.horizontal, AetherVisual.s1)
                    .aetherHoverHighlight(isHovered: hoveredTab == tab && selectedTab != tab)
                    .contentShape(Rectangle())
                    }
                    // A plain button keeps keyboard focus off the list, so the
                    // selection stays the quiet gray the main window uses.
                    .buttonStyle(.plain)
                    .onHover { isHovered in
                        hoveredTab = isHovered ? tab : (hoveredTab == tab ? nil : hoveredTab)
                    }
                    .accessibilityElement(children: .contain)
                    .tag(Optional(tab))
                    // The identifier lives on the title text only: on both
                    // the row and its text, UI automation found two matches
                    // and could not click either.
                }
            }
            .listStyle(.sidebar)
            // Rows are buttons; the list never takes focus, so its selection
            // is never drawn in the emphasized accent color.
            .focusable(false)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-sidebar-list")
            // Wide enough for "Privacy & Diagnostics" in English.
            .navigationSplitViewColumnWidth(min: 204, ideal: 214, max: 240)
            .accessibilityLabel(AppLocalization.string("Settings navigation"))
            .accessibilityIdentifier("aetherroute-settings-navigation")
        } detail: {
            // No label or identifier of its own: each pane is one scroll view,
            // and wrapper modifiers replaced the pane's identifier.
            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .task(id: selectedTab) {
                    await Task.yield()
                    guard let selectedTab else { return }
                    UIResponsivenessProbe.rendered(
                        "settings.\(selectedTab.rawValue)"
                    )
                }
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("AetherRoute settings"))
        .accessibilityIdentifier("aetherroute-settings-root")
        .frame(minWidth: AetherVisual.windowMinWidth, idealWidth: AetherVisual.windowWidth, minHeight: AetherVisual.windowMinHeight, idealHeight: 640)
        .onReceive(NotificationCenter.default.publisher(for: AppWindowManager.settingsNavigationNotification)) { notification in
            let raw = (notification.object as? String)
                ?? AppWindowManager.shared.consumePendingSettingsTab()
            if let raw, let tab = SettingsTab.resolve(raw) {
                _ = AppWindowManager.shared.consumePendingSettingsTab()
                selectedTab = tab
            }
        }
        .onAppear {
            if let pending = AppWindowManager.shared.consumePendingSettingsTab(),
               let tab = SettingsTab.resolve(pending) {
                selectedTab = tab
            }
        }
        .onDisappear {
            localProxyCopyResetTask?.cancel()
            localProxyCopyResetTask = nil
            tokenRotatedResetTask?.cancel()
            tokenRotatedResetTask = nil
        }
        .onChange(of: selectedTab) { _, tab in
            guard let tab else { return }
            UIResponsivenessProbe.begin("settings.\(tab.rawValue)")
        }
        .id(language.preference)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(alignment: .topLeading) {
            InitialFocusAnchor()
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .topLeading) {
            // The title names the open pane, as System Settings does.
            WindowChromeSynchronizer(
                title: (selectedTab ?? .general).titleString,
                showsTitle: true
            )
            .id("\(selectedTab?.rawValue ?? "general")-\(language.preference.rawValue)")
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .preferredColorScheme(uiReviewColorScheme)
    }

    @ViewBuilder
    private var selectedSettings: some View {
        switch selectedTab ?? .general {
        case .general:
            generalSettings
        case .network:
            networkSettings
        case .privacy:
            // Same grouped form as General and Network: privacy, live
            // diagnostics and the support report are sections, not cards.
            Form {
                PrivacyDisclosureView(isOnboarding: false, isEmbedded: true)
                SupportDiagnosticsView(
                    externalModalState: diagnosticsModalState,
                    isEmbedded: true
                )
            }
            .aetherSettingsForm(title: SettingsTab.privacy.titleString)
            .environmentObject(tunnel)
            .modifier(
                DiagnosticReportExporter(
                    state: diagnosticsModalState,
                    defaultFilename: SupportDiagnosticsView.defaultReportFilename
                )
            )
            .sheet(
                item: Binding(
                    get: { diagnosticsModalState.activeSheet },
                    set: { diagnosticsModalState.activeSheet = $0 }
                )
            ) { sheet in
                switch sheet {
                case .inventory:
                    ProxyInventorySheet()
                        .environmentObject(tunnel)
                case .logs:
                    DiagnosticLogViewer()
                        .environmentObject(tunnel)
                }
            }
        case .about:
            AboutAetherRouteView()
                .environmentObject(distribution)
                .environmentObject(tunnel)
        }
    }

    private var uiReviewColorScheme: ColorScheme? {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        switch ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_APPEARANCE"
        ] {
        case "light": .light
        case "dark": .dark
        default: nil
        }
#else
        nil
#endif
    }

    private var generalSettings: some View {
        Form {
            appearanceSettings
            languageSettings
            dockSettings
            menuBarSettings
            startupSettings
            automationSettings


            if !tunnel.hasAcceptedPrivacyDisclosure {
                Section {
                    Label(
                        AppLocalization.string("Network settings remain locked until the privacy disclosure is accepted."),
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(AetherVisual.secondaryText)
                }
            }
        }
        .aetherSettingsForm(title: SettingsTab.general.titleString)
        .onAppear {
            startup.refreshStatus()
        }
    }

    private var networkSettings: some View {
        Form {
            if !tunnel.hasAcceptedPrivacyDisclosure {
                Section {
                    Label(
                        AppLocalization.string("Network settings remain locked until the privacy disclosure is accepted."),
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(AetherVisual.secondaryText)
                }
            }

#if AETHERROUTE_INDEPENDENT
            Section {
                HStack(spacing: AetherVisual.s3) {
                    Text(AppLocalization.string("Traffic capture"))
                        .foregroundStyle(.primary)
                    AetherHelpButton(topic: .networkEngine)

                    Spacer(minLength: AetherVisual.s3)

                    AetherSegmentedPicker(
                        selection: networkEngineBinding,
                        options: NetworkEngineMode.allCases.map {
                            .init(value: $0, title: $0.localizedTitle)
                        },
                        accessibilityLabel: AppLocalization.string("Traffic capture"),
                        accessibilityIdentifier: "settings-network-engine-picker"
                    )
                    .disabled(!tunnel.canChangeNetworkEngine)
                }

                if let engineMessage = tunnel.networkEngineMessage {
                    HStack(spacing: AetherVisual.s2) {
                        Label(
                            engineMessage,
                            systemImage: tunnel.networkEngineMessageIsError
                                ? "exclamationmark.triangle.fill"
                                : "info.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            tunnel.networkEngineMessageIsError
                                ? AnyShapeStyle(AetherReadableTint(color: .orange))
                                : AnyShapeStyle(AetherVisual.secondaryText)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                        if tunnel.networkEngineBlockedNeedsSetup {
                            Spacer(minLength: AetherVisual.s2)
                            Button(AppLocalization.string("Open Network Setup…")) {
                                isEngineSetupPresented = true
                            }
                            .aetherButton()
                            .controlSize(.small)
                        }
                    }
                    .accessibilityIdentifier("settings-network-engine-message")
                }
            } header: {
                Text(AppLocalization.string("Network engine"))
            } footer: {
                Text(tunnel.networkEngineMode.localizedDetail)
            }
#endif

            Section {
                HStack(spacing: AetherVisual.s3) {
                    Text(AppLocalization.string("Routing mode"))
                        .foregroundStyle(.primary)
                    AetherHelpButton(topic: .routingMode)

                    Spacer(minLength: AetherVisual.s3)

                    AetherSegmentedPicker(
                        selection: Binding(
                            get: { tunnel.effectiveRoutingMode },
                            set: { mode in
                                Task { await tunnel.setRoutingMode(mode) }
                            }
                        ),
                        options: RoutingMode.allCases.map {
                            .init(value: $0, title: $0.localizedTitle)
                        },
                        accessibilityLabel: AppLocalization.string("Routing mode"),
                        accessibilityIdentifier: "settings-routing-mode-picker"
                    )
                    .disabled(!tunnel.canChangeRoutingMode)
                }

                if let routingMessage = tunnel.routingModeMessage {
                    Label(
                        routingMessage,
                        systemImage: tunnel.routingModeMessageIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        tunnel.routingModeMessageIsError
                            ? AnyShapeStyle(AetherReadableTint(color: .orange))
                            : AnyShapeStyle(AetherVisual.secondaryText)
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings-routing-mode-message")
                }

                Toggle(
                    AppLocalization.string("Accelerate domestic network & Apple services"),
                    isOn: Binding(
                        get: { tunnel.isDomesticOptimizationEnabled },
                        set: { tunnel.setDomesticOptimizationEnabled($0) }
                    )
                )
                .accessibilityIdentifier("domestic-optimization-toggle")
            } header: {
                Text(AppLocalization.string("Routing"))
            } footer: {
                Text(
                    AppLocalization.string(
                        "Injects high-speed direct routing and domestic DNS policy for Apple CDN, updates, and domestic websites."
                    )
                )
                Text(AppLocalization.string("Routing mode changes apply immediately when connected. Switching engines reconnects automatically. Network optimization applies on the next connection or profile reload."))
            }

            Section {
                Toggle(
                    AppLocalization.string("Close connections when switching nodes"),
                    isOn: Binding(
                        get: { tunnel.closesConnectionsOnProxySwitch },
                        set: { tunnel.setClosesConnectionsOnProxySwitch($0) }
                    )
                )
                .accessibilityIdentifier("close-connections-on-switch-toggle")
                Toggle(
                    AppLocalization.string("Test latency when opening Proxies"),
                    isOn: Binding(
                        get: { tunnel.testsLatencyWhenProxiesOpen },
                        set: { tunnel.setTestsLatencyWhenProxiesOpen($0) }
                    )
                )
                .accessibilityIdentifier("latency-on-open-toggle")
            } header: {
                Text(AppLocalization.string("Proxies"))
            } footer: {
                Text(AppLocalization.string("Closing connections makes a new node take effect at once; apps reconnect on their own. The latency test runs at most once a minute, only while connected."))
            }

            Section {
                Toggle(
                    isOn: Binding(
                        get: { tunnel.isUnifiedDelayEnabled },
                        set: { tunnel.setUnifiedDelayEnabled($0) }
                    )
                ) {
                    Text(verbatim: AppLocalization.string("Unified delay (exclude handshake)"))
                }
                .accessibilityIdentifier("unified-delay-toggle")
            } header: {
                Text(AppLocalization.string("Advanced"))
            } footer: {
                Text(verbatim: AppLocalization.string("Sends two probes over the same connection and records the second round-trip, removing TLS/QUIC handshake overhead for fairer cross-protocol comparison."))
            }

            Section {
                Toggle(
                    AppLocalization.string("Record traffic statistics"),
                    isOn: Binding(
                        get: { tunnel.isTrafficStatisticsEnabled },
                        set: { tunnel.setTrafficStatisticsEnabled($0) }
                    )
                )
                .accessibilityIdentifier("traffic-statistics-toggle")
            } header: {
                Text(AppLocalization.string("Statistics"))
            } footer: {
                Text(AppLocalization.string("Daily totals by app and by node for the last 30 days, encrypted on this Mac and never uploaded. Off until you turn it on. Open them from Overview › Statistics."))
            }

#if AETHERROUTE_INDEPENDENT
            localProxySection
#endif

            BypassRulesSection()
                .environmentObject(tunnel)
        }
        .aetherSettingsForm(title: SettingsTab.network.titleString)
        .sheet(isPresented: $isEngineSetupPresented) {
            NetworkSetupView(isOnboarding: false) {
                isEngineSetupPresented = false
            }
            .environmentObject(tunnel)
        }
    }

    private var appearanceSettings: some View {
        Section {
            LabeledContent(AppLocalization.string("Application theme")) {
                AetherSegmentedPicker(
                    selection: Binding(
                        get: { appearance.preference },
                        set: { appearance.select($0) }
                    ),
                    options: [
                        .init(value: .system, title: AppLocalization.string("Follow System")),
                        .init(value: .light, title: AppLocalization.string("Light")),
                        .init(value: .dark, title: AppLocalization.string("Dark")),
                    ],
                    accessibilityLabel: AppLocalization.string("Application theme"),
                    accessibilityIdentifier: "app-appearance-picker"
                )
            }

        } header: {
            Text(AppLocalization.string("Appearance"))
        } footer: {
            Text(AppLocalization.string("Theme changes apply immediately and are remembered next time."))
        }
    }

    private var dockSettings: some View {
        Section {
            Toggle(
                AppLocalization.string("Hide Dock icon"),
                isOn: Binding(
                    get: { dockVisibility.isDockIconHidden },
                    set: { dockVisibility.setDockIconHidden($0) }
                )
            )
            .accessibilityIdentifier("hide-dock-icon-toggle")
        } header: {
            Text(AppLocalization.string("Dock"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Keep AetherRoute in the menu bar only without a Dock icon. The main window can be reopened from the menu bar or by clicking the app icon."
                )
            )
        }
    }

    private var menuBarSettings: some View {
        Section {
            Toggle(
                AppLocalization.string("Show real-time traffic in menu bar"),
                isOn: Binding(
                    get: { menuBarTrafficController.isEnabled },
                    set: { menuBarTrafficController.setEnabled($0) }
                )
            )
            .accessibilityIdentifier("show-menubar-traffic-toggle")

            MenuBarIconPickerView(
                controller: menuBarIconController,
                isConnected: tunnel.isConnected
            )
        } header: {
            Text(AppLocalization.string("Menu Bar"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Display upload and download speeds next to the menu bar icon. Select an icon below."
                )
            )
        }
    }

    private var startupSettings: some View {
        Section {
            Toggle(
                AppLocalization.string("Launch at login"),
                isOn: Binding(
                    get: { startup.isLaunchAtLoginEnabled },
                    set: { startup.setLaunchAtLoginEnabled($0) }
                )
            )
            .accessibilityIdentifier("launch-at-login-toggle")

            if startup.serviceStatus == .requiresApproval {
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    AetherInlineMessage(
                        text: AppLocalization.string(
                            "AetherRoute requires approval in System Settings > General > Login Items & Extensions."
                        ),
                        kind: .warning,
                        isCompact: true
                    )
                    Button(AppLocalization.string("Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                }
            } else if let error = startup.errorMessage {
                AetherInlineMessage(text: error, isCompact: true)
            }
        } header: {
            Text(AppLocalization.string("Startup"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Automatically start AetherRoute when logging into macOS. If connected before quitting, it will automatically reconnect upon launch."
                )
            )
        }
    }

    private var languageSettings: some View {
        Section {
            LabeledContent(AppLocalization.string("Application language")) {
                AetherSegmentedPicker(
                    selection: languageBinding,
                    options: [
                        .init(value: .system, title: AppLocalization.string("Follow System")),
                        // Each language names itself, so it stays findable
                        // whatever language the app is showing.
                        .init(value: .simplifiedChinese, title: "简体中文"),
                        .init(value: .english, title: "English"),
                    ],
                    accessibilityLabel: AppLocalization.string("Application language"),
                    accessibilityIdentifier: "app-language-picker"
                )
            }

        } header: {
            Text(AppLocalization.string("Language"))
        } footer: {
            Text(AppLocalization.string("Language changes apply immediately throughout AetherRoute."))
        }
    }

    private var languageBinding: Binding<AppLanguagePreference> {
        Binding(
            get: { language.preference },
            set: { preference in
                UIResponsivenessProbe.begin(
                    "language.\(preference.rawValue)"
                )
                language.select(preference)
                UIResponsivenessProbe.selectLanguage(preference.rawValue)
                Task { @MainActor in
                    await Task.yield()
                    UIResponsivenessProbe.rendered(
                        "language.\(preference.rawValue)"
                    )
                }
            }
        )
    }

#if AETHERROUTE_INDEPENDENT
    private var localProxySection: some View {
        Section {
            Toggle(
                AppLocalization.string("Loopback HTTP and SOCKS5 proxy"),
                isOn: Binding(
                    get: { tunnel.localProxySettings.isEnabled },
                    set: { tunnel.setLocalProxyEnabled($0) }
                )
            )
            .disabled(!tunnel.canModifyLocalProxySettings)
            .accessibilityIdentifier("local-proxy-toggle")

            Toggle(
                AppLocalization.string("Set as macOS System Proxy"),
                isOn: Binding(
                    get: { tunnel.localProxySettings.setAsSystemProxy },
                    set: { enabled in
                        withAnimation(AetherVisual.animation(AetherVisual.disclosure)) {
                            tunnel.setSystemProxyEnabled(enabled)
                        }
                    }
                )
            )
            .disabled(!tunnel.canModifyLocalProxySettings)
            .accessibilityIdentifier("local-proxy-system-proxy-toggle")

            if tunnel.localProxySettings.setAsSystemProxy {
                LabeledContent(AppLocalization.string("System proxy status")) {
                    Text(
                        tunnel.isSystemProxyActive
                            ? AppLocalization.format(
                                "Active (127.0.0.1:%@ / :%@)",
                                String(tunnel.localProxySettings.httpPort),
                                String(tunnel.localProxySettings.socksPort)
                            )
                            : AppLocalization.string("Ready (applies automatically when active)")
                    )
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(tunnel.isSystemProxyActive ? AnyShapeStyle(AetherReadableTint(color: .green)) : AnyShapeStyle(AetherVisual.secondaryText))
                }

                SystemProxyBypassEditor(
                    domains: tunnel.localProxySettings.systemProxyBypassDomains,
                    isDisabled: !tunnel.canModifyLocalProxySettings,
                    onSave: { tunnel.setSystemProxyBypassDomains($0) }
                )
            }

            Toggle(
                AppLocalization.string("Allow LAN connections"),
                isOn: Binding(
                    get: { tunnel.localProxySettings.allowLAN },
                    set: { enabled in
                        withAnimation(AetherVisual.animation(AetherVisual.disclosure)) {
                            tunnel.setLocalProxyAllowLAN(enabled)
                        }
                    }
                )
            )
            .disabled(!tunnel.canModifyLocalProxySettings || (tunnel.isConnected && tunnel.networkEngineMode == .tun))
            .accessibilityIdentifier("local-proxy-allow-lan-toggle")

            if tunnel.isConnected && tunnel.networkEngineMode == .tun {
                Text(AppLocalization.string("Disconnect TUN mode to change Allow LAN."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
            }

            if tunnel.localProxySettings.allowLAN {
                SettingsLANAddressRow(tunnel: tunnel)
            }

            LabeledContent(AppLocalization.string("Mixed proxy (HTTP and SOCKS5)")) {
                LocalProxyPortField(
                    title: "HTTP proxy port",
                    port: tunnel.localProxySettings.httpPort,
                    identifier: "local-proxy-http-port",
                    commit: { tunnel.setLocalProxyHTTPPort($0) },
                    onValidationError: { error in
                        localProxyValidationError = error
                        localProxyCopyMessage = nil
                    },
                    onValidationCleared: {
                        localProxyValidationError = nil
                    }
                )
            }
            .disabled(!canEditLocalProxyPorts)

            LabeledContent(AppLocalization.string("Additional SOCKS5-only port")) {
                LocalProxyPortField(
                    title: "SOCKS5 proxy port",
                    port: tunnel.localProxySettings.socksPort,
                    identifier: "local-proxy-socks-port",
                    commit: { tunnel.setLocalProxySOCKSPort($0) },
                    onValidationError: { error in
                        localProxyValidationError = error
                        localProxyCopyMessage = nil
                    },
                    onValidationCleared: {
                        localProxyValidationError = nil
                    }
                )
            }
            .disabled(!canEditLocalProxyPorts)

            if !canEditLocalProxyPorts {
                Text(
                    !tunnel.canModifyLocalProxySettings
                        ? AppLocalization.string("Disconnect before changing local proxy ports.")
                        : AppLocalization.string("Enable loopback proxy, System Proxy, or Allow LAN above to customize ports.")
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
            }

            LabeledContent(AppLocalization.string("Terminal shell")) {
                AetherSegmentedPicker(
                    selection: $selectedShellDialect,
                    options: TerminalShellDialect.allCases.map {
                        .init(value: $0, title: $0.displayTitle)
                    },
                    accessibilityLabel: AppLocalization.string("Terminal shell"),
                    accessibilityIdentifier: "local-proxy-shell-dialect-picker"
                )
            }

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                AetherFlowLayout(spacing: AetherVisual.s2) {
                    AetherCopyButton(
                        title: Text(AppLocalization.string("Copy Shell Environment")),
                        systemImage: "terminal",
                        action: copyLocalProxyShellEnvironment
                    )
                    .disabled(!canCopyLocalProxyEnvironment)
                    .accessibilityIdentifier("copy-shell-proxy-button")

                    AetherCopyButton(
                        title: Text(AppLocalization.string("Copy Clear Command")),
                        systemImage: "xmark.circle"
                    ) {
                        copyToPasteboard(
                            TerminalProxyEnvGenerator.unsetCommand(
                                dialect: selectedShellDialect
                            )
                        )
                        showLocalProxyCopyMessage(
                            AppLocalization.string("Clear command copied.")
                        )
                        return true
                    }
                    .accessibilityIdentifier("copy-clear-proxy-button")

                    AetherCopyButton(
                        title: Text(AppLocalization.string("Copy PAC Script")),
                        systemImage: "doc.text",
                        action: copyLocalProxyPACScript
                    )
                    .disabled(!canCopyLocalProxyEnvironment)
                    .accessibilityIdentifier("copy-pac-script-button")
                }

                if let validationError = localProxyValidationError {
                    Label(validationError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AetherReadableTint(color: .orange))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("local-proxy-status")
                } else if let message = tunnel.localProxySettingsMessage
                    ?? localProxyCopyMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("local-proxy-status")
                }
            }
            .onChange(of: tunnel.localProxySettings) { _, _ in
                localProxyValidationError = nil
            }

        } header: {
            Text(AppLocalization.string("Local proxy"))
        } footer: {
            Text(localProxyDetail)
        }
    }

    private var canEditLocalProxyPorts: Bool {
        (tunnel.localProxySettings.isEnabled
            || tunnel.localProxySettings.allowLAN
            || tunnel.localProxySettings.setAsSystemProxy)
            && tunnel.canModifyLocalProxySettings
    }

    private var canCopyLocalProxyEnvironment: Bool {
        tunnel.localProxySettings.isEnabled
            || tunnel.localProxySettings.allowLAN
            || tunnel.localProxySettings.setAsSystemProxy
    }

    private var localProxyDetail: String {
        if tunnel.localProxySettings.setAsSystemProxy {
            return AppLocalization.string("Configures macOS HTTP, HTTPS, and SOCKS5 System Proxy (127.0.0.1) across active network services and restores prior settings automatically on disconnect or quit. Works standalone or alongside TUN / Transparent Proxy.")
        }
        if tunnel.networkEngineMode != .tun {
            return AppLocalization.string("Runs a standalone local HTTP & SOCKS5 proxy on 127.0.0.1 even outside TUN mode. Optionally enable System Proxy above to route macOS apps automatically.")
        }
        // TUN already carries Terminal traffic, so the copied environment is
        // rarely needed; say when it still helps instead of implying a step.
        return AppLocalization.string(
            "AetherRoute binds only 127.0.0.1 and never changes the macOS system proxy. Shell commands affect only the terminal where you paste them."
        ) + " " + AppLocalization.string(
            "TUN already routes Terminal traffic, so this is usually unnecessary. Use it when domain lookups misbehave, while troubleshooting, or for a tool that bypasses TUN."
        )
    }

    private func copyLocalProxyShellEnvironment() -> Bool {
        do {
            copyToPasteboard(
                try tunnel.localProxySettings.shellEnvironmentCommand(
                    dialect: selectedShellDialect
                )
            )
            localProxyValidationError = nil
            showLocalProxyCopyMessage(
                AppLocalization.string("Shell environment copied.")
            )
            return true
        } catch {
            showLocalProxyCopyMessage(tunnel.localizedLocalProxyError(error))
            return false
        }
    }

    private func showLocalProxyCopyMessage(_ message: String) {
        localProxyCopyMessage = message
        localProxyCopyResetTask?.cancel()
        localProxyCopyResetTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            localProxyCopyMessage = nil
        }
    }

    private func copyLocalProxyPACScript() -> Bool {
        do {
            let host = tunnel.localProxySettings.allowLAN
                ? LANProxyServerController.shared.currentLANIP
                : "127.0.0.1"
            copyToPasteboard(
                try tunnel.localProxySettings.pacScript(host: host)
            )
            localProxyCopyMessage = AppLocalization.string(
                "PAC script copied."
            )
            return true
        } catch {
            localProxyCopyMessage = error.localizedDescription
            return false
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
#endif

    private var automationSettings: some View {
        Section {
            Toggle(
                AppLocalization.string("Global shortcuts"),
                isOn: Binding(
                    get: { automation.shortcutPreferences.isEnabled },
                    set: { enabled in
                        automation.setGlobalShortcutsEnabled(enabled)
                    }
                )
            )
            .accessibilityIdentifier("global-shortcuts-toggle")
            .accessibilityValue(
                automation.shortcutPreferences.isEnabled
                    ? AppLocalization.string("On")
                    : AppLocalization.string("Off")
            )
            .accessibilityHint(
                Text(AppLocalization.string("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details."))
            )

            if automation.shortcutPreferences.isEnabled {
                shortcutPicker("Connect or disconnect", action: .toggleConnection)
                shortcutPicker("Rule mode", action: .routingRule)
                shortcutPicker("Global mode", action: .routingGlobal)
                shortcutPicker("Direct mode", action: .routingDirect)

                Label {
                    Text(shortcutStatusText)
                        .foregroundStyle(AetherVisual.secondaryText)
                } icon: {
                    Image(systemName: shortcutStatusSymbol)
                        .foregroundStyle(shortcutStatusStyle)
                }
                .font(.caption)
                .accessibilityIdentifier("global-shortcut-status")

                if let shortcutMessage = automation.shortcutMessage {
                    Label(shortcutMessage, systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AetherReadableTint(color: .orange))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("global-shortcut-message")
                }
            }

            Toggle(
                AppLocalization.string("Connection notifications"),
                isOn: Binding(
                    get: { automation.notificationsEnabled },
                    set: { enabled in
                        Task { await automation.setNotificationsEnabled(enabled) }
                    }
                )
            )
            .accessibilityIdentifier("connection-notifications-toggle")
            .accessibilityValue(
                automation.notificationsEnabled
                    ? AppLocalization.string("On")
                    : AppLocalization.string("Off")
            )
            .accessibilityHint(
                Text(AppLocalization.string("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details."))
            )

            Toggle(
                AppLocalization.string("Subscription alerts"),
                isOn: Binding(
                    get: { automation.subscriptionNotificationsEnabled },
                    set: { enabled in
                        Task { await automation.setSubscriptionNotificationsEnabled(enabled) }
                    }
                )
            )
            .accessibilityIdentifier("subscription-notifications-toggle")
            .help(AppLocalization.string("Notify me when the subscription in use is about to expire or has little traffic left."))

            Toggle(
                AppLocalization.string("Node switch alerts"),
                isOn: Binding(
                    get: { automation.proxySwitchNotificationsEnabled },
                    set: { enabled in
                        Task { await automation.setProxySwitchNotificationsEnabled(enabled) }
                    }
                )
            )
            .accessibilityIdentifier("proxy-switch-notifications-toggle")
            .help(AppLocalization.string("Notify me when a group in Fastest or Failover mode moves to another node because the one in use stopped answering, or returns to the preferred node."))

            HStack(spacing: AetherVisual.s2) {
                Label(notificationStatusText, systemImage: notificationStatusSymbol)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                if automation.notificationPermission == .denied {
                    Spacer(minLength: AetherVisual.s2)
                    Button(AppLocalization.string("Open System Settings")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                }
            }

            Toggle(
                AppLocalization.string("Network environment rules"),
                isOn: Binding(
                    get: { automation.networkAutomationPreferences.isEnabled },
                    set: { enabled in
                        automation.setNetworkAutomationEnabled(enabled)
                    }
                )
            )
            .accessibilityIdentifier("network-automation-toggle")
            .help(AppLocalization.string("Automatically switch routing mode or connect/disconnect when joining a specific router gateway, wired Ethernet, or Wi-Fi network."))

            if automation.networkAutomationPreferences.isEnabled {
                NetworkAutomationRulesEditor()
                    .environmentObject(automation)
                    .environmentObject(tunnel)
            }

            Toggle(
                AppLocalization.string("Allow control URL scheme (aetherroute://)"),
                isOn: Binding(
                    get: { tunnel.controlURLSchemePreferences.allowControlURLScheme },
                    set: { tunnel.setControlURLSchemeEnabled($0) }
                )
            )
            .accessibilityIdentifier("control-url-scheme-toggle")

            if tunnel.controlURLSchemePreferences.allowControlURLScheme {
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    Text(
                        AppLocalization.string("Supported actions: aetherroute://connect, disconnect, toggle, set-mode?mode=rule|global|direct|tun|transparent, switch-profile?name=... (append ?token=<secret> for silent script execution; links without a token require confirmation).")
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(AetherVisual.secondaryText)

                    HStack(spacing: AetherVisual.s2) {
                        AetherCopyButton(
                            title: Text(AppLocalization.string("Copy Token")),
                            systemImage: "key.fill"
                        ) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(tunnel.controlURLSchemeToken, forType: .string)
                            return true
                        }
                        Button(role: .destructive) {
                            isConfirmingTokenRegeneration = true
                        } label: {
                            Text(AppLocalization.string("Regenerate Token"))
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .confirmationDialog(
                            AppLocalization.string("Regenerate control URL token?"),
                            isPresented: $isConfirmingTokenRegeneration,
                            titleVisibility: .visible
                        ) {
                            Button(AppLocalization.string("Regenerate Token"), role: .destructive) {
                                _ = tunnel.regenerateControlURLSchemeToken()
                                tokenRotatedFeedback = true
                                tokenRotatedResetTask?.cancel()
                                tokenRotatedResetTask = Task { @MainActor in
                                    try? await Task.sleep(for: .seconds(2))
                                    guard !Task.isCancelled else { return }
                                    tokenRotatedFeedback = false
                                }
                            }
                        } message: {
                            Text(AppLocalization.string("Existing scripts using the previous token will stop working until you update them."))
                        }

                        if tokenRotatedFeedback {
                            Label(
                                AppLocalization.string("New token generated"),
                                systemImage: "checkmark.circle.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(AetherReadableTint(color: .green))
                        }
                    }
                }
            }

        } header: {
            Text(AppLocalization.string("Automation"))
        } footer: {
            Text(AppLocalization.string("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details."))
        }
    }

    private func shortcutPicker(
        _ title: String.LocalizationValue,
        action: GlobalShortcutAction
    ) -> some View {
        ShortcutAssignmentRow(title: title, action: action)
            .environmentObject(automation)
    }

    private var shortcutStatusText: String {
        switch automation.shortcutState {
        case .disabled:
            AppLocalization.string("Global shortcuts are off")
        case .active:
            AppLocalization.string("Global shortcuts are active")
        case let .conflict(key):
            AppLocalization.format(
                "%@ is already used by another app — all global shortcuts are paused",
                key
            )
        }
    }

    private var shortcutStatusSymbol: String {
        switch automation.shortcutState {
        case .disabled: "keyboard"
        case .active: "checkmark.circle.fill"
        case .conflict: "exclamationmark.triangle.fill"
        }
    }

    private var shortcutStatusStyle: AnyShapeStyle {
        switch automation.shortcutState {
        case .disabled: AnyShapeStyle(AetherVisual.secondaryText)
        case .active: AnyShapeStyle(AetherReadableTint(color: .green))
        case .conflict: AnyShapeStyle(AetherReadableTint(color: .orange))
        }
    }

    private var hasAnyNotificationEnabled: Bool {
        automation.notificationsEnabled
            || automation.subscriptionNotificationsEnabled
            || automation.proxySwitchNotificationsEnabled
    }

    private var notificationStatusText: String {
        switch automation.notificationPermission {
        case .notRequested:
            AppLocalization.string("macOS will ask only when you turn notifications on")
        case .authorized:
            hasAnyNotificationEnabled
                ? AppLocalization.string("Notification alerts are active")
                : AppLocalization.string("Notification permission is available")
        case .denied:
            AppLocalization.string("Notifications are disabled in System Settings")
        case .unavailable:
            AppLocalization.string("Notification status is unavailable")
        }
    }

    private var notificationStatusSymbol: String {
        switch automation.notificationPermission {
        case .authorized where hasAnyNotificationEnabled: "bell.badge.fill"
        case .denied, .unavailable: "bell.slash.fill"
        default: "bell"
        }
    }

#if AETHERROUTE_INDEPENDENT
    private var networkEngineBinding: Binding<NetworkEngineMode> {
        Binding(
            get: { tunnel.networkEngineMode },
            set: { mode in
                Task { await tunnel.setNetworkEngineMode(mode) }
            }
        )
    }
#endif
}

private struct ShortcutAssignmentRow: View {
    @EnvironmentObject private var automation: AppAutomationController
    @State private var isPresentingChoices = false

    let title: String.LocalizationValue
    let action: GlobalShortcutAction

    private var localizedTitle: String { AppLocalization.string(title) }

    private var isConflictingSelection: Bool {
        guard case let .conflict(conflictKey) = automation.shortcutState else {
            return false
        }
        return conflictKey == selection.displayTitle
    }

    private var selection: GlobalShortcutKey {
        automation.shortcutPreferences[action]
    }

    private var shortcutChoices: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(localizedTitle)
                .font(.headline)
                .padding(.horizontal, AetherVisual.s3)
                .padding(.top, AetherVisual.s2)

            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(GlobalShortcutKey.allCases, id: \.self) { key in
                        Button {
                            automation.assignShortcut(key, to: action)
                            isPresentingChoices = false
                        } label: {
                            HStack {
                                Text(key.displayTitle)
                                    .monospaced()
                                Spacer()
                                if key == selection {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(Color.accentColor)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .padding(.horizontal, AetherVisual.s3)
                        .frame(height: 28)
                    }
                }
            }
            .frame(maxHeight: 260)
        }
        .padding(AetherVisual.s2)
        .frame(width: 230)
    }

    var body: some View {
        LabeledContent {
            Button {
                isPresentingChoices = true
            } label: {
                HStack(spacing: AetherVisual.s2) {
                    Text(selection.displayTitle)
                        .monospaced()
                        .foregroundStyle(
                            isConflictingSelection
                                ? AnyShapeStyle(AetherReadableTint(color: .orange))
                                : AnyShapeStyle(.primary)
                        )
                    Image(systemName: isConflictingSelection ? "exclamationmark.triangle.fill" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(
                            isConflictingSelection
                                ? AnyShapeStyle(AetherReadableTint(color: .orange))
                                : AnyShapeStyle(AetherVisual.secondaryText)
                        )
                }
            }
            .aetherButton()
            .accessibilityLabel(localizedTitle)
            .accessibilityValue(selection.displayTitle)
            .popover(isPresented: $isPresentingChoices, arrowEdge: .trailing) {
                shortcutChoices
            }
        } label: {
            Text(localizedTitle)
        }
    }
}

private struct NetworkAutomationRulesEditor: View {
    @EnvironmentObject private var automation: AppAutomationController
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var triggerKind: NetworkTriggerKind = .gatewayAddress
    @State private var triggerValue = ""
    @State private var selectedAction: NetworkAutomationAction = .setRoutingMode(.direct)

    private var availableActions: [NetworkAutomationAction] {
        var actions: [NetworkAutomationAction] = [
            .setRoutingMode(.rule),
            .setRoutingMode(.global),
            .setRoutingMode(.direct),
            .connect,
            .disconnect,
            .setEngineMode(.transparent),
            .setEngineMode(.tun),
        ]
        for profile in tunnel.profiles {
            actions.append(.switchProfile(profile.id))
        }
        return actions
    }

    private var canAddRule: Bool {
        triggerKind == .ethernet
            || !triggerValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                HStack(spacing: AetherVisual.s2) {
                    Picker(AppLocalization.string("Condition"), selection: $triggerKind) {
                        Text(AppLocalization.string("Router gateway")).tag(NetworkTriggerKind.gatewayAddress)
                        Text(AppLocalization.string("Wired Ethernet")).tag(NetworkTriggerKind.ethernet)
                        Text(AppLocalization.string("Wi-Fi SSID")).tag(NetworkTriggerKind.wifiSSID)
                    }
                    .labelsHidden()
                    .frame(width: 140)
                    .accessibilityIdentifier("network-automation-trigger-picker")

                    if triggerKind != .ethernet {
                        TextField(
                            triggerKind == .gatewayAddress
                                ? AppLocalization.string("e.g. 192.168.50.1")
                                : AppLocalization.string("e.g. Office-5G"),
                            text: $triggerValue
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.callout.monospaced())
                        .onSubmit {
                            if canAddRule { addRule() }
                        }
                        .accessibilityIdentifier("network-automation-value-field")

                        if triggerKind == .gatewayAddress,
                           let currentGateway = automation.currentNetworkEnvironment?.gatewayAddress,
                           !currentGateway.isEmpty {
                            Button(AppLocalization.string("Use current")) {
                                triggerValue = currentGateway
                            }
                            .aetherButton()
                            .controlSize(.small)
                        }
                    }
                }

                HStack(spacing: AetherVisual.s2) {
                    Picker(AppLocalization.string("Action"), selection: $selectedAction) {
                        ForEach(availableActions, id: \.self) { action in
                            Text(actionTitle(action)).tag(action)
                        }
                    }
                    .labelsHidden()
                    .frame(minWidth: 160, maxWidth: 240, alignment: .leading)
                    .accessibilityIdentifier("network-automation-action-picker")

                    Spacer(minLength: AetherVisual.s2)

                    Button(AppLocalization.string("Add")) {
                        addRule()
                    }
                    .aetherButton(prominent: true)
                    .disabled(!canAddRule)
                    .accessibilityIdentifier("network-automation-add-button")
                }
            }
            .onChange(of: tunnel.profiles) { _, _ in
                if !availableActions.contains(selectedAction) {
                    selectedAction = availableActions.first ?? .setRoutingMode(.direct)
                }
            }

            if let message = automation.networkAutomationMessage {
                AetherInlineMessage(text: message, isCompact: true)
            }

            ForEach(automation.networkAutomationPreferences.rules) { rule in
                HStack(spacing: AetherVisual.s3) {
                    Toggle(
                        isOn: Binding(
                            get: { rule.isEnabled },
                            set: { isOn in
                                automation.setNetworkRuleEnabled(id: rule.id, isEnabled: isOn)
                            }
                        )
                    ) { EmptyView() }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(Text(verbatim: triggerSummary(rule)))

                    HStack(spacing: AetherVisual.s2) {
                        Text(verbatim: triggerSummary(rule))
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Image(systemName: "arrow.right")
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .accessibilityHidden(true)
                        Text(actionTitle(rule.action))
                            .font(.callout.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: AetherVisual.s2)
                    Button(role: .destructive) {
                        automation.removeNetworkRule(id: rule.id)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(AetherVisual.secondaryText)
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppLocalization.string("Delete"))
                }
            }
        }
        .onAppear {
            automation.refreshCurrentNetworkEnvironment()
        }
    }

    private func addRule() {
        let rule = NetworkAutomationRule(
            isEnabled: true,
            triggerKind: triggerKind,
            matchValue: triggerKind == .ethernet ? "" : triggerValue,
            action: selectedAction
        )
        if automation.addOrUpdateNetworkRule(rule) {
            triggerValue = ""
        }
    }

    private func triggerSummary(_ rule: NetworkAutomationRule) -> String {
        switch rule.triggerKind {
        case .ethernet:
            AppLocalization.string("Wired Ethernet")
        case .gatewayAddress:
            "\(AppLocalization.string("Gateway")) \(rule.matchValue)"
        case .wifiSSID:
            "Wi-Fi \(rule.matchValue)"
        }
    }

    private func actionTitle(_ action: NetworkAutomationAction) -> String {
        switch action {
        case .setRoutingMode(.rule):
            AppLocalization.string("Rule mode")
        case .setRoutingMode(.global):
            AppLocalization.string("Global mode")
        case .setRoutingMode(.direct):
            AppLocalization.string("Direct mode")
        case .connect:
            AppLocalization.string("Connect")
        case .disconnect:
            AppLocalization.string("Disconnect")
        case .setEngineMode(.transparent):
            AppLocalization.string("Engine: Transparent")
        case .setEngineMode(.tun):
            AppLocalization.string("Engine: TUN")
        case let .switchProfile(profileID):
            if let managed = tunnel.profiles.first(where: { $0.id == profileID }) {
                AppLocalization.format("Profile: %@", managed.profile.name)
            } else {
                AppLocalization.string("Switch profile")
            }
        }
    }
}

private struct SystemProxyBypassEditor: View {
    let domains: [String]
    let isDisabled: Bool
    let onSave: ([String]) -> Void

    @State private var text = ""
    @State private var didApply = false
    @State private var feedbackTask: Task<Void, Never>?

    private var parsedDomains: [String] {
        text.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var isDirty: Bool {
        parsedDomains != domains
    }

    private var canResetToDefaults: Bool {
        domains != LocalProxySettings.defaultSystemProxyBypassDomains
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s2) {
                Text(AppLocalization.string("System proxy bypass domains"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                if didApply {
                    Label(AppLocalization.string("Saved"), systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AetherReadableTint(color: .green))
                }
                Spacer(minLength: AetherVisual.s2)
                Button(AppLocalization.string("Reset defaults")) {
                    onSave(LocalProxySettings.defaultSystemProxyBypassDomains)
                    showSavedFeedback()
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(isDisabled || !canResetToDefaults)
            }
            HStack(spacing: AetherVisual.s2) {
                TextField(
                    AppLocalization.string("localhost, 127.0.0.1, *.local"),
                    text: $text
                )
                .textFieldStyle(.roundedBorder)
                .font(.caption.monospaced())
                .disabled(isDisabled)
                .onSubmit {
                    if isDirty && !isDisabled { commit() }
                }
                Button(AppLocalization.string("Apply")) {
                    commit()
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(isDisabled || !isDirty)
            }
        }
        .onAppear { syncFromDomains() }
        .onChange(of: domains) { _, _ in syncFromDomains() }
        .onDisappear {
            feedbackTask?.cancel()
            feedbackTask = nil
        }
    }

    private func syncFromDomains() {
        let joined = domains.joined(separator: ", ")
        if text != joined {
            text = joined
        }
    }

    private func commit() {
        onSave(parsedDomains)
        showSavedFeedback()
    }

    private func showSavedFeedback() {
        didApply = true
        feedbackTask?.cancel()
        feedbackTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            didApply = false
        }
    }
}

/// A loopback port typed in full. A stepper needed thousands of clicks to
/// move between common ports such as 7890 and 1080. The value is committed on
/// Return or when focus leaves; TunnelManager validates it and reports a bad
/// port, and the field then shows the port actually in effect.
private struct LocalProxyPortField: View {
    let title: String.LocalizationValue
    let port: Int
    let identifier: String
    let commit: (Int) -> Void
    var onValidationError: ((String) -> Void)? = nil
    var onValidationCleared: (() -> Void)? = nil

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AetherVisual.s1) {
            Text(verbatim: "127.0.0.1:")
                .monospacedDigit()
                .foregroundStyle(AetherVisual.secondaryText)
            TextField(AppLocalization.string(title), text: $text)
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
                .frame(width: 64)
                .focused($isFocused)
                .onSubmit(apply)
                .accessibilityIdentifier(identifier)
        }
        .onAppear { text = String(port) }
        .onChange(of: port) { _, newPort in text = String(newPort) }
        .onChange(of: isFocused) { _, focused in
            if !focused { apply() }
        }
    }

    private func apply() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let value = Int(trimmed) else {
            onValidationError?(
                AppLocalization.format(
                    "Port must be a number between %lld and %lld.",
                    Int64(LocalProxySettings.permittedPorts.lowerBound),
                    Int64(LocalProxySettings.permittedPorts.upperBound)
                )
            )
            text = String(port)
            return
        }
        onValidationCleared?()
        guard value != port else {
            text = String(port)
            return
        }
        commit(value)
        // A rejected port leaves `port` unchanged, so onChange never fires;
        // restore it here. An accepted one arrives through onChange.
        text = String(port)
    }
}

/// Holds a window's first focus so that no text field takes it on open.
/// Settings otherwise focused the bypass-rule field whenever Network opened,
/// and the form scrolled down to it past the engine and routing sections.
private struct InitialFocusAnchor: NSViewRepresentable {
    final class AnchorView: NSView {
        override var acceptsFirstResponder: Bool { true }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.initialFirstResponder = self
            if window.firstResponder is NSText || window.firstResponder === window {
                window.makeFirstResponder(self)
            }
        }
    }

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}
}

private struct MainWindowRootHost<Content: View>: View {
    @Environment(\.openWindow) private var openWindow
    @ViewBuilder let content: Content

    var body: some View {
        content
            .onAppear {
                AppWindowManager.shared.openWindowAction = { [openWindow] in
                    openWindow(id: "main")
                }
            }
    }
}

private struct MenuBarStatusItemView: View, Equatable {
    let iconController: AppMenuBarIconController
    let trafficController: MenuBarTrafficController
    let isConnected: Bool
    let hasUpdate: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.isConnected == rhs.isConnected
            && lhs.hasUpdate == rhs.hasUpdate
            && lhs.iconController === rhs.iconController
            && lhs.trafficController === rhs.trafficController
    }

    var body: some View {
        MenuBarStatusItemImage(
            iconController: iconController,
            trafficController: trafficController,
            isConnected: isConnected,
            hasUpdate: hasUpdate
        )
    }
}

private struct MenuBarStatusItemImage: View {
    @ObservedObject var iconController: AppMenuBarIconController
    @ObservedObject var trafficController: MenuBarTrafficController
    let isConnected: Bool
    let hasUpdate: Bool

    var body: some View {
        Image(nsImage: trafficController.menuBarImage(
            symbol: iconController.currentSymbol(isConnected: isConnected),
            isConnected: isConnected,
            hasUpdate: hasUpdate
        ))
    }
}

private struct SettingsLANAddressRow: View {
    @ObservedObject var tunnel: TunnelManager
    @ObservedObject private var lanController = LANProxyServerController.shared

    var body: some View {
        let lanIP = lanController.currentLANIP
        let canReachOverLAN = tunnel.isConnected && lanIP != "127.0.0.1"
        let failureMessage = lanController.statusFailure.map {
            tunnel.localizedLANProxyStatusFailure($0)
        } ?? lanController.statusMessage
        LabeledContent(AppLocalization.string("LAN proxy")) {
            if let errorMessage = failureMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(AetherReadableTint(color: .orange))
            } else if canReachOverLAN {
                HStack(spacing: AetherVisual.s2) {
                    Text(verbatim: "\(lanIP):\(tunnel.localProxySettings.httpPort)")
                        .font(.callout.monospaced())
                    LanCopyGuideButton(
                        guideText: tunnel.localProxySettings.localizedLANConfigurationGuide(lanIP: lanIP),
                        accessibilityIdentifier: "copy-lan-guide-button"
                    )
                }
            } else {
                Text(
                    tunnel.isConnected
                        ? AppLocalization.string("No active Wi-Fi or Ethernet address detected yet.")
                        : AppLocalization.string("LAN sharing is ready and activates when connected.")
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
            }
        }
    }
}

private struct MenuBarIconPickerView: View {
    @ObservedObject var controller: AppMenuBarIconController
    let isConnected: Bool

    private let columns = [
        GridItem(.adaptive(minimum: 40, maximum: 44), spacing: AetherVisual.sCompact)
    ]

    var body: some View {
        HStack(alignment: .top, spacing: AetherVisual.s4) {
            VStack(spacing: AetherVisual.s2) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                        .fill(AetherVisual.cardFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                .strokeBorder(AetherVisual.tintBorder(Color.secondary), lineWidth: 1)
                        )

                    Image(systemName: controller.currentSymbol(isConnected: isConnected))
                        .font(.largeTitle.weight(.medium))
                        .symbolRenderingMode(.hierarchical)
                        .frame(width: 44, height: 44)
                        .foregroundStyle(.primary)
                }
                .frame(width: 84, height: 84)

                Text(controller.currentIcon.localizedTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                Text(isConnected ? AppLocalization.string("Connected") : AppLocalization.string("Disconnected"))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(isConnected ? AnyShapeStyle(AetherReadableTint(color: .green)) : AnyShapeStyle(AetherVisual.secondaryText))
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(isConnected ? AetherVisual.tintFill(.green) : AetherVisual.neutralFill, in: Capsule())
            }
            .frame(width: 96)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(currentAccessibilityLabel)

            LazyVGrid(columns: columns, spacing: AetherVisual.sCompact) {
                ForEach(AppMenuBarIconOption.allCases) { option in
                    MenuBarIconCell(
                        option: option,
                        isSelected: controller.currentIcon == option,
                        isConnected: isConnected,
                        action: {
                            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                                controller.select(option)
                            }
                        }
                    )
                }
            }
        }
        .padding(.vertical, AetherVisual.s1)
    }

    private var currentAccessibilityLabel: String {
        let prefix = AppLocalization.string("Current")
        return "\(prefix): \(controller.currentIcon.localizedTitle)"
    }
}

private struct MenuBarIconCell: View {
    let option: AppMenuBarIconOption
    let isSelected: Bool
    let isConnected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            cellContent
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(option.localizedTitle)
        .accessibilityLabel(option.localizedTitle)
        .accessibilityIdentifier("menu-bar-icon-\(option.rawValue)")
    }

    private var cellContent: some View {
        let shape = RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
        return ZStack {
            shape
                .fill(backgroundFill)
                .overlay(shape.strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5))
            Image(systemName: option.symbol(isConnected: isConnected))
                .font(.body.weight(.medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                .frame(width: 22, height: 22)
        }
        .frame(height: 38)
        .contentShape(Rectangle())
    }

    private var backgroundFill: Color {
        if isSelected {
            return AetherVisual.selectionFill
        }
        if isHovered {
            return AetherVisual.hoverFill
        }
        return AetherVisual.subtleFill
    }
}


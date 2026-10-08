import AppKit
import AetherRouteKit
import Darwin
import OSLog
import SwiftUI

@MainActor
final class AetherRouteApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSUserInterfaceValidations {
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
        Task { @MainActor [weak self] in
            await self?.tunnel?.prepare()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            tunnel?.handleExternalURL(url)
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

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.update(title: title, showsTitle: showsTitle, isMainWindow: isMainWindow)
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.update(title: title, showsTitle: showsTitle, isMainWindow: isMainWindow)
    }
}

final class WindowChromeView: NSView {
    private static let automaticSidebarToggleIdentifier =
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"

    private var expectedTitle = ""
    private var showsWindowTitle = true
    private var isMainWindow = false
    private weak var observedWindow: NSWindow?
    private let visibilityCoordinator = WindowVisibilityCoordinator()

    func update(title: String, showsTitle: Bool, isMainWindow: Bool = false) {
        expectedTitle = title
        showsWindowTitle = showsTitle
        self.isMainWindow = isMainWindow
        applyWindowChrome()
        if isMainWindow, let window {
            AppWindowManager.shared.registerMainWindow(window)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        observedWindow = window
        visibilityCoordinator.observe(window)
        if isMainWindow, let window {
            AppWindowManager.shared.registerMainWindow(window)
        }
        window?.addObserver(
            self,
            forKeyPath: "title",
            options: [.new],
            context: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(toolbarWillAddItem(_:)),
            name: NSToolbar.willAddItemNotification,
            object: window?.toolbar
        )
        applyWindowChrome()
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.applyWindowChrome()
            self?.visibilityCoordinator.recoverIfNeeded()
        }
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        if keyPath == "title" {
            Task { @MainActor [weak self] in
                self?.applyWindowChrome()
            }
            return
        }
        super.observeValue(
            forKeyPath: keyPath,
            of: object,
            change: change,
            context: context
        )
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

    private func stopObservingWindow() {
        visibilityCoordinator.stopObserving()
        NotificationCenter.default.removeObserver(self)
        observedWindow?.removeObserver(
            self,
            forKeyPath: "title"
        )
        observedWindow = nil
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
        } label: {
            // Template artwork follows the menu bar's light/dark appearance.
            // With an update waiting, a drawn copy adds a blue dot; it draws
            // the glyph in the menu bar's label colour so it still adapts.
            Group {
                if updater.availability.availableVersion != nil {
                    Image(nsImage: MenuBarBadgedIcon.image(symbol: menuBarIcon))
                } else {
                    Image(systemName: menuBarIcon)
                }
            }
            .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(appearance)
                .environmentObject(dockVisibility)
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
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommandButton()
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
            CommandMenu("Navigate") {
                Button(AppLocalization.string("Command Palette…")) {
                    AppWindowManager.shared.showMainWindow()
                    NotificationCenter.default.post(name: .aetherRouteToggleCommandPalette, object: nil)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                Divider()
                ForEach(AppSection.allCases) { section in
                    Button(section.title) {
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

            CommandMenu("Proxy") {
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
        tunnel.isConnected ? "paperplane.fill" : "paperplane"
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
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onVisibilityChanged?(isVisible)
        }
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
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showingNodes = false
    @State private var isMenuVisible = false
    @State private var copiedMessage: String?
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
            showingNodes = false
        }
    }

    /// Laid out like a Control Center module: state and the switch first,
    /// then live traffic, then one glass group for the exit and the modes;
    /// terminal helpers and app commands live in the overflow menu.
    private var readyContent: some View {
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
                }
                .padding(AetherVisual.s3)
                .aetherGlass(in: RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            // The switch is disabled in both cases; say why and where to go
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

            footer
        }
        .padding(AetherVisual.s4)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: tunnel.isConnected)
    }

    /// The active subscription running out or ended, worded for the panel.
    private var subscriptionNotice: (alert: SubscriptionUsageAlert, title: String, detail: String)? {
        guard let usage = tunnel.activeProfile?.subscription?.usage else { return nil }
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
        section: AppSection
    ) -> some View {
        HStack(alignment: .top, spacing: AetherVisual.s2) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
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
                NotificationCenter.default.post(
                    name: .aetherRouteNavigateToSection,
                    object: section.rawValue
                )
                AppWindowManager.shared.showMainWindow()
            }
            .buttonStyle(.aetherGlassCapsule)
        }
        .padding(AetherVisual.s3)
        .aetherGlass(in: RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: AetherVisual.s3) {
            ConnectionMedallion(phase: ConnectionMedallion.Phase(tunnel: tunnel), size: 40)
                .padding(AetherVisual.s1)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(tunnel.compactStatusTitle)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(isFailed ? Color.red : Color.primary)
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
            TimelineView(.periodic(from: since, by: 60)) { context in
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("Connected for %@"),
                        AppLocalization.duration(context.date.timeIntervalSince(since))
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
        VStack(spacing: 0) {
            if let group = primaryGroup {
                exitRow(group)
                if showingNodes {
                    MenuNodeListInline(group: group) {
                        withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                            showingNodes = false
                        }
                    }
                    .padding(.horizontal, AetherVisual.s2)
                    .padding(.bottom, AetherVisual.s2)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
                rowDivider
            }
            panelRow(symbol: "arrow.triangle.branch", tint: .orange, title: AppLocalization.string("Routing mode"), help: .routingMode) {
                RoutingModeSegmentedControl(
                    selection: Binding(
                        get: { tunnel.routingMode },
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
#endif
        }
        .aetherGlass(in: RoundedRectangle(cornerRadius: Self.groupRadius, style: .continuous))
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
        .frame(minHeight: 44)
        .padding(.horizontal, AetherVisual.s3)
    }

    private func exitRow(_ group: ProxyGroupConfigurationSummary) -> some View {
        Button {
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                showingNodes.toggle()
            }
        } label: {
            HStack(spacing: AetherVisual.s2) {
                AetherIconTile(symbol: "globe", color: .indigo, size: Self.rowTileSize)
                let member = tunnel.proxySelections[group.name]?.selectedMember
                MenuSelectedNodeTitle(
                    member: member,
                    leaf: member.flatMap { tunnel.automaticGroupLeaves[$0] }
                )
                if let member {
                    MenuNodeLatency(
                        status: ProxyLatencyStatus.status(
                            member: member,
                            results: tunnel.proxyLatencies[group.name]?.results,
                            isTesting: tunnel.proxyLatencyRequests.contains(group.name)
                        ),
                        confidence: tunnel.latencyConfidence(group: group.name, member: member)
                    )
                }
                AetherDisclosureChevron(isExpanded: showingNodes)
            }
            .frame(minHeight: 44)
            .padding(.horizontal, AetherVisual.s3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.aetherPressable)
        .help(tunnel.proxySelections[group.name]?.selectedMember ?? AppLocalization.string("Select Node"))
        .accessibilityIdentifier("menu-proxy-node-selector")
        .task(id: "\(group.name):\(tunnel.isConnected)") {
            await tunnel.refreshProxySelection(group: group.name)
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
                    .foregroundStyle(.green)
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
            if let group = primaryGroup {
                let isTesting = tunnel.proxyLatencyRequests.contains(group.name)
                Button {
                    Task { await tunnel.testProxyLatency(group: group.name) }
                } label: {
                    // Text beside the icon: a bare bolt was easy to miss.
                    HStack(spacing: AetherVisual.s1) {
                        if isTesting {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "bolt.fill")
                        }
                        Text(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.aetherGlassCapsule)
                .disabled(isTesting)
                .help(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
                .accessibilityLabel(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
                .accessibilityIdentifier("menu-proxy-speedtest-button")
            }
            Menu {
                Text(verbatim: "AetherRoute \(SparkleUpdaterController.currentVersion)")
                Divider()
                Button(AppLocalization.string("Copy Proxy Command"), systemImage: "terminal") {
                    copy(terminalProxyCommand)
                }
                .disabled(!tunnel.canCopyTerminalProxyCommand)
                .accessibilityIdentifier("copy-terminal-proxy-button")
#if AETHERROUTE_INDEPENDENT
                if !tunnel.canCopyTerminalProxyCommand {
                    Text(
                        tunnel.networkEngineMode == .tun
                            ? AppLocalization.string("Turn on the local proxy in Settings › Network.")
                            : AppLocalization.string("Switch to TUN to use the local proxy.")
                    )
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
                .disabled(!SparkleUpdaterController.shared.canCheckForUpdates)
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
        (try? tunnel.localProxySettings.shellEnvironmentCommand())
            ?? [
                "export HTTP_PROXY=http://127.0.0.1:\(tunnel.localProxySettings.httpPort)",
                "export HTTPS_PROXY=http://127.0.0.1:\(tunnel.localProxySettings.httpPort)",
                "export ALL_PROXY=socks5h://127.0.0.1:\(tunnel.localProxySettings.socksPort)",
                "export http_proxy=\"$HTTP_PROXY\"",
                "export https_proxy=\"$HTTPS_PROXY\"",
                "export all_proxy=\"$ALL_PROXY\"",
                "export NO_PROXY=localhost,127.0.0.1,::1",
                "export no_proxy=\"$NO_PROXY\"",
            ].joined(separator: "; ")
    }

    private func copy(_ command: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        copiedMessage = AppLocalization.string("Copied")
        Task {
            try? await Task.sleep(for: .seconds(2))
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

    private var primaryGroup: ProxyGroupConfigurationSummary? {
        let groups = tunnel.activeProfileSummary?.proxyGroups ?? []
        return groups.first { $0.strategy.lowercased() == "select" } ?? groups.first
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
                AetherRouteBrandTile(size: 38)

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
                .aetherGlassButton(prominent: true)
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

private struct MenuNodeLatency: View {
    let status: ProxyLatencyStatus
    var confidence: ProxyLatencyConfidence = .reachability

    var body: some View {
        HStack(spacing: AetherVisual.sMicro) {
            Text(title)
                .font(.caption.monospacedDigit())
                .foregroundStyle(status.tint)
                .fixedSize()

            if status.isMeasured, confidence == .verified {
                Image(systemName: confidence.symbol)
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .help(status.isMeasured ? confidence.localizedHint : title)
    }

    private var title: String {
        status.localizedTitle
    }
}

private struct MenuNodeListInline: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let group: ProxyGroupConfigurationSummary
    let onClose: () -> Void
    @State private var orderedMembers: [String] = []
    @State private var selecting = false
    @State private var searchText = ""

    private var selectedMember: String? {
        tunnel.proxySelections[group.name]?.selectedMember
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
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            // A short list is faster to scan than to search.
            if orderedMembers.count > Self.searchThreshold {
                HStack(spacing: AetherVisual.s1) {
                    Image(systemName: "magnifyingglass")
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                    // Kept compact for the panel rather than AetherSearchField,
                    // but with the same Escape-to-clear and labelled clear button.
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
                    .padding(.vertical, AetherVisual.s2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if filteredMembers.isEmpty {
                Text(AppLocalization.string("No matching nodes"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .padding(.vertical, AetherVisual.s2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filteredMembers, id: \.self) { member in
                            MenuNodeRow(
                                member: member,
                                isSelected: member == selectedMember,
                                status: status(for: member),
                                confidence: tunnel.latencyConfidence(group: group.name, member: member)
                            ) {
                                if member == selectedMember {
                                    onClose()
                                    return
                                }
                                selecting = true
                                Task {
                                    await tunnel.selectProxy(group: group.name, member: member)
                                    selecting = false
                                }
                            }
                            .disabled(selecting || tunnel.proxySelectionRequests.contains(group.name)
                                || group.strategy.lowercased() != "select" || unsupported.contains(member))
                        }
                    }
                }
                .frame(height: min(CGFloat(filteredMembers.count) * MenuNodeRow.height, MenuNodeRow.height * Self.visibleRows))
                .scrollBounceBehavior(.basedOnSize)
            }
            if group.strategy.lowercased() != "select" {
                Text(AppLocalization.string("This group is automatically managed by latency tests."))
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            if let message = tunnel.proxySelectionMessages[group.name] {
                Text(verbatim: message)
                    .font(.caption2)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("menu-node-message")
            }
        }
        .task(id: group.name) {
            updateOrder()
            await tunnel.refreshProxySelection(group: group.name)
            guard !Task.isCancelled else { return }
            updateOrder()
            if tunnel.isConnected, tunnel.proxyLatencies[group.name] == nil {
                await tunnel.testProxyLatency(group: group.name)
                guard !Task.isCancelled else { return }
                updateOrder()
            }
        }
    }

    private static let searchThreshold = 8
    private static let visibleRows: CGFloat = 7

    private func status(for member: String) -> ProxyLatencyStatus {
        if unsupported.contains(member) { return .timedOut }
        return ProxyLatencyStatus.status(
            member: member,
            results: tunnel.proxyLatencies[group.name]?.results,
            isTesting: tunnel.proxyLatencyRequests.contains(group.name)
        )
    }

    private func updateOrder() {
        orderedMembers = MenuProxyNodeOrder.sorted(
            members: tunnel.proxySelections[group.name]?.members ?? group.members
        )
    }
}

/// The status-item glyph with a small blue "update available" dot.
enum MenuBarBadgedIcon {
    static func image(symbol: String) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else { return NSImage() }
        let dot: CGFloat = 6
        let size = NSSize(width: glyph.size.width + dot / 2, height: glyph.size.height)
        let image = NSImage(size: size, flipped: false) { _ in
            // Resolved at draw time, so the glyph follows the menu bar's
            // current appearance like a template image would.
            let glyphRect = NSRect(origin: .zero, size: glyph.size)
            glyph.draw(in: glyphRect)
            NSColor.labelColor.set()
            glyphRect.fill(using: .sourceAtop)
            let dotRect = NSRect(x: size.width - dot, y: size.height - dot, width: dot, height: dot)
            // Knock a thin gap out of the glyph around the dot.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            NSColor.controlAccentColor.set()
            NSBezierPath(ovalIn: dotRect).fill()
            return true
        }
        image.isTemplate = false
        return image
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
                        Text(String.localizedStringWithFormat(AppLocalization.string("New version %@"), version))
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
                    guard !reduceMotion else { return }
                    withAnimation(AetherVisual.animation(AetherVisual.attentionPulse)) {
                        isPulsing = true
                    }
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
    static let height: CGFloat = 30

    let member: String
    let isSelected: Bool
    let status: ProxyLatencyStatus
    let confidence: ProxyLatencyConfidence
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
                MenuNodeLatency(status: status, confidence: confidence)
            }
            .padding(.horizontal, AetherVisual.s2)
            .frame(height: Self.height)
            .background(
                isHovered && isEnabled ? AetherVisual.hoverFill : Color.clear,
                in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.aetherPressable)
        .onHover { isHovered = $0 }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
        .help(member)
        .accessibilityIdentifier("menu-node-\(member)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private enum MenuLiveTrafficMetricKind {
    case download
    case upload
    case connections
}

private struct MenuLiveTrafficMetric: View {
    let title: LocalizedStringKey
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
                Text(title)
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
            .aetherNumericValue(value)
    }

    private var value: String {
        switch metric {
        case .download:
            return formattedRate(telemetry.snapshot.downloadBytesPerSecond)
        case .upload:
            return formattedRate(telemetry.snapshot.uploadBytesPerSecond)
        case .connections:
            return String(telemetry.snapshot.connections.count)
        }
    }
}

/// Overview's live traffic graph at panel size: the same 30-second window
/// trailing the clock by one sampling period, samples placed by time, and
/// download and upload on one shared scale. Without the shared scale a small
/// upload filled its own sparkline and looked like a spike. It animates only
/// while the panel is open; closed, it rests on the last 30 seconds.
private struct MenuTrafficGraph: View {
    /// Like Overview's graph, the waveform is its own observing leaf, so a
    /// frame redraws this view and not the panel.
    @ObservedObject var model: NetworkTelemetryViewModel
    let isLive: Bool

    /// Half Overview's rate: smooth at this width, cheaper in the menu bar.
    private static let frameInterval: TimeInterval = 1.0 / 12
    private static let entryLag = TimeInterval(
        TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !isLive)) { context in
            let lastSample = model.history.samples.last?.date
            let now = isLive
                ? context.date.addingTimeInterval(-Self.entryLag)
                : (lastSample ?? context.date)
            let samples = model.history.visible(at: now)
            AetherTrafficMiniGraph(
                downloadSamples: samples.map(\.download),
                uploadSamples: samples.map(\.upload),
                samplePositions: samples.map { TrafficHistory.position(of: $0, at: now) },
                height: 36
            )
        }
        .accessibilityIdentifier("menu-traffic-graph")
    }
}

private struct MenuStaticTrafficValue: View {
    let metric: MenuLiveTrafficMetricKind
    let snapshot: NetworkTelemetrySnapshot

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
            return String(snapshot.connections.count)
        }
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
        case "network", "bypass": .network
        case "privacy", "diagnostics": .privacy
        case "about", "account", "licenses": .about
        default: nil
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .network: "Network"
        case .privacy: "Privacy & Diagnostics"
        case .about: "About"
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
    @EnvironmentObject private var startup: AppStartupController
    @State private var localProxyCopyMessage: String?
    @State private var selectedTab: SettingsTab?

    init() {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        let requestedTab = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_SETTINGS_TAB"
        ].flatMap(SettingsTab.resolve)
        _selectedTab = State(initialValue: requestedTab ?? .general)
#else
        _selectedTab = State(initialValue: .general)
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
                        Text(tab.title)
                            .font(.body.weight(.medium))
                            .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, AetherVisual.sMicro)
                    .contentShape(Rectangle())
                    }
                    // A plain button keeps keyboard focus off the list, so the
                    // selection stays the quiet gray the main window uses.
                    .buttonStyle(.plain)
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
        .onReceive(NotificationCenter.default.publisher(for: .aetherRouteNavigateToSettings)) { notification in
            if let raw = notification.object as? String, let tab = SettingsTab.resolve(raw) { selectedTab = tab }
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
                SupportDiagnosticsView(isEmbedded: true)
            }
            .aetherSettingsForm(title: SettingsTab.privacy.titleString)
            .environmentObject(tunnel)
        case .about:
            AboutAetherRouteView()
                .environmentObject(distribution)
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
    }

    private var networkSettings: some View {
        Form {
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
                            get: { tunnel.routingMode },
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

#if AETHERROUTE_INDEPENDENT
            localProxySection
#endif

            BypassRulesSection()
                .environmentObject(tunnel)
        }
        .aetherSettingsForm(title: SettingsTab.network.titleString)
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
            Text(AppLocalization.string("Dock & Menu Bar"))
        } footer: {
            Text(
                AppLocalization.string(
                    "Keep AetherRoute in the menu bar only without a Dock icon. The main window can be reopened from the menu bar or by clicking the app icon."
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
                Label(
                    AppLocalization.string(
                        "AetherRoute requires approval in System Settings > General > Login Items & Extensions."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            } else if let error = startup.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
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
            .disabled(
                tunnel.networkEngineMode != .tun
                    || !tunnel.canModifyLocalProxySettings
            )
            .accessibilityIdentifier("local-proxy-toggle")

            LabeledContent(AppLocalization.string("Mixed proxy (HTTP and SOCKS5)")) {
                LocalProxyPortField(
                    title: "HTTP proxy port",
                    port: tunnel.localProxySettings.httpPort,
                    identifier: "local-proxy-http-port",
                    commit: { tunnel.setLocalProxyHTTPPort($0) }
                )
            }
            .disabled(!canEditLocalProxyPorts)

            LabeledContent(AppLocalization.string("Additional SOCKS5-only port")) {
                LocalProxyPortField(
                    title: "SOCKS5 proxy port",
                    port: tunnel.localProxySettings.socksPort,
                    identifier: "local-proxy-socks-port",
                    commit: { tunnel.setLocalProxySOCKSPort($0) }
                )
            }
            .disabled(!canEditLocalProxyPorts)

            HStack {
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
                        LocalProxySettings.clearShellEnvironmentCommand
                    )
                    localProxyCopyMessage = AppLocalization.string(
                        "Clear command copied."
                    )
                    return true
                }
                .accessibilityIdentifier("copy-clear-proxy-button")

                Spacer(minLength: AetherVisual.s3)

                if let message = localProxyCopyMessage
                    ?? tunnel.localProxySettingsMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("local-proxy-status")
                }
            }

        } header: {
            Text(AppLocalization.string("Local proxy"))
        } footer: {
            Text(localProxyDetail)
        }
    }

    private var canEditLocalProxyPorts: Bool {
        tunnel.networkEngineMode == .tun
            && tunnel.localProxySettings.isEnabled
            && tunnel.canModifyLocalProxySettings
    }

    private var canCopyLocalProxyEnvironment: Bool {
        tunnel.networkEngineMode == .tun
            && tunnel.localProxySettings.isEnabled
    }

    private var localProxyDetail: String {
        if tunnel.networkEngineMode != .tun {
            return AppLocalization.string(
                "Switch to TUN to use the local proxy."
            )
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
                try tunnel.localProxySettings.shellEnvironmentCommand()
            )
            localProxyCopyMessage = AppLocalization.string(
                "Shell environment copied."
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
                        .foregroundStyle(shortcutStatusColor)
                }
                .font(.caption)
                .accessibilityIdentifier("global-shortcut-status")
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

            Label(notificationStatusText, systemImage: notificationStatusSymbol)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)

        } header: {
            Text(AppLocalization.string("Automation"))
        } footer: {
            Text(AppLocalization.string("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details."))
                .accessibilityHidden(true)
        }
    }

    private func shortcutPicker(
        _ title: LocalizedStringKey,
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
            String.localizedStringWithFormat(
                AppLocalization.string("%@ is already used by another app"),
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

    private var shortcutStatusColor: Color {
        switch automation.shortcutState {
        case .disabled: .secondary
        case .active: Color.green
        case .conflict: .orange
        }
    }

    private var notificationStatusText: String {
        switch automation.notificationPermission {
        case .notRequested:
            AppLocalization.string("macOS will ask only when you turn notifications on")
        case .authorized:
            automation.notificationsEnabled
                ? AppLocalization.string("Failure and unexpected disconnect alerts are on")
                : AppLocalization.string("Notification permission is available")
        case .denied:
            AppLocalization.string("Notifications are disabled in System Settings")
        case .unavailable:
            AppLocalization.string("Notification status is unavailable")
        }
    }

    private var notificationStatusSymbol: String {
        switch automation.notificationPermission {
        case .authorized where automation.notificationsEnabled: "bell.badge.fill"
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

    let title: LocalizedStringKey
    let action: GlobalShortcutAction

    var body: some View {
        LabeledContent {
            Button {
                isPresentingChoices = true
            } label: {
                HStack(spacing: AetherVisual.s2) {
                    Text(selection.displayTitle)
                        .monospaced()
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .aetherGlassButton()
            .accessibilityLabel(title)
            .accessibilityValue(selection.displayTitle)
            .popover(isPresented: $isPresentingChoices, arrowEdge: .trailing) {
                shortcutChoices
            }
        } label: {
            Text(title)
        }
    }

    private var selection: GlobalShortcutKey {
        automation.shortcutPreferences[action]
    }

    private var shortcutChoices: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, AetherVisual.s3)
                .padding(.top, AetherVisual.s2)

            Divider()

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
        .padding(AetherVisual.s2)
        .frame(width: 230)
    }
}

/// A loopback port typed in full. A stepper needed thousands of clicks to
/// move between common ports such as 7890 and 1080. The value is committed on
/// Return or when focus leaves; TunnelManager validates it and reports a bad
/// port, and the field then shows the port actually in effect.
private struct LocalProxyPortField: View {
    let title: LocalizedStringKey
    let port: Int
    let identifier: String
    let commit: (Int) -> Void

    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AetherVisual.s1) {
            Text(verbatim: "127.0.0.1:")
                .monospacedDigit()
                .foregroundStyle(AetherVisual.secondaryText)
            TextField(title, text: $text)
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
        guard let value = Int(trimmed), value != port else {
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

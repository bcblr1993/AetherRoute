import AppKit
import AetherRouteKit
import Darwin
import OSLog
import SwiftUI

@MainActor
final class AetherRouteApplicationDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSUserInterfaceValidations {
    private static let lifecycleLogger = AppLog.logger(category: AppLog.Category.appLifecycle)

    weak var tunnel: TunnelManager?
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
        AppWindowManager.shared.showMainWindow()
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
            Image(systemName: menuBarIcon)
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

                Divider()

                Button(AppLocalization.string("Check for Updates…")) {
                    SparkleUpdaterController.shared.checkForUpdates()
                }
                .keyboardShortcut("u", modifiers: [.command, .shift])
            }
            CommandMenu("Navigate") {
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
                Button("Previous proxy node") {
                    Task {
                        await tunnel.cycleManualProxySelection(.previous)
                    }
                }
                .keyboardShortcut(
                    .leftArrow,
                    modifiers: [.command, .option]
                )
                .disabled(!tunnel.canCycleManualProxySelection)

                Button("Next proxy node") {
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
                Button("Copy Terminal Export Command") {
                    let command = "export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .keyboardShortcut("c", modifiers: [.command, .control])

                Button("Copy Terminal Unset Command") {
                    let command = "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
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
        "\(productDisplayName) · \(tunnel.statusTitle)"
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
            onVisibilityChanged?(false)
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
            onVisibilityChanged?(false)
            return
        }
        let isVisible = window.isVisible && window.occlusionState.contains(.visible)
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
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var showingNodes = false
    @State private var isMenuVisible = false
    @State private var copiedTerminalCommand: Bool = false
    @State private var clearedTerminalCommand: Bool = false
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(spacing: 0) {
            if tunnel.hasAcceptedPrivacyDisclosure {
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
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                Rectangle().fill(.regularMaterial)
            }
        }
        .onChange(of: tunnel.activeProfile?.yaml) { _, _ in showingNodes = false }
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

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. 顶部品牌与连接状态指示
            HStack(spacing: AetherVisual.s3) {
                AetherRouteBrandTile(size: 28, isActive: tunnel.isConnected)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    HStack(spacing: AetherVisual.sCompact) {
                        Text("AetherRoute")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.primary)

                        AetherStatusBeacon(
                            isConnected: tunnel.isConnected,
                            isConnecting: tunnel.state == .connecting,
                            size: 6
                        )
                    }

                    Text(tunnel.isSwitchingNetworkEngine ? tunnel.statusTitle : (tunnel.isConnected ? AppLocalization.string("Tunnel Protected") : tunnel.statusTitle))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tunnel.isConnected ? Color.green : Color.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.top, AetherVisual.sRow)
            .padding(.bottom, AetherVisual.sRow)

            Divider()

            if tunnel.isConnected {
                HStack(spacing: AetherVisual.s3) {
                    MenuLiveTrafficMetric(title: "Download", symbol: "arrow.down", metric: .download, telemetry: telemetry, isLive: isMenuVisible)
                    MenuLiveTrafficMetric(title: "Upload", symbol: "arrow.up", metric: .upload, telemetry: telemetry, isLive: isMenuVisible)
                    MenuLiveTrafficMetric(title: "Connections", symbol: "point.3.connected.trianglepath.dotted", metric: .connections, telemetry: telemetry, isLive: isMenuVisible)
                }
                .padding(AetherVisual.s4)
                Divider()
            }

            // 3. 核心控制与节点选择
            VStack(spacing: AetherVisual.s3) {
#if AETHERROUTE_INDEPENDENT
                HStack(spacing: AetherVisual.s2) {
                    Text(AppLocalization.string("Engine"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Picker("Network engine", selection: networkEngineBinding) {
                        ForEach(NetworkEngineMode.allCases) { mode in
                            Text(mode.localizedTitleKey).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    .controlSize(.regular)
                    .disabled(!tunnel.canChangeNetworkEngine)
                }
#endif

                HStack(spacing: AetherVisual.s2) {
                    Text(AppLocalization.string("Routing"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 52, alignment: .leading)
                    Picker(
                        "Routing",
                        selection: Binding(
                            get: { tunnel.routingMode },
                            set: { mode in
                                Task { await tunnel.setRoutingMode(mode) }
                            }
                        )
                    ) {
                        ForEach(RoutingMode.allCases, id: \.self) { mode in
                            Text(mode.localizedTitleKey).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: .infinity)
                    .controlSize(.regular)
                    .disabled(!tunnel.canChangeRoutingMode)
                }


                if let group = primaryGroup {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack(spacing: AetherVisual.s2) {
                            Text(verbatim: group.name.isEmpty ? AppLocalization.string("Current Node") : group.name)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            if !group.strategy.isEmpty {
                                Text(verbatim: group.strategy.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(Color.accentColor)
                                    .padding(.horizontal, AetherVisual.sCompact)
                                    .padding(.vertical, AetherVisual.sMicro)
                                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                            }

                            Spacer()

                            let isTesting = tunnel.proxyLatencyRequests.contains(group.name)
                            Button {
                                Task { await tunnel.testProxyLatency(group: group.name) }
                            } label: {
                                HStack(spacing: AetherVisual.sMicro) {
                                    if isTesting {
                                        ProgressView()
                                            .controlSize(.mini)
                                    } else {
                                        Image(systemName: "bolt.fill")
                                            .font(.caption2)
                                    }
                                    Text(isTesting ? AppLocalization.string("Testing") : AppLocalization.string("Test all"))
                                        .font(.caption2.weight(.medium))
                                }
                                .foregroundStyle(isTesting ? Color.secondary : Color.primary)
                                .padding(.horizontal, AetherVisual.sCompact)
                                .padding(.vertical, AetherVisual.sMicro)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .disabled(isTesting)
                            .help(AppLocalization.string("Test all"))
                            .accessibilityIdentifier("menu-proxy-speedtest-button")
                        }
                        Button {
                            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                                showingNodes.toggle()
                            }
                        } label: {
                            HStack(spacing: AetherVisual.s2) {
                                let member = tunnel.proxySelections[group.name]?.selectedMember
                                Text(verbatim: AetherRegionFlag.flagAndRegion(from: member ?? "").flag)
                                Text(verbatim: member ?? AppLocalization.string("Select Node"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let member {
                                    MenuNodeLatency(
                                        status: ProxyLatencyStatus.status(
                                            member: member,
                                            results: tunnel.proxyLatencies[group.name]?.results,
                                            isTesting: tunnel.proxyLatencyRequests.contains(group.name)
                                        ),
                                        confidence: tunnel.latencyConfidence(
                                            group: group.name,
                                            member: member
                                        )
                                    )
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(showingNodes ? 90 : 0))
                            }
                            .padding(AetherVisual.s3)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(tunnel.proxySelections[group.name]?.selectedMember ?? AppLocalization.string("Select Node"))
                        .accessibilityIdentifier("menu-proxy-node-selector")
                        .task(id: "\(group.name):\(tunnel.isConnected)") {
                            await tunnel.refreshProxySelection(group: group.name)
                        }

                        if showingNodes {
                            MenuNodeListInline(group: group) {
                                withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                                    showingNodes = false
                                }
                            }
                            .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                    }
                }

                HStack(spacing: AetherVisual.s2) {
                    Button {
                        let command = (try? tunnel.localProxySettings.shellEnvironmentCommand())
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
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copiedTerminalCommand = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            copiedTerminalCommand = false
                        }
                    } label: {
                        HStack(spacing: AetherVisual.s1) {
                            Image(systemName: copiedTerminalCommand ? "checkmark.circle.fill" : "terminal")
                                .foregroundStyle(copiedTerminalCommand ? Color.green : Color.primary)
                            Text(copiedTerminalCommand ? AppLocalization.string("Copied") : AppLocalization.string("Copy Proxy Command"))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(AppLocalization.string("Copy terminal export command to clipboard"))
                    .accessibilityIdentifier("copy-terminal-proxy-button")

                    Button {
                        let command = LocalProxySettings.clearShellEnvironmentCommand
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        clearedTerminalCommand = true
                        Task {
                            try? await Task.sleep(nanoseconds: 2_000_000_000)
                            clearedTerminalCommand = false
                        }
                    } label: {
                        HStack(spacing: AetherVisual.s1) {
                            Image(systemName: clearedTerminalCommand ? "checkmark.circle.fill" : "terminal.fill")
                                .foregroundStyle(clearedTerminalCommand ? Color.green : Color.primary)
                            Text(clearedTerminalCommand ? AppLocalization.string("Copied") : AppLocalization.string("Copy Clear Command"))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help(AppLocalization.string("Copy terminal unset command to clipboard"))
                    .accessibilityIdentifier("clear-terminal-proxy-button")
                }

                Button {
                    Task { await tunnel.setEnabled(!tunnel.isEnabled) }
                } label: {
                    Label(tunnel.primaryActionTitle, systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.borderedProminent)
                .disabled(!tunnel.canPerformPrimaryAction)
            }
            .padding(AetherVisual.s4)

            Divider()

            HStack(spacing: AetherVisual.s3) {
                Button(AppLocalization.string("Open AetherRoute")) {
                    AppWindowManager.shared.showMainWindow()
                }
                Spacer()
                Button {
                    SparkleUpdaterController.shared.checkForUpdates()
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderless)
                .help(AppLocalization.string("Check for Updates…"))
                .disabled(!SparkleUpdaterController.shared.canCheckForUpdates)

                Button(AppLocalization.string("Quit")) { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.sRow)
        }
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
                    Text("Privacy review required")
                        .font(.headline)
                    Text("Connection controls are locked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(AetherVisual.s4)

            Divider()

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                Text("Review how profiles, network traffic, and DNS requests are handled before AetherRoute creates a network extension configuration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    openMainWindow()
                } label: {
                    Label("Review Network Privacy", systemImage: "lock.shield")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("menu-privacy-review-button")
            }
            .padding(AetherVisual.s4)

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
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
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
        }
        .help(status.isMeasured ? confidence.localizedHint : title)
    }

    private var title: String {
        switch status {
        case .responded(let milliseconds): "\(milliseconds) ms"
        case .testing: AppLocalization.string("Testing latency…")
        case .untested: AppLocalization.string("Untested")
        case .timedOut: AppLocalization.string("Unavailable")
        }
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
            if orderedMembers.count > 4 {
                HStack(spacing: AetherVisual.s1) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    TextField(AppLocalization.string("Search nodes"), text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .accessibilityIdentifier("menu-node-search-field")
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, AetherVisual.s2)
                .padding(.vertical, AetherVisual.sCompact)
                .background(
                    Color.secondary.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                )
            }

            if orderedMembers.isEmpty {
                Text(AppLocalization.string("No nodes available"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, AetherVisual.s2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else if filteredMembers.isEmpty {
                Text(AppLocalization.string("No matching nodes"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, AetherVisual.s2)
                    .frame(maxWidth: .infinity, alignment: .center)
            } else {
                ScrollView {
                    LazyVStack(spacing: AetherVisual.s1) {
                        ForEach(filteredMembers, id: \.self) { member in
                            Button {
                                if member == selectedMember {
                                    onClose()
                                    return
                                }
                                selecting = true
                                Task {
                                    await tunnel.selectProxy(group: group.name, member: member)
                                    selecting = false
                                }
                            } label: {
                                HStack(spacing: AetherVisual.s2) {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(Color.accentColor)
                                        .opacity(member == selectedMember ? 1 : 0)
                                        .frame(width: 14)
                                    Text(verbatim: AetherRegionFlag.flagAndRegion(from: member).flag)
                                    Text(verbatim: member)
                                        .font(.caption)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    MenuNodeLatency(
                                        status: status(for: member),
                                        confidence: tunnel.latencyConfidence(
                                            group: group.name,
                                            member: member
                                        )
                                    )
                                }
                                .padding(.horizontal, AetherVisual.s2)
                                .padding(.vertical, AetherVisual.sCompact)
                                .background(
                                    member == selectedMember ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04),
                                    in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                                )
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(member)
                            .accessibilityIdentifier("menu-node-\(member)")
                            .accessibilityAddTraits(member == selectedMember ? .isSelected : [])
                            .disabled(selecting || tunnel.proxySelectionRequests.contains(group.name)
                                || group.strategy.lowercased() != "select" || unsupported.contains(member))
                        }
                    }
                    .padding(AetherVisual.s1)
                }
                .frame(height: min(CGFloat(max(filteredMembers.count, 1)) * 36, 216))
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.4),
                    in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
            }
            if group.strategy.lowercased() != "select" {
                Text("This group is automatically managed by latency tests.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if let message = tunnel.proxySelectionMessages[group.name] {
                Text(verbatim: message)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

private enum MenuLiveTrafficMetricKind {
    case download
    case upload
    case connections
}

private struct MenuLiveTrafficMetric: View {
    let title: LocalizedStringKey
    let symbol: String
    let metric: MenuLiveTrafficMetricKind
    let telemetry: NetworkTelemetryViewModel
    var isLive: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
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


private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case privacy
    case bypass
    case diagnostics
    case account
    case licenses
    case about

    var id: Self { self }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .privacy: "Privacy"
        case .bypass: "Bypass"
        case .diagnostics: "Diagnostics"
        case .account: "Account"
        case .licenses: "Licenses"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .privacy: "hand.raised"
        case .bypass: "arrow.trianglehead.branch"
        case .diagnostics: "stethoscope"
        case .account: "person.crop.circle"
        case .licenses: "doc.text.magnifyingglass"
        case .about: "info.circle"
        }
    }
}

private struct SettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
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
        ].flatMap(SettingsTab.init(rawValue:))
        _selectedTab = State(initialValue: requestedTab ?? .general)
#else
        _selectedTab = State(initialValue: .general)
#endif
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedTab) {
                ForEach(SettingsTab.allCases) { tab in
                    Label(tab.title, systemImage: tab.symbol)
                        .font(.system(size: 14, weight: .semibold))
                        .tag(Optional(tab))
                        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
                }
            }
            .listStyle(.sidebar)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("settings-sidebar-list")
            .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 216)
            .background(settingsSidebarBackground)
            .accessibilityLabel("Settings navigation")
            .accessibilityIdentifier("aetherroute-settings-navigation")
        } detail: {
            selectedSettings
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("AetherRoute settings")
                .accessibilityIdentifier("aetherroute-settings-detail")
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
        .accessibilityLabel("AetherRoute settings")
        .accessibilityIdentifier("aetherroute-settings-root")
        .frame(width: 960, height: 640)
        .onChange(of: selectedTab) { _, tab in
            guard let tab else { return }
            UIResponsivenessProbe.begin("settings.\(tab.rawValue)")
        }
        .id(language.preference)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topLeading) {
            WindowChromeSynchronizer(
                title: AppLocalization.string("AetherRoute settings"),
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
        case .privacy:
            PrivacyDisclosureView(isOnboarding: false)
                .environmentObject(tunnel)
        case .bypass:
            BypassRulesView()
                .environmentObject(tunnel)
        case .diagnostics:
            SupportDiagnosticsView()
                .environmentObject(tunnel)
        case .account:
            IndependentDistributionView()
                .environmentObject(distribution)
        case .licenses:
            ThirdPartyLicensesView()
        case .about:
            AboutAetherRouteView()
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

    private var settingsSidebarBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    private var generalSettings: some View {
        Form {
            appearanceSettings
            dockSettings
            startupSettings
            languageSettings

#if AETHERROUTE_INDEPENDENT
            Section("Network engine") {
                HStack(spacing: AetherVisual.s3) {
                    Text("Traffic capture")
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Picker("", selection: networkEngineBinding) {
                        ForEach(NetworkEngineMode.allCases) { mode in
                            Text(mode.localizedTitleKey).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Traffic capture"))
                    .disabled(!tunnel.canChangeNetworkEngine)
                }

                Text(tunnel.networkEngineMode.localizedDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
#endif

            Section("Routing") {
                HStack(spacing: AetherVisual.s3) {
                    Text("Default routing mode")
                        .foregroundStyle(.primary)

                    Spacer(minLength: 12)

                    Picker(
                        "",
                        selection: Binding(
                            get: { tunnel.routingMode },
                            set: { mode in
                                Task { await tunnel.setRoutingMode(mode) }
                            }
                        )
                    ) {
                        ForEach(RoutingMode.allCases, id: \.self) { mode in
                            Text(mode.localizedTitleKey).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .accessibilityLabel(Text("Default routing mode"))
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

                Text(
                    AppLocalization.string(
                        "Injects high-speed direct routing and domestic DNS policy for Apple CDN, updates, and domestic websites."
                    )
                )
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

#if AETHERROUTE_INDEPENDENT
            localProxySection
#endif

            automationSettings

            if !tunnel.hasAcceptedPrivacyDisclosure {
                Section {
                    Label(
                        "Network settings remain locked until the privacy disclosure is accepted.",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .contentMargins(.horizontal, 20, for: .scrollContent)
        .contentMargins(.vertical, 16, for: .scrollContent)
        .contentMargins(.trailing, 10, for: .scrollIndicators)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var appearanceSettings: some View {
        Section("Appearance") {
            Picker("Application theme", selection: Binding(
                get: { appearance.preference },
                set: { appearance.select($0) }
            )) {
                Text("Follow System").tag(AppAppearancePreference.system)
                Text("Light").tag(AppAppearancePreference.light)
                Text("Dark").tag(AppAppearancePreference.dark)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("app-appearance-picker")

            Text("Theme changes apply immediately and are remembered next time.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dockSettings: some View {
        Section(AppLocalization.string("Dock & Menu Bar")) {
            Toggle(
                AppLocalization.string("Hide Dock icon"),
                isOn: Binding(
                    get: { dockVisibility.isDockIconHidden },
                    set: { dockVisibility.setDockIconHidden($0) }
                )
            )
            .accessibilityIdentifier("hide-dock-icon-toggle")

            Text(
                AppLocalization.string(
                    "Keep AetherRoute in the menu bar only without a Dock icon. The main window can be reopened from the menu bar or by clicking the app icon."
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var startupSettings: some View {
        Section(AppLocalization.string("Startup")) {
            Toggle(
                AppLocalization.string("Launch at login"),
                isOn: Binding(
                    get: { startup.isLaunchAtLoginEnabled },
                    set: { startup.setLaunchAtLoginEnabled($0) }
                )
            )
            .accessibilityIdentifier("launch-at-login-toggle")

            Text(
                AppLocalization.string(
                    "Automatically start AetherRoute when logging into macOS. If connected before quitting, it will automatically reconnect upon launch."
                )
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if startup.serviceStatus == .requiresApproval {
                Label(
                    AppLocalization.string(
                        "AetherRoute requires approval in System Settings > General > Login Items & Extensions."
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.yellow)
            } else if let error = startup.errorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var languageSettings: some View {
        Section("Language") {
            Picker("Application language", selection: languageBinding) {
                Text("Follow System")
                    .tag(AppLanguagePreference.system)
                Text(verbatim: "简体中文")
                    .tag(AppLanguagePreference.simplifiedChinese)
                Text(verbatim: "English")
                    .tag(AppLanguagePreference.english)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("app-language-picker")

            Label(
                "Language changes apply immediately throughout AetherRoute.",
                systemImage: "globe"
            )
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
        Section("Local proxy") {
            Toggle(
                "Loopback HTTP and SOCKS5 proxy",
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

            LabeledContent("Mixed proxy (HTTP and SOCKS5)") {
                HStack(spacing: AetherVisual.s3) {
                    Text(
                        verbatim:
                            "127.0.0.1:\(tunnel.localProxySettings.httpPort)"
                    )
                    .monospacedDigit()
                    Stepper(
                        "HTTP proxy port",
                        value: Binding(
                            get: { tunnel.localProxySettings.httpPort },
                            set: { tunnel.setLocalProxyHTTPPort($0) }
                        ),
                        in: LocalProxySettings.permittedPorts
                    )
                    .labelsHidden()
                }
            }
            .disabled(!canEditLocalProxyPorts)

            LabeledContent("Additional SOCKS5-only port") {
                HStack(spacing: AetherVisual.s3) {
                    Text(
                        verbatim:
                            "127.0.0.1:\(tunnel.localProxySettings.socksPort)"
                    )
                    .monospacedDigit()
                    Stepper(
                        "SOCKS5 proxy port",
                        value: Binding(
                            get: { tunnel.localProxySettings.socksPort },
                            set: { tunnel.setLocalProxySOCKSPort($0) }
                        ),
                        in: LocalProxySettings.permittedPorts
                    )
                    .labelsHidden()
                }
            }
            .disabled(!canEditLocalProxyPorts)

            HStack {
                Button("Copy Shell Environment", systemImage: "terminal") {
                    copyLocalProxyShellEnvironment()
                }
                .disabled(!canCopyLocalProxyEnvironment)
                .accessibilityIdentifier("copy-shell-proxy-button")

                Button("Copy Clear Command", systemImage: "xmark.circle") {
                    copyToPasteboard(
                        LocalProxySettings.clearShellEnvironmentCommand
                    )
                    localProxyCopyMessage = AppLocalization.string(
                        "Clear command copied."
                    )
                }
                .accessibilityIdentifier("copy-clear-proxy-button")

                Spacer(minLength: 12)

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

            Label(localProxyDetail, systemImage: localProxyDetailSymbol)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

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
        return AppLocalization.string(
            "AetherRoute binds only 127.0.0.1 and never changes the macOS system proxy. Shell commands affect only the terminal where you paste them."
        )
    }

    private var localProxyDetailSymbol: String {
        tunnel.networkEngineMode == .tun
            ? "lock.shield"
            : "arrow.triangle.swap"
    }

    private func copyLocalProxyShellEnvironment() {
        do {
            copyToPasteboard(
                try tunnel.localProxySettings.shellEnvironmentCommand()
            )
            localProxyCopyMessage = AppLocalization.string(
                "Shell environment copied."
            )
        } catch {
            localProxyCopyMessage = error.localizedDescription
        }
    }

    private func copyToPasteboard(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
#endif

    private var automationSettings: some View {
        Section("Automation") {
            Toggle(
                "Global shortcuts",
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
                Text("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details.")
            )

            if automation.shortcutPreferences.isEnabled {
                shortcutPicker("Connect or disconnect", action: .toggleConnection)
                shortcutPicker("Rule mode", action: .routingRule)
                shortcutPicker("Global mode", action: .routingGlobal)
                shortcutPicker("Direct mode", action: .routingDirect)

                Label {
                    Text(shortcutStatusText)
                        .foregroundStyle(.secondary)
                } icon: {
                    Image(systemName: shortcutStatusSymbol)
                        .foregroundStyle(shortcutStatusColor)
                }
                .font(.caption)
                .accessibilityIdentifier("global-shortcut-status")
            }

            Toggle(
                "Connection notifications",
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
                Text("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details.")
            )

            Label(notificationStatusText, systemImage: notificationStatusSymbol)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
            .buttonStyle(.bordered)
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

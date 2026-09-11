import AppKit
import AetherRouteKit
import Darwin
import OSLog
import SwiftUI

@MainActor
final class AetherRouteApplicationDelegate: NSObject, NSApplicationDelegate {
    private static let lifecycleLogger = Logger(
        subsystem: "com.aetherroute.desktop",
        category: "host-lifecycle"
    )

    weak var tunnel: TunnelManager?
    private var terminationReplyPending = false
    private var signalTerminationPending = false
    private var terminationSignalSource: (any DispatchSourceSignal)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installTerminationSignalSource()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            tunnel?.handleExternalURL(url)
        }
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
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
            sender?.reply(toApplicationShouldTerminate: disconnected)
        }
        return .terminateLater
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

    func makeNSView(context: Context) -> WindowChromeView {
        let view = WindowChromeView()
        view.update(title: title, showsTitle: showsTitle)
        return view
    }

    func updateNSView(_ nsView: WindowChromeView, context: Context) {
        nsView.update(title: title, showsTitle: showsTitle)
    }
}

final class WindowChromeView: NSView {
    private static let automaticSidebarToggleIdentifier =
        "com.apple.SwiftUI.navigationSplitView.toggleSidebar"

    private var expectedTitle = ""
    private var showsWindowTitle = true
    private weak var observedWindow: NSWindow?
    private let visibilityCoordinator = WindowVisibilityCoordinator()

    func update(title: String, showsTitle: Bool) {
        expectedTitle = title
        showsWindowTitle = showsTitle
        applyWindowChrome()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        observedWindow = window
        visibilityCoordinator.observe(window)
        window?.addObserver(
            self,
            forKeyPath: "title",
            options: [.new],
            context: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidUpdate(_:)),
            name: NSWindow.didUpdateNotification,
            object: window
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
    private func windowDidUpdate(_ notification: Notification) {
        applyWindowChrome()
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
        window.titlebarAppearsTransparent = true
        window.titleVisibility = showsWindowTitle ? .visible : .hidden

        guard let toolbar = window.toolbar else { return }
        toolbar.isVisible = false
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
    @StateObject private var tunnel: TunnelManager
    @StateObject private var automation: AppAutomationController
    @StateObject private var distribution:
        IndependentDistributionController
    @StateObject private var runtimeEnvironment:
        AppRuntimeEnvironmentController

    init() {
        NavigationShortcutMonitor.install()
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
            // Icon only. The symbol is a template image, so state is carried by
            // its shape rather than by colour or by an adjacent title.
            Image(systemName: menuBarIcon)
                .accessibilityLabel(menuBarAccessibilityLabel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(tunnel)
                .environmentObject(automation)
                .environmentObject(distribution)
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }
        .windowToolbarStyle(.unifiedCompact(showsTitle: true))
    }

    private var mainWindow: some Scene {
        WindowGroup(productDisplayName, id: "main") {
            ContentView()
                .environmentObject(tunnel)
                .environmentObject(runtimeEnvironment)
                .environmentObject(language)
                .environment(\.locale, language.locale)
        }
        .defaultSize(
            width: AetherVisual.windowWidth,
            height: AetherVisual.windowHeight
        )
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommandButton()
            }
            CommandMenu(AppLocalization.string("Tunnel")) {
                Button(tunnel.isConnected ? AppLocalization.string("Disconnect") : AppLocalization.string("Connect")) {
                    Task {
                        await tunnel.setEnabled(!tunnel.isConnected)
                    }
                }
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
        tunnel.isConnected ? "network.badge.shield.half.filled" : "network"
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

private struct MenuBarContent: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var language: AppLanguageController
    @Environment(\.openWindow) private var openWindow
    @State private var copiedTerminalCommand: Bool = false
    @State private var clearedTerminalCommand: Bool = false
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        Group {
            if tunnel.hasAcceptedPrivacyDisclosure {
                readyContent
                    .task { await tunnel.prepare() }
            } else {
                privacyRequiredContent
            }
        }
        .frame(width: AetherVisual.popoverWidth)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. 顶部品牌与连接状态指示
            HStack(spacing: AetherVisual.s3) {
                AetherRouteBrandTile(size: 32, isActive: tunnel.isConnected)

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

                    Text(tunnel.isConnected ? AppLocalization.string("Tunnel Protected") : tunnel.statusTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(tunnel.isConnected ? Color.green : Color.secondary)
                        .lineLimit(1)
                }
                Spacer()

                // 快捷主开关
                Button {
                    Task { await tunnel.setEnabled(!tunnel.isEnabled) }
                } label: {
                    Image(systemName: "power")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(tunnel.isConnected ? Color.green : Color.secondary)
                        .padding(AetherVisual.sCompact)
                        .background(
                            (tunnel.isConnected ? Color.green.opacity(0.15) : Color.secondary.opacity(0.12)),
                            in: Circle()
                        )
                }
                .buttonStyle(.plain)
                .disabled(!tunnel.canPerformPrimaryAction)
                .help(tunnel.primaryActionTitle)
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.top, AetherVisual.sRow)
            .padding(.bottom, AetherVisual.sRow)

            Divider().opacity(0.4)

            // 2. 实时速率双胶囊
            if tunnel.isConnected {
                HStack(spacing: AetherVisual.s2) {
                    // 下行
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.cyan)
                        Text(formatSpeed(telemetry.snapshot.downloadBytesPerSecond))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, AetherVisual.s2)
                    .padding(.vertical, AetherVisual.s1)
                    .background(Color.cyan.opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius))

                    // 上行
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.purple)
                        Text(formatSpeed(telemetry.snapshot.uploadBytesPerSecond))
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, AetherVisual.s2)
                    .padding(.vertical, AetherVisual.s1)
                    .background(Color.purple.opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius))

                    Spacer()

                    // 连接数
                    HStack(spacing: AetherVisual.sMicro) {
                        Image(systemName: "point.3.connected.trianglepath.dotted")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                        Text(verbatim: "\(telemetry.snapshot.connections.count)")
                            .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.sRow)

                Divider().opacity(0.4)
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
                    .controlSize(.small)
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
                    .controlSize(.small)
                    .disabled(!tunnel.canChangeRoutingMode)
                }

                if let summary = tunnel.activeProfileSummary,
                   let primaryGroup = summary.proxyGroups.first(where: { $0.strategy.lowercased() == "select" }) ?? summary.proxyGroups.first {
                    let currentMember = tunnel.proxySelections[primaryGroup.name]?.selectedMember ?? "Auto"
                    let flagInfo = AetherRegionFlag.flagAndRegion(from: currentMember)

                    HStack(spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Node"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .leading)

                        Menu {
                            let displayMembers = Array(primaryGroup.members.prefix(16))
                            ForEach(displayMembers, id: \.self) { member in
                                Button {
                                    Task { await tunnel.selectProxy(group: primaryGroup.name, member: member) }
                                } label: {
                                    let itemFlag = AetherRegionFlag.flagAndRegion(from: member)
                                    if member == currentMember {
                                        Label(title: { Text(verbatim: "\(itemFlag.flag) \(member)") }, icon: { Image(systemName: "checkmark") })
                                    } else {
                                        Text(verbatim: "\(itemFlag.flag) \(member)")
                                    }
                                }
                            }
                            if primaryGroup.members.count > 16 {
                                Divider()
                                Text(verbatim: "+\(primaryGroup.members.count - 16) more nodes")
                            }
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Text(flagInfo.flag)
                                    .font(.system(size: 12))
                                Text(currentMember)
                                    .font(.system(size: 11.5, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, AetherVisual.s2)
                            .padding(.vertical, AetherVisual.s1)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius))
                        }
                        .menuStyle(.borderlessButton)
                    }
                }

                HStack(spacing: AetherVisual.s2) {
                    Button {
                        let command = "export https_proxy=http://127.0.0.1:7890 http_proxy=http://127.0.0.1:7890 all_proxy=socks5://127.0.0.1:7890"
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
                            Text(copiedTerminalCommand ? AppLocalization.string("Copied") : AppLocalization.string("Copy Proxy"))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("copy-terminal-proxy-button")

                    Button {
                        let command = "unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY"
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
                            Text(clearedTerminalCommand ? AppLocalization.string("Cleared") : AppLocalization.string("Clear Proxy"))
                                .lineLimit(1)
                        }
                        .font(.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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

            Divider().opacity(0.4)

            HStack(spacing: AetherVisual.s3) {
                Button(AppLocalization.string("Open AetherRoute")) {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
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

    private func formatSpeed(_ bytesPerSecond: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .memory
        return "\(formatter.string(fromByteCount: Int64(bytesPerSecond)))/s"
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
        openWindow(id: "main")
        NSApplication.shared.activate()
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

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            MenuLiveTrafficValue(metric: metric, telemetry: telemetry)
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
                        .foregroundStyle(.secondary)
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

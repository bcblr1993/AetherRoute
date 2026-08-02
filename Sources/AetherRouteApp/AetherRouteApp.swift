import AppKit
import AetherRouteKit
import SwiftUI

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

    func update(title: String, showsTitle: Bool) {
        expectedTitle = title
        showsWindowTitle = showsTitle
        applyWindowChrome()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindow()
        observedWindow = window
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
        NotificationCenter.default.removeObserver(self)
        observedWindow?.removeObserver(
            self,
            forKeyPath: "title"
        )
        observedWindow = nil
    }
}

@main
struct AetherRouteApp: App {
    @StateObject private var language: AppLanguageController
    @StateObject private var tunnel: TunnelManager
    @StateObject private var automation: AppAutomationController
    @StateObject private var distribution:
        IndependentDistributionController
    @StateObject private var runtimeEnvironment:
        AppRuntimeEnvironmentController

    init() {
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
    }

    var body: some Scene {
        mainWindow

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(tunnel)
                .environmentObject(language)
                .environment(\.locale, language.locale)
        } label: {
            Label(menuBarTitle, systemImage: menuBarIcon)
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
        .defaultSize(width: 940, height: 640)
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unifiedCompact(showsTitle: false))
    }

    private var menuBarIcon: String {
        tunnel.isConnected ? "network.badge.shield.half.filled" : "network"
    }

    private var menuBarTitle: String {
        guard tunnel.isConnected else { return productDisplayName }
        return "↓ \(compactRate(tunnel.telemetry.downloadBytesPerSecond))  ↑ \(compactRate(tunnel.telemetry.uploadBytesPerSecond))"
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

    var body: some View {
        Group {
            if tunnel.hasAcceptedPrivacyDisclosure {
                readyContent
                    .task { await tunnel.prepare() }
            } else {
                privacyRequiredContent
            }
        }
        .frame(width: 330)
    }

    private var readyContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AetherRouteBrandTile(
                    size: 38,
                    isActive: tunnel.isConnected
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(tunnel.statusTitle)
                        .font(.headline)
                    Text(tunnel.statusDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if tunnel.isConnected {
                HStack(spacing: 16) {
                    MenuTrafficMetric(
                        title: "Download",
                        value: formattedRate(
                            tunnel.telemetry.downloadBytesPerSecond
                        ),
                        symbol: "arrow.down"
                    )
                    MenuTrafficMetric(
                        title: "Upload",
                        value: formattedRate(
                            tunnel.telemetry.uploadBytesPerSecond
                        ),
                        symbol: "arrow.up"
                    )
                    MenuTrafficMetric(
                        title: "Flows",
                        value: "\(tunnel.telemetry.connections.count)",
                        symbol: "point.3.connected.trianglepath.dotted"
                    )
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)

                Divider()
            }

            VStack(spacing: 12) {
#if AETHERROUTE_INDEPENDENT
                Picker("Network engine", selection: networkEngineBinding) {
                    ForEach(NetworkEngineMode.allCases) { mode in
                        Text(mode.localizedTitleKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .foregroundStyle(Color(nsColor: .labelColor))
                .disabled(!tunnel.canChangeNetworkEngine)
#endif

                Picker("Routing", selection: $tunnel.routingMode) {
                    ForEach(RoutingMode.allCases, id: \.self) { mode in
                        Text(mode.localizedTitleKey).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!tunnel.canChangeRoutingMode)

                Button {
                    Task { await tunnel.setEnabled(!tunnel.isEnabled) }
                } label: {
                    Label(tunnel.primaryActionTitle, systemImage: "power")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .disabled(!tunnel.canPerformPrimaryAction)
            }
            .padding(16)

            Divider()

            HStack {
                Button("Open AetherRoute") {
                    openWindow(id: "main")
                    NSApplication.shared.activate()
                }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(14)
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
            HStack(spacing: 12) {
                AetherRouteBrandTile(size: 38)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Privacy review required")
                        .font(.headline)
                    Text("Connection controls are locked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
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
            .padding(16)

            Divider()

            HStack {
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .buttonStyle(.borderless)
            .padding(14)
        }
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }
}

private struct MenuTrafficMetric: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

private func compactRate(_ bytes: UInt64) -> String {
    let value = Double(bytes)
    if value >= 1_000_000 {
        return String(format: "%.1fM", value / 1_000_000)
    }
    if value >= 1_000 {
        return String(format: "%.0fK", value / 1_000)
    }
    return "\(bytes)B"
}

private func formattedRate(_ bytes: UInt64) -> String {
    "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))/s"
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

private struct SettingsTabButton: View {
    @Environment(\.controlActiveState) private var controlActiveState

    let tab: SettingsTab
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.symbol)
                    .frame(width: 18)
                Text(tab.title)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.body)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityLabel(tab.title)
        .accessibilityIdentifier("settings-tab-\(tab.rawValue)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var foregroundColor: Color {
        Color(
            nsColor: isSelected && selectionIsEmphasized
                ? .alternateSelectedControlTextColor
                : .labelColor
        )
    }

    private var backgroundColor: Color {
        if isSelected {
            return Color(
                nsColor: selectionIsEmphasized
                    ? .selectedContentBackgroundColor
                    : .unemphasizedSelectedContentBackgroundColor
            )
        }
        if isHovered {
            return Color(nsColor: .unemphasizedSelectedContentBackgroundColor)
        }
        return .clear
    }

    private var selectionIsEmphasized: Bool {
        controlActiveState == .key
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
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(SettingsTab.allCases) { tab in
                        SettingsTabButton(
                            tab: tab,
                            isSelected: selectedTab == tab
                        ) {
                            UIResponsivenessProbe.begin(
                                "settings.\(tab.rawValue)"
                            )
                            selectedTab = tab
                        }
                    }
            }
            .padding(8)
        }
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
                HStack(spacing: 12) {
                    Text("Traffic capture")
                        .foregroundStyle(
                            colorScheme == .dark ? Color.white : Color.black
                        )

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
                    .foregroundStyle(.primary)
            }
#endif

            Section("Routing") {
                HStack(spacing: 12) {
                    Text("Default routing mode")
                        .foregroundStyle(
                            colorScheme == .dark ? Color.white : Color.black
                        )

                    Spacer(minLength: 12)

                    Picker("", selection: $tunnel.routingMode) {
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
            .foregroundStyle(Color(nsColor: .labelColor))
            .accessibilityIdentifier("app-language-picker")

            Label(
                "Language changes apply immediately throughout AetherRoute.",
                systemImage: "globe"
            )
            .font(.subheadline)
            .foregroundStyle(.primary)
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

            LabeledContent("HTTP proxy") {
                HStack(spacing: 10) {
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

            LabeledContent("SOCKS5 proxy") {
                HStack(spacing: 10) {
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
                        .foregroundStyle(
                            colorScheme == .dark ? Color.white : Color.black
                        )
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("local-proxy-status")
                }
            }

            Label(localProxyDetail, systemImage: localProxyDetailSymbol)
                .font(.subheadline)
                .foregroundStyle(.primary)
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
                        .foregroundStyle(.primary)
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
                .foregroundStyle(.primary)

            Text("Shortcuts work while AetherRoute is running and do not require Accessibility access. Notifications are optional and never include profile names, addresses, or traffic details.")
                .font(.subheadline)
                .foregroundStyle(.primary)
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
        case .active: AetherVisual.success
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
                HStack(spacing: 7) {
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 6)

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
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .padding(.horizontal, 10)
                .frame(height: 28)
            }
        }
        .padding(8)
        .frame(width: 230)
    }
}

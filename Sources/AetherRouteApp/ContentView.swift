import AppKit
import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

private var uiReviewRequestsReducedMotion: Bool {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
    ProcessInfo.processInfo.environment[
        "AETHERROUTE_UI_REVIEW_REDUCE_MOTION"
    ] == "1"
#else
    false
#endif
}

enum AppSection: String, CaseIterable, Identifiable {
    case overview
    case proxies
    case connections
    case profiles
    case rules
    case dns

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: AppLocalization.string("Overview")
        case .proxies: AppLocalization.string("Proxies")
        case .connections: AppLocalization.string("Connections")
        case .profiles: AppLocalization.string("Profiles")
        case .rules: AppLocalization.string("Rules")
        case .dns: AppLocalization.string("DNS")
        }
    }

    var subtitle: String {
        switch self {
        case .overview: AppLocalization.string("Connection health and the active route.")
        case .proxies: AppLocalization.string("Choose an exit node and see which one is fastest.")
        case .connections: AppLocalization.string("Review the current session and available telemetry.")
        case .profiles: AppLocalization.string("Manage local and subscribed configurations.")
        case .rules: AppLocalization.string("Inspect ordered routing decisions and targets.")
        case .dns: AppLocalization.string("How domain names are turned into addresses.")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.67percent"
        case .proxies: "globe"
        case .connections: "arrow.left.arrow.right"
        case .profiles: "doc.text.fill"
        case .rules: "list.bullet"
        case .dns: "server.rack"
        }
    }

    /// The sidebar tile colour, one per page as in System Settings.
    var tileColor: Color {
        switch self {
        case .overview: .blue
        case .proxies: .indigo
        case .connections: .green
        case .profiles: .orange
        case .rules: .purple
        case .dns: .teal
        }
    }

    var keyboardShortcut: KeyEquivalent {
        switch self {
        case .overview: "1"
        case .proxies: "2"
        case .connections: "3"
        case .profiles: "4"
        case .rules: "5"
        case .dns: "6"
        }
    }
}

extension Notification.Name {
    static let aetherRouteNavigateToSettings = Notification.Name("com.aetherroute.desktop.navigate-to-settings")
    static let aetherRouteNavigateToSection = Notification.Name(
        "com.aetherroute.desktop.navigate-to-section"
    )
}

extension RoutingMode {
    var localizedTitleKey: LocalizedStringKey {
        switch self {
        case .rule: "Rule"
        case .global: "Global"
        case .direct: "Direct"
        }
    }

    var localizedTitle: String {
        switch self {
        case .rule: AppLocalization.string("Rule")
        case .global: AppLocalization.string("Global")
        case .direct: AppLocalization.string("Direct")
        }
    }

    /// What the mode does, short enough to sit beside its heading.
    var shortHint: String {
        switch self {
        case .rule: AppLocalization.string("Split by rules")
        case .global: AppLocalization.string("Everything through the proxy")
        case .direct: AppLocalization.string("Everything connects directly")
        }
    }

    var symbol: String {
        switch self {
        case .rule: "arrow.triangle.branch"
        case .global: "globe.americas.fill"
        case .direct: "bolt.fill"
        }
    }
}

extension NetworkEngineMode {
    /// What the engine does, short enough to sit beside its heading.
    var shortHint: String {
        switch self {
        case .transparent: AppLocalization.string("Forwards each app's connections")
#if AETHERROUTE_INDEPENDENT
        case .tun: AppLocalization.string("Virtual interface takes all traffic")
#endif
        }
    }
}

extension NetworkEngineMode {
    var localizedTitleKey: LocalizedStringKey {
        switch self {
        case .transparent: "Transparent Proxy"
#if AETHERROUTE_INDEPENDENT
        case .tun: "TUN"
#endif
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var language: AppLanguageController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSection: AppSection? = .overview
    @State private var isCommandPalettePresented = false

    var body: some View {
        Group {
            if tunnel.hasAcceptedPrivacyDisclosure && tunnel.isNetworkSetupRequired {
                NetworkSetupView(isOnboarding: true)
                    .environmentObject(tunnel)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            } else if tunnel.hasAcceptedPrivacyDisclosure {
                applicationContent
                    // Any visible page keeps a 10 s traffic history, so the
                    // Overview waveform is already drawn when you switch back
                    // instead of "collecting samples" for several seconds.
                    .backgroundTelemetryDemand(source: "main-window")
                    .task { await tunnel.prepare() }
                    .task { await tunnel.runSubscriptionUpdateLoop() }
                    .transition(.opacity)
            } else {
                PrivacyDisclosureView(isOnboarding: true)
                    .environmentObject(tunnel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AetherRoute application content")
        .accessibilityIdentifier("aetherroute-semantic-root")
        .frame(minWidth: 780, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The content layer stays opaque, as Apple's guidelines ask: glass
        // belongs to the sidebar, cards and controls floating above it, and
        // secondary text then keeps its contrast whatever the desktop shows.
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: tunnel.isNetworkSetupRequired)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: tunnel.hasAcceptedPrivacyDisclosure)
        .id(language.preference)
        .preferredColorScheme(uiReviewColorScheme)
        .environment(\.dynamicTypeSize, effectiveDynamicTypeSize)
        .overlay(alignment: .topLeading) {
            WindowChromeSynchronizer(
                title: "AetherRoute",
                showsTitle: false,
                isMainWindow: true
            )
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: .aetherRouteNavigateToSection
            )
        ) { notification in
            guard let rawValue = notification.object as? String,
                  let section = AppSection(rawValue: rawValue)
            else { return }
            selectSection(section)
        }
        .onOpenURL { url in
            tunnel.handleExternalURL(url)
        }
        .overlay(alignment: .top) {
            if isCommandPalettePresented && tunnel.hasAcceptedPrivacyDisclosure {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12)
                        .ignoresSafeArea()
                        .onTapGesture { isCommandPalettePresented = false }
                        .transition(.opacity)
                    CommandPaletteView(
                        navigate: { selectSection($0) },
                        dismiss: { isCommandPalettePresented = false }
                    )
                    .environmentObject(tunnel)
                    .padding(.top, AetherVisual.overlayTopInset)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
        .animation(effectiveReduceMotion ? nil : AetherVisual.panelSpring, value: isCommandPalettePresented)
        .onReceive(NotificationCenter.default.publisher(for: .aetherRouteToggleCommandPalette)) { _ in
            isCommandPalettePresented.toggle()
        }
        .sheet(
            item: Binding(
                get: { tunnel.pendingExternalSubscription },
                set: { request in
                    if request == nil {
                        tunnel.cancelExternalSubscriptionImport()
                    }
                }
            ),
            onDismiss: tunnel.cancelExternalSubscriptionImport
        ) { request in
            ExternalSubscriptionConfirmationSheet(request: request)
                .environmentObject(tunnel)
        }
        .alert(
            "Cannot Open Subscription Link",
            isPresented: Binding(
                get: { tunnel.externalSubscriptionLinkError != nil },
                set: { isPresented in
                    if !isPresented {
                        tunnel.dismissExternalSubscriptionLinkError()
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                tunnel.dismissExternalSubscriptionLinkError()
            }
        } message: {
            Text(
                tunnel.externalSubscriptionLinkError
                    ?? AppLocalization.string("This AetherRoute link could not be opened safely.")
            )
        }
        .task {
#if AETHERROUTE_PERFORMANCE_MEASUREMENT
            if ProcessInfo.processInfo.environment[
                "AETHERROUTE_PERFORMANCE_MEASUREMENT_SURFACE"
            ] == "menu-bar" {
                await Task.yield()
                NSApplication.shared.windows.forEach { window in
                    window.close()
                }
            }
#endif
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
            if let requestedSection = ProcessInfo.processInfo.environment[
                "AETHERROUTE_UI_REVIEW_SECTION"
            ].flatMap(AppSection.init(rawValue:)) {
                selectSection(requestedSection)
            }
            if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PALETTE"] == "1" {
                isCommandPalettePresented = true
            }
            if let link = ProcessInfo.processInfo.environment[
                "AETHERROUTE_UI_REVIEW_EXTERNAL_SUBSCRIPTION"
            ].flatMap(URL.init(string:)) {
                tunnel.handleExternalURL(link)
            }
            await configureUIReviewWindowIfRequested()
            if let settingsTab = ProcessInfo.processInfo.environment[
                "AETHERROUTE_UI_REVIEW_SETTINGS_TAB"
            ], settingsTab != "-" {
                openSettings()
            }
#endif
        }
    }

    private var applicationContent: some View {
        NavigationSplitView {
            sidebar
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Primary navigation")
                .accessibilityIdentifier("aetherroute-primary-navigation")
                .navigationSplitViewColumnWidth(
                    min: AetherVisual.sidebarWidth,
                    ideal: AetherVisual.sidebarWidth,
                    max: AetherVisual.sidebarWidth
                )
        } detail: {
            // No label or identifier of its own: every page's root is a scroll
            // view, and wrapper modifiers landed on it and replaced the page's
            // identifier ("overview-page", "rules-page", …).
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(removing: .sidebarToggle)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Primary navigation and content")
        .accessibilityIdentifier("aetherroute-navigation-split")
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

    private var effectiveReduceMotion: Bool {
        reduceMotion || uiReviewRequestsReducedMotion
    }

    private var effectiveDynamicTypeSize: DynamicTypeSize {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_TEXT_SIZE"
        ] == "expanded" ? .xxxLarge : dynamicTypeSize
#else
        dynamicTypeSize
#endif
    }

#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
    @MainActor
    private func configureUIReviewWindowIfRequested() async {
        guard let requestedSize = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_WINDOW"
        ] else { return }
        let dimensions = requestedSize.split(separator: "x", maxSplits: 1)
        guard dimensions.count == 2,
              let width = Double(dimensions[0]),
              let height = Double(dimensions[1]),
              width >= 780,
              height >= 560 else { return }

        await Task.yield()
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible })
        else { return }
        window.setContentSize(NSSize(width: width, height: height))
        if ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_WINDOW_POSITION"
        ] == "top-left",
           let visibleFrame = window.screen?.visibleFrame
                ?? NSScreen.main?.visibleFrame {
            window.setFrameTopLeftPoint(
                NSPoint(
                    x: visibleFrame.minX + 20,
                    y: visibleFrame.maxY - 20
                )
            )
        } else {
            window.center()
        }
    }

#endif

    @State private var isSettingsHovered: Bool = false

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. 顶部品牌与状态指示栏
            HStack(spacing: AetherVisual.sRow) {
                AetherRouteBrandTile(size: 28, isActive: tunnel.isConnected)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text("AetherRoute")
                        .font(.headline.weight(.bold))
                        .tracking(-0.2)
                        .foregroundStyle(.primary)

                    HStack(spacing: AetherVisual.s1) {
                        AetherStatusBeacon(
                            isConnected: tunnel.isConnected,
                            isConnecting: tunnel.state == .connecting || tunnel.state == .recovering || tunnel.isSwitchingNetworkEngine,
                            isFailed: tunnel.isFailed,
                            size: 6
                        )
                        // Primary, not secondary: the beacon carries the
                        // colour, and grey caption text on glass failed the
                        // contrast audit.
                        Text(tunnel.compactStatusTitle)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .contentTransition(.opacity)
                            .animation(AetherVisual.animation(AetherVisual.quickFade), value: tunnel.compactStatusTitle)
                    }
                }

                Spacer()
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.top, AetherVisual.s3)
            .padding(.bottom, AetherVisual.sRow)

            Divider()
                .opacity(0.4)
                .padding(.horizontal, AetherVisual.s3)
                .padding(.bottom, AetherVisual.s1)

            // 2. 核心导航列表
            List(selection: sectionSelection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Button {
                            selectSection(section)
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                AetherIconTile(symbol: section.symbol, color: section.tileColor)

                                Text(section.title)
                                    .font(.body.weight(.medium))

                                Spacer()

                                navigationBadge(for: section)
                            }
                            .padding(.vertical, AetherVisual.sMicro)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .tag(section)
                        .accessibilityIdentifier("primary-navigation-\(section.rawValue)")
                    }
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)

            // 3. 底部设置入口
            VStack(spacing: 0) {
                Divider()
                    .opacity(0.3)
                    .padding(.horizontal, AetherVisual.s3)

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AetherVisual.s2) {
                        sidebarSettingsButton
                        Spacer(minLength: AetherVisual.s2)
                        sidebarVersionLabel
                    }
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        sidebarSettingsButton
                        sidebarVersionLabel
                            .padding(.leading, AetherVisual.sCompact)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s1)
            }
            .padding(.bottom, AetherVisual.s2)
        }
        .padding(.horizontal, AetherVisual.s1)
        // No pane of our own: the system sidebar is already the floating
        // Liquid Glass pane of macOS 26 and follows the Liquid Glass and
        // Reduce Transparency settings. A second glass pane on top of it
        // read as a box inside a box.
    }

    private var sidebarSettingsButton: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: AetherVisual.sRow) {
                AetherIconTile(symbol: "gearshape.fill", color: .gray)
                Text(AppLocalization.string("Settings"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, AetherVisual.s2)
            .padding(.horizontal, AetherVisual.sCompact)
            .aetherHoverHighlight(isHovered: isSettingsHovered)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isSettingsHovered = $0 }
        .accessibilityIdentifier("sidebar-settings-button")
    }

    private var sidebarVersionLabel: some View {
        Text(verbatim: currentAppVersion)
            .font(.system(.subheadline, design: .monospaced, weight: .medium))
            // A resolved grey: on the glass sidebar `.primary` was drawn
            // vibrantly and failed the contrast audit.
            .foregroundStyle(AetherVisual.secondaryText)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.trailing, AetherVisual.s2)
    }

    @ViewBuilder
    private func navigationBadge(for section: AppSection) -> some View {
        switch section {
        case .proxies:
            if let summary = tunnel.activeProfileSummary, summary.proxyCount > 0 {
                AetherCountBadge(count: summary.proxyCount)
            }
        case .connections:
            let count = tunnel.telemetryViewModel.snapshot.connections.count
            if count > 0 {
                AetherCountBadge(count: count)
            }
        case .rules:
            if let summary = tunnel.activeProfileSummary, summary.ruleCount > 0 {
                AetherCountBadge(count: summary.ruleCount)
            }
        default:
            EmptyView()
        }
    }

    private var currentAppVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.1"
        return "v\(version)"
    }

    private var sectionSelection: Binding<AppSection?> {
        Binding(
            get: { selectedSection },
            set: { selectSection($0) }
        )
    }

    private func selectSection(_ section: AppSection?) {
        guard section != selectedSection else { return }
        // Start before the state mutation: onChange runs after SwiftUI has
        // already begun updating the hierarchy and misses part of the work.
        if let section {
            UIResponsivenessProbe.begin("main.\(section.rawValue)")
        }
        selectedSection = section
    }

    private var detail: some View {
        let section = selectedSection ?? .overview
        return ZStack {
            Group {
                switch section {
                case .overview:
                    OverviewView {
                        selectSection(.profiles)
                    }
                case .proxies:
                    ProxiesView()
                case .connections:
                    ConnectionsView(telemetry: tunnel.telemetryViewModel)
                case .profiles:
                    ProfilesView()
                case .rules:
                    RulesView()
                case .dns:
                    DNSView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // Each page is a new identity: the incoming page fades up into
            // place and the outgoing one leaves at once. Scoping the
            // animation here keeps the sidebar and window chrome still;
            // animating the whole tree made the old page's cards morph into
            // the new page's layout.
            .id(section)
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .offset(y: AetherVisual.s2)),
                    removal: .identity
                )
            )
            .animation(effectiveReduceMotion ? nil : AetherVisual.pageEntrance, value: section)
        }
        .navigationTitle(section.title)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(section.subtitle)
        .task(id: section) {
            await Task.yield()
            UIResponsivenessProbe.rendered("main.\(section.rawValue)")
#if DEBUG
            ReviewPerformanceTour.rendered(section)
#endif
        }
#if DEBUG
        .task { await runReviewPerformanceTour() }
#endif
    }

#if DEBUG
    /// Isolated review only: switches through every page three times,
    /// timing selection to first rendered frame, then times the heavy pure
    /// work behind the lists, writes the results and quits.
    private func runReviewPerformanceTour() async {
        guard let path = ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PERF_TOUR"] else { return }
        try? await Task.sleep(for: .seconds(3))
        var lines: [String] = []
        var order: [AppSection] = [.proxies, .connections, .profiles, .rules, .dns, .overview]
        var rounds = 3
        // A focused page alternates with DNS (the lightest page) many times,
        // so a profiler can sample just that page's appearance.
        if let focus = ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PERF_FOCUS"]
            .flatMap(AppSection.init(rawValue:)) {
            order = [focus, .dns]
            rounds = 12
        }
        for round in 1...rounds {
            for section in order {
                let started = DispatchTime.now().uptimeNanoseconds
                async let rendered: Void = ReviewPerformanceTour.waitForRender(section)
                selectSection(section)
                await rendered
                let milliseconds = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
                lines.append(String(format: "page round=%d %@ %.1f ms", round, section.rawValue, milliseconds))
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        lines.append(contentsOf: await ReviewPerformanceTour.computeBenchmarks(tunnel: tunnel))
        try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
#endif
}

#if DEBUG
/// Timing support for `runReviewPerformanceTour`; review builds only.
@MainActor
enum ReviewPerformanceTour {
    private static var waiting: [AppSection: CheckedContinuation<Void, Never>] = [:]

    static func waitForRender(_ section: AppSection) async {
        await withCheckedContinuation { continuation in
            waiting[section] = continuation
        }
    }

    static func rendered(_ section: AppSection) {
        waiting.removeValue(forKey: section)?.resume()
    }

    /// The pure work behind the large lists, timed off the main thread.
    static func computeBenchmarks(tunnel: TunnelManager) async -> [String] {
        let yaml = tunnel.activeProfile?.yaml ?? ""
        let connections = tunnel.telemetryViewModel.snapshot.connections
        return await Task.detached(priority: .userInitiated) {
            var lines: [String] = []
            func time(_ label: String, _ work: () -> Int) {
                let start = DispatchTime.now().uptimeNanoseconds
                let count = work()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
                lines.append(String(format: "compute %@ %.1f ms (n=%d)", label, ms, count))
            }
            var summary: ProfileConfigurationSummary?
            time("parse-profile") {
                summary = ProfileConfigurationInspector.inspect(yaml: yaml)
                return summary?.ruleCount ?? 0
            }
            let rules = summary?.rules ?? []
            time("filter-rules-search") {
                rules.filter { ($0.criteria ?? "").lowercased().contains("site9") }.count
            }
            time("route-test-assess") {
                switch RouteMatchEngine.assess(destination: "site9996.example", against: rules, totalRuleCount: summary?.ruleCount) {
                case .matched: 1
                default: 0
                }
            }
            time("filter-connections-search") {
                connections.filter { $0.destination.localizedCaseInsensitiveContains("host19") }.count
            }
            time("sort-connections-traffic") {
                connections.sorted { $0.downloadTotal + $0.uploadTotal > $1.downloadTotal + $1.uploadTotal }.count
            }
            return lines
        }.value
    }
}
#endif

/// The connection switch, drawn like the VPN switch in System Settings. It is
/// still a button named after its action ("Connect", "Disconnect", "Retry",
/// "Cancel"), so VoiceOver reads the verb and automation finds it as before.
struct ConnectionSwitch: View {
    @EnvironmentObject private var tunnel: TunnelManager
    var identifier = "primary-connection-button"
    var isCompact = false

    var body: some View {
        Button {
            Task { await tunnel.setEnabled(!tunnel.isEnabled) }
        } label: {
            ZStack(alignment: tunnel.isEnabled ? .trailing : .leading) {
                Capsule()
                    .fill(tunnel.isEnabled ? Color.green : Color.secondary.opacity(0.32))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .padding(3)
                    .overlay {
                        if isWorking {
                            // Hidden: as an element of its own it turned the
                            // switch into a group that automation could not
                            // find as a button. The action title says it.
                            ProgressView()
                                .controlSize(.mini)
                                .tint(.gray)
                                .transition(.opacity)
                                .accessibilityHidden(true)
                        }
                    }
            }
            .frame(width: isCompact ? 52 : 62, height: isCompact ? 30 : 34)
            .contentShape(Capsule())
        }
        .buttonStyle(.aetherPressable)
        .disabled(!tunnel.canPerformPrimaryAction)
        .opacity(tunnel.canPerformPrimaryAction ? 1 : 0.45)
        .animation(AetherVisual.animation(AetherVisual.switchToggle), value: tunnel.isEnabled)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isWorking)
        .accessibilityLabel(tunnel.primaryActionTitle)
        .accessibilityIdentifier(identifier)
        .accessibilityHint(primaryActionHint)
        .help(primaryActionHint)
    }

    private var isWorking: Bool {
        if tunnel.isSwitchingNetworkEngine { return true }
        switch tunnel.state {
        case .connecting, .recovering, .disconnecting: return true
        default: return false
        }
    }

    private var primaryActionHint: String {
        if tunnel.systemExtensionApprovalRequired {
            return AppLocalization.string(
                "Approve the AetherRoute network extension to continue."
            )
        }
        if tunnel.isConnectionPreviewOnly {
            return AppLocalization.string(
                "This preview can import and inspect profiles, but it cannot enable system routing."
            )
        }
        return switch tunnel.state {
        case .connecting: AppLocalization.string("Cancels the connection attempt")
        case .connected, .recovering: AppLocalization.string("Disconnects the secure connection")
        case .failed: AppLocalization.string("Retries the secure connection")
        default: AppLocalization.string("Starts the secure connection")
        }
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let openProfiles: () -> Void
    @State private var isSubscriptionEditorPresented = false
    @State private var isCloudSyncSheetPresented = false
    @State private var subscriptionURL = ""

    var body: some View {
        ScrollView {
            VStack(spacing: AetherVisual.sectionSpacing + AetherVisual.s1) {
                AetherPageHeader(.overview)
                // With nothing to connect yet, getting a profile is the one
                // thing to do, so it leads; controls that cannot act yet stay
                // out of the way.
                if needsOnboarding {
                    onboardingCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ConnectionHero(openProfiles: openProfiles)
                if showsTraffic {
                    TrafficCard(
                        isConnected: tunnel.isConnected,
                        isRealtime: tunnel.isRealtimeTelemetryPreferred,
                        isBackground: tunnel.isBackgroundTelemetryPreferred,
                        telemetry: tunnel.telemetryViewModel
                    )
                    .transition(.opacity)
                }
                if !needsOnboarding {
                    routeSection
                }
            }
            .aetherPageContent(.wide)
            .animation(AetherVisual.animation(AetherVisual.panelSpring), value: needsOnboarding)
            .animation(AetherVisual.animation(AetherVisual.panelSpring), value: showsTraffic)
        }
        .sheet(isPresented: $isSubscriptionEditorPresented) {
            SubscriptionEditorSheet(urlText: $subscriptionURL)
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $isCloudSyncSheetPresented) {
            ProfileCloudSyncSheet()
                .environmentObject(tunnel)
        }
        .telemetryDemand(source: "overview")
        .accessibilityIdentifier("overview-page")
    }

    private var needsOnboarding: Bool {
        tunnel.activeProfile == nil
            && !tunnel.isConnected
            && !tunnel.systemExtensionApprovalRequired
            && tunnel.state != .privacyConsentRequired
    }

    /// A failed connection explains itself in the hero; an empty traffic
    /// card under it would only repeat "nothing is flowing".
    private var showsTraffic: Bool {
        guard !needsOnboarding else { return false }
        if case .failed = tunnel.state { return false }
        return true
    }

    private var onboardingCard: some View {
        EmptyProfileOnboardingCard(
            onAddSubscription: {
                tunnel.clearProfileMessage()
                subscriptionURL = ""
                isSubscriptionEditorPresented = true
            },
            onImportProfile: {
                openProfiles()
            },
            onCloudSync: {
                tunnel.clearProfileMessage()
                isCloudSyncSheetPresented = true
            }
        )
    }

    /// Where traffic goes and how: one grouped list, as in System Settings.
    private var routeSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(AppLocalization.string("Overview route section"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
                .padding(.horizontal, AetherVisual.s2)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                OverviewExitRow()
                OverviewRowDivider()
                OverviewModeRows(
                    networkEngineMode: tunnel.networkEngineMode,
                    routingMode: tunnel.routingMode,
                    canChangeNetworkEngine: tunnel.canChangeNetworkEngine,
                    canChangeRoutingMode: tunnel.canChangeRoutingMode,
                    selectNetworkEngine: { mode in
                        Task { await tunnel.setNetworkEngineMode(mode) }
                    },
                    selectRoutingMode: { mode in
                        Task { await tunnel.setRoutingMode(mode) }
                    }
                )
                OverviewRowDivider()
                OverviewRouteCheckRow()
            }
            .aetherPanel()
        }
        .transition(.opacity)
    }
}

/// The outlet the active profile routes through: the node, the group that
/// chose it, and its last latency result.
private struct ActiveOutlet: Equatable {
    let groupName: String
    let node: String
    let latency: ProxyLatencyStatus

    @MainActor
    init?(tunnel: TunnelManager) {
        guard let summary = tunnel.activeProfileSummary,
              let group = summary.proxyGroups.first(where: { $0.strategy.lowercased() == "select" })
                ?? summary.proxyGroups.first,
              let node = tunnel.proxySelections[group.name]?.selectedMember
        else { return nil }
        groupName = group.name
        self.node = node
        latency = ProxyLatencyStatus.status(
            member: node,
            results: tunnel.proxyLatencies[group.name]?.results,
            isTesting: tunnel.isTestingLatency(group: group.name, member: node)
        )
    }
}

/// Why the last connection failed and the next step, shown at the foot of
/// the hero. Retrying is the hero's own switch, so this section only adds
/// what the switch cannot: the reason, and a way to the profiles.
private struct RecoverySection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let plan: ConnectionRecoveryPlan
    let openProfiles: () -> Void
    @State private var isNetworkSetupPresented = false

    var body: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.body.weight(.semibold))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(recoveryDetail)
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: AetherVisual.s2)
            // A withdrawn permission (extension switched off, configuration
            // removed) is fixed with the same page as first-run setup.
            if plan.context == .configuration {
                Button {
                    isNetworkSetupPresented = true
                } label: {
                    Label(AppLocalization.string("Set Up Permissions Again"), systemImage: "lock.shield")
                }
                .aetherGlassButton(prominent: true)
                .accessibilityIdentifier("recovery-networkSetup")
            }
            if plan.primaryAction == .reviewProfiles || plan.secondaryAction == .reviewProfiles {
                let button = Button(action: openProfiles) {
                    Label(AppLocalization.string("Review Profiles"), systemImage: "doc.badge.gearshape")
                }
                .accessibilityIdentifier("recovery-reviewProfiles")
                if plan.primaryAction == .reviewProfiles {
                    button.aetherGlassButton(prominent: true)
                } else {
                    button.aetherGlassButton()
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-recovery-card")
        .sheet(isPresented: $isNetworkSetupPresented) {
            NetworkSetupView(isOnboarding: false) {
                isNetworkSetupPresented = false
            }
            .environmentObject(tunnel)
            .frame(width: AetherVisual.formMaxWidth, height: AetherVisual.windowHeight - AetherVisual.s6 * 2)
        }
    }

    private var recoveryDetail: String {
        switch plan.context {
        case .missingProfile:
            AppLocalization.string("Import or select a validated profile before connecting.")
        case .configuration:
            AppLocalization.string("The saved network extension configuration needs to be checked and prepared again.")
        case .provider:
            AppLocalization.string("The network extension stopped before it could report ready. Retry once, then review the active profile.")
        case .unknown:
            AppLocalization.string("AetherRoute could not confirm a healthy connection. Retry once, then review the active profile.")
        }
    }
}

/// The state at a glance: a medallion, one large word and the switch. The
/// glass takes a faint tint of the state colour, so the card itself reads as
/// connected, idle or failed before any text is read.
private struct ConnectionHero: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openProfiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s5) {
                ConnectionMedallion(phase: phase)
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(tunnel.compactStatusTitle)
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .accessibilityIdentifier("overview-status-title")
                        .accessibilityValue(Text(tunnel.statusDetail))
                    heroSubtitle
                        .font(.callout)
                        // On the tinted card the usual grey measured about 4:1.
                        .foregroundStyle(AetherVisual.strongSecondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ConnectionSwitch()
            }
            if let nextStep {
                Label {
                    Text(nextStep)
                } icon: {
                    Image(systemName: nextStepSymbol)
                        .foregroundStyle(tunnel.isFailed ? Color.orange : Color.accentColor)
                }
                .font(.subheadline)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, ConnectionMedallion.heroSize + AetherVisual.s5)
                .transition(.opacity)
            }
            if tunnel.systemExtensionApprovalRequired {
                approvalControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if let plan = tunnel.recoveryPlan {
                Divider()
                RecoverySection(plan: plan, openProfiles: openProfiles)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AetherVisual.s6)
        .frame(maxWidth: .infinity)
        .aetherGlass(
            in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous),
            tint: phase.color.opacity(phase == .idle ? 0 : 0.14)
        )
        .overlay(alignment: .top) {
            if tunnel.state == .connecting {
                ConnectionLuminousBar()
                    .clipShape(
                        UnevenRoundedRectangle(
                            topLeadingRadius: AetherVisual.panelRadius,
                            bottomLeadingRadius: 0,
                            bottomTrailingRadius: 0,
                            topTrailingRadius: AetherVisual.panelRadius,
                            style: .continuous
                        )
                    )
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-hero")
        .animation(
            effectiveReduceMotion ? nil : .smooth(duration: 0.34),
            value: tunnel.state
        )
    }

    private var phase: ConnectionMedallion.Phase {
        ConnectionMedallion.Phase(tunnel: tunnel)
    }

    private var approvalControls: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text("In System Settings, open General > Login Items & Extensions > Network Extensions, then enable AetherRoute. This window will update after approval.")
                .font(.subheadline)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: AetherVisual.s3) {
                Button {
                    if let settings = NSWorkspace.shared.urlForApplication(
                        withBundleIdentifier: "com.apple.systempreferences"
                    ) {
                        NSWorkspace.shared.open(settings)
                    }
                } label: {
                    Label("Open System Settings", systemImage: "gearshape")
                }
                .aetherGlassButton(prominent: true)
                .accessibilityIdentifier("extension-approval-open-settings")
                Button {
                    Task { await tunnel.recheckSystemExtensionApproval() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .aetherGlassButton()
                .accessibilityIdentifier("extension-approval-recheck")
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("extension-approval-controls")
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || uiReviewRequestsReducedMotion
    }

    /// While connected: how long, and through which node. Otherwise the
    /// state's own explanation.
    @ViewBuilder
    private var heroSubtitle: some View {
        if tunnel.isConnected, !tunnel.isAutomaticRouteRecovering, let since = tunnel.connectedSince {
            let node = ActiveOutlet(tunnel: tunnel).map { tunnel.automaticGroupLeaves[$0.node] ?? $0.node }
            TimelineView(.periodic(from: since, by: 60)) { context in
                let duration = AppLocalization.duration(context.date.timeIntervalSince(since))
                if let node {
                    Text(String.localizedStringWithFormat(AppLocalization.string("Connected for %@ · via %@"), duration, node))
                } else {
                    Text(String.localizedStringWithFormat(AppLocalization.string("Connected for %@"), duration))
                }
            }
        } else if tunnel.state == .disconnected, tunnel.activeProfile != nil {
            Text(AppLocalization.string("Traffic uses the normal network. Turn on the switch to connect."))
        } else {
            Text(tunnel.statusDetail)
        }
    }

    /// A next step only where the switch alone does not say what to do.
    private var nextStep: String? {
        guard tunnel.recoveryPlan == nil else { return nil }
        if tunnel.systemExtensionApprovalRequired {
            return AppLocalization.string("Open System Settings to allow the network extension.")
        }
        if tunnel.isSwitchingNetworkEngine {
            return AppLocalization.string("Switching network engine…")
        }
        return switch tunnel.state {
        case .privacyConsentRequired:
            AppLocalization.string("Review the privacy disclosure to unlock connection controls.")
        case .loading:
            AppLocalization.string("AetherRoute is preparing the local extension configuration.")
        case .disconnected where tunnel.activeProfile == nil:
            AppLocalization.string("Import or select a profile before connecting.")
        case .connecting:
            AppLocalization.string("You can cancel safely while readiness checks are running.")
        case .recovering:
            tunnel.statusDetail
        case .connected where tunnel.isAutomaticRouteRecovering:
            AppLocalization.string(
                "The tunnel remains active while AetherRoute retries the fastest available node."
            )
        case .disconnecting:
            AppLocalization.string("Wait while the normal network path is restored.")
        case .failed:
            AppLocalization.string("Retry once, then review the active profile and diagnostics.")
        case .disconnected, .connected:
            nil
        }
    }

    private var nextStepSymbol: String {
        if tunnel.systemExtensionApprovalRequired { return "hand.raised.fill" }
        if tunnel.isSwitchingNetworkEngine { return "arrow.triangle.2.circlepath" }
        return switch tunnel.state {
        case .connected, .recovering: "arrow.triangle.2.circlepath"
        case .failed: "exclamationmark.triangle.fill"
        case .connecting, .disconnecting, .loading: "clock"
        case .privacyConsentRequired: "hand.raised.fill"
        case .disconnected: "arrow.right.circle"
        }
    }
}

/// A shield in a filled circle of the state colour. While work is under way
/// an arc orbits it, so it never looks settled mid-change. Shared by the
/// overview hero and the menu bar panel.
struct ConnectionMedallion: View {
    enum Phase: Equatable {
        case connected, working, failed, idle

        @MainActor
        init(tunnel: TunnelManager) {
            if tunnel.isSwitchingNetworkEngine {
                self = .working
                return
            }
            switch tunnel.state {
            case .connected where tunnel.isAutomaticRouteRecovering: self = .working
            case .connected: self = .connected
            case .connecting, .recovering, .disconnecting: self = .working
            case .failed: self = .failed
            default: self = .idle
            }
        }

        var color: Color {
            switch self {
            case .connected: .green
            case .working: .orange
            case .failed: .red
            case .idle: Color(nsColor: .systemGray)
            }
        }

        var symbol: String {
            switch self {
            case .connected: "checkmark.shield.fill"
            case .working: "shield.fill"
            case .failed: "exclamationmark.shield.fill"
            case .idle: "shield.slash.fill"
            }
        }
    }

    static let heroSize: CGFloat = 64
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let phase: Phase
    var size: CGFloat = ConnectionMedallion.heroSize

    var body: some View {
        ZStack {
            Circle()
                .fill(phase.color.opacity(0.18))
                .padding(-size * 0.11)
            Circle()
                .fill(phase.color.gradient)
            Image(systemName: phase.symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
            if phase == .working {
                TimelineView(.animation(paused: reduceMotion || uiReviewRequestsReducedMotion)) { context in
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(phase.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .padding(-size * 0.11)
                        .rotationEffect(.degrees(angle(at: context.date)))
                }
                .transition(.opacity)
            }
        }
        .frame(width: size, height: size)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: phase)
        .accessibilityHidden(true)
    }

    private func angle(at date: Date) -> Double {
        guard !(reduceMotion || uiReviewRequestsReducedMotion) else { return -90 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2 * 360
    }
}

/// A mode's effect beside its heading. It cross-fades when the choice
/// changes, so the sentence visibly follows the control.
struct ModeHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .lineLimit(1)
            .truncationMode(.tail)
            .contentTransition(.opacity)
            .animation(AetherVisual.animation(AetherVisual.quickFade), value: text)
    }
}

// MARK: - Route rows

/// One System Settings-style row: a colour tile, a title, then the value or
/// control on the trailing edge.
private struct OverviewRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var help: HelpTopic?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: symbol, color: tint, size: 26)
            HStack(spacing: AetherVisual.s1) {
                // Wraps rather than widening the row: long translations
                // pushed the page past a narrow window.
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let help {
                    AetherHelpButton(topic: help)
                        .controlSize(.small)
                }
            }
            Spacer(minLength: AetherVisual.s3)
            trailing
        }
        .frame(minHeight: 52)
        .padding(.horizontal, AetherVisual.s4)
    }
}

private struct OverviewRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, AetherVisual.s4 + 26 + AetherVisual.s3)
    }
}

/// The exit node; the whole row opens the Proxies page to change it.
private struct OverviewExitRow: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        let outlet = ActiveOutlet(tunnel: tunnel)
        Button {
            NotificationCenter.default.post(
                name: .aetherRouteNavigateToSection,
                object: AppSection.proxies.rawValue
            )
        } label: {
            OverviewRow(symbol: "globe", tint: .indigo, title: AppLocalization.string("Exit node")) {
                HStack(spacing: AetherVisual.s2) {
                    if let outlet {
                        let node = tunnel.automaticGroupLeaves[outlet.node] ?? outlet.node
                        AetherRegionCode(name: node, reservesSlot: false)
                        Text(node)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityIdentifier("overview-active-outlet-node")
                        if outlet.latency != .untested || tunnel.isConnected {
                            ProxyLatencyText(status: outlet.latency)
                        }
                    } else {
                        Text(AppLocalization.string("Choose a node"))
                            .foregroundStyle(AetherVisual.secondaryText)
                    }
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AetherVisual.tertiaryText)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.aetherPressable)
        .accessibilityElement(children: .combine)
        .accessibilityHint(AppLocalization.string("Opens Proxies to change the node"))
        .accessibilityIdentifier("overview-active-outlet")
        // The selection is read from the extension (or the profile while
        // disconnected); without this the row said "Choose a node" until
        // the Proxies page had been opened once.
        .task(id: "\(primaryGroupName ?? ""):\(tunnel.isConnected)") {
            guard let primaryGroupName else { return }
            await tunnel.refreshProxySelection(group: primaryGroupName)
        }
    }

    private var primaryGroupName: String? {
        let groups = tunnel.activeProfileSummary?.proxyGroups ?? []
        return (groups.first { $0.strategy.lowercased() == "select" } ?? groups.first)?.name
    }
}

/// Routing mode and network engine. Takes plain values rather than observing
/// the tunnel, so the native segmented controls only update when a mode
/// actually changes.
private struct OverviewModeRows: View {
    let networkEngineMode: NetworkEngineMode
    let routingMode: RoutingMode
    let canChangeNetworkEngine: Bool
    let canChangeRoutingMode: Bool
    let selectNetworkEngine: (NetworkEngineMode) -> Void
    let selectRoutingMode: (RoutingMode) -> Void

    var body: some View {
        VStack(spacing: 0) {
            OverviewRow(
                symbol: "arrow.triangle.branch",
                tint: .orange,
                title: AppLocalization.string("Routing mode"),
                help: .routingMode
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AetherVisual.s3) {
                        ModeHint(text: routingMode.shortHint)
                        routingPicker
                    }
                    routingPicker
                }
            }
#if AETHERROUTE_INDEPENDENT
            OverviewRowDivider()
            OverviewRow(
                symbol: networkEngineMode == .tun ? "bolt.shield.fill" : "shield.fill",
                tint: .blue,
                title: AppLocalization.string("Network engine"),
                help: .networkEngine
            ) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: AetherVisual.s3) {
                        ModeHint(text: networkEngineMode.shortHint)
                        enginePicker
                    }
                    enginePicker
                }
            }
#endif
        }
    }

    private var routingPicker: some View {
        RoutingModeSegmentedControl(
            selection: Binding(
                get: { routingMode },
                set: { mode in selectRoutingMode(mode) }
            ),
            isEnabled: canChangeRoutingMode
        )
        // At least 240 pt so the two controls line up, wider when a long
        // translation needs it: a fixed frame let the native control draw
        // past its frame and out of the window.
        .fixedSize()
        .frame(minWidth: 240, alignment: .trailing)
    }

#if AETHERROUTE_INDEPENDENT
    private var enginePicker: some View {
        NetworkEngineSegmentedControl(
            selection: Binding(
                get: { networkEngineMode },
                set: { mode in selectNetworkEngine(mode) }
            ),
            isEnabled: canChangeNetworkEngine,
            // "Transparent Proxy" overflowed the 200 pt control in English.
            usesShortTitles: true
        )
        .fixedSize()
        .frame(minWidth: 200, alignment: .trailing)
    }
#endif
}

/// Route quality behind a tunnel that is already carrying traffic. The
/// tunnel being up and the route being fast are separate questions; this
/// answers the second without implying the first is in doubt.
private struct OverviewRouteCheckRow: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        let quality = ConnectionQualityPolicy.displayedQuality(
            tunnel.connectionQuality, isConnected: tunnel.isConnected
        )
        OverviewRow(symbol: "checkmark.seal.fill", tint: .green, title: AppLocalization.string("Route check")) {
            HStack(spacing: AetherVisual.s3) {
                if tunnel.isConnected {
                    Label {
                        Text(title(quality))
                    } icon: {
                        Image(systemName: symbol(quality))
                            .foregroundStyle(tint(quality))
                            .symbolEffect(.pulse, isActive: quality == .verifying)
                    }
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .help(detail(quality))
                    Button(AppLocalization.string("Check")) {
                        openSettings()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            NotificationCenter.default.post(
                                name: .aetherRouteNavigateToSettings,
                                object: "diagnostics"
                            )
                        }
                    }
                    .aetherGlassButton()
                    .controlSize(.small)
                    .help(AppLocalization.string("Run end-to-end network connectivity diagnostics."))
                    .accessibilityIdentifier("overview-diagnose-button")
                } else {
                    Text(AppLocalization.string("Available once connected"))
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-route-quality")
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: quality)
    }

    private func symbol(_ quality: ConnectionQuality?) -> String {
        switch quality {
        case nil, .unknown: "questionmark.circle"
        case .verifying: "gauge.with.dots.needle.bottom.50percent"
        case .verified: "checkmark.circle.fill"
        case .degraded: "exclamationmark.triangle.fill"
        }
    }

    private func tint(_ quality: ConnectionQuality?) -> Color {
        switch quality {
        case nil, .unknown: .secondary
        case .verifying: Color.accentColor
        case .verified: .green
        case .degraded: .orange
        }
    }

    private func title(_ quality: ConnectionQuality?) -> String {
        switch quality {
        case nil, .unknown: AppLocalization.string("Not checked yet")
        case .verifying: AppLocalization.string("Checking route quality")
        case .verified: AppLocalization.string("Route verified")
        case .degraded: AppLocalization.string("Route check incomplete")
        }
    }

    private func detail(_ quality: ConnectionQuality?) -> String {
        switch quality {
        case nil, .unknown:
            AppLocalization.string("Traffic is already routed. Use Diagnose to check the selected exit.")
        case .verifying:
            AppLocalization.string("The tunnel is connected. AetherRoute is checking the selected route in the background.")
        case .verified:
            AppLocalization.string("The selected route answered the latency and data-plane checks.")
        case .degraded:
            AppLocalization.string("Still connected. The route did not complete its checks within the time limit; target availability is not confirmed.")
        }
    }
}

#if AETHERROUTE_INDEPENDENT
struct NetworkEngineSegmentedControl: NSViewRepresentable {
    @Binding var selection: NetworkEngineMode
    let isEnabled: Bool
    /// The menu bar panel: see `NSSegmentedControl.markSelectedSegment`.
    var marksSelection = false
    /// Short engine names, for the narrow menu bar panel.
    var usesShortTitles = false

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    private func title(_ mode: NetworkEngineMode) -> String {
        usesShortTitles ? mode.shortTitle : mode.localizedTitle
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: NetworkEngineMode.allCases.map(title),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        configure(control)
    }

    private func configure(_ control: NSSegmentedControl) {
        let modes = NetworkEngineMode.allCases
        for (index, mode) in modes.enumerated() {
            control.setLabel(title(mode), forSegment: index)
            control.setToolTip(mode.localizedTitle, forSegment: index)
        }
        control.selectedSegment = modes.firstIndex(of: selection) ?? -1
        control.isEnabled = isEnabled
        if marksSelection {
            control.markSelectedSegment()
        }
        // Equal segments, like the routing-mode control beside it, so the two
        // controls read as a pair. When a translation no longer fits, the bar
        // above stacks the controls vertically instead of squeezing them.
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityIdentifier("network-engine-picker")
        control.setAccessibilityLabel(AppLocalization.string("Network engine"))
    }

    final class Coordinator: NSObject {
        var selection: Binding<NetworkEngineMode>

        init(selection: Binding<NetworkEngineMode>) {
            self.selection = selection
        }

        @MainActor @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let modes = NetworkEngineMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            if (0..<sender.segmentCount).contains(where: { sender.image(forSegment: $0) != nil }) {
                sender.markSelectedSegment()
            }
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}
#endif

struct RoutingModeSegmentedControl: NSViewRepresentable {
    @Binding var selection: RoutingMode
    let isEnabled: Bool
    /// The menu bar panel: see `NSSegmentedControl.markSelectedSegment`.
    var marksSelection = false

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: RoutingMode.allCases.map(\.localizedTitle),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.selectionChanged(_:))
        )
        configure(control)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        configure(control)
    }

    private func configure(_ control: NSSegmentedControl) {
        let modes = RoutingMode.allCases
        for (index, mode) in modes.enumerated() {
            control.setLabel(mode.localizedTitle, forSegment: index)
        }
        control.selectedSegment = modes.firstIndex(of: selection) ?? -1
        control.isEnabled = isEnabled
        if marksSelection {
            control.markSelectedSegment()
        }
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityIdentifier("routing-mode-picker")
        control.setAccessibilityLabel(AppLocalization.string("Routing mode"))
    }

    final class Coordinator: NSObject {
        var selection: Binding<RoutingMode>

        init(selection: Binding<RoutingMode>) {
            self.selection = selection
        }

        @MainActor @objc func selectionChanged(_ sender: NSSegmentedControl) {
            let modes = RoutingMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            if (0..<sender.segmentCount).contains(where: { sender.image(forSegment: $0) != nil }) {
                sender.markSelectedSegment()
            }
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}

private enum LiveTelemetryMetricKind {
    case download
    case upload
    case connections
}

/// A metric's label stays put while only the number observes high-frequency
/// telemetry updates.
private struct LiveTelemetryMetric: View {
    let label: String
    let dot: Color?
    let metric: LiveTelemetryMetricKind
    let isConnected: Bool
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
            HStack(spacing: AetherVisual.sCompact) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7)
                }
                Text(label)
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            LiveTelemetryMetricValue(
                metric: metric,
                isConnected: isConnected,
                telemetry: telemetry
            )
        }
        .accessibilityElement(children: .combine)
    }
}

/// The number large and the unit small, as in Apple's Activity app.
private struct LiveTelemetryMetricValue: View {
    let metric: LiveTelemetryMetricKind
    let isConnected: Bool
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        let parts = split(value)
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
            Text(parts.number)
                .font(.system(size: 30, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(isConnected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AetherVisual.secondaryText))
                .aetherNumericValue(parts.number)
            if let unit = parts.unit {
                Text(unit)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(AetherVisual.secondaryText)
            }
        }
    }

    private var value: String {
        guard isConnected else { return "—" }
        switch metric {
        case .download:
            return formattedRate(telemetry.snapshot.downloadBytesPerSecond)
        case .upload:
            return formattedRate(telemetry.snapshot.uploadBytesPerSecond)
        case .connections:
            return String(telemetry.snapshot.connections.count)
        }
    }

    private func split(_ text: String) -> (number: String, unit: String?) {
        guard let space = text.lastIndex(of: " ") else { return (text, nil) }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

/// Download, upload and connection count above the last 30 seconds of
/// traffic. While disconnected it keeps its place and says what will appear.
private struct TrafficCard: View {
    let isConnected: Bool
    let isRealtime: Bool
    let isBackground: Bool
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.string("Live traffic"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AetherVisual.s2)
                Text(AppLocalization.string("Last 30 seconds"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            HStack(alignment: .bottom, spacing: AetherVisual.s6 * 2) {
                LiveTelemetryMetric(
                    label: AppLocalization.string("Download"),
                    dot: .cyan,
                    metric: .download,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                LiveTelemetryMetric(
                    label: AppLocalization.string("Upload"),
                    dot: .purple,
                    metric: .upload,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                LiveTelemetryMetric(
                    label: AppLocalization.string("Active connections"),
                    dot: nil,
                    metric: .connections,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                Spacer(minLength: 0)
            }
            if isConnected {
                LiveTrafficHistoryGraph(model: telemetry, isRealtime: isRealtime, isBackground: isBackground)
                    .transition(.opacity)
            } else {
                Text(AppLocalization.string("Once connected, live download and upload curves appear here."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: 96)
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .strokeBorder(Color.secondary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .transition(.opacity)
            }
        }
        .padding(AetherVisual.s5)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-traffic")
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isConnected)
    }
}

/// Observe high-frequency updates only where the waveform is drawn.
private struct LiveTrafficHistoryGraph: View {
    @ObservedObject var model: NetworkTelemetryViewModel
    let isRealtime: Bool
    let isBackground: Bool

    /// About 24 frames a second: the chart moves roughly one point per
    /// frame, which reads as continuous without redrawing faster than needed.
    private static let frameInterval: TimeInterval = 1.0 / 24
    private static let entryLag = TimeInterval(
        TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.frameInterval, paused: !isRealtime)) { context in
            let lastSample = model.history.samples.last?.date
            // Live: the window slides continuously, one sampling period
            // behind the clock, so each new sample enters at the right edge
            // and drifts left instead of appearing mid-chart every 3 seconds.
            // Paused: nothing new arrives; anchoring the window at the last
            // sample keeps the final 30 seconds on screen instead of sliding
            // them off into an empty chart.
            let now = isRealtime
                ? context.date.addingTimeInterval(-Self.entryLag)
                : (lastSample ?? context.date)
            let samples = model.history.visible(at: now)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                // The chart's scale, the busiest moment in view, sits on its
                // own line so it never covers the curve.
                HStack {
                    Spacer(minLength: 0)
                    Text(peakRate(samples).map {
                        String.localizedStringWithFormat(AppLocalization.string("Peak %@"), $0)
                    } ?? " ")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .aetherNumericValue(peakRate(samples) ?? "")
                }
                ZStack {
                    AetherTrafficMiniGraph(
                        downloadSamples: samples.map(\.download),
                        uploadSamples: samples.map(\.upload),
                        samplePositions: samples.map { TrafficHistory.position(of: $0, at: now) },
                        height: 80
                    )
                    if samples.count < 2 {
                        Text(AppLocalization.string("Collecting traffic samples…"))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .transition(.opacity)
                    }
                }
                .animation(AetherVisual.animation(AetherVisual.quickFade), value: samples.count < 2)
                HStack {
                    Text(AppLocalization.string("30 s ago"))
                    Spacer(minLength: AetherVisual.s2)
                    refreshStatus(lastSample: lastSample)
                    Spacer(minLength: AetherVisual.s2)
                    Text(AppLocalization.string("Now"))
                }
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
            }
        }
    }

    private func peakRate(_ samples: [TrafficHistory.Sample]) -> String? {
        let peak = samples.map { max($0.download, $0.upload) }.max() ?? 0
        guard samples.count > 1, peak >= 1 else { return nil }
        return formattedRate(UInt64(peak))
    }

    @ViewBuilder
    private func refreshStatus(lastSample: Date?) -> some View {
        Group {
            if isRealtime {
                Text(AppLocalization.string("Refresh: every 3 seconds"))
            } else if isBackground {
                Text(AppLocalization.string("Refresh: every 10 seconds"))
            } else if let lastSample {
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("Paused while AetherRoute is in the background · updated %@"),
                        lastSample.formatted(.dateTime.hour().minute().second())
                    )
                )
            } else {
                Text(AppLocalization.string("Paused while AetherRoute is in the background"))
            }
        }
        .font(.caption)
        .foregroundStyle(AetherVisual.secondaryText)
        .contentTransition(.opacity)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isRealtime)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isBackground)
    }
}

extension NSSegmentedControl {
    /// An accent dot on the selected segment, for the menu bar panel only.
    /// The panel never activates the app, and AppKit then draws the selected
    /// segment as a barely lighter grey; the person chose this dot over a
    /// self-drawn control to keep the native look there.
    func markSelectedSegment() {
        for index in 0..<segmentCount {
            let wanted = index == selectedSegment ? Self.selectionDot : nil
            if image(forSegment: index) !== wanted {
                setImage(wanted, forSegment: index)
                setImageScaling(.scaleNone, forSegment: index)
            }
        }
    }

    /// Drawn at display time, so it follows the accent colour and the light
    /// or dark appearance. Not a template: AppKit would recolour it.
    private static let selectionDot: NSImage = {
        let diameter: CGFloat = 7
        let image = NSImage(size: NSSize(width: diameter + 3, height: diameter), flipped: false) { _ in
            NSColor.controlAccentColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: diameter, height: diameter)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }()
}

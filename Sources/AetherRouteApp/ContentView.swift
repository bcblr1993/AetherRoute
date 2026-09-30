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
        case .proxies: AppLocalization.string("Inspect endpoints, groups, and provider sources.")
        case .connections: AppLocalization.string("Review the current session and available telemetry.")
        case .profiles: AppLocalization.string("Manage local and subscribed configurations.")
        case .rules: AppLocalization.string("Inspect ordered routing decisions and targets.")
        case .dns: AppLocalization.string("Inspect resolver privacy, transports, and Fake-IP behavior.")
        }
    }

    var symbol: String {
        switch self {
        case .overview: "circle.grid.2x2"
        case .proxies: "point.3.connected.trianglepath.dotted"
        case .connections: "arrow.left.arrow.right"
        case .profiles: "doc.on.doc"
        case .rules: "list.bullet.rectangle.portrait"
        case .dns: "network.badge.shield.half.filled"
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

    var symbol: String {
        switch self {
        case .rule: "arrow.triangle.branch"
        case .global: "globe.americas.fill"
        case .direct: "bolt.fill"
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
                ZStack {
                    Color(nsColor: .windowBackgroundColor)
                    PrivacyDisclosureView(isOnboarding: true)
                        .environmentObject(tunnel)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("AetherRoute application content")
        .accessibilityIdentifier("aetherroute-semantic-root")
        .frame(minWidth: 780, minHeight: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            detail
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Selected page content")
                .accessibilityIdentifier("aetherroute-selected-page")
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
                            size: 6
                        )
                        Text(tunnel.compactStatusTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
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
                                Image(systemName: section.symbol)
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 18)
                                    .foregroundStyle(
                                        selectedSection == section
                                            ? Color.accentColor
                                            : Color.secondary
                                    )

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
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var sidebarSettingsButton: some View {
        Button {
            openSettings()
        } label: {
            HStack(spacing: AetherVisual.sCompact) {
                Image(systemName: "gearshape")
                    .font(.body.weight(.medium))
                Text(AppLocalization.string("Settings"))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .foregroundStyle(isSettingsHovered ? Color.primary : Color.secondary)
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
            .font(.system(.callout, design: .monospaced, weight: .semibold))
            .foregroundStyle(.primary)
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
            AetherContentCanvas()
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
        }
    }
}

/// One badge style for every sidebar count; counts are information, not
/// state, so none of them is tinted.
private struct ConnectionToolbarButton: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Button {
            Task { await tunnel.setEnabled(!tunnel.isEnabled) }
        } label: {
            HStack(spacing: AetherVisual.s2) {
                if tunnel.state == .connecting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "power")
                        .accessibilityHidden(true)
                }
                Text(tunnel.primaryActionTitle)
                    .contentTransition(.opacity)
            }
            .font(.body.weight(.semibold))
            .frame(minWidth: 118)
            .padding(.vertical, AetherVisual.sMicro)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!tunnel.canPerformPrimaryAction)
        .accessibilityIdentifier("primary-connection-button")
        .accessibilityHint(primaryActionHint)
        .help(primaryActionHint)
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
            VStack(spacing: AetherVisual.sectionSpacing) {
                AetherPageHeader(.overview)
                // With nothing to connect yet, getting a profile is the one
                // thing to do, so it leads; mode controls that cannot act
                // yet stay out of the way.
                if needsOnboarding {
                    onboardingCard
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
                ConnectionHero(openProfiles: openProfiles)
                if !needsOnboarding {
                    ConnectionControlBar(
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
                }
                overviewDetails
            }
            .aetherPageContent(.wide)
            .animation(AetherVisual.animation(AetherVisual.panelSpring), value: needsOnboarding)
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

    /// Everything below the hero and the mode controls. The hero already
    /// carries the active outlet and route check, so this only holds what is
    /// shown instead of an outlet (onboarding, the idle route) and traffic.
    private var needsOnboarding: Bool {
        tunnel.activeProfile == nil
            && !tunnel.isConnected
            && !tunnel.systemExtensionApprovalRequired
            && tunnel.state != .privacyConsentRequired
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

    /// What follows the hero. Each state shows only what adds information:
    /// the planned route while idle, live traffic while connected. A failed
    /// connection explains itself inside the hero instead of repeating
    /// "unavailable" in three more cards.
    private var overviewDetails: some View {
        VStack(spacing: AetherVisual.sectionSpacing) {
            if showsRouteSummary {
                RouteSummary()
                    .transition(.opacity)
            }
            if tunnel.isConnected {
                TrafficCard(
                    isConnected: tunnel.isConnected,
                    isRealtime: tunnel.isRealtimeTelemetryPreferred,
                    isBackground: tunnel.isBackgroundTelemetryPreferred,
                    telemetry: tunnel.telemetryViewModel
                )
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: tunnel.isConnected)
    }

    private var showsRouteSummary: Bool {
        guard !tunnel.isConnected, tunnel.activeProfile != nil else { return false }
        if case .failed = tunnel.state { return false }
        return true
    }
}

/// The outlet the active profile is routing through right now: the node, the
/// group that chose it, and its last latency result.
private struct ActiveOutlet: Equatable {
    let groupName: String
    let node: String
    /// Nil when the profile does not declare the node's protocol inline.
    let protocolName: String?
    /// Set when the selected member is itself a group (for example a
    /// url-test group); its strategy is shown instead of a protocol.
    let nestedGroupStrategy: String?
    let latency: ProxyLatencyStatus
    let confidence: ProxyLatencyConfidence

    @MainActor
    init?(tunnel: TunnelManager) {
        guard tunnel.isConnected,
              let summary = tunnel.activeProfileSummary,
              let group = summary.proxyGroups.first(where: { $0.strategy.lowercased() == "select" })
                ?? summary.proxyGroups.first,
              let node = tunnel.proxySelections[group.name]?.selectedMember
        else { return nil }
        groupName = group.name
        self.node = node
        protocolName = summary.proxies.first(where: { $0.name == node })?.protocolName
        nestedGroupStrategy = summary.proxyGroups.first(where: { $0.name == node })?.strategy
        latency = ProxyLatencyStatus.status(
            member: node,
            results: tunnel.proxyLatencies[group.name]?.results,
            isTesting: tunnel.isTestingLatency(group: group.name, member: node)
        )
        confidence = tunnel.latencyConfidence(group: group.name, member: node)
    }
}

/// One row inside the hero: where traffic leaves, how fast that exit last
/// answered, and the two things people do next (diagnose, switch).
private struct ActiveOutletRow: View {
    @Environment(\.openSettings) private var openSettings
    @EnvironmentObject private var tunnel: TunnelManager
    let outlet: ActiveOutlet
    /// The node an automatic group is using right now, read from the chains
    /// of live connections. Nil for plain nodes or before traffic flows.
    let resolvedLeaf: String?

    private var displayedNode: String { resolvedLeaf ?? outlet.node }

    private func testLatency() {
        Task { await tunnel.testSingleProxyLatency(group: outlet.groupName, member: outlet.node) }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AetherVisual.s3) {
                identity
                Spacer(minLength: AetherVisual.s2)
                actions
            }
            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                identity
                actions
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-active-outlet")
    }

    private var identity: some View {
        HStack(spacing: AetherVisual.s3) {
            outletIcon
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.string("Exit"))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(displayedNode)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(displayedNode)
                    .contentTransition(.opacity)
                    .accessibilityIdentifier("overview-active-outlet-node")
                HStack(spacing: AetherVisual.sCompact) {
                    Label(outlet.groupName, systemImage: "square.stack.3d.up")
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                    // "Proxy › Auto": the automatic group that picked the
                    // node above stays visible as routing context.
                    if resolvedLeaf != nil {
                        Text(verbatim: "› \(outlet.node)")
                            .lineLimit(1)
                    }
                    // A nested group shows its strategy (URL-TEST, FALLBACK…);
                    // a node shows its protocol. Nothing is shown rather than
                    // a placeholder when neither is known.
                    if let strategy = outlet.nestedGroupStrategy {
                        AetherProtocolBadge(type: strategy)
                    } else if let protocolName = outlet.protocolName {
                        AetherProtocolBadge(type: protocolName)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: displayedNode)
    }

    @ViewBuilder
    private var outletIcon: some View {
        if let strategy = outlet.nestedGroupStrategy {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                Image(systemName: proxyGroupSymbol(strategy))
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
        } else {
            AetherNodeIcon(name: outlet.node, protocolName: outlet.protocolName ?? "", size: 36)
        }
    }

    private var actions: some View {
        HStack(spacing: AetherVisual.s2) {
            // The exit's latency is a button, as on the Proxies page: it used
            // to have no tap action and so rendered disabled (dimmed).
            if outlet.latency == .untested {
                Button(AppLocalization.string("Test Latency"), systemImage: "bolt") {
                    testLatency()
                }
                .accessibilityIdentifier("overview-test-latency")
                .transition(.opacity)
            } else {
                AetherLatencyPill(status: outlet.latency, confidence: outlet.confidence) {
                    testLatency()
                }
                .help(AppLocalization.string("Test this node again"))
                .accessibilityIdentifier("overview-latency-pill")
                .transition(.opacity)
            }

            Button {
                openSettings()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    NotificationCenter.default.post(
                        name: .aetherRouteNavigateToSettings,
                        object: "diagnostics"
                    )
                }
            } label: {
                Label(AppLocalization.string("Diagnose"), systemImage: "stethoscope")
            }
            .accessibilityIdentifier("overview-diagnose-button")
            .help(AppLocalization.string("Run end-to-end network connectivity diagnostics."))

            Button {
                NotificationCenter.default.post(
                    name: .aetherRouteNavigateToSection,
                    object: AppSection.proxies.rawValue
                )
            } label: {
                Label(AppLocalization.string("Switch"), systemImage: "arrow.left.arrow.right")
            }
            .accessibilityIdentifier("overview-switch-node-button")
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .fixedSize()
    }
}

/// Why the last connection failed and the next step, shown at the foot of
/// the hero. Retrying is the hero's own primary button, so this section only
/// adds what that button cannot: the reason, and a way to the profiles.
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
                .foregroundStyle(.secondary)
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
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("recovery-networkSetup")
            }
            if plan.primaryAction == .reviewProfiles || plan.secondaryAction == .reviewProfiles {
                let button = Button(action: openProfiles) {
                    Label(AppLocalization.string("Review Profiles"), systemImage: "doc.badge.gearshape")
                }
                .accessibilityIdentifier("recovery-reviewProfiles")
                if plan.primaryAction == .reviewProfiles {
                    button.buttonStyle(.borderedProminent)
                } else {
                    button.buttonStyle(.bordered)
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

private struct ConnectionHero: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let openProfiles: () -> Void

    var body: some View {
        let outlet = ActiveOutlet(tunnel: tunnel)
        let quality = ConnectionQualityPolicy.displayedQuality(
            tunnel.connectionQuality, isConnected: tunnel.isConnected
        )
        VStack(spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s6) {
                connectionIdentity
                ConnectionToolbarButton()
                    .environmentObject(tunnel)
            }
            if tunnel.systemExtensionApprovalRequired {
                approvalControls
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            // State, exit and route check answer one question ("is my
            // traffic going where I think?"), so they share one card.
            if let outlet {
                Divider()
                ActiveOutletRow(outlet: outlet, resolvedLeaf: tunnel.automaticGroupLeaves[outlet.node])
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
            if tunnel.isConnected {
                RouteQualityLine(quality: quality, checkedAt: tunnel.connectionQualityCheckedAt)
                    .transition(.opacity)
            }
            if let plan = tunnel.recoveryPlan {
                Divider()
                RecoverySection(plan: plan, openProfiles: openProfiles)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(AetherVisual.s5)
        .frame(maxWidth: .infinity)
        .aetherHeroPanel()
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
        .animation(
            effectiveReduceMotion ? nil : .smooth(duration: 0.34),
            value: tunnel.state
        )
    }

    private var approvalControls: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text("In System Settings, open General > Login Items & Extensions > Network Extensions, then enable AetherRoute. This window will update after approval.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("extension-approval-open-settings")
                Button {
                    Task { await tunnel.recheckSystemExtensionApproval() }
                } label: {
                    Label("Check Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
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

    /// Any transition in progress orbits the ring, including recovery and
    /// the stop, so the lens never looks settled while work is under way.
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

    private var connectionIdentity: some View {
        HStack(spacing: AetherVisual.s4) {
            AetherRouteStatusLens(
                size: 54,
                isActive: tunnel.isConnected,
                isConnecting: isWorking,
                isFailed: isFailed
            )

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(tunnel.statusTitle)
                    .font(.title.weight(.semibold))
                    .tracking(-0.45)
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .accessibilityValue(Text(tunnel.statusDetail))
                heroSubtitle
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityHidden(true)
                if (!tunnel.isConnected || tunnel.isAutomaticRouteRecovering || tunnel.isSwitchingNetworkEngine)
                    && tunnel.recoveryPlan == nil {
                    Label(nextStep, systemImage: nextStepSymbol)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// While connected, how long the session has held says more than the
    /// extension's readiness; other states keep their explanation.
    @ViewBuilder
    private var heroSubtitle: some View {
        if tunnel.isConnected, !tunnel.isAutomaticRouteRecovering, let since = tunnel.connectedSince {
            TimelineView(.periodic(from: since, by: 60)) { context in
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("Connected for %@"),
                        AppLocalization.duration(context.date.timeIntervalSince(since))
                    )
                )
            }
        } else {
            Text(tunnel.statusDetail)
        }
    }

    private var nextStep: String {
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
        case .disconnected:
            tunnel.activeProfile == nil
                ? AppLocalization.string("Import or select a profile before connecting.")
                : AppLocalization.string("Connect when ready, or review the active profile first.")
        case .connecting:
            AppLocalization.string("You can cancel safely while readiness checks are running.")
        case .recovering:
            tunnel.statusDetail
        case .connected where tunnel.isAutomaticRouteRecovering:
            AppLocalization.string(
                "The tunnel remains active while AetherRoute retries the fastest available node."
            )
        case .connected:
            AppLocalization.string("Open Connections for per-flow details. Route checks are shown separately below.")
        case .disconnecting:
            AppLocalization.string("Wait while the normal network path is restored.")
        case .failed:
            AppLocalization.string("Retry once, then review the active profile and diagnostics.")
        }
    }

    private var nextStepSymbol: String {
        if tunnel.systemExtensionApprovalRequired { return "hand.raised.fill" }
        if tunnel.isSwitchingNetworkEngine { return "arrow.triangle.2.circlepath" }
        return switch tunnel.state {
        case .connected where tunnel.isAutomaticRouteRecovering:
            "arrow.triangle.2.circlepath"
        case .recovering: "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .connecting, .disconnecting, .loading: "clock"
        case .privacyConsentRequired: "hand.raised.fill"
        case .disconnected: "arrow.right.circle"
        }
    }
}


private struct ConnectionControlBar: View {
    let networkEngineMode: NetworkEngineMode
    let routingMode: RoutingMode
    let canChangeNetworkEngine: Bool
    let canChangeRoutingMode: Bool
    let selectNetworkEngine: (NetworkEngineMode) -> Void
    let selectRoutingMode: (RoutingMode) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: AetherVisual.s4) {
                routingControls
#if AETHERROUTE_INDEPENDENT
                Divider()
                    .frame(height: 38)
                    .opacity(0.4)
                engineControls
                    .frame(minWidth: 220)
#endif
            }
            VStack(alignment: .leading, spacing: AetherVisual.s4) {
                routingControls
#if AETHERROUTE_INDEPENDENT
                engineControls
#endif
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .aetherPanel()
    }

    private var routingControls: some View {
        VStack(alignment: .leading, spacing: AetherVisual.sCompact) {
            HStack(spacing: AetherVisual.sCompact) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Routing mode"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
            }
            RoutingModeSegmentedControl(
                selection: Binding(
                    get: { routingMode },
                    set: { mode in selectRoutingMode(mode) }
                ),
                isEnabled: canChangeRoutingMode
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

#if AETHERROUTE_INDEPENDENT
    private var engineControls: some View {
        VStack(alignment: .leading, spacing: AetherVisual.sCompact) {
            HStack(spacing: AetherVisual.sCompact) {
                Image(systemName: networkEngineMode == .tun ? "bolt.shield.fill" : "network")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Network engine"))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                AetherHelpButton(topic: .networkEngine)
                    .controlSize(.small)
            }
            NetworkEngineSegmentedControl(
                selection: Binding(
                    get: { networkEngineMode },
                    set: { mode in selectNetworkEngine(mode) }
                ),
                isEnabled: canChangeNetworkEngine
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
#endif
}

#if AETHERROUTE_INDEPENDENT
struct NetworkEngineSegmentedControl: NSViewRepresentable {
    @Binding var selection: NetworkEngineMode
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(
            labels: NetworkEngineMode.allCases.map(\.localizedTitle),
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
            control.setLabel(mode.localizedTitle, forSegment: index)
        }
        control.selectedSegment = modes.firstIndex(of: selection) ?? -1
        control.markSelectedSegment()
        control.isEnabled = isEnabled
        // Equal segments, like the routing-mode control beside it, so the two
        // controls read as a pair. When a translation no longer fits, the bar
        // above stacks the controls vertically instead of squeezing them.
        control.segmentDistribution = .fillEqually
        // The default selected bezel is a faint grey step that almost
        // disappears on dark materials; the accent fill reads at a glance
        // and matches the connection toggle above it.
        control.selectedSegmentBezelColor = .controlAccentColor
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
            sender.markSelectedSegment()
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}
#endif

struct RoutingModeSegmentedControl: NSViewRepresentable {
    @Binding var selection: RoutingMode
    let isEnabled: Bool

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
        control.markSelectedSegment()
        control.isEnabled = isEnabled
        control.segmentDistribution = .fillEqually
        // The default selected bezel is a faint grey step that almost
        // disappears on dark materials; the accent fill reads at a glance
        // and matches the connection toggle above it.
        control.selectedSegmentBezelColor = .controlAccentColor
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
            sender.markSelectedSegment()
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}

private struct RouteSummary: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack {
                Text("Current route")
                    .font(.headline)
                Spacer()
                Label(routeStatus.title, systemImage: routeStatus.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AetherVisual.s2) {
                    routeStops(horizontal: true)
                }
                .frame(maxWidth: .infinity)

                VStack(spacing: AetherVisual.s2) {
                    routeStops(horizontal: false)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .aetherPanel()
    }

    @ViewBuilder
    private func routeStops(horizontal: Bool) -> some View {
        RouteStop(
            identifier: "overview-route-device",
            symbol: "laptopcomputer",
            caption: "Device",
            value: AppLocalization.string("This Mac")
        )
        RouteConnector(isHorizontal: horizontal)
        RouteStop(
            identifier: "overview-route-policy",
            symbol: "arrow.triangle.branch",
            caption: "Policy",
            value: tunnel.activeProfile?.name
                ?? AppLocalization.string("No profile")
        )
        RouteConnector(isHorizontal: horizontal)
        RouteStop(
            identifier: "overview-route-exit",
            symbol: "network",
            caption: "Exit",
            value: routeExit
        )
    }

    private var routeExit: String {
        switch tunnel.state {
        case .privacyConsentRequired: AppLocalization.string("Privacy review")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected: AppLocalization.string("Normal network")
        case .connecting: AppLocalization.string("Starting")
        case .recovering: AppLocalization.string("Recovering network")
        case .connected where tunnel.isAutomaticRouteRecovering:
            AppLocalization.string("Retrying nodes")
        case .connected: AppLocalization.string("Extension ready")
        case .disconnecting: AppLocalization.string("Stopping")
        case .failed: AppLocalization.string("Unavailable")
        }
    }

    private var routeStatus: (title: String, symbol: String, color: Color) {
        switch tunnel.state {
        case .privacyConsentRequired:
            (AppLocalization.string("Privacy review"), "hand.raised.fill", .orange)
        case .loading:
            (AppLocalization.string("Preparing"), "circle.dotted", .secondary)
        case .disconnected:
            (AppLocalization.string("Standby"), "pause.circle", .secondary)
        case .connecting:
            (AppLocalization.string("Starting"), "progress.indicator", .orange)
        case .recovering:
            (AppLocalization.string("Recovering network"), "arrow.triangle.2.circlepath", .orange)
        case .connected where tunnel.isAutomaticRouteRecovering:
            (AppLocalization.string("Recovering"), "arrow.triangle.2.circlepath", .orange)
        case .connected:
            (AppLocalization.string("Active"), "checkmark.circle.fill", .teal)
        case .disconnecting:
            (AppLocalization.string("Stopping"), "progress.indicator", .orange)
        case .failed:
            (AppLocalization.string("Unavailable"), "exclamationmark.triangle.fill", .red)
        }
    }
}


private struct RouteStop: View {
    let identifier: String
    let symbol: String
    let caption: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: symbol)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(caption)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(value)
            }
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.85),
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(identifier)
    }
}

private struct RouteConnector: View {
    let isHorizontal: Bool

    var body: some View {
        Group {
            if isHorizontal {
                HStack(spacing: AetherVisual.sMicro) {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.15)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(height: 1.5)
                        .frame(minWidth: 10)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .imageScale(.small)
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                }
                .frame(maxWidth: 36)
            } else {
                VStack(spacing: AetherVisual.sMicro) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: 1.5, height: 8)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .imageScale(.small)
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                }
                .frame(height: 14)
            }
        }
        .accessibilityHidden(true)
    }
}

private enum LiveTelemetryMetricKind {
    case download
    case upload
    case connections
}

/// The label, SF Symbol and panel layout remain structurally stable while only
/// the numeric text observes high-frequency telemetry updates.
private struct LiveTelemetryMetricTile: View {
    let label: LocalizedStringKey
    let symbol: String
    let tint: Color
    let metric: LiveTelemetryMetricKind
    let isConnected: Bool
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Label {
                Text(label)
            } icon: {
                Image(systemName: symbol).foregroundStyle(tint)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            LiveTelemetryMetricValue(
                metric: metric,
                isConnected: isConnected,
                telemetry: telemetry
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s4)
    }
}

private struct LiveTelemetryMetricValue: View {
    let metric: LiveTelemetryMetricKind
    let isConnected: Bool
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        Text(value)
            .font(.title2.weight(.medium))
            .foregroundStyle(.primary)
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(AetherVisual.animation(AetherVisual.quickFade), value: value)
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
}

/// Reports route quality behind a tunnel that is already carrying traffic.
///
/// The tunnel being up and the selected route being fast are separate
/// questions. This answers the second one without ever implying the first is
/// in doubt, so a slow node reads as "still working, looking for better"
/// rather than as a failure. It sits at the foot of the hero, next to the
/// exit it describes.
private struct RouteQualityLine: View {
    let quality: ConnectionQuality?
    let checkedAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: quality == .verifying)
                .accessibilityHidden(true)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .accessibilityHint(Text(detail))
            if let checkedAt, quality != nil {
                Text(checkedAt, format: .dateTime.hour().minute().second())
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("overview-route-quality")
        .animation(
            AetherVisual.animation(AetherVisual.gentleSpring),
            value: quality
        )
    }

    private var symbol: String {
        switch quality {
        case nil, .unknown: "questionmark.circle"
        case .verifying: "gauge.with.dots.needle.bottom.50percent"
        case .verified: "checkmark.shield"
        case .degraded: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch quality {
        case nil, .unknown: .secondary
        case .verifying: Color.accentColor
        case .verified: .green
        case .degraded: .orange
        }
    }

    private var title: LocalizedStringKey {
        switch quality {
        case nil, .unknown: "Route not checked"
        case .verifying: "Checking route quality"
        case .verified: "Route verified"
        case .degraded: "Route check incomplete"
        }
    }

    private var detail: LocalizedStringKey {
        switch quality {
        case nil, .unknown:
            "Traffic is routed as soon as the network extension installs its settings."
        case .verifying:
            "The tunnel is connected. AetherRoute is checking the selected route in the background."
        case .verified:
            "The selected route answered the latency and data-plane checks."
        case .degraded:
            "Still connected. The route did not complete its checks within the time limit; target availability is not confirmed."
        }
    }
}

/// Download, upload and connection count, with the last 30 seconds drawn
/// underneath. The card states the real refresh cadence: every 3 s when
/// frontmost, every 10 s when visible behind another app, and paused (graph
/// frozen at the last sample) when nothing is visible, instead of letting the
/// graph drain empty beside numbers that look live.
private struct TrafficCard: View {
    let isConnected: Bool
    let isRealtime: Bool
    let isBackground: Bool
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                LiveTelemetryMetricTile(
                    label: "Download",
                    symbol: "arrow.down",
                    tint: .cyan,
                    metric: .download,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                Divider().frame(height: 40)
                LiveTelemetryMetricTile(
                    label: "Upload",
                    symbol: "arrow.up",
                    tint: .purple,
                    metric: .upload,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                Divider().frame(height: 40)
                LiveTelemetryMetricTile(
                    label: "Active connections",
                    symbol: "point.3.connected.trianglepath.dotted",
                    tint: .secondary,
                    metric: .connections,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
            }

            if isConnected {
                Divider()
                    .padding(.horizontal, AetherVisual.s4)
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    HStack(spacing: AetherVisual.s3) {
                        Label(AppLocalization.string("Traffic · Last 30 seconds"), systemImage: "chart.xyaxis.line")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: AetherVisual.s2)
                        legend(color: .cyan, title: "Down")
                        legend(color: .purple, title: "Up")
                    }
                    LiveTrafficHistoryGraph(model: telemetry, isRealtime: isRealtime, isBackground: isBackground)
                }
                .padding(AetherVisual.s4)
                .transition(.opacity)
            }
        }
        .aetherPanel()
    }

    private func legend(color: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: AetherVisual.s1) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
                ZStack {
                    AetherTrafficMiniGraph(
                        downloadSamples: samples.map(\.download),
                        uploadSamples: samples.map(\.upload),
                        samplePositions: samples.map { TrafficHistory.position(of: $0, at: now) },
                        height: 56
                    )
                    if samples.count < 2 {
                        Text(AppLocalization.string("Collecting traffic samples…"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .transition(.opacity)
                    }
                }
                .animation(AetherVisual.animation(AetherVisual.quickFade), value: samples.count < 2)
                refreshStatus(lastSample: lastSample)
            }
        }
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
        .foregroundStyle(.secondary)
        .contentTransition(.opacity)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isRealtime)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isBackground)
    }
}

extension NSSegmentedControl {
    /// A small accent-coloured dot on the selected segment. AppKit draws the
    /// selection in the accent colour only while the app is frontmost; the
    /// menu bar panel never activates the app, so the selection there was
    /// just a slightly lighter gray. The dot keeps the translucent native look
    /// and reads the same in every state.
    func markSelectedSegment() {
        for index in 0..<segmentCount {
            let isSelected = index == selectedSegment
            if (image(forSegment: index) == nil) == isSelected {
                setImage(isSelected ? Self.selectionDot : nil, forSegment: index)
                setImageScaling(.scaleNone, forSegment: index)
            }
        }
    }

    /// Drawn at display time, so it follows the user's accent colour and
    /// light or dark appearance. Not a template image: AppKit would recolour
    /// a template to match the label.
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

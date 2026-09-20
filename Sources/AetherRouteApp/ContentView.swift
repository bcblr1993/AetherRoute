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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSection: AppSection? = .overview

    var body: some View {
        Group {
            if tunnel.hasAcceptedPrivacyDisclosure {
                applicationContent
                    .task { await tunnel.prepare() }
                    .task { await tunnel.runSubscriptionUpdateLoop() }
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
        .animation(effectiveReduceMotion ? nil : .snappy(duration: 0.28), value: selectedSection)
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

    @State private var copiedTerminalExport: Bool = false
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
                        Text(tunnel.state == .recovering || tunnel.isSwitchingNetworkEngine ? tunnel.statusTitle : (tunnel.isConnected ? AppLocalization.string("Protected") : AppLocalization.string("Idle")))
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.primary)
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
                                    .font(.system(size: 14, weight: .semibold))
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

                HStack(spacing: AetherVisual.s2) {
                    Button {
                        openSettings()
                    } label: {
                        HStack(spacing: AetherVisual.sCompact) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 13, weight: .medium))
                            Text(AppLocalization.string("Settings"))
                                .font(.system(size: 12.5, weight: .medium))
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

                    Spacer()

                    Text(verbatim: currentAppVersion)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(.primary)
                        .padding(.trailing, AetherVisual.s2)
                }
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s1)
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private func navigationBadge(for section: AppSection) -> some View {
        switch section {
        case .proxies:
            if let summary = tunnel.activeProfileSummary, summary.proxyCount > 0 {
                Text(verbatim: "\(summary.proxyCount)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
            }
        case .connections:
            let count = tunnel.telemetryViewModel.snapshot.connections.count
            if count > 0 {
                Text(verbatim: "\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(Color.cyan.opacity(0.12), in: Capsule())
            }
        case .rules:
            if let summary = tunnel.activeProfileSummary, summary.ruleCount > 0 {
                Text(verbatim: "\(summary.ruleCount)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(Color.secondary.opacity(0.1), in: Capsule())
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
            VStack(spacing: AetherVisual.s3 + 2) {
                ConnectionHero()
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
                overviewDetails
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.s3)
            .padding(.bottom, AetherVisual.s4)
            .frame(maxWidth: AetherVisual.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .sheet(isPresented: $isSubscriptionEditorPresented) {
            SubscriptionEditorSheet(urlText: $subscriptionURL)
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $isCloudSyncSheetPresented) {
            ProfileCloudSyncSheet()
                .environmentObject(tunnel)
        }
        .onAppear {
            updateOverviewTelemetryState()
        }
        .onDisappear {
            tunnel.setRealtimeTelemetryPreferred(false, for: "overview")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in
            tunnel.setRealtimeTelemetryPreferred(false, for: "overview")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in
            updateOverviewTelemetryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willHideNotification)) { _ in
            tunnel.setRealtimeTelemetryPreferred(false, for: "overview")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in
            updateOverviewTelemetryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            updateOverviewTelemetryState()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            tunnel.setRealtimeTelemetryPreferred(false, for: "overview")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in
            updateOverviewTelemetryState()
        }
        .accessibilityIdentifier("overview-page")
    }

    private func updateOverviewTelemetryState() {
        let hasVisibleWindow = NSApplication.shared.isActive && NSApplication.shared.windows.contains { window in
            window.isVisible && !window.isMiniaturized && !(window is NSPanel)
                && window.occlusionState.contains(.visible)
        }
        tunnel.setRealtimeTelemetryPreferred(hasVisibleWindow, for: "overview")
    }

    private var overviewDetails: some View {
        VStack(spacing: AetherVisual.s3 + 2) {
            if tunnel.isConnected {
                activeNodeCard
            } else if tunnel.activeProfile == nil {
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
            } else {
                RouteSummary()
            }
            if let recoveryPlan = tunnel.recoveryPlan {
                ConnectionRecoveryCard(
                    plan: recoveryPlan,
                    openProfiles: openProfiles
                )
            }

            // 实时网络速率与动态波形看板卡片
            VStack(spacing: AetherVisual.s3) {
                // 顶部四大指标项
                HStack(spacing: 0) {
                    MetricTile(
                        label: "Latency",
                        value: bestLatency,
                        unit: bestLatencyUnit,
                        symbol: "waveform.path.ecg"
                    )
                    Divider().frame(height: 48)
                    LiveTelemetryMetricTile(
                        label: "Download",
                        unit: "",
                        symbol: "arrow.down",
                        metric: .download,
                        isConnected: tunnel.isConnected,
                        telemetry: tunnel.telemetryViewModel
                    )
                    Divider().frame(height: 48)
                    LiveTelemetryMetricTile(
                        label: "Upload",
                        unit: "",
                        symbol: "arrow.up",
                        metric: .upload,
                        isConnected: tunnel.isConnected,
                        telemetry: tunnel.telemetryViewModel
                    )
                    Divider().frame(height: 48)
                    LiveTelemetryMetricTile(
                        label: "Active connections",
                        unit: "",
                        symbol: "point.3.connected.trianglepath.dotted",
                        metric: .connections,
                        isConnected: tunnel.isConnected,
                        telemetry: tunnel.telemetryViewModel
                    )
                }
                .padding(.vertical, AetherVisual.s1)

                // 实时 30 秒上下行动态平滑双波形图
                if tunnel.isConnected {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        HStack {
                            Label(AppLocalization.string("Traffic · Last 30 seconds"), systemImage: "chart.xyaxis.line")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.primary)
                            Spacer()
                            HStack(spacing: AetherVisual.s3) {
                                HStack(spacing: AetherVisual.s1) {
                                    Circle().fill(Color.cyan).frame(width: 6, height: 6)
                                    Text("Down")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.primary)
                                }
                                HStack(spacing: AetherVisual.s1) {
                                    Circle().fill(Color.purple).frame(width: 6, height: 6)
                                    Text("Up")
                                        .font(.system(size: 10, weight: .medium))
                                        .foregroundStyle(.primary)
                                }
                            }
                        }
                        .padding(.horizontal, AetherVisual.s4)

                        Text(AppLocalization.string(tunnel.isRealtimeTelemetryPreferred ? "Refresh: every 3 seconds" : "Refresh: every 10 seconds"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, AetherVisual.s4)
                        LiveTrafficHistoryGraph(
                            model: tunnel.telemetryViewModel,
                            isRealtime: tunnel.isRealtimeTelemetryPreferred
                        )
                        .padding(.horizontal, AetherVisual.s2)
                        .padding(.bottom, AetherVisual.s2)
                    }
                }
            }
            .aetherPanel()

            if let quality = ConnectionQualityPolicy.displayedQuality(
                tunnel.connectionQuality, isConnected: tunnel.isConnected
            ) {
                SafetyNotice(quality: quality)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var bestLatency: String {
        let values = tunnel.proxyLatencies.values
            .flatMap(\.results)
            .compactMap(\.delayMilliseconds)
        return values.min().map(String.init)
            ?? AppLocalization.string("Not measured")
    }

    private var bestLatencyUnit: LocalizedStringKey {
        let values = tunnel.proxyLatencies.values
            .flatMap(\.results)
            .compactMap(\.delayMilliseconds)
        return values.isEmpty ? "" : "ms"
    }

    @ViewBuilder
    private var activeNodeCard: some View {
        if tunnel.isConnected,
           let summary = tunnel.activeProfileSummary,
           let primaryGroup = summary.proxyGroups.first(where: { $0.strategy.lowercased() == "select" }) ?? summary.proxyGroups.first,
           let activeNode = tunnel.proxySelections[primaryGroup.name]?.selectedMember {
            let protocolName = summary.proxies.first(where: { $0.name == activeNode })?.protocolName ?? "PROXY"
            let latencyResult = tunnel.proxyLatencies[primaryGroup.name]?.results.first(where: { $0.member == activeNode })?.delayMilliseconds
            let flagInfo = AetherRegionFlag.flagAndRegion(from: activeNode)

            HStack(spacing: AetherVisual.sRow) {
                // 国旗与图标融合
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Text(flagInfo.flag)
                        .font(.system(size: 18))
                        .accessibilityHidden(true)
                }
                .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    HStack(spacing: AetherVisual.sCompact) {
                        Text(primaryGroup.name)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.primary)
                            .textCase(.uppercase)

                        AetherProtocolBadge(type: protocolName)

                        Text(flagInfo.region)
                            .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, AetherVisual.s1)
                            .padding(.vertical, AetherVisual.sMicro)
                            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))
                    }

                    Text(activeNode)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer()

                HStack(spacing: AetherVisual.s3) {
                    if let ms = latencyResult {
                        AetherLatencyPill(latency: Int(ms))
                    }

                    Button {
                        NotificationCenter.default.post(
                            name: .aetherRouteNavigateToSection,
                            object: AppSection.proxies.rawValue
                        )
                    } label: {
                        HStack(spacing: AetherVisual.s1) {
                            Text(AppLocalization.string("Switch"))
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .bold))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(AetherVisual.s4)
            .aetherPanel()
        }
    }
}

private struct ConnectionRecoveryCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let plan: ConnectionRecoveryPlan
    let openProfiles: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text("Recovery Assistant")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(recoveryDetail)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AetherVisual.s2)

            HStack(spacing: AetherVisual.s2) {
                recoveryButton(plan.primaryAction, prominent: true)
                if let secondaryAction = plan.secondaryAction {
                    recoveryButton(secondaryAction, prominent: false)
                }
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .background(
            Color.orange.opacity(0.06),
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.2), lineWidth: 1)
        }
        .accessibilityIdentifier("connection-recovery-card")
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

    @ViewBuilder
    private func recoveryButton(
        _ action: ConnectionRecoveryAction,
        prominent: Bool
    ) -> some View {
        let button = Button {
            perform(action)
        } label: {
            Label(actionTitle(action), systemImage: actionSymbol(action))
        }
        .controlSize(.large)
        .accessibilityIdentifier("recovery-\(action.rawValue)")

        if prominent {
            button.buttonStyle(.borderedProminent)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private func perform(_ action: ConnectionRecoveryAction) {
        switch action {
        case .retry:
            Task { await tunnel.setEnabled(true) }
        case .reviewProfiles:
            openProfiles()
        }
    }

    private func actionTitle(_ action: ConnectionRecoveryAction) -> String {
        switch action {
        case .retry: AppLocalization.string("Retry Connection")
        case .reviewProfiles: AppLocalization.string("Review Profiles")
        }
    }

    private func actionSymbol(_ action: ConnectionRecoveryAction) -> String {
        switch action {
        case .retry: "arrow.clockwise"
        case .reviewProfiles: "doc.badge.gearshape"
        }
    }
}

private struct ConnectionHero: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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

    private var connectionIdentity: some View {
        HStack(spacing: AetherVisual.s4) {
            AetherRouteStatusLens(
                size: 54,
                isActive: tunnel.isConnected,
                isConnecting: tunnel.state == .connecting || tunnel.isSwitchingNetworkEngine
            )

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                HStack(spacing: AetherVisual.s2) {
                    AetherStatusBeacon(
                        isConnected: tunnel.isConnected,
                        isConnecting: tunnel.state == .connecting || tunnel.isSwitchingNetworkEngine,
                        size: 7
                    )
                    Text(stateBadgeTitle)
                        .foregroundStyle(.primary)
                        .font(.caption.weight(.semibold))
                        .contentTransition(.opacity)
                }
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s2)
                .background(
                    stateBadgeBackground,
                    in: Capsule()
                )
                .overlay {
                    Capsule()
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
                .accessibilityHidden(true)

                Text(tunnel.statusTitle)
                    .font(.title.weight(.semibold))
                    .tracking(-0.45)
                    .foregroundStyle(.primary)
                    .contentTransition(.opacity)
                    .accessibilityValue(Text(tunnel.statusDetail))
                Text(tunnel.statusDetail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .accessibilityHidden(true)
                Label(nextStep, systemImage: nextStepSymbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateBadgeTitle: String {
        if tunnel.systemExtensionApprovalRequired {
            return AppLocalization.string("Approval needed")
        }
        if tunnel.isSwitchingNetworkEngine {
            return AppLocalization.string("Switching network engine…")
        }
        return switch tunnel.state {
        case .privacyConsentRequired: AppLocalization.string("Privacy")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected: AppLocalization.string("Standby")
        case .connecting: AppLocalization.string("Starting")
        case .recovering: AppLocalization.string("Recovering network")
        case .connected where tunnel.isAutomaticRouteRecovering:
            AppLocalization.string("Recovering")
        case .connected: AppLocalization.string("Protected")
        case .disconnecting: AppLocalization.string("Stopping")
        case .failed: AppLocalization.string("Attention")
        }
    }

    private var stateBadgeBackground: Color {
        Color(nsColor: .controlBackgroundColor)
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
            AppLocalization.string("Readiness checks passed. Open Connections for per-flow details.")
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Routing mode"))
                    .font(.system(size: 12, weight: .semibold))
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
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                Text(AppLocalization.string("Network engine"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.primary)
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
private struct NetworkEngineSegmentedControl: NSViewRepresentable {
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
        control.isEnabled = isEnabled
        // The engine names have very different lengths. Equal segments waste
        // the short TUN segment's space and overflow with longer translations.
        control.segmentDistribution = .fillProportionally
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
            selection.wrappedValue = modes[sender.selectedSegment]
        }
    }
}
#endif

private struct RoutingModeSegmentedControl: NSViewRepresentable {
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
        control.isEnabled = isEnabled
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
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(caption)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(value)
                    .font(.system(size: 12.5, weight: .semibold))
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
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                }
                .frame(maxWidth: 36)
            } else {
                VStack(spacing: AetherVisual.sMicro) {
                    Rectangle()
                        .fill(Color.accentColor.opacity(0.3))
                        .frame(width: 1.5, height: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.accentColor.opacity(0.55))
                }
                .frame(height: 14)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct MetricTile: View {
    let label: LocalizedStringKey
    let value: String
    let unit: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                Text(value)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s5)
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
    let unit: LocalizedStringKey
    let symbol: String
    let metric: LiveTelemetryMetricKind
    let isConnected: Bool
    let telemetry: NetworkTelemetryViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                LiveTelemetryMetricValue(
                    metric: metric,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s5)
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
/// rather than as a failure.
private struct SafetyNotice: View {
    let quality: ConnectionQuality

    var body: some View {
        HStack(alignment: .top, spacing: AetherVisual.s3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: quality == .verifying)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .accessibilityHint(Text(detail))
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AetherVisual.s1)
        .padding(.vertical, AetherVisual.s2)
        .animation(
            AetherVisual.animation(AetherVisual.gentleSpring),
            value: quality
        )
    }

    private var symbol: String {
        switch quality {
        case .unknown: "lock.shield"
        case .verifying: "gauge.with.dots.needle.bottom.50percent"
        case .verified: "checkmark.shield"
        case .degraded: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch quality {
        case .unknown, .verifying: Color.accentColor
        case .verified: .green
        case .degraded: .orange
        }
    }

    private var title: LocalizedStringKey {
        switch quality {
        case .unknown: "Verified connection status"
        case .verifying: "Checking route quality"
        case .verified: "Route verified"
        case .degraded: "Route is slow"
        }
    }

    private var detail: LocalizedStringKey {
        switch quality {
        case .unknown:
            "Traffic is routed as soon as the network extension installs its settings."
        case .verifying:
            "You are already online. AetherRoute is measuring the selected route in the background."
        case .verified:
            "The selected route answered the latency and data-plane checks."
        case .degraded:
            "You are still connected. The selected route was slow to answer, and AetherRoute keeps looking for a faster node."
        }
    }
}


/// Observe high-frequency updates only where the waveform is drawn.
private struct LiveTrafficHistoryGraph: View {
    @ObservedObject var model: NetworkTelemetryViewModel
    let isRealtime: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 3, paused: !isRealtime)) { context in
            let now = isRealtime ? context.date : Date()
            let samples = model.history.visible(at: now)
            AetherTrafficMiniGraph(
                downloadSamples: samples.map(\.download),
                uploadSamples: samples.map(\.upload),
                samplePositions: samples.map { TrafficHistory.position(of: $0, at: now) },
                height: 44
            )
        }
    }
}

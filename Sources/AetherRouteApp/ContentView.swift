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
                showsTitle: false
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
                            isConnecting: tunnel.state == .connecting,
                            size: 6
                        )
                        Text(tunnel.isConnected ? AppLocalization.string("Protected") : AppLocalization.string("Idle"))
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
                Image(systemName: "power")
                Text(tunnel.primaryActionTitle)
            }
                .font(.body.weight(.semibold))
                .frame(minWidth: 116)
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
        case .connected: AppLocalization.string("Disconnects the secure connection")
        case .failed: AppLocalization.string("Retries the secure connection")
        default: AppLocalization.string("Starts the secure connection")
        }
    }

}

private struct OverviewView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let openProfiles: () -> Void
    @State private var isSubscriptionEditorPresented = false
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

                        Text(AppLocalization.string(tunnel.isRealtimeTelemetryPreferred ? "Refresh: every 1 second" : "Refresh: every 10 seconds"))
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
            } else if tunnel.state == .connecting {
                ConnectionProgressStages()
            }
        }
        .padding(AetherVisual.s5)
        .frame(maxWidth: .infinity)
        .aetherHeroPanel()
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
            AetherRouteStatusLens(size: 54, isActive: tunnel.isConnected)

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(stateBadgeTitle)
                    .foregroundStyle(.primary)
                    .font(.caption.weight(.semibold))
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
                    .accessibilityValue(Text(tunnel.statusDetail))
                Text(tunnel.statusDetail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
                Label(nextStep, systemImage: nextStepSymbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateBadgeTitle: String {
        if tunnel.systemExtensionApprovalRequired {
            return AppLocalization.string("Approval needed")
        }
        return switch tunnel.state {
        case .privacyConsentRequired: AppLocalization.string("Privacy")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected: AppLocalization.string("Standby")
        case .connecting: AppLocalization.string("Starting")
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
        return switch tunnel.state {
        case .connected where tunnel.isAutomaticRouteRecovering:
            "arrow.triangle.2.circlepath"
        case .connected: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .connecting, .disconnecting, .loading: "clock"
        case .privacyConsentRequired: "hand.raised.fill"
        case .disconnected: "arrow.right.circle"
        }
    }
}

/// Makes the fail-closed wait legible: the extension has to clear four steps
/// before this app will report "connected", and this draws which one is
/// running right now. Every value here is derived from the live provider
/// status — nothing is scripted.
private struct ConnectionProgressStages: View {
    @EnvironmentObject private var tunnel: TunnelManager

    /// The steps that stand between pressing Connect and carrying traffic.
    ///
    /// Route readiness is deliberately absent: it now runs after the tunnel is
    /// already usable, so showing it here would have described the connection
    /// as unfinished while traffic was already flowing. `SafetyNotice` reports
    /// route quality once these three are done.
    private static let stages: [(ConnectionStage, String)] = [
        (.systemAuthorization, "System authorization"),
        (.extensionStartup, "Extension startup"),
        (.protocolHandshake, "Protocol handshake"),
    ]

    var body: some View {
        let current = tunnel.connectionStage

        HStack(spacing: AetherVisual.s2) {
            ForEach(Array(Self.stages.enumerated()), id: \.offset) { index, stage in
                let position = position(of: stage.0, relativeTo: current)

                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: symbol(for: position))
                        .font(.caption.weight(.semibold))
                    Text(LocalizedStringKey(stage.1))
                        .font(.caption2.weight(position == .current ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
                .foregroundStyle(tint(for: position))
                .fixedSize(horizontal: false, vertical: true)

                if index < Self.stages.count - 1 {
                    Rectangle()
                        .fill(connectorTint(after: stage.0, current: current))
                        .frame(minWidth: AetherVisual.s2, maxWidth: .infinity)
                        .frame(height: 1)
                }
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Connection progress")
        .accessibilityValue(LocalizedStringKey(currentStageLabel(current)))
    }

    private enum StagePosition {
        case complete
        case current
        case pending
    }

    private func position(
        of stage: ConnectionStage,
        relativeTo current: ConnectionStage
    ) -> StagePosition {
        if stage.rawValue < current.rawValue { return .complete }
        if stage == current { return .current }
        return .pending
    }

    private func symbol(for position: StagePosition) -> String {
        switch position {
        case .complete: "checkmark.circle.fill"
        case .current: "circle.dotted"
        case .pending: "circle"
        }
    }

    /// Three status colors only, per the color-semantics rule: done is green,
    /// in-flight needs attention so it is orange, not-yet is idle.
    private func tint(for position: StagePosition) -> Color {
        switch position {
        case .complete: .green
        case .current: .orange
        case .pending: .secondary
        }
    }

    private func connectorTint(
        after stage: ConnectionStage,
        current: ConnectionStage
    ) -> AnyShapeStyle {
        if stage.rawValue < current.rawValue - 1 {
            return AnyShapeStyle(Color.green)
        }
        if stage.rawValue == current.rawValue - 1 {
            // The segment feeding the running step fades out, so the eye lands
            // on where progress has actually reached.
            return AnyShapeStyle(
                LinearGradient(
                    colors: [.green, Color(nsColor: .separatorColor)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(Color(nsColor: .separatorColor))
    }

    private func currentStageLabel(
        _ current: ConnectionStage
    ) -> String {
        Self.stages.first { $0.0 == current }?.1 ?? ""
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

private struct EmptyProfileOnboardingCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let onAddSubscription: () -> Void
    let onImportProfile: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s4) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), Color.blue.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Welcome to AetherRoute"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(AppLocalization.string("Import a subscription URL or configuration file to get started with high-speed, secure routing."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack(spacing: AetherVisual.s3) {
                Button {
                    onAddSubscription()
                } label: {
                    HStack(spacing: AetherVisual.sCompact) {
                        Image(systemName: "link.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text(AppLocalization.string("Add Subscription…"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, AetherVisual.s1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-add-subscription-button")

                Button {
                    onImportProfile()
                } label: {
                    HStack(spacing: AetherVisual.sCompact) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                        Text(AppLocalization.string("Import Profile…"))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-import-profile-button")

                Spacer()
            }

            Divider().opacity(0.35)

            HStack(spacing: AetherVisual.s2) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(AppLocalization.string("Supports Clash YAML/Meta, V2Ray/Base64 share links (VMess, VLESS, Trojan, SS, Hysteria2), automatic latency testing, and smart rule routing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(AetherVisual.s5)
        .aetherPanel()
        .accessibilityIdentifier("empty-profile-onboarding-card")
    }
}

private struct ExternalSubscriptionConfirmationSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    let request: ExternalSubscriptionImportRequest
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .background(
                        Color.accentColor.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius)
                    )

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Review Subscription Link")
                        .font(.title2.weight(.semibold))
                    Text("AetherRoute has not downloaded or changed anything yet.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text("Address")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(request.providerHost, systemImage: "lock.fill")
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("external-subscription-host")
                Text("AetherRoute will not access this address until you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(AetherVisual.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
            )

            Label(
                "If you continue, AetherRoute will make one HTTPS request, validate the size and contents, store the subscription in encrypted profile storage, and activate it.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !tunnel.canImportOrAddProfileRegardlessOfPrivacy {
                Label(
                    AppLocalization.string("Wait for current profile operations to finish before importing."),
                    systemImage: "hourglass"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else if tunnel.isEnabled {
                Label(
                    AppLocalization.string("The subscription will be downloaded and safely added to your profile library without interrupting your connection."),
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if !tunnel.hasAcceptedPrivacyDisclosure {
                Label(
                    AppLocalization.string("Confirming will accept the network privacy review and activate this subscription."),
                    systemImage: "checkmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if tunnel.profileMessageIsError,
               let message = tunnel.profileMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    tunnel.cancelExternalSubscriptionImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    isConfirming = true
                    Task {
                        if await tunnel.confirmExternalSubscriptionImport(
                            id: request.id
                        ) {
                            dismiss()
                        } else {
                            isConfirming = false
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        tunnel.isEnabled ? "Download and Save" : "Download and Enable",
                        isWorking: isConfirming
                            || tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !tunnel.canImportOrAddProfileRegardlessOfPrivacy
                        || isConfirming
                        || tunnel.isRefreshingSubscription
                )
                .accessibilityIdentifier("confirm-external-subscription")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 540)
        .interactiveDismissDisabled(isConfirming)
    }
}

private struct ProfilesView: View {
    private enum FileImporterKind {
        case profile
        case portableArchive
        case routingResource

        var allowedContentTypes: [UTType] {
            switch self {
            case .profile:
                [.plainText, .data]
            case .portableArchive:
                [.aetherRouteProfileArchive, .data]
            case .routingResource:
                [.data]
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var fileImporterKind: FileImporterKind = .profile
    @State private var isFileImporterPresented = false
    @State private var isManualNodeEditorPresented = false
    @State private var isSubscriptionEditorPresented = false
    @State private var subscriptionURL = ""
    @State private var profileToRename: ManagedProfile?
    @State private var nativeProfileToEdit: ManagedProfile?
    @State private var isArchivePasswordPresented = false
    @State private var isArchiveExporterPresented = false
    @State private var isExportPasswordPresented = false
    @State private var routingResourceImportKind: RoutingResourceKind?
    @State private var archiveImportURL: URL?
    @State private var pendingArchiveData: Data?
    @State private var archiveDocument = ProfileArchiveDocument()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                pageHeader

                if let message = tunnel.profileMessage, !tunnel.isImportingProfile {
                    profileMessageBanner(message: message, isError: tunnel.profileMessageIsError)
                }

                if tunnel.isImportingProfile {
                    importProgressCard
                }

                if tunnel.profiles.isEmpty {
                    emptyOnboardingSection
                } else {
                    if let active = tunnel.activeProfile {
                        activeProfileHeroCard(active: active)
                    }

                    profileLibraryCard

                    if !tunnel.requiredRoutingResources.isEmpty {
                        RoutingResourcesCard(
                            importResource: { kind in
                                routingResourceImportKind = kind
                                presentFileImporter(.routingResource)
                            }
                        )
                        .environmentObject(tunnel)
                    }
                }

                supportedFormatsCard
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImporterKind.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result, kind: fileImporterKind)
        }
        .fileExporter(
            isPresented: $isArchiveExporterPresented,
            document: archiveDocument,
            contentType: .aetherRouteProfileArchive,
            defaultFilename: "AetherRoute-Profiles"
        ) { result in
            switch result {
            case .success:
                tunnel.reportPortableArchiveSaved()
            case let .failure(error):
                tunnel.reportProfileImportError(error)
            }
        }
        .sheet(isPresented: $isSubscriptionEditorPresented) {
            SubscriptionEditorSheet(urlText: $subscriptionURL)
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $isManualNodeEditorPresented) {
            ManualNodeEditorSheet()
                .environmentObject(tunnel)
        }
        .sheet(item: $profileToRename) { managed in
            ProfileRenameSheet(profile: managed) { name in
                await tunnel.renameProfile(id: managed.id, name: name)
            }
        }
        .sheet(item: $nativeProfileToEdit) { managed in
            NativeProfileEditorSheet(profile: managed)
                .environmentObject(tunnel)
        }
        .sheet(
            isPresented: $isExportPasswordPresented,
            onDismiss: presentPendingArchiveExporter
        ) {
            ProfileArchivePasswordSheet(mode: .export) { password in
                guard let data = await tunnel.makePortableArchive(
                    password: password
                ) else {
                    return false
                }
                pendingArchiveData = data
                return true
            }
        }
        .sheet(isPresented: $isArchivePasswordPresented) {
            ProfileArchivePasswordSheet(mode: .import) { password in
                guard let archiveImportURL else { return false }
                let imported = await tunnel.importPortableArchive(
                    from: archiveImportURL,
                    password: password
                )
                if imported { self.archiveImportURL = nil }
                return imported
            }
        }
        .accessibilityIdentifier("profiles-page")
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text("Profiles")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Manage proxy subscriptions, local files, and routing profiles."))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s2)

            HStack(spacing: AetherVisual.s2) {
                Button("Add Subscription…", systemImage: "link.badge.plus") {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    isSubscriptionEditorPresented = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!tunnel.canImportOrAddProfile)
                .accessibilityIdentifier("add-subscription")

                Button("Import Profile…", systemImage: "square.and.arrow.down") {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!tunnel.canImportOrAddProfile)

                Menu("More", systemImage: "ellipsis.circle") {
                    Button("Add Node…", systemImage: "plus") {
                        tunnel.clearProfileMessage()
                        isManualNodeEditorPresented = true
                    }
                    .disabled(!tunnel.canImportOrAddProfile)

                    Divider()

                    Button("Export Portable Archive…", systemImage: "square.and.arrow.up") {
                        tunnel.clearProfileMessage()
                        isExportPasswordPresented = true
                    }
                    .disabled(tunnel.profiles.isEmpty || tunnel.isTransferringProfiles)

                    Button("Import Portable Archive…", systemImage: "square.and.arrow.down") {
                        tunnel.clearProfileMessage()
                        presentFileImporter(.portableArchive)
                    }
                    .disabled(!tunnel.canModifyProfiles)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("profiles-more-menu")
            }
        }
        .padding(.bottom, AetherVisual.s1)
    }

    private func profileMessageBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isError ? Color.orange : Color.green)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: AetherVisual.s2)

            Button {
                tunnel.clearProfileMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .background(
            (isError ? Color.orange : Color.green).opacity(0.08),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                .stroke((isError ? Color.orange : Color.green).opacity(0.2), lineWidth: 0.5)
        }
    }

    private var importProgressCard: some View {
        HStack(spacing: AetherVisual.s3) {
            ProgressView()
                .controlSize(.small)
            Text("Importing profile…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: AetherVisual.s2)
            Button("Cancel", role: .cancel) {
                tunnel.cancelProfileImport()
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s4)
        .aetherPanel()
        .accessibilityIdentifier("profile-import-progress")
    }

    private var emptyOnboardingSection: some View {
        VStack(spacing: AetherVisual.s5) {
            VStack(spacing: AetherVisual.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), Color.blue.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 60, height: 60)
                .padding(.top, AetherVisual.s3)

                Text(AppLocalization.string("No Profiles Added"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Add a subscription link or import a Clash-compatible configuration to get started."))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: AetherVisual.s4) {
                Button {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    isSubscriptionEditorPresented = true
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.blue.opacity(0.12))
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.blue)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(AppLocalization.string("Add Subscription…"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(AppLocalization.string("Import HTTPS subscription URL from your provider."))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AetherVisual.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.indigo.opacity(0.12))
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.indigo)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(AppLocalization.string("Import Profile…"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(AppLocalization.string("Supports Clash-compatible YAML/JSON profiles."))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AetherVisual.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, AetherVisual.s2)

            HStack(spacing: AetherVisual.s5) {
                Label(AppLocalization.string("Encrypted on this Mac"), systemImage: "lock.shield.fill")
                Label(AppLocalization.string("Clash Compatible"), systemImage: "checkmark.circle.fill")
                Label(AppLocalization.string("Multi-Protocol"), systemImage: "bolt.horizontal.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.bottom, AetherVisual.s2)
        }
        .padding(AetherVisual.s6)
        .aetherPanel()
    }

    private func activeProfileHeroCard(active: ActiveProfile) -> some View {
        let isSubscription = active.subscription != nil
        return VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: isSubscription
                                    ? [Color.blue.opacity(0.20), Color.cyan.opacity(0.08)]
                                    : [Color.teal.opacity(0.20), Color.green.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: isSubscription ? "link.circle.fill" : "doc.badge.gearshape.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSubscription ? Color.blue : Color.teal)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    HStack(spacing: AetherVisual.s2) {
                        Text(active.name)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)

                        HStack(spacing: AetherVisual.s1) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("In Use")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, AetherVisual.s2)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }

                    HStack(spacing: AetherVisual.s1) {
                        Text(isSubscription ? AppLocalization.string("HTTPS subscription") : AppLocalization.string("Local profile"))
                            .font(.caption)
                            .foregroundStyle(.primary)

                        Text(verbatim: "·")
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .accessibilityHidden(true)

                        Text(String.localizedStringWithFormat(
                            AppLocalization.string("Activated %@"),
                            AppLocalization.date(active.importedAt, date: .abbreviated, time: .shortened)
                        ))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    }
                }

                Spacer(minLength: AetherVisual.s2)

                if isSubscription {
                    Button {
                        Task { await tunnel.refreshSubscription() }
                    } label: {
                        AetherProgressButtonLabel(
                            "Check for Updates",
                            systemImage: "arrow.clockwise",
                            isWorking: tunnel.isRefreshingSubscription
                        )
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!tunnel.canModifyProfiles || tunnel.isRefreshingSubscription)
                }
            }

            if let subscription = active.subscription {
                Divider()
                    .opacity(0.4)

                HStack(spacing: AetherVisual.s3) {
                    Label(
                        subscriptionUpdateDetail(subscription),
                        systemImage: "clock"
                    )
                    .font(.caption2)
                    .foregroundStyle(.primary)

                    if let lastCheckedAt = subscription.lastCheckedAt {
                        Spacer(minLength: AetherVisual.s2)
                        Text(String.localizedStringWithFormat(
                            AppLocalization.string("Checked %@"),
                            AppLocalization.date(lastCheckedAt, date: .abbreviated, time: .shortened)
                        ))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
    }

    private var profileLibraryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: AetherVisual.s2) {
                    Text("Profile Library")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(verbatim: "\(tunnel.profiles.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                Spacer()

                Label("Encrypted on this Mac", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, AetherVisual.s5)
            .padding(.vertical, AetherVisual.s4)

            Divider()
                .padding(.horizontal, AetherVisual.s5)

            ForEach(Array(tunnel.profiles.enumerated()), id: \.element.id) { index, managed in
                ManagedProfileRow(
                    managed: managed,
                    isActive: managed.id == tunnel.activeProfileID,
                    canActivate: tunnel.canActivateProfile,
                    canModify: tunnel.canModifyProfiles,
                    activate: {
                        Task { await tunnel.activateProfile(id: managed.id) }
                    },
                    rename: {
                        profileToRename = managed
                    },
                    editNative: managed.profile.nativeNodes == nil ? nil : { nativeProfileToEdit = managed },
                    remove: {
                        Task { await tunnel.removeProfile(id: managed.id) }
                    }
                )

                if index < tunnel.profiles.count - 1 {
                    Divider()
                        .padding(.leading, AetherVisual.tableContentIndent)
                        .padding(.trailing, AetherVisual.s5)
                }
            }
        }
        .aetherPanel()
    }

    private var supportedFormatsCard: some View {
        HStack(spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.teal.opacity(0.12))
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.teal)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.string("Supported formats"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Supports Clash-compatible YAML/JSON profiles, HTTPS subscriptions, and common node links."))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AetherVisual.s2)
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
    }

    private func subscriptionUpdateDetail(_ subscription: ProfileSubscription) -> String {
        guard let interval = subscription.autoUpdateInterval else {
            return AppLocalization.string("HTTPS subscription · manual updates")
        }
        let hours = max(1, Int(interval / 3_600))
        return String.localizedStringWithFormat(
            AppLocalization.string("HTTPS subscription · updates every %lld hours"),
            Int64(hours)
        )
    }

    private func presentFileImporter(_ kind: FileImporterKind) {
        fileImporterKind = kind
        isFileImporterPresented = true
    }

    private func handleFileImport(
        _ result: Result<[URL], any Error>,
        kind: FileImporterKind
    ) {
        switch (kind, result) {
        case let (.profile, .success(urls)):
            guard let url = urls.first else { return }
            tunnel.importProfile(from: url)
        case let (.portableArchive, .success(urls)):
            guard let url = urls.first else { return }
            archiveImportURL = url
            Task { @MainActor in
                await Task.yield()
                isArchivePasswordPresented = true
            }
        case let (.routingResource, .success(urls)):
            guard let kind = routingResourceImportKind,
                  let url = urls.first else { return }
            routingResourceImportKind = nil
            Task {
                await tunnel.importRoutingResource(kind, from: url)
            }
        case let (_, .failure(error)):
            routingResourceImportKind = nil
            tunnel.reportProfileImportError(error)
        }
    }

    private func presentPendingArchiveExporter() {
        guard let pendingArchiveData else { return }
        archiveDocument = ProfileArchiveDocument(data: pendingArchiveData)
        self.pendingArchiveData = nil
        isArchiveExporterPresented = true
    }
}

private struct RoutingResourcesCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let importResource: (RoutingResourceKind) -> Void

    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                Image(systemName: resourcesAreReady ? "checkmark.shield" : "map")
                    .font(.title3)
                    .foregroundStyle(resourcesAreReady ? Color.teal : Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Routing rules")
                        .font(.headline)
                    Text(summary)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("routing-rules-summary")
                }
                Spacer(minLength: 0)

                if tunnel.isUpdatingRoutingResources {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing routing rules…")
                } else if tunnel.routingResourceMessageIsError {
                    Button("Retry") {
                        Task { await tunnel.prepareRequiredRoutingResources() }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!tunnel.canModifyProfiles)
                    .accessibilityIdentifier("retry-routing-rules")
                }
            }

            Button {
                showsAdvanced.toggle()
            } label: {
                HStack(spacing: AetherVisual.s1) {
                    Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
                    Text("Advanced")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routing-rules-advanced")
            .accessibilityAddTraits(showsAdvanced ? .isSelected : [])

            if showsAdvanced {
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    ForEach(tunnel.requiredRoutingResources, id: \.self) { kind in
                        resourceRow(kind)
                    }

                    if let message = tunnel.routingResourceMessage {
                        Label(
                            message,
                            systemImage: tunnel.routingResourceMessageIsError
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(
                            tunnel.routingResourceMessageIsError
                                ? Color.red : Color.secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await tunnel.downloadRequiredRoutingResources() }
                    } label: {
                        AetherProgressButtonLabel(
                            "Download & Verify",
                            systemImage: "arrow.down.shield",
                            isWorking: tunnel.isUpdatingRoutingResources
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !tunnel.canModifyProfiles
                            || tunnel.isUpdatingRoutingResources
                    )

                    Text("Bundled rules use DB-IP Lite and V2Fly data. Country rule updates may use MaxMind data through Loyalsoldier. See Open-Source Software for sources and licenses.")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-resources-card")
    }

    private var resourcesAreReady: Bool {
        tunnel.requiredRoutingResources.allSatisfy { kind in
            tunnel.routingResourceStatuses[kind]?.isUsableForConnection == true
        }
    }

    private var summary: String {
        if tunnel.isUpdatingRoutingResources {
            return AppLocalization.string("Preparing routing rules…")
        }
        if tunnel.routingResourceMessageIsError {
            return AppLocalization.string("Routing rules need attention. Try preparing them again.")
        }
        return AppLocalization.string(
            resourcesAreReady
                ? "Routing rules are ready."
                : "AetherRoute prepares routing rules automatically when you connect."
        )
    }

    private func resourceRow(_ kind: RoutingResourceKind) -> some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: resourceSymbol(kind))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(resourceColor(kind))
                .frame(width: 42, height: 42)
                .background(
                    resourceColor(kind).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                )

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(kind.fileName)
                    .font(.body.weight(.medium))
                Text(resourceStatusTitle(kind))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s3)

            Button("Import…", systemImage: "square.and.arrow.down") {
                importResource(kind)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                !tunnel.canModifyProfiles
                    || tunnel.isUpdatingRoutingResources
            )
        }
        .padding(.horizontal, AetherVisual.s5)
        .padding(.vertical, AetherVisual.s3)
    }

    private func resourceStatusTitle(_ kind: RoutingResourceKind) -> String {
        guard let status = tunnel.routingResourceStatuses[kind] else {
            return AppLocalization.string("Checking…")
        }
        switch status {
        case .missing:
            return AppLocalization.string("Required · not installed")
        case let .ready(record):
            return String.localizedStringWithFormat(
                AppLocalization.string("Verified · updated %@"),
                AppLocalization.date(
                    record.installedAt,
                    date: .abbreviated,
                    time: .omitted
                )
            )
        case let .stale(record):
            return String.localizedStringWithFormat(
                AppLocalization.string(
                    status.isUsableForConnection
                        ? "Update recommended · %@"
                        : "Update required · %@"
                ),
                AppLocalization.date(
                    record.installedAt,
                    date: .abbreviated,
                    time: .omitted
                )
            )
        case .invalid:
            return AppLocalization.string("Invalid · replace before connecting")
        }
    }

    private func resourceColor(_ kind: RoutingResourceKind) -> Color {
        switch tunnel.routingResourceStatuses[kind] {
        case .ready?: .teal
        case .stale?, .invalid?: .orange
        case .missing?, nil: .blue
        }
    }

    private func resourceSymbol(_ kind: RoutingResourceKind) -> String {
        switch tunnel.routingResourceStatuses[kind] {
        case .ready?: "checkmark.shield.fill"
        case .stale?: "clock.badge.exclamationmark"
        case .invalid?: "exclamationmark.shield.fill"
        case .missing?, nil: "arrow.down.doc.fill"
        }
    }
}

private struct ManagedProfileRow: View {
    @State private var isHovered = false
    @State private var isActionHovered = false
    let managed: ManagedProfile
    let isActive: Bool
    let canActivate: Bool
    let canModify: Bool
    let activate: () -> Void
    let rename: () -> Void
    let editNative: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(iconGradient)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(managed.profile.name)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isActive {
                        HStack(spacing: AetherVisual.s1) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("In Use")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, AetherVisual.s2)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: AetherVisual.s2)

            if !isActive {
                Button(AppLocalization.string("Use"), action: activate)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canActivate)
                    .accessibilityIdentifier("activate-profile-\(managed.id.uuidString)")
            }

            Menu {
                if let editNative {
                    Button(action: editNative) {
                        Label(AppLocalization.string("Edit Nodes…"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(!canModify)
                }

                Button(action: rename) {
                    Label(AppLocalization.string("Rename…"), systemImage: "pencil")
                }
                .disabled(!canModify)

                if !isActive {
                    Divider()
                    Button(role: .destructive, action: remove) {
                        Label(AppLocalization.string("Remove Profile"), systemImage: "trash")
                    }
                    .disabled(!canModify)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActionHovered ? Color.primary : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(isActionHovered ? Color.secondary.opacity(0.18) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .onHover { isActionHovered = $0 }
            .accessibilityLabel("Profile actions")
            .accessibilityIdentifier("profile-actions-\(managed.id.uuidString)")
        }
        .padding(.horizontal, AetherVisual.s5)
        .padding(.vertical, AetherVisual.sRow)
        .background(isHovered ? Color.primary.opacity(0.03) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .contextMenu {
            if !isActive {
                Button(action: activate) {
                    Label(AppLocalization.string("Use"), systemImage: "play.circle")
                }
                .disabled(!canActivate)
                Divider()
            }
            if let editNative {
                Button(action: editNative) {
                    Label(AppLocalization.string("Edit Nodes…"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(!canModify)
            }
            Button(action: rename) {
                Label(AppLocalization.string("Rename…"), systemImage: "pencil")
            }
            .disabled(!canModify)
            if !isActive {
                Divider()
                Button(role: .destructive, action: remove) {
                    Label(AppLocalization.string("Remove Profile"), systemImage: "trash")
                }
                .disabled(!canModify)
            }
        }
    }

    private var isSubscription: Bool {
        managed.profile.subscription != nil
    }

    private var iconName: String {
        if isSubscription {
            return "link"
        }
        if managed.profile.nativeNodes != nil {
            return "point.3.connected.trianglepath.dotted"
        }
        return "doc.text.fill"
    }

    private var iconTint: Color {
        if isSubscription {
            return .blue
        }
        if managed.profile.nativeNodes != nil {
            return .orange
        }
        return .teal
    }

    private var iconGradient: LinearGradient {
        LinearGradient(
            colors: [iconTint.opacity(0.18), iconTint.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var detail: String {
        let source = isSubscription
            ? AppLocalization.string("HTTPS subscription")
            : (managed.profile.nativeNodes != nil
                ? AppLocalization.string("Manual nodes")
                : AppLocalization.string("Local profile"))
        let importedAt = AppLocalization.date(
            managed.profile.importedAt,
            date: .abbreviated,
            time: .omitted
        )
        return "\(source) · \(importedAt)"
    }
}

private struct ProfileRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ManagedProfile
    let save: (String) async -> Bool
    @State private var name: String
    @State private var isSaving = false

    init(
        profile: ManagedProfile,
        save: @escaping (String) async -> Bool
    ) {
        self.profile = profile
        self.save = save
        _name = State(initialValue: profile.profile.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text("Rename Profile")
                    .font(.title2.weight(.semibold))
                Text("Choose a short name that is easy to recognize in the menu bar.")
                    .foregroundStyle(.secondary)
            }

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-name-field")

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if await save(name) { dismiss() }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        "Save",
                        isWorking: isSaving
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSaving
                )
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 460)
    }
}

private struct SubscriptionEditorSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Binding var urlText: String

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            HStack(spacing: AetherVisual.s4) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Add Profile Subscription")
                        .font(.title2.weight(.semibold))
                    Text("Paste the HTTPS address supplied by your trusted provider.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: AetherVisual.s2) {
                TextField("HTTPS subscription URL", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("subscription-url-field")
                    .onChange(of: urlText) { _, value in
                        // Pasted addresses often include a trailing line break.
                        // Normalize the editor as well as the submitted value so
                        // the field never scrolls to an apparently empty line.
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if normalized != value {
                            urlText = normalized
                        }
                    }

                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        urlText = pasted
                    }
                } label: {
                    Label(AppLocalization.string("Paste"), systemImage: "doc.on.clipboard")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("subscription-paste-button")
            }

            if let message = tunnel.profileMessage {
                Label(
                    message,
                    systemImage: tunnel.profileMessageIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(
                    tunnel.profileMessageIsError ? Color.red : Color.green
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("subscription-result-message")
            }

            Group {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
                Label(
                    "The download is size-limited and validated, then kept only for this preview session. It cannot enable system routing.",
                    systemImage: "checkmark.shield"
                )
#else
                Label(
                    "The address is stored inside the encrypted profile. Downloads are size-limited and validated before activation.",
                    systemImage: "lock.shield"
                )
#endif
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task {
                        if await tunnel.addSubscription(urlText: urlText) {
                            dismiss()
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        tunnel.isEnabled ? "Download and Save" : "Download and Activate",
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || tunnel.isRefreshingSubscription
                        || !tunnel.canImportOrAddProfile
                )
                .accessibilityIdentifier("activate-subscription-button")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 540)
        .onAppear {
            if urlText.isEmpty,
               let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               pasted.lowercased().hasPrefix("https://") {
                urlText = pasted
            }
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
        TimelineView(.animation(minimumInterval: 1, paused: !isRealtime)) { context in
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

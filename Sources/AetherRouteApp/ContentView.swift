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

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AetherVisual.s3) {
                AetherRouteBrandTile(size: 34, isActive: tunnel.isConnected)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("AetherRoute")
                        .font(.headline.weight(.semibold))
                        .tracking(-0.15)
                        .foregroundStyle(.primary)
                }
                Spacer()
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.top, AetherVisual.s2)
            .padding(.bottom, AetherVisual.s3)

            Divider()
                .padding(.horizontal, AetherVisual.s3)
                .padding(.bottom, AetherVisual.s2)

            List(selection: sectionSelection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        NavigationLink(value: section) {
                            Label(section.title, systemImage: section.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                            .accessibilityIdentifier(
                                "primary-navigation-\(section.rawValue)"
                            )
                    }
                }

                Section {
                    Text("ACTIVE PROFILE")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                        .accessibilityAddTraits(.isHeader)
                        .listRowSeparator(.hidden)
                        .listRowInsets(
                            EdgeInsets(
                                top: 8,
                                leading: 4,
                                bottom: 0,
                                trailing: 4
                            )
                        )

                    HStack(spacing: AetherVisual.s3) {
                        Image(systemName: "doc.badge.gearshape")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: AetherVisual.s1) {
                            Text(
                                tunnel.activeProfile?.name
                                    ?? AppLocalization.string("No profile")
                                )
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(.primary)
                            Text(
                                tunnel.activeProfile == nil
                                    ? AppLocalization.string("Import required")
                                    : activeProfileStatus
                            )
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .padding(.vertical, AetherVisual.s2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .listRowInsets(
                        EdgeInsets(
                            top: 0,
                            leading: 4,
                            bottom: 0,
                            trailing: 4
                        )
                    )
                    .help(
                        tunnel.activeProfile?.name
                            ?? AppLocalization.string("No profile")
                    )
                    // Keep the profile name and state as separate text nodes.
                    // A single combined SwiftUI node spans the icon as well as
                    // both text rows, which makes macOS sample non-text pixels
                    // when evaluating contrast at large accessibility sizes.
                    .accessibilityElement(children: .contain)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
        }
        .background(Color(nsColor: .windowBackgroundColor))
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

    private var activeProfileStatus: String {
        if tunnel.isUpdatingRoutingResources {
            return AppLocalization.string("Preparing routing rules…")
        }
        return switch tunnel.state {
        case .connecting: AppLocalization.string("Starting")
        case .connected: AppLocalization.string("In use")
        case .disconnecting: AppLocalization.string("Stopping")
        default: AppLocalization.string("Ready to connect")
        }
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

    var body: some View {
        ScrollView {
            VStack(spacing: AetherVisual.s5) {
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
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("overview-page")
    }

    private var overviewDetails: some View {
        VStack(spacing: AetherVisual.s4) {
            RouteSummary()
            if let recoveryPlan = tunnel.recoveryPlan {
                ConnectionRecoveryCard(
                    plan: recoveryPlan,
                    openProfiles: openProfiles
                )
            }
            HStack(spacing: 0) {
                MetricTile(
                    label: "Latency",
                    value: bestLatency,
                    unit: bestLatencyUnit,
                    symbol: "waveform.path.ecg"
                )
                Divider()
                    .frame(height: 52)
                LiveTelemetryMetricTile(
                    label: "Download",
                    unit: "",
                    symbol: "arrow.down",
                    metric: .download,
                    isConnected: tunnel.isConnected,
                    telemetry: tunnel.telemetryViewModel
                )
                Divider().frame(height: 52)
                LiveTelemetryMetricTile(
                    label: "Upload",
                    unit: "",
                    symbol: "arrow.up",
                    metric: .upload,
                    isConnected: tunnel.isConnected,
                    telemetry: tunnel.telemetryViewModel
                )
                Divider().frame(height: 52)
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
            .aetherPanel()
            SafetyNotice()
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
}

private struct ConnectionRecoveryCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let plan: ConnectionRecoveryPlan
    let openProfiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(
                        Color.orange.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius)
                    )

                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    Text("Recovery Assistant")
                        .font(.headline)
                    Text(recoveryDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: AetherVisual.s3) {
                recoveryButton(plan.primaryAction, prominent: true)
                if let secondaryAction = plan.secondaryAction {
                    recoveryButton(secondaryAction, prominent: false)
                }
                Spacer()
                Text("If this repeats, export a privacy-safe report from Settings › Diagnostics.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(AetherVisual.s5)
        .background(
            Color.orange.opacity(0.055),
            in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
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
            button.buttonStyle(.bordered)
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
            if tunnel.state == .connecting {
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
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateBadgeTitle: String {
        switch tunnel.state {
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
        switch tunnel.state {
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
        switch tunnel.state {
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
            HStack(spacing: AetherVisual.s4) { controls }
            VStack(alignment: .leading, spacing: AetherVisual.s3) { controls }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
    }

    @ViewBuilder
    private var controls: some View {
#if AETHERROUTE_INDEPENDENT
        labeledPicker("Network engine") {
            NetworkEngineSegmentedControl(
                selection: Binding(
                    get: { networkEngineMode },
                    set: { mode in selectNetworkEngine(mode) }
                ),
                isEnabled: canChangeNetworkEngine
            )
        }
#endif
        labeledPicker("Routing mode") {
            RoutingModeSegmentedControl(
                selection: Binding(
                    get: { routingMode },
                    set: { mode in selectRoutingMode(mode) }
                ),
                isEnabled: canChangeRoutingMode
            )
        }
    }

    private func labeledPicker<Control: View>(
        _ title: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AetherVisual.s2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.primary)
                .frame(width: 92, alignment: .leading)
            control()
        }
        .frame(maxWidth: .infinity)
    }

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
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            HStack {
                Text("Current route")
                    .font(.headline)
                Spacer()
                Label(routeStatus.title, systemImage: routeStatus.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AetherVisual.s3) {
                    routeStops(horizontal: true)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: AetherVisual.s2) {
                    routeStops(horizontal: false)
                }
            }
        }
        .padding(AetherVisual.s5)
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

            if !tunnel.canModifyProfiles {
                Label(
                    tunnel.hasAcceptedPrivacyDisclosure
                        ? AppLocalization.string("Disconnect before importing this subscription.")
                        : AppLocalization.string("Complete the network privacy review before importing this subscription."),
                    systemImage: "exclamationmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.orange)
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
                        "Download and Enable",
                        isWorking: isConfirming
                            || tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !tunnel.canModifyProfiles
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
                VStack(alignment: .leading, spacing: AetherVisual.s4) {
                    HStack(alignment: .center, spacing: AetherVisual.s4) {
                        VStack(alignment: .leading, spacing: AetherVisual.s1) {
                            Text("Profiles")
                                .font(.title2.weight(.semibold))
                            Text(
                                tunnel.activeProfile?.name
                                    ?? AppLocalization.string("No active profile")
                            )
                                .font(.headline)
                                .foregroundStyle(.primary)
                                .help(
                                    tunnel.activeProfile?.name
                                        ?? AppLocalization.string("No active profile")
                                )
                            Text(profileDetail)
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    HStack(spacing: AetherVisual.s2) {
                        Button("Add Subscription…", systemImage: "link.badge.plus") {
                            tunnel.clearProfileMessage()
                            subscriptionURL = ""
                            isSubscriptionEditorPresented = true
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!tunnel.canModifyProfiles)
                        .accessibilityIdentifier("add-subscription")

                        Button("Import Profile…", systemImage: "square.and.arrow.down") {
                            tunnel.clearProfileMessage()
                            presentFileImporter(.profile)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!tunnel.canModifyProfiles)

                        Menu("More", systemImage: "ellipsis.circle") {
                            Button("Add Node…", systemImage: "plus") {
                                tunnel.clearProfileMessage()
                                isManualNodeEditorPresented = true
                            }
                            Divider()
                            Button("Export Portable Archive…", systemImage: "square.and.arrow.up") {
                                tunnel.clearProfileMessage()
                                isExportPasswordPresented = true
                            }
                            .disabled(tunnel.profiles.isEmpty)
                            Button("Import Portable Archive…", systemImage: "square.and.arrow.down") {
                                tunnel.clearProfileMessage()
                                presentFileImporter(.portableArchive)
                            }
                        }
                        .accessibilityIdentifier("profiles-more-menu")
                        .disabled(!tunnel.canModifyProfiles)
                        Spacer(minLength: 0)
                    }
                    .controlSize(.large)

                    if let message = tunnel.profileMessage,
                       !tunnel.isImportingProfile {
                        Label(
                            message,
                            systemImage: tunnel.profileMessageIsError
                                ? "exclamationmark.triangle"
                                : "checkmark.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(tunnel.profileMessageIsError ? .red : .green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(AetherVisual.s6)
                .aetherPanel()

                if tunnel.isImportingProfile {
                    HStack(spacing: AetherVisual.s3) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Importing profile…")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Button("Cancel", role: .cancel) {
                            tunnel.cancelProfileImport()
                        }
                    }
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.vertical, AetherVisual.s4)
                    .aetherPanel()
                    .accessibilityIdentifier("profile-import-progress")
                }

                if let subscription = tunnel.activeProfile?.subscription {
                    ProfileSubscriptionCard(
                        subscription: subscription,
                        isRefreshing: tunnel.isRefreshingSubscription,
                        canRefresh: tunnel.canModifyProfiles
                    ) {
                        Task { await tunnel.refreshSubscription() }
                    }
                }

                if !tunnel.requiredRoutingResources.isEmpty {
                    RoutingResourcesCard(
                        importResource: { kind in
                            routingResourceImportKind = kind
                            presentFileImporter(.routingResource)
                        }
                    )
                    .environmentObject(tunnel)
                }

                if !tunnel.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                                Text("Profile Library")
                                    .font(.headline)
                                    .foregroundStyle(.primary)
                                Text(
                                    String.localizedStringWithFormat(
                                        AppLocalization.string("%lld encrypted profiles"),
                                        Int64(tunnel.profiles.count)
                                    )
                                )
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Label("Encrypted on this Mac", systemImage: "lock.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
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
                                    Task {
                                        await tunnel.activateProfile(
                                            id: managed.id
                                        )
                                    }
                                },
                                rename: {
                                    profileToRename = managed
                                },
                                editNative: managed.profile.nativeNodes == nil
                                    ? nil
                                    : { nativeProfileToEdit = managed },
                                remove: {
                                    Task {
                                        await tunnel.removeProfile(
                                            id: managed.id
                                        )
                                    }
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

                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    Label("Safe import", systemImage: "checkmark.shield")
                        .font(.headline)
                    Text("YAML profiles are size-limited, UTF-8 checked, and rejected when they request scripts, plug-ins, commands, or downloadable external UI. The protocol engine performs a second parse before the network extension can report ready.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AetherVisual.s5)
                .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous))
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

    private var profileDetail: String {
        guard let profile = tunnel.activeProfile else {
            return AppLocalization.string(
                "Add a node or import a YAML profile to enable the network extension."
            )
        }
        return String.localizedStringWithFormat(
            AppLocalization.string("Activated %@"),
            AppLocalization.date(
                profile.importedAt,
                date: .abbreviated,
                time: .shortened
            )
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
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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

            Spacer(minLength: 12)

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
    @State private var isActionsPresented = false
    let managed: ManagedProfile
    let isActive: Bool
    let canActivate: Bool
    let canModify: Bool
    let activate: () -> Void
    let rename: () -> Void
    let editNative: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(iconColor.opacity(0.10))
                Image(systemName: managed.profile.subscription == nil
                    ? "doc.text.fill"
                    : "link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                HStack(spacing: AetherVisual.s2) {
                    Text(managed.profile.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isActive {
                        Text("In Use")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, AetherVisual.s2)
                            .padding(.vertical, AetherVisual.s1)
                            .background(
                                Color.teal.opacity(0.10),
                                in: Capsule()
                            )
                    }
                }
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: 12)

            if !isActive {
                Button("Use", action: activate)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canActivate)
                    .accessibilityIdentifier("activate-profile-\(managed.id.uuidString)")
            }

            Button {
                isActionsPresented.toggle()
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.borderless)
            .frame(width: 28)
            .accessibilityLabel("Profile actions")
            .popover(isPresented: $isActionsPresented, arrowEdge: .trailing) {
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    if let editNative {
                        Button("Edit Nodes…", systemImage: "point.3.connected.trianglepath.dotted") {
                            isActionsPresented = false
                            editNative()
                        }
                        .disabled(!canModify)
                    }
                    Button("Rename…", systemImage: "pencil") {
                        isActionsPresented = false
                        rename()
                    }
                    .disabled(!canModify)
                    if !isActive {
                        Divider()
                        Button(
                            "Remove Profile",
                            systemImage: "trash",
                            role: .destructive
                        ) {
                            isActionsPresented = false
                            remove()
                        }
                        .disabled(!canModify)
                    }
                }
                .buttonStyle(.borderless)
                .padding(AetherVisual.s3)
            }
        }
        .padding(.horizontal, AetherVisual.s5)
        .padding(.vertical, AetherVisual.s3)
        .contentShape(Rectangle())
    }

    private var iconColor: Color {
        managed.profile.subscription == nil ? .teal : .blue
    }

    private var detail: String {
        let source = managed.profile.subscription == nil
            ? AppLocalization.string("Local profile")
            : AppLocalization.string("HTTPS subscription")
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

private struct ProfileSubscriptionCard: View {
    let subscription: ProfileSubscription
    let isRefreshing: Bool
    let canRefresh: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(subscription.url.host ?? AppLocalization.string("HTTPS subscription"))
                    .font(.headline)
                    .lineLimit(1)
                Text(updateDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let lastCheckedAt = subscription.lastCheckedAt {
                    Text(
                        String.localizedStringWithFormat(
                            AppLocalization.string("Checked %@"),
                            AppLocalization.date(
                                lastCheckedAt,
                                date: .abbreviated,
                                time: .shortened
                            )
                        )
                    )
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            Button(action: refresh) {
                AetherProgressButtonLabel(
                    "Check for Updates",
                    systemImage: "arrow.clockwise",
                    isWorking: isRefreshing
                )
            }
                .disabled(!canRefresh || isRefreshing)
        }
        .padding(AetherVisual.s5)
        .aetherPanel()
    }

    private var updateDetail: String {
        guard let interval = subscription.autoUpdateInterval else {
            return AppLocalization.string("HTTPS subscription · manual updates")
        }
        let hours = max(1, Int(interval / 3_600))
        return String.localizedStringWithFormat(
            AppLocalization.string("HTTPS subscription · updates every %lld hours"),
            Int64(hours)
        )
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

            TextField("HTTPS subscription URL", text: $urlText)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("subscription-url-field")

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
                        "Download and Activate",
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || tunnel.isRefreshingSubscription
                )
                .accessibilityIdentifier("activate-subscription-button")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 540)
    }
}

private struct RouteStop: View {
    let identifier: String
    let symbol: String
    let caption: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(value)
            }
        }
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.s2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
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
                HStack(spacing: AetherVisual.s1) {
                    Rectangle().frame(height: 1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: 42)
            } else {
                VStack(spacing: AetherVisual.s1) {
                    Rectangle().frame(width: 1, height: 7)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
                .frame(height: 15)
            }
        }
        .foregroundStyle(.quaternary)
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
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                Text(value)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.primary)
                    .monospacedDigit()
                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                LiveTelemetryMetricValue(
                    metric: metric,
                    isConnected: isConnected,
                    telemetry: telemetry
                )
                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
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
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        HStack(alignment: .top, spacing: AetherVisual.s3) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .symbolEffect(.pulse, isActive: tunnel.connectionQuality == .verifying)
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
            value: tunnel.connectionQuality
        )
    }

    private var symbol: String {
        switch tunnel.connectionQuality {
        case .unknown: "lock.shield"
        case .verifying: "gauge.with.dots.needle.bottom.50percent"
        case .verified: "checkmark.shield"
        case .degraded: "exclamationmark.triangle"
        }
    }

    private var tint: Color {
        switch tunnel.connectionQuality {
        case .unknown, .verifying: Color.accentColor
        case .verified: .green
        case .degraded: .orange
        }
    }

    private var title: LocalizedStringKey {
        switch tunnel.connectionQuality {
        case .unknown: "Verified connection status"
        case .verifying: "Checking route quality"
        case .verified: "Route verified"
        case .degraded: "Route is slow"
        }
    }

    private var detail: LocalizedStringKey {
        switch tunnel.connectionQuality {
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

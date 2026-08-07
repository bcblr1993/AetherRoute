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
                    AetherContentCanvas()
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
        .onOpenURL { url in
            tunnel.handleExternalURL(url)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            guard tunnel.systemExtensionApprovalRequired else { return }
            Task { await tunnel.recheckSystemExtensionApproval() }
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
                selectedSection = requestedSection
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
                    min: 220,
                    ideal: 236,
                    max: 280
                )
        } detail: {
            detail
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Selected page content")
                .accessibilityIdentifier("aetherroute-selected-page")
        }
        .navigationSplitViewStyle(.balanced)
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
            HStack(spacing: 11) {
                AetherRouteBrandTile(size: 34, isActive: tunnel.isConnected)

                VStack(alignment: .leading, spacing: 1) {
                    Text("AetherRoute")
                        .font(.headline.weight(.semibold))
                        .tracking(-0.15)
                        .foregroundStyle(.primary)
                    Text("Private routing")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .accessibilityIdentifier("sidebar-brand-subtitle")
                }
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 12)

            Divider()
                .padding(.horizontal, 12)
                .padding(.bottom, 6)

            List(selection: $selectedSection) {
                Section {
                    ForEach(AppSection.allCases) { section in
                        Button {
                            UIResponsivenessProbe.begin(
                                "main.\(section.rawValue)"
                            )
                            selectedSection = section
                        } label: {
                            Label(section.title, systemImage: section.symbol)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                            .buttonStyle(.plain)
                            .tag(section)
                            .keyboardShortcut(
                                section.keyboardShortcut,
                                modifiers: .command
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

                    HStack(spacing: 10) {
                        Image(systemName: "doc.badge.gearshape")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
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
                            .font(.caption)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .foregroundStyle(.primary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .layoutPriority(1)
                    }
                    .padding(.vertical, 5)
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
            .tint(.accentColor)
        }
    }

    private var activeProfileStatus: String {
        let requiredResources = tunnel.requiredRoutingResources
        if !requiredResources.isEmpty {
            let statuses = requiredResources.compactMap {
                tunnel.routingResourceStatuses[$0]
            }
            if statuses.count != requiredResources.count {
                return AppLocalization.string("Checking resources")
            }
            let allReady = statuses.allSatisfy {
                if case .ready = $0 { return true }
                return false
            }
            if !allReady {
                return AppLocalization.string("Routing resources required")
            }
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
                        UIResponsivenessProbe.begin("main.profiles")
                        selectedSection = .profiles
                    }
                case .proxies:
                    ProxiesView()
                case .connections:
                    ConnectionsView()
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
            HStack(spacing: 7) {
                Image(systemName: "power")
                Text(tunnel.primaryActionTitle)
            }
                .font(.body.weight(.semibold))
                .frame(minWidth: 116)
        }
        .aetherPrimaryActionStyle()
        .controlSize(.large)
        .tint(actionTint)
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

    private var actionTint: Color {
        return switch state {
        case .connected: AetherVisual.success
        case .connecting, .disconnecting: .orange
        case .failed: .red
        case .disconnected: .accentColor
        case .privacyConsentRequired, .loading: .secondary
        }
    }

    private var state: TunnelManager.State { tunnel.state }
}

private struct OverviewView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let openProfiles: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ConnectionHero()
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
        VStack(spacing: 16) {
            RouteSummary()
            if tunnel.systemExtensionApprovalRequired {
                SystemExtensionApprovalCard()
            } else if let recoveryPlan = tunnel.recoveryPlan {
                ConnectionRecoveryCard(
                    plan: recoveryPlan,
                    openProfiles: openProfiles
                )
            }
            HStack(spacing: 0) {
                MetricTile(
                    label: "Latency",
                    value: bestLatency,
                    unit: "ms",
                    symbol: "waveform.path.ecg"
                )
                Divider()
                    .frame(height: 52)
                MetricTile(
                    label: "Live traffic",
                    value: formattedRate(tunnel.telemetry.downloadBytesPerSecond),
                    unit: "Download",
                    symbol: "arrow.up.arrow.down"
                )
            }
            .padding(.vertical, 4)
            .aetherPanel(radius: 16)
            SafetyNotice()
        }
        .frame(maxWidth: .infinity)
    }

    private var bestLatency: String {
        let values = tunnel.proxyLatencies.values
            .flatMap(\.results)
            .compactMap(\.delayMilliseconds)
        return values.min().map(String.init) ?? "--"
    }
}

private struct SystemExtensionApprovalCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var copiedSteps = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(AetherVisual.blue)
                    .frame(width: 42, height: 42)
                    .background(
                        AetherVisual.blue.opacity(0.11),
                        in: RoundedRectangle(cornerRadius: 12)
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Approve Network Extension")
                        .font(.headline)
                    Text("macOS requires your approval because Transparent Proxy and TUN can route network traffic. AetherRoute cannot approve this security permission for you.")
                        .font(.subheadline)
                        .foregroundStyle(
                            colorScheme == .dark ? Color.white : Color.black
                        )
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 9) {
                approvalStep(
                    number: 1,
                    text: AppLocalization.string(
                        "Open System Settings. This button takes you to Login Items & Extensions."
                    )
                )
                approvalStep(
                    number: 2,
                    text: AppLocalization.string(
                        "Scroll to the bottom Extensions section. Do not use the Open at Login list."
                    )
                )
                approvalStep(
                    number: 3,
                    text: AppLocalization.string(
                        "Next to Network Extensions, click the info button, turn on AetherRoute, then click Done."
                    )
                )
            }
            .padding(14)
            .background(
                Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { approvalActions }
                VStack(alignment: .leading, spacing: 10) { approvalActions }
            }
        }
        .padding(18)
        .background(
            AetherVisual.panelFill(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(AetherVisual.blue.opacity(0.20), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("system-extension-approval-card")
    }

    @ViewBuilder
    private var approvalActions: some View {
        Button {
            SystemSettingsNavigator.openNetworkExtensions()
        } label: {
            Label("Open System Settings", systemImage: "gearshape")
        }
        .controlSize(.large)
        .aetherPrimaryActionStyle()
        .accessibilityIdentifier("open-network-extension-settings")

        Button {
            copyApprovalSteps()
        } label: {
            Label(
                copiedSteps
                    ? AppLocalization.string("Steps Copied")
                    : AppLocalization.string("Copy Steps"),
                systemImage: copiedSteps ? "checkmark" : "doc.on.doc"
            )
        }
        .controlSize(.large)
        .aetherSecondaryActionStyle()
        .accessibilityIdentifier("copy-network-extension-steps")

        Button {
            Task { await tunnel.recheckSystemExtensionApproval() }
        } label: {
            Label("Approved — Check Again", systemImage: "arrow.clockwise")
        }
        .controlSize(.large)
        .aetherSecondaryActionStyle()
        .accessibilityIdentifier("recheck-network-extension-approval")
    }

    private func approvalStep(number: Int, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: "\(number).")
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
                .frame(width: 24, alignment: .trailing)
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyApprovalSteps() {
        let steps = [
            AppLocalization.string(
                "Open System Settings. This button takes you to Login Items & Extensions."
            ),
            AppLocalization.string(
                "Scroll to the bottom Extensions section. Do not use the Open at Login list."
            ),
            AppLocalization.string(
                "Next to Network Extensions, click the info button, turn on AetherRoute, then click Done."
            ),
        ]
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            steps.enumerated().map { "\($0.offset + 1). \($0.element)" }
                .joined(separator: "\n"),
            forType: .string
        )
        copiedSteps = true
    }
}

private enum SystemSettingsNavigator {
    static func openNetworkExtensions() {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] != nil {
            return
        }
#endif
        let destinations = [
            "x-apple.systempreferences:com.apple.LoginItems-Settings.extension",
            "x-apple.systempreferences:com.apple.preference.general?LoginItems",
        ]
        for destination in destinations {
            guard let url = URL(string: destination) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }

        let settingsURL = URL(
            fileURLWithPath: "/System/Applications/System Settings.app"
        )
        NSWorkspace.shared.openApplication(
            at: settingsURL,
            configuration: .init()
        )
    }
}

private struct ConnectionRecoveryCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let plan: ConnectionRecoveryPlan
    let openProfiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 13) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: 42, height: 42)
                    .background(
                        Color.orange.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text("Recovery Assistant")
                        .font(.headline)
                    Text(recoveryDetail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }

            HStack(spacing: 10) {
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
        .padding(18)
        .background(
            Color.orange.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
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
            button.aetherPrimaryActionStyle()
        } else {
            button.aetherSecondaryActionStyle()
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
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 20) {
            HStack(spacing: 24) {
                connectionIdentity
                ConnectionToolbarButton()
                    .environmentObject(tunnel)
            }

            Divider()

            connectionControls
        }
        .padding(24)
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
        HStack(spacing: 16) {
            AetherRouteStatusLens(size: 54, isActive: tunnel.isConnected)

            VStack(alignment: .leading, spacing: 7) {
                Text(stateBadgeTitle)
                    .foregroundStyle(stateBadgeForeground)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        stateBadgeBackground,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(Color.primary.opacity(0.10), lineWidth: 1)
                    }
                    .accessibilityHidden(true)

                Text(tunnel.statusTitle)
                    .font(.title.weight(.semibold))
                    .tracking(-0.45)
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .accessibilityValue(Text(tunnel.statusDetail))
                Text(tunnel.statusDetail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var connectionControls: some View {
#if AETHERROUTE_INDEPENDENT
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 20) {
                engineControl
                Divider()
                    .frame(height: 66)
                routingControl
            }

            VStack(alignment: .leading, spacing: 16) {
                engineControl
                Divider()
                routingControl
            }
        }
#else
        routingControl
#endif
    }

#if AETHERROUTE_INDEPENDENT
    private var engineControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text("Network engine")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .accessibilityHidden(true)
                Spacer()
                Text(tunnel.networkEngineMode.localizedCompactDetail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityHidden(true)
            }

            Picker("Network engine", selection: networkEngineBinding) {
                ForEach(NetworkEngineMode.allCases) { mode in
                    Text(mode.localizedTitleKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(AetherVisual.blue)
            .disabled(!tunnel.canChangeNetworkEngine)
            .accessibilityIdentifier("network-engine-picker")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
#endif

    private var routingControl: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Routing mode")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
                .accessibilityHidden(true)

            Picker("Routing mode", selection: $tunnel.routingMode) {
                ForEach(RoutingMode.allCases, id: \.self) { mode in
                    Text(mode.localizedTitleKey).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .tint(AetherVisual.blue)
            .disabled(!tunnel.canChangeRoutingMode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var stateBadgeTitle: String {
        switch tunnel.state {
        case .privacyConsentRequired: AppLocalization.string("Privacy")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected: AppLocalization.string("Standby")
        case .connecting: AppLocalization.string("Starting")
        case .connected: AppLocalization.string("Protected")
        case .disconnecting: AppLocalization.string("Stopping")
        case .failed: AppLocalization.string("Attention")
        }
    }

    private var stateBadgeForeground: Color {
        colorScheme == .dark ? .white : .black
    }

    private var stateBadgeBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.09)
            : .white
    }
}

private struct RouteSummary: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack {
                Text("Current route")
                    .font(.headline)
                Spacer()
                Label(routeStatus.title, systemImage: routeStatus.symbol)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    routeStops(horizontal: true)
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    routeStops(horizontal: false)
                }
            }
        }
        .padding(20)
        .aetherPanel(radius: 16)
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(AetherVisual.blue)
                    .frame(width: 54, height: 54)
                    .background(
                        AetherVisual.blue.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 15)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Review Subscription Link")
                        .font(.title2.weight(.semibold))
                    Text("AetherRoute has not downloaded or changed anything yet.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("Profile provider")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(request.providerHost, systemImage: "lock.fill")
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("external-subscription-host")
                Text("Only the provider host is shown. Private query tokens stay hidden.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: 14)
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
                        "Review and Import",
                        isWorking: isConfirming
                            || tunnel.isRefreshingSubscription
                    )
                }
                .aetherPrimaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !tunnel.canModifyProfiles
                        || isConfirming
                        || tunnel.isRefreshingSubscription
                )
                .accessibilityIdentifier("confirm-external-subscription")
            }
        }
        .padding(26)
        .frame(width: 540)
        .interactiveDismissDisabled(isConfirming)
    }
}

private struct ProfilesView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var isImporterPresented = false
    @State private var isManualNodeEditorPresented = false
    @State private var isSubscriptionEditorPresented = false
    @State private var subscriptionURL = ""
    @State private var profileToRename: ManagedProfile?
    @State private var nativeProfileToEdit: ManagedProfile?
    @State private var isArchiveImporterPresented = false
    @State private var isArchivePasswordPresented = false
    @State private var isArchiveExporterPresented = false
    @State private var isExportPasswordPresented = false
    @State private var isPortableTransferPresented = false
    @State private var isRoutingResourceImporterPresented = false
    @State private var routingResourceImportKind: RoutingResourceKind?
    @State private var archiveImportURL: URL?
    @State private var pendingArchiveData: Data?
    @State private var archiveDocument = ProfileArchiveDocument()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .center, spacing: 18) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(Color.teal.opacity(0.10))
                            Image(systemName: "doc.badge.gearshape")
                                .font(.system(size: 30, weight: .medium))
                                .foregroundStyle(.teal)
                                .accessibilityHidden(true)
                        }
                        .frame(width: 68, height: 68)

                        VStack(alignment: .leading, spacing: 6) {
                            Text(
                                tunnel.activeProfile?.name
                                    ?? AppLocalization.string("No active profile")
                            )
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                                .help(
                                    tunnel.activeProfile?.name
                                        ?? AppLocalization.string("No active profile")
                                )
                            Text(profileDetail)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        Spacer(minLength: 0)
                    }

                    Divider()

                    HStack(spacing: 9) {
                        Button("Add Node…", systemImage: "plus") {
                            tunnel.clearProfileMessage()
                            isManualNodeEditorPresented = true
                        }
                        .disabled(!tunnel.canModifyProfiles)

                        Button("Import Profile…", systemImage: "square.and.arrow.down") {
                            tunnel.clearProfileMessage()
                            isImporterPresented = true
                        }
                        .disabled(!tunnel.canModifyProfiles)

                        Button("Add Subscription…", systemImage: "link.badge.plus") {
                            tunnel.clearProfileMessage()
                            subscriptionURL = ""
                            isSubscriptionEditorPresented = true
                        }
                        .disabled(!tunnel.canModifyProfiles)

                        Button {
                            isPortableTransferPresented.toggle()
                        } label: {
                            Image(systemName: "arrow.left.arrow.right.circle")
                                .frame(width: 22)
                        }
                        .buttonStyle(.bordered)
                        .disabled(!tunnel.canModifyProfiles)
                        .help("Move encrypted profiles between Macs")
                        .accessibilityLabel("Portable profile transfer")
                        .popover(
                            isPresented: $isPortableTransferPresented,
                            arrowEdge: .trailing
                        ) {
                            VStack(alignment: .leading, spacing: 8) {
                                Button(
                                    "Export Portable Archive…",
                                    systemImage: "square.and.arrow.up"
                                ) {
                                    isPortableTransferPresented = false
                                    tunnel.clearProfileMessage()
                                    isExportPasswordPresented = true
                                }
                                .disabled(tunnel.profiles.isEmpty)

                                Button(
                                    "Import Portable Archive…",
                                    systemImage: "square.and.arrow.down"
                                ) {
                                    isPortableTransferPresented = false
                                    tunnel.clearProfileMessage()
                                    isArchiveImporterPresented = true
                                }
                            }
                            .buttonStyle(.borderless)
                            .padding(12)
                        }
                        Spacer(minLength: 0)
                    }
                    .controlSize(.large)
                }
                .padding(22)
                .aetherPanel(radius: 18, elevated: true)

                if let message = tunnel.profileMessage,
                   !tunnel.isImportingProfile {
                    Label(
                        message,
                        systemImage: tunnel.profileMessageIsError
                            ? "exclamationmark.triangle"
                            : "checkmark.circle"
                    )
                        .foregroundStyle(tunnel.profileMessageIsError ? .orange : .teal)
                        .padding(15)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }

                if tunnel.isImportingProfile {
                    HStack(spacing: 12) {
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
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .aetherPanel(radius: 14)
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
                            isRoutingResourceImporterPresented = true
                        }
                    )
                    .environmentObject(tunnel)
                }

                if !tunnel.profiles.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
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
                                .foregroundStyle(
                                    colorScheme == .dark
                                        ? Color.white
                                        : Color.black
                                )
                            }
                            Spacer()
                            Label("Encrypted on this Mac", systemImage: "lock.fill")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 15)

                        Divider()
                            .padding(.horizontal, 18)

                        ForEach(Array(tunnel.profiles.enumerated()), id: \.element.id) { index, managed in
                            ManagedProfileRow(
                                managed: managed,
                                isActive: managed.id == tunnel.activeProfileID,
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
                                    .padding(.leading, 74)
                                    .padding(.trailing, 18)
                            }
                        }
                    }
                    .aetherPanel(radius: 17)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Safe import", systemImage: "checkmark.shield")
                        .font(.headline)
                    Text("YAML profiles are size-limited, UTF-8 checked, and rejected when they request scripts, plug-ins, commands, or downloadable external UI. The protocol engine performs a second parse before the network extension can report ready.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
                .background(Color.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.plainText, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                tunnel.importProfile(from: url)
            } else if case let .failure(error) = result {
                tunnel.reportProfileImportError(error)
            }
        }
        .fileImporter(
            isPresented: $isArchiveImporterPresented,
            allowedContentTypes: [.aetherRouteProfileArchive, .data],
            allowsMultipleSelection: false
        ) { result in
            if case let .success(urls) = result, let url = urls.first {
                archiveImportURL = url
                Task { @MainActor in
                    await Task.yield()
                    isArchivePasswordPresented = true
                }
            } else if case let .failure(error) = result {
                tunnel.reportProfileImportError(error)
            }
        }
        .fileImporter(
            isPresented: $isRoutingResourceImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard let kind = routingResourceImportKind else { return }
            routingResourceImportKind = nil
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task {
                    await tunnel.importRoutingResource(kind, from: url)
                }
            case let .failure(error):
                tunnel.reportProfileImportError(error)
            }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "map.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 42, height: 42)
                    .background(
                        Color.blue.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text("Routing Resources")
                        .font(.headline)
                    Text(
                        "The active profile uses GEOIP or GEOSITE rules. Required databases must pass integrity checks before connection."
                    )
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18)

            Divider()
                .padding(.horizontal, 18)

            ForEach(
                Array(tunnel.requiredRoutingResources.enumerated()),
                id: \.element
            ) { index, kind in
                resourceRow(kind)
                if index < tunnel.requiredRoutingResources.count - 1 {
                    Divider()
                        .padding(.leading, 74)
                        .padding(.trailing, 18)
                }
            }

            Divider()
                .padding(.horizontal, 18)

            VStack(alignment: .leading, spacing: 12) {
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
                            ? Color.orange : Color.teal
                    )
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 10) {
                    Button {
                        Task {
                            await tunnel.downloadRequiredRoutingResources()
                        }
                    } label: {
                        AetherProgressButtonLabel(
                            "Download & Verify",
                            systemImage: "arrow.down.shield",
                            isWorking: tunnel.isUpdatingRoutingResources
                        )
                    }
                    .aetherPrimaryActionStyle()
                    .disabled(
                        !tunnel.canModifyProfiles
                            || tunnel.isUpdatingRoutingResources
                    )

                    Text(
                        "Downloads are user-initiated over HTTPS and checksum-verified. Country.mmdb is MaxMind-derived through Loyalsoldier; GeoSite.dat is provided by V2Fly. Their upstream licenses apply."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .aetherPanel(radius: 17)
        .accessibilityIdentifier("routing-resources-card")
    }

    private func resourceRow(_ kind: RoutingResourceKind) -> some View {
        HStack(spacing: 14) {
            Image(systemName: resourceSymbol(kind))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(resourceColor(kind))
                .frame(width: 42, height: 42)
                .background(
                    resourceColor(kind).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 11)
                )

            VStack(alignment: .leading, spacing: 3) {
                Text(kind.fileName)
                    .font(.body.weight(.medium))
                Text(resourceStatusTitle(kind))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
                AppLocalization.string("Update required · %@"),
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
    let canModify: Bool
    let activate: () -> Void
    let rename: () -> Void
    let editNative: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(iconColor.opacity(0.10))
                Image(systemName: managed.profile.subscription == nil
                    ? "doc.text.fill"
                    : "link")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(iconColor)
            }
            .frame(width: 42, height: 42)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(managed.profile.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if isActive {
                        Text("In Use")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
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
                    .disabled(!canModify)
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
                VStack(alignment: .leading, spacing: 8) {
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
                .padding(12)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
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
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
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
                .aetherPrimaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSaving
                )
            }
        }
        .padding(26)
        .frame(width: 460)
    }
}

private struct ProfileSubscriptionCard: View {
    let subscription: ProfileSubscription
    let isRefreshing: Bool
    let canRefresh: Bool
    let refresh: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(.blue)
                .frame(width: 48, height: 48)
                .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 4) {
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
        .padding(18)
        .aetherPanel(radius: 16)
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
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.blue)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
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
                .aetherPrimaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || tunnel.isRefreshingSubscription
                )
                .accessibilityIdentifier("activate-subscription-button")
            }
        }
        .padding(26)
        .frame(width: 540)
    }
}

private struct RouteStop: View {
    let identifier: String
    let symbol: String
    let caption: LocalizedStringKey
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(AetherVisual.blue)
                .frame(width: 32, height: 32)
                .background(AetherVisual.blue.opacity(0.08), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(caption)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(value)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
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
                HStack(spacing: 3) {
                    Rectangle().frame(height: 1)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                }
                .frame(maxWidth: 42)
            } else {
                VStack(spacing: 2) {
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
    @Environment(\.colorScheme) private var colorScheme
    let label: LocalizedStringKey
    let value: String
    let unit: LocalizedStringKey
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.title2.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                Text(unit)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
    }
}

private struct SafetyNotice: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.teal)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Fail-closed development build")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .accessibilityHint(
                        Text("The network extension cannot report connected until the audited protocol bridge has started and passed readiness checks.")
                    )
                Text("The network extension cannot report connected until the audited protocol bridge has started and passed readiness checks.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 8)
    }
}

private func formattedRate(_ bytes: UInt64) -> String {
    "\(ByteCountFormatter.string(fromByteCount: Int64(clamping: bytes), countStyle: .file))/s"
}

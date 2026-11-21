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


struct ContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @EnvironmentObject private var language: AppLanguageController
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedSection: AppSection? = .overview
    @State private var isCommandPalettePresented = false
    @AppStorage(SparkleUpdaterController.dismissedUpdateVersionKey)
    private var dismissedUpdateVersion: String = ""
    @ObservedObject private var updater = SparkleUpdaterController.shared

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
                    .transition(.opacity)
            } else {
                PrivacyDisclosureView(isOnboarding: true)
                    .environmentObject(tunnel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("AetherRoute application content"))
        .accessibilityIdentifier("aetherroute-semantic-root")
        .frame(minWidth: AetherVisual.windowMinWidth, minHeight: AetherVisual.windowMinHeight)
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
                isMainWindow: true,
                usesNativeToolbar: true
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
        .alert(
            AppLocalization.string("Confirm External URL Command"),
            isPresented: Binding(
                get: { tunnel.pendingControlURLRequest != nil },
                set: { presented in
                    if !presented {
                        tunnel.cancelPendingControlURLAction()
                    }
                }
            ),
            presenting: tunnel.pendingControlURLRequest
        ) { _ in
            Button(AppLocalization.string("Allow")) {
                tunnel.confirmPendingControlURLAction()
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                tunnel.cancelPendingControlURLAction()
            }
        } message: { pending in
            Text(
                AppLocalization.format(
                    "An external link (%@) requested changing your connection state without an automation token. Allow this action?",
                    pending.url.host ?? "aetherroute"
                )
            )
        }
        .overlay(alignment: .top) {
            if isCommandPalettePresented && tunnel.hasAcceptedPrivacyDisclosure {
                ZStack(alignment: .top) {
                    AetherVisual.scrimFill
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
            guard tunnel.hasAcceptedPrivacyDisclosure else { return }
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
            AppLocalization.string("Cannot Open Subscription Link"),
            isPresented: Binding(
                get: { tunnel.externalSubscriptionLinkError != nil },
                set: { isPresented in
                    if !isPresented {
                        tunnel.dismissExternalSubscriptionLinkError()
                    }
                }
            )
        ) {
            Button(AppLocalization.string("OK"), role: .cancel) {
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
#if AETHERROUTE_UI_RESPONSIVENESS
            if let seconds = ProcessInfo.processInfo.environment[
                "AETHERROUTE_UI_RESPONSIVENESS_AUTOCYCLE_SECONDS"
            ].flatMap(Double.init), seconds > 0 {
                await cycleSectionsForResponsiveness(seconds: seconds)
            }
#endif
        }
    }

#if AETHERROUTE_UI_RESPONSIVENESS
    /// Measurement builds only: switches pages on a fixed beat so the
    /// probe can time navigation on a Mac where the XCUITest runner cannot
    /// run the gate (its sandbox cannot write evidence there), then quits.
    private func cycleSectionsForResponsiveness(seconds: Double) async {
        // AETHERROUTE_UI_RESPONSIVENESS_AUTOCYCLE_SECTIONS=overview,dns
        // narrows the cycle to the pages being profiled.
        let requested = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_RESPONSIVENESS_AUTOCYCLE_SECTIONS"
        ]?.split(separator: ",").compactMap { AppSection(rawValue: String($0)) } ?? []
        let sections = requested.isEmpty ? Array(AppSection.allCases.reversed()) : requested
        UIResponsivenessProbe.setWarmup(true)
        try? await Task.sleep(for: .seconds(1))
        for _ in 0..<2 {
            for section in sections {
                selectSection(section)
                try? await Task.sleep(for: .milliseconds(350))
            }
        }
        UIResponsivenessProbe.setWarmup(false)
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            for section in sections {
                selectSection(section)
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
        try? await Task.sleep(for: .seconds(1))
        NSApplication.shared.terminate(nil)
    }
#endif

    private var applicationContent: some View {
        NavigationSplitView {
            sidebar
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppLocalization.string("Primary navigation"))
                .accessibilityIdentifier("aetherroute-primary-navigation")
                // Resizable within reason, as in Mail and Finder.
                .navigationSplitViewColumnWidth(
                    min: AetherVisual.sidebarMinWidth,
                    ideal: AetherVisual.sidebarWidth,
                    max: AetherVisual.sidebarMaxWidth
                )
        } detail: {
            // No label or identifier of its own: every page's root is a scroll
            // view, and wrapper modifiers landed on it and replaced the page's
            // identifier ("overview-page", "rules-page", …).
            detail
        }
        .navigationSplitViewStyle(.balanced)
        // The toolbar holds only the sidebar button; without its own
        // background the pages run to the top edge and the button floats
        // in glass above them, instead of an empty bar across the window.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Primary navigation and content"))
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
              width >= Double(AetherVisual.windowMinWidth),
              height >= Double(AetherVisual.windowMinHeight) else { return }

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

    @State private var isBrandHeaderHovered: Bool = false
    @State private var hoveredSection: AppSection?
    @State private var isSettingsHovered: Bool = false

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // 1. 顶部品牌与状态指示栏（点击返回概览）
            Button {
                selectSection(.overview)
            } label: {
                HStack(spacing: AetherVisual.sRow) {
                    AetherRouteBrandTile(size: AetherVisual.brandMarkSize, isActive: tunnel.isConnected)

                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(verbatim: "AetherRoute")
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
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s2)
                .aetherHoverHighlight(isHovered: isBrandHeaderHovered, cornerRadius: AetherVisual.cardRadius)
                .contentShape(RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isBrandHeaderHovered = $0 }
            .padding(.horizontal, AetherVisual.s1)
            .padding(.top, AetherVisual.s1)
            .padding(.bottom, AetherVisual.s1)
            .help(AppLocalization.string("Overview"))
            .accessibilityLabel(AppLocalization.string("Overview"))
            .accessibilityIdentifier("sidebar-brand-overview-button")

            Divider()
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
                            .padding(.horizontal, AetherVisual.s1)
                            .aetherHoverHighlight(isHovered: hoveredSection == section && selectedSection != section)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .onHover { isHovered in
                            hoveredSection = isHovered ? section : (hoveredSection == section ? nil : hoveredSection)
                        }
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
                    .padding(.horizontal, AetherVisual.s3)

                AetherWrapPairLayout {
                    sidebarSettingsButton
                    sidebarVersionLabel
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
        Button {
            updater.checkForUpdates()
        } label: {
            HStack(spacing: AetherVisual.s1) {
                Text(verbatim: currentAppVersion)
                    .font(.system(.subheadline, design: .monospaced, weight: .medium))
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if updater.availability.availableVersion != nil {
                    Circle()
                        .fill(Color.accentColor)
                        .frame(width: AetherVisual.sCompact, height: AetherVisual.sCompact)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.trailing, AetherVisual.s2)
        .accessibilityLabel(
            updater.availability.availableVersion != nil
                ? AppLocalization.string("New version available. Click to update.")
                : currentAppVersion
        )
    }

    @ViewBuilder
    private func navigationBadge(for section: AppSection) -> some View {
        switch section {
        case .proxies:
            if let summary = tunnel.activeProfileSummary, summary.proxyCount > 0 {
                AetherCountBadge(count: summary.proxyCount)
            }
        case .connections:
            ConnectionCountBadge(telemetry: tunnel.telemetryViewModel)
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
        return VStack(spacing: 0) {
            if let availableVersion = updater.availability.availableVersion,
               availableVersion != dismissedUpdateVersion {
                UpdateAvailableBannerView(
                    version: availableVersion,
                    onUpdate: {
                        updater.checkForUpdates()
                    },
                    onDismiss: {
                        dismissedUpdateVersion = availableVersion
                    }
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            ZStack {
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
                // Each page is a new identity. It fades in on opacity alone: the
                // 1.5.0 fade-up also moved the page, which laid it out again on
                // every animation frame and doubled the slowest switches
                // (Connections p95 377 ms with it, 171 ms without; 1.5.1).
                // Opacity is composited, so the page is laid out once.
                .id(section)
                .transition(.asymmetric(insertion: .opacity, removal: .identity))
                .animation(
                    effectiveReduceMotion ? nil : AetherVisual.pageFade,
                    value: section
                )
            }
        }
        .animation(effectiveReduceMotion ? nil : AetherVisual.panelSpring, value: updater.availability.availableVersion)
        .animation(effectiveReduceMotion ? nil : AetherVisual.panelSpring, value: dismissedUpdateVersion)
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
        AppTermination.request()
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
                    .fill(tunnel.isEnabled ? Color.green : AetherVisual.switchOffTrack)
                // A hairline edge rather than a drop shadow keeps the knob
                // distinct from the grey track without a glow.
                Circle()
                    .fill(.white)
                    .overlay {
                        Circle().strokeBorder(AetherVisual.switchKnobEdge, lineWidth: 0.5)
                    }
                    .padding(AetherVisual.switchKnobInset)
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

extension NetworkSetupView {
    init(
        tunnel _: TunnelManager,
        isOnboarding: Bool = false,
        onClose: (() -> Void)? = nil
    ) {
        self.init(isOnboarding: isOnboarding, onClose: onClose)
    }
}

private struct OverviewView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let openProfiles: () -> Void
    @State private var isSubscriptionEditorPresented = false
    @State private var isCloudSyncSheetPresented = false
    @State private var isEngineSetupPresented = false
    @State private var subscriptionURL = ""
    @State private var overviewWindowDemand: TunnelManager.TelemetryDemand = .none

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
                        isRealtime: overviewWindowDemand == .realtime,
                        isBackground: overviewWindowDemand == .background,
                        subscriptionUsage: tunnel.effectiveActiveSubscriptionUsage,
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
        .telemetryDemand(source: "overview") { demand in
            if overviewWindowDemand != demand {
                overviewWindowDemand = demand
            }
        }
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
            AetherSectionHeader(title: AppLocalization.string("Overview route section"))
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
                if let message = tunnel.networkEngineMessage, tunnel.networkEngineMessageIsError {
                    OverviewRowDivider()
                    HStack(spacing: AetherVisual.s2) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherReadableTint(color: .orange))
                            .accessibilityHidden(true)
                        Text(verbatim: message)
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("overview-network-engine-message")
                        if tunnel.networkEngineBlockedNeedsSetup {
                            Button {
                                isEngineSetupPresented = true
                            } label: {
                                Text(
                                    AppLocalization.string("Open Network Setup…")
                                )
                            }
                            .aetherButton()
                            .controlSize(.small)
                            .accessibilityIdentifier("overview-engine-message-open-setup")
                        }
                    }
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.vertical, AetherVisual.s2)
                }
                OverviewRowDivider()
                OverviewRouteCheckRow()
                OverviewRowDivider()
                OverviewEgressRow()
            }
            .aetherPanel()
        }
        .transition(.opacity)
        .sheet(isPresented: $isEngineSetupPresented) {
            NetworkSetupView(tunnel: tunnel, isOnboarding: false) {
                isEngineSetupPresented = false
            }
            .environmentObject(tunnel)
            .aetherLargeSheetFrame()
        }
    }
}

/// The outlet the active profile routes through: the node, the group that
/// chose it, and its last latency result.
private struct ActiveOutlet: Equatable {
    let groupName: String
    let node: String
    let resolvedNode: String
    let latency: ProxyLatencyStatus
    let isDirectMode: Bool

    @MainActor
    init?(tunnel: TunnelManager) {
        let mode = tunnel.isConnected
            ? (tunnel.sessionRoutingMode ?? tunnel.routingMode)
            : tunnel.routingMode
        switch mode {
        case .direct:
            let directTitle = AppLocalization.string("Direct outbound (no proxy)")
            groupName = "DIRECT"
            node = directTitle
            resolvedNode = directTitle
            latency = .untested
            isDirectMode = true
        case .global:
            guard let summary = tunnel.activeProfileSummary else { return nil }
            let selected = tunnel.proxySelections["GLOBAL"]?.selectedMember
                ?? TunnelManager.resolvedGlobalTargetMember(in: summary)
            guard let selected else { return nil }
            groupName = "GLOBAL"
            node = selected
            resolvedNode = tunnel.resolvedLeafNode(from: selected)
            latency = tunnel.resolvedOutletLatencyStatus(
                groupName: "GLOBAL",
                selectedMember: selected
            ).status
            isDirectMode = false
        case .rule:
            guard let group = tunnel.resolvedPrimaryRoutingGroup(),
                  let selected = tunnel.proxySelections[group.name]?.selectedMember
            else { return nil }
            groupName = group.name
            node = selected
            resolvedNode = tunnel.resolvedLeafNode(from: selected)
            latency = tunnel.resolvedOutletLatencyStatus(
                groupName: group.name,
                selectedMember: selected
            ).status
            isDirectMode = false
        }
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
                .foregroundStyle(AetherReadableTint(color: .orange))
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
                .aetherButton(prominent: true)
                .accessibilityIdentifier("recovery-networkSetup")
            }
            if plan.primaryAction == .reviewProfiles || plan.secondaryAction == .reviewProfiles {
                let button = Button(action: openProfiles) {
                    Label(AppLocalization.string("Review Profiles"), systemImage: "doc.badge.gearshape")
                }
                .accessibilityIdentifier("recovery-reviewProfiles")
                if plan.primaryAction == .reviewProfiles {
                    button.aetherButton(prominent: true)
                } else {
                    button.aetherButton()
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
            .aetherLargeSheetFrame()
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
                        .font(.largeTitle.weight(.bold))
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
                        .foregroundStyle(tunnel.isFailed ? AnyShapeStyle(AetherReadableTint(color: .orange)) : AnyShapeStyle(Color.accentColor))
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
        // The state colour as a top-leading ambient wash over the card, which
        // the readable grey on it was measured against (strongSecondaryText).
        .background(
            heroAmbientWash,
            in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
        )
        .aetherPanel()
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
            effectiveReduceMotion ? nil : AetherVisual.panelSpring,
            value: tunnel.state
        )
    }

    private var phase: ConnectionMedallion.Phase {
        ConnectionMedallion.Phase(tunnel: tunnel)
    }

    private var heroAmbientWash: LinearGradient {
        switch phase {
        case .connected: AetherVisual.heroConnectedWash
        case .working: AetherVisual.heroRecoveringWash
        case .failed: AetherVisual.heroFailedWash
        case .idle: AetherVisual.heroDisconnectedWash
        }
    }

    private var approvalControls: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(AppLocalization.string("In System Settings, open General > Login Items & Extensions > Network Extensions, then enable AetherRoute. This window will update after approval."))
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
                    Label(AppLocalization.string("Open System Settings"), systemImage: "gearshape")
                }
                .aetherButton(prominent: true)
                .accessibilityIdentifier("extension-approval-open-settings")
                Button {
                    Task { await tunnel.recheckSystemExtensionApproval() }
                } label: {
                    Label(AppLocalization.string("Check Again"), systemImage: "arrow.clockwise")
                }
                .aetherButton()
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
            let outlet = ActiveOutlet(tunnel: tunnel)
            TimelineView(.periodic(from: since, by: 60)) { context in
                let duration = AppLocalization.duration(context.date.timeIntervalSince(since))
                if let outlet {
                    if outlet.isDirectMode {
                        let connectedPrefix = String.localizedStringWithFormat(
                            AppLocalization.string("Connected for %@"),
                            duration
                        )
                        Text(verbatim: "\(connectedPrefix) · \(outlet.resolvedNode)")
                    } else {
                        Text(String.localizedStringWithFormat(
                            AppLocalization.string("Connected for %@ · via %@"),
                            duration,
                            outlet.resolvedNode
                        ))
                    }
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

    /// How far the halo and the connecting arc reach past the medallion,
    /// relative to its size so the compact medallion keeps the proportion.
    private var haloOutset: CGFloat { size * 0.11 }

    var body: some View {
        ZStack {
            Circle()
                .fill(AetherVisual.tintFill(phase.color))
                .padding(-haloOutset)
            Circle()
                .strokeBorder(AetherVisual.tintBorder(phase.color), lineWidth: 1)
                .padding(-haloOutset)
            Circle()
                .fill(phase.color.gradient)
                .overlay {
                    Circle()
                        .strokeBorder(AetherVisual.medallionInnerRing, lineWidth: 1)
                }
            Image(systemName: phase.symbol)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(
                    (reduceMotion || uiReviewRequestsReducedMotion)
                        ? .identity
                        : .symbolEffect(.replace)
                )
            if phase == .working {
                TimelineView(.animation(paused: reduceMotion || uiReviewRequestsReducedMotion)) { context in
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(phase.color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .padding(-haloOutset)
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
struct OverviewRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var help: HelpTopic?
    /// Puts the trailing control below the title, for when a fixed-width
    /// control does not fit beside it.
    var isStacked = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        Group {
            if isStacked {
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    label
                    trailing
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.vertical, AetherVisual.s2)
            } else {
                HStack(spacing: AetherVisual.s3) {
                    label
                    Spacer(minLength: AetherVisual.s3)
                    trailing
                }
            }
        }
        .frame(minHeight: AetherVisual.rowHeight)
        .padding(.horizontal, AetherVisual.s4)
    }

    private var label: some View {
        OverviewRowLabel(symbol: symbol, tint: tint, title: title, help: help)
    }
}

/// The tile, title and help button that lead an Overview row.
private struct OverviewRowLabel: View {
    let symbol: String
    let tint: Color
    let title: String
    var help: HelpTopic?

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: symbol, color: tint, size: AetherVisual.rowTileSize)
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
        }
    }
}

/// A mode row: title, hint and control on one line when they fit, without
/// the hint when only the title and control do, and the control below the
/// title otherwise (long translations, narrow windows).
private struct OverviewModeRow<Control: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let help: HelpTopic
    let hint: String
    @ViewBuilder var control: Control

    var body: some View {
        OverviewAdaptiveRowLayout {
            OverviewRowLabel(symbol: symbol, tint: tint, title: title, help: help)
            // Proposed no width when it does not fit, it draws nothing
            // rather than a lone ellipsis, without duplicating via ViewThatFits.
            AetherSessionOptionalSlotLayout {
                ModeHint(text: hint)
            }
            control
        }
        .frame(minHeight: AetherVisual.rowHeight)
        .padding(.horizontal, AetherVisual.s4)
    }
}

/// Lays out a mode row's label, hint and control. One instance of each
/// rather than `ViewThatFits` over three whole rows, which built and
/// measured a native segmented control for every candidate on each visit
/// to Overview (1.5.1).
private struct OverviewAdaptiveRowLayout: Layout {
    private enum Arrangement {
        case withHint
        case inline
        case stacked
    }

    private static let gap = AetherVisual.s3
    private static let stackedSpacing = AetherVisual.s2

    private func arrangement(width: CGFloat, subviews: Subviews) -> Arrangement {
        let label = subviews[0].sizeThatFits(.unspecified).width
        let hint = subviews[1].sizeThatFits(.unspecified).width
        let control = subviews[2].sizeThatFits(.unspecified).width
        if label + Self.gap + hint + Self.gap + control <= width { return .withHint }
        if label + Self.gap + control <= width { return .inline }
        return .stacked
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let control = subviews[2].sizeThatFits(.unspecified)
        let label = subviews[0].sizeThatFits(.unspecified)
        let hint = subviews[1].sizeThatFits(.unspecified)
        // A zero-width probe asks for a minimum: answer with one line rather
        // than a label wrapped to nothing.
        guard let proposedWidth = proposal.width, proposedWidth >= 1, proposedWidth.isFinite else {
            return CGSize(width: 0, height: max(label.height, hint.height, control.height))
        }
        let width = proposedWidth
        switch arrangement(width: width, subviews: subviews) {
        case .withHint, .inline:
            return CGSize(width: width, height: max(label.height, hint.height, control.height))
        case .stacked:
            let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
            return CGSize(
                width: width,
                height: Self.stackedSpacing * 3 + wrapped.height + control.height
            )
        }
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let control = subviews[2].sizeThatFits(.unspecified)
        let hidden = ProposedViewSize(width: 0, height: 0)
        switch arrangement(width: bounds.width, subviews: subviews) {
        case .withHint, .inline:
            let showsHint = arrangement(width: bounds.width, subviews: subviews) == .withHint
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .unspecified)
            subviews[2].place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .trailing, proposal: .unspecified)
            subviews[1].place(
                at: CGPoint(x: bounds.maxX - control.width - Self.gap, y: bounds.midY),
                anchor: .trailing,
                proposal: showsHint ? .unspecified : hidden
            )
        case .stacked:
            let wrapped = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY + Self.stackedSpacing),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: nil)
            )
            subviews[2].place(
                at: CGPoint(x: bounds.maxX, y: bounds.minY + Self.stackedSpacing * 2 + wrapped.height),
                anchor: .topTrailing,
                proposal: .unspecified
            )
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY), proposal: hidden)
        }
    }
}

struct OverviewRowDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, AetherVisual.rowDividerInset)
    }
}

// BEGIN OverviewExitDrawerPolicy
enum OverviewExitDrawerPolicy {
    private static let metadataTokens = [
        "剩余流量", "套餐到期", "过期时间", "距离下次重置", "已用流量", "重置流量", "流量重置",
        "expire", "remaining", "traffic", "官网:", "官网：", "网址:", "网址："
    ]

    static func isSubscriptionNotice(_ member: String) -> Bool {
        let trimmed = member.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        let lower = trimmed.lowercased()
        return metadataTokens.contains { lower.contains($0.lowercased()) }
    }

    static func selectableGroups(
        in groups: [ProxyGroupConfigurationSummary]
    ) -> [ProxyGroupConfigurationSummary] {
        groups.filter {
            $0.strategy.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "select"
                && $0.name.uppercased() != "GLOBAL"
        }
    }

    static func displayMembers(from members: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for member in members where !isSubscriptionNotice(member) {
            if seen.insert(member).inserted {
                result.append(member)
            }
        }
        return result
    }

    static func shouldShowSearch(memberCount: Int) -> Bool {
        memberCount > 6
    }

    static func filterMembers(
        _ members: [String],
        query: String,
        protocolByName: [String: String],
        transportByName: [String: String],
        dialerByName: [String: String]
    ) -> [String] {
        NodeRegion.filterMembers(
            members,
            protocolByName: protocolByName,
            transportByName: transportByName,
            dialerByName: dialerByName,
            query: query,
            hideTimedOut: false,
            isTimedOut: { _ in false },
            selectedMember: nil
        )
    }

    static func resolvedActiveGroup(
        mode: RoutingMode,
        selectedGroupName: String?,
        primaryGroup: ProxyGroupConfigurationSummary?,
        manualGroups: [ProxyGroupConfigurationSummary],
        globalGroup: ProxyGroupConfigurationSummary?
    ) -> ProxyGroupConfigurationSummary? {
        switch mode {
        case .global:
            return globalGroup
        case .rule, .direct:
            if let selectedGroupName,
               let matched = manualGroups.first(where: { $0.name == selectedGroupName }) {
                return matched
            }
            if let primaryGroup,
               manualGroups.contains(where: { $0.name == primaryGroup.name }) {
                return primaryGroup
            }
            return manualGroups.first ?? primaryGroup ?? globalGroup
        }
    }

    static func shouldSwitchToManualBeforeSelecting(
        groupName: String,
        isFastestMode: Bool
    ) -> Bool {
        groupName.uppercased() != "GLOBAL" && isFastestMode
    }

    static func protocolBadgeLabel(
        for member: String,
        protocolsByName: [String: String],
        groupNames: Set<String>
    ) -> String? {
        let upper = member.uppercased()
        if upper == "DIRECT" || upper == "REJECT" || upper == "REJECT-DROP" {
            return upper
        }
        if groupNames.contains(member) {
            return "GROUP"
        }
        if let proto = protocolsByName[member]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !proto.isEmpty {
            return proto.uppercased()
        }
        return nil
    }
}
// END OverviewExitDrawerPolicy

/// The exit node; clicking expands an inline drawer in Rule/Global mode so nodes can be
/// switched right from Overview without leaving the page.
private struct OverviewExitRow: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var isExpanded = false
    @State private var selectedGroupName: String?
    @State private var searchText = ""
    @State private var pendingMember: String?

    private var effectiveRoutingMode: RoutingMode {
        tunnel.isConnected
            ? (tunnel.sessionRoutingMode ?? tunnel.routingMode)
            : tunnel.routingMode
    }

    private var allGroups: [ProxyGroupConfigurationSummary] {
        tunnel.activeProfileSummary?.proxyGroups ?? []
    }

    private var manualGroups: [ProxyGroupConfigurationSummary] {
        OverviewExitDrawerPolicy.selectableGroups(in: allGroups)
    }

    private var activeDrawerGroup: ProxyGroupConfigurationSummary? {
        OverviewExitDrawerPolicy.resolvedActiveGroup(
            mode: effectiveRoutingMode,
            selectedGroupName: selectedGroupName,
            primaryGroup: tunnel.resolvedPrimaryRoutingGroup(),
            manualGroups: manualGroups,
            globalGroup: tunnel.globalProxyGroup ?? tunnel.menuGlobalProxyGroup
        )
    }

    private var proxySummaryByName: [String: ProxyConfigurationSummary] {
        Dictionary(
            (tunnel.activeProfileSummary?.proxies ?? []).map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    private var unsupportedNames: Set<String> {
        Set(
            (tunnel.activeProfileSummary?.proxies ?? [])
                .filter { !$0.recognition.isSelectable }
                .map(\.name)
        )
    }

    var body: some View {
        let outlet = ActiveOutlet(tunnel: tunnel)
        let drawerGroup = activeDrawerGroup

        VStack(spacing: 0) {
            Button {
                if drawerGroup == nil {
                    if isExpanded {
                        withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                            isExpanded = false
                        }
                    }
                    NotificationCenter.default.post(
                        name: .aetherRouteNavigateToSection,
                        object: AppSection.proxies.rawValue
                    )
                } else {
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        isExpanded.toggle()
                    }
                }
            } label: {
                OverviewRow(symbol: "globe", tint: .indigo, title: AppLocalization.string("Exit node")) {
                    HStack(spacing: AetherVisual.s2) {
                        if let outlet {
                            if outlet.isDirectMode {
                                Text(verbatim: outlet.resolvedNode)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityIdentifier("overview-active-outlet-node")
                            } else {
                                let node = outlet.resolvedNode
                                AetherRegionCode(name: node, reservesSlot: false)
                                Text(verbatim: node)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .accessibilityIdentifier("overview-active-outlet-node")
                                HeaderLatencyLeaf(
                                    groupName: outlet.groupName,
                                    member: outlet.node,
                                    latencyStore: tunnel.latencyStore,
                                    tunnel: tunnel
                                )
                            }
                        } else {
                            Text(AppLocalization.string("Choose a node"))
                                .foregroundStyle(AetherVisual.secondaryText)
                        }
                        Image(
                            systemName: drawerGroup == nil
                                ? "chevron.right"
                                : (isExpanded ? "chevron.up" : "chevron.down")
                        )
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AetherVisual.tertiaryText)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.aetherPressable)
            .accessibilityElement(children: .combine)
            .accessibilityHint(
                drawerGroup == nil
                    ? AppLocalization.string("Opens Proxies to change the node")
                    : AppLocalization.string("Expands node list to switch the exit node")
            )
            .accessibilityIdentifier("overview-active-outlet")

            if isExpanded, let group = drawerGroup {
                OverviewRowDivider()
                drawerContent(for: group)
                    .transition(.opacity)
            }
        }
        // The selection is read from the extension (or the profile while
        // disconnected); without this the row said "Choose a node" until
        // the Proxies page had been opened once.
        .task(id: "\(primaryGroupName ?? ""):\(tunnel.isConnected):\(effectiveRoutingMode.rawValue)") {
            if effectiveRoutingMode == .global {
                tunnel.seedGlobalSelectionIfNeeded()
                await tunnel.refreshProxySelection(group: "GLOBAL")
            }
            guard let primaryGroupName else { return }
            await tunnel.refreshProxySelection(group: primaryGroupName)
        }
        .onChange(of: effectiveRoutingMode) { _, _ in
            searchText = ""
        }
    }

    private func drawerContent(for group: ProxyGroupConfigurationSummary) -> some View {
        let rawMembers = group.name == "GLOBAL"
            ? group.members
            : (tunnel.proxySelections[group.name]?.members ?? group.members)
        let cleanMembers = OverviewExitDrawerPolicy.displayMembers(from: rawMembers)
        let summaries = proxySummaryByName
        let protocolsByName = summaries.mapValues(\.protocolName)
        let transportsByName = summaries.compactMapValues(\.transportName)
        let dialersByName = summaries.compactMapValues(\.dialerProxy)
        let filteredMembers = OverviewExitDrawerPolicy.filterMembers(
            cleanMembers,
            query: searchText,
            protocolByName: protocolsByName,
            transportByName: transportsByName,
            dialerByName: dialersByName
        )
        let groupNames = Set(allGroups.map(\.name))
        let selectedMember = resolvedSelectedMember(for: group)
        let showsFastestNote = OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(
            groupName: group.name,
            isFastestMode: tunnel.proxySelectionMode(for: group.name) == .fastest
        )

        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            if effectiveRoutingMode == .direct {
                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityHidden(true)
                    Text(
                        AppLocalization.string("Direct mode routes all traffic without a proxy. Selected node takes effect in Rule or Global mode.")
                    )
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("overview-outlet-direct-mode-banner")

                    Button {
                        Task { await tunnel.setRoutingMode(.rule) }
                    } label: {
                        Text(
                            AppLocalization.string("Switch to Rule Mode")
                        )
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("overview-outlet-switch-to-rule")
                }
                .padding(.horizontal, AetherVisual.s2)
                .padding(.vertical, AetherVisual.sCompact)
                .background(
                    AetherVisual.subtleFill,
                    in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                )
            }

            HStack(spacing: AetherVisual.s2) {
                groupToolbarSwitcher(activeGroup: group)
                Spacer(minLength: AetherVisual.s1)
                HStack(spacing: AetherVisual.sCompact) {
                    if OverviewExitDrawerPolicy.shouldShowSearch(memberCount: cleanMembers.count) {
                        AetherSearchField(
                            text: $searchText,
                            prompt: AppLocalization.string("Search nodes"),
                            accessibilityIdentifier: "overview-outlet-search"
                        )
                        .frame(maxWidth: AetherVisual.searchFieldMinWidth)
                    }
                    DrawerTestLatencyButton(
                        groupName: group.name,
                        latencyStore: tunnel.latencyStore,
                        action: {
                            Task { await tunnel.testProxyLatency(group: group.name) }
                        }
                    )

                    Button {
                        NotificationCenter.default.post(
                            name: .aetherRouteNavigateToSection,
                            object: AppSection.proxies.rawValue
                        )
                    } label: {
                        HStack(spacing: AetherVisual.sMicro) {
                            Text(AppLocalization.string("Open Proxies"))
                            Image(systemName: "arrow.up.right")
                                .font(.caption2.weight(.semibold))
                                .accessibilityHidden(true)
                        }
                        .lineLimit(1)
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("overview-outlet-open-proxies")
                }
            }

            if showsFastestNote {
                Text(
                    AppLocalization.string("Auto-fastest active · click any node to switch to manual")
                )
                .font(.caption2)
                .foregroundStyle(AetherVisual.secondaryText)
                .accessibilityIdentifier("overview-outlet-fastest-note")
            }

            if cleanMembers.isEmpty {
                Text(AppLocalization.string("No nodes available"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AetherVisual.s3)
            } else if filteredMembers.isEmpty {
                Text(AppLocalization.string("No matching nodes"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, AetherVisual.s3)
            } else {
                let deterministicHeight = min(
                    CGFloat(filteredMembers.count) * AetherVisual.tableRowHeight
                        + CGFloat(max(0, filteredMembers.count - 1)) * AetherVisual.sMicro,
                    240
                )
                let unavailableSet = unsupportedNames
                ScrollView {
                    LazyVStack(spacing: AetherVisual.sMicro) {
                        ForEach(filteredMembers, id: \.self) { member in
                            drawerNodeRow(
                                member: member,
                                group: group,
                                isSelected: member == selectedMember,
                                isUnavailable: unavailableSet.contains(member),
                                proxySummary: summaries[member],
                                badgeLabel: OverviewExitDrawerPolicy.protocolBadgeLabel(
                                    for: member,
                                    protocolsByName: protocolsByName,
                                    groupNames: groupNames
                                )
                            )
                        }
                    }
                }
                .frame(height: deterministicHeight)
                .frame(maxHeight: 240)
            }
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .task(id: "\(group.name):\(tunnel.isConnected)") {
            if group.name == "GLOBAL" {
                tunnel.seedGlobalSelectionIfNeeded()
            }
            await tunnel.refreshProxySelection(group: group.name)
            guard !Task.isCancelled else { return }
            if tunnel.isConnected {
                await tunnel.refreshProxyLatencyIfNeeded(group: group.name)
            }
        }
    }

    @ViewBuilder
    private func groupToolbarSwitcher(activeGroup: ProxyGroupConfigurationSummary) -> some View {
        if effectiveRoutingMode == .global {
            groupPillLabel("GLOBAL", isSelected: true)
                .accessibilityIdentifier("overview-outlet-group-GLOBAL")
        } else if manualGroups.count > 1 {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AetherVisual.s1) {
                    ForEach(manualGroups) { candidate in
                        let isSelectedGroup = candidate.name == activeGroup.name
                        Button {
                            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                                selectedGroupName = candidate.name
                                searchText = ""
                            }
                            Task {
                                await tunnel.refreshProxySelection(group: candidate.name)
                            }
                        } label: {
                            groupPillLabel(candidate.name, isSelected: isSelectedGroup)
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("overview-outlet-group-\(candidate.name)")
                    }
                }
            }
        } else {
            groupPillLabel(activeGroup.name, isSelected: true)
                .accessibilityIdentifier("overview-outlet-group-\(activeGroup.name)")
        }
    }

    private func groupPillLabel(_ title: String, isSelected: Bool) -> some View {
        Text(verbatim: title)
            .font(.caption.weight(isSelected ? .semibold : .medium))
            .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
            .lineLimit(1)
            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
            .padding(.vertical, AetherVisual.pillVerticalPadding)
            .background(
                isSelected ? AetherVisual.selectionFill : AetherVisual.neutralFill,
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .strokeBorder(
                        isSelected ? AetherVisual.tintBorder(.accentColor) : AetherVisual.cardStroke,
                        lineWidth: 1
                    )
            }
    }

    private func drawerNodeRow(
        member: String,
        group: ProxyGroupConfigurationSummary,
        isSelected: Bool,
        isUnavailable: Bool,
        proxySummary: ProxyConfigurationSummary?,
        badgeLabel: String?
    ) -> some View {
        let isSwitchingThis = pendingMember == member
        let isSelectionDisabled = pendingMember != nil
            || tunnel.proxySelectionRequests.contains(group.name)
            || group.strategy.lowercased() != "select"
            || isUnavailable

        return Button {
            let needsManualSwitch = OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(
                groupName: group.name,
                isFastestMode: tunnel.proxySelectionMode(for: group.name) == .fastest
            )
            guard needsManualSwitch || member != resolvedSelectedMember(for: group) else { return }
            pendingMember = member
            Task {
                defer { pendingMember = nil }
                if group.name == "GLOBAL" {
                    await tunnel.selectGlobalOutlet(member)
                } else {
                    if OverviewExitDrawerPolicy.shouldSwitchToManualBeforeSelecting(
                        groupName: group.name,
                        isFastestMode: tunnel.proxySelectionMode(for: group.name) == .fastest
                    ) {
                        await tunnel.setProxySelectionMode(.manual, for: group.name)
                    }
                    await tunnel.selectProxy(group: group.name, member: member)
                }
            }
        } label: {
            HStack(spacing: AetherVisual.s2) {
                if isSwitchingThis {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: AetherVisual.s3)
                } else {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.subheadline)
                        .foregroundStyle(
                            isSelected
                                ? AnyShapeStyle(Color.accentColor)
                                : AnyShapeStyle(AetherVisual.tertiaryText)
                        )
                        .frame(width: AetherVisual.s3)
                        .accessibilityHidden(true)
                }
                AetherRegionCode(name: member, reservesSlot: true)
                Text(verbatim: member)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let badgeLabel {
                    AetherProtocolBadge(
                        type: badgeLabel,
                        transport: proxySummary?.transportName
                    )
                }
                DrawerNodeLatencyLeaf(
                    groupName: group.name,
                    member: member,
                    isUnavailable: isUnavailable,
                    latencyStore: tunnel.latencyStore,
                    tunnel: tunnel
                )
            }
            .padding(.horizontal, AetherVisual.s2)
            .padding(.vertical, AetherVisual.sCompact)
            .background(
                RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                    .fill(isSelected ? AetherVisual.selectionFill : Color.clear)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                        .strokeBorder(AetherVisual.tintBorder(.accentColor), lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.aetherPressable)
        .disabled(isSelectionDisabled)
        .accessibilityIdentifier("overview-outlet-node-\(member)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func resolvedSelectedMember(for group: ProxyGroupConfigurationSummary) -> String? {
        if group.name == "GLOBAL" {
            return tunnel.proxySelections["GLOBAL"]?.selectedMember
                ?? tunnel.activeProfileSummary.flatMap { TunnelManager.resolvedGlobalTargetMember(in: $0) }
        }
        return tunnel.proxySelections[group.name]?.selectedMember
    }

    private var primaryGroupName: String? {
        tunnel.resolvedPrimaryRoutingGroup()?.name
    }

    private struct HeaderLatencyLeaf: View {
        let groupName: String
        let member: String
        @ObservedObject var latencyStore: ProxyLatencyStore
        let tunnel: TunnelManager

        var body: some View {
            let _ = latencyStore.proxyLatencies[groupName]
            let _ = latencyStore.proxyLatencyRequests.contains(groupName)
            let _ = latencyStore.memberLatencyRequests
            let resolved = tunnel.resolvedOutletLatencyStatus(groupName: groupName, selectedMember: member)
            if resolved.status != .untested || tunnel.isConnected {
                ProxyLatencyText(status: resolved.status)
            }
        }
    }

    private struct DrawerTestLatencyButton: View {
        let groupName: String
        @ObservedObject var latencyStore: ProxyLatencyStore
        let action: () -> Void

        var body: some View {
            let isTestingGroup = latencyStore.proxyLatencyRequests.contains(groupName)
            Button(action: action) {
                AetherProgressButtonLabel(
                    AppLocalization.string("Test latency"),
                    systemImage: "bolt",
                    isWorking: isTestingGroup
                )
            }
            .aetherButton()
            .controlSize(.small)
            .disabled(isTestingGroup)
            .accessibilityIdentifier("overview-outlet-latency")
        }
    }

    private struct DrawerNodeLatencyLeaf: View {
        let groupName: String
        let member: String
        let isUnavailable: Bool
        @ObservedObject var latencyStore: ProxyLatencyStore
        let tunnel: TunnelManager

        var body: some View {
            let _ = latencyStore.proxyLatencies[groupName]
            let _ = latencyStore.proxyLatencyRequests.contains(groupName)
            let _ = latencyStore.memberLatencyRequests
            let resolved: (status: ProxyLatencyStatus, confidence: ProxyLatencyConfidence) = isUnavailable
                ? (.timedOut, tunnel.latencyConfidence(group: groupName, member: member))
                : tunnel.resolvedOutletLatencyStatus(groupName: groupName, selectedMember: member)
            ProxyLatencyText(
                status: resolved.status,
                confidence: resolved.confidence
            )
        }
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
            // Side by side with its hint, then without it; when even the
            // control alone does not fit beside the title (long
            // translations), the control moves below it rather than
            // overlapping the title and widening the page.
            OverviewModeRow(
                symbol: "arrow.triangle.branch",
                tint: .orange,
                title: AppLocalization.string("Routing mode"),
                help: .routingMode,
                hint: routingMode.shortHint
            ) {
                routingPicker
            }
#if AETHERROUTE_INDEPENDENT
            OverviewRowDivider()
            OverviewModeRow(
                symbol: networkEngineMode == .tun ? "bolt.shield.fill" : "shield.fill",
                tint: .blue,
                title: AppLocalization.string("Network engine"),
                help: .networkEngine,
                hint: networkEngineMode.shortHint
            ) {
                enginePicker
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
        .frame(minWidth: 240, alignment: .trailing)
    }
#endif
}

/// Route quality behind a tunnel that is already carrying traffic. The
/// tunnel being up and the route being fast are separate questions; this
/// answers the second without implying the first is in doubt.
private struct OverviewRouteCheckRow: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                            .foregroundStyle(tintStyle(quality))
                            .symbolEffect(.pulse, isActive: !reduceMotion && quality == .verifying)
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
                    .aetherButton()
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

    private func tintStyle(_ quality: ConnectionQuality?) -> AnyShapeStyle {
        switch quality {
        case nil, .unknown: AnyShapeStyle(AetherVisual.secondaryText)
        case .verifying: AnyShapeStyle(Color.accentColor)
        case .verified: AnyShapeStyle(AetherReadableTint(color: .green))
        case .degraded: AnyShapeStyle(AetherReadableTint(color: .orange))
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
        // In the panel, equal segments sized to "● Transparent" came to about
        // 202 pt and overran its 184-pt slot and the card edge; segments sized
        // in proportion to their labels fill exactly the slot instead.
        control.segmentDistribution = marksSelection ? .fillProportionally : .fillEqually
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
                    Circle().fill(dot).frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                }
                Text(label)
                    .lineLimit(1)
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

/// The sidebar's live connection count. It observes telemetry on its own so
/// each sample redraws only this badge, not the sidebar or the page.
private struct ConnectionCountBadge: View {
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        let count = telemetry.snapshot.totalActiveConnections
        if count > 0 {
            AetherCountBadge(count: count)
        }
    }
}

/// Opens the traffic statistics from the overview's traffic card.
private struct TrafficStatisticsButton: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var isPresented = false

    var body: some View {
        Button(AppLocalization.string("Statistics…")) {
            isPresented = true
        }
        .buttonStyle(.link)
        .font(.caption)
        .accessibilityIdentifier("overview-traffic-statistics")
        .sheet(isPresented: $isPresented) {
            TrafficStatisticsSheet(statistics: tunnel.trafficStatistics)
                .environmentObject(tunnel)
        }
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
                .font(.largeTitle.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(isConnected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AetherVisual.secondaryText))
                .aetherLiveValue()
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
            return String(telemetry.snapshot.totalActiveConnections)
        }
    }

    private func split(_ text: String) -> (number: String, unit: String?) {
        guard let space = text.lastIndex(of: " ") else { return (text, nil) }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }
}

private enum LiveMemoryMetricKind {
    case core
    case app
}

/// One inline memory metric (Core or App) with its static label and leaf
/// observed current footprint and 30-second peak for the bottom status strip.
private struct LiveMemoryWell: View {
    let kind: LiveMemoryMetricKind
    let isConnected: Bool
    let telemetry: NetworkTelemetryViewModel

    private var title: String {
        switch kind {
        case .core: AppLocalization.string("Core memory")
        case .app: AppLocalization.string("App memory")
        }
    }

    private var tint: Color {
        switch kind {
        case .core: .mint
        case .app: .indigo
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.sCompact) {
            Circle()
                .fill(tint)
                .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 3 }
            Text(title)
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
            LiveMemoryWellValue(
                kind: kind,
                isConnected: isConnected,
                model: telemetry
            )
        }
        .font(.caption)
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier(kind == .core ? "overview-core-memory" : "overview-app-memory")
    }
}

private struct LiveMemoryWellValue: View {
    let kind: LiveMemoryMetricKind
    let isConnected: Bool
    @ObservedObject var model: NetworkTelemetryViewModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
            Text(primaryText)
                .fontWeight(.semibold)
                .monospacedDigit()
                .foregroundStyle(isAvailable ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AetherVisual.secondaryText))
                .lineLimit(1)
                .aetherLiveValue()
            Text(verbatim: "(\(subtitleText))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AetherVisual.tertiaryText)
                .lineLimit(1)
                .aetherLiveValue()
        }
    }

    private var isAvailable: Bool {
        switch kind {
        case .core: isConnected && model.snapshot.memoryBytes > 0
        case .app: model.appMemoryBytes > 0
        }
    }

    private var primaryText: String {
        switch kind {
        case .core:
            guard isConnected, model.snapshot.memoryBytes > 0 else { return "—" }
            return formattedBytes(model.snapshot.memoryBytes)
        case .app:
            guard model.appMemoryBytes > 0 else { return "—" }
            return formattedBytes(model.appMemoryBytes)
        }
    }

    private var subtitleText: String {
        let samples = model.history.samples
        switch kind {
        case .core:
            guard isConnected, model.snapshot.memoryBytes > 0 else {
                return AppLocalization.string("Connect to measure")
            }
            let peak = max(model.snapshot.memoryBytes, TrafficHistory.peakCoreMemory(in: samples))
            return String.localizedStringWithFormat(
                AppLocalization.string("Peak %@"),
                formattedBytes(peak)
            )
        case .app:
            let peak = max(model.appMemoryBytes, TrafficHistory.peakAppMemory(in: samples))
            return String.localizedStringWithFormat(
                AppLocalization.string("Peak %@"),
                formattedBytes(peak)
            )
        }
    }
}

/// Dual-color proportional bar + total physical memory footprint on the
/// trailing end of the bottom memory status strip.
private struct LiveMemoryTotalFooter: View {
    let isConnected: Bool
    @ObservedObject var model: NetworkTelemetryViewModel

    private var coreFraction: CGFloat {
        let core = isConnected ? model.snapshot.memoryBytes : 0
        let app = model.appMemoryBytes
        let total = core + app
        guard total > 0 else { return 0 }
        return CGFloat(Double(core) / Double(total))
    }

    var body: some View {
        let barWidth: CGFloat = 72
        let coreWidth = barWidth * min(max(coreFraction, 0), 1)
        return HStack(spacing: AetherVisual.s2) {
            HStack(spacing: 0) {
                if coreWidth > 0 {
                    Rectangle()
                        .fill(Color.mint)
                        .frame(width: coreWidth)
                }
                Rectangle()
                    .fill(Color.indigo)
                    .frame(maxWidth: .infinity)
            }
            .frame(width: barWidth, height: 6)
            .background(AetherVisual.neutralFill)
            .clipShape(Capsule())
            .accessibilityHidden(true)

            Text(summaryText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .aetherLiveValue()
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var summaryText: String {
        if isConnected, model.snapshot.memoryBytes > 0 {
            let total = model.snapshot.memoryBytes + model.appMemoryBytes
            return String.localizedStringWithFormat(
                AppLocalization.string("Total %@"),
                formattedBytes(total)
            )
        }
        return String.localizedStringWithFormat(
            AppLocalization.string("App %@"),
            formattedBytes(model.appMemoryBytes)
        )
    }
}

/// Download, upload and connection count above the full-width 30-second
/// traffic waveform, with a compact live memory status strip along the bottom.
private struct TrafficCard: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let isConnected: Bool
    let isRealtime: Bool
    let isBackground: Bool
    var subscriptionUsage: SubscriptionUsage? = nil
    let telemetry: NetworkTelemetryViewModel

    private var usesStackedLayout: Bool {
        dynamicTypeSize >= .xxxLarge
            || UserDefaults.standard.bool(forKey: "NSDoubleLocalizedStrings")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            trafficSection
            if let subscriptionUsage {
                Divider()
                SubscriptionUsageLine(usage: subscriptionUsage)
            }
            Divider()
            memoryStatusStrip
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("overview-traffic")
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isConnected)
    }

    private var trafficSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .firstTextBaseline) {
                Text(AppLocalization.string("Live traffic"))
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: AetherVisual.s2)
                Text(AppLocalization.string("Last 30 seconds"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                // A leaf of its own: this card redraws with every traffic
                // sample and must not observe TunnelManager itself.
                TrafficStatisticsButton()
            }
            if usesStackedLayout {
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
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
                }
            } else {
                HStack(alignment: .bottom, spacing: AetherVisual.s6) {
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
            }
            if isConnected {
                LiveTrafficHistoryGraph(model: telemetry, isRealtime: isRealtime, isBackground: isBackground)
                    .transition(.opacity)
            } else {
                Text(AppLocalization.string("Once connected, live download and upload curves appear here."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, minHeight: AetherVisual.placeholderMinHeight)
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    .transition(.opacity)
            }
        }
    }

    private var memoryStatusStrip: some View {
        AetherMemoryStripLayout(forceStacked: usesStackedLayout) {
            Text(AppLocalization.string("Live memory"))
                .font(.caption.weight(.medium))
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
            LiveMemoryWell(
                kind: .core,
                isConnected: isConnected,
                telemetry: telemetry
            )
            LiveMemoryWell(
                kind: .app,
                isConnected: isConnected,
                telemetry: telemetry
            )
            LiveMemoryTotalFooter(
                isConnected: isConnected,
                model: telemetry
            )
        }
    }
}

/// Observe high-frequency updates only when this window is actually visible.
private struct LiveTrafficHistoryGraph: View {
    let model: NetworkTelemetryViewModel
    let isRealtime: Bool
    let isBackground: Bool

    var body: some View {
        if isRealtime || isBackground {
            LiveTrafficHistoryGraphActive(
                model: model,
                isRealtime: isRealtime,
                isBackground: isBackground
            )
        } else {
            LiveTrafficHistoryGraphFrozen(history: model.history)
        }
    }
}

private struct LiveTrafficHistoryGraphFrozen: View {
    let history: TrafficHistory

    var body: some View {
        let anchor = history.samples.last?.date ?? .now
        let samples = history.visible(at: anchor)
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack {
                Spacer(minLength: 0)
                Text(LiveTrafficHistoryGraphActive.peakRate(samples).map {
                    String.localizedStringWithFormat(AppLocalization.string("Peak %@"), $0)
                } ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AetherVisual.secondaryText)
                .aetherLiveValue()
            }
            ZStack {
                AetherTrafficMiniGraph(
                    downloadSamples: samples.map(\.download),
                    uploadSamples: samples.map(\.upload),
                    samplePositions: samples.map { TrafficHistory.position(of: $0, at: anchor) },
                    height: 80
                )
                if samples.count < 2 {
                    Text(AppLocalization.string("Collecting traffic samples…"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
            }
            HStack {
                Text(AppLocalization.string("30 s ago"))
                Spacer(minLength: AetherVisual.s2)
                Text(AppLocalization.string("Now"))
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
        }
    }
}

private struct LiveTrafficHistoryGraphActive: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var model: NetworkTelemetryViewModel
    let isRealtime: Bool
    let isBackground: Bool

    /// About 12 frames a second: silky smooth waveform progression while halving
    /// heap allocations and timer interruptions compared to 24 FPS.
    private static let frameInterval: TimeInterval = 1.0 / 12
    private static let entryLag = TimeInterval(
        TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds
    )

    var body: some View {
        // Only the waveform redraws every frame. The labels around it change
        // at most once per sample, so they sit outside the timeline: inside
        // it every caption was re-resolved and laid out 24 times a second
        // (1.5.1).
        let lastSample = model.history.samples.last?.date
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            // The chart's scale, the busiest moment in view, sits on its
            // own line so it never covers the curve.
            HStack {
                Spacer(minLength: 0)
                Text(Self.peakRate(model.history.visible(at: windowEnd(at: .now, lastSample: lastSample))).map {
                    String.localizedStringWithFormat(AppLocalization.string("Peak %@"), $0)
                } ?? " ")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AetherVisual.secondaryText)
                .aetherLiveValue()
            }
            TimelineView(
                .animation(
                    minimumInterval: Self.frameInterval,
                    paused: reduceMotion || !isRealtime || !model.history.hasActiveTraffic
                )
            ) { context in
                let now = windowEnd(at: context.date, lastSample: lastSample)
                let samples = model.history.visible(at: now)
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
            }
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

    /// Live: the window slides continuously, one sampling period behind the
    /// clock, so each new sample enters at the right edge and drifts left
    /// instead of appearing mid-chart every 3 seconds. Paused: nothing new
    /// arrives; anchoring the window at the last sample keeps the final 30
    /// seconds on screen instead of sliding them off into an empty chart.
    private func windowEnd(at date: Date, lastSample: Date?) -> Date {
        isRealtime
            ? date.addingTimeInterval(-Self.entryLag)
            : (lastSample ?? date)
    }

    fileprivate static func peakRate(_ samples: [TrafficHistory.Sample]) -> String? {
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

struct UpdateAvailableBannerView: View {
    let version: String
    let onUpdate: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            leadingIcon
            textContent
            Spacer(minLength: AetherVisual.s2)
            trailingActions
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .background(AetherVisual.cardFill)
        .overlay(alignment: .bottom) {
            Divider()
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("update-available-banner")
    }

    private var leadingIcon: some View {
        AetherIconTile(
            symbol: "sparkles",
            color: .accentColor,
            size: AetherVisual.rowTileSize
        )
    }

    private var textContent: some View {
        VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
            HStack(spacing: AetherVisual.s1) {
                Text(String(format: AppLocalization.string("AetherRoute v%@ is available"), version))
                    .font(.system(.subheadline, design: .default, weight: .semibold))

                Text(AppLocalization.string("New"))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(
                        Capsule()
                            .fill(AetherVisual.tintFill(.accentColor))
                    )
            }

            Text(AppLocalization.string("A new version is ready with improvements and bug fixes."))
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
        }
    }

    private var trailingActions: some View {
        HStack(spacing: AetherVisual.s2) {
            Button(AppLocalization.string("Update Now")) {
                onUpdate()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            .buttonStyle(.plain)
            .help(AppLocalization.string("Dismiss for this version"))
            .accessibilityLabel(AppLocalization.string("Dismiss for this version"))
        }
    }
}

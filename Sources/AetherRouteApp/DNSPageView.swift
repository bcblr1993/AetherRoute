import AetherRouteKit
import Network
import SwiftUI

struct DNSView: View {
    @Environment(\.pageSessionDrafts) private var environmentDrafts

    var body: some View {
        if let drafts = environmentDrafts?.dns {
            DNSContentView(drafts: drafts)
        } else {
            DNSStandaloneView()
        }
    }
}

private struct DNSStandaloneView: View {
    @StateObject private var fallbackDrafts = DNSPageDraftState()

    var body: some View {
        DNSContentView(drafts: fallbackDrafts)
    }
}

private struct DNSContentView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var drafts: DNSPageDraftState
    @State private var tailscale = TailscalePresence.absent
    @State private var tailscaleMonitorTask: Task<Void, Never>?
    @State private var isSavingCustomHosts = false
    @State private var isRunningLookup = false
    @State private var lookupTask: Task<Void, Never>?
    @State private var isRunningDiagnostics = false
    @State private var diagnosticsTask: Task<Void, Never>?

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        // Plain VStack (matching RulesPageView 1.7.1) to prevent LazyVStack
                        // width/constraint invalidation loops inside NavigationSplitView.
                        VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                            AetherPageHeader(.dns)
                            if tailscale.isRunning {
                                TailscaleCoexistenceNote(presence: tailscale)
                            }
                            if usesAutomaticTUNDNS(summary.dns) {
#if AETHERROUTE_INDEPENDENT
                                automaticTUNDNSCard(summary.dns)
                                tunAdjustmentsSection(summary.dns)
#endif
                            } else if summary.dns.isPresent {
                                configuredContent(summary.dns)
                            } else {
                                systemResolverContent
                            }
                            dnsLookupSection(summary: summary)
                                .id("dns-lookup-section")
                            RecentDNSQueriesCard(
                                viewModel: tunnel.dnsQueriesViewModel,
                                telemetry: tunnel.telemetryViewModel,
                                selectedFilter: $drafts.recentQueryFilter,
                                onSelectDomain: { domain in
                                    drafts.lookupQuery = domain
                                    withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) {
                                        scrollProxy.scrollTo("dns-lookup-section", anchor: .top)
                                    }
                                    runDNSLookup(summary: summary)
                                }
                            )
                            .environmentObject(tunnel)
                            RouteSimulatorSection(drafts: drafts)
                            networkDiagnosticSection(summary: summary)
                            customHostsSection
                        }
                        .aetherPageContent(.wide)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(AppLocalization.string("DNS configuration details"))
                        .accessibilityIdentifier("dns-page-content")
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                        AetherPageHeader(.dns)
                        FeatureEmptyState(
                            symbol: "network.badge.shield.half.filled",
                            title: AppLocalization.string("No DNS policy loaded"),
                            detail: AppLocalization.string("Import a validated profile to inspect its resolver behavior without exposing server addresses.")
                        )
                    }
                    .aetherPageContent(.wide)
                }
            }
        }
        .accessibilityIdentifier("dns-page")
        .onChange(of: tunnel.activeProfileID) { _, _ in
            resetTransientState()
        }
        .onAppear {
            startTailscalePathMonitor()
        }
        .task(id: tunnel.activeProfileID) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            tunnel.syncRecentDNSQueriesFromTelemetry()
        }
        .onDisappear {
            stopTailscalePathMonitor()
            cancelRunningTasks()
        }
    }

    private func startTailscalePathMonitor() {
        if let review = Self.reviewTailscale {
            tailscale = review
            return
        }
        tailscaleMonitorTask?.cancel()
        tailscaleMonitorTask = Task {
            await Task.yield()
            guard !Task.isCancelled else { return }
            let initial = await Task.detached(priority: .utility) {
                TailscalePresence.current()
            }.value
            guard !Task.isCancelled else { return }
            if initial != tailscale {
                tailscale = initial
            }
            let stream = AsyncStream<Void> { continuation in
                let monitor = NWPathMonitor()
                monitor.pathUpdateHandler = { _ in
                    continuation.yield()
                }
                continuation.onTermination = { _ in
                    monitor.cancel()
                }
                monitor.start(
                    queue: DispatchQueue(
                        label: "com.aetherroute.dns.tailscale-path-monitor",
                        qos: .utility
                    )
                )
            }
            for await _ in stream {
                guard !Task.isCancelled else { break }
                let latest = await Task.detached(priority: .utility) {
                    TailscalePresence.current()
                }.value
                guard !Task.isCancelled else { break }
                if latest != tailscale {
                    tailscale = latest
                }
            }
        }
    }

    private func stopTailscalePathMonitor() {
        tailscaleMonitorTask?.cancel()
        tailscaleMonitorTask = nil
    }

    private func cancelRunningTasks() {
        lookupTask?.cancel()
        lookupTask = nil
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        isRunningLookup = false
        isRunningDiagnostics = false
    }

    private func resetTransientState() {
        cancelRunningTasks()
        drafts.resetForProfileChange()
    }

    /// Screenshot review can show the note without Tailscale installed.
    private static var reviewTailscale: TailscalePresence? {
#if DEBUG
        switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_TAILSCALE"] {
        case "1": return TailscalePresence(isRunning: true, usesExitNode: false)
        case "exit-node": return TailscalePresence(isRunning: true, usesExitNode: true)
        default: return nil
        }
#else
        return nil
#endif
    }

    @ViewBuilder
    private func configuredContent(_ dns: DNSConfigurationSummary) -> some View {
        summaryCard(
            title: AppLocalization.string("Profile DNS"),
            caption: dns.isEnabled
                ? AppLocalization.string("From the active profile")
                : AppLocalization.string("Present in the profile but turned off"),
            stats: [
                (AppLocalization.string("Resolution mode"), modeTitle(dns.mode)),
                (AppLocalization.string("Primary"), AppLocalization.format("%lld upstreams", Int64(dns.nameserverCount))),
                (AppLocalization.string("Fallback"), AppLocalization.format("%lld resolvers", Int64(dns.fallbackCount))),
                (AppLocalization.string("Policies"), AppLocalization.format("%lld domain rules", Int64(dns.nameserverPolicyCount))),
            ],
            details: dns
        )

#if AETHERROUTE_INDEPENDENT
        tunAdjustmentsSection(dns)
#else
        resolutionBehaviorSection(dns)
#endif
    }

    // MARK: - Summary

    /// What resolves names, in one card: the mode and the counts, with the
    /// transport and Fake-IP details folded away underneath.
    private func summaryCard(
        title: String,
        caption: String,
        stats: [(String, String)],
        details: DNSConfigurationSummary?
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                Text(title)
                    .font(.headline)
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding([.horizontal, .top], AetherVisual.s4)

            DNSSummaryStatsLayout(spacing: AetherVisual.s2) {
                ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(stat.0)
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                        Text(stat.1)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .aetherNumericValue(stat.1)
                    }
                    .padding(AetherVisual.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AetherVisual.cardFill,
                        in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(AetherVisual.s4)

            if let details {
                Divider().padding(.horizontal, AetherVisual.s4)
                detailsDisclosure(details)
            }
        }
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }

    private func detailsDisclosure(_ dns: DNSConfigurationSummary) -> some View {
        let showsFakeIP = dns.mode == .fakeIP || dns.fakeIPFilterCount > 0
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(AetherVisual.animation(AetherVisual.disclosure)) {
                    drafts.showsAdvancedDNS.toggle()
                }
            } label: {
                HStack(spacing: AetherVisual.s2) {
                    AetherDisclosureChevron(isExpanded: drafts.showsAdvancedDNS)
                    Text(AppLocalization.string("Details"))
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(
                        showsFakeIP
                            ? AppLocalization.string("Encryption and Fake-IP exclusions")
                            : AppLocalization.string("Encryption")
                    )
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.s3)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(
                drafts.showsAdvancedDNS
                    ? AppLocalization.string("Expanded")
                    : AppLocalization.string("Collapsed")
            )
            .accessibilityIdentifier("dns-details-disclosure")

            if drafts.showsAdvancedDNS {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 260), spacing: AetherVisual.s4, alignment: .top)],
                    alignment: .leading,
                    spacing: AetherVisual.s4
                ) {
                    upstreamPrivacyDetails(dns)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    if showsFakeIP {
                        fakeIPDetails(dns)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding([.horizontal, .bottom], AetherVisual.s4)
                .transition(AetherVisual.insertion)
            }
        }
    }

    private func upstreamPrivacyDetails(_ dns: DNSConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            Text(AppLocalization.string("Upstream privacy"))
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Transport types"))
                        .font(.subheadline.weight(.semibold))
                    Text(AppLocalization.string("Server addresses stay hidden in this summary."))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AetherVisual.s2)
                Text(
                    AppLocalization.format(
                        "%lld total",
                        Int64(totalResolverCount(dns))
                    )
                )
                .font(.caption.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
            }

            if dns.upstreamTransports.isEmpty {
                Label(AppLocalization.string("No explicit upstream transport"), systemImage: "minus.circle")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
            } else {
                AetherFlowLayout(spacing: AetherVisual.s2) {
                    ForEach(dns.upstreamTransports, id: \.self) { transport in
                        Label(
                            transportTitle(transport),
                            systemImage: transportSymbol(transport)
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(AetherReadableTint(color: transportColor(transport)))
                        .padding(.horizontal, AetherVisual.pillHorizontalPadding)
                        .padding(.vertical, AetherVisual.pillVerticalPadding)
                        .background(
                            AetherVisual.tintFill(transportColor(transport)),
                            in: Capsule()
                        )
                    }
                }
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: AetherVisual.s3, verticalSpacing: AetherVisual.s2) {
                GridRow {
                    DNSCountLabel(AppLocalization.string("Bootstrap"))
                    Spacer(minLength: AetherVisual.s2)
                    Text(verbatim: String(dns.defaultNameserverCount))
                        .monospacedDigit()
                }
                GridRow {
                    DNSCountLabel(AppLocalization.string("Proxy hostnames"))
                    Spacer(minLength: AetherVisual.s2)
                    Text(verbatim: String(dns.proxyNameserverCount))
                        .monospacedDigit()
                }
                GridRow {
                    DNSCountLabel(AppLocalization.string("Local listener"))
                    Spacer(minLength: AetherVisual.s2)
                    Text(
                        dns.hasListener
                            ? AppLocalization.string("Configured")
                            : AppLocalization.string("None")
                    )
                }
                GridRow {
                    DNSCountLabel(AppLocalization.string("EDNS subnet"))
                    Spacer(minLength: AetherVisual.s2)
                    Text(
                        dns.hasEDNSClientSubnet
                            ? AppLocalization.string("Configured")
                            : AppLocalization.string("None")
                    )
                }
            }
            .font(.subheadline)
        }
    }

    private func fakeIPDetails(_ dns: DNSConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            Text(AppLocalization.string("Fake-IP safeguards"))
                .font(.subheadline.weight(.semibold))
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Address pool"))
                        .font(.subheadline.weight(.semibold))
                    Text(
                        dns.hasExplicitFakeIPRange
                            ? AppLocalization.string("Profile range")
                            : AppLocalization.string("Core default")
                    )
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AetherVisual.s2)
                StatePill(
                    title: modeTitle(dns.mode),
                    color: modeColor(dns.mode),
                    symbol: modeSymbol(dns.mode)
                )
            }

            HStack(spacing: AetherVisual.s2) {
                Label(
                    dns.hasExplicitFakeIPRange
                        ? AppLocalization.string("Profile range")
                        : AppLocalization.string("Core default"),
                    systemImage: "rectangle.3.group.bubble"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(AetherReadableTint(color: .accentColor))
                .padding(.horizontal, AetherVisual.pillHorizontalPadding)
                .padding(.vertical, AetherVisual.pillVerticalPadding)
                .background(
                    AetherVisual.tintFill(.accentColor),
                    in: Capsule()
                )
            }

            Divider()

            Grid(alignment: .leading, horizontalSpacing: AetherVisual.s3, verticalSpacing: AetherVisual.s2) {
                GridRow {
                    DNSCountLabel(AppLocalization.string("Bypass filters"))
                    Spacer(minLength: AetherVisual.s2)
                    Text(verbatim: String(dns.fakeIPFilterCount))
                        .monospacedDigit()
                }
                GridRow {
                    DNSCountLabel(AppLocalization.string("Fallback filter"))
                    Spacer(minLength: AetherVisual.s2)
                    Text(
                        dns.hasFallbackFilter
                            ? AppLocalization.string("Configured")
                            : AppLocalization.string("Default")
                    )
                }
            }
            .font(.subheadline)
        }
    }

#if !AETHERROUTE_INDEPENDENT
    private func resolutionBehaviorSection(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        FeatureSection(title: AppLocalization.string("Resolution behavior")) {
            VStack(spacing: 0) {
                DNSSettingRow(
                    title: AppLocalization.string("Enhanced mode"),
                    detail: modeDetail(dns.mode),
                    value: modeTitle(dns.mode),
                    symbol: modeSymbol(dns.mode),
                    tint: .blue
                )
                Divider().padding(.leading, AetherVisual.rowDividerInset)
                DNSSettingRow(
                    title: AppLocalization.string("IPv6 answers"),
                    detail: dns.allowsIPv6
                        ? AppLocalization.string("AAAA responses are allowed by this profile.")
                        : AppLocalization.string("AAAA responses are filtered by this profile."),
                    value: dns.allowsIPv6
                        ? AppLocalization.string("Allowed")
                        : AppLocalization.string("Filtered"),
                    symbol: "6.circle",
                    tint: .teal
                )
                Divider().padding(.leading, AetherVisual.rowDividerInset)
                DNSSettingRow(
                    title: AppLocalization.string("Rule-aware queries"),
                    detail: dns.respectsRules
                        ? AppLocalization.string("Upstream queries follow the routing rule engine.")
                        : AppLocalization.string("Upstream queries use the core's direct DNS path."),
                    value: dns.respectsRules
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "arrow.triangle.branch",
                    tint: .purple
                )
                Divider().padding(.leading, AetherVisual.rowDividerInset)
                DNSSettingRow(
                    title: AppLocalization.string("Hosts mapping"),
                    detail: dns.usesHosts
                        ? AppLocalization.string("Profile hosts entries participate in resolution.")
                        : AppLocalization.string("Profile hosts entries are ignored for DNS."),
                    value: dns.usesHosts
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "house.and.flag",
                    tint: .indigo
                )
            }
            .aetherPanel()
        }
    }
#endif

#if AETHERROUTE_INDEPENDENT
    /// TUN without an enabled DNS section in the profile: TUN's own resolver.
    private func automaticTUNDNSCard(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        let mode = tunnel.dnsRuntimePolicy
            .effectivePacketTunnelResolutionMode(for: dns)
        let allowsIPv6 = tunnel.dnsRuntimePolicy
            .effectivePacketTunnelAllowsIPv6(
                for: dns,
                profileAllowsIPv6: tunnel.activeProfileSummary?.allowsIPv6 == true
            )
        return summaryCard(
            title: AppLocalization.string("Automatic TUN DNS"),
            caption: AppLocalization.string("The profile has no DNS section turned on, so TUN resolves names itself."),
            stats: [
                (AppLocalization.string("Resolution mode"), modeTitle(mode)),
                (AppLocalization.string("IPv6 answers"), onOffTitle(allowsIPv6)),
            ],
            details: nil
        )
    }

    // MARK: - Adjustments in TUN mode

    private func tunAdjustmentsSection(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s2) {
                Text(AppLocalization.string("DNS adjustments in TUN mode"))
                    .font(.headline)
                AetherHelpButton(topic: .dnsRuntimeOverrides)
                Spacer(minLength: AetherVisual.s2)
                // Only offered once something was changed; it replaces the
                // old "Customized" badge.
                // A link button does not look disabled, so while the policy
                // is locked it is left out rather than shown dead.
                if tunnel.networkEngineMode == .tun,
                   !tunnel.dnsRuntimePolicy.isInherited,
                   tunnel.canModifyDNSRuntimePolicy {
                    Button {
                        Task { await tunnel.setDNSRuntimePolicy(DNSRuntimePolicy()) }
                    } label: {
                        Label(AppLocalization.string("Restore defaults"), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.link)
                    .accessibilityIdentifier("dns-restore-defaults")
                    .transition(.opacity)
                }
            }

            if tunnel.networkEngineMode == .tun {
                tunPolicyForm(dns)
                    .transition(.opacity)
            } else {
                transparentProxyNotice
                    .transition(.opacity)
            }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.networkEngineMode)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: tunnel.dnsRuntimePolicy.isInherited)
    }

    /// With Transparent Proxy none of the adjustments apply, so instead of a
    /// card of controls that cannot be used: why, and the way to TUN.
    private var transparentProxyNotice: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherStatusSymbol(symbol: "info.circle.fill", color: .blue)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.string("Transparent Proxy is on"))
                    .font(.headline)
                Text(AppLocalization.string("With Transparent Proxy, apps use the system DNS. Switch to TUN to adjust the resolution mode, IPv6 and more here."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AetherVisual.s3)
            Button {
                Task { await tunnel.setNetworkEngineMode(.tun) }
            } label: {
                AetherProgressButtonLabel(
                    AppLocalization.string("Switch to TUN"),
                    systemImage: "arrow.left.arrow.right",
                    isWorking: tunnel.isSwitchingNetworkEngine
                )
            }
            .aetherButton()
            .disabled(!tunnel.canChangeNetworkEngine)
            .help(AppLocalization.string("While connected, AetherRoute reconnects with TUN."))
            .accessibilityIdentifier("dns-switch-to-tun")
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
    }

    /// Settings-style rows: the name on the left, a menu on the right whose
    /// "Follow profile" entry names what the profile says.
    private func tunPolicyForm(_ dns: DNSConfigurationSummary) -> some View {
        let policy = tunnel.dnsRuntimePolicy
        let profileMode = DNSRuntimePolicy.inherited.effectivePacketTunnelResolutionMode(for: dns)
        let profileIPv6 = DNSRuntimePolicy.inherited.effectivePacketTunnelAllowsIPv6(
            for: dns,
            profileAllowsIPv6: tunnel.activeProfileSummary?.allowsIPv6 == true
        )
        return VStack(spacing: 0) {
            policyRow(
                AppLocalization.string("Resolution mode"),
                help: .dnsResolutionMode,
                isChanged: policy.resolutionMode != .inherit
            ) {
                Picker(AppLocalization.string("Resolution mode"), selection: resolutionModeBinding) {
                    ForEach(DNSRuntimeResolutionMode.allCases, id: \.self) { mode in
                        Text(runtimeModeTitle(mode, profileMode: profileMode)).tag(mode)
                    }
                }
                .accessibilityIdentifier("dns-runtime-resolution-mode")
            }
            Divider().padding(.horizontal, AetherVisual.s4)
            policyRow(
                AppLocalization.string("IPv6 answers"),
                help: .dnsIPv6,
                isChanged: policy.ipv6 != .inherit
            ) {
                booleanMenu(
                    AppLocalization.string("IPv6 answers"),
                    selection: booleanBinding(\.ipv6),
                    profileValue: profileIPv6
                )
                .accessibilityIdentifier("dns-runtime-ipv6")
            }
            Divider().padding(.horizontal, AetherVisual.s4)
            policyRow(
                AppLocalization.string("Rule-aware queries"),
                help: .dnsRespectRules,
                isChanged: policy.respectsRules != .inherit
            ) {
                booleanMenu(
                    AppLocalization.string("Rule-aware queries"),
                    selection: booleanBinding(\.respectsRules),
                    profileValue: dns.respectsRules
                )
                .accessibilityIdentifier("dns-runtime-respect-rules")
            }
            Divider().padding(.horizontal, AetherVisual.s4)
            // Hosts has no override: it always follows the profile.
            policyRow(AppLocalization.string("Hosts mapping"), help: .dnsHosts, isChanged: false) {
                Text(followProfileTitle(onOffTitle(dns.usesHosts)))
                    .foregroundStyle(AetherVisual.secondaryText)
            }

            if tunnel.isUpdatingDNSRuntimePolicy {
                Divider().padding(.horizontal, AetherVisual.s4)
                HStack(spacing: AetherVisual.s2) {
                    ProgressView()
                        .controlSize(.small)
                    Text(AppLocalization.string("Applying DNS policy…"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.s3)
            } else if let reason = tunnel.profileEditLockReason {
                Divider().padding(.horizontal, AetherVisual.s4)
                Label(reason, systemImage: "lock")
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.vertical, AetherVisual.s3)
                    .accessibilityIdentifier("dns-runtime-lock-reason")
            }

            Divider().padding(.horizontal, AetherVisual.s4)
            HStack(spacing: AetherVisual.s2) {
                if !policy.isInherited {
                    ChangedSettingDot()
                    Text(AppLocalization.string("Marks a changed setting. Changes apply the next time you connect with TUN."))
                } else {
                    Text(AppLocalization.string("Changes apply the next time you connect with TUN."))
                }
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.s3)

            if let message = tunnel.dnsRuntimePolicyMessage {
                Divider().padding(.horizontal, AetherVisual.s4)
                Label(
                    message,
                    systemImage: tunnel.dnsRuntimePolicyMessageIsError
                        ? "exclamationmark.circle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(
                    AetherReadableTint(
                        color: tunnel.dnsRuntimePolicyMessageIsError ? .red : .green
                    )
                )
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(AetherVisual.s4)
                .transition(AetherVisual.insertion)
            }
        }
        .aetherPanel()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.dnsRuntimePolicyMessage)
    }

    private func policyRow<Control: View>(
        _ title: String,
        help: HelpTopic,
        isChanged: Bool,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AetherVisual.s2) {
            Text(title)
                .font(.body.weight(.medium))
            AetherHelpButton(topic: help)
            Spacer(minLength: AetherVisual.s3)
            if isChanged {
                ChangedSettingDot()
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
            control()
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                .disabled(!tunnel.canModifyDNSRuntimePolicy)
        }
        .frame(minHeight: AetherVisual.rowHeight)
        .padding(.horizontal, AetherVisual.s4)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isChanged)
    }

    private func booleanMenu(
        _ title: String,
        selection: Binding<DNSRuntimeBoolean>,
        profileValue: Bool
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(DNSRuntimeBoolean.allCases, id: \.self) { value in
                Text(runtimeBooleanTitle(value, profileValue: profileValue)).tag(value)
            }
        }
    }

    private var resolutionModeBinding: Binding<DNSRuntimeResolutionMode> {
        Binding(
            get: { tunnel.dnsRuntimePolicy.resolutionMode },
            set: { value in
                var policy = tunnel.dnsRuntimePolicy
                policy.resolutionMode = value
                applyDNSRuntimePolicyAfterViewUpdate(policy)
            }
        )
    }

    private func booleanBinding(
        _ keyPath: WritableKeyPath<DNSRuntimePolicy, DNSRuntimeBoolean>
    ) -> Binding<DNSRuntimeBoolean> {
        Binding(
            get: { tunnel.dnsRuntimePolicy[keyPath: keyPath] },
            set: { value in
                var policy = tunnel.dnsRuntimePolicy
                policy[keyPath: keyPath] = value
                applyDNSRuntimePolicyAfterViewUpdate(policy)
            }
        )
    }

    private func applyDNSRuntimePolicyAfterViewUpdate(
        _ policy: DNSRuntimePolicy
    ) {
        // A Picker can invoke its Binding setter from SwiftUI's view update
        // pass. Dispatch to the next main run-loop turn before the
        // observable manager publishes the validated policy and message.
        DispatchQueue.main.async {
            Task { await tunnel.setDNSRuntimePolicy(policy) }
        }
    }

    /// "Follow profile (Fake-IP)": the menu never hides what following the
    /// profile actually means.
    private func followProfileTitle(_ value: String) -> String {
        AppLocalization.format("Follow profile (%@)", value)
    }

    private func onOffTitle(_ isOn: Bool) -> String {
        isOn ? AppLocalization.string("On") : AppLocalization.string("Off")
    }

    private func runtimeModeTitle(_ mode: DNSRuntimeResolutionMode, profileMode: DNSResolutionMode) -> String {
        switch mode {
        case .inherit: followProfileTitle(modeTitle(profileMode))
        case .normal: AppLocalization.string("Normal")
        case .fakeIP: AppLocalization.string("Fake-IP")
        case .redirHost: AppLocalization.string("Redir-host")
        }
    }

    private func runtimeBooleanTitle(_ value: DNSRuntimeBoolean, profileValue: Bool) -> String {
        switch value {
        case .inherit: followProfileTitle(onOffTitle(profileValue))
        case .disabled: AppLocalization.string("Off")
        case .enabled: AppLocalization.string("On")
        }
    }
#endif

    private func usesAutomaticTUNDNS(_ dns: DNSConfigurationSummary) -> Bool {
#if AETHERROUTE_INDEPENDENT
        tunnel.networkEngineMode == .tun && !dns.isEnabled
#else
        false
#endif
    }

    private var systemResolverContent: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            Label(AppLocalization.string("System resolver"), systemImage: "desktopcomputer")
                .font(.headline)
            Text(AppLocalization.string("The active profile has no DNS section. The core therefore uses the system resolver behavior available to the selected network engine."))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                AppLocalization.string("No DNS queries or resolver details leave this Mac."),
                systemImage: "hand.raised.fill"
            )
            .font(.subheadline)
            .foregroundStyle(AetherReadableTint(color: .accentColor))
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
    }

    // MARK: - Custom host mappings

    private var customHostsSection: some View {
        let mappings = tunnel.activeProfileOverrides.customHosts
        let perProfileIDs = Set(mappings.map(\.id))
        let inheritedHosts = tunnel.effectiveCustomHosts.filter { !perProfileIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("Custom host mappings"),
                note: AppLocalization.string("Preserved across subscription updates")
            )

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: AetherVisual.s2) {
                    TextField(
                        AppLocalization.string("Domain (e.g. nas.local, *.dev.internal, +.corp.example)"),
                        text: $drafts.newHostDomain
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit {
                        guard !drafts.newHostDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !drafts.newHostIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !isSavingCustomHosts else { return }
                        addCustomHost()
                    }
                    .disabled(isSavingCustomHosts)
                    .accessibilityIdentifier("dns-custom-host-domain-field")

                    TextField(
                        AppLocalization.string("IPv4 or IPv6 address"),
                        text: $drafts.newHostIP
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .frame(minWidth: 150, maxWidth: 240)
                    .onSubmit {
                        guard !drafts.newHostDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !drafts.newHostIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                              !isSavingCustomHosts else { return }
                        addCustomHost()
                    }
                    .disabled(isSavingCustomHosts)
                    .accessibilityIdentifier("dns-custom-host-ip-field")

                    Button {
                        addCustomHost()
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Add Host"),
                            isWorking: isSavingCustomHosts && drafts.editingHostID == nil
                        )
                    }
                    .aetherButton(prominent: true)
                    .disabled(
                        isSavingCustomHosts
                            || drafts.newHostDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || drafts.newHostIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                    .accessibilityIdentifier("dns-custom-host-add-button")
                }
                .padding(AetherVisual.s4)

                if let hostOverrideErrorMessage = drafts.hostOverrideErrorMessage {
                    Divider().padding(.horizontal, AetherVisual.s4)
                    AetherInlineMessage(text: hostOverrideErrorMessage, isCompact: true)
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.vertical, AetherVisual.s2)
                }

                if !mappings.isEmpty {
                    Divider().padding(.horizontal, AetherVisual.s4)
                    ForEach(Array(mappings.enumerated()), id: \.element.id) { index, mapping in
                        if index > 0 {
                            Divider().padding(.leading, AetherVisual.s4)
                        }
                        if drafts.editingHostID == mapping.id {
                            HStack(spacing: AetherVisual.s2) {
                                TextField(
                                    AppLocalization.string("Domain"),
                                    text: $drafts.editingHostDomain
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())

                                TextField(
                                    AppLocalization.string("IPv4 or IPv6 address"),
                                    text: $drafts.editingHostIP
                                )
                                .textFieldStyle(.roundedBorder)
                                .font(.callout.monospaced())
                                .frame(minWidth: 150, maxWidth: 220)

                                Button(AppLocalization.string("Save")) {
                                    saveEditedCustomHost(id: mapping.id)
                                }
                                .aetherButton(prominent: true)
                                .controlSize(.small)
                                .disabled(isSavingCustomHosts)

                                Button(AppLocalization.string("Cancel"), role: .cancel) {
                                    drafts.editingHostID = nil
                                }
                                .aetherButton()
                                .controlSize(.small)
                                .disabled(isSavingCustomHosts)
                            }
                            .frame(minHeight: AetherVisual.tableRowHeight)
                            .padding(.horizontal, AetherVisual.s4)
                            .padding(.vertical, AetherVisual.s1)
                        } else {
                            HStack(spacing: AetherVisual.s3) {
                                Toggle(
                                    isOn: Binding(
                                        get: { mapping.isEnabled },
                                        set: { isOn in
                                            setCustomHostEnabled(id: mapping.id, isEnabled: isOn)
                                        }
                                    )
                                ) { EmptyView() }
                                .toggleStyle(.switch)
                                .controlSize(.small)
                                .labelsHidden()
                                .disabled(isSavingCustomHosts)
                                .accessibilityLabel(Text(verbatim: mapping.domain))

                                HStack(spacing: AetherVisual.s2) {
                                    Text(verbatim: mapping.domain)
                                        .font(.body.monospaced())
                                        .lineLimit(1)
                                    Image(systemName: "arrow.right")
                                        .font(.caption)
                                        .foregroundStyle(AetherVisual.secondaryText)
                                        .accessibilityHidden(true)
                                    Text(verbatim: mapping.ip)
                                        .font(.callout.monospaced())
                                        .foregroundStyle(AetherVisual.secondaryText)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: AetherVisual.s2)
                                Button {
                                    drafts.editingHostID = mapping.id
                                    drafts.editingHostDomain = mapping.domain
                                    drafts.editingHostIP = mapping.ip
                                    drafts.hostOverrideErrorMessage = nil
                                } label: {
                                    AetherRowIconLabel(symbol: "pencil")
                                }
                                .buttonStyle(.aetherPressable)
                                .disabled(isSavingCustomHosts)
                                .help(AppLocalization.string("Edit"))
                                .accessibilityLabel(AppLocalization.string("Edit"))

                                Button(role: .destructive) {
                                    removeCustomHost(id: mapping.id)
                                } label: {
                                    AetherRowIconLabel(symbol: "trash", tint: .red)
                                }
                                .buttonStyle(.aetherPressable)
                                .disabled(isSavingCustomHosts)
                                .help(AppLocalization.string("Delete"))
                                .accessibilityLabel(AppLocalization.string("Delete"))
                            }
                            .frame(minHeight: AetherVisual.tableRowHeight)
                            .padding(.horizontal, AetherVisual.s4)
                        }
                    }
                }

                if !inheritedHosts.isEmpty {
                    Divider().padding(.horizontal, AetherVisual.s4)
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Inherited global hosts"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherVisual.secondaryText)
                        ForEach(inheritedHosts) { mapping in
                            HStack(spacing: AetherVisual.s2) {
                                Text(verbatim: mapping.domain)
                                    .font(.caption.monospaced())
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(AetherVisual.secondaryText)
                                    .accessibilityHidden(true)
                                Text(verbatim: mapping.ip)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                            .opacity(mapping.isEnabled ? 1.0 : 0.65)
                        }
                    }
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.vertical, AetherVisual.s3)
                }
            }
            .aetherPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("dns-custom-hosts-section")
        }
    }

    private func addCustomHost() {
        guard !isSavingCustomHosts else { return }
        do {
            let entry = try CustomHostMapping(
                domain: drafts.newHostDomain,
                ip: drafts.newHostIP,
                isEnabled: true
            ).validated()
            var overrides = tunnel.activeProfileOverrides
            overrides.customHosts.append(entry)
            let validated = try overrides.validated()
            drafts.hostOverrideErrorMessage = nil
            isSavingCustomHosts = true
            Task {
                defer { isSavingCustomHosts = false }
                let saved = await tunnel.setProfileOverrides(validated)
                if saved {
                    drafts.newHostDomain = ""
                    drafts.newHostIP = ""
                } else {
                    drafts.hostOverrideErrorMessage = tunnel.profileMessage
                        ?? AppLocalization.string("Could not save host mapping.")
                }
            }
        } catch {
            drafts.hostOverrideErrorMessage = error.overrideMessage
        }
    }

    private func saveEditedCustomHost(id: UUID) {
        guard !isSavingCustomHosts else { return }
        do {
            var overrides = tunnel.activeProfileOverrides
            guard let index = overrides.customHosts.firstIndex(where: { $0.id == id }) else { return }
            let updated = try CustomHostMapping(
                id: id,
                domain: drafts.editingHostDomain,
                ip: drafts.editingHostIP,
                isEnabled: overrides.customHosts[index].isEnabled
            ).validated()
            overrides.customHosts[index] = updated
            let validated = try overrides.validated()
            drafts.hostOverrideErrorMessage = nil
            isSavingCustomHosts = true
            Task {
                defer { isSavingCustomHosts = false }
                let saved = await tunnel.setProfileOverrides(validated)
                if saved {
                    drafts.editingHostID = nil
                    drafts.editingHostDomain = ""
                    drafts.editingHostIP = ""
                } else {
                    drafts.hostOverrideErrorMessage = tunnel.profileMessage
                        ?? AppLocalization.string("Could not save host mapping.")
                }
            }
        } catch {
            drafts.hostOverrideErrorMessage = error.overrideMessage
        }
    }

    private func setCustomHostEnabled(id: UUID, isEnabled: Bool) {
        guard !isSavingCustomHosts else { return }
        var overrides = tunnel.activeProfileOverrides
        guard let index = overrides.customHosts.firstIndex(where: { $0.id == id }) else { return }
        overrides.customHosts[index].isEnabled = isEnabled
        drafts.hostOverrideErrorMessage = nil
        isSavingCustomHosts = true
        Task {
            defer { isSavingCustomHosts = false }
            let saved = await tunnel.setProfileOverrides(overrides)
            if !saved {
                drafts.hostOverrideErrorMessage = tunnel.profileMessage
                    ?? AppLocalization.string("Could not update host mapping.")
            }
        }
    }

    private func removeCustomHost(id: UUID) {
        guard !isSavingCustomHosts else { return }
        var overrides = tunnel.activeProfileOverrides
        overrides.customHosts.removeAll { $0.id == id }
        drafts.hostOverrideErrorMessage = nil
        isSavingCustomHosts = true
        Task {
            defer { isSavingCustomHosts = false }
            let saved = await tunnel.setProfileOverrides(overrides)
            if !saved {
                drafts.hostOverrideErrorMessage = tunnel.profileMessage
                    ?? AppLocalization.string("Could not delete host mapping.")
            }
        }
    }

    // MARK: - Interactive DNS Lookup

    private func dnsLookupSection(summary: ProfileConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("DNS lookup")) {
                DNSLookupClearCacheButton(
                    viewModel: tunnel.dnsQueriesViewModel,
                    isConnected: tunnel.isConnected,
                    hasLookupResult: drafts.lookupReport != nil
                        || drafts.fakeIPReverseLookup != nil
                        || drafts.simTraceResult != nil,
                    onClear: clearDNSCacheAction
                )
            }

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                HStack(spacing: AetherVisual.s2) {
                    HStack(spacing: AetherVisual.s2) {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(AetherVisual.secondaryText)
                            .accessibilityHidden(true)
                        TextField(
                            AppLocalization.string("Enter a domain or Fake-IP (198.18.x.x) to inspect DNS and reverse lookup"),
                            text: $drafts.lookupQuery
                        )
                        .textFieldStyle(.plain)
                        .font(.body)
                        .onSubmit { runDNSLookup(summary: summary) }
                        .accessibilityIdentifier("dns-lookup-field")
                        if !drafts.lookupQuery.isEmpty {
                            Button {
                                drafts.lookupQuery = ""
                                drafts.lookupReport = nil
                                drafts.fakeIPReverseLookup = nil
                                drafts.hasAttemptedLookup = false
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(AppLocalization.string("Clear"))
                        }
                    }
                    .padding(.horizontal, AetherVisual.s3 + AetherVisual.sMicro)
                    .frame(minHeight: AetherVisual.tableRowHeight)
                    .background(AetherVisual.neutralFill, in: Capsule())

                    Button {
                        runDNSLookup(summary: summary)
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Resolve"),
                            isWorking: isRunningLookup
                        )
                    }
                    .aetherButton(prominent: true)
                    .controlSize(.large)
                    .disabled(drafts.lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRunningLookup)
                    .accessibilityIdentifier("dns-lookup-button")
                }

                DNSCacheClearStatusBanner(viewModel: tunnel.dnsQueriesViewModel)

                if let reverseState = drafts.fakeIPReverseLookup {
                    fakeIPReverseLookupResultView(reverseState, summary: summary)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("dns-fakeip-reverse-result")
                        .transition(AetherVisual.insertion)
                } else if let report = drafts.lookupReport {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack(spacing: AetherVisual.s2) {
                            StatePill(
                                title: modeTitle(report.effectiveMode),
                                color: modeColor(report.effectiveMode),
                                symbol: modeSymbol(report.effectiveMode)
                            )
                            if let hostIP = report.matchedCustomHostIP {
                                Label(
                                    AppLocalization.format(
                                        "Hosts: %@ -> %@",
                                        report.normalizedHost,
                                        hostIP
                                    ),
                                    systemImage: "pin.fill"
                                )
                                .font(.caption.monospaced())
                                .foregroundStyle(AetherReadableTint(color: .teal))
                            }
                            if let ruleSummary = report.matchedRuleSummary,
                               let target = report.matchedRouteTarget {
                                Text(verbatim: ruleSummary)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AetherVisual.secondaryText)
                                Image(systemName: "arrow.right")
                                    .font(.caption2)
                                    .foregroundStyle(AetherVisual.secondaryText)
                                    .accessibilityHidden(true)
                                RuleTargetLabel(target: target)
                            }
                            Spacer(minLength: AetherVisual.s2)
                            if let ms = report.latencyMilliseconds {
                                Text(AppLocalization.format("%lld ms", Int64(ms)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                        }

                        if report.resolvedAddresses.isEmpty {
                            Label(
                                AppLocalization.string("No system DNS address returned for this host."),
                                systemImage: "info.circle"
                            )
                            .font(.callout)
                            .foregroundStyle(AetherVisual.secondaryText)
                        } else {
                            AetherFlowLayout(spacing: AetherVisual.s2) {
                                ForEach(Array(report.resolvedAddresses.prefix(4)), id: \.self) { address in
                                    HStack(spacing: AetherVisual.s1) {
                                        Text(verbatim: address)
                                            .font(.callout.monospaced())
                                            .textSelection(.enabled)
                                        if DNSLookupInspector.isFakeIPAddress(address) {
                                            Text(AppLocalization.string("Fake-IP"))
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(AetherReadableTint(color: .accentColor))
                                                .padding(.horizontal, AetherVisual.s1)
                                                .padding(.vertical, AetherVisual.sMicro)
                                                .background(
                                                    AetherVisual.tintFill(.accentColor),
                                                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                                                )
                                        }
                                    }
                                    .padding(.horizontal, AetherVisual.s2)
                                    .padding(.vertical, AetherVisual.s1)
                                    .background(
                                        AetherVisual.neutralFill,
                                        in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                                    )
                                }
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("dns-lookup-result")
                    .transition(AetherVisual.insertion)
                } else if drafts.hasAttemptedLookup && !isRunningLookup {
                    Label(
                        AppLocalization.string("Enter a valid domain name (such as example.com) or Fake-IP (198.18.x.x) to inspect DNS resolution."),
                        systemImage: "info.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                } else {
                    HStack(spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Try:"))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                        ForEach(["google.com", "apple.com", "github.com", "bilibili.com"], id: \.self) { domain in
                            Button(domain) {
                                drafts.lookupQuery = domain
                                runDNSLookup(summary: summary)
                            }
                            .buttonStyle(.aetherPressable)
                            .font(.caption)
                            .padding(.horizontal, AetherVisual.s2)
                            .padding(.vertical, AetherVisual.sMicro)
                            .background(AetherVisual.neutralFill, in: Capsule())
                        }
                    }
                }
            }
            .padding(AetherVisual.cardPadding)
            .aetherPanel()
            .aetherAnimation(AetherVisual.gentleSpring, value: drafts.lookupReport)
            .aetherAnimation(AetherVisual.gentleSpring, value: drafts.fakeIPReverseLookup)
        }
    }

    @ViewBuilder
    private func fakeIPReverseLookupResultView(
        _ state: FakeIPReverseLookupState,
        summary: ProfileConfigurationSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            switch state {
            case let .hit(match):
                HStack(spacing: AetherVisual.s2) {
                    StatePill(
                        title: AppLocalization.string("Fake-IP Reverse"),
                        color: .indigo,
                        symbol: "arrow.triangle.2.circlepath"
                    )
                    Text(verbatim: match.fakeIP)
                        .font(.callout.monospaced())
                        .foregroundStyle(AetherVisual.secondaryText)
                        .textSelection(.enabled)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityHidden(true)
                    Text(verbatim: match.domain)
                        .font(.callout.monospaced().weight(.semibold))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                    Spacer(minLength: AetherVisual.s2)
                    Button {
                        drafts.lookupQuery = match.domain
                        runDNSLookup(summary: summary)
                    } label: {
                        Text(AppLocalization.string("Resolve Domain"))
                    }
                    .buttonStyle(.aetherPressable)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, AetherVisual.s2)
                    .padding(.vertical, AetherVisual.s1)
                    .background(AetherVisual.neutralFill, in: Capsule())
                }

                HStack(spacing: AetherVisual.s2) {
                    if let sourceApp = match.record.sourceApp, !sourceApp.isEmpty {
                        Label(sourceApp, systemImage: "app.dashed")
                            .font(.caption.monospaced())
                            .foregroundStyle(AetherVisual.secondaryText)
                    }
                    if let ruleSummary = match.record.matchedRuleSummary {
                        Text(verbatim: ruleSummary)
                            .font(.caption.monospaced())
                            .foregroundStyle(AetherVisual.secondaryText)
                    }
                    if let target = match.record.matchedRouteTarget {
                        if match.record.matchedRuleSummary != nil {
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(AetherVisual.secondaryText)
                                .accessibilityHidden(true)
                        }
                        RuleTargetLabel(target: target)
                    }
                    Spacer(minLength: AetherVisual.s2)
                    Text(verbatim: AppLocalization.date(match.timestamp, date: .omitted, time: .standard))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AetherVisual.secondaryText)
                }

            case let .miss(fakeIP):
                HStack(spacing: AetherVisual.s2) {
                    StatePill(
                        title: AppLocalization.string("Fake-IP Pool"),
                        color: .orange,
                        symbol: "questionmark.circle"
                    )
                    Text(verbatim: fakeIP)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                }
                Text(
                    AppLocalization.string("This address is in the Fake-IP pool (198.18.0.0/15), but no cached domain mapping was found yet. Run a domain lookup here or inspect active Fake-IP connections to populate the reverse lookup table.")
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AetherVisual.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
    }

    private func clearDNSCacheAction() {
        guard !tunnel.dnsQueriesViewModel.isClearingCache else { return }
        lookupTask?.cancel()
        lookupTask = nil
        isRunningLookup = false
        drafts.lookupReport = nil
        drafts.fakeIPReverseLookup = nil
        drafts.hasAttemptedLookup = false
        drafts.simTraceResult = nil
        drafts.simValidationError = nil
        Task {
            _ = await tunnel.clearDNSCache()
        }
    }

    private func runDNSLookup(summary: ProfileConfigurationSummary) {
        let query = drafts.lookupQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        drafts.hasAttemptedLookup = true

        if let normalizedFakeIP = FakeIPAddressMatcher.normalizeFakeIP(query) {
            lookupTask?.cancel()
            lookupTask = nil
            drafts.lookupReport = nil
            isRunningLookup = false
            if let match = tunnel.reverseLookupFakeIP(normalizedFakeIP) {
                drafts.fakeIPReverseLookup = .hit(match)
            } else {
                drafts.fakeIPReverseLookup = .miss(fakeIP: normalizedFakeIP)
            }
            return
        }

        drafts.fakeIPReverseLookup = nil
        guard let normalized = DNSLookupInspector.normalizeHost(query) else {
            lookupTask?.cancel()
            lookupTask = nil
            drafts.lookupReport = nil
            isRunningLookup = false
            return
        }
        lookupTask?.cancel()
        isRunningLookup = true
        let customHosts = tunnel.effectiveCustomHosts
        let dnsModeOverride: DNSResolutionMode? = switch tunnel.dnsRuntimePolicy.resolutionMode {
        case .inherit: nil
        case .normal: .normal
        case .fakeIP: .fakeIP
        case .redirHost: .redirHost
        }
        let geoSiteData = tunnel.slicedGeoSiteData(for: summary)
        let targetProfileID = tunnel.activeProfileID

        lookupTask = Task {
            let resolved = await DNSLookupInspector.resolveSystemAddresses(for: normalized)
            guard !Task.isCancelled else { return }
            let report = await Task.detached(priority: .userInitiated) {
                DNSLookupInspector.evaluate(
                    query: normalized,
                    summary: summary,
                    customHosts: customHosts,
                    dnsModeOverride: dnsModeOverride,
                    geoSiteData: geoSiteData,
                    resolvedAddresses: resolved.addresses,
                    latencyMilliseconds: resolved.latencyMilliseconds
                )
            }.value
            guard !Task.isCancelled, tunnel.activeProfileID == targetProfileID else {
                isRunningLookup = false
                return
            }
            drafts.lookupReport = report
            if let report {
                tunnel.recordDNSLookupReport(report)
            }
            isRunningLookup = false
        }
    }

    private func networkDiagnosticSection(summary: ProfileConfigurationSummary) -> some View {
        FeatureSection(title: AppLocalization.string("Network diagnostics")) {
            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                Text(
                    AppLocalization.string(
                        "One-click health check for local proxy listeners, loopback direct protection, DNS resolution, domestic direct reachability, and active subscription rules."
                    )
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)

                HStack(spacing: AetherVisual.s2) {
                    Button {
                        runNetworkDiagnostics(summary: summary)
                    } label: {
                        AetherProgressButtonLabel(
                            isRunningDiagnostics
                                ? AppLocalization.string("Running diagnostics…")
                                : AppLocalization.string("Run Diagnostics"),
                            systemImage: "stethoscope",
                            isWorking: isRunningDiagnostics
                        )
                    }
                    .aetherButton(prominent: true)
                    .disabled(isRunningDiagnostics)
                    .accessibilityIdentifier("run-network-diagnostics-button")

                    if let report = drafts.diagnosticReport {
                        AetherCopyButton(
                            title: Text(AppLocalization.string("Copy diagnostic report")),
                            systemImage: "doc.on.doc"
                        ) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(
                                report.formattedMarkdownReport(),
                                forType: .string
                            )
                            return true
                        }
                        .accessibilityIdentifier("copy-network-diagnostics-button")
                    }

                    Spacer(minLength: AetherVisual.s2)

                    if let report = drafts.diagnosticReport {
                        Text(diagnosticStatusTitle(report.overallStatus))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(diagnosticStatusStyle(report.overallStatus))
                            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
                            .padding(.vertical, AetherVisual.pillVerticalPadding)
                            .background(
                                AetherVisual.tintFill(diagnosticStatusColor(report.overallStatus)),
                                in: Capsule()
                            )
                    }
                }

                if let report = drafts.diagnosticReport {
                    Divider()
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        ForEach(report.checks) { check in
                            HStack(alignment: .top, spacing: AetherVisual.s2) {
                                Image(systemName: diagnosticStatusSymbol(check.status))
                                    .foregroundStyle(diagnosticStatusStyle(check.status))
                                    .font(.callout)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                    Text(diagnosticCheckTitle(check.kind))
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                    if !check.detail.isEmpty {
                                        Text(verbatim: check.detail)
                                            .font(.caption)
                                            .foregroundStyle(AetherVisual.secondaryText)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                                Spacer(minLength: AetherVisual.s2)
                                if let ms = check.latencyMilliseconds {
                                    Text(AppLocalization.format("%lld ms", Int64(ms)))
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(AetherVisual.secondaryText)
                                }
                                Text(diagnosticStatusTitle(check.status))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(diagnosticStatusStyle(check.status))
                            }
                        }
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("network-diagnostics-results")
                }
            }
            .padding(AetherVisual.cardPadding)
            .aetherPanel()
        }
    }

    private func runNetworkDiagnostics(summary: ProfileConfigurationSummary) {
        guard !isRunningDiagnostics else { return }
        diagnosticsTask?.cancel()
        isRunningDiagnostics = true
        let targetProfileID = tunnel.activeProfileID
        let isConnected = tunnel.isConnected
#if AETHERROUTE_INDEPENDENT
        let engineMode = tunnel.networkEngineMode.rawValue
        let localProxyEnabled = tunnel.localProxySettings.isEnabled
            || tunnel.localProxySettings.allowLAN
            || tunnel.localProxySettings.setAsSystemProxy
        let localProxyPort = tunnel.localProxySettings.httpPort
#else
        let engineMode = "tun"
        let localProxyEnabled = false
        let localProxyPort = 7_890
#endif
        let effectiveMode = tunnel.effectiveRoutingMode
        let routingMode = effectiveMode.rawValue
        let dnsMode = summary.dns.mode.rawValue
        let nodeCount = summary.proxyCount
        let customProviders = tunnel.customRuleProviders
        let providerCount = summary.ruleProviderCount + customProviders.count
        let staleProviders = NetworkDiagnosticDoctor.countStaleRuleProviders(customProviders)
        let isUIReview = tunnel.isUIReviewMode
        let shouldProbeProxy = isConnected && effectiveMode != .direct
        let rulesSnapshot = summary.allRules

        diagnosticsTask = Task {
            let (loopbackEval, localListening) = await Task.detached(priority: .userInitiated) {
                let loopback = RouteMatchEngine.evaluate(
                    destination: "localhost:8080",
                    against: rulesSnapshot
                )?.target == "DIRECT"
                let listening = localProxyEnabled
                    ? NetworkDiagnosticDoctor.probeLoopbackTCPPort(localProxyPort)
                    : false
                return (loopback, listening)
            }.value
            guard !Task.isCancelled else { return }
            let dnsResolved = await DNSLookupInspector.resolveSystemAddresses(for: "www.apple.com")
            guard !Task.isCancelled else { return }
            let domesticMs: Int?
            let proxyMs: Int?
            if isUIReview {
                domesticMs = dnsResolved.latencyMilliseconds
                proxyMs = shouldProbeProxy ? max(dnsResolved.latencyMilliseconds, 1) : nil
            } else {
                async let domesticProbe = NetworkDiagnosticDoctor.probeHTTPConnectivity(
                    url: URL(string: "https://captive.apple.com/hotspot-detect.html")!
                )
                async let proxyProbe: Int? = shouldProbeProxy
                    ? NetworkDiagnosticDoctor.probeHTTPConnectivity(
                        url: URL(string: "https://www.google.com/generate_204")!
                    )
                    : nil
                domesticMs = await domesticProbe
                proxyMs = await proxyProbe
            }
            guard !Task.isCancelled, tunnel.activeProfileID == targetProfileID else {
                isRunningDiagnostics = false
                return
            }
            let snapshot = NetworkDiagnosticInputSnapshot(
                isConnected: isConnected,
                engineMode: engineMode,
                routingMode: routingMode,
                localProxyEnabled: localProxyEnabled,
                localProxyPort: localProxyPort,
                localProxyListening: localListening,
                loopbackBypassIntact: loopbackEval,
                dnsEnhancedMode: dnsMode,
                dnsResolvedCount: dnsResolved.addresses.count,
                dnsLatencyMilliseconds: dnsResolved.latencyMilliseconds,
                domesticLatencyMilliseconds: domesticMs,
                proxyLatencyMilliseconds: proxyMs,
                activeProfileNodeCount: nodeCount,
                ruleProviderCount: providerCount,
                staleRuleProviderCount: staleProviders
            )
            drafts.diagnosticReport = NetworkDiagnosticDoctor.evaluate(snapshot: snapshot)
            isRunningDiagnostics = false
        }
    }

    private func diagnosticCheckTitle(_ kind: DiagnosticCheckKind) -> String {
        switch kind {
        case .localProxyListener:
            AppLocalization.string("Local proxy listener")
        case .loopbackDirectBypass:
            AppLocalization.string("Loopback & localhost direct protection")
        case .dnsResolutionHealth:
            AppLocalization.string("DNS resolution & Fake-IP health")
        case .domesticDirectConnectivity:
            AppLocalization.string("Domestic direct reachability")
        case .proxyOutboundConnectivity:
            AppLocalization.string("Proxy outbound connectivity")
        case .subscriptionAndRuleProviderHealth:
            AppLocalization.string("Subscription & rule providers")
        }
    }

    private func diagnosticStatusTitle(_ status: DiagnosticCheckStatus) -> String {
        switch status {
        case .passed:
            AppLocalization.string("Passed")
        case .warning:
            AppLocalization.string("Warning")
        case .failed:
            AppLocalization.string("Failed")
        case .skipped:
            AppLocalization.string("Skipped")
        }
    }

    private func diagnosticStatusSymbol(_ status: DiagnosticCheckStatus) -> String {
        switch status {
        case .passed:
            "checkmark.circle.fill"
        case .warning:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.circle.fill"
        case .skipped:
            "minus.circle"
        }
    }

    private func diagnosticStatusColor(_ status: DiagnosticCheckStatus) -> Color {
        switch status {
        case .passed:
            .green
        case .warning:
            .orange
        case .failed:
            .red
        case .skipped:
            .secondary
        }
    }

    private func diagnosticStatusStyle(_ status: DiagnosticCheckStatus) -> AnyShapeStyle {
        switch status {
        case .passed, .warning, .failed:
            AnyShapeStyle(AetherReadableTint(color: diagnosticStatusColor(status)))
        case .skipped:
            AnyShapeStyle(AetherVisual.secondaryText)
        }
    }

    private func modeTitle(_ mode: DNSResolutionMode) -> String {
        switch mode {
        case .normal: AppLocalization.string("Normal")
        case .fakeIP: AppLocalization.string("Fake-IP")
        case .redirHost: AppLocalization.string("Redir-host")
        case .unsupported: AppLocalization.string("Core check")
        }
    }

    private func modeDetail(_ mode: DNSResolutionMode) -> String {
        switch mode {
        case .normal: AppLocalization.string("Returns upstream addresses without synthetic mapping.")
        case .fakeIP: AppLocalization.string("Maps names into a synthetic range for deterministic domain routing.")
        case .redirHost: AppLocalization.string("Resolves real addresses while retaining enhanced host routing.")
        case .unsupported: AppLocalization.string("The profile uses a mode that requires protocol-core validation.")
        }
    }

    private func modeSymbol(_ mode: DNSResolutionMode) -> String {
        switch mode {
        case .normal: "network"
        case .fakeIP: "wand.and.stars"
        case .redirHost: "arrow.triangle.turn.up.right.diamond.fill"
        case .unsupported: "questionmark.diamond"
        }
    }

    private func modeColor(_ mode: DNSResolutionMode) -> Color {
        switch mode {
        case .normal: .blue
        case .fakeIP: .accentColor
        case .redirHost: .accentColor
        case .unsupported: .orange
        }
    }

    private func totalResolverCount(_ dns: DNSConfigurationSummary) -> Int {
        dns.nameserverCount + dns.fallbackCount + dns.defaultNameserverCount
            + dns.proxyNameserverCount + dns.nameserverPolicyCount
    }

    private func transportTitle(_ transport: DNSUpstreamTransport) -> String {
        switch transport {
        case .udp: "UDP"
        case .tcp: "TCP"
        case .dnsOverTLS: "DoT"
        case .dnsOverHTTPS: "DoH"
        case .dhcp: "DHCP"
        case .unsupported: AppLocalization.string("Core check")
        }
    }

    private func transportSymbol(_ transport: DNSUpstreamTransport) -> String {
        switch transport {
        case .udp: "paperplane"
        case .tcp: "arrow.left.arrow.right"
        case .dnsOverTLS: "lock"
        case .dnsOverHTTPS: "lock.shield"
        case .dhcp: "network"
        case .unsupported: "questionmark.circle"
        }
    }

    private func transportColor(_ transport: DNSUpstreamTransport) -> Color {
        switch transport {
        case .dnsOverTLS, .dnsOverHTTPS: .accentColor
        case .udp, .tcp: .blue
        case .dhcp: .accentColor
        case .unsupported: .orange
        }
    }
}

/// The mark beside a DNS setting that no longer follows the profile.
private struct ChangedSettingDot: View {
    var body: some View {
        Circle()
            .fill(AetherReadableTint(color: .accentColor))
            .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
            .accessibilityElement()
            .accessibilityLabel(AppLocalization.string("Changed"))
            // A labelled shape has no role of its own; announce it as an image.
            .accessibilityAddTraits(.isImage)
    }
}

private struct DNSSettingRow: View {

    let title: String
    let detail: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: symbol, color: tint, size: AetherVisual.rowTileSize)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: AetherVisual.s3)
            // The value trails as plain text, as in System Settings; the
            // tile colour names the setting and says nothing about its value.
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        // Keep the heading, explanation and value individually readable.
        // The visible heading introduces the group without repeating it as
        // an additional spoken label on the container.
        .accessibilityElement(children: .contain)
    }
}

private struct DNSCountLabel: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(.primary)
            .frame(minWidth: 80, alignment: .leading)
    }
}

/// How AetherRoute shares the network with Tailscale (1.7.0).
private struct TailscaleCoexistenceNote: View {
    let presence: TailscalePresence

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Label {
                Text(AppLocalization.string("Tailscale is running"))
                    .font(.headline)
            } icon: {
                Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                    .foregroundStyle(AetherReadableTint(color: .accentColor))
            }
            Text(AppLocalization.string("Addresses in your tailnet go straight to Tailscale. HTTPS sites still follow your rules by name, even when Tailscale's DNS answers first."))
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if presence.usesExitNode {
                AetherInlineMessage(
                    text: AppLocalization.string("A Tailscale exit node is carrying this Mac's traffic. Turn it off while AetherRoute is connected, or the two will compete for every connection."),
                    kind: .warning,
                    isCompact: true
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dns-tailscale-note")
    }
}

/// Single-pass adaptive grid for DNS summary stat tiles: lays all stats out in
/// one horizontal row when they fit, or wraps into 2-column / 1-column rows
/// at narrower widths without duplicate view construction.
private struct DNSSummaryStatsLayout: Layout {
    let spacing: CGFloat

    private func columnCount(for width: CGFloat, subviews: Subviews) -> Int {
        let count = subviews.count
        guard count > 1 else { return max(1, count) }
        let maxIdealWidth = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        if maxIdealWidth * CGFloat(count) + spacing * CGFloat(count - 1) <= width {
            return count
        }
        if maxIdealWidth * 2 + spacing <= width {
            return 2
        }
        return 1
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        guard let width = proposal.width, width >= 1, width.isFinite else {
            let maxH = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
            return CGSize(width: 0, height: maxH)
        }
        let columns = columnCount(for: width, subviews: subviews)
        let colWidth = max(0, (width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var totalHeight: CGFloat = 0
        var index = 0
        while index < subviews.count {
            let rowEnd = min(index + columns, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<rowEnd {
                let h = subviews[i].sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height
                rowHeight = max(rowHeight, h)
            }
            if index > 0 { totalHeight += spacing }
            totalHeight += rowHeight
            index = rowEnd
        }
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard !subviews.isEmpty else { return }
        let columns = columnCount(for: bounds.width, subviews: subviews)
        let colWidth = max(0, (bounds.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
        var y = bounds.minY
        var index = 0
        while index < subviews.count {
            let rowEnd = min(index + columns, subviews.count)
            var rowHeight: CGFloat = 0
            for i in index..<rowEnd {
                let h = subviews[i].sizeThatFits(ProposedViewSize(width: colWidth, height: nil)).height
                rowHeight = max(rowHeight, h)
            }
            for col in 0..<(rowEnd - index) {
                let x = bounds.minX + CGFloat(col) * (colWidth + spacing)
                subviews[index + col].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: colWidth, height: rowHeight)
                )
            }
            y += rowHeight + spacing
            index = rowEnd
        }
    }
}

private struct DNSLookupClearCacheButton: View {
    @ObservedObject var viewModel: DNSRecentQueriesViewModel
    let isConnected: Bool
    let hasLookupResult: Bool
    let onClear: () -> Void

    var body: some View {
        Button {
            onClear()
        } label: {
            AetherProgressButtonLabel(
                AppLocalization.string("Clear DNS Log"),
                isWorking: viewModel.isClearingCache
            )
        }
        .aetherButton(prominent: false)
        .controlSize(.small)
        .disabled(
            viewModel.isClearingCache
                || (!isConnected && viewModel.store.isEmpty && !hasLookupResult)
        )
        .help(AppLocalization.string("Clears the recorded DNS query log, lookup output, and route trace results"))
        .accessibilityIdentifier("dns-clear-cache-button")
    }
}

private struct DNSCacheClearStatusBanner: View {
    @ObservedObject var viewModel: DNSRecentQueriesViewModel

    var body: some View {
        if let status = viewModel.lastCacheClearStatus {
            Label(
                status,
                systemImage: viewModel.lastCacheClearIsError
                    ? "exclamationmark.triangle.fill"
                    : "checkmark.circle.fill"
            )
            .font(.caption)
            .foregroundStyle(AetherReadableTint(color: viewModel.lastCacheClearIsError ? .red : .green))
            .fixedSize(horizontal: false, vertical: true)
            .transition(AetherVisual.insertion)
            .accessibilityIdentifier("dns-clear-cache-status")
        }
    }
}

private struct RouteSimulatorSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var drafts: DNSPageDraftState

    @State private var isSimulating = false
    @State private var simulationTask: Task<Void, Never>?

    var body: some View {
        FeatureSection(title: AppLocalization.string("Route & DNS Simulator")) {
            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                Text(
                    AppLocalization.string("Test how AetherRoute evaluates a destination across rules, Fake-IP/DNS, and proxy groups. Uses the live engine when connected and falls back to static inspection when disconnected.")
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)

                HStack(spacing: AetherVisual.s2) {
                    TextField(
                        AppLocalization.string("Domain or IP (e.g. api.openai.com)"),
                        text: $drafts.simHostInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                    .onSubmit(runSimulation)
                    .accessibilityIdentifier("route-sim-host-field")

                    TextField(
                        AppLocalization.string("Port"),
                        text: $drafts.simPortInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospacedDigit())
                    .frame(width: 72)
                    .onSubmit(runSimulation)
                    .accessibilityIdentifier("route-sim-port-field")

                    AetherSegmentedPicker(
                        selection: $drafts.simNetwork,
                        options: [
                            .init(value: .tcp, title: "TCP"),
                            .init(value: .udp, title: "UDP"),
                        ],
                        accessibilityLabel: AppLocalization.string("Protocol"),
                        accessibilityIdentifier: "route-sim-network-picker",
                        fillsWidth: false
                    )
                    .fixedSize()
                }

                HStack(spacing: AetherVisual.s2) {
                    TextField(
                        AppLocalization.string("Optional IP override (for IP-ASN / IP-CIDR)"),
                        text: $drafts.simIPInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit(runSimulation)
                    .accessibilityIdentifier("route-sim-ip-field")

                    TextField(
                        AppLocalization.string("Optional process path (e.g. /usr/bin/curl)"),
                        text: $drafts.simProcessPathInput
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.caption.monospaced())
                    .onSubmit(runSimulation)
                    .accessibilityIdentifier("route-sim-process-field")
                }

                if let validationError = drafts.simValidationError {
                    AetherInlineMessage(text: validationError, kind: .failure, isCompact: true)
                }

                HStack(spacing: AetherVisual.s2) {
                    Spacer(minLength: 0)
                    if drafts.simTraceResult != nil
                        || !drafts.simHostInput.isEmpty
                        || !drafts.simIPInput.isEmpty
                        || !drafts.simProcessPathInput.isEmpty
                        || drafts.simPortInput != "443" {
                        Button(AppLocalization.string("Clear")) {
                            clearSimulation()
                        }
                        .aetherButton()
                        .disabled(isSimulating)
                        .accessibilityIdentifier("route-sim-clear-button")
                    }
                    Button {
                        runSimulation()
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Simulate"),
                            isWorking: isSimulating
                        )
                    }
                    .aetherButton(prominent: true)
                    .disabled(
                        isSimulating
                            || (drafts.simHostInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                && drafts.simIPInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    )
                    .accessibilityIdentifier("route-sim-run-button")
                }

                if let result = drafts.simTraceResult {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack(spacing: AetherVisual.s2) {
                            Text(
                                result.source == .liveProvider
                                    ? AppLocalization.string("Live Engine")
                                    : AppLocalization.string("Static Fallback")
                            )
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(
                                result.source == .liveProvider
                                    ? AnyShapeStyle(AetherReadableTint(color: .green))
                                    : AnyShapeStyle(AetherVisual.secondaryText)
                            )
                            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
                            .padding(.vertical, AetherVisual.pillVerticalPadding)
                            .background(
                                result.source == .liveProvider
                                    ? AetherVisual.tintFill(.green)
                                    : AetherVisual.neutralFill,
                                in: Capsule()
                            )

                            Text(ruleSummaryText(result))
                                .font(.callout.monospaced())
                                .textSelection(.enabled)
                        }

                        if !result.outboundChain.isEmpty {
                            HStack(spacing: AetherVisual.s1) {
                                Text(AppLocalization.string("Outbound:"))
                                    .font(.caption)
                                    .foregroundStyle(AetherVisual.secondaryText)
                                Text(verbatim: result.outboundChain.map(localizedPolicyOrOutbound).joined(separator: " → "))
                                    .font(.callout.weight(.medium))
                                    .textSelection(.enabled)
                            }
                        }

                        AetherFlowLayout(spacing: AetherVisual.s2) {
                            if let alias = result.resolvedHostAlias {
                                Text(AppLocalization.format("Hosts: %@", alias))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }

                            ForEach(result.dnsAddresses, id: \.self) { address in
                                Text(verbatim: address)
                                    .font(.caption.monospaced())
                                    .foregroundStyle(AetherVisual.secondaryText)
                                    .padding(.horizontal, AetherVisual.s1)
                                    .padding(.vertical, AetherVisual.sMicro)
                                    .background(AetherVisual.neutralFill, in: Capsule())
                                    .textSelection(.enabled)
                            }

                            if result.isFakeIP {
                                Text(AppLocalization.string("Fake-IP"))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(AetherReadableTint(color: .accentColor))
                            }

                            if let ms = result.dnsLatencyMilliseconds {
                                Text(AppLocalization.format("DNS %lld ms", Int64(ms)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                        }
                    }
                    .padding(AetherVisual.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AetherVisual.cardFill,
                        in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
                    )
                    .transition(AetherVisual.insertion)
                    .accessibilityIdentifier("route-sim-result")
                }
            }
            .padding(AetherVisual.cardPadding)
            .aetherPanel()
        }
        .onChange(of: tunnel.activeProfileID) { _, _ in
            clearSimulation()
        }
        .onDisappear {
            simulationTask?.cancel()
            simulationTask = nil
            isSimulating = false
        }
    }

    private func clearSimulation() {
        simulationTask?.cancel()
        simulationTask = nil
        isSimulating = false
        drafts.simHostInput = ""
        drafts.simIPInput = ""
        drafts.simPortInput = "443"
        drafts.simProcessPathInput = ""
        drafts.simValidationError = nil
        drafts.simTraceResult = nil
    }

    private func localizedPolicyOrOutbound(_ raw: String) -> String {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "DIRECT":
            AppLocalization.string("Direct")
        case "REJECT", "REJECT-DROP":
            AppLocalization.string("Reject")
        default:
            raw
        }
    }

    private func ruleSummaryText(_ result: RouteTraceResult) -> String {
        var parts: [String] = []
        if let order = result.matchedRuleOrder {
            parts.append("#\(order)")
        }
        if let criteria = result.matchedRuleCriteria, !criteria.isEmpty {
            parts.append("\(result.matchedRuleKind),\(criteria)")
        } else {
            parts.append(result.matchedRuleKind)
        }
        parts.append("→ \(localizedPolicyOrOutbound(result.targetOutbound))")
        return parts.joined(separator: " ")
    }

    private static func isValidIPAddress(_ raw: String) -> Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return raw.withCString { cstr in
            inet_pton(AF_INET, cstr, &v4) == 1 || inet_pton(AF_INET6, cstr, &v6) == 1
        }
    }

    private func runSimulation() {
        let host = drafts.simHostInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let ip = drafts.simIPInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty || !ip.isEmpty else { return }

        let trimmedPort = drafts.simPortInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let port: Int
        if trimmedPort.isEmpty {
            port = 443
        } else if let parsedPort = Int(trimmedPort), (1...65_535).contains(parsedPort) {
            port = parsedPort
        } else {
            drafts.simValidationError = AppLocalization.string("Enter a valid port between 1 and 65535.")
            return
        }

        if !ip.isEmpty, !Self.isValidIPAddress(ip) {
            drafts.simValidationError = AppLocalization.string("Enter a valid IPv4 or IPv6 address.")
            return
        }

        drafts.simValidationError = nil
        let processPath = drafts.simProcessPathInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = RouteTraceRequest(
            host: host.isEmpty ? ip : host,
            ip: ip.isEmpty ? nil : ip,
            port: port,
            network: drafts.simNetwork,
            processPath: processPath.isEmpty ? nil : processPath
        )
        simulationTask?.cancel()
        isSimulating = true
        let targetProfileID = tunnel.activeProfileID
        simulationTask = Task {
            let result = await tunnel.traceRoute(request)
            guard !Task.isCancelled, tunnel.activeProfileID == targetProfileID else {
                isSimulating = false
                return
            }
            drafts.simTraceResult = result
            isSimulating = false
        }
    }
}

enum FakeIPReverseLookupState: Equatable {
    case hit(FakeIPReverseLookupMatch)
    case miss(fakeIP: String)
}

private struct RecentDNSQueriesCard: View {
    private static let listMaxHeight: CGFloat = 260

    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var viewModel: DNSRecentQueriesViewModel
    let telemetry: NetworkTelemetryViewModel
    @Binding var selectedFilter: DNSRecentQueryFilter
    let onSelectDomain: (String) -> Void

    private var filteredEntries: [DNSRecentQueryRecord] {
        viewModel.store.entries(matching: selectedFilter)
    }

    var body: some View {
        FeatureSection(title: AppLocalization.string("Recent DNS Queries")) {
            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                AetherWrapPairLayout {
                    AetherFlowLayout(spacing: AetherVisual.s2) {
                        ForEach(DNSRecentQueryFilter.allCases, id: \.self) { filter in
                            filterPill(for: filter)
                        }
                    }
                    Text(verbatim: "\(viewModel.store.count) / \(DNSRecentQueryStore.maxEntries)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityIdentifier("dns-recent-queries-count")
                }

                if filteredEntries.isEmpty {
                    HStack(spacing: AetherVisual.s2) {
                        Image(systemName: "magnifyingglass.circle")
                            .foregroundStyle(AetherVisual.secondaryText)
                            .accessibilityHidden(true)
                        Text(emptyMessage)
                            .font(.callout)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AetherVisual.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        AetherVisual.cardFill,
                        in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
                    }
                } else {
                    ScrollView {
                        // Plain VStack inside a bounded ScrollView so DNSView's plain VStack
                        // never triggers AppKit LazyVStack layout invalidation loops.
                        VStack(alignment: .leading, spacing: AetherVisual.s1) {
                            ForEach(filteredEntries) { record in
                                queryRow(record)
                            }
                        }
                    }
                    .frame(maxHeight: Self.listMaxHeight)
                    .accessibilityIdentifier("dns-recent-queries-list")
                }
            }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
    }
    .backgroundTelemetryDemand(source: "dns-recent-queries")
    .onReceive(telemetry.$snapshot) { newSnapshot in
        viewModel.ingestConnections(
            newSnapshot.connections,
            runtimePolicy: tunnel.dnsRuntimePolicy
        )
    }
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("dns-recent-queries-card")
    }

    private func filterPill(for filter: DNSRecentQueryFilter) -> some View {
        let isSelected = selectedFilter == filter
        let count = viewModel.store.count(matching: filter)
        return Button {
            selectedFilter = filter
        } label: {
            HStack(spacing: AetherVisual.s1) {
                Text(filterTitle(filter))
                    .font(.caption.weight(isSelected ? .semibold : .medium))
                Text(verbatim: "\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? AnyShapeStyle(AetherReadableTint(color: .accentColor)) : AnyShapeStyle(AetherVisual.secondaryText))
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(AetherReadableTint(color: .accentColor)) : AnyShapeStyle(Color.primary))
            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
            .padding(.vertical, AetherVisual.pillVerticalPadding)
            .background(
                isSelected ? AetherVisual.selectionFill : AetherVisual.neutralFill,
                in: Capsule()
            )
        }
        .buttonStyle(.aetherPressable)
        .accessibilityIdentifier("dns-recent-filter-\(filter.rawValue)")
    }

    private func queryRow(_ record: DNSRecentQueryRecord) -> some View {
        HStack(spacing: AetherVisual.s2) {
            Text(verbatim: AppLocalization.date(record.timestamp, date: .omitted, time: .standard))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .fixedSize()

            Text(verbatim: record.queryType.rawValue)
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(
                    AetherVisual.neutralFill,
                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                )

            Button {
                onSelectDomain(record.domain)
            } label: {
                Text(verbatim: record.domain)
                    .font(.caption.monospaced())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .buttonStyle(.plain)
            .help(AppLocalization.string("Resolve this domain above"))
            .accessibilityHint(AppLocalization.string("Resolves this domain in the lookup panel above"))

            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(AetherVisual.secondaryText)
                .accessibilityHidden(true)

            Text(localizedResolvedValue(record))
                .font(record.resolvedPolicyKind == nil ? .caption.monospaced() : .caption.weight(.semibold))
                .foregroundStyle(kindTextStyle(record.kind))
                .lineLimit(1)
                .truncationMode(.tail)
                .textSelection(.enabled)

            Spacer(minLength: AetherVisual.s2)

            if let sourceApp = record.sourceApp, !sourceApp.isEmpty {
                Text(verbatim: sourceApp)
                    .font(.caption2.monospaced())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            Text(AppLocalization.string(record.upstreamLabel))
                .font(.caption2)
                .foregroundStyle(kindTextStyle(record.kind))
                .lineLimit(1)
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(
                    AetherVisual.tintFill(kindColor(record.kind)),
                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                )

            if let latencyMs = record.latencyMs {
                Text(AppLocalization.format("%lld ms", Int64(latencyMs)))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
    }

    private var emptyMessage: String {
        if viewModel.store.isEmpty {
            return AppLocalization.string("No recent DNS queries recorded yet. Resolve a domain above or open active connections to populate this bounded 64-entry log.")
        }
        return AppLocalization.string("No queries match the selected filter.")
    }

    private func filterTitle(_ filter: DNSRecentQueryFilter) -> String {
        switch filter {
        case .all:
            AppLocalization.string("All")
        case .fakeIP:
            AppLocalization.string("Fake-IP")
        case .direct:
            AppLocalization.string("Direct")
        case .rejectedOrFailed:
            AppLocalization.string("Blocked / Failed")
        }
    }

    private func kindColor(_ kind: DNSRecentQueryKind) -> Color {
        switch kind {
        case .fakeIP: .indigo
        case .direct: .teal
        case .rejected: .orange
        case .failed: .red
        }
    }

    private func localizedResolvedValue(_ record: DNSRecentQueryRecord) -> String {
        switch record.resolvedPolicyKind {
        case .direct:
            AppLocalization.string("Direct")
        case .reject, .rejectDrop:
            AppLocalization.string("Reject")
        case nil:
            record.resolvedValue.isEmpty ? "—" : record.resolvedValue
        }
    }

    private func kindTextStyle(_ kind: DNSRecentQueryKind) -> AnyShapeStyle {
        switch kind {
        case .fakeIP: AnyShapeStyle(AetherReadableTint(color: .indigo))
        case .direct: AnyShapeStyle(AetherReadableTint(color: .teal))
        case .rejected: AnyShapeStyle(AetherReadableTint(color: .orange))
        case .failed: AnyShapeStyle(AetherReadableTint(color: .red))
        }
    }
}

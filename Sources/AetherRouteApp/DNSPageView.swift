import AetherRouteKit
import SwiftUI

struct DNSView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var showsAdvancedDNS = false

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                        AetherPageHeader(.dns)
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
                    }
                    .aetherPageContent(.wide)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(AppLocalization.string("DNS configuration details"))
                    .accessibilityIdentifier("dns-page-content")
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

            HStack(spacing: 0) {
                ForEach(Array(stats.enumerated()), id: \.offset) { index, stat in
                    if index > 0 {
                        Divider().padding(.vertical, AetherVisual.s3)
                    }
                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(stat.0)
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                        Text(stat.1)
                            .font(.title3.weight(.semibold).monospacedDigit())
                            .foregroundStyle(.primary)
                            .aetherNumericValue(stat.1)
                    }
                    .padding(AetherVisual.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                }
            }
            .fixedSize(horizontal: false, vertical: true)

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
                    showsAdvancedDNS.toggle()
                }
            } label: {
                HStack(spacing: AetherVisual.s2) {
                    AetherDisclosureChevron(isExpanded: showsAdvancedDNS)
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
                showsAdvancedDNS
                    ? AppLocalization.string("Expanded")
                    : AppLocalization.string("Collapsed")
            )
            .accessibilityIdentifier("dns-details-disclosure")

            if showsAdvancedDNS {
                HStack(alignment: .top, spacing: AetherVisual.s5) {
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
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AetherVisual.s2)
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("%lld total"),
                        totalResolverCount(dns)
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
                HStack(spacing: AetherVisual.s2) {
                    ForEach(dns.upstreamTransports, id: \.self) { transport in
                        Label(
                            transportTitle(transport),
                            systemImage: transportSymbol(transport)
                        )
                        .font(.caption.weight(.medium))
                        .foregroundStyle(transportColor(transport))
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
                .foregroundStyle(Color.accentColor)
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
            .aetherGlassButton()
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

            // Saving this card's own change locks it for a moment; that is
            // not a lock the person needs explained.
            if !tunnel.isUpdatingDNSRuntimePolicy,
               let reason = tunnel.profileEditLockReason {
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
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.subheadline)
                .foregroundStyle(
                    AetherReadableTint(
                        color: tunnel.dnsRuntimePolicyMessageIsError ? .orange : .accentColor
                    )
                )
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
        String.localizedStringWithFormat(AppLocalization.string("Follow profile (%@)"), value)
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
            Label(AppLocalization.string("System resolver"), systemImage: "macbook.and.iphone")
                .font(.headline)
            Text(AppLocalization.string("The active profile has no DNS section. The core therefore uses the system resolver behavior available to the selected network engine."))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                AppLocalization.string("No resolver address or browsing-domain value is collected for this screen."),
                systemImage: "hand.raised.fill"
            )
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
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
            .fill(Color.accentColor)
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

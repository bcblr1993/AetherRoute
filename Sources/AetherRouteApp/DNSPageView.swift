import AetherRouteKit
import SwiftUI

struct DNSView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var showsAdvancedDNS = false
    @State private var isCompactPolicyLayout = false

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                        header(summary.dns)
                        if usesAutomaticTUNDNS(summary.dns) {
#if AETHERROUTE_INDEPENDENT
                            automaticTUNDNSContent(summary.dns)
                            tunRuntimePolicyContent(summary.dns)
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

    private func header(_ dns: DNSConfigurationSummary) -> some View {
        AetherPageHeader(.dns, subtitle: headerDetail(dns)) {
            StatePill(
                title: statusTitle(dns),
                color: headerColor(dns),
                symbol: headerSymbol(dns)
            )
        }
    }

    @ViewBuilder
    private func configuredContent(_ dns: DNSConfigurationSummary) -> some View {
        HStack(spacing: AetherVisual.s3) {
            DNSMetricCard(
                title: AppLocalization.string("Primary"),
                summary: AppLocalization.format("%lld upstreams", Int64(dns.nameserverCount)),
                symbol: "server.rack",
                tint: .blue
            )
            DNSMetricCard(
                title: AppLocalization.string("Fallback"),
                summary: AppLocalization.format("%lld resolvers", Int64(dns.fallbackCount)),
                symbol: "arrow.trianglehead.branch",
                tint: .accentColor
            )
            DNSMetricCard(
                title: AppLocalization.string("Policies"),
                summary: AppLocalization.format("%lld domain rules", Int64(dns.nameserverPolicyCount)),
                symbol: "list.bullet.indent",
                tint: .accentColor
            )
        }

#if AETHERROUTE_INDEPENDENT
        tunRuntimePolicyContent(dns)
#else
        resolutionBehaviorSection(dns)
#endif

        DisclosureGroup("Advanced DNS details", isExpanded: $showsAdvancedDNS) {
        if dns.mode == .fakeIP || dns.fakeIPFilterCount > 0 {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                upstreamPrivacySection(dns)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                fakeIPSafeguardsSection(dns)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        } else {
            upstreamPrivacySection(dns)
        }

        }

        Label(
            AppLocalization.string("This page is a privacy-safe view of the imported profile. The protocol core remains authoritative and validates DNS semantics when a session starts."),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.primary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, AetherVisual.s1)
    }

    private func upstreamPrivacySection(_ dns: DNSConfigurationSummary) -> some View {
        FeatureSection(title: AppLocalization.string("Upstream privacy"), symbol: "lock.shield") {
            VStack(alignment: .leading, spacing: AetherVisual.s4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Transport types"))
                            .font(.subheadline.weight(.semibold))
                        Text(AppLocalization.string("Server addresses stay hidden in this summary."))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
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
                            .padding(.horizontal, AetherVisual.s3)
                            .padding(.vertical, AetherVisual.s2)
                            .background(
                                transportColor(transport).opacity(0.09),
                                in: Capsule()
                            )
                        }
                    }
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: AetherVisual.s3, verticalSpacing: AetherVisual.s2) {
                    GridRow {
                        DNSCountLabel(AppLocalization.string("Bootstrap"))
                        Spacer(minLength: 8)
                        Text(verbatim: String(dns.defaultNameserverCount))
                            .monospacedDigit()
                    }
                    GridRow {
                        DNSCountLabel(AppLocalization.string("Proxy hostnames"))
                        Spacer(minLength: 8)
                        Text(verbatim: String(dns.proxyNameserverCount))
                            .monospacedDigit()
                    }
                    GridRow {
                        DNSCountLabel(AppLocalization.string("Local listener"))
                        Spacer(minLength: 8)
                        Text(
                            dns.hasListener
                                ? AppLocalization.string("Configured")
                                : AppLocalization.string("None")
                        )
                    }
                    GridRow {
                        DNSCountLabel(AppLocalization.string("EDNS subnet"))
                        Spacer(minLength: 8)
                        Text(
                            dns.hasEDNSClientSubnet
                                ? AppLocalization.string("Configured")
                                : AppLocalization.string("None")
                        )
                    }
                }
                .font(.subheadline)
            }
            .padding(AetherVisual.s5)
            .aetherPanel()
        }
    }

    private func fakeIPSafeguardsSection(_ dns: DNSConfigurationSummary) -> some View {
        FeatureSection(title: AppLocalization.string("Fake-IP safeguards"), symbol: "wand.and.stars") {
            VStack(alignment: .leading, spacing: AetherVisual.s4) {
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
                    Spacer(minLength: 8)
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
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.vertical, AetherVisual.s2)
                    .background(
                        Color.accentColor.opacity(0.09),
                        in: Capsule()
                    )
                }

                Divider()

                Grid(alignment: .leading, horizontalSpacing: AetherVisual.s3, verticalSpacing: AetherVisual.s2) {
                    GridRow {
                        DNSCountLabel(AppLocalization.string("Bypass filters"))
                        Spacer(minLength: 8)
                        Text(verbatim: String(dns.fakeIPFilterCount))
                            .monospacedDigit()
                    }
                    GridRow {
                        DNSCountLabel(AppLocalization.string("Fallback filter"))
                        Spacer(minLength: 8)
                        Text(
                            dns.hasFallbackFilter
                                ? AppLocalization.string("Configured")
                                : AppLocalization.string("Default")
                        )
                    }
                }
                .font(.subheadline)
            }
            .padding(AetherVisual.s5)
            .aetherPanel()
        }
    }

#if !AETHERROUTE_INDEPENDENT
    private func resolutionBehaviorSection(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        FeatureSection(title: AppLocalization.string("Resolution behavior"), symbol: "switch.2") {
            VStack(spacing: 0) {
                DNSSettingRow(
                    title: AppLocalization.string("Enhanced mode"),
                    detail: modeDetail(dns.mode),
                    value: modeTitle(dns.mode),
                    symbol: modeSymbol(dns.mode),
                    tint: modeColor(dns.mode)
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: AppLocalization.string("IPv6 answers"),
                    detail: dns.allowsIPv6
                        ? AppLocalization.string("AAAA responses are allowed by this profile.")
                        : AppLocalization.string("AAAA responses are filtered by this profile."),
                    value: dns.allowsIPv6
                        ? AppLocalization.string("Allowed")
                        : AppLocalization.string("Filtered"),
                    symbol: "6.circle",
                    tint: dns.allowsIPv6 ? .accentColor : .secondary
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: AppLocalization.string("Rule-aware queries"),
                    detail: dns.respectsRules
                        ? AppLocalization.string("Upstream queries follow the routing rule engine.")
                        : AppLocalization.string("Upstream queries use the core's direct DNS path."),
                    value: dns.respectsRules
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "arrow.triangle.branch",
                    tint: dns.respectsRules ? .accentColor : .secondary
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: AppLocalization.string("Hosts mapping"),
                    detail: dns.usesHosts
                        ? AppLocalization.string("Profile hosts entries participate in resolution.")
                        : AppLocalization.string("Profile hosts entries are ignored for DNS."),
                    value: dns.usesHosts
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "house.and.flag",
                    tint: dns.usesHosts ? .blue : .secondary
                )
            }
            .aetherPanel()
        }
    }
#endif

#if AETHERROUTE_INDEPENDENT
    private func automaticTUNDNSContent(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        let mode = tunnel.dnsRuntimePolicy
            .effectivePacketTunnelResolutionMode(for: dns)
        let allowsIPv6 = tunnel.dnsRuntimePolicy
            .effectivePacketTunnelAllowsIPv6(
                for: dns,
                profileAllowsIPv6: tunnel.activeProfileSummary?.allowsIPv6 == true
            )
        return FeatureSection(title: AppLocalization.string("Automatic TUN DNS"), symbol: "network") {
            VStack(spacing: 0) {
                DNSSettingRow(
                    title: AppLocalization.string("Enhanced mode"),
                    detail: modeDetail(mode),
                    value: modeTitle(mode),
                    symbol: modeSymbol(mode),
                    tint: modeColor(mode)
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: AppLocalization.string("IPv6 answers"),
                    detail: AppLocalization.string("IPv6 answers follow the selected TUN policy."),
                    value: allowsIPv6
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "6.circle",
                    tint: allowsIPv6 ? .accentColor : .secondary
                )
            }
            .aetherPanel()
        }
    }

    private func tunRuntimePolicyContent(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        FeatureSection(
            title: AppLocalization.string("DNS adjustments in TUN mode"),
            symbol: "slider.horizontal.3",
            accessory: { AetherHelpButton(topic: .dnsRuntimeOverrides) }
        ) {
            VStack(spacing: 0) {
                HStack(spacing: AetherVisual.s3) {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Override the active profile"))
                            .font(.body.weight(.semibold))
                        Text(
                            tunnel.networkEngineMode == .tun
                                ? AppLocalization.string("Changes are validated first and apply the next time you connect with TUN.")
                                : AppLocalization.string("Select the TUN engine on Overview to edit runtime overrides.")
                        )
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: AetherVisual.s3)
                    StatePill(
                        title: tunnel.dnsRuntimePolicy.isInherited
                            ? AppLocalization.string("Follow profile")
                            : AppLocalization.string("Customized"),
                        color: tunnel.dnsRuntimePolicy.isInherited
                            ? .secondary
                            : .accentColor,
                        symbol: tunnel.dnsRuntimePolicy.isInherited
                            ? "doc.text"
                            : "slider.horizontal.3"
                    )
                }
                .padding(AetherVisual.s4)

                Divider().padding(.leading, AetherVisual.s4)
                let mode = effectiveResolutionMode(dns)
                dnsPolicyRow(
                    symbol: modeSymbol(mode),
                    tint: modeColor(mode),
                    title: AppLocalization.string("Resolution mode"),
                    detail: followsProfile(
                        tunnel.dnsRuntimePolicy.resolutionMode == .inherit,
                        value: modeTitle(mode),
                        detail: modeDetail(mode)
                    ),
                    help: .dnsResolutionMode
                ) {
                    AetherSegmentedPicker(
                        selection: resolutionModeBinding,
                        options: DNSRuntimeResolutionMode.allCases.map {
                            .init(value: $0, title: runtimeModeTitle($0))
                        },
                        accessibilityLabel: AppLocalization.string("Resolution mode"),
                        accessibilityIdentifier: "dns-runtime-resolution-mode"
                    )
                    .fixedSize()
                }

                Divider().padding(.leading, AetherVisual.s4)
                let allowsIPv6 = tunnel.dnsRuntimePolicy
                    .effectivePacketTunnelAllowsIPv6(
                        for: dns,
                        profileAllowsIPv6: tunnel.activeProfileSummary?.allowsIPv6 == true
                    )
                dnsPolicyRow(
                    symbol: "6.circle",
                    tint: allowsIPv6 ? .accentColor : .secondary,
                    title: AppLocalization.string("IPv6 answers"),
                    detail: followsProfile(
                        tunnel.dnsRuntimePolicy.ipv6 == .inherit,
                        value: onOffTitle(allowsIPv6),
                        detail: allowsIPv6
                            ? AppLocalization.string("AAAA responses are allowed.")
                            : AppLocalization.string("AAAA responses are filtered.")
                    ),
                    help: .dnsIPv6
                ) {
                    dnsBooleanPicker(
                        AppLocalization.string("IPv6 answers"),
                        selection: booleanBinding(\.ipv6),
                        identifier: "dns-runtime-ipv6"
                    )
                }

                Divider().padding(.leading, AetherVisual.s4)
                let respectsRules = tunnel.dnsRuntimePolicy.respectsRules
                    .resolved(profileValue: dns.respectsRules)
                dnsPolicyRow(
                    symbol: "arrow.triangle.branch",
                    tint: respectsRules ? .accentColor : .secondary,
                    title: AppLocalization.string("Rule-aware queries"),
                    detail: followsProfile(
                        tunnel.dnsRuntimePolicy.respectsRules == .inherit,
                        value: onOffTitle(respectsRules),
                        detail: respectsRules
                            ? AppLocalization.string("Upstream queries follow the routing rule engine.")
                            : AppLocalization.string("Upstream queries use the core's direct DNS path.")
                    ),
                    help: .dnsRespectRules
                ) {
                    dnsBooleanPicker(
                        AppLocalization.string("Rule-aware queries"),
                        selection: booleanBinding(\.respectsRules),
                        identifier: "dns-runtime-respect-rules"
                    )
                }

                Divider().padding(.leading, AetherVisual.s4)
                dnsPolicyRow(
                    symbol: "house.and.flag",
                    tint: dns.usesHosts ? .blue : .secondary,
                    title: AppLocalization.string("Hosts mapping"),
                    // Hosts has no override: it always follows the profile,
                    // so it reads as a fact rather than a lone control.
                    detail: followsProfile(
                        true,
                        value: onOffTitle(dns.usesHosts),
                        detail: dns.usesHosts
                            ? AppLocalization.string("Profile hosts entries participate in resolution.")
                            : AppLocalization.string("Profile hosts entries are ignored for DNS.")
                    ),
                    help: .dnsHosts,
                    canDisable: false
                ) {
                    EmptyView()
                }

                // Saving this card's own change locks it for a moment; that
                // is not a lock the person needs explained.
                if tunnel.networkEngineMode == .tun,
                   !tunnel.isUpdatingDNSRuntimePolicy,
                   let reason = tunnel.profileEditLockReason {
                    Divider().padding(.leading, AetherVisual.s4)
                    Label(reason, systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.vertical, AetherVisual.s3)
                        .accessibilityIdentifier("dns-runtime-lock-reason")
                }

                Divider().padding(.leading, AetherVisual.s4)
                HStack {
                    Text("DNS changes apply on the next TUN connection, including restoring profile defaults.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Restore profile defaults") {
                        Task { await tunnel.setDNSRuntimePolicy(DNSRuntimePolicy()) }
                    }
                    .disabled(tunnel.dnsRuntimePolicy.isInherited || !tunnel.canModifyDNSRuntimePolicy || tunnel.networkEngineMode != .tun)
                    .accessibilityIdentifier("dns-restore-defaults")
                }
                .padding(AetherVisual.s4)
                if let message = tunnel.dnsRuntimePolicyMessage {
                    Divider().padding(.leading, AetherVisual.s4)
                    Label(
                        message,
                        systemImage: tunnel.dnsRuntimePolicyMessageIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        tunnel.dnsRuntimePolicyMessageIsError
                            ? Color.orange
                            : Color.accentColor
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AetherVisual.s4)
                    .transition(AetherVisual.insertion)
                }
            }
            .aetherPanel()
            .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.dnsRuntimePolicyMessage)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width < Self.compactPolicyWidth
            } action: { isCompact in
                isCompactPolicyLayout = isCompact
            }
        }
    }

    /// Below this card width a row cannot hold its description beside the
    /// four-way resolution picker, which keeps its natural width (about 350
    /// points: "Redir-host" sets every segment's width) rather than
    /// overflowing the card as a fixed 250-point frame did.
    nonisolated private static let compactPolicyWidth: CGFloat = 720
    private static let policyIconSize: CGFloat = 34

    private func dnsPolicyRow<Control: View>(
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        help: HelpTopic? = nil,
        canDisable: Bool = true,
        @ViewBuilder control: () -> Control
    ) -> some View {
        // In a narrow window the segmented control moves under the text
        // instead of squeezing the description into a tall column.
        let layout = isCompactPolicyLayout
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: AetherVisual.s2))
            : AnyLayout(HStackLayout(spacing: AetherVisual.s4))
        return layout {
            HStack(spacing: AetherVisual.s4) {
                Image(systemName: symbol)
                    .foregroundStyle(tint)
                    .frame(width: Self.policyIconSize, height: Self.policyIconSize)
                    .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    HStack(spacing: AetherVisual.s1) {
                        Text(title)
                            .font(.body.weight(.medium))
                            .foregroundStyle(.primary)
                        if let help {
                            AetherHelpButton(topic: help)
                        }
                    }
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Group {
                if canDisable {
                    control()
                        .disabled(
                            tunnel.networkEngineMode != .tun
                                || !tunnel.canModifyDNSRuntimePolicy
                        )
                } else {
                    control()
                }
            }
            .padding(.leading, isCompactPolicyLayout ? Self.policyIconSize + AetherVisual.s4 : .zero)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
    }

    private func dnsBooleanPicker(
        _ title: String,
        selection: Binding<DNSRuntimeBoolean>,
        identifier: String
    ) -> some View {
        AetherSegmentedPicker(
            selection: selection,
            options: DNSRuntimeBoolean.allCases.map {
                .init(value: $0, title: runtimeBooleanTitle($0))
            },
            accessibilityLabel: title,
            accessibilityIdentifier: identifier
        )
        .fixedSize()
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
        // Segmented Picker can invoke its Binding setter from SwiftUI's view
        // update pass. Dispatch to the next main run-loop turn before the
        // observable manager publishes the validated policy and message.
        DispatchQueue.main.async {
            Task { await tunnel.setDNSRuntimePolicy(policy) }
        }
    }

    /// The mode the next TUN session uses: the override, or the profile's.
    private func effectiveResolutionMode(
        _ dns: DNSConfigurationSummary
    ) -> DNSResolutionMode {
        tunnel.dnsRuntimePolicy.effectivePacketTunnelResolutionMode(for: dns)
    }

    /// Names the profile's value when a row follows it, so "Follow profile"
    /// never hides what the profile actually says.
    private func followsProfile(
        _ inherits: Bool,
        value: String,
        detail: String
    ) -> String {
        guard inherits else { return detail }
        return String.localizedStringWithFormat(
            AppLocalization.string("Follows profile: %@ · %@"),
            value,
            detail
        )
    }

    private func onOffTitle(_ isOn: Bool) -> String {
        isOn ? AppLocalization.string("On") : AppLocalization.string("Off")
    }

    private func runtimeModeTitle(_ mode: DNSRuntimeResolutionMode) -> String {
        switch mode {
        case .inherit: AppLocalization.string("Follow profile")
        case .normal: AppLocalization.string("Normal")
        case .fakeIP: AppLocalization.string("Fake-IP")
        case .redirHost: AppLocalization.string("Redir-host")
        }
    }

    private func runtimeBooleanTitle(_ value: DNSRuntimeBoolean) -> String {
        switch value {
        case .inherit: AppLocalization.string("Follow profile")
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
        .padding(AetherVisual.s5)
        .aetherPanel()
    }

    private func headerColor(_ dns: DNSConfigurationSummary) -> Color {
        if usesAutomaticTUNDNS(dns) {
            return modeColor(
                tunnel.dnsRuntimePolicy.effectivePacketTunnelResolutionMode(for: dns)
            )
        }
        guard dns.isPresent else { return .secondary }
        return dns.isEnabled ? modeColor(dns.mode) : .orange
    }

    private func headerSymbol(_ dns: DNSConfigurationSummary) -> String {
        if usesAutomaticTUNDNS(dns) {
            return modeSymbol(
                tunnel.dnsRuntimePolicy.effectivePacketTunnelResolutionMode(for: dns)
            )
        }
        guard dns.isPresent else { return "macbook.and.iphone" }
        return dns.isEnabled ? modeSymbol(dns.mode) : "pause.circle.fill"
    }

    private func statusTitle(_ dns: DNSConfigurationSummary) -> String {
        if usesAutomaticTUNDNS(dns) {
            return modeTitle(
                tunnel.dnsRuntimePolicy.effectivePacketTunnelResolutionMode(for: dns)
            )
        }
        guard dns.isPresent else { return AppLocalization.string("System resolver") }
        return dns.isEnabled
            ? AppLocalization.string("Profile DNS on")
            : AppLocalization.string("Profile DNS off")
    }

    private func headerDetail(_ dns: DNSConfigurationSummary) -> String {
        if usesAutomaticTUNDNS(dns) {
            return AppLocalization.string("TUN manages DNS automatically when the profile has no enabled DNS section. Review or adjust its policy below.")
        }
        guard dns.isPresent else {
            return AppLocalization.string("This profile does not define a custom DNS section.")
        }
        return dns.isEnabled
            ? AppLocalization.string("Resolver behavior is supplied by the active profile and validated by the core.")
            : AppLocalization.string("A DNS section is present, but its resolver is disabled.")
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

private struct DNSMetricCard: View {
    @State private var isHovered = false

    let title: String
    /// The counted phrase ("2 upstreams"), plural-aware as one string.
    let summary: String
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(spacing: AetherVisual.s3) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(tint)
                    .frame(width: 32, height: 32)
                    .background(
                        tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(summary)
                .font(.title3.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .aetherNumericValue(summary)
        }
        .padding(AetherVisual.s4)
        .frame(maxWidth: .infinity)
        .aetherPanel()
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .stroke(isHovered ? tint.opacity(0.35) : Color.clear, lineWidth: 1)
        }
        .animation(AetherVisual.quickFade, value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

private struct DNSSettingRow: View {

    let title: String
    let detail: String
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 14)
            Text(value)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s2)
                .background(tint.opacity(0.09), in: Capsule())
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

private extension DNSRuntimeBoolean {
    func resolved(profileValue: Bool) -> Bool {
        switch self {
        case .inherit: profileValue
        case .disabled: false
        case .enabled: true
        }
    }
}

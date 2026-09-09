import AetherRouteKit
import SwiftUI

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AetherVisual.s5) {
                        VStack(alignment: .leading, spacing: AetherVisual.s4) {
                            HStack(spacing: AetherVisual.s5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                        .fill(Color.indigo.opacity(0.10))
                                    Image(systemName: "list.number")
                                        .font(.system(size: 25, weight: .medium))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .frame(width: 58, height: 58)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                                    Text("Ordered routing policy")
                                        .font(.title3.weight(.semibold))
                                        .foregroundStyle(.primary)
                                    Text("Rules are evaluated from top to bottom by the protocol core.")
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack(spacing: AetherVisual.s4) {
                                HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                                    Text(verbatim: String(summary.ruleCount))
                                        .font(.title2.weight(.semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(.primary)
                                    Text("explicit rules")
                                        .font(.body)
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: AetherVisual.s2)
                                StatePill(
                                    title: String.localizedStringWithFormat(
                                        AppLocalization.string("Selected: %@"),
                                        tunnel.routingMode.localizedTitle
                                    ),
                                    color: .indigo,
                                    symbol: "arrow.triangle.branch"
                                )
                            }
                        }
                        .padding(AetherVisual.s5)
                        .featureCard()
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isStaticText)

                        if !summary.ruleProviders.isEmpty {
                            FeatureSection(title: "Rule providers", symbol: "shippingbox") {
                                VStack(spacing: 0) {
                                    ForEach(summary.ruleProviders) { provider in
                                        ProviderRow(provider: provider)
                                        if provider.id != summary.ruleProviders.last?.id {
                                            Divider().padding(
                                                .leading,
                                                AetherVisual.onboardingTopPadding
                                            )
                                        }
                                    }
                                }
                                .featureCard()
                            }
                        }

                        if summary.rules.isEmpty {
                            FeatureEmptyState(
                                symbol: "list.bullet.rectangle.portrait",
                                title: "No explicit rules",
                                detail: "The active profile contains no ordered rule entries. Its effective fallback is determined only after the protocol core validates and starts the profile."
                            )
                        } else {
                            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                                Label("Evaluation order", systemImage: "arrow.down")
                                    .font(.title3.weight(.bold))
                                VStack(spacing: AetherVisual.s3) {
                                    ForEach(summary.rules) { rule in
                                        RuleRow(rule: rule)
                                    }
                                }
                                .accessibilityElement(children: .contain)
                                .accessibilityLabel("Ordered routing rules")
                            }
                        }

                        TruncationNotice(
                            visibleCount: summary.rules.count,
                            totalCount: summary.ruleCount
                        )
                        TruncationNotice(
                            visibleCount: summary.ruleProviders.count,
                            totalCount: summary.ruleProviderCount
                        )
                    }
                    .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                    .padding(.top, AetherVisual.pageTopPadding)
                    .padding(.bottom, AetherVisual.pageBottomPadding)
                    .frame(maxWidth: AetherVisual.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Routing rules content")
                }
            } else {
                FeatureEmptyState(
                    symbol: "list.bullet.rectangle.portrait",
                    title: "No rule set loaded",
                    detail: "Import a validated profile to inspect routing order and targets."
                )
            }
        }
        .accessibilityIdentifier("rules-page")
    }
}

struct DNSView: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AetherVisual.s5) {
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
                    .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                    .padding(.top, AetherVisual.pageTopPadding)
                    .padding(.bottom, AetherVisual.pageBottomPadding)
                    .frame(maxWidth: AetherVisual.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("DNS configuration details")
                    .accessibilityIdentifier("dns-page-content")
                }
            } else {
                FeatureEmptyState(
                    symbol: "network.badge.shield.half.filled",
                    title: "No DNS policy loaded",
                    detail: "Import a validated profile to inspect its resolver behavior without exposing server addresses."
                )
            }
        }
        .accessibilityIdentifier("dns-page")
    }

    private func header(_ dns: DNSConfigurationSummary) -> some View {
        HStack(spacing: AetherVisual.s5) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(headerColor(dns).opacity(0.10))
                Image(systemName: headerSymbol(dns))
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(headerColor(dns))
            }
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text("DNS & Fake-IP")
                    .font(.title3.weight(.semibold))
                Text(headerDetail(dns))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            StatePill(
                title: statusTitle(dns),
                color: headerColor(dns),
                symbol: headerSymbol(dns)
            )
        }
        .padding(AetherVisual.s5)
        .featureCard()
    }

    @ViewBuilder
    private func configuredContent(_ dns: DNSConfigurationSummary) -> some View {
        HStack(spacing: AetherVisual.s3) {
            DNSMetricCard(
                title: "Primary",
                value: "\(dns.nameserverCount)",
                detail: "upstreams",
                symbol: "server.rack",
                tint: .blue
            )
            DNSMetricCard(
                title: "Fallback",
                value: "\(dns.fallbackCount)",
                detail: "resolvers",
                symbol: "arrow.trianglehead.branch",
                tint: .indigo
            )
            DNSMetricCard(
                title: "Policies",
                value: "\(dns.nameserverPolicyCount)",
                detail: "domain rules",
                symbol: "list.bullet.indent",
                tint: .teal
            )
        }

        FeatureSection(title: "Resolution behavior", symbol: "switch.2") {
            VStack(spacing: 0) {
                DNSSettingRow(
                    title: "Enhanced mode",
                    detail: modeDetail(dns.mode),
                    value: modeTitle(dns.mode),
                    symbol: modeSymbol(dns.mode),
                    tint: modeColor(dns.mode)
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: "IPv6 answers",
                    detail: dns.allowsIPv6
                        ? "AAAA responses are allowed by this profile."
                        : "AAAA responses are filtered by this profile.",
                    value: dns.allowsIPv6
                        ? AppLocalization.string("Allowed")
                        : AppLocalization.string("Filtered"),
                    symbol: "6.circle",
                    tint: dns.allowsIPv6 ? .teal : .secondary
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: "Rule-aware queries",
                    detail: dns.respectsRules
                        ? "Upstream queries follow the routing rule engine."
                        : "Upstream queries use the core's direct DNS path.",
                    value: dns.respectsRules
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "arrow.triangle.branch",
                    tint: dns.respectsRules ? .indigo : .secondary
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: "Hosts mapping",
                    detail: dns.usesHosts
                        ? "Profile hosts entries participate in resolution."
                        : "Profile hosts entries are ignored for DNS.",
                    value: dns.usesHosts
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "house.and.flag",
                    tint: dns.usesHosts ? .blue : .secondary
                )
            }
            .featureCard()
        }

#if AETHERROUTE_INDEPENDENT
        tunRuntimePolicyContent(dns)
#endif

        FeatureSection(title: "Upstream privacy", symbol: "lock.shield") {
            VStack(alignment: .leading, spacing: AetherVisual.s4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text("Transport types")
                            .font(.subheadline.weight(.semibold))
                        Text("Server addresses stay hidden in this summary.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(
                        String.localizedStringWithFormat(
                            AppLocalization.string("%lld total"),
                            totalResolverCount(dns)
                        )
                    )
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                if dns.upstreamTransports.isEmpty {
                    Label("No explicit upstream transport", systemImage: "minus.circle")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
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

                Grid(horizontalSpacing: 28, verticalSpacing: 10) {
                    GridRow {
                        DNSCountLabel("Bootstrap")
                        Text(verbatim: String(dns.defaultNameserverCount))
                            .monospacedDigit()
                        DNSCountLabel("Proxy hostnames")
                        Text(verbatim: String(dns.proxyNameserverCount))
                            .monospacedDigit()
                    }
                    GridRow {
                        DNSCountLabel("Local listener")
                        Text(
                            dns.hasListener
                                ? AppLocalization.string("Configured")
                                : AppLocalization.string("None")
                        )
                        DNSCountLabel("EDNS subnet")
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
            .featureCard()
        }

        if dns.mode == .fakeIP || dns.fakeIPFilterCount > 0 {
            FeatureSection(title: "Fake-IP safeguards", symbol: "wand.and.stars") {
                HStack(spacing: 0) {
                    DNSCompactFact(
                        title: "Address pool",
                        value: dns.hasExplicitFakeIPRange
                            ? AppLocalization.string("Profile range")
                            : AppLocalization.string("Core default"),
                        symbol: "rectangle.3.group.bubble"
                    )
                    Divider().frame(height: 50)
                    DNSCompactFact(
                        title: "Bypass filters",
                        value: "\(dns.fakeIPFilterCount)",
                        symbol: "line.3.horizontal.decrease.circle"
                    )
                    Divider().frame(height: 50)
                    DNSCompactFact(
                        title: "Fallback filter",
                        value: dns.hasFallbackFilter
                            ? AppLocalization.string("Configured")
                            : AppLocalization.string("Default"),
                        symbol: "checkmark.shield"
                    )
                }
                .padding(.vertical, AetherVisual.s2)
                .featureCard()
            }
        }

        Label(
            "This page is a privacy-safe view of the imported profile. The protocol core remains authoritative and validates DNS semantics when a session starts.",
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, AetherVisual.s1)
    }

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
        return FeatureSection(title: "Automatic TUN DNS", symbol: "network") {
            VStack(spacing: 0) {
                DNSSettingRow(
                    title: "Enhanced mode",
                    detail: modeDetail(mode),
                    value: modeTitle(mode),
                    symbol: modeSymbol(mode),
                    tint: modeColor(mode)
                )
                Divider().padding(.leading, AetherVisual.wideListIndent)
                DNSSettingRow(
                    title: "IPv6 answers",
                    detail: "IPv6 answers follow the selected TUN policy.",
                    value: allowsIPv6
                        ? AppLocalization.string("On")
                        : AppLocalization.string("Off"),
                    symbol: "6.circle",
                    tint: allowsIPv6 ? .teal : .secondary
                )
            }
            .featureCard()
        }
    }

    private func tunRuntimePolicyContent(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        FeatureSection(title: "TUN runtime overrides", symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: AetherVisual.s3) {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text("Structured core policy")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            tunnel.networkEngineMode == .tun
                                ? AppLocalization.string("Overrides are validated and passed directly to the Rust core when TUN starts.")
                                : AppLocalization.string("Select the TUN engine on Overview to edit runtime overrides.")
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    StatePill(
                        title: tunnel.dnsRuntimePolicy.isInherited
                            ? AppLocalization.string("Profile")
                            : AppLocalization.string("Customized"),
                        color: tunnel.dnsRuntimePolicy.isInherited
                            ? .secondary
                            : .indigo,
                        symbol: tunnel.dnsRuntimePolicy.isInherited
                            ? "doc.text"
                            : "slider.horizontal.3"
                    )
                }
                .padding(AetherVisual.s4)

                Divider().padding(.leading, AetherVisual.s4)
                dnsPolicyRow(
                    title: "Resolution mode",
                    detail: "Choose Normal, Fake-IP, or Redir-host without rewriting imported YAML."
                ) {
                    Picker("Resolution mode", selection: resolutionModeBinding) {
                        ForEach(DNSRuntimeResolutionMode.allCases, id: \.self) {
                            Text(runtimeModeTitle($0)).tag($0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                    .accessibilityIdentifier("dns-runtime-resolution-mode")
                }

                Divider().padding(.leading, AetherVisual.s4)
                dnsPolicyRow(
                    title: "IPv6 answers",
                    detail: "Override whether the resolver returns AAAA answers."
                ) {
                    dnsBooleanPicker(
                        "IPv6 answers",
                        selection: booleanBinding(\.ipv6),
                        identifier: "dns-runtime-ipv6"
                    )
                }

                Divider().padding(.leading, AetherVisual.s4)
                dnsPolicyRow(
                    title: "Rule-aware queries",
                    detail: "Route upstream DNS queries through the rule engine."
                ) {
                    dnsBooleanPicker(
                        "Rule-aware queries",
                        selection: booleanBinding(\.respectsRules),
                        identifier: "dns-runtime-respect-rules"
                    )
                }

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
                            : Color.teal
                    )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(AetherVisual.s4)
                }
            }
            .featureCard()
        }
    }

    private func dnsPolicyRow<Control: View>(
        title: LocalizedStringKey,
        detail: LocalizedStringKey,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AetherVisual.s4) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 16)
            control()
                .disabled(
                    tunnel.networkEngineMode != .tun
                        || !tunnel.canModifyDNSRuntimePolicy
                )
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
    }

    private func dnsBooleanPicker(
        _ title: LocalizedStringKey,
        selection: Binding<DNSRuntimeBoolean>,
        identifier: String
    ) -> some View {
        Picker(title, selection: selection) {
            ForEach(DNSRuntimeBoolean.allCases, id: \.self) {
                Text(runtimeBooleanTitle($0)).tag($0)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .frame(width: 174)
        .accessibilityIdentifier(identifier)
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

    private func runtimeModeTitle(_ mode: DNSRuntimeResolutionMode) -> String {
        switch mode {
        case .inherit: AppLocalization.string("Profile")
        case .normal: AppLocalization.string("Normal")
        case .fakeIP: AppLocalization.string("Fake-IP")
        case .redirHost: AppLocalization.string("Redir-host")
        }
    }

    private func runtimeBooleanTitle(_ value: DNSRuntimeBoolean) -> String {
        switch value {
        case .inherit: AppLocalization.string("Profile")
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
            Label("System resolver", systemImage: "macbook.and.iphone")
                .font(.headline)
            Text("The active profile has no DNS section. The core therefore uses the system resolver behavior available to the selected network engine.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                "No resolver address or browsing-domain value is collected for this screen.",
                systemImage: "hand.raised.fill"
            )
            .font(.subheadline)
            .foregroundStyle(Color.accentColor)
        }
        .padding(AetherVisual.s5)
        .featureCard()
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

    private func headerDetail(_ dns: DNSConfigurationSummary) -> LocalizedStringKey {
        if usesAutomaticTUNDNS(dns) {
            return "TUN manages DNS automatically when the profile has no enabled DNS section. Review or adjust its policy below."
        }
        guard dns.isPresent else {
            return "This profile does not define a custom DNS section."
        }
        return dns.isEnabled
            ? "Resolver behavior is supplied by the active profile and validated by the core."
            : "A DNS section is present, but its resolver is disabled."
    }

    private func modeTitle(_ mode: DNSResolutionMode) -> String {
        switch mode {
        case .normal: AppLocalization.string("Normal")
        case .fakeIP: AppLocalization.string("Fake-IP")
        case .redirHost: AppLocalization.string("Redir-host")
        case .unsupported: AppLocalization.string("Core check")
        }
    }

    private func modeDetail(_ mode: DNSResolutionMode) -> LocalizedStringKey {
        switch mode {
        case .normal: "Returns upstream addresses without synthetic mapping."
        case .fakeIP: "Maps names into a synthetic range for deterministic domain routing."
        case .redirHost: "Resolves real addresses while retaining enhanced host routing."
        case .unsupported: "The profile uses a mode that requires protocol-core validation."
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
        case .fakeIP: .indigo
        case .redirHost: .teal
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
        case .dnsOverTLS, .dnsOverHTTPS: .teal
        case .udp, .tcp: .blue
        case .dhcp: .indigo
        case .unsupported: .orange
        }
    }
}

private struct DNSMetricCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: LocalizedStringKey
    let value: String
    let detail: LocalizedStringKey
    let symbol: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(spacing: AetherVisual.s3) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(
                        tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(AetherVisual.s4)
        .frame(maxWidth: .infinity)
        .featureCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

private struct DNSSettingRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: LocalizedStringKey
    let detail: LocalizedStringKey
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
    let title: LocalizedStringKey

    init(_ title: LocalizedStringKey) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .foregroundStyle(.secondary)
            .frame(minWidth: 110, alignment: .leading)
    }
}

private struct DNSCompactFact: View {
    let title: LocalizedStringKey
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AetherVisual.s5)
        .accessibilityElement(children: .combine)
    }
}

struct ProfileInspectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let profileName: String
    let itemCount: Int
    let groupCount: Int
    let providerCount: Int

    var body: some View {
        HStack(spacing: AetherVisual.s5) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.teal.opacity(0.10))
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(profileName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .help(profileName)
                Text("Import safety checks passed. The core validates protocol semantics when a session starts.")
                    .font(.body.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            CountBadge(value: itemCount, label: "Endpoints")
            CountBadge(value: groupCount, label: "Groups")
            if providerCount > 0 {
                CountBadge(value: providerCount, label: "Providers")
            }
        }
        .padding(AetherVisual.s5)
        .featureCard()
    }
}

private struct CountBadge: View {
    let value: Int
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: AetherVisual.s1) {
            Text(verbatim: String(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 52)
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.s2)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

}

struct FeatureSection<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
    }
}

struct ProviderRow: View {
    let provider: ProviderConfigurationSummary

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(provider.name).fontWeight(.medium)
                Text(provider.sourceType.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .accessibilityElement(children: .combine)
    }
}

func formattedRate(_ bytes: UInt64) -> String {
    "\(formattedBytes(bytes))/s"
}

func formattedBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(
        fromByteCount: Int64(clamping: bytes),
        countStyle: .file
    )
}

private struct RuleRow: View {
    let rule: RuleConfigurationSummary

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            Text(verbatim: String(rule.order))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(rule.kind)
                    .font(.body.monospaced().weight(.semibold))
                if let criteria = rule.criteria {
                    Text(criteria)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Any remaining traffic")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                }
            }
            Spacer(minLength: 14)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(rule.target)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(AetherVisual.s4)
        .featureCard()
        .accessibilityElement(children: .contain)
    }

}

private struct StatePill: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(.primary)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
            .font(.body.weight(.medium))
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(color.opacity(0.52), lineWidth: 0.75)
            }
    }
}

struct FeatureEmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let detail: LocalizedStringKey

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .aetherPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(detail))
    }
}

private struct TruncationNotice: View {
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        if visibleCount < totalCount {
            Label(
                String.localizedStringWithFormat(
                    AppLocalization.string("Showing %lld of %lld items."),
                    visibleCount,
                    totalCount
                ),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension View {
    func featureCard() -> some View {
        aetherPanel()
    }
}

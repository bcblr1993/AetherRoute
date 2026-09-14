import AetherRouteKit
import SwiftUI

enum RuleKindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case domain = "Domain"
    case ip = "IP / CIDR"
    case geo = "Geo"
    case match = "Match"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all: AppLocalization.string("All")
        case .domain: "DOMAIN"
        case .ip: "IP-CIDR"
        case .geo: "GEO"
        case .match: "MATCH"
        }
    }

    func accepts(_ kind: String) -> Bool {
        let upper = kind.uppercased()
        switch self {
        case .all: return true
        case .domain: return upper.contains("DOMAIN")
        case .ip: return upper.contains("IP") || upper.contains("CIDR")
        case .geo: return upper.contains("GEO")
        case .match: return upper.contains("MATCH") || (!upper.contains("DOMAIN") && !upper.contains("IP") && !upper.contains("CIDR") && !upper.contains("GEO"))
        }
    }
}

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var searchText = ""
    @State private var selectedFilter: RuleKindFilter = .all

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                let displayedRules = filteredRules(from: summary.rules)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: AetherVisual.s4) {
                        // 1. 顶部规则概览 Hero 卡片
                        VStack(alignment: .leading, spacing: AetherVisual.s4) {
                            HStack(spacing: AetherVisual.s5) {
                                ZStack {
                                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                        .fill(Color.indigo.opacity(0.12))
                                    Image(systemName: "list.number")
                                        .font(.system(size: 24, weight: .semibold))
                                        .foregroundStyle(Color.accentColor)
                                }
                                .frame(width: 52, height: 52)
                                .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                    Text(AppLocalization.string("Ordered routing policy"))
                                        .font(.title3.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Text(AppLocalization.string("Rules are evaluated from top to bottom by the protocol core."))
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            HStack(spacing: AetherVisual.s4) {
                                HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                                    Text(verbatim: String(summary.ruleCount))
                                        .font(.title2.weight(.bold))
                                        .monospacedDigit()
                                        .foregroundStyle(.primary)
                                    Text(AppLocalization.string("explicit rules"))
                                        .font(.body.weight(.medium))
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
                            FeatureSection(title: AppLocalization.string("Rule providers"), symbol: "shippingbox") {
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

                        // 2. 搜索与分类过滤工具栏
                        if !summary.rules.isEmpty {
                            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                                HStack(spacing: AetherVisual.s2) {
                                    // 过滤胶囊栏
                                    HStack(spacing: AetherVisual.sMicro) {
                                        ForEach(RuleKindFilter.allCases) { filter in
                                            let isSelected = selectedFilter == filter
                                            let count = summary.rules.filter { filter.accepts($0.kind) }.count
                                            Button {
                                                withAnimation(AetherVisual.quickFade) {
                                                    selectedFilter = filter
                                                }
                                            } label: {
                                                HStack(spacing: AetherVisual.s1) {
                                                    Text(filter.localizedTitle)
                                                        .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                                    if filter != .all {
                                                        Text(verbatim: "\(count)")
                                                            .font(.body.weight(.semibold))
                                                            .padding(.horizontal, AetherVisual.s1)
                                                            .padding(.vertical, AetherVisual.sMicro)
                                                            .background(
                                                                isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                                                in: Capsule()
                                                            )
                                                    }
                                                }
                                                .padding(.horizontal, AetherVisual.s2)
                                                .padding(.vertical, AetherVisual.s1)
                                                .foregroundStyle(.primary)
                                                .background(
                                                    isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                                                    in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                                                )
                                                .contentShape(Rectangle())
                                            }
                                            .buttonStyle(.plain)
                                        }
                                    }
                                    .padding(AetherVisual.sMicro)
                                    .background(
                                        Color(nsColor: .controlBackgroundColor).opacity(0.5),
                                        in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    )

                                    Spacer()

                                    Text(
                                        String.localizedStringWithFormat(
                                            AppLocalization.string("Showing %lld of %lld items."),
                                            Int64(displayedRules.count),
                                            Int64(summary.rules.count)
                                        )
                                    )
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                }

                                HStack {
                                    Label(AppLocalization.string("Evaluation order"), systemImage: "arrow.down")
                                        .font(.subheadline.weight(.bold))
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.top, AetherVisual.s1)
                            }
                        }

                        if summary.rules.isEmpty {
                            FeatureEmptyState(
                                symbol: "list.bullet.rectangle.portrait",
                                title: AppLocalization.string("No explicit rules"),
                                detail: AppLocalization.string("The active profile contains no ordered rule entries. Its effective fallback is determined only after the protocol core validates and starts the profile.")
                            )
                        } else if displayedRules.isEmpty {
                            FeatureEmptyState(
                                symbol: "line.3.horizontal.decrease.circle",
                                title: AppLocalization.string("No matching rules"),
                                detail: AppLocalization.string("Try adjusting the filter or clearing the search text.")
                            )
                        } else {
                            VStack(spacing: AetherVisual.sCompact) {
                                ForEach(displayedRules) { rule in
                                    RuleRow(rule: rule)
                                }
                            }
                            .accessibilityElement(children: .contain)
                            .accessibilityLabel(AppLocalization.string("Ordered routing rules"))
                            .animation(AetherVisual.gentleSpring, value: displayedRules.count)
                        }

                        TruncationNotice(
                            visibleCount: displayedRules.count,
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
                    .accessibilityLabel(AppLocalization.string("Routing rules content"))
                }
                .searchable(
                    text: $searchText,
                    placement: .toolbar,
                    prompt: Text(AppLocalization.string("Search rules"))
                )
            } else {
                FeatureEmptyState(
                    symbol: "list.bullet.rectangle.portrait",
                    title: AppLocalization.string("No rule set loaded"),
                    detail: AppLocalization.string("Import a validated profile to inspect routing order and targets.")
                )
            }
        }
        .accessibilityIdentifier("rules-page")
    }

    private func filteredRules(from rules: [RuleConfigurationSummary]) -> [RuleConfigurationSummary] {
        rules.filter { rule in
            let matchesKind = selectedFilter.accepts(rule.kind)
            guard matchesKind else { return false }
            if searchText.isEmpty { return true }
            let text = searchText.lowercased()
            if rule.kind.lowercased().contains(text) { return true }
            if let criteria = rule.criteria, criteria.lowercased().contains(text) { return true }
            if rule.target.lowercased().contains(text) { return true }
            return false
        }
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
                    .accessibilityLabel(AppLocalization.string("DNS configuration details"))
                    .accessibilityIdentifier("dns-page-content")
                }
            } else {
                FeatureEmptyState(
                    symbol: "network.badge.shield.half.filled",
                    title: AppLocalization.string("No DNS policy loaded"),
                    detail: AppLocalization.string("Import a validated profile to inspect its resolver behavior without exposing server addresses.")
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
                Text(AppLocalization.string("DNS & Fake-IP"))
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
                title: AppLocalization.string("Primary"),
                value: "\(dns.nameserverCount)",
                detail: AppLocalization.string("upstreams"),
                symbol: "server.rack",
                tint: .blue
            )
            DNSMetricCard(
                title: AppLocalization.string("Fallback"),
                value: "\(dns.fallbackCount)",
                detail: AppLocalization.string("resolvers"),
                symbol: "arrow.trianglehead.branch",
                tint: .indigo
            )
            DNSMetricCard(
                title: AppLocalization.string("Policies"),
                value: "\(dns.nameserverPolicyCount)",
                detail: AppLocalization.string("domain rules"),
                symbol: "list.bullet.indent",
                tint: .teal
            )
        }

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
                    tint: dns.allowsIPv6 ? .teal : .secondary
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
                    tint: dns.respectsRules ? .indigo : .secondary
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
            .featureCard()
        }

#if AETHERROUTE_INDEPENDENT
        tunRuntimePolicyContent(dns)
#endif

        FeatureSection(title: AppLocalization.string("Upstream privacy"), symbol: "lock.shield") {
            VStack(alignment: .leading, spacing: AetherVisual.s4) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Transport types"))
                            .font(.subheadline.weight(.semibold))
                        Text(AppLocalization.string("Server addresses stay hidden in this summary."))
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
                    Label(AppLocalization.string("No explicit upstream transport"), systemImage: "minus.circle")
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
                        DNSCountLabel(AppLocalization.string("Bootstrap"))
                        Text(verbatim: String(dns.defaultNameserverCount))
                            .monospacedDigit()
                        DNSCountLabel(AppLocalization.string("Proxy hostnames"))
                        Text(verbatim: String(dns.proxyNameserverCount))
                            .monospacedDigit()
                    }
                    GridRow {
                        DNSCountLabel(AppLocalization.string("Local listener"))
                        Text(
                            dns.hasListener
                                ? AppLocalization.string("Configured")
                                : AppLocalization.string("None")
                        )
                        DNSCountLabel(AppLocalization.string("EDNS subnet"))
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
            FeatureSection(title: AppLocalization.string("Fake-IP safeguards"), symbol: "wand.and.stars") {
                HStack(spacing: 0) {
                    DNSCompactFact(
                        title: AppLocalization.string("Address pool"),
                        value: dns.hasExplicitFakeIPRange
                            ? AppLocalization.string("Profile range")
                            : AppLocalization.string("Core default"),
                        symbol: "rectangle.3.group.bubble"
                    )
                    Divider().frame(height: 50)
                    DNSCompactFact(
                        title: AppLocalization.string("Bypass filters"),
                        value: "\(dns.fakeIPFilterCount)",
                        symbol: "line.3.horizontal.decrease.circle"
                    )
                    Divider().frame(height: 50)
                    DNSCompactFact(
                        title: AppLocalization.string("Fallback filter"),
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
            AppLocalization.string("This page is a privacy-safe view of the imported profile. The protocol core remains authoritative and validates DNS semantics when a session starts."),
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
                    tint: allowsIPv6 ? .teal : .secondary
                )
            }
            .featureCard()
        }
    }

    private func tunRuntimePolicyContent(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        FeatureSection(title: AppLocalization.string("TUN runtime overrides"), symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: AetherVisual.s3) {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Structured core policy"))
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
                    title: AppLocalization.string("Resolution mode"),
                    detail: AppLocalization.string("Choose Normal, Fake-IP, or Redir-host without rewriting imported YAML.")
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
                    title: AppLocalization.string("IPv6 answers"),
                    detail: AppLocalization.string("Override whether the resolver returns AAAA answers.")
                ) {
                    dnsBooleanPicker(
                        AppLocalization.string("IPv6 answers"),
                        selection: booleanBinding(\.ipv6),
                        identifier: "dns-runtime-ipv6"
                    )
                }

                Divider().padding(.leading, AetherVisual.s4)
                dnsPolicyRow(
                    title: AppLocalization.string("Rule-aware queries"),
                    detail: AppLocalization.string("Route upstream DNS queries through the rule engine.")
                ) {
                    dnsBooleanPicker(
                        AppLocalization.string("Rule-aware queries"),
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
        title: String,
        detail: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AetherVisual.s4) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        _ title: String,
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
            Label(AppLocalization.string("System resolver"), systemImage: "macbook.and.iphone")
                .font(.headline)
            Text(AppLocalization.string("The active profile has no DNS section. The core therefore uses the system resolver behavior available to the selected network engine."))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Label(
                AppLocalization.string("No resolver address or browsing-domain value is collected for this screen."),
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
    @State private var isHovered = false

    let title: String
    let value: String
    let detail: String
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
    @Environment(\.colorScheme) private var colorScheme

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
            .foregroundStyle(.secondary)
            .frame(minWidth: 110, alignment: .leading)
    }
}

private struct DNSCompactFact: View {
    let title: String
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
    let title: Text
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.symbol = symbol
        self.content = content()
    }

    init(title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Label {
                title
            } icon: {
                Image(systemName: symbol)
            }
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
    if bytes < 1024 {
        return "\(bytes) B/s"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB/s", kb).replacingOccurrences(of: ".0 ", with: " ")
    } else if bytes < 1024 * 1024 * 1024 {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB/s", mb).replacingOccurrences(of: ".0 ", with: " ")
    } else {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return String(format: "%.2f GB/s", gb)
    }
}

func formattedBytes(_ bytes: UInt64) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB", kb).replacingOccurrences(of: ".0 ", with: " ")
    } else if bytes < 1024 * 1024 * 1024 {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb).replacingOccurrences(of: ".0 ", with: " ")
    } else {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return String(format: "%.2f GB", gb)
    }
}

private struct RuleRow: View {
    let rule: RuleConfigurationSummary
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Text(verbatim: String(rule.order))
                .font(.body.monospacedDigit().weight(.semibold))
                .foregroundStyle(.primary)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.1), in: Circle())

            HStack(spacing: AetherVisual.sCompact) {
                Text(rule.kind)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, AetherVisual.sCompact)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(ruleKindColor(rule.kind).opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))

                if let criteria = rule.criteria {
                    Text(criteria)
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(criteria)
                } else {
                    Text(AppLocalization.string("Any remaining traffic"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.primary)
                }
            }

            Spacer(minLength: AetherVisual.s3)

            Image(systemName: "arrow.right")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            HStack(spacing: AetherVisual.s1) {
                if targetColor == .green {
                    Image(systemName: "arrow.forward")
                        .font(.system(size: 9.5, weight: .bold))
                        .accessibilityHidden(true)
                } else if targetColor == .red {
                    Image(systemName: "hand.raised.fill")
                        .font(.system(size: 9.5, weight: .bold))
                        .accessibilityHidden(true)
                } else {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9.5, weight: .bold))
                        .accessibilityHidden(true)
                }

                Text(rule.target)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, AetherVisual.s2)
            .padding(.vertical, AetherVisual.s1)
            .background(targetColor.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(targetColor.opacity(0.25), lineWidth: 0.5)
            }
            .lineLimit(1)
            .frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(.horizontal, AetherVisual.sRow)
        .padding(.vertical, AetherVisual.sCompact)
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .fill(isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.9) : Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(isHovered ? Color.accentColor.opacity(0.3) : Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var targetColor: Color {
        let upper = rule.target.uppercased()
        if upper == "DIRECT" { return .green }
        if upper == "REJECT" { return .red }
        return Color.accentColor
    }

    private func ruleKindColor(_ kind: String) -> Color {
        let upper = kind.uppercased()
        if upper.contains("DOMAIN") { return .blue }
        if upper.contains("IP") || upper.contains("CIDR") { return .orange }
        if upper.contains("GEO") { return .purple }
        if upper.contains("MATCH") { return .gray }
        return .cyan
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
    let title: String
    let detail: String

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

import AetherRouteKit
import SwiftUI

struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Group {
            if let profile = tunnel.activeProfile,
               let summary = tunnel.activeProfileSummary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        ProfileInspectionHeader(
                            profileName: profile.name,
                            itemCount: summary.proxyCount,
                            groupCount: summary.proxyGroupCount,
                            providerCount: summary.proxyProviderCount
                        )

                        if !summary.proxyGroups.isEmpty {
                            FeatureSection(title: "Proxy groups", symbol: "square.stack.3d.up") {
                                VStack(spacing: 12) {
                                    ForEach(summary.proxyGroups) { group in
                                        ProxyGroupCard(group: group)
                                    }
                                }
                            }
                        }

                        if !summary.proxies.isEmpty {
                            FeatureSection(title: "Endpoints", symbol: "server.rack") {
                                VStack(spacing: 12) {
                                    ForEach(summary.proxies) { proxy in
                                        ProxyCard(proxy: proxy)
                                    }
                                }
                            }
                        }

                        if !summary.proxyProviders.isEmpty {
                            FeatureSection(title: "Providers", symbol: "shippingbox") {
                                VStack(spacing: 0) {
                                    ForEach(summary.proxyProviders) { provider in
                                        ProviderRow(provider: provider)
                                        if provider.id != summary.proxyProviders.last?.id {
                                            Divider().padding(.leading, 44)
                                        }
                                    }
                                }
                                .featureCard()
                            }
                        }

                        if summary.proxyCount == 0,
                           summary.proxyGroupCount == 0,
                           summary.proxyProviderCount == 0 {
                            FeatureEmptyState(
                                symbol: "point.3.connected.trianglepath.dotted",
                                title: "No proxy definitions",
                                detail: "The active profile passed import checks but does not expose inline endpoints, groups, or providers."
                            )
                        }

                        TruncationNotice(
                            visibleCount: summary.proxies.count,
                            totalCount: summary.proxyCount
                        )
                        TruncationNotice(
                            visibleCount: summary.proxyGroups.count,
                            totalCount: summary.proxyGroupCount
                        )
                        TruncationNotice(
                            visibleCount: summary.proxyProviders.count,
                            totalCount: summary.proxyProviderCount
                        )
                    }
                    .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                    .padding(.top, AetherVisual.pageTopPadding)
                    .padding(.bottom, AetherVisual.pageBottomPadding)
                    .frame(maxWidth: AetherVisual.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Proxy configuration")
                    .accessibilityIdentifier("proxies-page-content")
                }
            } else {
                FeatureEmptyState(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: "No proxies yet",
                    detail: "Import a validated profile to inspect its endpoints and proxy groups."
                )
            }
        }
        .accessibilityIdentifier("proxies-page")
    }
}

struct ConnectionsView: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    sessionMetric.frame(width: 170)
                    modeMetric.frame(width: 170)
                    profileMetric
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Label("Current session", systemImage: "clock.arrow.circlepath")
                            .font(.headline)
                        Spacer()
                        StatePill(
                            title: tunnel.statusTitle,
                            color: sessionTint,
                            symbol: sessionSymbol
                        )
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 12) {
                        GridRow {
                            SessionLabel("Status")
                            Text(tunnel.statusDetail)
                                .gridColumnAlignment(.leading)
                        }
                        GridRow {
                            SessionLabel("Started")
                            if let connectedSince = tunnel.connectedSince {
                                Text(
                                    AppLocalization.date(
                                        connectedSince,
                                        date: .abbreviated,
                                        time: .standard
                                    )
                                )
                            } else {
                                Text("Not running").foregroundStyle(.secondary)
                            }
                        }
                        GridRow {
                            SessionLabel("Visibility")
                            Text("Live bounded telemetry")
                        }
                        GridRow {
                            SessionLabel("Runtime mode")
                            if let mode = tunnel.sessionRoutingMode {
                                Text(mode.localizedTitleKey)
                            } else {
                                Text("Not running").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .padding(20)
                .featureCard()

                HStack(spacing: 12) {
                    TelemetryMetric(
                        title: "Upload",
                        symbol: "arrow.up",
                        value: formattedRate(
                            tunnel.telemetry.uploadBytesPerSecond
                        ),
                        tint: .indigo,
                        accessibilityIdentifier: "connections-upload-title"
                    )
                    TelemetryMetric(
                        title: "Download",
                        symbol: "arrow.down",
                        value: formattedRate(
                            tunnel.telemetry.downloadBytesPerSecond
                        ),
                        tint: .teal,
                        accessibilityIdentifier: "connections-download-title"
                    )
                    TelemetryMetric(
                        title: "Open flows",
                        symbol: "arrow.left.arrow.right",
                        value: "\(tunnel.telemetry.connections.count)",
                        tint: .blue,
                        accessibilityIdentifier: "connections-open-flows-title"
                    )
                }

                if tunnel.telemetry.connections.isEmpty {
                    FeatureEmptyState(
                        symbol: tunnel.isEnabled
                            ? "checkmark.circle"
                            : "arrow.left.arrow.right",
                        title: "No active connections",
                        detail: tunnel.isEnabled
                            ? "The secure connection is ready. New flows will appear here without exposing source addresses or account identifiers."
                            : "Connect with an active profile to start a session. No connection data is fabricated while the secure connection is stopped."
                    )
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(
                                "Active connections",
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                            .font(.headline)
                            Spacer()
                            Text(
                                verbatim: String(
                                    tunnel.telemetry.connections.count
                                )
                                )
                                .font(.subheadline.monospacedDigit().weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                        ForEach(
                            Array(tunnel.telemetry.connections.enumerated()),
                            id: \.offset
                        ) { _, connection in
                            ConnectionTelemetryRow(connection: connection)
                        }
                    }
                    .padding(20)
                    .featureCard()
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("connections-page")
    }

    private var sessionMetric: some View {
        SessionMetric(
            label: "Session",
            value: sessionValue,
            symbol: sessionSymbol,
            tint: sessionTint
        )
    }

    private var modeMetric: some View {
        SessionMetric(
            label: "Selected mode",
            value: tunnel.routingMode.localizedTitle,
            symbol: "arrow.triangle.branch",
            tint: .blue
        )
    }

    private var profileMetric: some View {
        SessionMetric(
            label: "Profile",
            value: tunnel.activeProfile?.name ?? AppLocalization.string("None"),
            symbol: "doc.badge.gearshape",
            tint: .indigo
        )
    }

    private var sessionValue: String {
        switch tunnel.state {
        case .privacyConsentRequired: AppLocalization.string("Privacy")
        case .loading: AppLocalization.string("Preparing")
        case .disconnected: AppLocalization.string("Stopped")
        case .connecting: AppLocalization.string("Starting")
        case .connected: AppLocalization.string("Active")
        case .disconnecting: AppLocalization.string("Stopping")
        case .failed: AppLocalization.string("Unavailable")
        }
    }

    private var sessionSymbol: String {
        switch tunnel.state {
        case .connected: "checkmark.circle.fill"
        case .connecting, .disconnecting, .loading: "circle.dotted"
        case .failed: "exclamationmark.triangle.fill"
        case .privacyConsentRequired: "hand.raised.fill"
        case .disconnected: "pause.circle"
        }
    }

    private var sessionTint: Color {
        switch tunnel.state {
        case .connected: .teal
        case .connecting, .disconnecting, .loading: .orange
        case .failed: .red
        case .privacyConsentRequired: .orange
        case .disconnected: .secondary
        }
    }
}

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 18) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.indigo.opacity(0.10))
                                Image(systemName: "list.number")
                                    .font(.system(size: 25, weight: .medium))
                                    .foregroundStyle(.indigo)
                            }
                            .frame(width: 58, height: 58)
                            .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Ordered routing policy")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.primary)
                                Text("Rules are evaluated from top to bottom by the protocol core.")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 5) {
                                Text(verbatim: String(summary.ruleCount))
                                    .font(.title2.weight(.semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(.primary)
                                Text("explicit rules")
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                            }
                            Divider()
                                .frame(height: 34)
                                .accessibilityHidden(true)
                            StatePill(
                                title: String.localizedStringWithFormat(
                                    AppLocalization.string("Selected: %@"),
                                    tunnel.routingMode.localizedTitle
                                ),
                                color: .indigo,
                                symbol: "arrow.triangle.branch"
                            )
                        }
                        .padding(20)
                        .featureCard()
                        .accessibilityElement(children: .contain)
                        .accessibilityAddTraits(.isStaticText)

                        if !summary.ruleProviders.isEmpty {
                            FeatureSection(title: "Rule providers", symbol: "shippingbox") {
                                VStack(spacing: 0) {
                                    ForEach(summary.ruleProviders) { provider in
                                        ProviderRow(provider: provider)
                                        if provider.id != summary.ruleProviders.last?.id {
                                            Divider().padding(.leading, 44)
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
                            VStack(alignment: .leading, spacing: 12) {
                                Label("Evaluation order", systemImage: "arrow.down")
                                    .font(.title3.weight(.bold))
                                VStack(spacing: 10) {
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
                    LazyVStack(alignment: .leading, spacing: 18) {
                        header(summary.dns)
                        if summary.dns.isPresent {
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
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(headerColor(dns).opacity(0.10))
                Image(systemName: headerSymbol(dns))
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(headerColor(dns))
            }
            .frame(width: 58, height: 58)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
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
        .padding(20)
        .featureCard()
    }

    @ViewBuilder
    private func configuredContent(_ dns: DNSConfigurationSummary) -> some View {
        HStack(spacing: 12) {
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
                Divider().padding(.leading, 55)
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
                Divider().padding(.leading, 55)
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
                Divider().padding(.leading, 55)
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
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
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
                    HStack(spacing: 8) {
                        ForEach(dns.upstreamTransports, id: \.self) { transport in
                            Label(
                                transportTitle(transport),
                                systemImage: transportSymbol(transport)
                            )
                            .font(.caption.weight(.medium))
                            .foregroundStyle(transportColor(transport))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
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
            .padding(18)
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
                .padding(.vertical, 8)
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
        .padding(.horizontal, 2)
    }

#if AETHERROUTE_INDEPENDENT
    private func tunRuntimePolicyContent(
        _ dns: DNSConfigurationSummary
    ) -> some View {
        FeatureSection(title: "TUN runtime overrides", symbol: "slider.horizontal.3") {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
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
                .padding(16)

                Divider().padding(.leading, 16)
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

                Divider().padding(.leading, 16)
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

                Divider().padding(.leading, 16)
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
                    Divider().padding(.leading, 16)
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
                    .padding(16)
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
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
            }
            Spacer(minLength: 16)
            control()
                .disabled(
                    tunnel.networkEngineMode != .tun
                        || !tunnel.canModifyDNSRuntimePolicy
                )
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
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

    private var systemResolverContent: some View {
        VStack(alignment: .leading, spacing: 15) {
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
            .foregroundStyle(.teal)
        }
        .padding(20)
        .featureCard()
    }

    private func headerColor(_ dns: DNSConfigurationSummary) -> Color {
        guard dns.isPresent else { return .secondary }
        return dns.isEnabled ? modeColor(dns.mode) : .orange
    }

    private func headerSymbol(_ dns: DNSConfigurationSummary) -> String {
        guard dns.isPresent else { return "macbook.and.iphone" }
        return dns.isEnabled ? modeSymbol(dns.mode) : "pause.circle.fill"
    }

    private func statusTitle(_ dns: DNSConfigurationSummary) -> String {
        guard dns.isPresent else { return AppLocalization.string("System resolver") }
        return dns.isEnabled
            ? AppLocalization.string("Profile DNS on")
            : AppLocalization.string("Profile DNS off")
    }

    private func headerDetail(_ dns: DNSConfigurationSummary) -> LocalizedStringKey {
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(width: 32, height: 32)
                    .background(
                        tint.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(value)
                    .font(.title3.monospacedDigit().weight(.semibold))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                Text(detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(16)
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
        HStack(spacing: 13) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
            }
            Spacer(minLength: 14)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(tint.opacity(0.09), in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
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
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
        .accessibilityElement(children: .combine)
    }
}

private struct ProfileInspectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let profileName: String
    let itemCount: Int
    let groupCount: Int
    let providerCount: Int

    var body: some View {
        HStack(spacing: 18) {
            ZStack {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.teal.opacity(0.10))
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(.teal)
                    .accessibilityHidden(true)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 5) {
                Text(profileName)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .lineLimit(1)
                    .help(profileName)
                Text("Import safety checks passed. The core validates protocol semantics when a session starts.")
                    .font(.body.weight(.medium))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            CountBadge(value: itemCount, label: "Endpoints")
            CountBadge(value: groupCount, label: "Groups")
            if providerCount > 0 {
                CountBadge(value: providerCount, label: "Providers")
            }
        }
        .padding(20)
        .featureCard()
    }
}

private struct CountBadge: View {
    @Environment(\.colorScheme) private var colorScheme

    let value: Int
    let label: LocalizedStringKey

    var body: some View {
        VStack(spacing: 3) {
            Text(verbatim: String(value))
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(primaryTextColor)
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(primaryTextColor)
        }
        .frame(minWidth: 52)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            colorScheme == .dark ? Color.black : Color.white,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }
}

private struct FeatureSection<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: symbol)
                .font(.headline)
            content
        }
    }
}

private struct ProxyGroupCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.colorScheme) private var colorScheme
    @State private var isPresentingMembers = false
    let group: ProxyGroupConfigurationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 13) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(.blue)
                    .frame(width: 34, height: 34)
                    .background(
                        Color.blue.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: 9)
                )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(group.name)
                        .fontWeight(.medium)
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                    Text(
                        String.localizedStringWithFormat(
                            AppLocalization.string("%@ · %lld members"),
                            group.strategy,
                            Int64(group.memberCount)
                        )
                    )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if isManuallySelectable {
                    Text("Manual")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(primaryTextColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            colorScheme == .dark ? Color.black : Color.white,
                            in: Capsule()
                        )
                        .overlay {
                            Capsule()
                                .stroke(Color.blue.opacity(0.68), lineWidth: 0.75)
                        }
                } else {
                    Text(group.strategy.uppercased())
                        .font(.caption2.monospaced())
                        .foregroundStyle(primaryTextColor)
                }
            }
            .accessibilityElement(children: .contain)

            if isManuallySelectable {
                selectionControl
            }

            latencyControl

            if let message = tunnel.proxySelectionMessages[group.name] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(15)
        .featureCard()
        .help(group.name)
        .task(id: tunnel.isConnected) {
            guard isManuallySelectable, tunnel.isConnected else { return }
            await tunnel.refreshProxySelection(group: group.name)
        }
    }

    @ViewBuilder
    private var selectionControl: some View {
        if !tunnel.isConnected {
            selectionShell(
                title: AppLocalization.string("Connect to choose"),
                symbol: "circle.dashed",
                color: .secondary
            )
        } else if tunnel.proxySelectionRequests.contains(group.name) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Loading proxy choices")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
            .accessibilityElement(children: .combine)
        } else if let snapshot = tunnel.proxySelections[group.name] {
            Button {
                isPresentingMembers = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.teal)
                    Text(snapshot.selectedMember ?? AppLocalization.string("No selection"))
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
                .background(Color.blue.opacity(0.065), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("Selected proxy")
            .accessibilityValue(
                snapshot.selectedMember ?? AppLocalization.string("No selection")
            )
            .popover(isPresented: $isPresentingMembers, arrowEdge: .trailing) {
                memberChoices(snapshot)
            }
        } else {
            Button {
                Task {
                    await tunnel.refreshProxySelection(group: group.name)
                }
            } label: {
                selectionShell(
                    title: AppLocalization.string("Load choices"),
                    symbol: "arrow.clockwise",
                    color: .blue
                )
            }
            .buttonStyle(.plain)
        }
    }

    private var latencyControl: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Button {
                    Task { await tunnel.testProxyLatency(group: group.name) }
                } label: {
                    HStack(spacing: 7) {
                        if tunnel.proxyLatencyRequests.contains(group.name) {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "speedometer")
                        }
                        Text(
                            tunnel.proxyLatencyRequests.contains(group.name)
                                ? AppLocalization.string("Testing latency…")
                                : AppLocalization.string("Test latency")
                        )
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(
                    !tunnel.isConnected
                        || tunnel.proxyLatencyRequests.contains(group.name)
                )

                Spacer(minLength: 8)

                if let best = bestLatency {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(latencyColor(best))
                            .accessibilityHidden(true)
                        Text(
                            String.localizedStringWithFormat(
                                AppLocalization.string("Best %lld ms"),
                                Int64(best)
                            )
                        )
                        .foregroundStyle(primaryTextColor)
                    }
                    .font(.subheadline.weight(.semibold))
                } else if tunnel.proxyLatencies[group.name] != nil {
                    Text("No response")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(primaryTextColor)
                }
            }

            if let results = tunnel.proxyLatencies[group.name]?.results,
               !results.isEmpty {
                HStack(spacing: 7) {
                    ForEach(Array(results.prefix(3)), id: \.member) { result in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(
                                    result.delayMilliseconds.map(latencyColor)
                                        ?? Color.secondary.opacity(0.5)
                                )
                                .frame(width: 5, height: 5)
                            Text(result.member)
                                .foregroundStyle(primaryTextColor)
                                .lineLimit(1)
                            Text(latencyText(result.delayMilliseconds))
                                .foregroundStyle(primaryTextColor)
                        }
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .frame(height: 25)
                        .background(
                            Color.secondary.opacity(0.055),
                            in: Capsule()
                        )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            Color.secondary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var bestLatency: UInt32? {
        tunnel.proxyLatencies[group.name]?.results
            .compactMap(\.delayMilliseconds)
            .min()
    }

    private func memberChoices(_ snapshot: ProxySelectionState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.name)
                .font(.headline)
                .padding(.horizontal, 10)
                .padding(.top, 6)

            Divider()

            ForEach(snapshot.members, id: \.self) { member in
                Button {
                    isPresentingMembers = false
                    Task {
                        await tunnel.selectProxy(
                            group: group.name,
                            member: member
                        )
                    }
                } label: {
                    HStack {
                        Text(menuTitle(for: member))
                        Spacer()
                        if member == snapshot.selectedMember {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .frame(height: 30)
            }
        }
        .padding(8)
        .frame(width: 260)
    }

    private func menuTitle(for member: String) -> String {
        guard let delay = tunnel.proxyLatencies[group.name]?.results
            .first(where: { $0.member == member })?.delayMilliseconds else {
            return member
        }
        return "\(member) · \(latencyText(delay))"
    }

    private func latencyText(_ delay: UInt32?) -> String {
        guard let delay else { return AppLocalization.string("Timeout") }
        return String.localizedStringWithFormat(
            AppLocalization.string("%lld ms"),
            Int64(delay)
        )
    }

    private func latencyColor(_ delay: UInt32) -> Color {
        switch delay {
        case ...120: .green
        case ...260: .orange
        default: .red
        }
    }

    private func selectionShell(
        title: String,
        symbol: String,
        color: Color
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(color)
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
        .background(Color.secondary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
    }

    private var isManuallySelectable: Bool {
        group.strategy.lowercased() == "select"
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }
}

private struct ProxyCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let proxy: ProxyConfigurationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundStyle(statusColor)
                    .accessibilityHidden(true)
                Spacer()
                Text(statusTitle)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(primaryTextColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        colorScheme == .dark ? Color.black : Color.white,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule()
                            .stroke(statusColor.opacity(0.72), lineWidth: 0.75)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(proxy.name)
                    .fontWeight(.medium)
                    .foregroundStyle(primaryTextColor)
                    .lineLimit(1)
                Text(proxy.protocolName.uppercased())
                    .font(.caption.monospaced().weight(.medium))
                    .foregroundStyle(primaryTextColor)
            }
        }
        .padding(15)
        .featureCard()
        .help(proxy.name)
        .accessibilityElement(children: .contain)
    }

    private var statusTitle: String {
        switch proxy.recognition {
        case .recognized: AppLocalization.string("Recognized")
        case .requiresCoreValidation: AppLocalization.string("Core check")
        case .incomplete: AppLocalization.string("Incomplete")
        }
    }

    private var statusColor: Color {
        switch proxy.recognition {
        case .recognized: .teal
        case .requiresCoreValidation: .orange
        case .incomplete: .red
        }
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }
}

private struct ProviderRow: View {
    let provider: ProviderConfigurationSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(.indigo)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(provider.name).fontWeight(.medium)
                Text(provider.sourceType.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

private struct SessionMetric: View {
    @Environment(\.colorScheme) private var colorScheme

    let label: LocalizedStringKey
    let value: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                Text(value)
                    .fontWeight(.medium)
                    .foregroundStyle(
                        colorScheme == .dark ? Color.white : Color.black
                    )
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(15)
        .frame(maxWidth: .infinity)
        .featureCard()
        .accessibilityElement(children: .contain)
    }
}

private struct SessionLabel: View {
    let value: LocalizedStringKey

    init(_ value: LocalizedStringKey) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color(nsColor: .labelColor))
            .frame(width: 94, alignment: .leading)
    }
}

private struct TelemetryMetric: View {
    let title: LocalizedStringKey
    let symbol: String
    let value: String
    let tint: Color
    let accessibilityIdentifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .accessibilityHidden(true)
                Text(title)
                    .accessibilityIdentifier(accessibilityIdentifier)
            }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color(nsColor: .labelColor))
            Text(value)
                .font(.title3.monospacedDigit().weight(.medium))
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(17)
        .featureCard()
        // Keep the metric name and value as distinct semantic children. A
        // combined card is announced as one long phrase and also prevents
        // macOS from evaluating each text run against its real background.
        .accessibilityElement(children: .contain)
    }
}

private struct ConnectionTelemetryRow: View {
    let connection: ConnectionTelemetry

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: connection.transport == .tcp ? "arrow.left.arrow.right" : "dot.radiowaves.left.and.right")
                .font(.body.weight(.medium))
                .foregroundStyle(connection.transport == .tcp ? .blue : .teal)
                .frame(width: 34, height: 34)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text(
                    verbatim: "\(connection.destination):\(connection.destinationPort)"
                )
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 8) {
                    Text(connection.transport == .tcp ? "TCP" : "UDP")
                    if !connection.rule.isEmpty {
                        Text(connection.rulePayload.isEmpty
                            ? connection.rule
                            : "\(connection.rule) · \(connection.rulePayload)")
                    }
                    if !connection.proxyChain.isEmpty {
                        Text(connection.proxyChain)
                    }
                }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color(nsColor: .labelColor))
                .lineLimit(1)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 4) {
                Label(
                    formattedBytes(connection.downloadTotal),
                    systemImage: "arrow.down"
                )
                Label(
                    formattedBytes(connection.uploadTotal),
                    systemImage: "arrow.up"
                )
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Color(nsColor: .labelColor))
        }
        .padding(.vertical, 10)
        // Destination, route decision and byte counters are independently
        // useful to VoiceOver. Keeping them as children also avoids treating
        // the decorative transport tile as part of one giant text element.
        .accessibilityElement(children: .contain)
    }
}

private func formattedRate(_ bytes: UInt64) -> String {
    "\(formattedBytes(bytes))/s"
}

private func formattedBytes(_ bytes: UInt64) -> String {
    ByteCountFormatter.string(
        fromByteCount: Int64(clamping: bytes),
        countStyle: .file
    )
}

private struct RuleRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let rule: RuleConfigurationSummary

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: String(rule.order))
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(primaryTextColor)
                .frame(width: 30, height: 30)
                .background(Color.secondary.opacity(0.08), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(rule.kind)
                    .font(.subheadline.monospaced().weight(.medium))
                if let criteria = rule.criteria {
                    Text(criteria)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(primaryTextColor)
                        .lineLimit(2)
                } else {
                    Text("Any remaining traffic")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(primaryTextColor)
                }
            }
            Spacer(minLength: 14)
            Image(systemName: "arrow.right")
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
            Text(rule.target)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(primaryTextColor)
                .lineLimit(1)
                .frame(maxWidth: 180, alignment: .trailing)
        }
        .padding(15)
        .featureCard()
        .accessibilityElement(children: .contain)
    }

    private var primaryTextColor: Color {
        colorScheme == .dark ? .white : .black
    }
}

private struct StatePill: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(
                    colorScheme == .dark ? Color.white : Color.black
                )
        }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                colorScheme == .dark ? Color.black : Color.white,
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(color.opacity(0.52), lineWidth: 0.75)
            }
    }
}

private struct FeatureEmptyState: View {
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
        .aetherPanel(radius: 18)
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

private extension View {
    func featureCard() -> some View {
        aetherPanel(radius: 15)
    }
}

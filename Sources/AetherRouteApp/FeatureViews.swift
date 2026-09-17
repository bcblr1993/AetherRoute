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

    var icon: String {
        switch self {
        case .all: "list.bullet"
        case .domain: "globe"
        case .ip: "network"
        case .geo: "map"
        case .match: "asterisk"
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

enum RuleActionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case direct = "Direct"
    case proxy = "Proxy"
    case reject = "Reject"

    var id: String { rawValue }

    var localizedTitle: String {
        switch self {
        case .all: AppLocalization.string("All Actions")
        case .direct: AppLocalization.string("Direct")
        case .proxy: AppLocalization.string("Proxy")
        case .reject: AppLocalization.string("Reject")
        }
    }

    func accepts(_ target: String) -> Bool {
        let upper = target.uppercased()
        switch self {
        case .all: return true
        case .direct: return upper == "DIRECT"
        case .reject: return upper == "REJECT"
        case .proxy: return upper != "DIRECT" && upper != "REJECT"
        }
    }
}

/// 路由策略出口比例分布条
struct RuleDistributionBar: View {
    let directCount: Int
    let proxyCount: Int
    let rejectCount: Int
    let totalCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            GeometryReader { proxy in
                let total = max(totalCount, 1)
                let directWidth = proxy.size.width * CGFloat(directCount) / CGFloat(total)
                let proxyWidth = proxy.size.width * CGFloat(proxyCount) / CGFloat(total)
                let rejectWidth = proxy.size.width * CGFloat(rejectCount) / CGFloat(total)

                HStack(spacing: 2) {
                    if directCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.green)
                            .frame(width: max(directWidth - 1, 4))
                    }
                    if proxyCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.indigo)
                            .frame(width: max(proxyWidth - 1, 4))
                    }
                    if rejectCount > 0 {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color.red)
                            .frame(width: max(rejectWidth - 1, 4))
                    }
                }
            }
            .frame(height: 6)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 3, style: .continuous))

            HStack(spacing: AetherVisual.s4) {
                HStack(spacing: AetherVisual.s1) {
                    Circle().fill(Color.green).frame(width: 6.5, height: 6.5)
                    Text(String.localizedStringWithFormat(AppLocalization.string("Direct: %lld"), Int64(directCount)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: AetherVisual.s1) {
                    Circle().fill(Color.indigo).frame(width: 6.5, height: 6.5)
                    Text(String.localizedStringWithFormat(AppLocalization.string("Proxy: %lld"), Int64(proxyCount)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if rejectCount > 0 {
                    HStack(spacing: AetherVisual.s1) {
                        Circle().fill(Color.red).frame(width: 6.5, height: 6.5)
                        Text(String.localizedStringWithFormat(AppLocalization.string("Reject: %lld"), Int64(rejectCount)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()
            }
        }
    }
}

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var searchText = ""
    @State private var selectedFilter: RuleKindFilter = .all
    @State private var selectedAction: RuleActionFilter = .all
    @State private var showSimulator: Bool = false
    @State private var testQuery: String = ""
    @State private var testResult: RouteMatchResult? = nil
    @State private var hasAttemptedMatch: Bool = false
    @State private var matchExplanation = ""
    @State private var highlightedRuleID: Int? = nil

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                let displayedRules = filteredRules(from: summary.rules)
                let directCount = summary.rules.filter { $0.target.uppercased() == "DIRECT" }.count
                let rejectCount = summary.rules.filter { $0.target.uppercased() == "REJECT" }.count
                let proxyCount = max(0, summary.rules.count - directCount - rejectCount)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AetherVisual.s4) {
                            // 1. 现代化路由策略 Hero 仪表盘
                            VStack(alignment: .leading, spacing: AetherVisual.s4) {
                                HStack(alignment: .center, spacing: AetherVisual.s4) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.indigo.opacity(0.22), Color.accentColor.opacity(0.08)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .overlay {
                                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                                    .stroke(Color.indigo.opacity(0.35), lineWidth: 0.75)
                                            }
                                        Image(systemName: "point.filled.topleft.down.curvedto.point.bottomright.up")
                                            .font(.system(size: 24, weight: .semibold))
                                            .foregroundStyle(Color.indigo)
                                    }
                                    .frame(width: 50, height: 50)
                                    .accessibilityHidden(true)

                                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                        HStack(spacing: AetherVisual.s2) {
                                            Text(AppLocalization.string("Ordered routing policy"))
                                                .font(.title3.weight(.bold))
                                                .foregroundStyle(.primary)

                                            Text(verbatim: "\(summary.ruleCount)")
                                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                                .foregroundStyle(Color.indigo)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.indigo.opacity(0.12), in: Capsule())
                                        }

                                        Text(AppLocalization.string("Rules are evaluated from top to bottom by the protocol core."))
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(.secondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    HStack(spacing: AetherVisual.s2) {
                                        Button {
                                            withAnimation(AetherVisual.panelSpring) {
                                                showSimulator.toggle()
                                            }
                                        } label: {
                                            Label(
                                                showSimulator ? AppLocalization.string("Hide Test") : AppLocalization.string("Test Route"),
                                                systemImage: showSimulator ? "chevron.up.circle.fill" : "bolt.badge.clock.fill"
                                            )
                                            .font(.system(size: 12, weight: .semibold))
                                            .padding(.horizontal, AetherVisual.s3)
                                            .padding(.vertical, AetherVisual.s2)
                                            .foregroundStyle(showSimulator ? Color.white : Color.accentColor)
                                            .background(
                                                showSimulator ? Color.accentColor : Color.accentColor.opacity(0.12),
                                                in: Capsule()
                                            )
                                            .overlay {
                                                Capsule().stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
                                            }
                                        }
                                        .buttonStyle(.plain)

                                        StatePill(
                                            title: String.localizedStringWithFormat(
                                                AppLocalization.string("Selected: %@"),
                                                tunnel.routingMode.localizedTitle
                                            ),
                                            color: .indigo,
                                            symbol: tunnel.routingMode.symbol
                                        )
                                    }
                                }

                                Divider().opacity(0.6)

                                // 策略分布比例条
                                RuleDistributionBar(
                                    directCount: directCount,
                                    proxyCount: proxyCount,
                                    rejectCount: rejectCount,
                                    totalCount: summary.rules.count
                                )
                            }
                            .padding(AetherVisual.s5)
                            .featureCard()
                            .accessibilityElement(children: .contain)

                            // 2. 路由匹配测试抽屉 (Simulator)
                            if showSimulator {
                                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                                    HStack {
                                        Label(AppLocalization.string("Route Match Simulator"), systemImage: "sparkles")
                                            .font(.headline.weight(.bold))
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Text(AppLocalization.string("Instant dry-run against active rules"))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }

                                    HStack(spacing: AetherVisual.s2) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(.secondary)
                                            .padding(.leading, 4)

                                        TextField(
                                            AppLocalization.string("Enter a domain (e.g. github.com) or IP (e.g. 192.168.1.1)…"),
                                            text: $testQuery
                                        )
                                        .textFieldStyle(.plain)
                                        .font(.system(size: 12.5, design: .monospaced))
                                        .onSubmit {
                                            performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                                        }

                                        if !testQuery.isEmpty {
                                            Button {
                                                testQuery = ""
                                                testResult = nil
                                                hasAttemptedMatch = false
                                            } label: {
                                                Image(systemName: "xmark.circle.fill")
                                                    .foregroundStyle(.secondary)
                                            }
                                            .buttonStyle(.plain)
                                        }

                                        Button(AppLocalization.string("Test")) {
                                            performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                        .disabled(testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                    }
                                    .padding(.horizontal, AetherVisual.s3)
                                    .padding(.vertical, 7)
                                    .background(
                                        Color(nsColor: .controlBackgroundColor).opacity(0.8),
                                        in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                                    )
                                    .overlay {
                                        RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                                            .stroke(Color.accentColor.opacity(0.4), lineWidth: 0.5)
                                    }

                                    if let result = testResult {
                                        HStack(spacing: AetherVisual.s3) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.system(size: 20))
                                                .foregroundStyle(Color.green)

                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack(spacing: AetherVisual.s2) {
                                                    Text(String.localizedStringWithFormat(AppLocalization.string("Matched Rule #%lld"), Int64(result.order)))
                                                        .font(.system(size: 12.5, weight: .bold))

                                                    Text(result.matchedRule.kind)
                                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                        .padding(.horizontal, 5)
                                                        .padding(.vertical, 1.5)
                                                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))

                                                    Image(systemName: "arrow.right")
                                                        .font(.caption2)
                                                        .foregroundStyle(.secondary)

                                                    TargetPillView(target: result.target)
                                                }

                                                Text(AppLocalization.string("Destination-only preview; the target may be a policy group."))
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }

                                            Spacer()

                                            Button {
                                                withAnimation(AetherVisual.panelSpring) {
                                                    highlightedRuleID = result.matchedRule.id
                                                    scrollProxy.scrollTo(result.matchedRule.id, anchor: .center)
                                                }
                                            } label: {
                                                Label(AppLocalization.string("Locate"), systemImage: "scope")
                                                    .font(.system(size: 11, weight: .semibold))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        .padding(AetherVisual.s3)
                                        .background(Color.green.opacity(0.08), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                                        .overlay {
                                            RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                                                .stroke(Color.green.opacity(0.25), lineWidth: 0.5)
                                        }
                                    } else if hasAttemptedMatch && !testQuery.isEmpty {
                                        HStack(spacing: AetherVisual.s2) {
                                            Image(systemName: "exclamationmark.triangle")
                                                .foregroundStyle(.orange)
                                            Text(matchExplanation)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        .padding(AetherVisual.s3)
                                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                                    }
                                }
                                .padding(AetherVisual.s4)
                                .featureCard()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // 3. 规则集 Rule providers
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

                            // 4. 现代化多维过滤与搜索工具栏
                            if !summary.rules.isEmpty {
                                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                                    // 第一行：即时搜索框 + 策略动作过滤菜单
                                    HStack(spacing: AetherVisual.s3) {
                                        HStack(spacing: AetherVisual.s2) {
                                            Image(systemName: "magnifyingglass")
                                                .foregroundStyle(.secondary)
                                            TextField(AppLocalization.string("Filter criteria, targets, or kinds…"), text: $searchText)
                                                .textFieldStyle(.plain)
                                            if !searchText.isEmpty {
                                                Button {
                                                    searchText = ""
                                                } label: {
                                                    Image(systemName: "xmark.circle.fill")
                                                        .foregroundStyle(.secondary)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(.horizontal, AetherVisual.s3)
                                        .padding(.vertical, 6)
                                        .background(
                                            Color(nsColor: .controlBackgroundColor).opacity(0.8),
                                            in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                                                .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 0.5)
                                        }

                                        // 动作筛选菜单
                                        Menu {
                                            ForEach(RuleActionFilter.allCases) { action in
                                                Button {
                                                    selectedAction = action
                                                } label: {
                                                    HStack {
                                                        Text(action.localizedTitle)
                                                        if selectedAction == action {
                                                            Image(systemName: "checkmark")
                                                        }
                                                    }
                                                }
                                            }
                                        } label: {
                                            HStack(spacing: 5) {
                                                Image(systemName: "line.3.horizontal.decrease.circle")
                                                Text(selectedAction.localizedTitle)
                                            }
                                            .font(.system(size: 12, weight: .medium))
                                        }
                                        .menuStyle(.borderedButton)
                                        .fixedSize()
                                    }

                                    // 第二行：规则种类分段标签 + 计数提示
                                    HStack(spacing: AetherVisual.s2) {
                                        HStack(spacing: 4) {
                                            ForEach(RuleKindFilter.allCases) { filter in
                                                let isSelected = selectedFilter == filter
                                                let count = summary.rules.filter { filter.accepts($0.kind) }.count
                                                Button {
                                                    withAnimation(AetherVisual.quickFade) {
                                                        selectedFilter = filter
                                                    }
                                                } label: {
                                                    HStack(spacing: 4) {
                                                        Image(systemName: filter.icon)
                                                            .font(.system(size: 10))
                                                        Text(filter.localizedTitle)
                                                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                                        Text(verbatim: "\(count)")
                                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                            .padding(.horizontal, 4)
                                                            .padding(.vertical, 1)
                                                            .background(
                                                                isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                                                in: Capsule()
                                                            )
                                                    }
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                                                    .background(
                                                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                                                        in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                                                    )
                                                    .contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                            }
                                        }
                                        .padding(3)
                                        .background(
                                            Color(nsColor: .controlBackgroundColor).opacity(0.5),
                                            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                                .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                                        }

                                        Spacer()

                                        Text(
                                            String.localizedStringWithFormat(
                                                AppLocalization.string("Showing %lld of %lld items."),
                                                Int64(displayedRules.count),
                                                Int64(summary.rules.count)
                                            )
                                        )
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                    }

                                    HStack(spacing: AetherVisual.s1) {
                                        Label(AppLocalization.string("Evaluation order (top to bottom)"), systemImage: "arrow.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                    }
                                    .padding(.top, 2)
                                }
                            }

                            // 5. 规则列表
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
                                        RuleRow(
                                            rule: rule,
                                            isHighlighted: highlightedRuleID == rule.id,
                                            onTest: { destination in
                                                testQuery = destination
                                                showSimulator = true
                                                performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                                            }
                                        )
                                        .id(rule.id)
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
                }
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

    private func performMatch(rules: [RuleConfigurationSummary], totalRuleCount: Int) {
        hasAttemptedMatch = true
        testResult = nil
        switch RouteMatchEngine.assess(destination: testQuery, against: rules, totalRuleCount: totalRuleCount) {
        case let .matched(result): testResult = result
        case .indeterminate:
            matchExplanation = AppLocalization.string("Cannot determine the route: runtime data or rules outside this preview are required.")
        case .noMatch:
            matchExplanation = AppLocalization.string("No preview rule matched. The runtime routing mode remains authoritative.")
        case .invalidDestination:
            matchExplanation = AppLocalization.string("Enter a valid domain, IP address, or URL.")
        }
    }

    private func filteredRules(from rules: [RuleConfigurationSummary]) -> [RuleConfigurationSummary] {
        rules.filter { rule in
            guard selectedFilter.accepts(rule.kind) else { return false }
            guard selectedAction.accepts(rule.target) else { return false }
            if searchText.isEmpty { return true }
            let text = searchText.lowercased()
            if rule.kind.lowercased().contains(text) { return true }
            if let criteria = rule.criteria, criteria.lowercased().contains(text) { return true }
            if rule.target.lowercased().contains(text) { return true }
            if String(rule.order) == text { return true }
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

#if AETHERROUTE_INDEPENDENT
        tunRuntimePolicyContent(dns)
#else
        resolutionBehaviorSection(dns)
#endif

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

        Label(
            AppLocalization.string("This page is a privacy-safe view of the imported profile. The protocol core remains authoritative and validates DNS semantics when a session starts."),
            systemImage: "info.circle"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
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
                            .foregroundStyle(.secondary)
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
            .featureCard()
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
                        .foregroundStyle(.secondary)
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
                    .foregroundStyle(Color.indigo)
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.vertical, AetherVisual.s2)
                    .background(
                        Color.indigo.opacity(0.09),
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
            .featureCard()
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
                    symbol: modeSymbol(dns.mode),
                    tint: modeColor(dns.mode),
                    title: AppLocalization.string("Resolution mode"),
                    detail: modeDetail(dns.mode)
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
                    symbol: "6.circle",
                    tint: dns.allowsIPv6 ? .teal : .secondary,
                    title: AppLocalization.string("IPv6 answers"),
                    detail: dns.allowsIPv6
                        ? AppLocalization.string("AAAA responses are allowed by this profile.")
                        : AppLocalization.string("AAAA responses are filtered by this profile.")
                ) {
                    dnsBooleanPicker(
                        AppLocalization.string("IPv6 answers"),
                        selection: booleanBinding(\.ipv6),
                        identifier: "dns-runtime-ipv6"
                    )
                }

                Divider().padding(.leading, AetherVisual.s4)
                dnsPolicyRow(
                    symbol: "arrow.triangle.branch",
                    tint: dns.respectsRules ? .indigo : .secondary,
                    title: AppLocalization.string("Rule-aware queries"),
                    detail: dns.respectsRules
                        ? AppLocalization.string("Upstream queries follow the routing rule engine.")
                        : AppLocalization.string("Upstream queries use the core's direct DNS path.")
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
                    detail: dns.usesHosts
                        ? AppLocalization.string("Profile hosts entries participate in resolution.")
                        : AppLocalization.string("Profile hosts entries are ignored for DNS."),
                    canDisable: false
                ) {
                    Text(
                        dns.usesHosts
                            ? AppLocalization.string("On")
                            : AppLocalization.string("Off")
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(dns.usesHosts ? Color.blue : Color.secondary)
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.vertical, AetherVisual.s1)
                    .background(
                        (dns.usesHosts ? Color.blue : Color.secondary).opacity(0.12),
                        in: Capsule()
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
        symbol: String,
        tint: Color,
        title: String,
        detail: String,
        canDisable: Bool = true,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
                .frame(width: 34, height: 34)
                .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
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
            .frame(minWidth: 80, alignment: .leading)
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

struct TargetPillView: View {
    let target: String
    var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)

            Text(target)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, 8)
        .padding(.vertical, 3.5)
        .background(pillColor.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(pillColor.opacity(0.28), lineWidth: 0.6)
        }
        .lineLimit(1)
    }

    private var upperTarget: String {
        target.uppercased()
    }

    private var pillColor: Color {
        if upperTarget == "DIRECT" { return .green }
        if upperTarget == "REJECT" { return .red }
        return .indigo
    }

    private var foregroundColor: Color {
        if upperTarget == "DIRECT" { return .green }
        if upperTarget == "REJECT" { return .red }
        return .primary
    }

    private var iconName: String {
        if upperTarget == "DIRECT" { return "arrow.forward" }
        if upperTarget == "REJECT" { return "hand.raised.fill" }
        return "arrow.triangle.branch"
    }
}

private struct RuleRow: View {
    let rule: RuleConfigurationSummary
    let isHighlighted: Bool
    let onTest: (String) -> Void

    @State private var isHovered = false
    @State private var showCopied = false

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            // 规则序号
            Text(verbatim: "\(rule.order)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

            // 规则类型徽章
            HStack(spacing: 3.5) {
                Image(systemName: kindIcon(rule.kind))
                    .font(.system(size: 9, weight: .bold))
                Text(rule.kind)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(ruleKindColor(rule.kind))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                ruleKindColor(rule.kind).opacity(0.12),
                in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                    .stroke(ruleKindColor(rule.kind).opacity(0.24), lineWidth: 0.5)
            }

            // 规则条件
            if let criteria = rule.criteria {
                Text(criteria)
                    .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(criteria)
            } else {
                Text(AppLocalization.string("Any remaining traffic (Fallback)"))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: AetherVisual.s3)

            // 悬停快捷复制
            if isHovered || showCopied {
                Button {
                    copyCriteria()
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10.5))
                        .foregroundStyle(showCopied ? Color.green : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.secondary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Copy criteria"))
                .transition(.opacity)
            }

            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            TargetPillView(target: rule.target, isHovered: isHovered)
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, AetherVisual.sRow)
        .padding(.vertical, AetherVisual.sCompact + 1)
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .fill(
                    isHighlighted
                        ? Color.accentColor.opacity(0.14)
                        : (isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.95) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(
                    isHighlighted
                        ? Color.accentColor
                        : (isHovered ? Color.accentColor.opacity(0.35) : Color(nsColor: .separatorColor).opacity(0.3)),
                    lineWidth: isHighlighted ? 1.5 : 0.5
                )
        }
        .shadow(
            color: isHighlighted ? Color.accentColor.opacity(0.25) : (isHovered ? Color.black.opacity(0.04) : Color.clear),
            radius: isHighlighted ? 5 : 2,
            y: 1
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if let criteria = rule.criteria {
                Button {
                    copyText(criteria)
                } label: {
                    Label(AppLocalization.string("Copy Criteria"), systemImage: "doc.on.doc")
                }

                Button {
                    onTest(criteria)
                } label: {
                    Label(AppLocalization.string("Test This Destination"), systemImage: "bolt.badge.clock")
                }
            }

            Button {
                let line = "\(rule.kind),\(rule.criteria.map { $0 + "," } ?? "")\(rule.target)"
                copyText(line)
            } label: {
                Label(AppLocalization.string("Copy Full Rule"), systemImage: "list.clipboard")
            }

            Button {
                copyText(rule.target)
            } label: {
                Label(AppLocalization.string("Copy Target Name"), systemImage: "arrow.right.circle")
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func copyCriteria() {
        if let criteria = rule.criteria {
            copyText(criteria)
        } else {
            copyText(rule.kind)
        }
        withAnimation {
            showCopied = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation {
                showCopied = false
            }
        }
    }

    private func copyText(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private func kindIcon(_ kind: String) -> String {
        let upper = kind.uppercased()
        if upper.contains("DOMAIN") { return "globe" }
        if upper.contains("IP") || upper.contains("CIDR") { return "network" }
        if upper.contains("GEO") { return "map" }
        if upper.contains("MATCH") { return "asterisk" }
        return "number"
    }

    private func ruleKindColor(_ kind: String) -> Color {
        let upper = kind.uppercased()
        if upper.contains("DOMAIN") { return .blue }
        if upper.contains("IP") || upper.contains("CIDR") { return .orange }
        if upper.contains("GEO") { return .purple }
        if upper.contains("MATCH") { return .secondary }
        return .teal
    }
}

private struct StatePill: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(color)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s1)
        .background(
            color.opacity(0.12),
            in: Capsule()
        )
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

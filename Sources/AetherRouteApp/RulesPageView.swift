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

                HStack(spacing: AetherVisual.sMicro) {
                    if directCount > 0 {
                        RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                            .fill(Color.green)
                            .frame(width: max(directWidth - 1, 4))
                    }
                    if proxyCount > 0 {
                        RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                            .fill(Color.indigo)
                            .frame(width: max(proxyWidth - 1, 4))
                    }
                    if rejectCount > 0 {
                        RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                            .fill(Color.red)
                            .frame(width: max(rejectWidth - 1, 4))
                    }
                }
            }
            .frame(height: 6)
            .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))

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
                                        RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                                            .fill(
                                                LinearGradient(
                                                    colors: [Color.indigo.opacity(0.22), Color.accentColor.opacity(0.08)],
                                                    startPoint: .topLeading,
                                                    endPoint: .bottomTrailing
                                                )
                                            )
                                            .overlay {
                                                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
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
                                                .padding(.horizontal, AetherVisual.sCompact)
                                                .padding(.vertical, AetherVisual.sMicro)
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
                                            .padding(.leading, AetherVisual.s1)

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
                                    .padding(.vertical, AetherVisual.sCompact)
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

                                            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                                HStack(spacing: AetherVisual.s2) {
                                                    Text(String.localizedStringWithFormat(AppLocalization.string("Matched Rule #%lld"), Int64(result.order)))
                                                        .font(.system(size: 12.5, weight: .bold))

                                                    Text(result.matchedRule.kind)
                                                        .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                                                        .padding(.horizontal, AetherVisual.s1)
                                                        .padding(.vertical, AetherVisual.sMicro)
                                                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))

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
                                        .padding(.vertical, AetherVisual.sCompact)
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
                                            HStack(spacing: AetherVisual.s1) {
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
                                        HStack(spacing: AetherVisual.s1) {
                                            ForEach(RuleKindFilter.allCases) { filter in
                                                let isSelected = selectedFilter == filter
                                                let count = summary.rules.filter { filter.accepts($0.kind) }.count
                                                Button {
                                                    withAnimation(AetherVisual.quickFade) {
                                                        selectedFilter = filter
                                                    }
                                                } label: {
                                                    HStack(spacing: AetherVisual.s1) {
                                                        Image(systemName: filter.icon)
                                                            .font(.system(size: 10))
                                                        Text(filter.localizedTitle)
                                                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                                                        Text(verbatim: "\(count)")
                                                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                                                            .padding(.horizontal, AetherVisual.s1)
                                                            .padding(.vertical, AetherVisual.sMicro)
                                                            .background(
                                                                isSelected ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12),
                                                                in: Capsule()
                                                            )
                                                    }
                                                    .padding(.horizontal, AetherVisual.s2)
                                                    .padding(.vertical, AetherVisual.s1)
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
                                        .padding(AetherVisual.sMicro)
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
                                    .padding(.top, AetherVisual.sMicro)
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
                    RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

            // 规则类型徽章
            HStack(spacing: AetherVisual.s1) {
                Image(systemName: kindIcon(rule.kind))
                    .font(.system(size: 9, weight: .bold))
                Text(rule.kind)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(ruleKindColor(rule.kind))
            .padding(.horizontal, AetherVisual.sCompact)
            .padding(.vertical, AetherVisual.sMicro)
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
        .padding(.vertical, AetherVisual.sCompact)
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

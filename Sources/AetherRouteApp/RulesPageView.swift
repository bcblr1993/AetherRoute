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
                        .foregroundStyle(.primary)
                }

                HStack(spacing: AetherVisual.s1) {
                    Circle().fill(Color.indigo).frame(width: 6.5, height: 6.5)
                    Text(String.localizedStringWithFormat(AppLocalization.string("Proxy: %lld"), Int64(proxyCount)))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                }

                if rejectCount > 0 {
                    HStack(spacing: AetherVisual.s1) {
                        Circle().fill(Color.red).frame(width: 6.5, height: 6.5)
                        Text(String.localizedStringWithFormat(AppLocalization.string("Reject: %lld"), Int64(rejectCount)))
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                    }
                }

                Spacer()
            }
        }
    }
}

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.openSettings) private var openSettings
    @State private var searchText = ""
    @State private var selectedFilter: RuleKindFilter = .all
    @State private var selectedAction: RuleActionFilter = .all
    @State private var showSimulator: Bool = false
    @State private var testQuery: String = ""
    @State private var testResult: RouteMatchResult? = nil
    @State private var hasAttemptedMatch: Bool = false
    @State private var matchExplanation = ""
    @State private var highlightedRuleID: Int? = nil
    @State private var showAddRuleSheet: Bool = false
    @State private var editingRule: CustomRule? = nil

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                let displayedRules = filteredRules(from: summary.rules)
                let directCount = summary.rules.filter { $0.target.uppercased() == "DIRECT" }.count
                let rejectCount = summary.rules.filter { $0.target.uppercased() == "REJECT" }.count
                let proxyCount = max(0, summary.rules.count - directCount - rejectCount)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                            AetherPageHeader(.rules) {
                                simulatorToggle
                            }

                            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                                ruleHeading(count: summary.ruleCount)
                                DisclosureGroup("Rule sources & scope") {
                                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                                        Text("Custom rules take precedence in the core rule list. Imported rules retain their order; optimization may add direct rules at runtime.")
                                        Text("This list is a configuration summary. System bypass exclusions and runtime optimization can affect actual traffic outside the displayed list.")
                                        Text("Bypass changes apply on the next connection. Network optimization applies on the next connection or profile reload.")
                                        Button("Manage bypass rules") {
                                            openSettings()
                                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                                NotificationCenter.default.post(name: .aetherRouteNavigateToSettings, object: "bypass")
                                            }
                                        }
                                        .help("Open Settings and select Bypass.")
                                    }
                                    .font(.callout).foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                }
                                RuleDistributionBar(directCount: directCount, proxyCount: proxyCount,
                                                    rejectCount: rejectCount, totalCount: summary.rules.count)
                            }
                            .padding(AetherVisual.s4)
                            .featureCard()

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
                                            .foregroundStyle(.primary)
                                    }

                                    Text("Predicts a match against the displayed rules. This does not test reachability, DNS resolution, or the complete runtime policy.")
                                        .font(.callout).foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                    HStack(spacing: AetherVisual.s2) {
                                        Image(systemName: "magnifyingglass")
                                            .foregroundStyle(.primary)
                                            .padding(.leading, AetherVisual.s1)

                                        TextField(
                                            AppLocalization.string("Enter a domain (e.g. github.com) or IP (e.g. 192.168.1.1)…"),
                                            text: $testQuery
                                        )
                                        .textFieldStyle(.plain)
                                        .font(.system(.callout, design: .monospaced))
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
                                                    .foregroundStyle(.primary)
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

                                    HStack(spacing: AetherVisual.s1) {
                                        Text(AppLocalization.string("Quick Test:"))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                        ForEach(["google.com", "apple.com", "github.com", "bilibili.com"], id: \.self) { domain in
                                            Button(domain) {
                                                testQuery = domain
                                                performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                                            }
                                            .buttonStyle(.plain)
                                            .font(.subheadline)
                                            .padding(.horizontal, AetherVisual.s2)
                                            .padding(.vertical, AetherVisual.sMicro)
                                            .background(Color.secondary.opacity(0.1), in: Capsule())
                                            .accessibilityIdentifier("rule-quick-test-\(domain)")
                                        }
                                    }

                                    if let result = testResult {
                                        HStack(spacing: AetherVisual.s3) {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.title)
                                                .foregroundStyle(Color.green)

                                            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                                HStack(spacing: AetherVisual.s2) {
                                                    if result.isCustomRule {
                                                        Text(verbatim: "CUSTOM RULE")
                                                            .font(.caption2.weight(.semibold))
                                                            .foregroundStyle(Color.white)
                                                            .padding(.horizontal, AetherVisual.sCompact)
                                                            .padding(.vertical, AetherVisual.sMicro)
                                                            .background(Color.teal, in: Capsule())
                                                    }

                                                    Text(String.localizedStringWithFormat(AppLocalization.string("Matched Rule #%lld"), Int64(result.order)))
                                                        .font(.callout.weight(.bold))

                                                    Text(result.matchedRule.kind)
                                                        .font(.system(.caption2, design: .monospaced, weight: .bold))
                                                        .padding(.horizontal, AetherVisual.s1)
                                                        .padding(.vertical, AetherVisual.sMicro)
                                                        .background(Color.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))

                                                    Image(systemName: "arrow.right")
                                                        .font(.caption2)
                                                        .foregroundStyle(.primary)

                                                    TargetPillView(target: result.target)
                                                }

                                                Text(result.reason)
                                                    .font(.caption)
                                                    .foregroundStyle(result.isCustomRule ? Color.teal : Color.secondary)
                                            }

                                            Spacer()

                                            Button {
                                                withAnimation(AetherVisual.panelSpring) {
                                                    highlightedRuleID = result.matchedRule.id
                                                    scrollProxy.scrollTo(result.matchedRule.id, anchor: .center)
                                                }
                                            } label: {
                                                Label(AppLocalization.string("Locate"), systemImage: "scope")
                                                    .font(.subheadline.weight(.semibold))
                                            }
                                            .buttonStyle(.bordered)
                                            .controlSize(.small)
                                        }
                                        .padding(AetherVisual.s3)
                                        .background(
                                            result.isCustomRule ? Color.teal.opacity(0.1) : Color.green.opacity(0.08),
                                            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                                                .stroke(result.isCustomRule ? Color.teal.opacity(0.4) : Color.green.opacity(0.25), lineWidth: 0.5)
                                        }
                                    } else if hasAttemptedMatch && !testQuery.isEmpty {
                                        HStack(spacing: AetherVisual.s2) {
                                            Image(systemName: "exclamationmark.triangle")
                                                .foregroundStyle(.orange)
                                            Text(matchExplanation)
                                                .font(.caption)
                                                .foregroundStyle(.primary)
                                        }
                                        .padding(AetherVisual.s3)
                                        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                                    }
                                }
                                .padding(AetherVisual.s4)
                                .featureCard()
                                .transition(.opacity.combined(with: .move(edge: .top)))
                            }

                            // 2.5 用户自定义分流规则 (Custom Rules - Top Priority)
                            FeatureSection(
                                title: AppLocalization.string("Custom rules (Top priority)"),
                                symbol: "slider.horizontal.3"
                            ) {
                                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                                    HStack {
                                        VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                            HStack(spacing: AetherVisual.s2) {
                                                Text(AppLocalization.string("Custom routing rules"))
                                                    .font(.headline.weight(.semibold))
                                                Text(String.localizedStringWithFormat(AppLocalization.string("%lld rules"), Int64(tunnel.customRules.count)))
                                                    .font(.system(.callout, design: .monospaced, weight: .semibold))
                                                    .foregroundStyle(Color(nsColor: .labelColor))
                                                    .padding(.horizontal, AetherVisual.sCompact)
                                                    .padding(.vertical, AetherVisual.sMicro)
                                                    .background(Color.teal.opacity(0.12), in: Capsule())
                                            }
                                            Text(AppLocalization.string("Custom rules take absolute top priority. Direct IP-CIDR rules automatically bypass TUN kernel routing."))
                                                .font(.callout.weight(.medium))
                                                .foregroundStyle(Color(nsColor: .labelColor))
                                        }
                                        Spacer()

                                        Button {
                                            editingRule = nil
                                            showAddRuleSheet = true
                                        } label: {
                                            Label(AppLocalization.string("Add Rule"), systemImage: "plus.circle.fill")
                                                .font(.callout.weight(.semibold))
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .controlSize(.small)
                                    }

                                    if let msg = tunnel.customRuleMessage {
                                        HStack(spacing: AetherVisual.s2) {
                                            Image(systemName: tunnel.customRuleMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                                .foregroundStyle(tunnel.customRuleMessageIsError ? Color.red : Color.green)
                                            Text(msg)
                                                .font(.caption)
                                                .foregroundStyle(tunnel.customRuleMessageIsError ? Color.red : Color.primary)
                                        }
                                        .padding(.vertical, AetherVisual.sMicro)
                                    }

                                    if tunnel.customRules.isEmpty {
                                        Label(AppLocalization.string("No custom rules configured"), systemImage: "pencil.and.list.clipboard")
                                            .font(.callout).foregroundStyle(.primary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    } else {
                                        VStack(spacing: AetherVisual.sCompact) {
                                            ForEach(tunnel.customRules) { rule in
                                                CustomRuleRow(
                                                    rule: rule,
                                                    onToggle: {
                                                        Task {
                                                            await tunnel.toggleCustomRule(id: rule.id)
                                                        }
                                                    },
                                                    onEdit: {
                                                        editingRule = rule
                                                        showAddRuleSheet = true
                                                    },
                                                    onDelete: {
                                                        Task {
                                                            await tunnel.deleteCustomRule(id: rule.id)
                                                        }
                                                    },
                                                    onTest: {
                                                        testQuery = rule.value
                                                        showSimulator = true
                                                        if let s = tunnel.activeProfileSummary {
                                                            performMatch(rules: s.rules, totalRuleCount: s.ruleCount)
                                                        }
                                                    }
                                                )
                                            }
                                        }
                                    }
                                }
                                .padding(AetherVisual.s4)
                                .featureCard()
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
                                        AetherSearchField(
                                            text: $searchText,
                                            prompt: AppLocalization.string("Filter criteria, targets, or kinds…"),
                                            accessibilityIdentifier: "rules-search-field"
                                        )

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
                                            .font(.callout.weight(.medium))
                                        }
                                        .menuStyle(.borderedButton)
                                        .accessibilityLabel(selectedAction.localizedTitle)
                                        .accessibilityIdentifier("rules-action-filter")
                                        .fixedSize()
                                    }

                                    // 第二行：规则种类分段标签 + 计数提示
                                    HStack(spacing: AetherVisual.s2) {
                                        // Chips keep their labels on one line and
                                        // scroll sideways in a narrow window
                                        // instead of breaking "DOMAIN" in two.
                                        ScrollView(.horizontal, showsIndicators: false) {
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
                                                            .font(.caption)
                                                        Text(filter.localizedTitle)
                                                            .font(.subheadline.weight(isSelected ? .semibold : .regular))
                                                        Text(verbatim: "\(count)")
                                                            .font(.system(.callout, design: .monospaced, weight: .semibold))
                                                            .foregroundStyle(Color(nsColor: .labelColor))
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
                                                    .fixedSize()
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
                                        }

                                        Spacer(minLength: AetherVisual.s2)

                                        Text(
                                            String.localizedStringWithFormat(
                                                AppLocalization.string("Showing %lld of %lld items."),
                                                Int64(displayedRules.count),
                                                Int64(summary.rules.count)
                                            )
                                        )
                                        .font(.caption.weight(.medium))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .fixedSize()
                                    }

                                    HStack(spacing: AetherVisual.s1) {
                                        Label(AppLocalization.string("Evaluation order (top to bottom)"), systemImage: "arrow.down")
                                            .font(.caption.weight(.semibold))
                                            .foregroundStyle(.primary)
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
                        .aetherPageContent(.wide)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(AppLocalization.string("Routing rules content"))
                    }
                }
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                        AetherPageHeader(.rules)
                        FeatureEmptyState(
                            symbol: "list.bullet.rectangle.portrait",
                            title: AppLocalization.string("No rule set loaded"),
                            detail: AppLocalization.string("Import a validated profile to inspect routing order and targets.")
                        )
                    }
                    .aetherPageContent(.wide)
                }
            }
        }
        .accessibilityIdentifier("rules-page")
#if DEBUG
        .task {
            // Isolated screenshot review only: open one sheet on launch.
            switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_SHEET"] {
            case "custom-rule": showAddRuleSheet = true
            default: break
            }
        }
#endif
        .sheet(isPresented: $showAddRuleSheet) {
            CustomRuleEditorSheet(
                initialRule: editingRule,
                onSave: { rule in
                    if editingRule != nil {
                        return await tunnel.updateCustomRule(rule)
                    }
                    return await tunnel.addCustomRule(rule)
                }
            )
            .environmentObject(tunnel)
        }
    }

    /// The page header already names the page; the card heading only
    /// qualifies what the distribution below summarizes.
    private func ruleHeading(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
            Text("Ordered routing policy").font(.headline)
            Spacer(minLength: AetherVisual.s2)
            Text(verbatim: "\(String.localizedStringWithFormat(AppLocalization.string("%lld rules"), Int64(count))) · \(routingModeTitle)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var routingModeTitle: String {
        switch tunnel.routingMode {
        case .rule: AppLocalization.string("Rule mode")
        case .global: AppLocalization.string("Global mode")
        case .direct: AppLocalization.string("Direct mode")
        }
    }

    private var simulatorToggle: some View {
        Button {
            withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) { showSimulator.toggle() }
        } label: {
            Label(AppLocalization.string(showSimulator ? "Hide Test" : "Test Route"), systemImage: "arrow.triangle.branch")
        }
        .buttonStyle(.bordered)
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
                .font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                        .fill(Color.secondary.opacity(0.08))
                )

            if rule.isCustom {
                Text(verbatim: "CUSTOM")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color.teal)
                    .padding(.horizontal, AetherVisual.s1)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(Color.teal.opacity(0.18), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.badgeRadius)
                            .stroke(Color.teal.opacity(0.4), lineWidth: 0.5)
                    }
            }

            // 规则类型徽章
            HStack(spacing: AetherVisual.s1) {
                Image(systemName: kindIcon(rule.kind))
                    .font(.caption2.weight(.bold))
                    .imageScale(.small)
                    .accessibilityHidden(true)
                Text(rule.kind)
                    .font(.caption.monospaced().weight(.medium))
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
                    .font(.system(.callout, design: .monospaced, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(criteria)
            } else {
                Text(AppLocalization.string("Any remaining traffic (Fallback)"))
                    .font(.callout.weight(.regular))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s3)

            // 悬停快捷复制
            if isHovered || showCopied {
                Button {
                    copyCriteria()
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(showCopied ? Color.green : Color.secondary)
                        .frame(width: 22, height: 22)
                        .background(Color.secondary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Copy criteria"))
                .transition(.opacity)
            }

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
        .onHover { hovering in
            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
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

    /// Rule kinds are told apart by their symbol and label. Colour stays
    /// with the target (direct, proxy, reject), which is what a reader
    /// scanning the list is actually looking for.
    private func ruleKindColor(_: String) -> Color {
        .secondary
    }
}

struct CustomRuleRow: View {
    let rule: CustomRule
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTest: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            ))
            .toggleStyle(.switch)
            .controlSize(.mini)
            .labelsHidden()

            Text(verbatim: "CUSTOM")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Color.teal)
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(Color.teal.opacity(0.15), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: AetherVisual.badgeRadius)
                        .stroke(Color.teal.opacity(0.3), lineWidth: 0.5)
                }

            Text(rule.kind.rawValue)
                .font(.system(.caption2, design: .monospaced, weight: .bold))
                .foregroundStyle(Color.blue)
                .padding(.horizontal, AetherVisual.sCompact)
                .padding(.vertical, AetherVisual.sMicro)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s1) {
                    Text(rule.value)
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                        .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                        .lineLimit(1)

                    if rule.noResolve {
                        Text(verbatim: "no-resolve")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, AetherVisual.sMicro)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                }

                if let comment = rule.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: AetherVisual.s2)

            Image(systemName: "arrow.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)

            TargetPillView(target: rule.target.rawString, isHovered: isHovered)
                .frame(maxWidth: 160, alignment: .trailing)

            HStack(spacing: AetherVisual.sMicro) {
                Button {
                    onTest()
                } label: {
                    Image(systemName: "bolt.badge.clock")
                        .font(.subheadline)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 24, height: 24)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Verify rule"))

                Button {
                    onEdit()
                } label: {
                    Image(systemName: "pencil")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .frame(width: 24, height: 24)
                        .background(Color.secondary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Edit rule"))

                Button {
                    onDelete()
                } label: {
                    Image(systemName: "trash")
                        .font(.subheadline)
                        .foregroundStyle(Color.red.opacity(0.85))
                        .frame(width: 24, height: 24)
                        .background(Color.red.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Delete rule"))
            }
        }
        .padding(.horizontal, AetherVisual.sRow)
        .padding(.vertical, AetherVisual.sCompact)
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .fill(isHovered ? Color(nsColor: .controlBackgroundColor).opacity(0.95) : Color(nsColor: .controlBackgroundColor).opacity(0.55))
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(isHovered ? Color.teal.opacity(0.4) : Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
        }
        .opacity(rule.isEnabled ? 1.0 : 0.6)
        .onHover { hovering in
            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                isHovered = hovering
            }
        }
    }
}

struct CustomRuleEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    var initialRule: CustomRule?
    var onSave: (CustomRule) async -> Bool

    @State private var requestsCancel = false
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var mode: InputMode = .form
    @State private var rawClashString: String = ""
    @State private var selectedKind: CustomRuleKind = .domainSuffix
    @State private var ruleValue: String = ""
    @State private var selectedTargetKind: TargetKind = .direct
    @State private var customTargetName: String = ""
    @State private var noResolve: Bool = false
    @State private var comment: String = ""

    @State private var testResult: RouteMatchResult? = nil
    @State private var hasTested: Bool = false
    @State private var testExplanation: String = ""

    enum InputMode: String, CaseIterable, Identifiable {
        case form
        case raw
        var id: String { rawValue }

        var title: String {
            switch self {
            case .form: AppLocalization.string("Form")
            case .raw: AppLocalization.string("Clash Rule Text")
            }
        }
    }

    enum TargetKind: String, CaseIterable, Identifiable {
        case direct = "DIRECT"
        case reject = "REJECT"
        case proxy = "PROXY"
        var id: String { rawValue }

        var title: String {
            switch self {
            case .direct: AppLocalization.string("Direct (DIRECT)")
            case .reject: AppLocalization.string("Reject (REJECT)")
            case .proxy: AppLocalization.string("Proxy node or group")
            }
        }
    }

    init(initialRule: CustomRule? = nil, onSave: @escaping (CustomRule) async -> Bool) {
        self.initialRule = initialRule
        self.onSave = onSave
        _rawClashString = State(initialValue: initialRule?.toClashRuleString() ?? "")
        _selectedKind = State(initialValue: initialRule?.kind ?? .domainSuffix)
        _ruleValue = State(initialValue: initialRule?.value ?? "")
        _noResolve = State(initialValue: initialRule?.noResolve ?? false)
        _comment = State(initialValue: initialRule?.comment ?? "")
        if let initial = initialRule {
            switch initial.target {
            case .direct:
                _selectedTargetKind = State(initialValue: .direct)
            case .reject:
                _selectedTargetKind = State(initialValue: .reject)
            case let .proxy(name):
                _selectedTargetKind = State(initialValue: .proxy)
                _customTargetName = State(initialValue: name)
            }
        }
    }

    private var currentRuleTarget: CustomRuleTarget {
        switch selectedTargetKind {
        case .direct: return .direct
        case .reject: return .reject
        case .proxy:
            let trimmed = customTargetName.trimmingCharacters(in: .whitespacesAndNewlines)
            return .proxy(trimmed.isEmpty ? "Proxy" : trimmed)
        }
    }

    private var validationResult: RuleValidationResult {
        if mode == .raw {
            do {
                let parsed = try CustomRule.parse(rawClashString)
                return CustomRuleValidator.validate(parsed)
            } catch {
                return .invalid(reason: error.localizedDescription)
            }
        } else {
            return CustomRuleValidator.validate(kind: selectedKind, value: ruleValue, target: currentRuleTarget)
        }
    }

    private var candidateRule: CustomRule? {
        if mode == .raw {
            return try? CustomRule.parse(
                rawClashString,
                id: initialRule?.id ?? UUID(),
                comment: comment.isEmpty ? nil : comment
            )
        } else {
            guard validationResult.isValid else { return nil }
            return CustomRule(
                id: initialRule?.id ?? UUID(),
                kind: selectedKind,
                value: ruleValue,
                target: currentRuleTarget,
                noResolve: noResolve,
                isEnabled: initialRule?.isEnabled ?? true,
                comment: comment.isEmpty ? nil : comment
            )
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "arrow.triangle.branch",
                title: initialRule == nil
                    ? AppLocalization.string("Add Custom Routing Rule")
                    : AppLocalization.string("Edit Custom Routing Rule"),
                subtitle: AppLocalization.string("Custom rules take top priority in traffic matching.")
            )

            Picker(AppLocalization.string("Input mode"), selection: $mode) {
                ForEach(InputMode.allCases) { m in
                    Text(m.title).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityIdentifier("custom-rule-input-mode")

            if mode == .form {
                Grid(alignment: .leading, horizontalSpacing: AetherVisual.s3, verticalSpacing: AetherVisual.s3) {
                    GridRow {
                        fieldLabel(AppLocalization.string("Rule kind"))
                        Picker(AppLocalization.string("Rule kind"), selection: $selectedKind) {
                            ForEach(CustomRuleKind.allCases, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                    }
                    GridRow {
                        fieldLabel(AppLocalization.string("Match"))
                        TextField(placeholderForKind(selectedKind), text: $ruleValue)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("custom-rule-value-field")
                    }
                    if selectedKind == .ipCIDR || selectedKind == .ipCIDR6 || selectedKind == .geoIP {
                        GridRow {
                            Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            Toggle(AppLocalization.string("Match by IP without DNS lookup (no-resolve)"), isOn: $noResolve)
                        }
                    }
                    GridRow {
                        fieldLabel(AppLocalization.string("Action"))
                        Picker(AppLocalization.string("Action"), selection: $selectedTargetKind) {
                            ForEach(TargetKind.allCases) { t in
                                Text(t.title).tag(t)
                            }
                        }
                        .labelsHidden()
                    }
                    if selectedTargetKind == .proxy {
                        GridRow {
                            fieldLabel(AppLocalization.string("Node or group"))
                            TextField(AppLocalization.string("e.g. PROXY, Node Select, Auto…"), text: $customTargetName)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    GridRow {
                        fieldLabel(AppLocalization.string("Note"))
                        TextField(AppLocalization.string("Optional, e.g. Tailscale node / local service"), text: $comment)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            } else {
                Grid(alignment: .leading, horizontalSpacing: AetherVisual.s3, verticalSpacing: AetherVisual.s3) {
                    GridRow {
                        fieldLabel(AppLocalization.string("Rule"))
                        TextField(AppLocalization.string("e.g. DOMAIN-SUFFIX,baizhiedu.xin,DIRECT or IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"), text: $rawClashString)
                            .textFieldStyle(.roundedBorder)
                            .font(.body.monospaced())
                            .accessibilityIdentifier("custom-rule-raw-field")
                    }
                    GridRow {
                        fieldLabel(AppLocalization.string("Note"))
                        TextField(AppLocalization.string("Optional, e.g. Direct private subnet"), text: $comment)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }

            // 实时校验提示 (Validation Status)
            HStack(spacing: AetherVisual.s2) {
                switch validationResult {
                case .valid:
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(Color.green)
                    Text(AppLocalization.string("Rule syntax is valid and active"))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.green)
                case let .invalid(reason):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color.orange)
                    Text(reason)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.orange)
                }
                Spacer()

                Button {
                    verifyRule()
                } label: {
                    Label(AppLocalization.string("Verify rule"), systemImage: "bolt.badge.clock.fill")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!validationResult.isValid || isSaving)
            }
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(
                validationResult.isValid ? Color.green.opacity(0.08) : Color.orange.opacity(0.08),
                in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
            )

            // 规则验证结果 (Dry-run Result)
            if hasTested {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    if let res = testResult {
                        HStack(spacing: AetherVisual.s2) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.green)
                            Text(String.localizedStringWithFormat(AppLocalization.string("Simulated match: %@ -> %@"), res.matchedRule.kind, res.target))
                                .font(.callout.weight(.bold))
                                .foregroundStyle(Color.green)
                        }
                    } else if !testExplanation.isEmpty {
                        HStack(spacing: AetherVisual.s2) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.secondary)
                            Text(testExplanation)
                                .font(.caption)
                                .foregroundStyle(.primary)
                        }
                    }
                }
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius))
            }

            if saveFailed, let message = tunnel.customRuleMessage {
                Text(message).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            }
            // Action Buttons
            HStack {
                Button(AppLocalization.string("Cancel")) { requestsCancel = true }
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    if let rule = candidateRule {
                        isSaving = true
                        saveFailed = false
                        Task {
                            let saved = await onSave(rule)
                            isSaving = false
                            if saved { dismiss() } else { saveFailed = true }
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(AppLocalization.string("Save rule"), isWorking: isSaving)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!validationResult.isValid || isSaving)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(minWidth: AetherVisual.sheetMinWidth, idealWidth: AetherVisual.sheetIdealWidth, maxWidth: AetherVisual.sheetMaxWidth)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: mode)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: selectedTargetKind)
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
    }

    private var hasChanges: Bool {
        if let initialRule {
            return rawClashString != initialRule.toClashRuleString()
                || selectedKind != initialRule.kind || ruleValue != initialRule.value
                || currentRuleTarget != initialRule.target || noResolve != initialRule.noResolve
                || comment != (initialRule.comment ?? "")
        }
        return !rawClashString.isEmpty || !ruleValue.isEmpty || !comment.isEmpty
            || !customTargetName.isEmpty || noResolve || selectedKind != .domainSuffix || selectedTargetKind != .direct
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func placeholderForKind(_ kind: CustomRuleKind) -> String {
        switch kind {
        case .domainSuffix: AppLocalization.string("e.g. example.com")
        case .domain: AppLocalization.string("e.g. my.server.com")
        case .domainKeyword: AppLocalization.string("e.g. tailscale or internal")
        case .ipCIDR: AppLocalization.string("e.g. 100.64.0.0/10 or 192.168.1.0/24")
        case .ipCIDR6: AppLocalization.string("e.g. fd7a:115c:a1e0::/48")
        case .geoIP: AppLocalization.string("e.g. CN or US")
        }
    }

    private func verifyRule() {
        hasTested = true
        testResult = nil
        testExplanation = ""
        guard let rule = candidateRule else {
            testExplanation = AppLocalization.string("Rule validation failed")
            return
        }

        let ruleSummary = RuleConfigurationSummary(
            id: -1,
            order: 1,
            kind: rule.kind.rawValue,
            criteria: rule.value,
            target: rule.target.rawString,
            isCustom: true
        )

        let existingRules = tunnel.activeProfileSummary?.rules ?? []
        let simulatedList = [ruleSummary] + existingRules

        let destination: String
        switch rule.kind {
        case .domain, .domainSuffix:
            destination = rule.value
        case .domainKeyword:
            destination = "service.\(rule.value).com"
        case .ipCIDR:
            let ipPart = rule.value.split(separator: "/").first.map(String.init) ?? rule.value
            destination = ipPart
        case .ipCIDR6:
            let ipPart = rule.value.split(separator: "/").first.map(String.init) ?? rule.value
            destination = ipPart
        case .geoIP:
            destination = "223.5.5.5"
        }

        switch RouteMatchEngine.assess(destination: destination, against: simulatedList, totalRuleCount: simulatedList.count) {
        case let .matched(res):
            testResult = res
        case .indeterminate:
            testExplanation = AppLocalization.string("Rule created; IP/GEO rules are evaluated at runtime by core DNS resolution.")
        case .noMatch:
            testExplanation = AppLocalization.string("No match found for simulated destination; please verify rule.")
        case .invalidDestination:
            testExplanation = AppLocalization.string("Invalid simulated destination address.")
        }
    }
}

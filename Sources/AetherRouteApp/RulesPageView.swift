import AetherRouteKit
import SwiftUI

enum RuleActionFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case proxy = "Proxy"
    case direct = "Direct"
    case reject = "Reject"

    var id: String { rawValue }

    /// The segment label, before its count.
    var shortTitle: String {
        switch self {
        case .all: AppLocalization.string("All")
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

/// Shares of the rule list by target, as one thin bar. It counts rules, not
/// traffic; the numbers are in the filter beside it.
struct RuleDistributionBar: View {
    let directCount: Int
    let proxyCount: Int
    let rejectCount: Int
    let totalCount: Int
    let routingMode: RoutingMode

    var body: some View {
        GeometryReader { proxy in
            let total = CGFloat(max(totalCount, 1))
            HStack(spacing: AetherVisual.sMicro) {
                segment(count: proxyCount, color: .indigo, width: proxy.size.width, total: total)
                segment(count: directCount, color: .green, width: proxy.size.width, total: total)
                segment(count: rejectCount, color: .red, width: proxy.size.width, total: total)
            }
        }
        .frame(height: 6)
        .frame(minWidth: 80)
        .background(AetherVisual.neutralFill, in: Capsule())
        .clipShape(Capsule())
        // Outside Rule mode the list is not consulted, so the shares
        // describe nothing that happens to traffic right now.
        .opacity(routingMode == .rule ? 1 : 0.4)
        .help(summary)
        .accessibilityElement()
        .accessibilityLabel(summary)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: [directCount, proxyCount, rejectCount])
    }

    @ViewBuilder
    private func segment(count: Int, color: Color, width: CGFloat, total: CGFloat) -> some View {
        if count > 0 {
            Rectangle()
                .fill(color)
                .frame(width: max(width * CGFloat(count) / total - 1, 4))
        }
    }

    private var summary: String {
        [
            String.localizedStringWithFormat(AppLocalization.string("Proxy rules: %lld"), Int64(proxyCount)),
            String.localizedStringWithFormat(AppLocalization.string("Direct rules: %lld"), Int64(directCount)),
            String.localizedStringWithFormat(AppLocalization.string("Reject rules: %lld"), Int64(rejectCount)),
        ].joined(separator: " · ")
    }
}

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.openSettings) private var openSettings
    @State private var searchText = ""
    @State private var selectedAction: RuleActionFilter = .all
    @State private var testQuery: String = ""
    @State private var testResult: RouteMatchResult? = nil
    @State private var hasAttemptedMatch: Bool = false
    @State private var matchExplanation = ""
    @State private var highlightedRuleID: Int? = nil
    @State private var showAddRuleSheet: Bool = false
    @State private var editingRule: CustomRule? = nil
    @State private var routingResourceImportKind: RoutingResourceKind?
    @State private var isResourceImporterPresented = false

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                let displayedRules = filteredRules(from: summary.rules)

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        // A plain stack (1.7.1). As a LazyVStack the page took
                        // a width wider than its column, slid under the
                        // sidebar, and kept re-laying out until AppKit ended
                        // the loop by crashing the app ("more Update
                        // Constraints in Window passes than there are views").
                        // It holds a dozen sections; the rule list below
                        // stays lazy inside the same scroll view.
                        VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing + AetherVisual.s1) {
                            AetherPageHeader(.rules) {
                                Button {
                                    editingRule = nil
                                    showAddRuleSheet = true
                                } label: {
                                    Label(AppLocalization.string("Add Rule"), systemImage: "plus")
                                        .labelStyle(.titleAndIcon)
                                }
                                .aetherButton(prominent: true)
                                .accessibilityIdentifier("add-custom-rule")
                            }

                            routeTester(summary: summary, scrollProxy: scrollProxy)

                            ApplicationRulesSection()

                            customRulesSection(summary: summary)

                            if !summary.ruleProviders.isEmpty {
                                section(title: AppLocalization.string("Rule providers"), note: nil) {
                                    VStack(spacing: 0) {
                                        ForEach(summary.ruleProviders) { provider in
                                            ProviderRow(provider: provider, tint: AppSection.rules.tileColor)
                                            if provider.id != summary.ruleProviders.last?.id {
                                                Divider().padding(.leading, AetherVisual.rowDividerInset)
                                            }
                                        }
                                    }
                                    .aetherPanel()
                                }
                            }

                            profileRulesSection(summary: summary, displayedRules: displayedRules)

                            if !tunnel.requiredRoutingResources.isEmpty {
                                RoutingResourcesCard(
                                    importResource: { kind in
                                        routingResourceImportKind = kind
                                        isResourceImporterPresented = true
                                    }
                                )
                                .environmentObject(tunnel)
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
                        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.customRuleMessage)
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
        .fileImporter(
            isPresented: $isResourceImporterPresented,
            allowedContentTypes: [.data],
            allowsMultipleSelection: false
        ) { result in
            guard let kind = routingResourceImportKind else { return }
            routingResourceImportKind = nil
            switch result {
            case let .success(urls):
                guard let url = urls.first else { return }
                Task { await tunnel.importRoutingResource(kind, from: url) }
            case let .failure(error):
                tunnel.reportProfileImportError(error)
            }
        }
    }

    /// A heading above a group, with an optional quieter note beside it, as
    /// in System Settings.
    private func section<Content: View>(
        title: String,
        note: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: title, note: note)
            content()
        }
    }

    // MARK: Route tester

    /// "Where would this go?" answered in place: the page's most useful
    /// question, so it leads the page instead of hiding behind a button.
    private func routeTester(summary: ProfileConfigurationSummary, scrollProxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(spacing: AetherVisual.s2) {
                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: "globe")
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityHidden(true)
                    TextField(
                        AppLocalization.string("Enter a website or IP to see which route it takes"),
                        text: $testQuery
                    )
                    .textFieldStyle(.plain)
                    .font(.body)
                    .onSubmit { performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount) }
                    .accessibilityIdentifier("rule-test-field")
                    if !testQuery.isEmpty {
                        Button {
                            testQuery = ""
                            testResult = nil
                            hasAttemptedMatch = false
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

                Button(AppLocalization.string("Test")) {
                    performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                }
                .aetherButton(prominent: true)
                .controlSize(.large)
                .disabled(testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("rule-test-button")
            }

            if let result = testResult {
                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AetherReadableTint(color: .green))
                        .accessibilityHidden(true)
                    Text(String.localizedStringWithFormat(AppLocalization.string("Matched Rule #%lld"), Int64(result.order)))
                        .font(.callout.weight(.semibold))
                    RuleKindTag(kind: result.matchedRule.kind)
                    if let criteria = result.matchedRule.criteria {
                        Text(verbatim: criteria)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityHidden(true)
                    RuleTargetLabel(target: result.target)
                    Spacer(minLength: AetherVisual.s2)
                    Button {
                        withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) {
                            highlightedRuleID = result.matchedRule.id
                            scrollProxy.scrollTo(result.matchedRule.id, anchor: .center)
                        }
                    } label: {
                        Label(AppLocalization.string("Locate"), systemImage: "scope")
                    }
                    .aetherButton()
                    .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("rule-test-result")
                .transition(AetherVisual.insertion)
            } else if hasAttemptedMatch && !testQuery.isEmpty {
                Label(matchExplanation, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rule-test-explanation")
                    .transition(AetherVisual.insertion)
            } else {
                HStack(spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Try:"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    ForEach(["google.com", "apple.com", "github.com", "bilibili.com"], id: \.self) { domain in
                        Button(domain) {
                            testQuery = domain
                            performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                        }
                        .buttonStyle(.aetherPressable)
                        .font(.caption)
                        .padding(.horizontal, AetherVisual.s2)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(AetherVisual.neutralFill, in: Capsule())
                        // A bare domain read as an unclear label; say the action.
                        .accessibilityLabel(String.localizedStringWithFormat(AppLocalization.string("Test %@"), domain))
                        .accessibilityIdentifier("rule-quick-test-\(domain)")
                    }
                }
                .transition(.opacity)
            }
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: testResult?.matchedRule.id)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: hasAttemptedMatch)
    }

    // MARK: Custom rules

    private func customRulesSection(summary: ProfileConfigurationSummary) -> some View {
        section(
            title: AppLocalization.string("Custom rules"),
            note: AppLocalization.string("Checked after application rules")
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if let msg = tunnel.customRuleMessage {
                    Label(msg, systemImage: tunnel.customRuleMessageIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(tunnel.customRuleMessageIsError ? AnyShapeStyle(Color.red) : AnyShapeStyle(AetherVisual.secondaryText))
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.top, AetherVisual.s3)
                        .transition(AetherVisual.insertion)
                }
                if destinationRules.isEmpty {
                    HStack(spacing: AetherVisual.s3) {
                        Text(AppLocalization.string("No custom rules yet. To always send a site direct or through the proxy, add a rule here."))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: AetherVisual.s2)
                        Button(AppLocalization.string("Add")) {
                            editingRule = nil
                            showAddRuleSheet = true
                        }
                        .aetherButton()
                        .controlSize(.small)
                    }
                    .padding(AetherVisual.s4)
                } else {
                    VStack(spacing: AetherVisual.sCompact) {
                        let rulesList = destinationRules
                        ForEach(Array(rulesList.enumerated()), id: \.element.id) { index, rule in
                            CustomRuleRow(
                                rule: rule,
                                canMoveUp: index > 0,
                                canMoveDown: index + 1 < rulesList.count,
                                onMoveUp: {
                                    Task { await tunnel.moveCustomRule(id: rule.id, direction: .up) }
                                },
                                onMoveDown: {
                                    Task { await tunnel.moveCustomRule(id: rule.id, direction: .down) }
                                },
                                onToggle: {
                                    Task { await tunnel.toggleCustomRule(id: rule.id) }
                                },
                                onEdit: {
                                    editingRule = rule
                                    showAddRuleSheet = true
                                },
                                onDelete: {
                                    Task { await tunnel.deleteCustomRule(id: rule.id) }
                                },
                                onTest: {
                                    testQuery = rule.value
                                    performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                                }
                            )
                            .transition(AetherVisual.insertion)
                        }
                    }
                    .padding(AetherVisual.listCardInset)
                }
            }
            .aetherPanel()
            .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: destinationRules.map(\.id))
        }
    }

    /// Custom rules other than application rules, which have their own
    /// section above.
    private var destinationRules: [CustomRule] {
        tunnel.customRules.filter { $0.kind != .application }
    }

    // MARK: Profile rules

    private func profileRulesSection(
        summary: ProfileConfigurationSummary,
        displayedRules: [RuleConfigurationSummary]
    ) -> some View {
        let directCount = summary.rules.filter { $0.target.uppercased() == "DIRECT" }.count
        let rejectCount = summary.rules.filter { $0.target.uppercased() == "REJECT" }.count
        let proxyCount = max(0, summary.rules.count - directCount - rejectCount)
        return section(
            title: AppLocalization.string("Profile rules"),
            note: AppLocalization.string("Matched top to bottom; the first match wins")
        ) {
            VStack(alignment: .leading, spacing: 0) {
                if summary.rules.isEmpty {
                    FeatureEmptyState(
                        symbol: "list.bullet.rectangle.portrait",
                        title: AppLocalization.string("No explicit rules"),
                        detail: AppLocalization.string("The active profile contains no ordered rule entries. Its effective fallback is determined only after the protocol core validates and starts the profile.")
                    )
                    .padding(AetherVisual.s4)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: AetherVisual.s3) {
                            actionFilter(summary: summary)
                            RuleDistributionBar(
                                directCount: directCount, proxyCount: proxyCount,
                                rejectCount: rejectCount, totalCount: summary.rules.count,
                                routingMode: tunnel.routingMode
                            )
                            // Decorative: the filter's segments carry the counts.
                            .accessibilityHidden(true)
                            rulesSearchField
                                .frame(width: AetherVisual.searchFieldWidth)
                        }
                        VStack(alignment: .leading, spacing: AetherVisual.s2) {
                            HStack(spacing: AetherVisual.s3) {
                                actionFilter(summary: summary)
                                rulesSearchField
                            }
                            RuleDistributionBar(
                                directCount: directCount, proxyCount: proxyCount,
                                rejectCount: rejectCount, totalCount: summary.rules.count,
                                routingMode: tunnel.routingMode
                            )
                            .accessibilityHidden(true)
                        }
                    }
                    .padding(AetherVisual.s3)

                    if let modeNote {
                        Label(modeNote, systemImage: "info.circle")
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, AetherVisual.s4)
                            .padding(.bottom, AetherVisual.s2)
                            .accessibilityIdentifier("rule-distribution-mode-note")
                            .transition(AetherVisual.insertion)
                    }

                    if displayedRules.isEmpty {
                        Text(AppLocalization.string("No rules match. Try another filter or clear the search."))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(AetherVisual.s5)
                    } else {
                        // Lazy: a profile can carry thousands of rules, and
                        // only the rows on screen should be built.
                        LazyVStack(spacing: 0) {
                            ForEach(displayedRules) { rule in
                                Divider().padding(.leading, AetherVisual.s4)
                                RuleRow(
                                    rule: rule,
                                    isHighlighted: highlightedRuleID == rule.id,
                                    onTest: { destination in
                                        testQuery = destination
                                        performMatch(rules: summary.rules, totalRuleCount: summary.ruleCount)
                                    }
                                )
                                .id(rule.id)
                            }
                        }
                        .padding(.bottom, AetherVisual.s1)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(AppLocalization.string("Ordered routing rules"))
                        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: displayedRules.count)
                    }
                }
            }
            .aetherPanel()

            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.string("This is a summary of the profile; bypass rules and runtime optimization can also affect traffic."))
                Button(AppLocalization.string("Manage bypass rules")) {
                    openSettings()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        NotificationCenter.default.post(name: .aetherRouteNavigateToSettings, object: "bypass")
                    }
                }
                .buttonStyle(.link)
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .padding(.horizontal, AetherVisual.s2)
            .padding(.top, AetherVisual.s1)
        }
    }

    private var modeNote: String? {
        switch tunnel.routingMode {
        case .rule: nil
        case .global: AppLocalization.string("Global mode does not match rules; all traffic goes through the proxy.")
        case .direct: AppLocalization.string("Direct mode does not match rules; all traffic connects directly.")
        }
    }

    private func actionFilter(summary: ProfileConfigurationSummary) -> some View {
        AetherSegmentedPicker(
            selection: $selectedAction,
            options: RuleActionFilter.allCases.map { action in
                .init(
                    value: action,
                    title: "\(action.shortTitle) \(summary.rules.filter { action.accepts($0.target) }.count)"
                )
            },
            accessibilityLabel: AppLocalization.string("Filter by target"),
            accessibilityIdentifier: "rules-action-filter"
        )
        .fixedSize()
    }

    private var rulesSearchField: some View {
        AetherSearchField(
            text: $searchText,
            prompt: AppLocalization.string("Search rules"),
            accessibilityIdentifier: "rules-search-field"
        )
    }

    private func performMatch(rules: [RuleConfigurationSummary], totalRuleCount: Int) {
        hasAttemptedMatch = true
        testResult = nil
        switch RouteMatchEngine.assess(destination: testQuery, against: rules, totalRuleCount: totalRuleCount) {
        case let .matched(result): testResult = result
        case let .indeterminate(ruleOrder?):
            // A GEOSITE/GEOIP or similar rule needs the core's databases; say
            // which rule stops the preview rather than guessing past it.
            matchExplanation = String.localizedStringWithFormat(
                AppLocalization.string("Rule #%lld needs data only available once connected, so the route is decided by the core."),
                Int64(ruleOrder)
            )
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

/// A rule's kind as a small monospaced tag.
struct RuleKindTag: View {
    let kind: String

    var body: some View {
        Text(verbatim: kind.uppercased())
            .font(.caption2.monospaced().weight(.semibold))
            .foregroundStyle(AetherVisual.strongSecondaryText)
            .padding(.horizontal, AetherVisual.sCompact)
            .padding(.vertical, AetherVisual.sMicro)
            .background(AetherVisual.neutralFill, in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
            .fixedSize()
    }
}

/// Marks a rule the person wrote, in the rule list and in the custom rule
/// editor alike. Teal names the source; it does not carry state.
private struct CustomRuleBadge: View {
    var body: some View {
        Text(AppLocalization.string("Custom"))
            .textCase(.uppercase)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(AetherReadableTint(color: .teal))
            .padding(.horizontal, AetherVisual.s1)
            .padding(.vertical, AetherVisual.sMicro)
            .background(AetherVisual.tintFill(.teal), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
            .fixedSize()
    }
}

/// Where a rule sends traffic, coloured by kind of target: direct green,
/// reject red, a proxy or group indigo.
struct RuleTargetLabel: View {
    let target: String

    var body: some View {
        Label {
            Text(title)
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: symbol)
        }
        .font(.callout.weight(.semibold))
        .foregroundStyle(AetherReadableTint(color: tint))
        .help(target)
    }

    private var upper: String { target.uppercased() }

    private var title: String {
        switch upper {
        case "DIRECT": AppLocalization.string("Direct")
        case "REJECT", "REJECT-DROP": AppLocalization.string("Reject")
        default: target
        }
    }

    private var symbol: String {
        switch upper {
        case "DIRECT": "arrow.right"
        case "REJECT", "REJECT-DROP": "hand.raised.fill"
        default: "arrow.triangle.branch"
        }
    }

    private var tint: Color {
        switch upper {
        case "DIRECT": .green
        case "REJECT", "REJECT-DROP": .red
        default: .indigo
        }
    }
}

private struct RuleRow: View {
    let rule: RuleConfigurationSummary
    let isHighlighted: Bool
    let onTest: (String) -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Text(verbatim: "\(rule.order)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(width: 28, alignment: .trailing)

            if rule.isCustom {
                CustomRuleBadge()
            }

            RuleKindTag(kind: rule.kind)
                .frame(minWidth: 110, alignment: .leading)

            if let criteria = rule.criteria {
                Text(criteria)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(criteria)
            } else {
                Text(AppLocalization.string("Any remaining traffic (Fallback)"))
                    .font(.callout)
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s3)

            if isHovered {
                // The shared copy button: it confirms with a check mark and
                // respects Reduce Motion, unlike the hand-made one it replaced.
                AetherCopyButton(title: Text(AppLocalization.string("Copy Criteria"))) {
                    copyText(rule.criteria ?? rule.kind)
                }
                .labelStyle(.iconOnly)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(width: AetherVisual.iconButtonSize, height: AetherVisual.iconButtonSize)
                .buttonStyle(.aetherPressable)
                .help(AppLocalization.string("Copy Criteria"))
                .transition(.opacity)
            }

            RuleTargetLabel(target: rule.target)
                .frame(maxWidth: 190, alignment: .trailing)
        }
        .padding(.horizontal, AetherVisual.s4)
        .frame(minHeight: AetherVisual.listRowHeight)
        .background(
            isHighlighted
                ? AetherVisual.selectionFill
                : (isHovered ? AetherVisual.hoverFill : Color.clear)
        )
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

    @discardableResult
    private func copyText(_ text: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(text, forType: .string)
    }
}

struct CustomRuleRow: View {
    let rule: CustomRule
    var canMoveUp: Bool = false
    var canMoveDown: Bool = false
    var onMoveUp: (() -> Void)? = nil
    var onMoveDown: (() -> Void)? = nil
    let onToggle: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTest: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Toggle(isOn: Binding(
                get: { rule.isEnabled },
                set: { _ in onToggle() }
            )) { EmptyView() }
            // Switches inside a list row are small; labelled rows use
            // AetherRowToggleStyle at the regular size.
            .toggleStyle(.switch)
            .controlSize(.small)
            .labelsHidden()

            CustomRuleBadge()

            // The same neutral tag as the rule list: a rule kind names
            // what is matched, it is not a state, so it carries no colour.
            RuleKindTag(kind: rule.kind.rawValue)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s1) {
                    // Middle truncation keeps the registrable end of a long
                    // domain readable, as in the profile rules table.
                    Text(rule.value)
                        .font(.system(.callout, design: .monospaced, weight: .semibold))
                        .foregroundStyle(rule.isEnabled ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AetherVisual.secondaryText))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.value)

                    if rule.noResolve {
                        Text(verbatim: "no-resolve")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, AetherVisual.sMicro)
                            .background(AetherVisual.neutralFill, in: Capsule())
                    }
                }

                if let comment = rule.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption2)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
            // The value is what the row is about; the target label and the
            // five buttons gave it up first, leaving "signup…" beside a gap.
            // The minimum keeps a fragment visible in the narrowest window.
            .frame(minWidth: 72, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: AetherVisual.s2)

            // RuleTargetLabel draws its own arrow; a second one stood here.
            // At its natural width (a long proxy name capped at 160 pt), so
            // "Direct" stays whole without reserving a 160-pt gap.
            RuleTargetLabel(target: rule.target.rawString)
                .frame(maxWidth: 160, alignment: .trailing)
                .fixedSize(horizontal: true, vertical: false)

            HStack(spacing: AetherVisual.sMicro) {
                if let onMoveUp {
                    Button {
                        onMoveUp()
                    } label: {
                        AetherRowIconLabel(symbol: "chevron.up")
                    }
                    .buttonStyle(.aetherPressable)
                    .disabled(!canMoveUp)
                    .help(AppLocalization.string("Move rule up"))
                    .accessibilityLabel(AppLocalization.string("Move rule up"))
                }

                if let onMoveDown {
                    Button {
                        onMoveDown()
                    } label: {
                        AetherRowIconLabel(symbol: "chevron.down")
                    }
                    .buttonStyle(.aetherPressable)
                    .disabled(!canMoveDown)
                    .help(AppLocalization.string("Move rule down"))
                    .accessibilityLabel(AppLocalization.string("Move rule down"))
                }

                Button {
                    onTest()
                } label: {
                    AetherRowIconLabel(symbol: "bolt.badge.clock", tint: .accentColor)
                }
                .buttonStyle(.aetherPressable)
                .help(AppLocalization.string("Verify rule"))
                .accessibilityLabel(AppLocalization.string("Verify rule"))

                Button {
                    onEdit()
                } label: {
                    AetherRowIconLabel(symbol: "pencil")
                }
                .buttonStyle(.aetherPressable)
                .help(AppLocalization.string("Edit rule"))
                .accessibilityLabel(AppLocalization.string("Edit rule"))

                Button {
                    onDelete()
                } label: {
                    AetherRowIconLabel(symbol: "trash", tint: .red)
                }
                .buttonStyle(.aetherPressable)
                .help(AppLocalization.string("Delete rule"))
                .accessibilityLabel(AppLocalization.string("Delete rule"))
            }
        }
        .padding(.horizontal, AetherVisual.sRow)
        .padding(.vertical, AetherVisual.sCompact)
        .background(
            isHovered ? AetherVisual.hoverFill : Color.clear,
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .opacity(rule.isEnabled ? 1.0 : 0.6)
        .onHover { hovering in
            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                isHovered = hovering
            }
        }
        .contextMenu {
            if let onMoveUp, canMoveUp {
                Button {
                    onMoveUp()
                } label: {
                    Label(AppLocalization.string("Move rule up"), systemImage: "arrow.up")
                }
            }
            if let onMoveDown, canMoveDown {
                Button {
                    onMoveDown()
                } label: {
                    Label(AppLocalization.string("Move rule down"), systemImage: "arrow.down")
                }
            }
            Button {
                onTest()
            } label: {
                Label(AppLocalization.string("Verify rule"), systemImage: "bolt.badge.clock")
            }
            Button {
                onEdit()
            } label: {
                Label(AppLocalization.string("Edit rule"), systemImage: "pencil")
            }
            Divider()
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label(AppLocalization.string("Delete rule"), systemImage: "trash")
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
                if let report = batchReport {
                    // Valid as soon as one line imports; skipped lines are
                    // listed by `batchSummary`, not treated as a failure.
                    guard let first = report.rules.first else {
                        return .invalid(
                            reason: report.skipped.first?.reason
                                ?? CustomRuleParseError.emptyValue.localizedDescription
                        )
                    }
                    return checkingGeoSiteCategory(CustomRuleValidator.validate(first), of: first)
                }
                let parsed = try CustomRule.parse(rawClashString)
                return checkingGeoSiteCategory(CustomRuleValidator.validate(parsed), of: parsed)
            } catch {
                return .invalid(reason: error.localizedDescription)
            }
        } else {
            return checkingGeoSiteCategory(
                CustomRuleValidator.validate(kind: selectedKind, value: ruleValue, target: currentRuleTarget),
                of: CustomRule(kind: selectedKind, value: ruleValue, target: currentRuleTarget)
            )
        }
    }

    /// A GEOSITE category missing from the routing database makes the core
    /// refuse every rule, so a typo is caught here rather than at connect.
    private func checkingGeoSiteCategory(
        _ result: RuleValidationResult,
        of rule: CustomRule
    ) -> RuleValidationResult {
        guard result.isValid, rule.kind == .geoSite,
              let index = tunnel.bundledGeoSiteCategories,
              !index.contains(ruleValue: rule.value) else { return result }
        return .invalid(reason: AppLocalization.format(
            "GEOSITE category %@ is not in the routing database. Check the spelling, for example cn, apple or openai.",
            GeoSiteCategoryIndex.categoryCode(of: rule.value)
        ))
    }

    /// The pasted text read line by line; nil unless adding in raw mode.
    private var batchReport: CustomRuleBatchReport? {
        guard mode == .raw, initialRule == nil else { return nil }
        // One unknown GEOSITE category would stop the core from loading any
        // rule; skip it with the other unsupported lines.
        return CustomRule.parseBatchReport(
            rawClashString,
            defaultTarget: currentRuleTarget,
            rejection: { rule in
                guard case let .invalid(reason) = checkingGeoSiteCategory(.valid, of: rule) else {
                    return nil
                }
                return reason
            }
        )
    }

    private var candidateBatchRules: [CustomRule]? {
        guard let parsed = batchReport?.rules, !parsed.isEmpty else {
            return nil
        }
        let fallbackComment = comment.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fallbackComment.isEmpty else { return parsed }
        return parsed.map { rule in
            var copy = rule
            if copy.comment == nil || copy.comment?.isEmpty == true {
                copy.comment = fallbackComment
            }
            return copy
        }
    }

    private var candidateRule: CustomRule? {
        if mode == .raw {
            if initialRule == nil {
                return candidateBatchRules?.first
            }
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
                subtitle: AppLocalization.string("Custom rules take top priority in traffic matching."),
                tint: AppSection.rules.tileColor
            )

            // A compact switch between the two ways to write a rule; a
            // full-width bar outweighed the fields it switches (1.5.2).
            HStack {
                Spacer(minLength: 0)
                AetherSegmentedPicker(
                    selection: $mode,
                    options: InputMode.allCases.map { .init(value: $0, title: $0.title) },
                    accessibilityLabel: AppLocalization.string("Input mode"),
                    accessibilityIdentifier: "custom-rule-input-mode"
                )
                .fixedSize()
                Spacer(minLength: 0)
            }

            // Grouped rows as in Settings: the name leading, the control
            // trailing, every row on one grid.
            VStack(spacing: 0) {
                if mode == .form {
                    ruleRow(AppLocalization.string("Rule kind")) {
                        Picker(AppLocalization.string("Rule kind"), selection: $selectedKind) {
                            ForEach(CustomRuleKind.editableKinds, id: \.self) { kind in
                                Text(kind.displayName).tag(kind)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    ruleDivider
                    ruleRow(AppLocalization.string("Match")) {
                        TextField(placeholderForKind(selectedKind), text: $ruleValue)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("custom-rule-value-field")
                    }
                    if selectedKind == .ipCIDR || selectedKind == .ipCIDR6 || selectedKind == .geoIP {
                        ruleDivider
                        Toggle(AppLocalization.string("Match by IP without DNS lookup (no-resolve)"), isOn: $noResolve)
                            .toggleStyle(AetherRowToggleStyle())
                            .padding(.horizontal, AetherVisual.s4)
                            .frame(minHeight: AetherVisual.compactRowHeight)
                            .transition(.opacity)
                    }
                    ruleDivider
                    ruleRow(AppLocalization.string("Action")) {
                        Picker(AppLocalization.string("Action"), selection: $selectedTargetKind) {
                            ForEach(TargetKind.allCases) { t in
                                Text(t.title).tag(t)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                    if selectedTargetKind == .proxy {
                        ruleDivider
                        ruleRow(AppLocalization.string("Node or group")) {
                            TextField(AppLocalization.string("e.g. PROXY, Node Select, Auto…"), text: $customTargetName)
                                .textFieldStyle(.plain)
                                .multilineTextAlignment(.trailing)
                        }
                        .transition(.opacity)
                    }
                    ruleDivider
                    ruleRow(AppLocalization.string("Note")) {
                        TextField(AppLocalization.string("Optional, e.g. Tailscale node / local service"), text: $comment)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    ruleRow(AppLocalization.string("Rule")) {
                        TextField(
                            AppLocalization.string("e.g. DOMAIN-SUFFIX,baizhiedu.xin,DIRECT or IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"),
                            text: $rawClashString,
                            axis: initialRule == nil ? .vertical : .horizontal
                        )
                        .lineLimit(initialRule == nil ? 1...5 : 1...1)
                        .textFieldStyle(.plain)
                        .font(.body.monospaced())
                        // A whole rule line reads from its start.
                        .multilineTextAlignment(.leading)
                        .accessibilityIdentifier("custom-rule-raw-field")
                    }
                    ruleDivider
                    ruleRow(AppLocalization.string("Note")) {
                        TextField(AppLocalization.string("Optional, e.g. Direct private subnet"), text: $comment)
                            .textFieldStyle(.plain)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .aetherPanel()

            // One quiet line under the fields, once there is something to
            // judge: an empty form is not an error yet.
            if hasEnteredRule {
                validationLine
                    .padding(.horizontal, AetherVisual.sectionHeaderInset)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                batchSummary
                    .padding(.horizontal, AetherVisual.sectionHeaderInset)
            }

            // 规则验证结果 (Dry-run Result)
            if hasTested {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    if let res = testResult {
                        Label {
                            Text(String.localizedStringWithFormat(AppLocalization.string("Simulated match: %@ -> %@"), res.matchedRule.kind, res.target))
                                .font(.callout.weight(.semibold))
                        } icon: {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(AetherReadableTint(color: .green))
                        }
                    } else if !testExplanation.isEmpty {
                        Label {
                            Text(testExplanation)
                                .font(.callout)
                        } icon: {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(AetherVisual.secondaryText)
                        }
                    }
                }
                .padding(.horizontal, AetherVisual.s3)
                .padding(.vertical, AetherVisual.s2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .aetherCallout(tint: testResult == nil ? .gray : .green)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if saveFailed, let message = tunnel.customRuleMessage {
                AetherInlineMessage(text: message)
            }

            // Verify is a secondary step and leads; Cancel and Save share
            // the trailing edge, as in every macOS sheet.
            HStack(spacing: AetherVisual.s2) {
                Button {
                    verifyRule()
                } label: {
                    Label(AppLocalization.string("Verify rule"), systemImage: "checkmark.shield")
                }
                .aetherButton()
                .disabled(!validationResult.isValid || isSaving)
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .aetherButton()
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)
                Button {
                    if let batch = candidateBatchRules, batch.count > 1 {
                        isSaving = true
                        saveFailed = false
                        Task {
                            let saved = await tunnel.importCustomRulesBatch(batch)
                            isSaving = false
                            if saved { dismiss() } else { saveFailed = true }
                        }
                    } else if let rule = candidateRule {
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
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(!validationResult.isValid || isSaving)
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: mode)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: selectedTargetKind)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: selectedKind)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: hasEnteredRule)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: hasTested)
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

    /// Whether there is anything to validate yet.
    private var hasEnteredRule: Bool {
        mode == .raw
            ? !rawClashString.trimmingCharacters(in: .whitespaces).isEmpty
            : !ruleValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var validationLine: some View {
        switch validationResult {
        case .valid:
            Label {
                Text(AppLocalization.string("Rule syntax is valid and active"))
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(AetherReadableTint(color: .green))
            }
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
        case let .invalid(reason):
            AetherInlineMessage(text: reason, kind: .warning)
        }
    }

    /// Says what a pasted list will actually import before Save, so lines
    /// this app cannot import are never dropped without a word.
    @ViewBuilder
    private var batchSummary: some View {
        if let report = batchReport, !report.rules.isEmpty,
           !report.skipped.isEmpty || report.wasTruncated {
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.format(
                    "%lld rules will be imported.",
                    Int64(report.rules.count)
                ))
                if !report.skipped.isEmpty {
                    let lines = report.skipped.prefix(8).map { String($0.lineNumber) }
                        .joined(separator: ", ")
                    Text(AppLocalization.format(
                        "%lld unsupported lines will be skipped (line %@).",
                        Int64(report.skipped.count),
                        report.skipped.count > 8 ? lines + ", …" : lines
                    ))
                    .help(report.skipped.prefix(20)
                        .map { "\($0.lineNumber): \($0.line) — \($0.reason)" }
                        .joined(separator: "\n"))
                }
                if report.wasTruncated {
                    Text(AppLocalization.format(
                        "Only the first %lld rules are read from one paste.",
                        Int64(CustomRule.maximumBatchRules)
                    ))
                }
            }
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("custom-rule-batch-summary")
        }
    }

    private func ruleRow<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: AetherVisual.s3) {
            Text(title)
                .foregroundStyle(.primary)
                .fixedSize()
            Spacer(minLength: AetherVisual.s3)
            control()
        }
        .padding(.horizontal, AetherVisual.s4)
        .frame(minHeight: AetherVisual.compactRowHeight)
    }

    private var ruleDivider: some View {
        Divider().padding(.leading, AetherVisual.s4)
    }

    private func placeholderForKind(_ kind: CustomRuleKind) -> String {
        switch kind {
        case .domainSuffix: AppLocalization.string("e.g. example.com")
        case .domain: AppLocalization.string("e.g. my.server.com")
        case .domainKeyword: AppLocalization.string("e.g. tailscale or internal")
        case .ipCIDR: AppLocalization.string("e.g. 100.64.0.0/10 or 192.168.1.0/24")
        case .ipCIDR6: AppLocalization.string("e.g. fd7a:115c:a1e0::/48")
        case .geoIP: AppLocalization.string("e.g. CN or US")
        case .geoSite: AppLocalization.string("e.g. openai, apple, cn or netflix")
        case .dstPort: AppLocalization.string("e.g. 443, 80 or 853")
        case .application: ""
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
        case .geoSite, .dstPort:
            destination = "example.com"
        case .application:
            // Matched by the connecting app, not a destination.
            testExplanation = AppLocalization.string("Application rules match the app that opens a connection, so they cannot be tested by destination.")
            return
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

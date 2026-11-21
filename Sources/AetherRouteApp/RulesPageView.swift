import AetherRouteKit
import SwiftUI

enum RulesPageSectionFilter: String, CaseIterable, Identifiable {
    case all
    case appAndCustom
    case providers
    case profileRules
    case routeTester

    var id: Self { self }

    var title: String {
        switch self {
        case .all: AppLocalization.string("All")
        case .appAndCustom: AppLocalization.string("App & Custom")
        case .providers: AppLocalization.string("Providers")
        case .profileRules: AppLocalization.string("Profile rules")
        case .routeTester: AppLocalization.string("Route Tester")
        }
    }
}

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
        if self == .all { return true }
        let upper = target.uppercased()
        switch self {
        case .all: return true
        case .direct: return upper == "DIRECT"
        case .reject: return upper == "REJECT" || upper == "REJECT-DROP"
        case .proxy: return upper != "DIRECT" && upper != "REJECT" && upper != "REJECT-DROP"
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
        Canvas { context, size in
            let total = CGFloat(max(totalCount, 1))
            let gap = AetherVisual.sMicro
            let counts: [(Int, Color)] = [
                (proxyCount, .indigo),
                (directCount, .green),
                (rejectCount, .red),
            ].filter { $0.0 > 0 }
            var x: CGFloat = 0
            for (index, item) in counts.enumerated() {
                let isLast = index == counts.count - 1
                let rawWidth = size.width * CGFloat(item.0) / total
                let segWidth = isLast
                    ? max(0, size.width - x)
                    : min(max(rawWidth - gap, 4), max(0, size.width - x))
                guard segWidth > 0 else { continue }
                let rect = CGRect(x: x, y: 0, width: segWidth, height: size.height)
                context.fill(Path(rect), with: .color(item.1))
                x += segWidth + gap
            }
        }
        .frame(height: AetherVisual.statusDotSize)
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

    private var summary: String {
        [
            String.localizedStringWithFormat(AppLocalization.string("Proxy rules: %lld"), Int64(proxyCount)),
            String.localizedStringWithFormat(AppLocalization.string("Direct rules: %lld"), Int64(directCount)),
            String.localizedStringWithFormat(AppLocalization.string("Reject rules: %lld"), Int64(rejectCount)),
        ].joined(separator: " · ")
    }
}

private struct RouteTestRequest: Equatable {
    let id = UUID()
    let query: String
}

struct RulesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.openSettings) private var openSettings
    @State private var selectedSection: RulesPageSectionFilter = .all
    @State private var searchText = ""
    @State private var selectedAction: RuleActionFilter = .all
    @State private var externalRouteTestRequest: RouteTestRequest? = nil
    @State private var pageContentWidth: CGFloat = 0
    @State private var rulesFilterBarWidth: CGFloat = 0
    @State private var highlightedRuleID: Int? = nil
    @State private var showsAllProfileRules: Bool = false
    @State private var showAddRuleSheet: Bool = false
    @State private var editingRule: CustomRule? = nil
    @State private var showRuleProviderEditorSheet: Bool = false
    @State private var editingRuleProvider: RuleProviderMetadata? = nil
    @State private var previewingRuleProvider: RuleProviderMetadata? = nil
    @State private var routingResourceImportKind: RoutingResourceKind?
    @State private var isResourceImporterPresented = false

    var body: some View {
        Group {
            if let summary = tunnel.activeProfileSummary {
                let showsProfileRules = selectedSection == .all || selectedSection == .profileRules
                let useFullRules = showsProfileRules && (
                    !searchText.isEmpty
                        || selectedAction != .all
                        || showsAllProfileRules
                        || (highlightedRuleID.map { $0 >= summary.rules.count } ?? false)
                )
                let displayedRules = showsProfileRules
                    ? filteredRules(from: useFullRules ? summary.allRules : summary.rules)
                    : []

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
                                AetherFlowLayout(spacing: AetherVisual.s2) {
                                    blockQUICButton
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
                            }

                            // Only the rules: the nodes have their own page.
                            ProfileCompatibilityNotice(report: ProfileCompatibilityReport(
                                unsupportedProxies: [],
                                unsupportedRules: summary.compatibility.unsupportedRules,
                                limitedOptions: []
                            ))

                            rulesSectionFilterControl

                            if selectedSection == .all || selectedSection == .routeTester {
                                RouteTesterCard(
                                    summary: summary,
                                    externalRequest: externalRouteTestRequest,
                                    onLocateRule: { matchedRuleID in
                                        locateRule(matchedRuleID, using: scrollProxy)
                                    }
                                )
                                .environmentObject(tunnel)
                                .transition(.opacity)
                            }

                            if selectedSection == .all || selectedSection == .appAndCustom {
                                ScenarioRulePresetsSection()
                                    .transition(.opacity)

                                ApplicationRulesSection()
                                    .transition(.opacity)

                                customRulesSection(summary: summary)
                                    .transition(.opacity)
                            }

                            if selectedSection == .all || selectedSection == .providers {
                                customRuleProvidersSection(summary: summary)
                                    .transition(.opacity)

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
                                    .transition(.opacity)
                                }

                                if !tunnel.requiredRoutingResources.isEmpty {
                                    RoutingResourcesCard(
                                        importResource: { kind in
                                            routingResourceImportKind = kind
                                            isResourceImporterPresented = true
                                        }
                                    )
                                    .environmentObject(tunnel)
                                    .transition(.opacity)
                                }

                                RoutingResourceMirrorSettingsCard(
                                    importResource: { kind in
                                        routingResourceImportKind = kind
                                        isResourceImporterPresented = true
                                    }
                                )
                                .environmentObject(tunnel)
                                .transition(.opacity)

                                TruncationNotice(
                                    visibleCount: summary.ruleProviders.count,
                                    totalCount: summary.ruleProviderCount
                                )
                                .transition(.opacity)
                            }

                            if selectedSection == .all || selectedSection == .profileRules {
                                profileRulesSection(summary: summary, displayedRules: displayedRules)
                                    .transition(.opacity)

                                TruncationNotice(
                                    visibleCount: displayedRules.count,
                                    totalCount: summary.ruleCount
                                )
                                .transition(.opacity)
                            }
                        }
                        .aetherPageContent(.wide)
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.width
                        } action: { newWidth in
                            if abs(pageContentWidth - newWidth) >= 1 {
                                pageContentWidth = newWidth
                            }
                        }
                        .animation(AetherVisual.animation(AetherVisual.quickFade), value: selectedSection)
                        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.customRuleMessage)
                        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.ruleProviderMessage)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(AppLocalization.string("Routing rules content"))
                    }
                    .onAppear {
                        consumePendingRuleTestDestination(summary: summary, scrollProxy: scrollProxy)
                    }
                    .onChange(of: tunnel.pendingRuleTestDestination) { _, _ in
                        consumePendingRuleTestDestination(summary: summary, scrollProxy: scrollProxy)
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
        .sheet(isPresented: $showRuleProviderEditorSheet) {
            RuleProviderEditorSheet(
                initialProvider: editingRuleProvider,
                onSave: { provider in
                    if editingRuleProvider != nil {
                        return await tunnel.updateCustomRuleProvider(provider)
                    }
                    return await tunnel.addCustomRuleProvider(provider)
                }
            )
            .environmentObject(tunnel)
        }
        .sheet(item: $previewingRuleProvider) { provider in
            RuleProviderPreviewSheet(provider: provider) { sample in
                if selectedSection != .all && selectedSection != .routeTester {
                    selectedSection = .all
                }
                externalRouteTestRequest = RouteTestRequest(query: sample)
            }
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

    @ViewBuilder
    private var rulesSectionFilterControl: some View {
        if pageContentWidth > 0 && pageContentWidth < 600 {
            HStack(spacing: AetherVisual.s2) {
                Text(AppLocalization.string("Rule sections"))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                Spacer(minLength: AetherVisual.s2)
                Picker(AppLocalization.string("Rule sections"), selection: $selectedSection) {
                    ForEach(RulesPageSectionFilter.allCases) { sectionFilter in
                        Text(sectionFilter.title).tag(sectionFilter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .accessibilityIdentifier("rules-section-filter")
            }
        } else {
            AetherSegmentedPicker(
                selection: $selectedSection,
                options: RulesPageSectionFilter.allCases.map {
                    .init(value: $0, title: $0.title)
                },
                accessibilityLabel: AppLocalization.string("Rule sections"),
                accessibilityIdentifier: "rules-section-filter",
                fillsWidth: true
            )
        }
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
                        .foregroundStyle(tunnel.customRuleMessageIsError ? AnyShapeStyle(AetherReadableTint(color: .red)) : AnyShapeStyle(AetherVisual.secondaryText))
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
                        blockQUICButton
                        Button(AppLocalization.string("Add")) {
                            editingRule = nil
                            showAddRuleSheet = true
                        }
                        .aetherButton()
                        .controlSize(.small)
                    }
                    .padding(AetherVisual.s4)
                } else {
                    let allRulesList = destinationRules
                    let visibleRules = filteredDestinationRules
                    let indexByID = Dictionary(
                        allRulesList.enumerated().map { ($1.id, $0) },
                        uniquingKeysWith: { first, _ in first }
                    )
                    if visibleRules.isEmpty {
                        Text(AppLocalization.string("No rules match. Try another filter or clear the search."))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(AetherVisual.s4)
                    } else {
                        LazyVStack(spacing: AetherVisual.sCompact) {
                            ForEach(visibleRules) { rule in
                                let fullIndex = indexByID[rule.id] ?? 0
                                CustomRuleRow(
                                    rule: rule,
                                    canMoveUp: fullIndex > 0,
                                    canMoveDown: fullIndex + 1 < allRulesList.count,
                                    onMoveUp: {
                                        Task { await tunnel.moveCustomRule(id: rule.id, direction: .up) }
                                    },
                                    onMoveDown: {
                                        Task { await tunnel.moveCustomRule(id: rule.id, direction: .down) }
                                    },
                                    onMoveToTop: {
                                        Task { await tunnel.moveCustomRule(id: rule.id, direction: .top) }
                                    },
                                    onMoveToBottom: {
                                        Task { await tunnel.moveCustomRule(id: rule.id, direction: .bottom) }
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
                                        if selectedSection != .all && selectedSection != .routeTester {
                                            selectedSection = .all
                                        }
                                        let query = rule.kind == .dstPort ? "example.com:\(rule.value)" : rule.value
                                        externalRouteTestRequest = RouteTestRequest(query: query)
                                    }
                                )
                                .transition(AetherVisual.insertion)
                            }
                        }
                        .padding(AetherVisual.listCardInset)
                    }
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

    private var existingBlockQUICRule: CustomRule? {
        let targetSignature = CustomRule.blockQUICPreset().toClashRuleString().uppercased()
        return tunnel.customRules.first {
            $0.toClashRuleString().uppercased() == targetSignature
        }
    }

    @ViewBuilder
    private var blockQUICButton: some View {
        let existing = existingBlockQUICRule
        Button {
            Task {
                if let existing {
                    if !existing.isEnabled {
                        await tunnel.toggleCustomRule(id: existing.id)
                    }
                } else {
                    _ = await tunnel.addCustomRule(CustomRule.blockQUICPreset())
                }
            }
        } label: {
            Label(
                existing?.isEnabled == true
                    ? AppLocalization.string("QUIC Blocked (UDP 443)")
                    : AppLocalization.string("Block QUIC (UDP 443)"),
                systemImage: existing?.isEnabled == true ? "checkmark.shield.fill" : "bolt.slash.fill"
            )
            .labelStyle(.titleAndIcon)
        }
        .aetherButton()
        .disabled(existing?.isEnabled == true)
        .accessibilityIdentifier("block-quic-preset-button")
    }

    private var filteredDestinationRules: [CustomRule] {
        destinationRules.filter { rule in
            guard selectedAction.accepts(rule.target.rawString) else { return false }
            guard !searchText.isEmpty else { return true }
            let query = searchText.lowercased()
            return rule.kind.rawValue.lowercased().contains(query)
                || rule.value.lowercased().contains(query)
                || rule.target.rawString.lowercased().contains(query)
                || (rule.comment?.lowercased().contains(query) ?? false)
        }
    }

    private func consumePendingRuleTestDestination(
        summary: ProfileConfigurationSummary,
        scrollProxy: ScrollViewProxy
    ) {
        guard let pending = tunnel.pendingRuleTestDestination?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !pending.isEmpty
        else { return }
        tunnel.pendingRuleTestDestination = nil
        if selectedSection != .all {
            selectedSection = .all
        }
        externalRouteTestRequest = RouteTestRequest(query: pending)
        let customHosts = Dictionary(
            tunnel.activeProfileOverrides.customHosts
                .filter(\.isEnabled)
                .map { ($0.domain.lowercased(), $0.ip) },
            uniquingKeysWith: { _, last in last }
        )
        if case let .matched(result) = RouteTesterCard.evaluateMatch(
            query: pending,
            rules: summary.allRules,
            totalRuleCount: summary.ruleCount,
            customHosts: customHosts,
            geoSiteData: tunnel.bundledGeoSiteData
        ) {
            locateRule(result.matchedRule.id, using: scrollProxy)
        }
    }

    private func locateRule(_ ruleID: Int, using scrollProxy: ScrollViewProxy) {
        if selectedSection == .routeTester {
            selectedSection = .all
        }
        highlightedRuleID = ruleID
        Task { @MainActor in
            await Task.yield()
            withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) {
                scrollProxy.scrollTo(ruleID, anchor: .center)
            }
        }
    }

    // MARK: Custom rule providers

    private func customRuleProvidersSection(summary: ProfileConfigurationSummary) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("Custom rule providers"),
                note: AppLocalization.string("HTTPS rule lists compiled after custom rules")
            ) {
                HStack(spacing: AetherVisual.s2) {
                    if !tunnel.customRuleProviders.isEmpty {
                        Button {
                            Task { await tunnel.refreshAllCustomRuleProviders() }
                        } label: {
                            AetherProgressButtonLabel(
                                AppLocalization.string("Update All"),
                                systemImage: "arrow.clockwise",
                                isWorking: tunnel.isRefreshingAllRuleProviders
                            )
                        }
                        .aetherButton()
                        .controlSize(.small)
                        .disabled(tunnel.isRefreshingAllRuleProviders)
                        .accessibilityIdentifier("refresh-all-rule-providers")
                    }
                    Button {
                        editingRuleProvider = nil
                        showRuleProviderEditorSheet = true
                    } label: {
                        Label(AppLocalization.string("Add Rule Set"), systemImage: "plus")
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("add-custom-rule-provider")
                }
            }

            VStack(alignment: .leading, spacing: 0) {
                if let msg = tunnel.ruleProviderMessage {
                    Label(
                        msg,
                        systemImage: tunnel.ruleProviderMessageIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(
                        tunnel.ruleProviderMessageIsError
                            ? AnyShapeStyle(AetherReadableTint(color: .red))
                            : AnyShapeStyle(AetherVisual.secondaryText)
                    )
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.top, AetherVisual.s3)
                    .transition(AetherVisual.insertion)
                }

                if tunnel.customRuleProviders.isEmpty {
                    HStack(spacing: AetherVisual.s3) {
                        Text(AppLocalization.string("No custom rule sets yet. Subscribe to an HTTPS domain, IP-CIDR, or classical rule list to apply rules across profiles."))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: AetherVisual.s2)
                        Button(AppLocalization.string("Add")) {
                            editingRuleProvider = nil
                            showRuleProviderEditorSheet = true
                        }
                        .aetherButton()
                        .controlSize(.small)
                    }
                    .padding(AetherVisual.s4)
                } else {
                    LazyVStack(spacing: AetherVisual.sCompact) {
                        ForEach(tunnel.customRuleProviders) { provider in
                            CustomRuleProviderRow(
                                provider: provider,
                                isRefreshing: tunnel.refreshingRuleProviderIDs.contains(provider.id),
                                onToggle: {
                                    Task { await tunnel.toggleCustomRuleProvider(id: provider.id) }
                                },
                                onRefresh: {
                                    Task { await tunnel.refreshCustomRuleProvider(id: provider.id) }
                                },
                                onPreview: {
                                    previewingRuleProvider = provider
                                },
                                onEdit: {
                                    editingRuleProvider = provider
                                    showRuleProviderEditorSheet = true
                                },
                                onDelete: {
                                    Task { await tunnel.deleteCustomRuleProvider(id: provider.id) }
                                }
                            )
                            .transition(AetherVisual.insertion)
                        }
                    }
                    .padding(AetherVisual.listCardInset)
                }
            }
            .aetherPanel()
            .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.customRuleProviders.map(\.id))
        }
    }

    // MARK: Profile rules

    private func ruleOverrideTargets(summary: ProfileConfigurationSummary) -> [CustomRuleTarget] {
        let groups = summary.proxyGroups.map { CustomRuleTarget.proxy($0.name) }
        let proxyTargets = groups.isEmpty ? [CustomRuleTarget.proxy("Proxy")] : groups
        return [.direct] + proxyTargets + [.reject]
    }

    private func profileRulesSection(
        summary: ProfileConfigurationSummary,
        displayedRules: [RuleConfigurationSummary]
    ) -> some View {
        let directCount = summary.directRuleCount
        let rejectCount = summary.rejectRuleCount
        let proxyCount = summary.proxyRuleCount
        let totalCount = summary.ruleCount
        let overrideTargets = ruleOverrideTargets(summary: summary)
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
                    AetherRulesFilterBarLayout {
                        actionFilter(summary: summary)
                        RuleDistributionBar(
                            directCount: directCount, proxyCount: proxyCount,
                            rejectCount: rejectCount, totalCount: totalCount,
                            routingMode: tunnel.routingMode
                        )
                        // Decorative: the filter's segments carry the counts.
                        .accessibilityHidden(true)
                        rulesSearchField
                    }
                    .padding(AetherVisual.s3)
                    .onGeometryChange(for: CGFloat.self) { proxy in
                        proxy.size.width
                    } action: { newWidth in
                        if abs(rulesFilterBarWidth - newWidth) >= 1 {
                            rulesFilterBarWidth = newWidth
                        }
                    }

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
                        let destinationRuleTargets: [String: CustomRuleTarget] = Dictionary(
                            tunnel.customRules.map { ("\($0.kind.rawValue)|\($0.value)", $0.target) },
                            uniquingKeysWith: { first, _ in first }
                        )
                        // Lazy: a profile can carry thousands of rules, and
                        // only the rows on screen should be built.
                        LazyVStack(spacing: 0) {
                            ForEach(displayedRules) { rule in
                                Divider().padding(.leading, AetherVisual.s4)
                                let existingOverrideTarget = rule.overrideCustomRuleKind.flatMap { kind -> CustomRuleTarget? in
                                    guard let criteria = rule.criteria?.trimmingCharacters(in: .whitespacesAndNewlines) else {
                                        return nil
                                    }
                                    return destinationRuleTargets["\(kind.rawValue)|\(criteria)"]
                                }
                                RuleRow(
                                    rule: rule,
                                    isHighlighted: highlightedRuleID == rule.id,
                                    overrideTargets: rule.overrideCustomRuleKind == nil ? [] : overrideTargets,
                                    existingOverrideTarget: existingOverrideTarget,
                                    onTest: { destination in
                                        if selectedSection != .all && selectedSection != .routeTester {
                                            selectedSection = .all
                                        }
                                        externalRouteTestRequest = RouteTestRequest(query: destination)
                                    },
                                    onOverride: { target in
                                        guard let customRule = rule.makeCustomRuleOverride(target: target) else { return }
                                        Task {
                                            await tunnel.setDestinationRule(
                                                kind: customRule.kind,
                                                value: customRule.value,
                                                noResolve: customRule.noResolve,
                                                target: customRule.target
                                            )
                                        }
                                    }
                                )
                                .id(rule.id)
                            }
                        }
                        .padding(.bottom, AetherVisual.s1)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(AppLocalization.string("Ordered routing rules"))
                        .animation(
                            displayedRules.count <= 60 ? AetherVisual.animation(AetherVisual.gentleSpring) : nil,
                            value: displayedRules.count
                        )

                        if summary.allRules.count > summary.rules.count,
                           searchText.isEmpty,
                           selectedAction == .all {
                            Divider().padding(.leading, AetherVisual.s4)
                            HStack {
                                Spacer()
                                Button {
                                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                                        showsAllProfileRules.toggle()
                                    }
                                } label: {
                                    Text(
                                        showsAllProfileRules
                                            ? String.localizedStringWithFormat(
                                                AppLocalization.string("Show first %lld rules"),
                                                Int64(summary.rules.count)
                                            )
                                            : String.localizedStringWithFormat(
                                                AppLocalization.string("Show all %lld rules"),
                                                Int64(summary.allRules.count)
                                            )
                                    )
                                    .font(.caption.weight(.medium))
                                }
                                .buttonStyle(.link)
                                .accessibilityIdentifier("rules-toggle-show-all")
                                Spacer()
                            }
                            .padding(.vertical, AetherVisual.s2)
                        }
                    }
                }
            }
            .aetherPanel()

            AetherFlowLayout(spacing: AetherVisual.s1) {
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

    @ViewBuilder
    private func actionFilter(summary: ProfileConfigurationSummary) -> some View {
        let items: [(filter: RuleActionFilter, title: String)] = RuleActionFilter.allCases.map { action in
            let count: Int = switch action {
            case .all: summary.ruleCount
            case .direct: summary.directRuleCount
            case .proxy: summary.proxyRuleCount
            case .reject: summary.rejectRuleCount
            }
            return (action, "\(action.shortTitle) \(count)")
        }
        if rulesFilterBarWidth > 0 && rulesFilterBarWidth < 520 {
            Picker(AppLocalization.string("Filter by target"), selection: $selectedAction) {
                ForEach(items, id: \.filter.id) { entry in
                    Text(verbatim: entry.title).tag(entry.filter)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(AppLocalization.string("Filter by target"))
            .accessibilityIdentifier("rules-action-filter")
        } else {
            AetherSegmentedPicker(
                selection: $selectedAction,
                options: items.map { .init(value: $0.filter, title: $0.title) },
                accessibilityLabel: AppLocalization.string("Filter by target"),
                accessibilityIdentifier: "rules-action-filter"
            )
            .fixedSize()
        }
    }

    private var rulesSearchField: some View {
        AetherSearchField(
            text: $searchText,
            prompt: AppLocalization.string("Search rules"),
            accessibilityIdentifier: "rules-search-field"
        )
    }

    private func filteredRules(from rules: [RuleConfigurationSummary]) -> [RuleConfigurationSummary] {
        if selectedAction == .all, searchText.isEmpty {
            return rules
        }
        let text = searchText.lowercased()
        return rules.filter { rule in
            guard selectedAction.accepts(rule.target) else { return false }
            if text.isEmpty { return true }
            if rule.kind.lowercased().contains(text) { return true }
            if let criteria = rule.criteria, criteria.lowercased().contains(text) { return true }
            if rule.target.lowercased().contains(text) { return true }
            if String(rule.order) == text { return true }
            return false
        }
    }
}

private struct RouteTesterCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let summary: ProfileConfigurationSummary
    let externalRequest: RouteTestRequest?
    let onLocateRule: (Int) -> Void

    @State private var testQuery: String = ""
    @State private var testResult: RouteMatchResult? = nil
    @State private var hasAttemptedMatch: Bool = false
    @State private var matchExplanation: String = ""
    @State private var lastConsumedRequestID: UUID? = nil

    var body: some View {
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
                    .onSubmit { performMatch() }
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
                    performMatch()
                }
                .aetherButton(prominent: true)
                .controlSize(.large)
                .disabled(testQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("rule-test-button")
            }

            if let result = testResult {
                AetherFlowLayout(spacing: AetherVisual.s2) {
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
                    Button {
                        onLocateRule(result.matchedRule.id)
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
                AetherFlowLayout(spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Try:"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    ForEach(["google.com", "apple.com", "github.com", "bilibili.com"], id: \.self) { domain in
                        Button(domain) {
                            testQuery = domain
                            performMatch()
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
        .onAppear { consumeExternalRequest() }
        .onChange(of: externalRequest) { _, _ in consumeExternalRequest() }
    }

    private func consumeExternalRequest() {
        guard let request = externalRequest, request.id != lastConsumedRequestID else { return }
        lastConsumedRequestID = request.id
        testQuery = request.query
        performMatch()
    }

    private func performMatch() {
        hasAttemptedMatch = true
        testResult = nil
        let customHosts = Dictionary(
            tunnel.activeProfileOverrides.customHosts
                .filter(\.isEnabled)
                .map { ($0.domain.lowercased(), $0.ip) },
            uniquingKeysWith: { _, last in last }
        )
        let assessment = Self.evaluateMatch(
            query: testQuery,
            rules: summary.allRules,
            totalRuleCount: summary.ruleCount,
            customHosts: customHosts,
            geoSiteData: tunnel.bundledGeoSiteData
        )
        switch assessment {
        case let .matched(result): testResult = result
        case let .indeterminate(ruleOrder?):
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

    static func evaluateMatch(
        query: String,
        rules: [RuleConfigurationSummary],
        totalRuleCount: Int,
        customHosts: [String: String],
        geoSiteData: Data?
    ) -> RouteMatchAssessment {
        var assessment = RouteMatchEngine.assess(
            destination: query,
            against: rules,
            totalRuleCount: totalRuleCount,
            geoSiteData: geoSiteData
        )
        if !customHosts.isEmpty {
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let resolvedHost = ProfileHostsInspector.resolveAlias(trimmedQuery, in: customHosts)
            if resolvedHost != trimmedQuery {
                let aliasAssessment = RouteMatchEngine.assess(
                    destination: resolvedHost,
                    against: rules,
                    totalRuleCount: totalRuleCount,
                    geoSiteData: geoSiteData
                )
                if case let .matched(aliasMatch) = aliasAssessment {
                    switch assessment {
                    case let .matched(directMatch) where aliasMatch.order < directMatch.order:
                        assessment = aliasAssessment
                    case .indeterminate, .noMatch:
                        assessment = aliasAssessment
                    default:
                        break
                    }
                }
            }
        }
        return assessment
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
    var overrideTargets: [CustomRuleTarget] = []
    var existingOverrideTarget: CustomRuleTarget? = nil
    let onTest: (String) -> Void
    var onOverride: ((CustomRuleTarget) -> Void)? = nil

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

            // Reserve the copy-button slot so hovering across rows never shifts criteria/target horizontally.
            AetherCopyButton(title: Text(AppLocalization.string("Copy Criteria"))) {
                copyText(rule.criteria ?? rule.kind)
            }
            .labelStyle(.iconOnly)
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .frame(width: AetherVisual.iconButtonSize, height: AetherVisual.iconButtonSize)
            .buttonStyle(.aetherPressable)
            .help(AppLocalization.string("Copy Criteria"))
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)

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

            if !overrideTargets.isEmpty, onOverride != nil {
                Divider()
                Menu {
                    ForEach(overrideTargets, id: \.rawString) { target in
                        Button {
                            onOverride?(target)
                        } label: {
                            if existingOverrideTarget == target {
                                Label(overrideTargetTitle(target), systemImage: "checkmark")
                            } else {
                                Text(overrideTargetTitle(target))
                            }
                        }
                    }
                } label: {
                    Label(AppLocalization.string("Override with Custom Rule"), systemImage: "arrow.triangle.branch")
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: AppLocalization.string("Copy Criteria")) {
            copyText(rule.criteria ?? rule.kind)
        }
        .accessibilityAction(named: AppLocalization.string("Copy Full Rule")) {
            let line = "\(rule.kind),\(rule.criteria.map { $0 + "," } ?? "")\(rule.target)"
            copyText(line)
        }
        .accessibilityAction(named: AppLocalization.string("Copy Target Name")) {
            copyText(rule.target)
        }
        .accessibilityAction(named: AppLocalization.string("Test This Destination")) {
            if let criteria = rule.criteria {
                onTest(criteria)
            }
        }
    }

    private func overrideTargetTitle(_ target: CustomRuleTarget) -> String {
        switch target {
        case .direct: AppLocalization.string("Always connect directly")
        case .reject: AppLocalization.string("Always block")
        case let .proxy(group): AppLocalization.format("Always use %@", group)
        }
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
    var onMoveToTop: (() -> Void)? = nil
    var onMoveToBottom: (() -> Void)? = nil
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
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
                }
            }
            // The value is what the row is about; the target label and the
            // five buttons gave it up first, leaving "signup…" beside a gap.
            // The minimum keeps a fragment visible in the narrowest window.
            .frame(minWidth: 72, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: AetherVisual.s2)

            RuleTargetLabel(target: rule.target.rawString)
                .frame(maxWidth: 160, alignment: .trailing)
                .opacity(isHovered ? 0 : 1)
                .accessibilityHidden(isHovered)
        }
        .overlay(alignment: .trailing) {
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
            .padding(.horizontal, AetherVisual.s1)
            .padding(.vertical, AetherVisual.sMicro)
            .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
            .background(AetherVisual.cardFill, in: Capsule())
            .overlay {
                Capsule().strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
            }
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
            .accessibilityHidden(!isHovered)
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
            if let onMoveToTop, canMoveUp {
                Button {
                    onMoveToTop()
                } label: {
                    Label(AppLocalization.string("Move to Top"), systemImage: "arrow.up.to.line")
                }
            }
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
            if let onMoveToBottom, canMoveDown {
                Button {
                    onMoveToBottom()
                } label: {
                    Label(AppLocalization.string("Move to Bottom"), systemImage: "arrow.down.to.line")
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
        .accessibilityAction(named: AppLocalization.string("Verify rule")) {
            onTest()
        }
        .accessibilityAction(named: AppLocalization.string("Edit rule")) {
            onEdit()
        }
        .accessibilityAction(named: AppLocalization.string("Delete rule")) {
            onDelete()
        }
        .accessibilityAction(named: AppLocalization.string("Move rule up")) {
            if canMoveUp { onMoveUp?() }
        }
        .accessibilityAction(named: AppLocalization.string("Move rule down")) {
            if canMoveDown { onMoveDown?() }
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
                        if selectedKind == .network {
                            AetherSegmentedPicker(
                                selection: Binding(
                                    get: {
                                        let upper = ruleValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                        return upper == "TCP" ? "TCP" : "UDP"
                                    },
                                    set: { ruleValue = $0 }
                                ),
                                options: [
                                    .init(value: "UDP", title: "UDP"),
                                    .init(value: "TCP", title: "TCP"),
                                ],
                                accessibilityLabel: AppLocalization.string("Transport protocol"),
                                accessibilityIdentifier: "custom-rule-network-picker"
                            )
                            .fixedSize()
                            .onAppear {
                                let upper = ruleValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                                if upper != "TCP" && upper != "UDP" {
                                    ruleValue = "UDP"
                                }
                            }
                        } else {
                            TextField(placeholderForKind(selectedKind), text: $ruleValue)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                                .accessibilityIdentifier("custom-rule-value-field")
                        }
                    }
                    if selectedKind == .ipCIDR
                        || selectedKind == .ipCIDR6
                        || selectedKind == .geoIP
                        || selectedKind == .ipASN {
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
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 280)
                        }
                        .transition(.opacity)
                    }
                    ruleDivider
                    ruleRow(AppLocalization.string("Note")) {
                        TextField(AppLocalization.string("Optional, e.g. Tailscale node / local service"), text: $comment)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
                    }
                } else {
                    ruleRow(AppLocalization.string("Rule")) {
                        TextField(
                            AppLocalization.string("e.g. DOMAIN-SUFFIX,example.com,DIRECT or IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"),
                            text: $rawClashString,
                            axis: initialRule == nil ? .vertical : .horizontal
                        )
                        .lineLimit(initialRule == nil ? 1...5 : 1...1)
                        .textFieldStyle(.roundedBorder)
                        .font(.body.monospaced())
                        .frame(maxWidth: 300)
                        .padding(.vertical, AetherVisual.s2)
                        .accessibilityIdentifier("custom-rule-raw-field")
                    }
                    ruleDivider
                    ruleRow(AppLocalization.string("Note")) {
                        TextField(AppLocalization.string("Optional, e.g. Direct private subnet"), text: $comment)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 280)
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
        case .domainWildcard: AppLocalization.string("e.g. *.dev.local or api-?.example.com")
        case .domainRegex: AppLocalization.string("e.g. ^api-\\d{1,3}\\.example\\.com$")
        case .ipCIDR: AppLocalization.string("e.g. 100.64.0.0/10 or 192.168.1.0/24")
        case .ipCIDR6: AppLocalization.string("e.g. fd7a:115c:a1e0::/48")
        case .geoIP: AppLocalization.string("e.g. CN or US")
        case .geoSite: AppLocalization.string("e.g. openai, apple, cn or netflix")
        case .ipASN: AppLocalization.string("e.g. 13335 or AS15169")
        case .dstPort: AppLocalization.string("e.g. 443, 80 or 853")
        case .network: AppLocalization.string("TCP or UDP")
        case .processName: AppLocalization.string("e.g. curl, ssh or node")
        case .processPath: AppLocalization.string("e.g. /usr/bin/curl")
        case .and: AppLocalization.string("e.g. ((NETWORK,UDP),(DST-PORT,443))")
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
            isCustom: true,
            noResolve: rule.noResolve
        )

        let existingRules = tunnel.activeProfileSummary?.allRules ?? []
        let simulatedList = [ruleSummary] + existingRules

        let destination: String
        switch rule.kind {
        case .domain, .domainSuffix:
            destination = rule.value
        case .domainKeyword:
            destination = "service.\(rule.value).com"
        case .domainWildcard:
            let sample = rule.value
                .replacingOccurrences(of: "*.", with: "sub.")
                .replacingOccurrences(of: "*", with: "demo")
                .replacingOccurrences(of: "?", with: "1")
            destination = sample
        case .domainRegex:
            testExplanation = AppLocalization.string("Regex syntax verified; evaluated against each requested hostname at connection time.")
            return
        case .ipCIDR:
            let ipPart = rule.value.split(separator: "/").first.map(String.init) ?? rule.value
            destination = ipPart
        case .ipCIDR6:
            let ipPart = rule.value.split(separator: "/").first.map(String.init) ?? rule.value
            destination = ipPart
        case .geoIP:
            destination = rule.value.lowercased() == "private" ? "192.168.1.1" : "223.5.5.5"
        case .geoSite:
            destination = "example.com"
        case .ipASN:
            testExplanation = AppLocalization.string("ASN rule syntax verified; evaluated at runtime against ASN.mmdb.")
            return
        case .dstPort:
            destination = "example.com:\(rule.value)"
        case .network, .and:
            testExplanation = AppLocalization.string("Transport/composite rule syntax verified; evaluated by the core router on live connections.")
            return
        case .processName, .processPath:
            testExplanation = AppLocalization.string("Process rules match the originating local binary or process name at connection time.")
            return
        case .application:
            // Matched by the connecting app, not a destination.
            testExplanation = AppLocalization.string("Application rules match the app that opens a connection, so they cannot be tested by destination.")
            return
        }

        switch RouteMatchEngine.assess(
            destination: destination,
            against: simulatedList,
            totalRuleCount: simulatedList.count,
            geoSiteData: tunnel.bundledGeoSiteData
        ) {
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

private struct CustomRuleProviderRow: View {
    let provider: RuleProviderMetadata
    let isRefreshing: Bool
    let onToggle: () -> Void
    let onRefresh: () -> Void
    let onPreview: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Toggle(
                AppLocalization.string("Enabled"),
                isOn: Binding(
                    get: { provider.isEnabled },
                    set: { _ in onToggle() }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(
                String.localizedStringWithFormat(
                    AppLocalization.string("Enable rule set %@"),
                    provider.name
                )
            )

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(provider.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(
                            provider.isEnabled
                                ? AnyShapeStyle(.primary)
                                : AnyShapeStyle(AetherVisual.secondaryText)
                        )
                    RuleKindTag(kind: provider.behavior.rawValue)
                    RuleKindTag(kind: provider.format.rawValue)
                }
                Text(subtitle)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
            }

            Spacer(minLength: AetherVisual.s2)

            RuleTargetLabel(target: provider.defaultTarget)
                .opacity(provider.isEnabled ? 1.0 : 0.6)

            HStack(spacing: AetherVisual.s1) {
                Button(action: onPreview) {
                    Image(systemName: "magnifyingglass")
                }
                .aetherButton()
                .controlSize(.small)
                .help(AppLocalization.string("Preview rules"))
                .accessibilityLabel(AppLocalization.string("Preview rules"))

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(isRefreshing)
                .help(AppLocalization.string("Update rule set"))
                .accessibilityLabel(AppLocalization.string("Update rule set"))

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .aetherButton()
                .controlSize(.small)
                .help(AppLocalization.string("Edit"))
                .accessibilityLabel(AppLocalization.string("Edit"))

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .aetherButton()
                .controlSize(.small)
                .help(AppLocalization.string("Delete"))
                .accessibilityLabel(AppLocalization.string("Delete"))
            }
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .contextMenu {
            Button(AppLocalization.string("Preview rules"), action: onPreview)
            Button(AppLocalization.string("Update rule set"), action: onRefresh)
            Button(AppLocalization.string("Edit"), action: onEdit)
            Divider()
            Button(AppLocalization.string("Delete"), role: .destructive, action: onDelete)
        }
    }

    private var subtitle: String {
        var parts = [
            String.localizedStringWithFormat(
                AppLocalization.string("%lld rules"),
                Int64(provider.ruleCount)
            ),
        ]
        if let updatedAt = provider.lastUpdatedAt {
            parts.append(
                String.localizedStringWithFormat(
                    AppLocalization.string("Updated %@"),
                    updatedAt.formatted(date: .abbreviated, time: .shortened)
                )
            )
        } else {
            parts.append(AppLocalization.string("Not updated yet"))
        }
        if let host = provider.url.host, !host.isEmpty {
            parts.append(host)
        }
        return parts.joined(separator: " · ")
    }
}

private struct RuleProviderEditorSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    let initialProvider: RuleProviderMetadata?
    let onSave: (RuleProviderMetadata) async -> Bool

    @State private var name: String = ""
    @State private var urlString: String = ""
    @State private var behavior: RuleProviderBehavior = .domain
    @State private var format: RuleProviderFormat = .text
    @State private var defaultTarget: String = "PROXY"
    @State private var intervalHours: Int = 24
    @State private var isSaving: Bool = false
    @State private var requestsCancel: Bool = false
    @State private var errorMessage: String?

    private var hasChanges: Bool {
        if let initialProvider {
            let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            let initialHours = max(1, Int(initialProvider.intervalSeconds / 3_600))
            return trimmedName != initialProvider.name
                || trimmedURL != initialProvider.url.absoluteString
                || behavior != initialProvider.behavior
                || format != initialProvider.format
                || defaultTarget != initialProvider.defaultTarget
                || intervalHours != initialHours
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !urlString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || behavior != .domain
            || format != .text
            || defaultTarget != "PROXY"
            || intervalHours != 24
    }

    init(
        initialProvider: RuleProviderMetadata?,
        onSave: @escaping (RuleProviderMetadata) async -> Bool
    ) {
        self.initialProvider = initialProvider
        self.onSave = onSave
        if let initialProvider {
            _name = State(initialValue: initialProvider.name)
            _urlString = State(initialValue: initialProvider.url.absoluteString)
            _behavior = State(initialValue: initialProvider.behavior)
            _format = State(initialValue: initialProvider.format)
            _defaultTarget = State(initialValue: initialProvider.defaultTarget)
            _intervalHours = State(initialValue: max(1, Int(initialProvider.intervalSeconds / 3_600)))
        }
    }

    private var availableTargets: [String] {
        let groups = (tunnel.activeProfileSummary?.proxyGroups ?? []).map(\.name)
        var list = ["DIRECT", "REJECT"]
        for group in groups where !list.contains(group) {
            list.append(group)
        }
        if !list.contains("PROXY") {
            list.insert("PROXY", at: 1)
        }
        if !defaultTarget.isEmpty, !list.contains(defaultTarget) {
            list.append(defaultTarget)
        }
        return list
    }

    private var isValid: Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty,
              let url = URL(string: trimmedURL),
              url.scheme?.lowercased() == "https",
              url.host != nil
        else { return false }
        return true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AetherSheetHeader(
                symbol: "shippingbox.fill",
                title: initialProvider == nil
                    ? AppLocalization.string("Add Rule Set")
                    : AppLocalization.string("Edit Rule Set"),
                subtitle: AppLocalization.string("Subscribe to an HTTPS rule provider list."),
                tint: AppSection.rules.tileColor
            )
            .padding([.horizontal, .top], AetherVisual.dialogPadding)

            Form {
                Section {
                    TextField(AppLocalization.string("Name"), text: $name)
                        .accessibilityIdentifier("rule-provider-name-field")
                    TextField(AppLocalization.string("HTTPS URL"), text: $urlString)
                        .font(.body.monospaced())
                        .accessibilityIdentifier("rule-provider-url-field")
                    Picker(AppLocalization.string("Behavior"), selection: $behavior) {
                        Text(AppLocalization.string("Domain")).tag(RuleProviderBehavior.domain)
                        Text(AppLocalization.string("IP-CIDR")).tag(RuleProviderBehavior.ipcidr)
                        Text(AppLocalization.string("Classical")).tag(RuleProviderBehavior.classical)
                    }
                    Picker(AppLocalization.string("Format"), selection: $format) {
                        Text(verbatim: "Text").tag(RuleProviderFormat.text)
                        Text(verbatim: "YAML").tag(RuleProviderFormat.yaml)
                    }
                    Picker(AppLocalization.string("Target"), selection: $defaultTarget) {
                        ForEach(availableTargets, id: \.self) { target in
                            Text(verbatim: target).tag(target)
                        }
                    }
                    Picker(AppLocalization.string("Update interval"), selection: $intervalHours) {
                        Text(AppLocalization.string("6 hours")).tag(6)
                        Text(AppLocalization.string("12 hours")).tag(12)
                        Text(AppLocalization.string("24 hours")).tag(24)
                        Text(AppLocalization.string("72 hours")).tag(72)
                    }
                }
            }
            .aetherSettingsForm(isSheet: true)
            .frame(
                minHeight: AetherVisual.sheetFormMinHeight,
                idealHeight: AetherVisual.sheetFormIdealHeight,
                maxHeight: AetherVisual.sheetFormMaxHeight
            )

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                if let errorMessage {
                    AetherInlineMessage(text: errorMessage, kind: .warning)
                }

                HStack(spacing: AetherVisual.s2) {
                    Spacer()
                    Button(AppLocalization.string("Cancel"), role: .cancel) {
                        requestsCancel = true
                    }
                    .aetherButton()
                    .controlSize(.large)
                    .disabled(isSaving)
                    .keyboardShortcut(.cancelAction)

                    Button {
                        save()
                    } label: {
                        AetherProgressButtonLabel(AppLocalization.string("Save"), isWorking: isSaving)
                    }
                    .aetherButton(prominent: true)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
                    .accessibilityIdentifier("save-rule-provider-button")
                }
            }
            .padding([.horizontal, .bottom], AetherVisual.dialogPadding)
        }
        .aetherSheetFrame()
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURL = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmedURL), url.scheme?.lowercased() == "https" else {
            errorMessage = RuleProviderError.insecureScheme.localizedDescription
            return
        }
        isSaving = true
        errorMessage = nil
        let clampedHours = max(1, intervalHours)
        let (rawIntervalSeconds, overflow) = clampedHours.multipliedReportingOverflow(by: 3_600)
        let safeIntervalSeconds: UInt32 = overflow
            ? UInt32.max
            : RuleProviderEngine.sanitizedIntervalSeconds(rawIntervalSeconds)
        let provider = RuleProviderMetadata(
            id: initialProvider?.id ?? UUID(),
            name: trimmedName,
            url: url,
            behavior: behavior,
            format: format,
            defaultTarget: defaultTarget,
            isEnabled: initialProvider?.isEnabled ?? true,
            intervalSeconds: safeIntervalSeconds,
            lastUpdatedAt: initialProvider?.lastUpdatedAt,
            ruleCount: initialProvider?.ruleCount ?? 0,
            etag: initialProvider?.etag,
            sha256: initialProvider?.sha256
        )
        Task {
            let ok = await onSave(provider)
            isSaving = false
            if ok {
                dismiss()
            } else {
                errorMessage = tunnel.ruleProviderMessage
            }
        }
    }
}

private struct RuleProviderPreviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    let provider: RuleProviderMetadata
    let onTestSample: (String) -> Void

    @State private var query: String = ""
    @State private var items: [RemoteRuleItem] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            AetherSheetHeader(
                symbol: "list.bullet.rectangle",
                title: provider.name,
                subtitle: String.localizedStringWithFormat(
                    AppLocalization.string("%lld cached rules · showing up to 200 matches"),
                    Int64(provider.ruleCount)
                ),
                tint: AppSection.rules.tileColor
            )

            AetherSearchField(
                text: $query,
                prompt: AppLocalization.string("Search rules in this set"),
                accessibilityIdentifier: "rule-provider-preview-search"
            )

            if items.isEmpty {
                ContentUnavailableView(
                    AppLocalization.string("No matching rules"),
                    systemImage: "magnifyingglass",
                    description: Text(AppLocalization.string("Update the rule set or try another search keyword."))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .aetherPanel()
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            HStack(spacing: AetherVisual.s2) {
                                RuleKindTag(kind: item.type)
                                Text(verbatim: item.payload)
                                    .font(.body.monospaced())
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: AetherVisual.s2)
                                RuleTargetLabel(
                                    target: item.target.isEmpty ? provider.defaultTarget : item.target
                                )
                                Button(AppLocalization.string("Test")) {
                                    let sample = item.payload.split(separator: "/").first.map(String.init) ?? item.payload
                                    onTestSample(sample)
                                    dismiss()
                                }
                                .aetherButton()
                                .controlSize(.small)
                            }
                            .padding(.horizontal, AetherVisual.s3)
                            .padding(.vertical, AetherVisual.s2)
                            if index < items.count - 1 {
                                Divider().padding(.leading, AetherVisual.s3)
                            }
                        }
                    }
                }
                .frame(
                    minHeight: AetherVisual.sheetFormMinHeight,
                    idealHeight: AetherVisual.sheetFormIdealHeight,
                    maxHeight: AetherVisual.sheetFormMaxHeight
                )
                .aetherPanel()
            }

            HStack {
                Spacer()
                Button(AppLocalization.string("Done")) {
                    dismiss()
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .task(id: query) {
            items = (try? await RuleProviderEngine.shared.searchRules(
                for: provider.id,
                query: query,
                limit: 200
            )) ?? []
        }
    }
}

private struct RoutingResourceMirrorSettingsCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let importResource: (RoutingResourceKind) -> Void

    @State private var isExpanded = false
    @State private var resourceURLStrings: [RoutingResourceKind: String] = [:]
    @State private var checksumURLStrings: [RoutingResourceKind: String] = [:]
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var busyKinds: Set<RoutingResourceKind> = []

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("Database Mirrors & ASN.mmdb"),
                note: AppLocalization.string("Customize HTTPS mirror URLs for Country.mmdb, GeoSite.dat, and ASN.mmdb")
            ) {
                Button {
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Label(
                        isExpanded
                            ? AppLocalization.string("Hide")
                            : AppLocalization.string("Configure"),
                        systemImage: isExpanded ? "chevron.up" : "slider.horizontal.3"
                    )
                }
                .aetherButton()
                .controlSize(.small)
                .accessibilityIdentifier("routing-resource-mirrors-toggle")
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    if let statusMessage {
                        Label(
                            statusMessage,
                            systemImage: statusIsError
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            statusIsError
                                ? AnyShapeStyle(AetherReadableTint(color: .red))
                                : AnyShapeStyle(AetherVisual.secondaryText)
                        )
                    }

                    ForEach(RoutingResourceKind.allCases, id: \.self) { kind in
                        mirrorRow(for: kind)
                        if kind != RoutingResourceKind.allCases.last {
                            Divider()
                        }
                    }
                }
                .padding(AetherVisual.s4)
                .aetherPanel()
                .transition(.opacity)
            }
        }
        .onAppear { loadCurrentMirrors() }
        .accessibilityIdentifier("routing-resource-mirrors-card")
    }

    @ViewBuilder
    private func mirrorRow(for kind: RoutingResourceKind) -> some View {
        let isBusy = busyKinds.contains(kind)
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s2) {
                Text(verbatim: kind.fileName)
                    .font(.callout.weight(.semibold))
                Spacer(minLength: AetherVisual.s2)
                Button(AppLocalization.string("Import…")) {
                    importResource(kind)
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(!tunnel.canModifyProfiles || isBusy)

                Button(AppLocalization.string("Reset")) {
                    resetMirror(for: kind)
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(isBusy)

                Button(AppLocalization.string("Save & Download")) {
                    saveAndDownloadMirror(for: kind)
                }
                .aetherButton(prominent: true)
                .controlSize(.small)
                .disabled(isBusy)
            }

            TextField(
                AppLocalization.string("HTTPS database URL"),
                text: Binding(
                    get: { resourceURLStrings[kind] ?? defaultResourceURLString(for: kind) },
                    set: { resourceURLStrings[kind] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())

            TextField(
                AppLocalization.string("Optional HTTPS .sha256sum URL (defaults to <URL>.sha256sum)"),
                text: Binding(
                    get: { checksumURLStrings[kind] ?? "" },
                    set: { checksumURLStrings[kind] = $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .font(.caption.monospaced())
        }
    }

    private func defaultResourceURLString(for kind: RoutingResourceKind) -> String {
        (try? RoutingResourceRemoteDescriptor.maintainedDefault(for: kind).resourceURL.absoluteString) ?? ""
    }

    private func loadCurrentMirrors() {
        guard let store = try? tunnel.routingResourceStoreFactory() else { return }
        for kind in RoutingResourceKind.allCases {
            if let custom = store.customMirrorDescriptor(for: kind) {
                resourceURLStrings[kind] = custom.resourceURL.absoluteString
                checksumURLStrings[kind] = custom.checksumURL.absoluteString
            } else {
                resourceURLStrings[kind] = defaultResourceURLString(for: kind)
                checksumURLStrings[kind] = ""
            }
        }
    }

    private func resetMirror(for kind: RoutingResourceKind) {
        statusMessage = nil
        do {
            let store = try tunnel.routingResourceStoreFactory()
            try store.clearCustomMirrorURLs(for: kind)
            resourceURLStrings[kind] = defaultResourceURLString(for: kind)
            checksumURLStrings[kind] = ""
            statusMessage = AppLocalization.format(
                "Reset %@ to the maintained default URL.",
                kind.fileName
            )
            statusIsError = false
        } catch {
            statusMessage = error.localizedDescription
            statusIsError = true
        }
    }

    private func saveAndDownloadMirror(for kind: RoutingResourceKind) {
        let rawResource = (resourceURLStrings[kind] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let resourceURL = URL(string: rawResource) else {
            statusMessage = RoutingResourceError.invalidRemoteURL.localizedDescription
            statusIsError = true
            return
        }
        let rawChecksum = (checksumURLStrings[kind] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let checksumURL: URL? = rawChecksum.isEmpty ? nil : URL(string: rawChecksum)
        if !rawChecksum.isEmpty && checksumURL == nil {
            statusMessage = RoutingResourceError.invalidRemoteURL.localizedDescription
            statusIsError = true
            return
        }

        busyKinds.insert(kind)
        statusMessage = nil
        let storeFactory = tunnel.routingResourceStoreFactory
        let downloadClient = tunnel.routingResourceDownloadClient
        Task {
            defer { busyKinds.remove(kind) }
            do {
                try await Task.detached(priority: .userInitiated) {
                    let store = try storeFactory()
                    try store.setCustomMirrorURLs(
                        for: kind,
                        resourceURL: resourceURL,
                        checksumURL: checksumURL
                    )
                    let descriptor = try RoutingResourceRemoteDescriptor.resolved(
                        for: kind,
                        in: store
                    )
                    _ = try await downloadClient.downloadAndInstall(descriptor, into: store)
                }.value
                tunnel.refreshRoutingResourceStatuses()
                statusMessage = AppLocalization.format(
                    "Updated %@ from the configured mirror.",
                    kind.fileName
                )
                statusIsError = false
            } catch {
                statusMessage = error.localizedDescription
                statusIsError = true
            }
        }
    }
}

import AetherRouteKit
import SwiftUI

/// Choosing a node and testing latency, nothing else: the groups beside the
/// nodes of the chosen one. Inventory and provider details for
/// troubleshooting live in Settings › Privacy & Diagnostics.
///
/// The page itself does not scroll (2.10): the group column and the node
/// list scroll on their own, so the group's header, search, sort and
/// latency test stay in view however long a subscription is.
private enum ProxiesOverrideSheet: Identifiable {
    case newGroup(defaultParent: String?)
    case chainedProxy(defaultParent: String?)
    case regionGroups(defaultParent: String?)
    case hiddenNodes
    case editCustomGroup(CustomProxyGroup)
    case editChainedProxy(ChainedProxyOverride)

    var id: String {
        switch self {
        case .newGroup: "new-group"
        case .chainedProxy: "chained-proxy"
        case .regionGroups: "region-groups"
        case .hiddenNodes: "hidden-nodes"
        case let .editCustomGroup(group): "edit-custom-group-\(group.id)"
        case let .editChainedProxy(chain): "edit-chained-proxy-\(chain.id)"
        }
    }
}

struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    /// By name rather than summary id: the synthetic GLOBAL group shown in
    /// global mode is not part of the profile summary.
    @State private var selectedGroupName: String?
    @State private var activeOverrideSheet: ProxiesOverrideSheet?
    /// Kept here rather than in the group card so switching groups keeps
    /// the search, the sort and the filter.
    @State private var sort: ProxyNodeSort = .default
    @State private var searchText = ""
    @State private var hidesTimedOutNodes = false
    @State private var filtersAIAvailableOnly = false
    @State private var pageWidth: CGFloat? = nil
    @State private var cachedSummary: ProfileConfigurationSummary? = nil
    @State private var cachedInventory: ProxyInventoryIndex = .empty
    @AppStorage("aetherroute.proxies.gridLayout") private var usesGridLayout = false
    @AppStorage("aetherroute.proxies.showsSubscriptionNotices") private var showsSubscriptionNotices = false

    var body: some View {
        Group {
            if tunnel.activeProfile != nil,
               let summary = tunnel.activeProfileSummary {
                content(summary: summary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                        AetherPageHeader(.proxies)
                        ContentUnavailableView {
                            Label(
                                AppLocalization.string("No proxies yet"),
                                systemImage: "point.3.connected.trianglepath.dotted"
                            )
                        } description: {
                            Text(AppLocalization.string("Import a validated profile to inspect its endpoints and proxy groups."))
                        } actions: {
                            Button(AppLocalization.string("Go to Profiles")) {
                                NotificationCenter.default.post(
                                    name: .aetherRouteNavigateToSection,
                                    object: AppSection.profiles.rawValue
                                )
                            }
                            .aetherButton(prominent: true)
                            .accessibilityIdentifier("proxies-go-to-profiles")
                        }
                        .frame(maxWidth: .infinity, minHeight: AetherVisual.emptyStateMinHeight)
                        .aetherPanel()
                    }
                    .aetherPageContent(.wide)
                }
            }
        }
        .accessibilityIdentifier("proxies-page")
        .onChange(of: tunnel.activeProfileID) { _, _ in
            activeOverrideSheet = nil
            selectedGroupName = nil
            searchText = ""
            filtersAIAvailableOnly = false
            hidesTimedOutNodes = false
            sort = .default
            cachedSummary = nil
            cachedInventory = .empty
        }
        .onChange(of: tunnel.effectiveRoutingMode) { _, mode in
            if mode == .global, let global = tunnel.globalProxyGroup {
                selectedGroupName = global.name
            } else if mode != .global, selectedGroupName == "GLOBAL" {
                selectedGroupName = nil
            }
        }
        .sheet(item: $activeOverrideSheet) { sheet in
            switch sheet {
            case let .newGroup(defaultParent):
                CustomProxyGroupSheet(defaultParent: defaultParent) { savedName in
                    if let savedName {
                        selectedGroupName = savedName
                    }
                }
            case let .chainedProxy(defaultParent):
                ChainedProxySheet(defaultParent: defaultParent)
            case let .regionGroups(defaultParent):
                RegionGroupsSheet(defaultParent: defaultParent)
            case .hiddenNodes:
                HiddenNodesSheet()
            case let .editCustomGroup(group):
                CustomProxyGroupSheet(initial: group) { savedName in
                    selectedGroupName = savedName
                }
            case let .editChainedProxy(chain):
                ChainedProxySheet(initial: chain)
            }
        }
#if DEBUG
        .task {
            // Isolated screenshot review only: open one sheet on launch.
            let defaultParent = tunnel.activeProfileSummary.flatMap { catchAllGroup(in: $0) }
            switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_SHEET"] {
            case "new-group": activeOverrideSheet = .newGroup(defaultParent: defaultParent)
            case "region-groups": activeOverrideSheet = .regionGroups(defaultParent: defaultParent)
            case "hidden-nodes": activeOverrideSheet = .hiddenNodes
            case "chained-proxy": activeOverrideSheet = .chainedProxy(defaultParent: defaultParent)
            default: break
            }
        }
#endif
    }

    private func content(summary: ProfileConfigurationSummary) -> some View {
        let measuredWidth = pageWidth ?? 700
        let isWideGroupLayout = measuredWidth >= Self.wideGroupLayoutWidth
        return groupsAndCard(
            summary: summary,
            isWideGroupLayout: isWideGroupLayout,
            pageWidth: measuredWidth
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            guard newWidth > 0 else { return }
            if let existing = pageWidth {
                let wasWide = existing >= Self.wideGroupLayoutWidth
                let isWide = newWidth >= Self.wideGroupLayoutWidth
                if isWide != wasWide {
                    withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) {
                        pageWidth = newWidth
                    }
                } else if abs(existing - newWidth) >= 2 {
                    pageWidth = newWidth
                }
            } else {
                pageWidth = newWidth
            }
        }
        .onAppear { refreshInventoryIfNeeded(for: summary) }
        .onChange(of: summary) { _, updated in
            refreshInventoryIfNeeded(for: updated)
        }
    }

    private func refreshInventoryIfNeeded(for summary: ProfileConfigurationSummary) {
        guard cachedSummary != summary else { return }
        cachedSummary = summary
        cachedInventory = ProxyInventoryIndex.build(from: summary)
    }

    private func groupsAndCard(
        summary: ProfileConfigurationSummary,
        isWideGroupLayout: Bool,
        pageWidth: CGFloat
    ) -> some View {
        let groups = displayedGroups(summary: summary)
        let usesWideSplit = groups.count > 1 && isWideGroupLayout
        return VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
            AetherPageHeader(.proxies) { overrideActions(in: summary) }
            ProfileCompatibilityNotice(report: summary.compatibility)
            if let notice = summary.subscriptionNotice {
                ProxySubscriptionNoticeBar(notice: notice)
            }
            routingModeBanner

            if !groups.isEmpty {
                ProxyGroupsAdaptiveLayout(
                    isSideBySide: usesWideSplit,
                    sidebarWidth: Self.groupColumnWidth(for: pageWidth),
                    spacing: usesWideSplit ? AetherVisual.s4 : AetherVisual.sectionSpacing
                ) {
                    if usesWideSplit {
                        proxyGroupColumn(groups: groups, summary: summary)
                    } else {
                        // One group needs no switcher; the card names it.
                        HStack(spacing: AetherVisual.s2) {
                            if groups.count > 1 {
                                proxyGroupTabBar(groups: groups, summary: summary)
                            }
                            Spacer(minLength: 0)
                            newGroupButton(in: summary)
                        }
                    }

                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        if usesWideSplit {
                            AetherSectionHeader(
                                title: AppLocalization.string("Nodes"),
                                count: activeGroupMemberCount(from: groups, summary: summary)
                            )
                            .frame(minHeight: AetherVisual.s5)
                        }
                        activeGroupView(summary: summary, groups: groups)
                            .frame(maxHeight: .infinity, alignment: .top)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                }
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                HStack(spacing: AetherVisual.s2) {
                    Spacer(minLength: 0)
                    newGroupButton(in: summary)
                }
            }

            if summary.proxyCount == 0,
               summary.proxyGroupCount == 0,
               summary.proxyProviderCount == 0 {
                FeatureEmptyState(
                    symbol: "point.3.connected.trianglepath.dotted",
                    title: AppLocalization.string("No proxy definitions"),
                    detail: AppLocalization.string("The active profile passed import checks but does not expose inline endpoints, groups, or providers.")
                )
                Spacer(minLength: 0)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        // Not in the shared page glass container: on macOS 27 it kept the
        // click areas of glass panels that had moved or gone (layout
        // switches, a new group card), and those swallowed clicks on the
        // groups, so often only one group could be chosen.
        .aetherPageContent(.wide, sharesGlassContainer: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Proxy configuration"))
        .accessibilityIdentifier("proxies-page-content")
    }

    @ViewBuilder
    private var routingModeBanner: some View {
        switch tunnel.effectiveRoutingMode {
        case .direct:
            Label {
                Text(AppLocalization.string("Direct mode is active. All traffic connects directly without using proxy groups."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "arrow.forward.circle")
                    .foregroundStyle(AetherReadableTint(color: .orange))
            }
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(AetherVisual.tintFill(.orange), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("proxies-direct-mode-banner")
        case .global:
            Label {
                Text(AppLocalization.string("Global mode is active. All traffic routes through the GLOBAL exit group."))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "globe")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s2)
            .background(AetherVisual.subtleFill, in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("proxies-global-mode-banner")
        case .rule:
            EmptyView()
        }
    }

    /// The profile's groups, with GLOBAL first while global mode routes
    /// every connection through it.
    private func displayedGroups(summary: ProfileConfigurationSummary) -> [ProxyGroupConfigurationSummary] {
        guard tunnel.effectiveRoutingMode == .global,
              let global = tunnel.globalProxyGroup else {
            return summary.proxyGroups
        }
        return [global] + summary.proxyGroups.filter { $0.name != global.name }
    }

    private func catchAllGroup(in summary: ProfileConfigurationSummary) -> String? {
        let excludedParentGroups = Set(tunnel.activeProfileOverrides.groups.map(\.name))
            .union(tunnel.standaloneChainedProxyGroupName.map { [$0] } ?? [])
        return ProfileOverrideSuggestions.defaultParentGroup(
            in: summary,
            excluding: excludedParentGroups
        )
    }

    /// New groups and hidden nodes change only this app's view of the
    /// profile (1.7.0); the subscription is never edited. Creating a group
    /// is a side task, so it is a light "+" rather than the page's main
    /// button.
    private func newGroupButton(in summary: ProfileConfigurationSummary) -> some View {
        Button {
            activeOverrideSheet = .newGroup(defaultParent: catchAllGroup(in: summary))
        } label: {
            Image(systemName: "plus")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .disabled(!canEditOverrides)
        .help(AppLocalization.string("New Group"))
        .accessibilityLabel(AppLocalization.string("New Group"))
        .accessibilityIdentifier("proxies-new-group")
    }

    @ViewBuilder
    private func overrideActions(in summary: ProfileConfigurationSummary) -> some View {
        Menu {
            Button(AppLocalization.string("New Group") + "…", systemImage: "plus.rectangle.on.folder") {
                activeOverrideSheet = .newGroup(defaultParent: catchAllGroup(in: summary))
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-more-new-group")
            Divider()
            Button(AppLocalization.string("Chained Proxy…"), systemImage: "link.badge.plus") {
                activeOverrideSheet = .chainedProxy(defaultParent: catchAllGroup(in: summary))
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-chained-proxy")
            Button(AppLocalization.string("Groups by Region…"), systemImage: "globe.asia.australia") {
                activeOverrideSheet = .regionGroups(defaultParent: catchAllGroup(in: summary))
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-region-groups")
            Button(AppLocalization.string("Hide Nodes…"), systemImage: "eye.slash") {
                activeOverrideSheet = .hiddenNodes
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-hidden-nodes")
            Divider()
            Toggle(
                AppLocalization.string("Show subscription info entries"),
                isOn: $showsSubscriptionNotices
            )
            .accessibilityIdentifier("proxies-show-subscription-notices")
        } label: {
            Label(AppLocalization.string("More"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .aetherButton()
        .fixedSize()
        .accessibilityIdentifier("proxies-more-menu")
    }

    /// Overrides can change while connected (the running profile reloads),
    /// but not in the middle of a connect, engine switch, or privacy gate.
    private var canEditOverrides: Bool {
        tunnel.hasAcceptedPrivacyDisclosure
            && !tunnel.isTransitioning
            && !tunnel.isSwitchingNetworkEngine
            && !tunnel.isUpdatingProfiles
            && !tunnel.isRefreshingSubscription
    }

    nonisolated private static let wideGroupLayoutWidth: CGFloat = 560
    private static func groupColumnWidth(for pageWidth: CGFloat) -> CGFloat {
        min(236, max(204, floor(pageWidth * 0.32)))
    }

    private func activeGroupMemberCount(
        from groups: [ProxyGroupConfigurationSummary],
        summary: ProfileConfigurationSummary
    ) -> Int? {
        guard let group = currentGroup(from: groups, summary: summary) else { return nil }
        let all = ProxyPageNodeOrder.uniqueMembersPreservingOrder(
            tunnel.proxySelections[group.name]?.members ?? group.members
        )
        let filtered = showsSubscriptionNotices
            ? all
            : all.filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }
        return filtered.count
    }

    @ViewBuilder
    private func activeGroupView(
        summary: ProfileConfigurationSummary,
        groups: [ProxyGroupConfigurationSummary]
    ) -> some View {
        if let activeGroup = currentGroup(from: groups, summary: summary) {
            let inventory = (cachedSummary == summary)
                ? cachedInventory
                : ProxyInventoryIndex.build(from: summary)
            let selectionState = tunnel.proxySelections[activeGroup.name]
            let rawSelected = selectionState?.selectedMember
            let selectionMode = tunnel.proxySelectionMode(for: activeGroup.name)
            let preferred = selectionMode == .failover
                ? tunnel.preferredProxyMembers[activeGroup.name]
                : nil
            let effectiveSelected = activeGroup.strategy.lowercased() == "select"
                ? rawSelected
                : (tunnel.automaticGroupLeaves[activeGroup.name] ?? rawSelected)
            let backup = (preferred != nil && effectiveSelected != nil && effectiveSelected != preferred)
                ? effectiveSelected
                : nil
            let failoverSince = backup.flatMap { currentBackup in
                tunnel.proxySwitchLog.latest(forGroup: activeGroup.name).flatMap { event in
                    event.reason == .unresponsive && event.to == currentBackup ? event.date : nil
                }
            }
            let inputs = ActiveProxyGroupInputs(
                profileID: tunnel.activeProfileID,
                group: activeGroup,
                rawMembers: selectionState?.members ?? activeGroup.members,
                selectedMember: rawSelected,
                automaticLeaf: tunnel.automaticGroupLeaves[activeGroup.name],
                nestedSelectedLeaf: rawSelected.flatMap { tunnel.automaticGroupLeaves[$0] },
                selectionMode: selectionMode,
                preferredMember: preferred,
                backupMember: backup,
                failoverSince: failoverSince,
                isSelectionBusy: tunnel.proxySelectionRequests.contains(activeGroup.name),
                selectionMessage: tunnel.proxySelectionMessages[activeGroup.name],
                customGroup: tunnel.customProxyGroup(named: activeGroup.name),
                chainedOverrides: tunnel.activeProfileOverrides.chainedProxies,
                groupNames: Set(summary.proxyGroups.map(\.name)),
                isConnected: tunnel.isConnected,
                isTransitioning: tunnel.isTransitioning,
                isSwitchingNetworkEngine: tunnel.isSwitchingNetworkEngine,
                isPrivacyConsentRequired: tunnel.state == .privacyConsentRequired,
                inventory: inventory
            )
            ActiveProxyGroupView(
                tunnel: tunnel,
                inputs: inputs,
                canEditOverrides: canEditOverrides,
                sort: $sort,
                searchText: $searchText,
                hidesTimedOutNodes: $hidesTimedOutNodes,
                filtersAIAvailableOnly: $filtersAIAvailableOnly,
                usesGridLayout: $usesGridLayout,
                showsSubscriptionNotices: showsSubscriptionNotices,
                onEditCustomGroup: { customGroup in
                    activeOverrideSheet = .editCustomGroup(customGroup)
                },
                onEditChainedProxy: { chainedOverride in
                    activeOverrideSheet = .editChainedProxy(chainedOverride)
                }
            )
        }
    }

    /// The groups as a vertical list beside the members of the chosen one;
    /// the list scrolls on its own.
    private func proxyGroupColumn(
        groups: [ProxyGroupConfigurationSummary],
        summary: ProfileConfigurationSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Proxy groups"), count: groups.count) {
                newGroupButton(in: summary)
            }
            .frame(minHeight: AetherVisual.s5)
            ScrollView {
                LazyVStack(spacing: AetherVisual.sMicro) {
                    ForEach(groups) { group in
                        groupButton(group, in: groups, summary: summary, fillsWidth: true)
                    }
                }
                .padding(AetherVisual.listCardInset)
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .aetherPanel()
            .accessibilityIdentifier("proxy-group-column")
        }
    }

    /// Narrow windows: the same buttons in a row that scrolls sideways.
    private func proxyGroupTabBar(
        groups: [ProxyGroupConfigurationSummary],
        summary: ProfileConfigurationSummary
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherVisual.s1) {
                ForEach(groups) { group in
                    groupButton(group, in: groups, summary: summary, fillsWidth: false)
                }
            }
            .padding(AetherVisual.sMicro)
        }
    }

    private func groupButton(
        _ group: ProxyGroupConfigurationSummary,
        in groups: [ProxyGroupConfigurationSummary],
        summary: ProfileConfigurationSummary,
        fillsWidth: Bool
    ) -> some View {
        ProxyGroupTabButton(
            group: group,
            title: proxyGroupDisplayName(group.name),
            isSelected: currentGroup(from: groups, summary: summary)?.name == group.name,
            currentMember: currentMemberDescription(for: group),
            fillsWidth: fillsWidth,
            onSelect: {
                withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                    selectedGroupName = group.name
                }
            }
        )
    }

    /// The node a group uses now. A url-test, fallback or load-balance group
    /// reports it through the live connections; a select group whose choice
    /// is itself an automatic group shows where that leads ("Auto → Tokyo").
    private func currentMemberDescription(for group: ProxyGroupConfigurationSummary) -> String? {
        let selected = tunnel.proxySelections[group.name]?.selectedMember
        guard group.strategy.lowercased() == "select" else {
            return tunnel.automaticGroupLeaves[group.name] ?? selected
        }
        guard let selected else { return nil }
        if let leaf = tunnel.automaticGroupLeaves[selected], leaf != selected {
            return "\(selected) → \(leaf)"
        }
        return selected
    }

    private func currentGroup(
        from groups: [ProxyGroupConfigurationSummary],
        summary: ProfileConfigurationSummary?
    ) -> ProxyGroupConfigurationSummary? {
        if let name = selectedGroupName, let found = groups.first(where: { $0.name == name }) {
            return found
        }
        return defaultGroup(from: groups, summary: summary)
    }

    /// GLOBAL in global mode; otherwise the group the profile's catch-all
    /// rule sends traffic to, never one of the person's own groups (a new
    /// custom group used to take over the page).
    private func defaultGroup(
        from groups: [ProxyGroupConfigurationSummary],
        summary: ProfileConfigurationSummary?
    ) -> ProxyGroupConfigurationSummary? {
        if tunnel.effectiveRoutingMode == .global,
           let global = tunnel.globalProxyGroup,
           let found = groups.first(where: { $0.name == global.name }) {
            return found
        }
        if let summary, let primary = primaryProxyGroup(in: summary, tunnel: tunnel),
           let found = groups.first(where: { $0.name == primary.name }) {
            return found
        }
        return groups.first { $0.strategy.lowercased() == "select" } ?? groups.first
    }
}

/// Preserves subview structural identity across narrow/wide breakpoints so
/// `ActiveProxyGroupView` keeps scroll position and in-flight state on resize.
private struct ProxyGroupsAdaptiveLayout: Layout {
    let isSideBySide: Bool
    let sidebarWidth: CGFloat
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 700
        let height = proposal.height ?? 500
        guard subviews.count >= 2 else {
            return subviews.first?.sizeThatFits(proposal) ?? .zero
        }
        if isSideBySide {
            return CGSize(width: width, height: height)
        }
        let barSize = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        let contentHeight = max(0, height - barSize.height - spacing)
        let cardSize = subviews[1].sizeThatFits(ProposedViewSize(width: width, height: contentHeight))
        let totalHeight = proposal.height ?? (barSize.height + spacing + cardSize.height)
        return CGSize(width: width, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count >= 2 else { return }
        if isSideBySide {
            let leadingWidth = min(sidebarWidth, max(0, bounds.width - spacing))
            let trailingWidth = max(0, bounds.width - leadingWidth - spacing)
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: leadingWidth, height: bounds.height)
            )
            subviews[1].place(
                at: CGPoint(x: bounds.minX + leadingWidth + spacing, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: trailingWidth, height: bounds.height)
            )
        } else {
            let barSize = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(
                at: CGPoint(x: bounds.minX, y: bounds.minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: barSize.height)
            )
            let contentY = bounds.minY + barSize.height + spacing
            let contentHeight = max(0, bounds.maxY - contentY)
            subviews[1].place(
                at: CGPoint(x: bounds.minX, y: contentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: contentHeight)
            )
        }
    }
}

/// The group a person most likely means by "the proxy": the target of the
/// profile's catch-all rule, skipping groups this app added. Shared by the
/// proxies page and the command palette.
@MainActor
func primaryProxyGroup(
    in summary: ProfileConfigurationSummary,
    tunnel: TunnelManager
) -> ProxyGroupConfigurationSummary? {
    let groups = summary.proxyGroups
    let excluded = Set(tunnel.activeProfileOverrides.groups.map(\.name))
        .union(tunnel.standaloneChainedProxyGroupName.map { [$0] } ?? [])
    if let name = summary.primaryOutboundGroup(excluding: excluded),
       let found = groups.first(where: { $0.name == name }) {
        return found
    }
    return groups.first { $0.strategy.lowercased() == "select" && !excluded.contains($0.name) }
        ?? groups.first { !excluded.contains($0.name) }
        ?? groups.first
}

/// GLOBAL is a Clash keyword; say what it is.
func proxyGroupDisplayName(_ name: String) -> String {
    guard name == "GLOBAL" else { return name }
    return AppLocalization.string("GLOBAL (Global exit)")
}

/// Shared with the overview, which shows a group when one is the outlet.
func proxyGroupSymbol(_ strategy: String) -> String {
    switch strategy.lowercased() {
    case "select": return "square.stack.3d.up.fill"
    case "url-test": return "bolt.fill"
    case "fallback": return "arrow.triangle.branch"
    case "load-balance": return "scale.3d"
    case "smart": return "sparkles"
    default: return "point.3.connected.trianglepath.dotted"
    }
}

/// The group's tile colour, by strategy, so the kinds tell apart at a glance.
func proxyGroupTint(_ strategy: String) -> Color {
    switch strategy.lowercased() {
    case "select": .indigo
    case "url-test": .green
    case "fallback": .orange
    case "load-balance": .teal
    case "smart": .purple
    default: .gray
    }
}

/// The strategy badge in the reader's language. Profile files spell these
/// as Clash keywords (SELECT, URL-TEST…), which meant nothing in a Chinese
/// interface; an unknown strategy keeps its keyword.
func proxyGroupStrategyTitle(_ strategy: String) -> String {
    switch strategy.lowercased() {
    case "select": AppLocalization.string("Strategy select")
    case "url-test": AppLocalization.string("Strategy url-test")
    case "fallback": AppLocalization.string("Strategy fallback")
    case "load-balance": AppLocalization.string("Strategy load-balance")
    case "smart": AppLocalization.string("Strategy smart")
    case "relay": AppLocalization.string("Strategy relay")
    default: strategy.uppercased()
    }
}

// MARK: - Subscription notice

/// What a provider wrote into fake node names ("剩余流量：154.92 GB",
/// "套餐到期：…"), read once and shown as one quiet line instead of rows
/// that look like servers.
private struct ProxySubscriptionNoticeBar: View {
    let notice: SubscriptionNoticeSummary

    var body: some View {
        Label {
            Text(message)
                .lineLimit(1)
                .truncationMode(.tail)
        } icon: {
            Image(systemName: "info.circle")
                .foregroundStyle(Color.accentColor)
        }
        .font(.callout)
        .foregroundStyle(AetherVisual.secondaryText)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .background(AetherVisual.subtleFill, in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
        .help(notice.noticeNames.joined(separator: "\n"))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proxy-subscription-notice-bar")
    }

    private var message: String {
        var parts: [String] = []
        if let remaining = notice.remainingTraffic {
            parts.append(AppLocalization.format("Remaining %@", remaining))
        }
        if notice.isLongTerm {
            parts.append(AppLocalization.string("No expiry"))
        } else if let expiry = notice.expiry {
            parts.append(AppLocalization.format("Expires %@", expiry))
        }
        if parts.isEmpty, let first = notice.contacts.first ?? notice.noticeNames.first {
            parts.append(first)
        } else if parts.isEmpty {
            parts.append(AppLocalization.string("Subscription info"))
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Group button

/// A group as a row: its tile, its name, and "strategy · current node".
private struct ProxyGroupTabButton: View {
    let group: ProxyGroupConfigurationSummary
    let title: String
    let isSelected: Bool
    let currentMember: String?
    /// In the group column each button spans the column; in the top bar it
    /// keeps its natural width.
    var fillsWidth = false
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AetherVisual.sRow) {
                AetherIconTile(symbol: group.name == "GLOBAL" ? "globe" : proxyGroupSymbol(group.strategy), color: proxyGroupTint(group.strategy), size: AetherVisual.rowTileSize)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if fillsWidth {
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, AetherVisual.sRow)
            .padding(.vertical, AetherVisual.s2)
            .contentShape(RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
            .background(
                isSelected
                    ? AetherVisual.selectionFill
                    : (isHovered ? AetherVisual.hoverFill : Color.clear),
                in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
            )
        }
        .buttonStyle(.aetherPressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("proxy-group-\(group.name)")
        .onHover { hovering in
            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                isHovered = hovering
            }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: isSelected)
    }

    /// "Manual select · Singapore Edge"; a group with no node yet says what
    /// it will do instead.
    private var subtitle: String {
        let strategy = proxyGroupStrategyTitle(group.strategy)
        if let currentMember {
            return "\(strategy) · \(currentMember)"
        }
        return switch group.strategy.lowercased() {
        case "url-test": AppLocalization.string("Auto select fastest")
        case "fallback": AppLocalization.string("Uses the first available node")
        case "load-balance": AppLocalization.string("Spreads traffic across nodes")
        case "smart": AppLocalization.string("Picks a working node by quality")
        default: strategy
        }
    }
}

private struct ProxyInventoryIndex: Equatable {
    let protocols: [String: String]
    let transports: [String: String]
    let dialers: [String: String]
    let recognitions: [String: ProxyConfigurationSummary.Recognition]

    static let empty = ProxyInventoryIndex(
        protocols: [:],
        transports: [:],
        dialers: [:],
        recognitions: [:]
    )

    static func build(from summary: ProfileConfigurationSummary) -> ProxyInventoryIndex {
        var protocols: [String: String] = [:]
        var transports: [String: String] = [:]
        var dialers: [String: String] = [:]
        var recognitions: [String: ProxyConfigurationSummary.Recognition] = [:]
        protocols.reserveCapacity(summary.proxies.count)
        recognitions.reserveCapacity(summary.proxies.count)
        for proxy in summary.proxies {
            if protocols[proxy.name] == nil {
                protocols[proxy.name] = proxy.protocolName
            }
            if transports[proxy.name] == nil, let transportName = proxy.transportName {
                transports[proxy.name] = transportName
            }
            if dialers[proxy.name] == nil, let dialerProxy = proxy.dialerProxy {
                dialers[proxy.name] = dialerProxy
            }
            if recognitions[proxy.name] == nil {
                recognitions[proxy.name] = proxy.recognition
            }
        }
        return ProxyInventoryIndex(
            protocols: protocols,
            transports: transports,
            dialers: dialers,
            recognitions: recognitions
        )
    }
}

// MARK: - The chosen group

private struct ActiveProxyGroupInputs: Equatable {
    let profileID: UUID?
    let group: ProxyGroupConfigurationSummary
    let rawMembers: [String]
    let selectedMember: String?
    let automaticLeaf: String?
    let nestedSelectedLeaf: String?
    let selectionMode: ProxySelectionMode
    let preferredMember: String?
    let backupMember: String?
    let failoverSince: Date?
    let isSelectionBusy: Bool
    let selectionMessage: String?
    let customGroup: CustomProxyGroup?
    let chainedOverrides: [ChainedProxyOverride]
    let groupNames: Set<String>
    let isConnected: Bool
    let isTransitioning: Bool
    let isSwitchingNetworkEngine: Bool
    let isPrivacyConsentRequired: Bool
    let inventory: ProxyInventoryIndex

    var isManuallySelectable: Bool {
        group.strategy.lowercased() == "select"
    }

    var isAutomaticSelectionMode: Bool {
        selectionMode == .fastest
    }
}

@MainActor
private final class ActiveProxyGroupListModel: ObservableObject {
    struct Query: Equatable {
        let inputs: ActiveProxyGroupInputs
        let sort: ProxyNodeSort
        let searchText: String
        let hidesTimedOutNodes: Bool
        let filtersAIAvailableOnly: Bool
        let showsSubscriptionNotices: Bool
        let pendingMember: String?
    }

    @Published private(set) var rows: [ProxyMemberTableItem] = []
    @Published private(set) var visibleMembers: Set<String> = []
    @Published private(set) var allMembersCount: Int = 0
    @Published private(set) var hasTestableMembers: Bool = false
    @Published private(set) var resolvedSelectedMember: String?

    private weak var latencyStore: ProxyLatencyStore?
    private weak var egressStore: EgressProbeStore?
    private var currentQuery: Query
    private var lastAppliedQuery: Query?
    private var lastLatencyState: ProxyLatencyState?
    private var lastGroupIsTesting = false
    private var lastGroupMemberRequests: Set<String> = []
    private var lastAINodes: Set<String> = []

    init(
        initialQuery: Query,
        latencyStore: ProxyLatencyStore,
        egressStore: EgressProbeStore
    ) {
        self.currentQuery = initialQuery
        self.latencyStore = latencyStore
        self.egressStore = egressStore
        recompute(force: true)
    }

    func update(query: Query) {
        guard query != currentQuery || lastAppliedQuery == nil else { return }
        currentQuery = query
        recompute(force: true)
    }

    func refreshForLatencyChange() {
        guard currentQuery.sort == .latency || currentQuery.hidesTimedOutNodes else { return }
        recompute(force: false)
    }

    func refreshForEgressChange() {
        guard currentQuery.filtersAIAvailableOnly else { return }
        recompute(force: false)
    }

    private func recompute(force: Bool) {
        let query = currentQuery
        let inputs = query.inputs
        let groupName = inputs.group.name
        let needsLatency = query.sort == .latency || query.hidesTimedOutNodes

        let latencyState = needsLatency ? latencyStore?.proxyLatencies[groupName] : nil
        let groupIsTesting = needsLatency ? (latencyStore?.proxyLatencyRequests.contains(groupName) ?? false) : false
        let prefix = "\(groupName):"
        let groupMemberRequests: Set<String> = needsLatency
            ? Set((latencyStore?.memberLatencyRequests ?? []).filter { $0.hasPrefix(prefix) })
            : []
        let aiNodes: Set<String> = query.filtersAIAvailableOnly
            ? (egressStore?.aiAvailableNodeNames ?? [])
            : []

        if !force,
           lastAppliedQuery == query,
           lastLatencyState == latencyState,
           lastGroupIsTesting == groupIsTesting,
           lastGroupMemberRequests == groupMemberRequests,
           lastAINodes == aiNodes {
            return
        }

        lastAppliedQuery = query
        lastLatencyState = latencyState
        lastGroupIsTesting = groupIsTesting
        lastGroupMemberRequests = groupMemberRequests
        lastAINodes = aiNodes

        let uniqueAll = ProxyPageNodeOrder.uniqueMembersPreservingOrder(inputs.rawMembers)
        let allMembers = query.showsSubscriptionNotices
            ? uniqueAll
            : uniqueAll.filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }

        let nextAllCount = allMembers.count
        let nextHasTestable = allMembers.contains {
            !Self.isBuiltInOutlet($0, protocols: inputs.inventory.protocols)
                && (inputs.inventory.recognitions[$0]?.isSelectable ?? true)
        }
        let currentSelected: String? = {
            if !inputs.isManuallySelectable,
               let leaf = inputs.automaticLeaf,
               allMembers.contains(leaf) {
                return leaf
            }
            return inputs.selectedMember
        }()

        let nextRows: [ProxyMemberTableItem]
        if allMembers.isEmpty {
            nextRows = []
        } else {
            let statusByMember: [String: ProxyLatencyStatus] = needsLatency
                ? Self.latencyStatusMap(
                    for: allMembers,
                    groupName: groupName,
                    state: latencyState,
                    groupIsTesting: groupIsTesting,
                    memberRequests: groupMemberRequests
                )
                : [:]
            var resolvedTypeLabels: [String: String] = [:]
            var resolvedKinds: [String: String] = [:]
            resolvedTypeLabels.reserveCapacity(allMembers.count)
            for member in allMembers {
                let resolved = Self.memberType(
                    member,
                    protocols: inputs.inventory.protocols,
                    groupNames: inputs.groupNames
                )
                resolvedTypeLabels[member] = resolved.label
                if let kind = resolved.canonicalKind {
                    resolvedKinds[member] = kind
                }
            }
            let chainedByName: [String: ChainedProxyOverride] = Dictionary(
                inputs.chainedOverrides.map { ($0.name, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            let sorted = ProxyPageNodeOrder.sorted(members: allMembers, by: query.sort) {
                Self.latencyRank(statusByMember[$0] ?? .untested)
            }
            let ordered = NodeRegion.filterMembers(
                sorted,
                protocolByName: resolvedTypeLabels,
                transportByName: inputs.inventory.transports,
                dialerByName: inputs.inventory.dialers,
                query: query.searchText,
                hideTimedOut: query.hidesTimedOutNodes,
                isTimedOut: { statusByMember[$0] == .timedOut },
                selectedMember: currentSelected
            )
            let aiFiltered = query.filtersAIAvailableOnly
                ? ordered.filter { aiNodes.contains($0) }
                : ordered

            let pending = inputs.isSelectionBusy ? query.pendingMember : nil
            nextRows = aiFiltered.map { member in
                ProxyMemberTableItem(
                    member: member,
                    protocolName: resolvedTypeLabels[member],
                    canonicalProtocolKind: resolvedKinds[member],
                    transportName: inputs.inventory.transports[member],
                    dialerProxy: inputs.inventory.dialers[member],
                    recognition: inputs.inventory.recognitions[member],
                    chainedOverride: chainedByName[member],
                    isSelected: member == currentSelected,
                    isBusy: inputs.isSelectionBusy,
                    isPending: member == pending,
                    showsLatency: !Self.isBuiltInOutlet(member, protocols: inputs.inventory.protocols),
                    badge: member == inputs.preferredMember
                        ? .preferred
                        : (member == inputs.backupMember ? .backupInUse : nil)
                )
            }
        }

        let nextVisible = Set(nextRows.map(\.member))
        if rows != nextRows {
            rows = nextRows
        }
        if visibleMembers != nextVisible {
            visibleMembers = nextVisible
        }
        if allMembersCount != nextAllCount {
            allMembersCount = nextAllCount
        }
        if hasTestableMembers != nextHasTestable {
            hasTestableMembers = nextHasTestable
        }
        if resolvedSelectedMember != currentSelected {
            resolvedSelectedMember = currentSelected
        }
    }

    private static func latencyStatusMap(
        for uniqueMembers: [String],
        groupName: String,
        state: ProxyLatencyState?,
        groupIsTesting: Bool,
        memberRequests: Set<String>
    ) -> [String: ProxyLatencyStatus] {
        var map: [String: ProxyLatencyStatus] = [:]
        map.reserveCapacity(uniqueMembers.count)
        for member in uniqueMembers {
            let isMemberTesting = groupIsTesting
                || memberRequests.contains("\(groupName):\(member)")
            map[member] = ProxyLatencyStatus.status(
                member: member,
                state: state,
                isTesting: isMemberTesting
            )
        }
        return map
    }

    private static func memberType(
        _ member: String,
        protocols: [String: String],
        groupNames: Set<String>
    ) -> (label: String, canonicalKind: String?) {
        switch member.uppercased() {
        case "DIRECT": return (AppLocalization.string("Direct"), "DIRECT")
        case "REJECT", "REJECT-DROP": return (AppLocalization.string("Reject"), "REJECT")
        default:
            if let protocolName = protocols[member] {
                return (protocolName.uppercased(), protocolName.uppercased())
            }
            if groupNames.contains(member) {
                return (AppLocalization.string("Proxy group"), nil)
            }
            return (AppLocalization.string("Unknown"), nil)
        }
    }

    private static func isBuiltInOutlet(_ member: String, protocols: [String: String]) -> Bool {
        let outlets: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP"]
        return outlets.contains(member.uppercased())
            || outlets.contains(protocols[member]?.uppercased() ?? "")
    }

    private static func latencyRank(_ status: ProxyLatencyStatus) -> Int {
        switch status {
        case let .responded(milliseconds): Int(milliseconds)
        case .timedOut: Int.max - 2
        case .testing: Int.max - 1
        case .untested: Int.max
        }
    }
}

/// One card: the group and its current node with its controls pinned on
/// top, then the nodes, which scroll on their own.
private struct ActiveProxyGroupView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// A choice made while disconnected takes effect later; say so for a
    /// moment instead of keeping a permanent caption on the card.
    @State private var showsNextConnectionNote = false
    @State private var nextConnectionNoteToken = UUID()
    @State private var showsSwitchHistory = false
    /// The row just clicked, per group, so only it shows a spinner while
    /// the switch is applied.
    @State private var pendingSelections: [String: String] = [:]
    @State private var activeLatencyTask: Task<Void, Never>?
    @StateObject private var listModel: ActiveProxyGroupListModel
    let tunnel: TunnelManager
    let inputs: ActiveProxyGroupInputs
    let canEditOverrides: Bool
    @Binding var sort: ProxyNodeSort
    @Binding var searchText: String
    @Binding var hidesTimedOutNodes: Bool
    @Binding var filtersAIAvailableOnly: Bool
    @Binding var usesGridLayout: Bool
    var showsSubscriptionNotices = false
    let onEditCustomGroup: (CustomProxyGroup) -> Void
    let onEditChainedProxy: (ChainedProxyOverride) -> Void

    init(
        tunnel: TunnelManager,
        inputs: ActiveProxyGroupInputs,
        canEditOverrides: Bool,
        sort: Binding<ProxyNodeSort>,
        searchText: Binding<String>,
        hidesTimedOutNodes: Binding<Bool>,
        filtersAIAvailableOnly: Binding<Bool>,
        usesGridLayout: Binding<Bool>,
        showsSubscriptionNotices: Bool = false,
        onEditCustomGroup: @escaping (CustomProxyGroup) -> Void,
        onEditChainedProxy: @escaping (ChainedProxyOverride) -> Void
    ) {
        self.tunnel = tunnel
        self.inputs = inputs
        self.canEditOverrides = canEditOverrides
        self._sort = sort
        self._searchText = searchText
        self._hidesTimedOutNodes = hidesTimedOutNodes
        self._filtersAIAvailableOnly = filtersAIAvailableOnly
        self._usesGridLayout = usesGridLayout
        self.showsSubscriptionNotices = showsSubscriptionNotices
        self.onEditCustomGroup = onEditCustomGroup
        self.onEditChainedProxy = onEditChainedProxy
        let initialQuery = ActiveProxyGroupListModel.Query(
            inputs: inputs,
            sort: sort.wrappedValue,
            searchText: searchText.wrappedValue,
            hidesTimedOutNodes: hidesTimedOutNodes.wrappedValue,
            filtersAIAvailableOnly: filtersAIAvailableOnly.wrappedValue,
            showsSubscriptionNotices: showsSubscriptionNotices,
            pendingMember: nil
        )
        _listModel = StateObject(
            wrappedValue: ActiveProxyGroupListModel(
                initialQuery: initialQuery,
                latencyStore: tunnel.latencyStore,
                egressStore: tunnel.egressProbeStore
            )
        )
    }

    private static let listTopAnchor = "proxy-node-list-top"

    private var group: ProxyGroupConfigurationSummary { inputs.group }
    private var selectionMode: ProxySelectionMode { inputs.selectionMode }
    private var isManuallySelectable: Bool { inputs.isManuallySelectable }
    private var isAutomaticSelectionMode: Bool { inputs.isAutomaticSelectionMode }
    private var preferredMember: String? { inputs.preferredMember }
    private var backupMember: String? { inputs.backupMember }
    private var customGroup: CustomProxyGroup? { inputs.customGroup }

    private var currentQuery: ActiveProxyGroupListModel.Query {
        ActiveProxyGroupListModel.Query(
            inputs: inputs,
            sort: sort,
            searchText: searchText,
            hidesTimedOutNodes: hidesTimedOutNodes,
            filtersAIAvailableOnly: filtersAIAvailableOnly,
            showsSubscriptionNotices: showsSubscriptionNotices,
            pendingMember: pendingSelections[inputs.group.name]
        )
    }

    private var canSelect: Bool {
        isManuallySelectable
            && !isAutomaticSelectionMode
            && !inputs.isTransitioning
            && !inputs.isSwitchingNetworkEngine
            && !inputs.isPrivacyConsentRequired
    }

    var body: some View {
        let query = currentQuery
        let rows = listModel.rows
        let totalCount = listModel.allMembersCount
        let selected = listModel.resolvedSelectedMember
        let needsLatencyObservation = sort == .latency || hidesTimedOutNodes
        let hasTestableMembers = listModel.hasTestableMembers

        return ScrollViewReader { scroller in
            VStack(alignment: .leading, spacing: 0) {
                header(hasTestableMembers: hasTestableMembers)
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.top, AetherVisual.s3)
                    .padding(.bottom, AetherVisual.s2)
                if totalCount > 0 {
                    toolbar(
                        displayedCount: rows.count,
                        totalCount: totalCount,
                        selectedMember: selected,
                        scroller: scroller
                    )
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.bottom, AetherVisual.s3)
                }

                if inputs.isConnected, let preferredMember, let backupMember {
                    FailoverBackupBanner(
                        preferred: preferredMember,
                        backup: backupMember,
                        since: inputs.failoverSince
                    )
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.bottom, AetherVisual.s3)
                    .transition(AetherVisual.insertion)
                }

                if let message = inputs.selectionMessage {
                    AetherInlineMessage(text: message, isCompact: true)
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.bottom, AetherVisual.s3)
                        .transition(AetherVisual.insertion)
                }

                Divider().padding(.horizontal, AetherVisual.s4)

                ScrollView {
                    Color.clear.frame(height: 0).id(Self.listTopAnchor)
                    if totalCount == 0 {
                        Text(AppLocalization.string("This group has no nodes."))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AetherVisual.s4)
                    } else if needsLatencyObservation {
                        ActiveProxyGroupLatencySortedList(
                            groupName: group.name,
                            latencyStore: tunnel.latencyStore,
                            egressStore: tunnel.egressProbeStore,
                            observesEgress: filtersAIAvailableOnly,
                            rows: rows,
                            onLatencyChange: { listModel.refreshForLatencyChange() },
                            onEgressChange: { listModel.refreshForEgressChange() },
                            nodeRow: { row in nodeRow(row, isCompact: usesGridLayout) },
                            emptyView: { filteredEmptyState },
                            usesGridLayout: usesGridLayout
                        )
                    } else if filtersAIAvailableOnly {
                        ActiveProxyGroupAIObservingList(
                            egressStore: tunnel.egressProbeStore,
                            rows: rows,
                            onEgressChange: { listModel.refreshForEgressChange() },
                            nodeRow: { row in nodeRow(row, isCompact: usesGridLayout) },
                            emptyView: { filteredEmptyState },
                            usesGridLayout: usesGridLayout
                        )
                    } else if rows.isEmpty {
                        filteredEmptyState
                    } else {
                        nodeList(rows: rows)
                            .padding(AetherVisual.listCardInset)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("proxy-node-scroll")
            }
            .onChange(of: group.name) { _, _ in
                activeLatencyTask?.cancel()
                activeLatencyTask = nil
                showsNextConnectionNote = false
                showsSwitchHistory = false
                scroller.scrollTo(Self.listTopAnchor, anchor: .top)
            }
        }
        .aetherPanel()
        .onAppear {
            listModel.update(query: query)
        }
        .onChange(of: query) { _, nextQuery in
            listModel.update(query: nextQuery)
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: inputs.selectionMessage)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: showsNextConnectionNote)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: backupMember)
        .task(id: "\(group.name)|\(inputs.isConnected)") {
            if isManuallySelectable {
                await tunnel.refreshProxySelection(group: group.name)
            }
            guard !Task.isCancelled else { return }
            let task = Task {
                await tunnel.testLatencyOnOpenIfDue(group: group.name)
            }
            activeLatencyTask = task
            await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }
        }
        .task(id: nextConnectionNoteToken) {
            guard showsNextConnectionNote else { return }
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            showsNextConnectionNote = false
        }
        .onChange(of: inputs.isConnected) { _, _ in
            showsNextConnectionNote = false
        }
        .onChange(of: selectionMode) { _, mode in
            if !mode.switchesAutomatically {
                showsSwitchHistory = false
            }
        }
        .onChange(of: inputs.isSelectionBusy) { _, isBusy in
            if !isBusy {
                pendingSelections.removeValue(forKey: group.name)
            }
        }
        .onDisappear {
            activeLatencyTask?.cancel()
            activeLatencyTask = nil
        }
    }

    // MARK: Header

    private func header(hasTestableMembers: Bool) -> some View {
        HStack(alignment: .center, spacing: AetherVisual.s2) {
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(proxyGroupDisplayName(group.name))
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .accessibilityIdentifier("proxy-active-group-name")
                    if customGroup != nil {
                        Text(AppLocalization.string("Custom"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherVisual.secondaryText)
                            .padding(.horizontal, AetherVisual.s1)
                            .padding(.vertical, AetherVisual.sMicro)
                            .background(AetherVisual.neutralFill, in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
                            .accessibilityIdentifier("proxy-group-custom-badge")
                    }
                }
                currentNodeLine
                if !isManuallySelectable {
                    Text(automaticGroupNote)
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("proxy-group-automatic-note")
                } else if isAutomaticSelectionMode {
                    Text(selectionMode.localizedExplanation)
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("proxy-group-automatic-note")
                }
                if showsNextConnectionNote {
                    Label(
                        AppLocalization.string("The selected node will be used on the next connection."),
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .transition(AetherVisual.insertion)
                }
            }
            Spacer(minLength: AetherVisual.s2)
            if let customGroup {
                Button {
                    onEditCustomGroup(customGroup)
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(!canEditOverrides)
                .help(AppLocalization.string("Edit group"))
                .accessibilityLabel(AppLocalization.string("Edit group"))
                .accessibilityIdentifier("proxy-edit-custom-group")
            }
            if selectionMode.switchesAutomatically {
                switchHistoryButton
            }
            if isManuallySelectable, !isGlobalGroup {
                selectionModeMenu
                    .disabled(
                        inputs.isTransitioning
                            || inputs.isSwitchingNetworkEngine
                            || !canEditOverrides
                            || (group.memberCount <= 1 && selectionMode == .manual)
                    )
            }
            ProxyGroupTestLatencyButton(
                groupName: group.name,
                hasTestableMembers: hasTestableMembers,
                latencyStore: tunnel.latencyStore,
                action: {
                    activeLatencyTask?.cancel()
                    activeLatencyTask = Task {
                        await tunnel.testProxyLatency(group: group.name)
                    }
                },
                onCancel: {
                    activeLatencyTask?.cancel()
                }
            )
        }
    }

    /// Search, count and the view controls, pinned above the nodes.
    private func toolbar(
        displayedCount: Int,
        totalCount: Int,
        selectedMember: String?,
        scroller: ScrollViewProxy
    ) -> some View {
        AetherWrapPairLayout {
            HStack(spacing: AetherVisual.s2) {
                AetherSearchField(
                    text: $searchText,
                    prompt: AppLocalization.string("Search nodes"),
                    accessibilityIdentifier: "proxy-node-search-field"
                )
                .frame(minWidth: AetherVisual.searchFieldMinWidth, maxWidth: 260)
                nodeCountText(displayedCount: displayedCount, totalCount: totalCount)
            }
            AetherFlowLayout(spacing: AetherVisual.s2) {
                aiFilterPill
                sortMenu
                layoutToggle
                ProxyLocateSelectedButton(
                    selectedMember: selectedMember,
                    isVisible: selectedMember.map { listModel.visibleMembers.contains($0) } ?? false,
                    scroller: scroller
                )
            }
        }
    }

    private func nodeCountText(displayedCount: Int, totalCount: Int) -> some View {
        let text = displayedCount == totalCount
            ? AppLocalization.format("%lld nodes", Int64(totalCount))
            : AppLocalization.format("%lld of %lld nodes", Int64(displayedCount), Int64(totalCount))
        return Text(text)
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("proxy-group-node-count")
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label(
                AppLocalization.string("No matching nodes"),
                systemImage: "magnifyingglass"
            )
        } description: {
            Text(
                filtersAIAvailableOnly
                    ? AppLocalization.string("Try clearing filters or running an AI availability check from Settings.")
                    : AppLocalization.string("No nodes in this group match your current search or filters.")
            )
        } actions: {
            Button(AppLocalization.string("Clear filters")) {
                withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                    searchText = ""
                    filtersAIAvailableOnly = false
                    hidesTimedOutNodes = false
                }
            }
            .aetherButton()
            .accessibilityIdentifier("proxy-clear-filters")
        }
        .frame(maxWidth: .infinity)
        .padding(AetherVisual.s4)
    }

    private var aiFilterPill: some View {
        let label = AppLocalization.string("AI Available")
        return Button {
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                filtersAIAvailableOnly.toggle()
            }
        } label: {
            HStack(spacing: AetherVisual.s1) {
                Image(systemName: filtersAIAvailableOnly ? "sparkles" : "sparkle")
                    .font(.caption.weight(.semibold))
                Text(label)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(
                filtersAIAvailableOnly
                    ? AnyShapeStyle(AetherReadableTint(color: .green))
                    : AnyShapeStyle(AetherVisual.secondaryText)
            )
            .padding(.horizontal, AetherVisual.s2)
            .padding(.vertical, AetherVisual.s1)
            .background(
                filtersAIAvailableOnly ? AetherVisual.tintFill(.green) : AetherVisual.neutralFill,
                in: Capsule()
            )
            .overlay {
                if filtersAIAvailableOnly {
                    Capsule()
                        .strokeBorder(AetherVisual.tintBorder(.green), lineWidth: 0.5)
                }
            }
        }
        .buttonStyle(.plain)
        .help(
            AppLocalization.string("Show only nodes verified as AI-available by an egress check")
        )
        .accessibilityLabel(label)
        .accessibilityAddTraits(filtersAIAvailableOnly ? [.isSelected] : [])
        .accessibilityIdentifier("proxy-filter-ai-available")
    }

    private var layoutToggle: some View {
        Button {
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                usesGridLayout.toggle()
            }
        } label: {
            Image(systemName: usesGridLayout ? "list.bullet" : "square.grid.2x2")
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .aetherButton()
        .controlSize(.small)
        .help(layoutToggleTitle)
        .accessibilityLabel(layoutToggleTitle)
        .accessibilityIdentifier("proxy-layout-toggle")
    }

    private var layoutToggleTitle: String {
        usesGridLayout
            ? AppLocalization.string("Show as list")
            : AppLocalization.string("Show as grid")
    }

    /// Manual, fastest or failover, in a compact menu instead of a row of
    /// its own that pushed the nodes down.
    private var selectionModeMenu: some View {
        let canChangeMode = !inputs.isTransitioning
            && !inputs.isSwitchingNetworkEngine
            && canEditOverrides
            && (group.memberCount > 1 || selectionMode != .manual)
        return Menu {
            Picker(
                AppLocalization.string("Node selection"),
                selection: Binding(
                    get: { selectionMode },
                    set: { mode in
                        guard group.memberCount > 1 || mode == .manual else { return }
                        Task {
                            await tunnel.setProxySelectionMode(
                                group: group.name,
                                mode: mode
                            )
                        }
                    }
                )
            ) {
                ForEach(ProxySelectionMode.allCases, id: \.self) { mode in
                    Label(mode.localizedTitle, systemImage: mode.symbol)
                        .tag(mode)
                        .disabled(group.memberCount <= 1 && mode != .manual)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Text(selectionMode.localizedExplanation)
                .accessibilityIdentifier("proxy-selection-mode-explanation")
        } label: {
            Label(selectionMode.localizedTitle, systemImage: selectionMode.symbol)
                .labelStyle(.titleAndIcon)
        }
        .menuIndicator(.hidden)
        .aetherButton()
        .controlSize(.small)
        .fixedSize()
        .disabled(!canChangeMode)
        .help(selectionMode.localizedExplanation)
        .accessibilityLabel(AppLocalization.string("Node selection"))
        .accessibilityValue(selectionMode.localizedTitle)
        .accessibilityIdentifier("proxy-selection-mode-\(group.name)")
    }

    @ViewBuilder
    private var currentNodeLine: some View {
        if let selectedMember {
            HStack(spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Current node"))
                    .foregroundStyle(AetherVisual.secondaryText)
                Text(selectedMember)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let leaf = nestedLeaf {
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    Text(leaf)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if !isBuiltInOutlet(selectedMember) {
                    ProxyCurrentNodeLatencyLeaf(
                        groupName: group.name,
                        member: selectedMember,
                        latencyStore: tunnel.latencyStore,
                        tunnel: tunnel
                    )
                }
            }
            .font(.subheadline)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("proxy-current-node")
        } else {
            Text(
                isManuallySelectable
                    ? AppLocalization.string("No node selected yet")
                    : AppLocalization.string("Chooses a node once connected")
            )
            .font(.subheadline)
            .foregroundStyle(AetherVisual.secondaryText)
        }
    }

    /// The node behind a chosen automatic group ("Auto" → "Tokyo 01").
    private var nestedLeaf: String? {
        guard isManuallySelectable, let selectedMember = inputs.selectedMember,
              let leaf = inputs.nestedSelectedLeaf,
              leaf != selectedMember else { return nil }
        return leaf
    }

    private var switchHistoryButton: some View {
        Button {
            showsSwitchHistory.toggle()
        } label: {
            Image(systemName: "clock.arrow.circlepath")
        }
        .aetherButton()
        .controlSize(.small)
        .help(AppLocalization.string("Automatic switches"))
        .accessibilityLabel(AppLocalization.string("Automatic switches"))
        .accessibilityIdentifier("proxy-switch-history-button")
        .popover(isPresented: $showsSwitchHistory, arrowEdge: .bottom) {
            ProxySwitchHistoryView(events: tunnel.proxySwitchLog.events(forGroup: group.name))
        }
    }

    private var sortMenu: some View {
        Menu {
            Picker(AppLocalization.string("Sort"), selection: $sort) {
                ForEach(ProxyNodeSort.allCases) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
            Divider()
            Toggle(AppLocalization.string("Hide timed-out nodes"), isOn: $hidesTimedOutNodes)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .aetherButton()
        .controlSize(.small)
        .fixedSize()
        .help(AppLocalization.format("Sort: %@", sort.localizedTitle))
        .accessibilityLabel(AppLocalization.string("Sort"))
        .accessibilityValue(sort.localizedTitle)
        .accessibilityIdentifier("proxy-sort-picker")
    }

    /// What a group that picks its own node does, so its rows not being
    /// clickable is explained rather than discovered.
    private var automaticGroupNote: String {
        switch group.strategy.lowercased() {
        case "url-test": AppLocalization.string("This group automatically uses the node with the lowest latency.")
        case "fallback": AppLocalization.string("This group uses the first node that responds, in list order.")
        case "load-balance": AppLocalization.string("This group spreads connections across its nodes.")
        case "smart": AppLocalization.string("This group chooses a node automatically based on latency and stability.")
        default: AppLocalization.string("This group chooses its node automatically.")
        }
    }

    // MARK: Nodes

    @ViewBuilder
    private func nodeList(rows: [ProxyMemberTableItem]) -> some View {
        // Lazy: a group can hold hundreds of nodes.
        Group {
            if usesGridLayout {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: AetherVisual.s2),
                        GridItem(.flexible(), spacing: AetherVisual.s2),
                    ],
                    spacing: AetherVisual.s2
                ) {
                    ForEach(rows) { row in
                        nodeRow(row, isCompact: true)
                    }
                }
            } else {
                LazyVStack(spacing: AetherVisual.sMicro) {
                    ForEach(rows) { row in
                        nodeRow(row, isCompact: false)
                    }
                }
            }
        }
        .animation(
            rows.count <= 60 ? AetherVisual.animation(AetherVisual.gentleSpring) : nil,
            value: rows.map(\.id)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Proxy group members"))
        .accessibilityIdentifier("proxy-group-members-table")
    }

    private func nodeRow(_ row: ProxyMemberTableItem, isCompact: Bool) -> some View {
        ProxyNodeRow(
            groupName: group.name,
            row: row,
            canSelect: canSelect,
            showsSelectionControl: isManuallySelectable,
            canEditOverrides: canEditOverrides,
            isCompact: isCompact,
            latencyStore: tunnel.latencyStore,
            tunnel: tunnel,
            onSelect: {
                guard canSelect, row.isSelectable else { return }
                pendingSelections[group.name] = row.member
                Task {
                    await tunnel.selectProxy(group: group.name, member: row.member)
                    if pendingSelections[group.name] == row.member {
                        pendingSelections[group.name] = nil
                    }
                    if !tunnel.isConnected,
                       tunnel.proxySelectionMessages[group.name] == nil,
                       tunnel.proxySelections[group.name]?.selectedMember == row.member {
                        nextConnectionNoteToken = UUID()
                        showsNextConnectionNote = true
                    }
                }
            },
            onTest: {
                guard row.isSelectable else { return }
                Task { await tunnel.testSingleProxyLatency(group: group.name, member: row.member) }
            },
            onEditChained: row.chainedOverride.map { item in
                { onEditChainedProxy(item) }
            }
        )
        .id(row.member)
    }

    /// DIRECT and REJECT are not servers: a delay measured through them says
    /// nothing about choosing a node, and a slow direct probe read as a fault.
    /// A profile node of `type: direct` behaves the same under another name.
    private func isBuiltInOutlet(_ member: String) -> Bool {
        let outlets: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP"]
        return outlets.contains(member.uppercased())
            || outlets.contains(inputs.inventory.protocols[member]?.uppercased() ?? "")
    }

    private var isGlobalGroup: Bool {
        group.name == "GLOBAL"
    }

    /// The node in use: the choice of a select group, or the node a
    /// url-test, fallback or load-balance group is using right now.
    private var selectedMember: String? {
        guard isManuallySelectable else {
            return inputs.automaticLeaf ?? inputs.selectedMember
        }
        return inputs.selectedMember
    }
}

private struct ProxyLocateSelectedButton: View {
    let selectedMember: String?
    let isVisible: Bool
    let scroller: ScrollViewProxy

    var body: some View {
        let title = AppLocalization.string("Locate current node")
        Button {
            guard let selectedMember, isVisible else { return }
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                scroller.scrollTo(selectedMember, anchor: .center)
            }
        } label: {
            Image(systemName: "scope")
        }
        .aetherButton()
        .controlSize(.small)
        .disabled(selectedMember == nil || !isVisible)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("proxy-locate-current-node")
    }
}

private struct ActiveProxyGroupAIObservingList<RowContent: View, EmptyContent: View>: View {
    @ObservedObject var egressStore: EgressProbeStore
    let rows: [ProxyMemberTableItem]
    let onEgressChange: () -> Void
    let nodeRow: (ProxyMemberTableItem) -> RowContent
    let emptyView: () -> EmptyContent
    let usesGridLayout: Bool

    var body: some View {
        Group {
            if rows.isEmpty {
                emptyView()
            } else {
                Group {
                    if usesGridLayout {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: AetherVisual.s2),
                                GridItem(.flexible(), spacing: AetherVisual.s2),
                            ],
                            spacing: AetherVisual.s2
                        ) {
                            ForEach(rows, content: nodeRow)
                        }
                    } else {
                        LazyVStack(spacing: AetherVisual.sMicro) {
                            ForEach(rows, content: nodeRow)
                        }
                    }
                }
                .padding(AetherVisual.listCardInset)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppLocalization.string("Proxy group members"))
                .accessibilityIdentifier("proxy-group-members-table")
            }
        }
        .onChange(of: egressStore.cache) { _, _ in
            onEgressChange()
        }
    }
}

/// Observes `ProxyLatencyStore` only when the user sorts by latency or hides timed-out nodes.
private struct ActiveProxyGroupLatencySortedList<RowContent: View, EmptyContent: View>: View {
    let groupName: String
    @ObservedObject var latencyStore: ProxyLatencyStore
    @ObservedObject var egressStore: EgressProbeStore
    let observesEgress: Bool
    let rows: [ProxyMemberTableItem]
    let onLatencyChange: () -> Void
    let onEgressChange: () -> Void
    let nodeRow: (ProxyMemberTableItem) -> RowContent
    let emptyView: () -> EmptyContent
    let usesGridLayout: Bool

    var body: some View {
        let memberPrefix = "\(groupName):"
        Group {
            if rows.isEmpty {
                emptyView()
            } else {
                Group {
                    if usesGridLayout {
                        LazyVGrid(
                            columns: [
                                GridItem(.flexible(), spacing: AetherVisual.s2),
                                GridItem(.flexible(), spacing: AetherVisual.s2),
                            ],
                            spacing: AetherVisual.s2
                        ) {
                            ForEach(rows, content: nodeRow)
                        }
                    } else {
                        LazyVStack(spacing: AetherVisual.sMicro) {
                            ForEach(rows, content: nodeRow)
                        }
                    }
                }
                .padding(AetherVisual.listCardInset)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(AppLocalization.string("Proxy group members"))
                .accessibilityIdentifier("proxy-group-members-table")
            }
        }
        .onChange(of: latencyStore.proxyLatencies[groupName]) { _, _ in
            onLatencyChange()
        }
        .onChange(of: latencyStore.proxyLatencyRequests.contains(groupName)) { _, _ in
            onLatencyChange()
        }
        .onChange(of: latencyStore.memberLatencyRequests) { previous, current in
            let prevForGroup = previous.filter { $0.hasPrefix(memberPrefix) }
            let nextForGroup = current.filter { $0.hasPrefix(memberPrefix) }
            if prevForGroup != nextForGroup {
                onLatencyChange()
            }
        }
        .onChange(of: egressStore.cache) { _, _ in
            if observesEgress {
                onEgressChange()
            }
        }
    }
}

private struct ProxyGroupTestLatencyButton: View {
    let groupName: String
    let hasTestableMembers: Bool
    @ObservedObject var latencyStore: ProxyLatencyStore
    let action: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let isTesting = latencyStore.proxyLatencyRequests.contains(groupName)
        HStack(spacing: AetherVisual.s1) {
            Button(action: action) {
                AetherProgressButtonLabel(AppLocalization.string("Test latency"), systemImage: "bolt", isWorking: isTesting)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 72)
            }
            .aetherButton()
            .controlSize(.small)
            .disabled(isTesting || !hasTestableMembers)
            .help(lastTestedHelp)
            .accessibilityIdentifier("proxy-test-latency-\(groupName)")

            if isTesting {
                Button(action: onCancel) {
                    Image(systemName: "xmark.circle")
                }
                .aetherButton()
                .controlSize(.small)
                .help(AppLocalization.string("Stop testing"))
                .accessibilityLabel(AppLocalization.string("Stop testing"))
                .accessibilityIdentifier("proxy-cancel-latency-\(groupName)")
            }
        }
    }

    private var lastTestedHelp: String {
        guard hasTestableMembers else {
            return AppLocalization.string("This group has no testable nodes")
        }
        guard let latest = latencyStore.latencyMeasuredAt[groupName]?.values.max() else {
            return AppLocalization.string("Test latency for current group nodes")
        }
        return AppLocalization.format(
            "Last tested at %@",
            AppLocalization.date(latest, date: .omitted, time: .standard)
        )
    }
}

private struct ProxyCurrentNodeLatencyLeaf: View {
    let groupName: String
    let member: String
    @ObservedObject var latencyStore: ProxyLatencyStore
    let tunnel: TunnelManager

    var body: some View {
        let isTestingMember = latencyStore.proxyLatencyRequests.contains(groupName)
            || latencyStore.memberLatencyRequests.contains("\(groupName):\(member)")
        let status = ProxyLatencyStatus.status(
            member: member,
            state: latencyStore.proxyLatencies[groupName],
            isTesting: isTestingMember
        )
        if status.isMeasured {
            HStack(spacing: AetherVisual.s1) {
                Text(verbatim: "·")
                    .foregroundStyle(AetherVisual.secondaryText)
                ProxyLatencyText(
                    status: status,
                    confidence: tunnel.latencyConfidence(group: groupName, member: member)
                )
            }
        }
    }
}
// MARK: - Node row

/// Selection, region, name, protocol and latency on one line, or a clean
/// two-line card when `isCompact` (2-column grid) is true. Unselected rows
/// rely on subtle card fills and selection highlights rather than empty radio
/// rings.
private struct ProxyNodeRow: View {
    let groupName: String
    let row: ProxyMemberTableItem
    let canSelect: Bool
    let showsSelectionControl: Bool
    let canEditOverrides: Bool
    var isCompact = false
    let latencyStore: ProxyLatencyStore
    let tunnel: TunnelManager
    let onSelect: () -> Void
    let onTest: () -> Void
    var onEditChained: (() -> Void)? = nil
    @State private var isHovered = false

    private var isSelectionDisabled: Bool {
        (row.isBusy && !row.isPending) || !canSelect || !row.isSelectable
    }

    private var accessibilityValueSummary: String {
        var parts: [String] = []
        if let protocolName = row.protocolName {
            if let transportName = row.transportName, !transportName.isEmpty {
                parts.append("\(protocolName) \(transportName)")
            } else {
                parts.append(protocolName)
            }
        }
        if let dialer = row.dialerProxy {
            parts.append(AppLocalization.format("via %@", dialer))
        }
        if !showsSelectionControl && row.isSelected {
            parts.append(AppLocalization.string("Current"))
        }
        if let badge = row.badge {
            parts.append(
                badge == .preferred
                    ? AppLocalization.string("Preferred")
                    : AppLocalization.string("Backup in use")
            )
        }
        if let report = tunnel.egressProbeStore.report(forNode: row.member) {
            parts.append(
                report.isAIAvailable
                    ? AppLocalization.string("AI")
                    : AppLocalization.string("AI Limited")
            )
        }
        if let recognition = row.recognition, !recognition.isSelectable {
            parts.append(recognition.localizedTitle)
        }
        return parts.joined(separator: ", ")
    }

    var body: some View {
        Group {
            if isCompact {
                gridCardBody
            } else {
                listRowBody
            }
        }
        .onHover { isHovered = $0 }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: row.isSelected)
        .contextMenu {
            if showsSelectionControl {
                Button(AppLocalization.string("Switch to this node"), action: onSelect)
                    .disabled(isSelectionDisabled)
            }
            if row.showsLatency {
                Button(AppLocalization.string("Test latency"), action: onTest)
                    .disabled(!row.isSelectable)
            }
            if let onEditChained {
                Divider()
                Button(AppLocalization.string("Edit Chained Proxy…"), action: onEditChained)
                    .disabled(!canEditOverrides)
            }
            Divider()
            Button(AppLocalization.string("Copy node name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.member, forType: .string)
            }
        }
    }

    private var gridCardBody: some View {
        VStack(alignment: .leading, spacing: AetherVisual.sCompact) {
            if showsSelectionControl {
                Button(action: onSelect) {
                    gridTopLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isSelectionDisabled)
                .accessibilityLabel(row.member)
                .accessibilityValue(accessibilityValueSummary)
                .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
                .modifier(OptionalChainedProxyActionModifier(action: canEditOverrides ? onEditChained : nil))
            } else {
                gridTopLine
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.member)
                    .accessibilityValue(accessibilityValueSummary)
                    .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
                    .modifier(OptionalChainedProxyActionModifier(action: canEditOverrides ? onEditChained : nil))
            }

            HStack(alignment: .center, spacing: AetherVisual.s1) {
                gridMetadataBadges
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard showsSelectionControl, !isSelectionDisabled else { return }
                        onSelect()
                    }
                    .accessibilityHidden(true)

                if let onEditChained {
                    editChainedButton(onEditChained)
                }
                if row.showsLatency {
                    ProxyNodeLatencyAccessory(
                        groupName: groupName,
                        member: row.member,
                        isNodeSelectable: row.isSelectable,
                        recognitionHint: row.recognition?.localizedTitle,
                        latencyStore: latencyStore,
                        tunnel: tunnel,
                        onTest: onTest
                    )
                }
            }
        }
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s2)
        .frame(minHeight: AetherVisual.twoLineRowHeight)
        .background(
            cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .strokeBorder(
                    row.isSelected
                        ? AetherVisual.tintBorder(.accentColor)
                        : Color(nsColor: .separatorColor),
                    lineWidth: row.isSelected ? 1.5 : 0.5
                )
        }
    }

    private var gridTopLine: some View {
        HStack(spacing: AetherVisual.s2) {
            AetherRegionCode(name: row.member, reservesSlot: false)
            Text(row.member)
                .font(.callout.weight(row.isSelected ? .semibold : .medium))
                .foregroundStyle(row.isSelectable ? AnyShapeStyle(.primary) : AnyShapeStyle(AetherVisual.secondaryText))
                .strikethrough(!row.isSelectable)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(memberTooltip)
            Spacer(minLength: AetherVisual.s1)
            selectionAccessory
        }
    }

    private var gridMetadataBadges: some View {
        AetherFlowLayout(spacing: AetherVisual.s1) {
            if let protocolName = row.protocolName {
                AetherProtocolBadge(
                    type: protocolName,
                    transport: row.transportName,
                    canonicalKind: row.canonicalProtocolKind
                )
            }
            if let dialer = row.dialerProxy {
                dialerBadge(dialer)
            }
            if let recognition = row.recognition, !recognition.isSelectable {
                unsupportedBadge(recognition)
            }
            if let badge = row.badge {
                ProxyNodeBadge(badge: badge)
                    .transition(.opacity)
            }
            ProxyNodeAIAvailabilityBadge(member: row.member, egressStore: tunnel.egressProbeStore)
        }
    }

    private var listRowBody: some View {
        HStack(spacing: AetherVisual.s3) {
            if showsSelectionControl {
                Button(action: onSelect) {
                    listRowContent.contentShape(Rectangle())
                }
                .buttonStyle(.aetherPressable)
                .disabled(isSelectionDisabled)
                .accessibilityLabel(row.member)
                .accessibilityValue(accessibilityValueSummary)
                .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
                .modifier(OptionalChainedProxyActionModifier(action: canEditOverrides ? onEditChained : nil))
            } else {
                // Not a disabled button: that would grey out rows that are
                // simply not meant to be clicked.
                listRowContent
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(row.member)
                    .accessibilityValue(accessibilityValueSummary)
                    .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
                    .modifier(OptionalChainedProxyActionModifier(action: canEditOverrides ? onEditChained : nil))
            }

            if let onEditChained {
                editChainedButton(onEditChained)
            }

            if row.showsLatency {
                ProxyNodeLatencyAccessory(
                    groupName: groupName,
                    member: row.member,
                    isNodeSelectable: row.isSelectable,
                    recognitionHint: row.recognition?.localizedTitle,
                    latencyStore: latencyStore,
                    tunnel: tunnel,
                    onTest: onTest
                )
            }
        }
        .padding(.horizontal, AetherVisual.s3)
        .frame(minHeight: AetherVisual.listRowHeight)
        .background(
            listRowFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
        )
        .overlay {
            if row.isSelected {
                RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                    .strokeBorder(AetherVisual.tintBorder(.accentColor), lineWidth: 1)
            }
        }
    }

    private var listRowContent: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherRegionCode(name: row.member, reservesSlot: true)
            Text(row.member)
                .font(.body.weight(row.isSelected ? .semibold : .regular))
                .foregroundStyle(row.isSelectable ? AnyShapeStyle(.primary) : AnyShapeStyle(AetherVisual.secondaryText))
                .strikethrough(!row.isSelectable)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(memberTooltip)
            if let dialer = row.dialerProxy {
                dialerBadge(dialer)
            }
            if let recognition = row.recognition, !recognition.isSelectable {
                unsupportedBadge(recognition)
            }
            if let badge = row.badge {
                ProxyNodeBadge(badge: badge)
                    .transition(.opacity)
            }
            ProxyNodeAIAvailabilityBadge(member: row.member, egressStore: tunnel.egressProbeStore)
            Spacer(minLength: AetherVisual.s1)
            selectionAccessory
            if let protocolName = row.protocolName {
                AetherProtocolBadge(
                    type: protocolName,
                    transport: row.transportName,
                    canonicalKind: row.canonicalProtocolKind
                )
            }
        }
    }

    private var memberTooltip: String {
        if let recognition = row.recognition, !recognition.isSelectable {
            return "\(row.member) · \(recognition.localizedTitle)"
        }
        return row.member
    }

    private func unsupportedBadge(_ recognition: ProxyConfigurationSummary.Recognition) -> some View {
        HStack(spacing: AetherVisual.sMicro) {
            Image(systemName: recognition.symbol)
                .font(.caption2.weight(.semibold))
            Text(AppLocalization.string("Unsupported"))
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
        }
        .foregroundStyle(AetherReadableTint(color: .orange))
        .padding(.horizontal, AetherVisual.s1)
        .padding(.vertical, AetherVisual.sMicro)
        .background(
            AetherVisual.tintFill(.orange),
            in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
        )
        .fixedSize()
        .help(recognition.localizedTitle)
        .accessibilityIdentifier("proxy-node-unsupported-badge-\(row.member)")
    }

    @ViewBuilder
    private var selectionAccessory: some View {
        if showsSelectionControl {
            if row.isPending {
                ProgressView()
                    .controlSize(.mini)
            } else if row.isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                    .transition(.opacity)
            }
        } else if row.isSelected {
            Text(AppLocalization.string("Current"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(AetherReadableTint(color: .green))
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(
                    AetherVisual.tintFill(.green),
                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                )
                .fixedSize()
                .accessibilityIdentifier("proxy-node-badge-current")
                .transition(.opacity)
        }
    }

    private func dialerBadge(_ dialer: String) -> some View {
        HStack(spacing: AetherVisual.sMicro) {
            Image(systemName: "link")
                .font(.caption2.weight(.semibold))
            Text(AppLocalization.format("via %@", dialer))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: 140, alignment: .leading)
        .foregroundStyle(AetherVisual.secondaryText)
        .padding(.horizontal, AetherVisual.s1)
        .padding(.vertical, AetherVisual.sMicro)
        .background(
            AetherVisual.neutralFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
        )
        .help(dialer)
        .accessibilityIdentifier("proxy-node-dialer-badge-\(row.member)")
    }

    private func editChainedButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "slider.horizontal.3")
        }
        .aetherButton()
        .controlSize(.small)
        .disabled(!canEditOverrides)
        .help(AppLocalization.string("Edit chained proxy"))
        .accessibilityLabel(AppLocalization.string("Edit chained proxy"))
        .accessibilityIdentifier("proxy-edit-chained-\(row.member)")
    }

    private var cardFill: Color {
        if row.isSelected {
            return AetherVisual.selectionFill
        }
        return isHovered ? AetherVisual.hoverFill : AetherVisual.subtleFill
    }

    private var listRowFill: Color {
        if row.isSelected {
            return AetherVisual.selectionFill
        }
        return isHovered ? AetherVisual.hoverFill : Color.clear
    }
}

private struct OptionalChainedProxyActionModifier: ViewModifier {
    let action: (() -> Void)?

    func body(content: Content) -> some View {
        if let action {
            content.accessibilityAction(named: AppLocalization.string("Edit Chained Proxy…"), action)
        } else {
            content
        }
    }
}

/// Leaf observer so 10Hz latency flushes only redraw visible node badges and
/// sparklines rather than rebuilding the full 500-node group view.
private struct ProxyNodeLatencyAccessory: View {
    let groupName: String
    let member: String
    var isNodeSelectable = true
    var recognitionHint: String? = nil
    @ObservedObject var latencyStore: ProxyLatencyStore
    let tunnel: TunnelManager
    let onTest: () -> Void
    @State private var showsHistoryPopover = false

    var body: some View {
        let isTestingMember = latencyStore.proxyLatencyRequests.contains(groupName)
            || latencyStore.memberLatencyRequests.contains("\(groupName):\(member)")
        let status = ProxyLatencyStatus.status(
            member: member,
            state: latencyStore.proxyLatencies[groupName],
            isTesting: isTestingMember
        )
        let confidence: ProxyLatencyConfidence? = status.isMeasured
            ? tunnel.latencyConfidence(group: groupName, member: member)
            : nil
        let stats = tunnel.latencyStats(for: member)
        let measuredAt = latencyStore.latencyMeasuredAt[groupName]?[member]

        HStack(spacing: AetherVisual.s1) {
            if !stats.samples.isEmpty {
                historySparklineButton(stats: stats)
            }
            Button(action: onTest) {
                ProxyLatencyPill(status: status, confidence: confidence)
            }
            .buttonStyle(.aetherPressable)
            .disabled(status == .testing || !isNodeSelectable)
            .fixedSize()
            .help(
                isNodeSelectable
                    ? latencyHelp(measuredAt: measuredAt, stats: stats, confidence: confidence)
                    : (recognitionHint ?? AppLocalization.string("Unsupported"))
            )
            .accessibilityLabel(
                AppLocalization.format("Latency: %@", status.localizedTitle)
            )
            .accessibilityHint(
                isNodeSelectable
                    ? AppLocalization.string("Tests this node again")
                    : (recognitionHint ?? AppLocalization.string("Unsupported"))
            )
        }
    }

    private func historySparklineButton(stats: ProxyLatencyStats) -> some View {
        Button {
            showsHistoryPopover.toggle()
        } label: {
            HStack(spacing: AetherVisual.s1) {
                ProxyLatencySparkline(stats: stats)
                    .frame(
                        width: AetherVisual.s6 + AetherVisual.s3,
                        height: AetherVisual.s3
                    )
                if let jitter = stats.jitterMilliseconds {
                    Text(AppLocalization.format("±%lld ms", Int64(jitter)))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                if stats.lossRate > 0 {
                    let lossPercent = Int((stats.lossRate * 100.0).rounded())
                    Text(AppLocalization.format("%lld%%", Int64(lossPercent)))
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            AetherReadableTint(
                                color: stats.lossRate >= 0.25 ? .red : .orange
                            )
                        )
                        .padding(.horizontal, AetherVisual.sMicro)
                        .background(
                            AetherVisual.tintWash(
                                stats.lossRate >= 0.25 ? .red : .orange
                            ),
                            in: RoundedRectangle(
                                cornerRadius: AetherVisual.badgeRadius,
                                style: .continuous
                            )
                        )
                }
            }
            .padding(.horizontal, AetherVisual.s1)
            .padding(.vertical, AetherVisual.sMicro)
            .background(
                AetherVisual.neutralFill,
                in: RoundedRectangle(
                    cornerRadius: AetherVisual.controlRadius,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .help(AppLocalization.string("Latency history, jitter & packet loss"))
        .accessibilityLabel(AppLocalization.string("Latency history, jitter & packet loss"))
        .accessibilityIdentifier("proxy-latency-sparkline-\(member)")
        .popover(isPresented: $showsHistoryPopover, arrowEdge: .bottom) {
            ProxyLatencyHistoryPopover(member: member, stats: stats)
        }
    }

    private func latencyHelp(
        measuredAt: Date?,
        stats: ProxyLatencyStats,
        confidence: ProxyLatencyConfidence?
    ) -> String {
        var lines: [String] = []
        if let measuredAt {
            lines.append(AppLocalization.format(
                "Last tested at %@",
                AppLocalization.date(measuredAt, date: .omitted, time: .standard)
            ))
        } else {
            lines.append(AppLocalization.string("Test latency"))
        }
        if let jitter = stats.jitterMilliseconds {
            lines.append(
                AppLocalization.format("Jitter: ±%lld ms", Int64(jitter))
            )
        }
        if !stats.samples.isEmpty {
            let lossPercent = Int((stats.lossRate * 100.0).rounded())
            lines.append(
                AppLocalization.format("Loss: %lld%%", Int64(lossPercent))
            )
        }
        if let confidence {
            lines.append(confidence.localizedHint)
        }
        return lines.joined(separator: "\n")
    }
}

private struct ProxyMemberTableItem: Identifiable, Equatable {
    enum Badge: Equatable {
        /// Failover mode's preferred node.
        case preferred
        /// The node failover mode is using while the preferred one is down.
        case backupInUse
    }

    let member: String
    let protocolName: String?
    var canonicalProtocolKind: String? = nil
    var transportName: String? = nil
    var dialerProxy: String? = nil
    var recognition: ProxyConfigurationSummary.Recognition? = nil
    var chainedOverride: ChainedProxyOverride? = nil
    let isSelected: Bool
    let isBusy: Bool
    var isPending = false
    let showsLatency: Bool
    var badge: Badge?

    var isSelectable: Bool { recognition?.isSelectable ?? true }
    var id: String { member }
}

private struct ProxyLatencySparkline: View {
    let stats: ProxyLatencyStats

    var body: some View {
        Canvas { context, size in
            let samples = stats.samples
            guard !samples.isEmpty else { return }

            let validValues = samples.compactMap(\.latencyMilliseconds).map(Double.init)
            let minVal = validValues.min() ?? 0
            let maxVal = max((validValues.max() ?? 100), minVal + 1)
            let span = max(1, maxVal - minVal)
            let count = samples.count
            let stepX = count > 1 ? size.width / CGFloat(count - 1) : size.width
            let lineTint: Color = {
                if stats.lossRate >= 0.25 {
                    return .red
                }
                if let jitter = stats.jitterMilliseconds, jitter >= 60 {
                    return .orange
                }
                return .green
            }()
            let lineShading = GraphicsContext.Shading.style(AetherReadableTint(color: lineTint))
            let lossShading = GraphicsContext.Shading.style(AetherReadableTint(color: .red))

            var baseline = Path()
            baseline.move(to: CGPoint(x: 0, y: size.height - 1))
            baseline.addLine(to: CGPoint(x: size.width, y: size.height - 1))
            context.stroke(baseline, with: .color(Color(nsColor: .separatorColor)), lineWidth: 0.5)

            var linePath = Path()
            var hasStarted = false
            for (index, sample) in samples.enumerated() {
                let x = count > 1 ? CGFloat(index) * stepX : size.width * 0.5
                if let ms = sample.latencyMilliseconds {
                    let normalized = (Double(ms) - minVal) / span
                    let y = max(1.5, min(size.height - 2.0, (1.0 - normalized) * (size.height - 3.5) + 1.5))
                    let point = CGPoint(x: x, y: y)
                    if !hasStarted {
                        linePath.move(to: point)
                        hasStarted = true
                    } else {
                        linePath.addLine(to: point)
                    }
                    let dotRect = CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)
                    if count <= 8 {
                        context.fill(Path(ellipseIn: dotRect), with: lineShading)
                    }
                } else {
                    hasStarted = false
                    var lossTick = Path()
                    lossTick.move(to: CGPoint(x: x, y: max(0, size.height - 5)))
                    lossTick.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(lossTick, with: lossShading, lineWidth: 1.5)
                }
            }
            if hasStarted || validValues.count >= 2 {
                context.stroke(
                    linePath,
                    with: lineShading,
                    style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct ProxyLatencyHistoryPopover: View {
    let member: String
    let stats: ProxyLatencyStats

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(member)
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)

            ProxyLatencySparkline(stats: stats)
                .frame(
                    width: AetherVisual.s6 * 8,
                    height: AetherVisual.s6 * 2
                )
                .padding(AetherVisual.s2)
                .background(
                    AetherVisual.subtleFill,
                    in: RoundedRectangle(
                        cornerRadius: AetherVisual.insetRadius,
                        style: .continuous
                    )
                )

            HStack(spacing: AetherVisual.s4) {
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Avg RTT"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    Text(
                        stats.averageLatencyMilliseconds.map { AppLocalization.format("%lld ms", Int64($0)) } ?? "—"
                    )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Jitter"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    Text(
                        stats.jitterMilliseconds.map { AppLocalization.format("±%lld ms", Int64($0)) } ?? "—"
                    )
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                }

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Packet Loss"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    let lossPercent = Int((stats.lossRate * 100.0).rounded())
                    Text(AppLocalization.format("%lld%%", Int64(lossPercent)))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(
                            lossPercent > 0
                                ? AnyShapeStyle(AetherReadableTint(
                                    color: lossPercent >= 25 ? .red : .orange
                                ))
                                : AnyShapeStyle(.primary)
                        )
                }

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Samples"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    Text(verbatim: "\(stats.samples.count)/\(ProxyLatencyIndex.maxHistoryCount)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
            }
        }
        .padding(AetherVisual.s4)
    }
}

/// A latency result as coloured text, matching the app's unified delay bands.
/// When a measured value came from a bare TCP connect probe rather than a full
/// protocol round-trip, a small `TCP` caption precedes the number.
struct ProxyLatencyText: View {
    let status: ProxyLatencyStatus
    var confidence: ProxyLatencyConfidence? = nil

    var body: some View {
        if status == .testing {
            ProgressView()
                .controlSize(.mini)
                .transition(.opacity)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
                if status.isMeasured, confidence == .reachability {
                    Text(verbatim: "TCP")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityIdentifier("proxy-latency-tcp-badge")
                }
                Text(status.localizedTitle)
                    .font(.subheadline.weight(isResult ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(foregroundStyle)
                    .aetherNumericValue(status)
            }
        }
    }

    private var isResult: Bool {
        status.isMeasured || status == .timedOut
    }

    private var foregroundStyle: AnyShapeStyle {
        guard isResult else { return AnyShapeStyle(AetherVisual.secondaryText) }
        return AnyShapeStyle(AetherReadableTint(color: status.tint))
    }
}

private extension ProxyLatencyStatus {
    static func status(
        member: String,
        state: ProxyLatencyState?,
        isTesting: Bool
    ) -> ProxyLatencyStatus {
        switch ProxyLatencyReading.resolve(
            member: member,
            state: state,
            isTesting: isTesting
        ) {
        case .untested: .untested
        case .testing: .testing
        case let .responded(delay): .responded(delay)
        case .timedOut: .timedOut
        }
    }
}

/// Semantic tinted latency capsule for node rows and 2-column grid cards,
/// backed by `ProxyLatencyStatus.band` thresholds.
private struct ProxyLatencyPill: View {
    let status: ProxyLatencyStatus
    var confidence: ProxyLatencyConfidence? = nil

    var body: some View {
        if status == .testing {
            ProgressView()
                .controlSize(.mini)
                .padding(.horizontal, AetherVisual.pillHorizontalPadding)
                .padding(.vertical, AetherVisual.pillVerticalPadding)
                .background(AetherVisual.neutralFill, in: Capsule())
                .transition(.opacity)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
                if status.isMeasured, confidence == .reachability {
                    Text(verbatim: "TCP")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityIdentifier("proxy-latency-tcp-badge")
                }
                Text(status.localizedTitle)
                    .font(.caption.weight(isResult ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(foreground)
                    .aetherNumericValue(status)
            }
            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
            .padding(.vertical, AetherVisual.pillVerticalPadding)
            .background(background, in: Capsule())
        }
    }

    private var isResult: Bool {
        status.isMeasured || status == .timedOut
    }

    private var semanticColor: Color? {
        switch status.band {
        case .fast: return .green
        case .moderate: return .orange
        case .slow: return .red
        case nil: return status == .timedOut ? .red : nil
        }
    }

    private var foreground: AnyShapeStyle {
        guard let semanticColor else { return AnyShapeStyle(AetherVisual.secondaryText) }
        return AnyShapeStyle(AetherReadableTint(color: semanticColor))
    }

    private var background: Color {
        guard let semanticColor else { return AetherVisual.neutralFill }
        return AetherVisual.tintFill(semanticColor)
    }
}

/// "Preferred" or "Backup in use" beside a node's name in failover mode.
/// Lightweight leaf observer so egress probe updates only redraw probed node badges.
private struct ProxyNodeAIAvailabilityBadge: View {
    let member: String
    @ObservedObject var egressStore: EgressProbeStore

    var body: some View {
        if let report = egressStore.report(forNode: member) {
            let isAvailable = report.isAIAvailable
            let tint: Color = isAvailable ? .green : .orange
            let label = isAvailable
                ? AppLocalization.string("AI")
                : AppLocalization.string("AI Limited")
            let total = max(report.aiServices.count, EgressServiceKind.aiServices.count)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AetherReadableTint(color: tint))
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(
                    AetherVisual.tintFill(tint),
                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                )
                .fixedSize()
                .help(
                    AppLocalization.format(
                        "AI services available: %lld/%lld",
                        Int64(report.availableAICount),
                        Int64(total)
                    )
                )
                .accessibilityIdentifier("proxy-node-ai-badge-\(member)")
        }
    }
}

private struct ProxyNodeBadge: View {
    let badge: ProxyMemberTableItem.Badge

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(AetherReadableTint(color: tint))
            .padding(.horizontal, AetherVisual.s1)
            .padding(.vertical, AetherVisual.sMicro)
            .background(AetherVisual.tintFill(tint), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
            .fixedSize()
            .accessibilityIdentifier(badge == .preferred ? "proxy-node-badge-preferred" : "proxy-node-badge-backup")
    }

    private var title: String {
        switch badge {
        case .preferred: AppLocalization.string("Preferred")
        case .backupInUse: AppLocalization.string("Backup in use")
        }
    }

    private var tint: Color {
        switch badge {
        case .preferred: .accentColor
        case .backupInUse: .orange
        }
    }
}

/// Shown while failover mode uses a backup: which node is down, since when,
/// and that traffic returns on its own.
private struct FailoverBackupBanner: View {
    let preferred: String
    let backup: String
    let since: Date?

    var body: some View {
        Label {
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(AetherReadableTint(color: .orange))
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s3)
        .background(AetherVisual.tintFill(.orange), in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("proxy-failover-backup-banner")
    }

    private var message: String {
        if let since {
            return AppLocalization.format(
                "%1$@ stopped answering, so %2$@ took over at %3$@. Traffic returns to %1$@ once it answers again.",
                preferred,
                backup,
                AppLocalization.date(since, date: .omitted, time: .shortened)
            )
        }
        return AppLocalization.format(
            "%1$@ is not answering, so %2$@ is in use. Traffic returns to %1$@ once it answers again.",
            preferred,
            backup
        )
    }
}

/// The group's recent automatic switches, newest first. Kept for this run
/// only.
private struct ProxySwitchHistoryView: View {
    let events: [ProxySwitchEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(AppLocalization.string("Automatic switches"))
                .font(.headline)
            if events.isEmpty {
                Text(AppLocalization.string("No automatic switches yet."))
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .padding(.vertical, AetherVisual.s2)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(events) { event in
                            row(event)
                            if event.id != events.last?.id {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
            Text(AppLocalization.string("Kept until AetherRoute quits."))
                .font(.caption)
                .foregroundStyle(AetherVisual.tertiaryText)
        }
        .padding(AetherVisual.s4)
        .frame(width: 340)
        .accessibilityIdentifier("proxy-switch-history")
    }

    private func row(_ event: ProxySwitchEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s3) {
            Text(AppLocalization.date(event.date, date: .omitted, time: .standard))
                .font(.caption.monospacedDigit())
                .foregroundStyle(AetherVisual.secondaryText)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s1) {
                    Text(event.from ?? "—")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "arrow.right")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                    Text(event.to)
                        .fontWeight(.semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.callout)
                Text(event.reason.localizedTitle)
                    .font(.caption)
                    .foregroundStyle(event.reason == .unresponsive
                        ? AnyShapeStyle(AetherReadableTint(color: .orange))
                        : AnyShapeStyle(AetherVisual.secondaryText))
            }
        }
        .padding(.vertical, AetherVisual.s2)
        .accessibilityElement(children: .combine)
    }
}

extension ProxySelectionMode {
    var symbol: String {
        switch self {
        case .manual: "hand.point.up.left"
        case .fastest: "bolt.fill"
        case .failover: "arrow.triangle.branch"
        }
    }

    var localizedTitle: String {
        switch self {
        case .manual: AppLocalization.string("Manual")
        case .fastest: AppLocalization.string("Fastest")
        case .failover: AppLocalization.string("Failover")
        }
    }

    var localizedExplanation: String {
        switch self {
        case .manual:
            AppLocalization.string("The node you pick stays in use, even when it stops answering.")
        case .fastest:
            AppLocalization.string("Uses the fastest node that works, and moves on as soon as it stops answering.")
        case .failover:
            AppLocalization.string("Uses the node you pick. When it stops answering, the fastest working node takes over until it answers again.")
        }
    }
}

extension ProxySwitchEvent.Reason {
    var localizedTitle: String {
        switch self {
        case .unresponsive: AppLocalization.string("Previous node stopped answering")
        case .preferredRecovered: AppLocalization.string("Preferred node answers again")
        }
    }
}

// MARK: - Inventory (opened from Settings › Privacy & Diagnostics)

/// Every node and provider in the active profile, for troubleshooting
/// subscription parsing or protocol support.
struct ProxyInventorySheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "server.rack",
                title: AppLocalization.string("Node inventory & providers"),
                subtitle: AppLocalization.string("For troubleshooting subscription parsing or protocol support."),
                tint: AppSection.proxies.tileColor
            )
            ScrollView {
                VStack(alignment: .leading, spacing: AetherVisual.s4) {
                    if let summary = tunnel.activeProfileSummary {
                        if !summary.proxies.isEmpty {
                            ProxyNodeInventory(
                                proxies: summary.proxies,
                                groups: summary.proxyGroups,
                                totalProxyCount: summary.proxyCount
                            )
                        }
                        if !summary.proxyProviders.isEmpty {
                            FeatureSection(title: AppLocalization.string("Providers")) {
                                VStack(spacing: 0) {
                                    ForEach(summary.proxyProviders) { provider in
                                        ProviderRow(provider: provider)
                                        if provider.id != summary.proxyProviders.last?.id {
                                            Divider().padding(.leading, AetherVisual.rowDividerInset)
                                        }
                                    }
                                }
                                .aetherPanel()
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button(AppLocalization.string("Done")) { dismiss() }
                    .aetherButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .accessibilityIdentifier("proxy-inventory-sheet")
    }
}

private struct ProxyNodeInventory: View {
    let proxies: [ProxyConfigurationSummary]
    let groups: [ProxyGroupConfigurationSummary]
    let totalProxyCount: Int

    var body: some View {
        let membershipByNode = precomputedMemberships()
        FeatureSection(title: AppLocalization.string("Nodes")) {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(inventorySummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)

                Table(proxies) {
                    TableColumn(AppLocalization.string("Name")) { proxy in
                        Text(proxy.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .strikethrough(!proxy.recognition.isSelectable)
                            .lineLimit(1)
                            .help(proxy.name)
                    }
                    .width(min: 84, ideal: 96)
                    TableColumn(AppLocalization.string("Protocol")) { proxy in
                        let protocolSummary = "\(proxy.protocolName.uppercased()) · \(proxy.effectiveTransportName)"
                        Text(verbatim: protocolSummary)
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(protocolSummary)
                    }
                    .width(min: 88, ideal: 108, max: 136)
                    TableColumn(AppLocalization.string("In groups")) { proxy in
                        let label = membershipByNode[proxy.name] ?? AppLocalization.string("In no group")
                        Text(label)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(label)
                    }
                    .width(min: 80, ideal: 96, max: 170)
                    TableColumn(AppLocalization.string("Core status")) { proxy in
                        Label(
                            proxy.recognition.localizedTitle,
                            systemImage: proxy.recognition.symbol
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(proxy.recognition.localizedTitle)
                    }
                    .width(min: 128, ideal: 176, max: 260)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .accessibilityLabel(AppLocalization.string("Proxy nodes"))
                .accessibilityIdentifier("proxy-node-inventory-table")
                .scrollIndicators(.hidden, axes: .horizontal)
                .environment(\.defaultMinListRowHeight, 36)
                .frame(height: min(CGFloat(proxies.count * 36 + 34), 320))
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: AetherVisual.panelRadius,
                        style: .continuous
                    )
                )
                .aetherPanel()

                TruncationNotice(
                    visibleCount: proxies.count,
                    totalCount: totalProxyCount
                )
            }
        }
    }

    private var inventorySummary: String {
        let usable = proxies.filter {
            $0.recognition.isUsable && !InitialProxySelectionPolicy.isSubscriptionMetadata($0.name)
        }
        let realCount = proxies.filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0.name) }.count
        return AppLocalization.format(
            "%lld total · %lld usable · %lld unsupported",
            Int64(realCount),
            Int64(usable.count),
            Int64(realCount - usable.count)
        )
    }

    private func precomputedMemberships() -> [String: String] {
        var ownersByNode: [String: [String]] = [:]
        for group in groups {
            for member in group.members {
                ownersByNode[member, default: []].append(group.name)
            }
        }
        return ownersByNode.mapValues { $0.joined(separator: " · ") }
    }
}

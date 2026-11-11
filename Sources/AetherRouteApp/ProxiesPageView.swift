import AetherRouteKit
import SwiftUI

/// Choosing a node and testing latency, nothing else: the groups beside the
/// nodes of the chosen one. Inventory and provider details for
/// troubleshooting live in Settings › Privacy & Diagnostics.
///
/// The page itself does not scroll (2.10): the group column and the node
/// list scroll on their own, so the group's header, search, sort and
/// latency test stay in view however long a subscription is.
struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    /// By name rather than summary id: the synthetic GLOBAL group shown in
    /// global mode is not part of the profile summary.
    @State private var selectedGroupName: String?
    @State private var showsNewGroup = false
    @State private var showsRegionGroups = false
    @State private var showsHiddenNodes = false
    @State private var showsChainedProxy = false
    /// Kept here rather than in the group card so switching groups keeps
    /// the search, the sort and the filter.
    @State private var sort: ProxyNodeSort = .default
    @State private var searchText = ""
    @State private var hidesTimedOutNodes = false
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
                        FeatureEmptyState(
                            symbol: "point.3.connected.trianglepath.dotted",
                            title: AppLocalization.string("No proxies yet"),
                            detail: AppLocalization.string("Import a validated profile to inspect its endpoints and proxy groups.")
                        )
                    }
                    .aetherPageContent(.wide)
                }
            }
        }
        .accessibilityIdentifier("proxies-page")
#if DEBUG
        .task {
            // Isolated screenshot review only: open one sheet on launch.
            switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_SHEET"] {
            case "new-group": showsNewGroup = true
            case "region-groups": showsRegionGroups = true
            case "hidden-nodes": showsHiddenNodes = true
            case "chained-proxy": showsChainedProxy = true
            default: break
            }
        }
#endif
    }

    private func content(summary: ProfileConfigurationSummary) -> some View {
        // Wide enough for the groups to sit in a column beside their
        // members, read from the page's size in the first layout pass. (A
        // state set by onGeometryChange drew the narrow layout first and
        // then switched, moving every glass panel on the page.)
        GeometryReader { page in
            let isWideGroupLayout = page.size.width >= Self.wideGroupLayoutWidth
            groupsAndCard(summary: summary, isWideGroupLayout: isWideGroupLayout)
        }
        .sheet(isPresented: $showsNewGroup) {
            CustomProxyGroupSheet(defaultParent: catchAllGroup(in: summary))
        }
        .sheet(isPresented: $showsChainedProxy) {
            ChainedProxySheet(defaultParent: catchAllGroup(in: summary))
        }
        .sheet(isPresented: $showsRegionGroups) {
            RegionGroupsSheet(defaultParent: catchAllGroup(in: summary))
        }
        .sheet(isPresented: $showsHiddenNodes) {
            HiddenNodesSheet()
        }
    }

    private func groupsAndCard(
        summary: ProfileConfigurationSummary,
        isWideGroupLayout: Bool
    ) -> some View {
        let groups = displayedGroups(summary: summary)
        return VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
            AetherPageHeader(.proxies) { overrideActions }
            ProfileCompatibilityNotice(report: summary.compatibility)
            if let notice = summary.subscriptionNotice {
                ProxySubscriptionNoticeBar(notice: notice)
            }

            if !groups.isEmpty {
                if groups.count > 1, isWideGroupLayout {
                    // Groups in a column beside their members, so the
                    // current choice of every group stays in view.
                    HStack(alignment: .top, spacing: AetherVisual.s4) {
                        proxyGroupColumn(groups: groups)
                            .frame(width: Self.groupColumnWidth)
                        // Level with the group card, below its heading.
                        activeGroupView(summary: summary, groups: groups)
                            .padding(.top, AetherVisual.s5 + AetherVisual.s1)
                    }
                    .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    // One group needs no switcher; the card names it.
                    HStack(spacing: AetherVisual.s2) {
                        if groups.count > 1 {
                            proxyGroupTabBar(groups: groups)
                        }
                        Spacer(minLength: 0)
                        newGroupButton
                    }
                    activeGroupView(summary: summary, groups: groups)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            } else {
                HStack(spacing: AetherVisual.s2) {
                    Spacer(minLength: 0)
                    newGroupButton
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
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isWideGroupLayout)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Proxy configuration"))
        .accessibilityIdentifier("proxies-page-content")
    }

    /// The profile's groups, with GLOBAL first while global mode routes
    /// every connection through it.
    private func displayedGroups(summary: ProfileConfigurationSummary) -> [ProxyGroupConfigurationSummary] {
        guard tunnel.routingMode == .global,
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
    private var newGroupButton: some View {
        Button {
            showsNewGroup = true
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
    private var overrideActions: some View {
        Menu {
            Button(AppLocalization.string("New Group") + "…", systemImage: "plus.rectangle.on.folder") {
                showsNewGroup = true
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-more-new-group")
            Divider()
            Button(AppLocalization.string("Chained Proxy…"), systemImage: "link.badge.plus") {
                showsChainedProxy = true
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-chained-proxy")
            Button(AppLocalization.string("Groups by Region…"), systemImage: "globe.asia.australia") {
                showsRegionGroups = true
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-region-groups")
            Button(AppLocalization.string("Hide Nodes…"), systemImage: "eye.slash") {
                showsHiddenNodes = true
            }
            .disabled(!canEditOverrides)
            .accessibilityIdentifier("proxies-hidden-nodes")
            Divider()
            Toggle(
                AppLocalization.inline("Show subscription info entries", chinese: "显示订阅信息节点"),
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
    /// but not in the middle of a connect or another profile operation.
    private var canEditOverrides: Bool {
        !tunnel.isTransitioning && !tunnel.isUpdatingProfiles && !tunnel.isRefreshingSubscription
    }

    nonisolated private static let wideGroupLayoutWidth: CGFloat = 720
    private static let groupColumnWidth: CGFloat = 236

    @ViewBuilder
    private func activeGroupView(
        summary: ProfileConfigurationSummary,
        groups: [ProxyGroupConfigurationSummary]
    ) -> some View {
        if let activeGroup = currentGroup(from: groups, summary: summary) {
            ActiveProxyGroupView(
                group: activeGroup,
                // A repeated node name must not trap while the page renders.
                protocols: Dictionary(
                    summary.proxies.map { ($0.name, $0.protocolName) },
                    uniquingKeysWith: { first, _ in first }
                ),
                transports: Dictionary(
                    summary.proxies.compactMap { proxy in
                        proxy.transportName.map { (proxy.name, $0) }
                    },
                    uniquingKeysWith: { first, _ in first }
                ),
                dialers: Dictionary(
                    summary.proxies.compactMap { proxy in
                        proxy.dialerProxy.map { (proxy.name, $0) }
                    },
                    uniquingKeysWith: { first, _ in first }
                ),
                sort: $sort,
                searchText: $searchText,
                hidesTimedOutNodes: $hidesTimedOutNodes,
                usesGridLayout: $usesGridLayout,
                showsSubscriptionNotices: showsSubscriptionNotices
            )
            // Opt-in (Settings › Network): one test when a group comes into
            // view, throttled per group so switching back and forth is free.
            .task(id: activeGroup.name) {
                await tunnel.testLatencyOnOpenIfDue(group: activeGroup.name)
            }
        }
    }

    /// The groups as a vertical list beside the members of the chosen one;
    /// the list scrolls on its own.
    private func proxyGroupColumn(groups: [ProxyGroupConfigurationSummary]) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Proxy groups")) {
                newGroupButton
            }
            ScrollView {
                VStack(spacing: AetherVisual.sMicro) {
                    ForEach(groups) { group in
                        groupButton(group, in: groups, fillsWidth: true)
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
    private func proxyGroupTabBar(groups: [ProxyGroupConfigurationSummary]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: AetherVisual.s1) {
                ForEach(groups) { group in
                    groupButton(group, in: groups, fillsWidth: false)
                }
            }
            .padding(AetherVisual.sMicro)
        }
    }

    private func groupButton(
        _ group: ProxyGroupConfigurationSummary,
        in groups: [ProxyGroupConfigurationSummary],
        fillsWidth: Bool
    ) -> some View {
        ProxyGroupTabButton(
            group: group,
            title: proxyGroupDisplayName(group.name),
            isSelected: currentGroup(from: groups, summary: tunnel.activeProfileSummary)?.name == group.name,
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
        if tunnel.routingMode == .global,
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
    return AppLocalization.inline("GLOBAL (Global exit)", chinese: "GLOBAL（全局出口）")
}

extension AppLocalization {
    /// Copy added before it reaches the string catalog. The catalog wins as
    /// soon as it has the key; until then the Chinese text is used whenever
    /// the app runs in Chinese (read from a key the catalog has always had).
    static func inline(_ english: String, chinese: String) -> String {
        let localized = string(english)
        if localized != english { return localized }
        return string("Proxy groups") == "Proxy groups" ? english : chinese
    }
}

/// Shared with the overview, which shows a group when one is the outlet.
func proxyGroupSymbol(_ strategy: String) -> String {
    switch strategy.lowercased() {
    case "select": return "square.stack.3d.up.fill"
    case "url-test": return "bolt.fill"
    case "fallback": return "arrow.triangle.branch"
    case "load-balance": return "scale.3d"
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
            parts.append(String(
                format: AppLocalization.inline("Remaining %@", chinese: "剩余流量 %@"),
                remaining
            ))
        }
        if notice.isLongTerm {
            parts.append(AppLocalization.inline("No expiry", chinese: "长期有效"))
        } else if let expiry = notice.expiry {
            parts.append(String(
                format: AppLocalization.inline("Expires %@", chinese: "到期 %@"),
                expiry
            ))
        }
        if parts.isEmpty, let first = notice.contacts.first ?? notice.noticeNames.first {
            parts.append(first)
        } else if parts.isEmpty {
            parts.append(AppLocalization.inline("Subscription info", chinese: "订阅信息"))
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
        default: strategy
        }
    }
}

// MARK: - The chosen group

/// One card: the group and its current node with its controls pinned on
/// top, then the nodes, which scroll on their own.
private struct ActiveProxyGroupView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    /// A choice made while disconnected takes effect later; say so for a
    /// moment instead of keeping a permanent caption on the card.
    @State private var showsNextConnectionNote = false
    @State private var showsSwitchHistory = false
    @State private var editsCustomGroup = false
    @State private var chainedProxyToEdit: ChainedProxyOverride?
    /// The row just clicked, per group, so only it shows a spinner while
    /// the switch is applied.
    @State private var pendingSelections: [String: String] = [:]
    let group: ProxyGroupConfigurationSummary
    let protocols: [String: String]
    var transports: [String: String] = [:]
    var dialers: [String: String] = [:]
    @Binding var sort: ProxyNodeSort
    @Binding var searchText: String
    @Binding var hidesTimedOutNodes: Bool
    @Binding var usesGridLayout: Bool
    var showsSubscriptionNotices = false

    private static let listTopAnchor = "proxy-node-list-top"

    var body: some View {
        let allMembers = members
        let rows = computeMemberRows(from: allMembers)
        return ScrollViewReader { scroller in
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.top, AetherVisual.s3)
                    .padding(.bottom, AetherVisual.s2)
                if !allMembers.isEmpty {
                    toolbar(memberCount: allMembers.count, rows: rows, scroller: scroller)
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.bottom, AetherVisual.s3)
                }

                if tunnel.isConnected, let preferredMember, let backupMember {
                    FailoverBackupBanner(
                        preferred: preferredMember,
                        backup: backupMember,
                        since: tunnel.proxySwitchLog.latest(forGroup: group.name)
                            .flatMap { $0.reason == .unresponsive && $0.to == backupMember ? $0.date : nil }
                    )
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.bottom, AetherVisual.s3)
                    .transition(AetherVisual.insertion)
                }

                if let message = tunnel.proxySelectionMessages[group.name] {
                    AetherInlineMessage(text: message, isCompact: true)
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.bottom, AetherVisual.s3)
                        .transition(AetherVisual.insertion)
                }

                Divider().padding(.horizontal, AetherVisual.s4)

                ScrollView {
                    Color.clear.frame(height: 0).id(Self.listTopAnchor)
                    if allMembers.isEmpty {
                        Text(AppLocalization.string("This group has no nodes."))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(AetherVisual.s4)
                    } else if rows.isEmpty {
                        Text(AppLocalization.string("No matching nodes"))
                            .font(.subheadline)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .frame(maxWidth: .infinity)
                            .padding(AetherVisual.s4)
                    } else {
                        nodeList(rows: rows)
                            .padding(AetherVisual.listCardInset)
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .accessibilityIdentifier("proxy-node-scroll")
            }
            .onChange(of: group.name) { _, _ in
                scroller.scrollTo(Self.listTopAnchor, anchor: .top)
            }
        }
        .aetherPanel()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.proxySelectionMessages[group.name])
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: showsNextConnectionNote)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: backupMember)
        .task(id: "\(group.name)|\(tunnel.isConnected)") {
            guard isManuallySelectable else { return }
            await tunnel.refreshProxySelection(group: group.name)
        }
        .task(id: showsNextConnectionNote) {
            guard showsNextConnectionNote else { return }
            try? await Task.sleep(for: .seconds(4))
            showsNextConnectionNote = false
        }
        .onChange(of: tunnel.proxySelectionRequests) { _, requests in
            pendingSelections = pendingSelections.filter { requests.contains($0.key) }
        }
        .sheet(item: $chainedProxyToEdit) { item in
            ChainedProxySheet(initial: item)
        }
    }

    // MARK: Header

    private var header: some View {
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
                        .lineLimit(1)
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
                    editsCustomGroup = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .aetherButton()
                .controlSize(.small)
                .help(AppLocalization.string("Edit group"))
                .accessibilityLabel(AppLocalization.string("Edit group"))
                .accessibilityIdentifier("proxy-edit-custom-group")
                .sheet(isPresented: $editsCustomGroup) {
                    CustomProxyGroupSheet(initial: customGroup)
                }
            }
            if selectionMode.switchesAutomatically {
                switchHistoryButton
            }
            if isManuallySelectable, !isGlobalGroup {
                selectionModeMenu
            }
            Button {
                Task { await tunnel.testProxyLatency(group: group.name) }
            } label: {
                AetherProgressButtonLabel(AppLocalization.string("Test latency"), systemImage: "bolt", isWorking: isTesting)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 72)
            }
            .aetherButton()
            .controlSize(.small)
            .disabled(isTesting)
            .help(lastTestedHelp)
            .accessibilityIdentifier("proxy-test-latency-\(group.name)")
        }
    }

    /// Search, count and the view controls, pinned above the nodes.
    private func toolbar(
        memberCount: Int,
        rows: [ProxyMemberTableItem],
        scroller: ScrollViewProxy
    ) -> some View {
        HStack(spacing: AetherVisual.s2) {
            AetherSearchField(
                text: $searchText,
                prompt: AppLocalization.string("Search nodes"),
                accessibilityIdentifier: "proxy-node-search-field"
            )
            .frame(maxWidth: 320)
            Text(String(
                format: AppLocalization.inline("%lld nodes", chinese: "%lld 个节点"),
                Int64(memberCount)
            ))
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
            .accessibilityIdentifier("proxy-group-node-count")
            Spacer(minLength: AetherVisual.s2)
            sortMenu
            layoutToggle
            locateButton(rows: rows, scroller: scroller)
        }
    }

    private var layoutToggle: some View {
        Button {
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                usesGridLayout.toggle()
            }
        } label: {
            Image(systemName: usesGridLayout ? "list.bullet" : "square.grid.2x2")
                .contentTransition(.symbolEffect(.replace))
        }
        .aetherButton()
        .controlSize(.small)
        .help(layoutToggleTitle)
        .accessibilityLabel(layoutToggleTitle)
        .accessibilityIdentifier("proxy-layout-toggle")
    }

    private var layoutToggleTitle: String {
        usesGridLayout
            ? AppLocalization.inline("Show as list", chinese: "单列列表")
            : AppLocalization.inline("Show as grid", chinese: "双列网格")
    }

    private func locateButton(rows: [ProxyMemberTableItem], scroller: ScrollViewProxy) -> some View {
        let target = rows.first(where: \.isSelected)?.member
        let title = AppLocalization.inline("Locate current node", chinese: "定位当前节点")
        return Button {
            guard let target else { return }
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                scroller.scrollTo(target, anchor: .center)
            }
        } label: {
            Image(systemName: "scope")
        }
        .aetherButton()
        .controlSize(.small)
        .disabled(target == nil)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("proxy-locate-current-node")
    }

    /// Manual, fastest or failover, in a compact menu instead of a row of
    /// its own that pushed the nodes down.
    private var selectionModeMenu: some View {
        Menu {
            Picker(
                AppLocalization.string("Node selection"),
                selection: Binding(
                    get: { selectionMode },
                    set: { mode in
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
                    Label(mode.localizedTitle, systemImage: mode.symbol).tag(mode)
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
                if !isBuiltInOutlet(selectedMember), status(for: selectedMember).isMeasured {
                    Text(verbatim: "·")
                        .foregroundStyle(AetherVisual.secondaryText)
                    ProxyLatencyText(
                        status: status(for: selectedMember),
                        confidence: tunnel.latencyConfidence(group: group.name, member: selectedMember)
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
        guard isManuallySelectable, let selectedMember,
              let leaf = tunnel.automaticGroupLeaves[selectedMember],
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
        .help(String.localizedStringWithFormat(AppLocalization.string("Sort: %@"), sort.localizedTitle))
        .accessibilityLabel(AppLocalization.string("Sort"))
        .accessibilityValue(sort.localizedTitle)
        .accessibilityIdentifier("proxy-sort-picker")
    }

    /// The last result's time, on the button that refreshes it.
    private var lastTestedHelp: String {
        guard let latest = tunnel.latencyMeasuredAt[group.name]?.values.max() else {
            return AppLocalization.string("Test latency for current group nodes")
        }
        return String.localizedStringWithFormat(
            AppLocalization.string("Last tested at %@"),
            AppLocalization.date(latest, date: .omitted, time: .standard)
        )
    }

    /// What a group that picks its own node does, so its rows not being
    /// clickable is explained rather than discovered.
    private var automaticGroupNote: String {
        switch group.strategy.lowercased() {
        case "url-test": AppLocalization.string("This group automatically uses the node with the lowest latency.")
        case "fallback": AppLocalization.string("This group uses the first node that responds, in list order.")
        case "load-balance": AppLocalization.string("This group spreads connections across its nodes.")
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
                        GridItem(.flexible(), spacing: AetherVisual.sMicro),
                        GridItem(.flexible(), spacing: AetherVisual.sMicro),
                    ],
                    spacing: AetherVisual.sMicro
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
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: rows.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Proxy group members"))
        .accessibilityIdentifier("proxy-group-members-table")
    }

    private func nodeRow(_ row: ProxyMemberTableItem, isCompact: Bool) -> some View {
        ProxyNodeRow(
            row: row,
            canSelect: isManuallySelectable && !isAutomaticSelectionMode,
            showsSelectionControl: isManuallySelectable,
            isCompact: isCompact,
            measuredAt: tunnel.latencyMeasuredAt[group.name]?[row.member],
            onSelect: {
                pendingSelections[group.name] = row.member
                Task {
                    await tunnel.selectProxy(group: group.name, member: row.member)
                    if pendingSelections[group.name] == row.member {
                        pendingSelections[group.name] = nil
                    }
                    if !tunnel.isConnected {
                        showsNextConnectionNote = true
                    }
                }
            },
            onTest: {
                Task { await tunnel.testSingleProxyLatency(group: group.name, member: row.member) }
            },
            onEditChained: row.chainedOverride.map { item in
                { chainedProxyToEdit = item }
            }
        )
        .id(row.member)
    }

    private func memberType(_ member: String, groupNames: Set<String>) -> String {
        switch member.uppercased() {
        case "DIRECT": return AppLocalization.string("Direct")
        case "REJECT", "REJECT-DROP": return AppLocalization.string("Reject")
        default:
            if let protocolName = protocols[member] { return protocolName.uppercased() }
            if groupNames.contains(member) {
                return AppLocalization.string("Proxy group")
            }
            return AppLocalization.string("Unknown")
        }
    }

    private func computeMemberRows(from uniqueMembers: [String]) -> [ProxyMemberTableItem] {
        guard !uniqueMembers.isEmpty else { return [] }

        let groupNameSet = Set(tunnel.activeProfileSummary?.proxyGroups.map(\.name) ?? [])
        let groupIsTesting = tunnel.proxyLatencyRequests.contains(group.name)
        let resultByMember: [String: UInt32?] = Dictionary(
            (tunnel.proxyLatencies[group.name]?.results ?? []).map { ($0.member, $0.delayMilliseconds) },
            uniquingKeysWith: { first, _ in first }
        )
        let statusByMember: [String: ProxyLatencyStatus] = Dictionary(
            uniqueMembers.map { member in
                let isMemberTesting = groupIsTesting
                    || tunnel.isTestingLatency(group: group.name, member: member)
                let resolvedStatus: ProxyLatencyStatus
                if let measured = resultByMember[member] {
                    resolvedStatus = measured.map(ProxyLatencyStatus.responded) ?? .timedOut
                } else {
                    resolvedStatus = isMemberTesting ? .testing : .untested
                }
                return (member, resolvedStatus)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let typeByMember: [String: String] = Dictionary(
            uniqueMembers.map { ($0, memberType($0, groupNames: groupNameSet)) },
            uniquingKeysWith: { first, _ in first }
        )
        let chainedByName: [String: ChainedProxyOverride] = Dictionary(
            tunnel.activeProfileOverrides.chainedProxies.map { ($0.name, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        let currentSelected = currentRowMember(in: uniqueMembers)
        let sorted = ProxyPageNodeOrder.sorted(members: uniqueMembers, by: sort) {
            latencyRank(statusByMember[$0] ?? .untested)
        }
        let ordered = NodeRegion.filterMembers(
            sorted,
            protocolByName: typeByMember,
            transportByName: transports,
            dialerByName: dialers,
            query: searchText,
            hideTimedOut: hidesTimedOutNodes,
            isTimedOut: { statusByMember[$0] == .timedOut },
            selectedMember: currentSelected
        )
        let isBusy = tunnel.proxySelectionRequests.contains(group.name)
        let pending = isBusy ? pendingSelections[group.name] : nil
        let currentPreferred = preferredMember
        let currentBackup = backupMember
        return ordered.map { member in
            let status = statusByMember[member] ?? .untested
            return ProxyMemberTableItem(
                member: member,
                protocolName: typeByMember[member],
                transportName: transports[member],
                dialerProxy: dialers[member],
                chainedOverride: chainedByName[member],
                status: status,
                confidence: status.isMeasured
                    ? tunnel.latencyConfidence(group: group.name, member: member)
                    : nil,
                isSelected: member == currentSelected,
                isBusy: isBusy,
                isPending: member == pending,
                showsLatency: !isBuiltInOutlet(member),
                badge: member == currentPreferred
                    ? .preferred
                    : (member == currentBackup ? .backupInUse : nil)
            )
        }
    }

    /// The row marked as in use: the group's choice, or for a group that
    /// picks its own node, the node its live connections go through.
    private func currentRowMember(in members: [String]) -> String? {
        guard !isManuallySelectable,
              let leaf = tunnel.automaticGroupLeaves[group.name],
              members.contains(leaf) else {
            return tunnel.proxySelections[group.name]?.selectedMember
        }
        return leaf
    }

    /// DIRECT and REJECT are not servers: a delay measured through them says
    /// nothing about choosing a node, and a slow direct probe read as a fault.
    /// A profile node of `type: direct` behaves the same under another name.
    private func isBuiltInOutlet(_ member: String) -> Bool {
        let outlets: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP"]
        return outlets.contains(member.uppercased())
            || outlets.contains(protocols[member]?.uppercased() ?? "")
    }

    private var isAutomaticSelectionMode: Bool {
        selectionMode == .fastest
    }

    private var selectionMode: ProxySelectionMode {
        tunnel.proxySelectionMode(for: group.name)
    }

    private var customGroup: CustomProxyGroup? {
        tunnel.customProxyGroup(named: group.name)
    }

    private var isGlobalGroup: Bool {
        group.name == "GLOBAL"
    }

    private var preferredMember: String? {
        selectionMode == .failover ? tunnel.preferredProxyMembers[group.name] : nil
    }

    /// Failover mode is on a backup: the node in use is not the preferred one.
    private var backupMember: String? {
        guard let preferredMember, let selectedMember,
              selectedMember != preferredMember else { return nil }
        return selectedMember
    }

    /// Subscription notices ("剩余流量：…") are not servers; they stay out of
    /// the list and the count unless asked for in the More menu.
    private var members: [String] {
        let all = ProxyPageNodeOrder.uniqueMembersPreservingOrder(
            tunnel.proxySelections[group.name]?.members ?? group.members
        )
        guard !showsSubscriptionNotices else { return all }
        return all.filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }
    }

    private func latencyRank(_ status: ProxyLatencyStatus) -> Int {
        switch status {
        case let .responded(milliseconds): Int(milliseconds)
        case .timedOut: Int.max - 2
        case .testing: Int.max - 1
        case .untested: Int.max
        }
    }

    /// The node in use: the choice of a select group, or the node a
    /// url-test, fallback or load-balance group is using right now.
    private var selectedMember: String? {
        let selected = tunnel.proxySelections[group.name]?.selectedMember
        guard isManuallySelectable else {
            return tunnel.automaticGroupLeaves[group.name] ?? selected
        }
        return selected
    }

    private var isTesting: Bool {
        tunnel.proxyLatencyRequests.contains(group.name)
    }

    private var isManuallySelectable: Bool {
        group.strategy.lowercased() == "select"
    }

    private func status(for member: String) -> ProxyLatencyStatus {
        ProxyLatencyStatus.status(
            member: member,
            results: tunnel.proxyLatencies[group.name]?.results,
            isTesting: tunnel.isTestingLatency(group: group.name, member: member)
        )
    }
}
// MARK: - Node row

/// Selection, region, name, protocol and latency on one line (or a compact
/// two-column card when `isCompact` is true). In a group that picks its own
/// node the row is information only: no radio, and the node in use carries
/// a "Current" tag.
private struct ProxyNodeRow: View {
    let row: ProxyMemberTableItem
    let canSelect: Bool
    let showsSelectionControl: Bool
    var isCompact = false
    let measuredAt: Date?
    let onSelect: () -> Void
    let onTest: () -> Void
    var onEditChained: (() -> Void)? = nil
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: isCompact ? AetherVisual.s2 : AetherVisual.s3) {
            if showsSelectionControl {
                Button(action: onSelect) {
                    rowContent.contentShape(Rectangle())
                }
                .buttonStyle(.aetherPressable)
                .disabled((row.isBusy && !row.isPending) || !canSelect)
                .accessibilityLabel(row.member)
                .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            } else {
                // Not a disabled button: that would grey out rows that are
                // simply not meant to be clicked.
                rowContent
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            }

            if let onEditChained, !isCompact {
                Button(action: onEditChained) {
                    Image(systemName: "slider.horizontal.3")
                }
                .aetherButton()
                .controlSize(.small)
                .help(AppLocalization.string("Edit chained proxy"))
                .accessibilityLabel(AppLocalization.string("Edit chained proxy"))
                .accessibilityIdentifier("proxy-edit-chained-\(row.member)")
            }

            Group {
                if row.showsLatency {
                    Button(action: onTest) {
                        ProxyLatencyText(status: row.status, confidence: row.confidence)
                    }
                    .buttonStyle(.aetherPressable)
                    .disabled(row.status == .testing)
                    .help(latencyHelp)
                    .accessibilityLabel(
                        String.localizedStringWithFormat(
                            AppLocalization.string("Latency: %@"),
                            row.status.localizedTitle
                        )
                    )
                    .accessibilityHint(AppLocalization.string("Tests this node again"))
                }
            }
            .frame(minWidth: isCompact ? 64 : 84, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, isCompact ? AetherVisual.sRow : AetherVisual.s3)
        .frame(minHeight: isCompact ? 36 : AetherVisual.listRowHeight)
        .background(rowFill, in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: row.isSelected)
        .contextMenu {
            if showsSelectionControl {
                Button(AppLocalization.string("Switch to this node"), action: onSelect)
                    .disabled((row.isBusy && !row.isPending) || !canSelect)
            }
            if row.showsLatency {
                Button(AppLocalization.string("Test latency"), action: onTest)
            }
            if let onEditChained {
                Divider()
                Button(AppLocalization.string("Edit Chained Proxy…"), action: onEditChained)
            }
            Divider()
            Button(AppLocalization.string("Copy node name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.member, forType: .string)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: isCompact ? AetherVisual.s2 : AetherVisual.s3) {
            if showsSelectionControl {
                Group {
                    if row.isPending {
                        ProgressView()
                            .controlSize(.mini)
                    } else {
                        Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.body)
                            .foregroundStyle(row.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(AetherVisual.tertiaryText))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: AetherVisual.s5)
                .accessibilityHidden(true)
            }
            AetherRegionCode(name: row.member, reservesSlot: !isCompact)
            Text(row.member)
                .font(.body.weight(row.isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.member)
            if let dialer = row.dialerProxy, !isCompact {
                HStack(spacing: AetherVisual.sMicro) {
                    Image(systemName: "link")
                        .font(.caption2.weight(.semibold))
                    Text(
                        String.localizedStringWithFormat(
                            AppLocalization.string("via %@"),
                            dialer
                        )
                    )
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                }
                .foregroundStyle(AetherVisual.secondaryText)
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(
                    AetherVisual.neutralFill,
                    in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                )
                .accessibilityIdentifier("proxy-node-dialer-badge-\(row.member)")
            }
            if let badge = row.badge {
                ProxyNodeBadge(badge: badge)
                    .transition(.opacity)
            }
            if !showsSelectionControl, row.isSelected {
                Text(AppLocalization.string("Current"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AetherReadableTint(color: .green))
                    .padding(.horizontal, AetherVisual.s1)
                    .padding(.vertical, AetherVisual.sMicro)
                    .background(AetherVisual.tintFill(.green), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
                    .fixedSize()
                    .accessibilityIdentifier("proxy-node-badge-current")
                    .transition(.opacity)
            }
            Spacer(minLength: AetherVisual.s1)
            if let protocolName = row.protocolName, !isCompact {
                AetherProtocolBadge(type: protocolName, transport: row.transportName)
            }
        }
    }

    private var rowFill: Color {
        if row.isSelected {
            return AetherVisual.selectionFill
        }
        return isHovered ? AetherVisual.hoverFill : Color.clear
    }

    private var latencyHelp: String {
        var lines: [String] = []
        if let measuredAt {
            lines.append(String.localizedStringWithFormat(
                AppLocalization.string("Last tested at %@"),
                AppLocalization.date(measuredAt, date: .omitted, time: .standard)
            ))
        } else {
            lines.append(AppLocalization.string("Test latency"))
        }
        if let confidence = row.confidence {
            lines.append(confidence.localizedHint)
        }
        return lines.joined(separator: "\n")
    }
}

private struct ProxyMemberTableItem: Identifiable {
    enum Badge: Equatable {
        /// Failover mode's preferred node.
        case preferred
        /// The node failover mode is using while the preferred one is down.
        case backupInUse
    }

    let member: String
    let protocolName: String?
    var transportName: String? = nil
    var dialerProxy: String? = nil
    var chainedOverride: ChainedProxyOverride? = nil
    let status: ProxyLatencyStatus
    var confidence: ProxyLatencyConfidence? = nil
    let isSelected: Bool
    let isBusy: Bool
    var isPending = false
    let showsLatency: Bool
    var badge: Badge?

    var id: String { member }
}

/// A latency result as coloured text, the same colour bands as everywhere
/// else. The system green and orange are too light for text on a light
/// background, so they are deepened there. When a measured value came from a
/// bare TCP connect probe rather than a full protocol round-trip, a small
/// `TCP` caption precedes the number.
struct ProxyLatencyText: View {
    @Environment(\.colorScheme) private var colorScheme
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
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("proxy-latency-tcp-badge")
                }
                Text(status.localizedTitle)
                    .font(.subheadline.weight(isResult ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(color)
                    .aetherNumericValue(status)
            }
        }
    }

    private var isResult: Bool {
        status.isMeasured || status == .timedOut
    }

    private var color: Color {
        guard isResult else { return .secondary }
        return colorScheme == .dark ? status.tint : status.tint.mix(with: .black, by: 0.3)
    }
}

/// "Preferred" or "Backup in use" beside a node's name in failover mode.
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
            return String.localizedStringWithFormat(
                AppLocalization.string("%1$@ stopped answering, so %2$@ took over at %3$@. Traffic returns to %1$@ once it answers again."),
                preferred,
                backup,
                AppLocalization.date(since, date: .omitted, time: .shortened)
            )
        }
        return String.localizedStringWithFormat(
            AppLocalization.string("%1$@ is not answering, so %2$@ is in use. Traffic returns to %1$@ once it answers again."),
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
                            ProxyNodeInventory(proxies: summary.proxies, groups: summary.proxyGroups)
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

    var body: some View {
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
                    .width(min: 84, ideal: 90)
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
                        Text(membership(of: proxy.name))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(membership(of: proxy.name))
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
                        .help(proxy.recognition.localizedTitle)
                    }
                    .width(min: 100, ideal: 104, max: 132)
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
                .overlay {
                    RoundedRectangle(
                        cornerRadius: AetherVisual.panelRadius,
                        style: .continuous
                    )
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
                }
            }
        }
    }

    private var inventorySummary: String {
        let usable = proxies.filter {
            $0.recognition.isUsable && !InitialProxySelectionPolicy.isSubscriptionMetadata($0.name)
        }
        let realCount = proxies.filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0.name) }.count
        return String.localizedStringWithFormat(
            AppLocalization.string("%lld total · %lld usable · %lld unsupported"),
            Int64(realCount),
            Int64(usable.count),
            Int64(realCount - usable.count)
        )
    }

    private func membership(of name: String) -> String {
        let owners = groups
            .filter { $0.members.contains(name) }
            .map(\.name)
        guard !owners.isEmpty else {
            return AppLocalization.string("In no group")
        }
        return owners.joined(separator: " · ")
    }
}

import AetherRouteKit
import SwiftUI

/// Choosing a node and testing latency, nothing else: the groups beside the
/// nodes of the chosen one. Inventory and provider details for
/// troubleshooting live in Settings › Privacy & Diagnostics.
struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var selectedGroupId: Int?
    @State private var showsNewGroup = false
    @State private var showsRegionGroups = false
    @State private var showsHiddenNodes = false

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
    }

    private func groupsAndCard(
        summary: ProfileConfigurationSummary,
        isWideGroupLayout: Bool
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                AetherPageHeader(.proxies) { overrideActions(summary: summary) }
                ProfileCompatibilityNotice(report: summary.compatibility)

                if !summary.proxyGroups.isEmpty {
                    if summary.proxyGroups.count > 1, isWideGroupLayout {
                        // Groups in a column beside their members, so the
                        // current choice of every group stays in view.
                        HStack(alignment: .top, spacing: AetherVisual.s4) {
                            proxyGroupColumn(groups: summary.proxyGroups)
                                .frame(width: Self.groupColumnWidth)
                            // Level with the group card, below its heading.
                            activeGroupView(summary: summary)
                                .padding(.top, AetherVisual.s5 + AetherVisual.s1)
                        }
                    } else {
                        // One group needs no switcher; the card names it.
                        if summary.proxyGroups.count > 1 {
                            proxyGroupTabBar(groups: summary.proxyGroups)
                        }
                        activeGroupView(summary: summary)
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
                }
            }
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
    }

    /// New groups and hidden nodes change only this app's view of the
    /// profile (1.7.0); the subscription is never edited.
    @ViewBuilder
    private func overrideActions(summary: ProfileConfigurationSummary) -> some View {
        let catchAll = ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary)
            .first { tunnel.customProxyGroup(named: $0.name) == nil }?.name
        Button {
            showsNewGroup = true
        } label: {
            Label(AppLocalization.string("New Group"), systemImage: "plus")
        }
        .labelStyle(.titleAndIcon)
        .aetherButton(prominent: true)
        .disabled(!canEditOverrides)
        .accessibilityIdentifier("proxies-new-group")
        .sheet(isPresented: $showsNewGroup) {
            CustomProxyGroupSheet(defaultParent: catchAll)
        }
        Menu {
            Button(AppLocalization.string("Groups by Region…"), systemImage: "globe.asia.australia") {
                showsRegionGroups = true
            }
            .accessibilityIdentifier("proxies-region-groups")
            Button(AppLocalization.string("Hide Nodes…"), systemImage: "eye.slash") {
                showsHiddenNodes = true
            }
            .accessibilityIdentifier("proxies-hidden-nodes")
        } label: {
            Label(AppLocalization.string("More"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .aetherButton()
        .fixedSize()
        .disabled(!canEditOverrides)
        .accessibilityIdentifier("proxies-more-menu")
        .sheet(isPresented: $showsRegionGroups) {
            RegionGroupsSheet(defaultParent: catchAll)
        }
        .sheet(isPresented: $showsHiddenNodes) {
            HiddenNodesSheet()
        }
    }

    /// Overrides can change while connected (the running profile reloads),
    /// but not in the middle of a connect or another profile operation.
    private var canEditOverrides: Bool {
        !tunnel.isTransitioning && !tunnel.isUpdatingProfiles && !tunnel.isRefreshingSubscription
    }

    nonisolated private static let wideGroupLayoutWidth: CGFloat = 720
    private static let groupColumnWidth: CGFloat = 236

    @ViewBuilder
    private func activeGroupView(summary: ProfileConfigurationSummary) -> some View {
        if let activeGroup = currentGroup(from: summary.proxyGroups) {
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
                )
            )
            .id(activeGroup.name)
            .transition(.opacity)
            // Opt-in (Settings › Network): one test when a group comes into
            // view, throttled per group so switching back and forth is free.
            .task(id: activeGroup.name) {
                await tunnel.testLatencyOnOpenIfDue(group: activeGroup.name)
            }
        }
    }

    /// The groups as a vertical list beside the members of the chosen one.
    private func proxyGroupColumn(groups: [ProxyGroupConfigurationSummary]) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Proxy groups"))
            VStack(spacing: AetherVisual.sMicro) {
                ForEach(groups) { group in
                    groupButton(group, in: groups, fillsWidth: true)
                }
            }
            .padding(AetherVisual.listCardInset)
            .aetherPanel()
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
            isSelected: currentGroup(from: groups)?.id == group.id,
            currentMember: tunnel.proxySelections[group.name]?.selectedMember,
            fillsWidth: fillsWidth,
            onSelect: {
                withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                    selectedGroupId = group.id
                }
            }
        )
    }

    private func currentGroup(from groups: [ProxyGroupConfigurationSummary]) -> ProxyGroupConfigurationSummary? {
        if let id = selectedGroupId, let found = groups.first(where: { $0.id == id }) {
            return found
        }
        return defaultGroup(from: groups)
    }

    private func defaultGroup(from groups: [ProxyGroupConfigurationSummary]) -> ProxyGroupConfigurationSummary? {
        groups.first { $0.strategy.lowercased() == "select" } ?? groups.first
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

// MARK: - Group button

/// A group as a row: its tile, its name, and "strategy · current node".
private struct ProxyGroupTabButton: View {
    let group: ProxyGroupConfigurationSummary
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
                AetherIconTile(symbol: proxyGroupSymbol(group.strategy), color: proxyGroupTint(group.strategy), size: AetherVisual.rowTileSize)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(group.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
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

/// One card: the group and its current node, the one switch that matters,
/// then the nodes.
private struct ActiveProxyGroupView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var sort: ProxyNodeSort = .default
    @State private var searchText = ""
    @State private var hidesTimedOutNodes = false
    /// A choice made while disconnected takes effect later; say so for a
    /// moment instead of keeping a permanent caption on the card.
    @State private var showsNextConnectionNote = false
    @State private var showsSwitchHistory = false
    @State private var editsCustomGroup = false
    let group: ProxyGroupConfigurationSummary
    let protocols: [String: String]
    var transports: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.s3)
            Divider().padding(.horizontal, AetherVisual.s4)
            modeRow
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.s3)
            Divider().padding(.horizontal, AetherVisual.s4)

            if tunnel.isConnected, let preferredMember, let backupMember {
                FailoverBackupBanner(
                    preferred: preferredMember,
                    backup: backupMember,
                    since: tunnel.proxySwitchLog.latest(forGroup: group.name)
                        .flatMap { $0.reason == .unresponsive && $0.to == backupMember ? $0.date : nil }
                )
                .padding(.horizontal, AetherVisual.s4)
                .padding(.top, AetherVisual.s3)
                .transition(AetherVisual.insertion)
            }

            if let message = tunnel.proxySelectionMessages[group.name] {
                AetherInlineMessage(text: message, isCompact: true)
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.top, AetherVisual.s3)
                    .transition(AetherVisual.insertion)
            }

            if members.isEmpty {
                Text(AppLocalization.string("This group has no nodes."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .padding(AetherVisual.s4)
            } else {
                if members.count > 8 {
                    AetherSearchField(
                        text: $searchText,
                        prompt: AppLocalization.string("Search nodes"),
                        accessibilityIdentifier: "proxy-node-search-field"
                    )
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.top, AetherVisual.s3)
                }
                if memberRows.isEmpty {
                    Text(AppLocalization.string("No matching nodes"))
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(AetherVisual.s4)
                } else {
                    nodeList
                        .padding(AetherVisual.listCardInset)
                }
            }
        }
        .aetherPanel()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.proxySelectionMessages[group.name])
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: showsNextConnectionNote)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: backupMember)
        .task(id: tunnel.isConnected) {
            guard isManuallySelectable else { return }
            await tunnel.refreshProxySelection(group: group.name)
        }
        .task(id: showsNextConnectionNote) {
            guard showsNextConnectionNote else { return }
            try? await Task.sleep(for: .seconds(4))
            showsNextConnectionNote = false
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: AetherVisual.s2) {
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(group.name)
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
            sortMenu
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
                if !isBuiltInOutlet(selectedMember), status(for: selectedMember).isMeasured {
                    Text(verbatim: "·")
                        .foregroundStyle(AetherVisual.secondaryText)
                    ProxyLatencyText(status: status(for: selectedMember))
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
            latest.formatted(date: .omitted, time: .standard)
        )
    }

    // MARK: Mode

    @ViewBuilder
    private var modeRow: some View {
        if isManuallySelectable {
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s3) {
                    Text(AppLocalization.string("Node selection"))
                        .font(.body.weight(.semibold))
                    Spacer(minLength: AetherVisual.s3)
                    AetherSegmentedPicker(
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
                        ),
                        options: ProxySelectionMode.allCases.map {
                            .init(value: $0, title: $0.localizedTitle)
                        },
                        accessibilityLabel: AppLocalization.string("Node selection"),
                        accessibilityIdentifier: "proxy-selection-mode-\(group.name)"
                    )
                    .fixedSize()
                    .disabled(tunnel.proxySelectionRequests.contains(group.name))
                }
                Text(selectionMode.localizedExplanation)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("proxy-selection-mode-explanation")
            }
        } else {
            Label {
                Text(automaticGroupNote)
            } icon: {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.accentColor)
            }
            .font(.subheadline)
            .foregroundStyle(AetherVisual.secondaryText)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("proxy-group-automatic-note")
        }
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

    private var nodeList: some View {
        // Lazy: a group can hold hundreds of nodes.
        LazyVStack(spacing: AetherVisual.sMicro) {
            ForEach(memberRows) { row in
                ProxyNodeRow(
                    row: row,
                    canSelect: isManuallySelectable && !isAutomaticSelectionMode,
                    showsSelectionControl: isManuallySelectable,
                    measuredAt: tunnel.latencyMeasuredAt[group.name]?[row.member],
                    onSelect: {
                        Task {
                            await tunnel.selectProxy(group: group.name, member: row.member)
                            if !tunnel.isConnected {
                                showsNextConnectionNote = true
                            }
                        }
                    },
                    onTest: {
                        Task { await tunnel.testSingleProxyLatency(group: group.name, member: row.member) }
                    }
                )
            }
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: memberRows.map(\.id))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Proxy group members"))
        .accessibilityIdentifier("proxy-group-members-table")
    }

    private func memberType(_ member: String) -> String {
        switch member.uppercased() {
        case "DIRECT": return AppLocalization.string("Direct")
        case "REJECT", "REJECT-DROP": return AppLocalization.string("Reject")
        default:
            if let protocolName = protocols[member] { return protocolName.uppercased() }
            if tunnel.activeProfileSummary?.proxyGroups.contains(where: { $0.name == member }) == true {
                return AppLocalization.string("Proxy group")
            }
            return AppLocalization.string("Unknown")
        }
    }

    private var memberRows: [ProxyMemberTableItem] {
        let sorted = ProxyPageNodeOrder.sorted(members: members, by: sort) {
            latencyRank(status(for: $0))
        }
        let ordered = NodeRegion.filterMembers(
            sorted,
            protocolByName: Dictionary(
                uniqueKeysWithValues: sorted.map { ($0, memberType($0)) }
            ),
            query: searchText,
            hideTimedOut: hidesTimedOutNodes,
            isTimedOut: { status(for: $0) == .timedOut },
            selectedMember: selectedMember
        )
        let isBusy = tunnel.proxySelectionRequests.contains(group.name)
        return ordered.map { member in
            ProxyMemberTableItem(
                member: member,
                protocolName: memberType(member),
                transportName: transports[member],
                status: status(for: member),
                isSelected: member == selectedMember,
                isBusy: isBusy,
                showsLatency: !isBuiltInOutlet(member),
                badge: member == preferredMember
                    ? .preferred
                    : (member == backupMember ? .backupInUse : nil)
            )
        }
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

    private var preferredMember: String? {
        selectionMode == .failover ? tunnel.preferredProxyMembers[group.name] : nil
    }

    /// Failover mode is on a backup: the node in use is not the preferred one.
    private var backupMember: String? {
        guard let preferredMember, let selectedMember,
              selectedMember != preferredMember else { return nil }
        return selectedMember
    }

    private var members: [String] {
        tunnel.proxySelections[group.name]?.members ?? group.members
    }

    private func latencyRank(_ status: ProxyLatencyStatus) -> Int {
        switch status {
        case let .responded(milliseconds): Int(milliseconds)
        case .timedOut: Int.max - 2
        case .testing: Int.max - 1
        case .untested: Int.max
        }
    }

    private var selectedMember: String? {
        tunnel.proxySelections[group.name]?.selectedMember
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

/// Selection, region, name, protocol and latency on one line. In a group
/// that picks its own node the row is information only: no radio, and the
/// node in use carries a "Current" tag.
private struct ProxyNodeRow: View {
    let row: ProxyMemberTableItem
    let canSelect: Bool
    let showsSelectionControl: Bool
    let measuredAt: Date?
    let onSelect: () -> Void
    let onTest: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            if showsSelectionControl {
                Button(action: onSelect) {
                    rowContent.contentShape(Rectangle())
                }
                .buttonStyle(.aetherPressable)
                .disabled(row.isBusy || !canSelect)
                .accessibilityLabel(row.member)
                .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            } else {
                // Not a disabled button: that would grey out rows that are
                // simply not meant to be clicked.
                rowContent
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            }

            Group {
                if row.showsLatency {
                    Button(action: onTest) {
                        ProxyLatencyText(status: row.status)
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
            .frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, AetherVisual.s3)
        .frame(minHeight: AetherVisual.listRowHeight)
        .background(rowFill, in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous))
        .onHover { isHovered = $0 }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: row.isSelected)
        .contextMenu {
            if showsSelectionControl {
                Button(AppLocalization.string("Switch to this node"), action: onSelect)
                    .disabled(row.isBusy || !canSelect)
            }
            if row.showsLatency {
                Button(AppLocalization.string("Test latency"), action: onTest)
            }
            Divider()
            Button(AppLocalization.string("Copy node name")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(row.member, forType: .string)
            }
        }
    }

    private var rowContent: some View {
        HStack(spacing: AetherVisual.s3) {
            if showsSelectionControl {
                Image(systemName: row.isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.body)
                    .foregroundStyle(row.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(AetherVisual.tertiaryText))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: AetherVisual.s5)
                    .accessibilityHidden(true)
            }
            AetherRegionCode(name: row.member)
            Text(row.member)
                .font(.body.weight(row.isSelected ? .semibold : .regular))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(row.member)
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
                    .transition(.opacity)
            }
            Spacer(minLength: AetherVisual.s2)
            if let protocolName = row.protocolName {
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
        guard let measuredAt else { return AppLocalization.string("Test latency") }
        return String.localizedStringWithFormat(
            AppLocalization.string("Last tested at %@"),
            measuredAt.formatted(date: .omitted, time: .standard)
        )
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
    let status: ProxyLatencyStatus
    let isSelected: Bool
    let isBusy: Bool
    let showsLatency: Bool
    var badge: Badge?

    var id: String { member }
}

/// A latency result as coloured text, the same colour bands as everywhere
/// else. The system green and orange are too light for text on a light
/// background, so they are deepened there.
struct ProxyLatencyText: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: ProxyLatencyStatus

    var body: some View {
        if status == .testing {
            ProgressView()
                .controlSize(.mini)
                .transition(.opacity)
        } else {
            Text(status.localizedTitle)
                .font(.subheadline.weight(isResult ? .semibold : .regular).monospacedDigit())
                .foregroundStyle(color)
                .aetherNumericValue(status)
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
                since.formatted(date: .omitted, time: .shortened)
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
            Text(event.date.formatted(date: .omitted, time: .standard))
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
        let usable = proxies.filter { $0.recognition.isUsable }.count
        return String.localizedStringWithFormat(
            AppLocalization.string("%lld total · %lld usable · %lld unsupported"),
            Int64(proxies.count),
            Int64(usable),
            Int64(proxies.count - usable)
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

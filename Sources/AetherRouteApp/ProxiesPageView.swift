import AetherRouteKit
import SwiftUI

/// Choosing a node and testing latency, nothing else: the groups beside the
/// nodes of the chosen one. Inventory and provider details for
/// troubleshooting live in Settings › Privacy & Diagnostics.
struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var selectedGroupId: Int?
    /// Wide enough for the groups to sit in a column beside their members.
    @State private var isWideGroupLayout = false

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
    }

    private func content(summary: ProfileConfigurationSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                AetherPageHeader(.proxies)

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
            .aetherPageContent(.wide)
            .onGeometryChange(for: Bool.self) { proxy in
                proxy.size.width >= Self.wideGroupLayoutWidth
            } action: { isWide in
                isWideGroupLayout = isWide
            }
            .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isWideGroupLayout)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppLocalization.string("Proxy configuration"))
            .accessibilityIdentifier("proxies-page-content")
        }
    }

    nonisolated private static let wideGroupLayoutWidth: CGFloat = 720
    private static let groupColumnWidth: CGFloat = 236

    @ViewBuilder
    private func activeGroupView(summary: ProfileConfigurationSummary) -> some View {
        if let activeGroup = currentGroup(from: summary.proxyGroups) {
            ActiveProxyGroupView(
                group: activeGroup,
                protocols: Dictionary(
                    uniqueKeysWithValues: summary.proxies.map { ($0.name, $0.protocolName) }
                )
            )
            .id(activeGroup.name)
            .transition(.opacity)
        }
    }

    /// The groups as a vertical list beside the members of the chosen one.
    private func proxyGroupColumn(groups: [ProxyGroupConfigurationSummary]) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(AppLocalization.string("Proxy groups"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
                .padding(.horizontal, AetherVisual.s2)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: AetherVisual.sMicro) {
                ForEach(groups) { group in
                    groupButton(group, in: groups, fillsWidth: true)
                }
            }
            .padding(AetherVisual.sCompact)
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
                AetherIconTile(symbol: proxyGroupSymbol(group.strategy), color: proxyGroupTint(group.strategy), size: 28)
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
            .contentShape(RoundedRectangle(cornerRadius: AetherVisual.s3, style: .continuous))
            .background(
                isSelected
                    ? Color.accentColor.opacity(0.22)
                    : (isHovered ? Color.secondary.opacity(0.1) : Color.clear),
                in: RoundedRectangle(cornerRadius: AetherVisual.s3, style: .continuous)
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
    /// A choice made while disconnected takes effect later; say so for a
    /// moment instead of keeping a permanent caption on the card.
    @State private var showsNextConnectionNote = false
    let group: ProxyGroupConfigurationSummary
    let protocols: [String: String]

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

            if let message = tunnel.proxySelectionMessages[group.name] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
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
                nodeList
                    .padding(AetherVisual.s2)
            }
        }
        .aetherPanel()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.proxySelectionMessages[group.name])
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: showsNextConnectionNote)
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
                Text(group.name)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .accessibilityIdentifier("proxy-active-group-name")
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
            sortMenu
            Button {
                Task { await tunnel.testProxyLatency(group: group.name) }
            } label: {
                AetherProgressButtonLabel(AppLocalization.string("Test latency"), systemImage: "bolt", isWorking: isTesting)
                    .fixedSize(horizontal: true, vertical: false)
                    .frame(minWidth: 72)
            }
            .aetherGlassButton()
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

    private var sortMenu: some View {
        Menu {
            Picker(AppLocalization.string("Sort"), selection: $sort) {
                ForEach(ProxyNodeSort.allCases) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .aetherGlassButton()
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
            HStack(spacing: AetherVisual.s3) {
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Pick the fastest node automatically"))
                        .font(.body.weight(.semibold))
                    Text(AppLocalization.string("When on, AetherRoute uses the node with the lowest latency, so you never switch by hand."))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AetherVisual.s3)
                Toggle(
                    AppLocalization.string("Pick the fastest node automatically"),
                    isOn: Binding(
                        get: { isAutomaticSelectionMode },
                        set: { isAutomatic in
                            Task {
                                await tunnel.setProxySelectionAutomatic(
                                    group: group.name,
                                    isAutomatic: isAutomatic
                                )
                            }
                        }
                    )
                )
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
                .disabled(tunnel.proxySelectionRequests.contains(group.name))
                .accessibilityIdentifier("proxy-auto-select-\(group.name)")
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
        let ordered = ProxyPageNodeOrder.sorted(members: members, by: sort) {
            latencyRank(status(for: $0))
        }
        let isBusy = tunnel.proxySelectionRequests.contains(group.name)
        return ordered.map { member in
            ProxyMemberTableItem(
                member: member,
                protocolName: memberType(member),
                status: status(for: member),
                isSelected: member == selectedMember,
                isBusy: isBusy,
                showsLatency: !isBuiltInOutlet(member)
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
        tunnel.automaticProxySelectionGroups.contains(group.name)
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
        .frame(minHeight: 40)
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
                    .foregroundStyle(row.isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(AetherVisual.secondaryText.opacity(0.5)))
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
            if !showsSelectionControl, row.isSelected {
                Text(AppLocalization.string("Current"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AetherReadableTint(color: .green))
                    .padding(.horizontal, AetherVisual.s1)
                    .padding(.vertical, 1)
                    .background(Color.green.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .transition(.opacity)
            }
            Spacer(minLength: AetherVisual.s2)
            if let protocolName = row.protocolName {
                AetherProtocolBadge(type: protocolName)
            }
        }
    }

    private var rowFill: Color {
        if row.isSelected {
            return showsSelectionControl ? Color.accentColor.opacity(0.08) : Color.green.opacity(0.07)
        }
        return isHovered ? Color.secondary.opacity(0.08) : Color.clear
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
    let member: String
    let protocolName: String?
    let status: ProxyLatencyStatus
    let isSelected: Bool
    let isBusy: Bool
    let showsLatency: Bool

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
                .contentTransition(.numericText())
                .animation(AetherVisual.animation(AetherVisual.valueChange), value: status)
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

// MARK: - Inventory (opened from Settings › Privacy & Diagnostics)

/// Every node and provider in the active profile, for troubleshooting
/// subscription parsing or protocol support.
struct ProxyInventorySheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.string("Node inventory & providers"))
                    .font(.title3.weight(.semibold))
                Text(AppLocalization.string("For troubleshooting subscription parsing or protocol support."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AetherVisual.s4) {
                    if let summary = tunnel.activeProfileSummary {
                        if !summary.proxies.isEmpty {
                            ProxyNodeInventory(proxies: summary.proxies, groups: summary.proxyGroups)
                        }
                        if !summary.proxyProviders.isEmpty {
                            FeatureSection(title: AppLocalization.string("Providers"), symbol: "shippingbox") {
                                VStack(spacing: 0) {
                                    ForEach(summary.proxyProviders) { provider in
                                        ProviderRow(provider: provider)
                                        if provider.id != summary.proxyProviders.last?.id {
                                            Divider().padding(.leading, AetherVisual.onboardingTopPadding)
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
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AetherVisual.s5)
        .frame(width: 640, height: 520)
        .accessibilityIdentifier("proxy-inventory-sheet")
    }
}

private struct ProxyNodeInventory: View {
    let proxies: [ProxyConfigurationSummary]
    let groups: [ProxyGroupConfigurationSummary]

    var body: some View {
        FeatureSection(title: AppLocalization.string("Nodes"), symbol: "server.rack") {
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
                        Text(proxy.protocolName.uppercased())
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(proxy.protocolName.uppercased())
                    }
                    .width(min: 68, ideal: 80, max: 92)
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
        let recognized = proxies.filter { $0.recognition == .recognized }.count
        let pending = proxies.filter {
            $0.recognition == .requiresCoreValidation
        }.count
        let unsupported = proxies.filter { $0.recognition == .incomplete }.count
        return String.localizedStringWithFormat(
            AppLocalization.string(
                "%lld total · %lld recognized · %lld pending core check · %lld unsupported"
            ),
            Int64(proxies.count),
            Int64(recognized),
            Int64(pending),
            Int64(unsupported)
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

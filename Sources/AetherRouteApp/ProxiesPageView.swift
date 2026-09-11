import AetherRouteKit
import SwiftUI

/// 现代化的代理节点选择页面
/// 对标 Clash Verge Rev 与 ClashX Pro，采用横向策略组 Tab 切换 + 自适应卡片网格/紧凑列表双视图。
struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var searchText = ""
    @State private var selectedGroupId: Int?
    @AppStorage("proxies-view-display-mode") private var isGridView: Bool = true
    @State private var showAdvancedInventory: Bool = false

    var body: some View {
        Group {
            if tunnel.activeProfile != nil,
               let summary = tunnel.activeProfileSummary {
                content(summary: summary)
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

    private func content(summary: ProfileConfigurationSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                if !summary.proxyGroups.isEmpty {
                    // 1. 顶部策略组水平 Tab 分段选择栏
                    proxyGroupTabBar(groups: summary.proxyGroups)

                    // 2. 当前选中策略组的节点网格/列表展示
                    if let activeGroup = currentGroup(from: summary.proxyGroups) {
                        ActiveProxyGroupView(
                            group: activeGroup,
                            protocols: Dictionary(
                                uniqueKeysWithValues: summary.proxies.map { ($0.name, $0.protocolName) }
                            ),
                            searchText: searchText,
                            isGridView: $isGridView
                        )
                        .id(activeGroup.name)
                    }
                }

                // 3. 辅助折叠区域：节点底库清单与 Providers（高级选项）
                advancedInventorySection(summary: summary)

                if summary.proxyCount == 0,
                   summary.proxyGroupCount == 0,
                   summary.proxyProviderCount == 0 {
                    FeatureEmptyState(
                        symbol: "point.3.connected.trianglepath.dotted",
                        title: "No proxy definitions",
                        detail: "The active profile passed import checks but does not expose inline endpoints, groups, or providers."
                    )
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Proxy configuration")
            .accessibilityIdentifier("proxies-page-content")
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text("Search nodes")
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

    // MARK: - 顶部策略组胶囊 Tab 栏
    private func proxyGroupTabBar(groups: [ProxyGroupConfigurationSummary]) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack {
                Text("Proxy groups")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text("\(groups.count)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.12), in: Capsule())

                Spacer()

                Button {
                    Task {
                        for group in groups where tunnel.isConnected {
                            await tunnel.testProxyLatency(group: group.name)
                        }
                    }
                } label: {
                    Label("Test all", systemImage: "gauge.with.dots.needle.33percent")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!tunnel.isConnected || !tunnel.proxyLatencyRequests.isEmpty)
                .accessibilityIdentifier("test-all-proxy-groups")
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(groups) { group in
                        let isSelected = (currentGroup(from: groups)?.id == group.id)
                        let currentMember = tunnel.proxySelections[group.name]?.selectedMember

                        Button {
                            selectedGroupId = group.id
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: groupSymbol(group.strategy))
                                    .font(.caption.weight(.semibold))

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(group.name)
                                            .font(.subheadline.weight(isSelected ? .bold : .medium))
                                            .lineLimit(1)
                                        Text(group.strategy.uppercased())
                                            .font(.system(size: 8, weight: .bold))
                                            .padding(.horizontal, 3)
                                            .padding(.vertical, 1)
                                            .background(
                                                (isSelected ? Color.white.opacity(0.25) : Color.secondary.opacity(0.15)),
                                                in: RoundedRectangle(cornerRadius: 3)
                                            )
                                    }

                                    if let currentMember {
                                        Text(currentMember)
                                            .font(.caption2)
                                            .opacity(isSelected ? 0.9 : 0.6)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(
                                isSelected
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(Color(nsColor: .controlBackgroundColor)),
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(
                                        isSelected ? Color.clear : Color(nsColor: .separatorColor).opacity(0.5),
                                        lineWidth: 0.5
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private func groupSymbol(_ strategy: String) -> String {
        switch strategy.lowercased() {
        case "select": return "square.stack.3d.up.fill"
        case "url-test": return "bolt.horizontal.fill"
        case "fallback": return "arrow.triangle.pull"
        case "load-balance": return "scale.3d"
        default: return "point.3.connected.trianglepath.dotted"
        }
    }

    // MARK: - 高级节点底库与 Providers (折叠收起)
    private func advancedInventorySection(summary: ProfileConfigurationSummary) -> some View {
        DisclosureGroup(isExpanded: $showAdvancedInventory) {
            VStack(alignment: .leading, spacing: AetherVisual.s4) {
                if !summary.proxies.isEmpty {
                    ProxyNodeInventory(
                        proxies: summary.proxies,
                        groups: summary.proxyGroups,
                        searchText: searchText
                    )
                }

                if !summary.proxyProviders.isEmpty {
                    FeatureSection(title: "Providers", symbol: "shippingbox") {
                        VStack(spacing: 0) {
                            ForEach(summary.proxyProviders) { provider in
                                ProviderRow(provider: provider)
                                if provider.id != summary.proxyProviders.last?.id {
                                    Divider().padding(.leading, AetherVisual.onboardingTopPadding)
                                }
                            }
                        }
                        .featureCard()
                    }
                }
            }
            .padding(.top, AetherVisual.s3)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "slider.horizontal.3")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Raw Node Inventory & Providers")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(summary.proxyCount) endpoints")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(AetherVisual.s3)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.5),
            in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius)
        )
    }
}

// MARK: - 当前选中策略组视图
private struct ActiveProxyGroupView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var filter: ProxyNodeFilter = .all
    @State private var sort: ProxyNodeSort = .latency
    let group: ProxyGroupConfigurationSummary
    let protocols: [String: String]
    let searchText: String
    @Binding var isGridView: Bool

    init(
        group: ProxyGroupConfigurationSummary,
        protocols: [String: String],
        searchText: String,
        isGridView: Binding<Bool>
    ) {
        self.group = group
        self.protocols = protocols
        self.searchText = searchText
        self._isGridView = isGridView
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            // 1. 策略组模式与说明栏
            groupModeHeader

            Divider()
                .opacity(0.35)

            // 2. 节点过滤与工具操作栏
            nodeToolbar

            if let message = tunnel.proxySelectionMessages[group.name] {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            // 3. 节点内容
            if visibleMembers.isEmpty {
                FeatureEmptyState(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No matching nodes",
                    detail: "Change the filter, or clear the search field."
                )
            } else {
                if isGridView {
                    nodeGrid
                } else {
                    nodeList
                }

                HStack {
                    Text(
                        String.localizedStringWithFormat(
                            AppLocalization.string("Showing %lld of %lld nodes"),
                            Int64(visibleMembers.count),
                            Int64(members.count)
                        )
                    )
                    Spacer()
                    Text(isTesting ? "Testing…" : "Latency results are local")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
        .task(id: tunnel.isConnected) {
            guard isManuallySelectable else { return }
            await tunnel.refreshProxySelection(group: group.name)
        }
    }

    // MARK: - 策略组模式与状态信息顶栏
    private var groupModeHeader: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            if isManuallySelectable {
                HStack(spacing: AetherVisual.s2) {
                    Text("Selection mode")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Picker(
                        selection: Binding(
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
                    ) {
                        Text("Manual").tag(false)
                        Text("Auto").tag(true)
                    } label: {
                        EmptyView()
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .frame(width: 120)
                    .disabled(tunnel.proxySelectionRequests.contains(group.name))
                    .accessibilityIdentifier("proxy-selection-mode-\(group.name)")
                }

                Text(
                    isAutomaticSelectionMode
                        ? "Retries the fastest available node"
                        : "Keeps the selected node pinned"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            } else {
                HStack(spacing: 6) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.accentColor)
                    Text(
                        tunnel.isConnected
                            ? "This group is automatically managed by latency tests."
                            : "This automatic group is ready and will choose the fastest available node when you connect."
                    )
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if !tunnel.isConnected {
                Label(
                    "The selected node will be used on the next connection.",
                    systemImage: "checkmark.circle"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 节点工具栏 (过滤 / 排序 / 测速 / 视图切换)
    private var nodeToolbar: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            // 左侧：轻量通透过滤 Tabs (宽屏 Pill Tabs，空间受限时自适应至原生 PopUpButton)
            ViewThatFits(in: .horizontal) {
                filterPills
                    .fixedSize(horizontal: true, vertical: false)

                NativeFilterPicker(
                    selection: $filter,
                    options: ProxyNodeFilter.allCases,
                    title: label(for:),
                    accessibilityLabel: AppLocalization.string("Filter"),
                    accessibilityIdentifier: "proxy-filter-picker-\(group.name)"
                )
            }

            Spacer()

            // 右侧：紧凑工具群组 (排序、测速、网格/列表视图切换)
            HStack(spacing: AetherVisual.s2) {
                Picker("Sort", selection: $sort) {
                    ForEach(ProxyNodeSort.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .labelsHidden()
                .frame(width: 90)
                .accessibilityIdentifier("proxy-sort-picker")

                Button {
                    Task { await tunnel.testProxyLatency(group: group.name) }
                } label: {
                    AetherProgressButtonLabel("Test latency", isWorking: isTesting)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!tunnel.isConnected || isTesting)
                .accessibilityIdentifier("proxy-test-latency-\(group.name)")

                Picker("", selection: $isGridView) {
                    Image(systemName: "square.grid.2x2").tag(true)
                    Image(systemName: "list.bullet").tag(false)
                }
                .pickerStyle(.segmented)
                .controlSize(.small)
                .frame(width: 60)
            }
        }
    }

    private var filterPills: some View {
        HStack(spacing: 4) {
            ForEach(ProxyNodeFilter.allCases) { option in
                let isSelected = (filter == option)
                let count = members.filter { option.accepts(status(for: $0)) && matchesSearch($0) }.count

                Button {
                    withAnimation(AetherVisual.quickFade) {
                        filter = option
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(option.localizedTitle)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        Text("\(count)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, 4.5)
                            .padding(.vertical, 1)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4.5)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .background(
                        isSelected ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.5),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    // MARK: - 节点网格展示 (现代卡片布局)
    private var nodeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: 12)],
            spacing: 12
        ) {
            ForEach(visibleMembers, id: \.self) { member in
                let isSelected = (member == selectedMember)
                let isBusy = tunnel.proxySelectionRequests.contains(group.name)
                let nodeStatus = status(for: member)
                let proto = protocols[member] ?? "PROXY"

                ProxyNodeModernCard(
                    name: member,
                    protocolName: proto,
                    status: nodeStatus,
                    isSelected: isSelected,
                    isBusy: isBusy,
                    canSelect: isManuallySelectable && !isAutomaticSelectionMode,
                    onSelect: {
                        Task {
                            await tunnel.selectProxy(group: group.name, member: member)
                        }
                    },
                    onTest: {
                        Task {
                            await tunnel.testProxyLatency(group: group.name)
                        }
                    }
                )
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 节点列表展示 (Table 兼容已有测试标识)
    private var nodeList: some View {
        Table(memberRows) {
            TableColumn("Name") { row in
                Button {
                    Task {
                        await tunnel.selectProxy(group: group.name, member: row.member)
                    }
                } label: {
                    Text(row.member)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(row.isBusy || !isManuallySelectable || isAutomaticSelectionMode)
                .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
            }
            TableColumn("Protocol") { row in
                Text(row.protocolName?.uppercased() ?? "—")
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .width(84)
            TableColumn("Latency") { row in
                ProxyLatencyBadge(status: row.status, name: nil)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(72)
            TableColumn("") { row in
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .opacity(row.isSelected ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .width(14)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .accessibilityLabel("Proxy group members")
        .accessibilityIdentifier("proxy-group-members-table")
        .scrollIndicators(.hidden, axes: .horizontal)
        .environment(\.defaultMinListRowHeight, 28)
        .frame(height: min(CGFloat(memberRows.count * 28 + 34), 280))
    }

    private var memberRows: [ProxyMemberTableItem] {
        visibleMembers.map { member in
            ProxyMemberTableItem(
                member: member,
                protocolName: protocols[member],
                status: status(for: member),
                isSelected: member == selectedMember,
                isBusy: tunnel.proxySelectionRequests.contains(group.name)
            )
        }
    }

    private var isAutomaticSelectionMode: Bool {
        tunnel.automaticProxySelectionGroups.contains(group.name)
    }

    private func label(for option: ProxyNodeFilter) -> String {
        let count = members.filter {
            option.accepts(status(for: $0)) && matchesSearch($0)
        }.count
        return "\(option.localizedTitle) \(count)"
    }

    private var members: [String] {
        tunnel.proxySelections[group.name]?.members ?? group.members
    }

    private var visibleMembers: [String] {
        members
            .filter { filter.accepts(status(for: $0)) && matchesSearch($0) }
            .sorted { lhs, rhs in
                switch sort {
                case .latency:
                    return latencyRank(status(for: lhs)) < latencyRank(status(for: rhs))
                case .name:
                    return lhs.localizedStandardCompare(rhs) == .orderedAscending
                }
            }
    }

    private func latencyRank(_ status: ProxyLatencyStatus) -> Int {
        switch status {
        case let .responded(milliseconds): Int(milliseconds)
        case .timedOut: Int.max - 2
        case .testing: Int.max - 1
        case .untested: Int.max
        }
    }

    private func matchesSearch(_ member: String) -> Bool {
        searchText.isEmpty || member.localizedCaseInsensitiveContains(searchText)
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
            isTesting: isTesting
        )
    }
}

// MARK: - 现代节点卡片组件 (对标 Clash Verge Rev & Surge 5 Mac)
private struct ProxyNodeModernCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let protocolName: String
    let status: ProxyLatencyStatus
    let isSelected: Bool
    let isBusy: Bool
    let canSelect: Bool
    let onSelect: () -> Void
    let onTest: () -> Void

    @State private var isHovered = false

    var body: some View {
        let flagInfo = AetherRegionFlag.flagAndRegion(from: name)

        Button {
            if canSelect && !isBusy {
                onSelect()
            }
        } label: {
            HStack(spacing: 10) {
                // 左侧 Accent Bar 指示 (仅在选中时点亮，未选中透明占位保持整齐对齐)
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 3.5, height: 34)

                // 节点图标：匹配国旗或协议科技微晶
                AetherNodeIcon(name: name, protocolName: protocolName, size: 28)

                // 中间信息：节点名 (单行不折行) + 协议徽标与状态
                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)

                    HStack(spacing: 6) {
                        AetherProtocolBadge(type: protocolName)

                        if isSelected {
                            HStack(spacing: 3.5) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                Text(AppLocalization.string("Active"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.green)
                            }
                        } else {
                            Text(flagInfo.region)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                    }
                }

                Spacer(minLength: 4)

                // 右侧延迟测速胶囊
                AetherLatencyPill(
                    latency: latencyMs,
                    isTesting: status == .testing,
                    onTap: onTest
                )
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .disabled(!canSelect || isBusy)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(cardBorder, lineWidth: isSelected ? 1.0 : (isHovered ? 0.8 : 0.5))
        }
        .shadow(
            color: isSelected
                ? Color.accentColor.opacity(colorScheme == .dark ? 0.20 : 0.12)
                : (isHovered ? Color.black.opacity(colorScheme == .dark ? 0.20 : 0.06) : Color.clear),
            radius: isSelected ? 5 : 3,
            y: isSelected ? 1.5 : 1
        )
        .animation(AetherVisual.gentleSpring, value: isHovered)
        .animation(AetherVisual.gentleSpring, value: isSelected)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button("Switch to this node") { onSelect() }
                .disabled(!canSelect || isBusy)
            Button("Retest group") { onTest() }
            Divider()
            Button("Copy node name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(name, forType: .string)
            }
        }
    }

    private var cardBackground: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.07)
        }
        if isHovered {
            return Color(nsColor: .controlBackgroundColor).opacity(0.95)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var cardBorder: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.6 : 0.45)
        }
        if isHovered {
            return Color.accentColor.opacity(0.35)
        }
        return Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.45 : 0.25)
    }

    private var latencyMs: Int? {
        if case let .responded(ms) = status {
            return Int(ms)
        }
        return nil
    }
}

// MARK: - 排序与状态模型
private enum ProxyNodeSort: String, CaseIterable, Identifiable {
    case latency
    case name

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .latency: AppLocalization.string("By latency")
        case .name: AppLocalization.string("By name")
        }
    }
}

private struct ProxyMemberTableItem: Identifiable {
    let member: String
    let protocolName: String?
    let status: ProxyLatencyStatus
    let isSelected: Bool
    let isBusy: Bool

    var id: String { member }
}

private struct ProxyLatencyBadge: View {
    let status: ProxyLatencyStatus
    let name: String?

    var body: some View {
        HStack(spacing: AetherVisual.s2) {
            if let name {
                Text(name)
                    .font(.caption)
                    .lineLimit(1)
            }

            if status == .testing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: status.symbol)
                    .font(.system(size: 7))
                    .foregroundStyle(status.tint)
                    .accessibilityHidden(true)
            }

            Text(text)
                .font(.subheadline.monospacedDigit().weight(.semibold))
                .foregroundStyle(status.isMeasured ? .primary : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var text: String {
        switch status {
        case let .responded(milliseconds):
            String.localizedStringWithFormat(
                AppLocalization.string("%lld ms"),
                Int64(milliseconds)
            )
        case .timedOut: AppLocalization.string("Timed out")
        case .testing: AppLocalization.string("Testing")
        case .untested: AppLocalization.string("Untested")
        }
    }
}

private struct ProxyNodeInventory: View {
    let proxies: [ProxyConfigurationSummary]
    let groups: [ProxyGroupConfigurationSummary]
    let searchText: String

    var body: some View {
        FeatureSection(title: "Nodes", symbol: "server.rack") {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(inventorySummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)

                Table(visibleProxies) {
                    TableColumn("Name") { proxy in
                        Text(proxy.name)
                            .font(.body)
                            .foregroundStyle(.primary)
                            .strikethrough(!proxy.recognition.isSelectable)
                            .lineLimit(1)
                            .help(proxy.name)
                    }
                    .width(min: 84, ideal: 100)
                    TableColumn("Protocol") { proxy in
                        Text(proxy.protocolName.uppercased())
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(proxy.protocolName.uppercased())
                    }
                    .width(min: 68, ideal: 80, max: 92)
                    TableColumn("In groups") { proxy in
                        Text(membership(of: proxy.name))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .help(membership(of: proxy.name))
                    }
                    .width(min: 80, ideal: 104, max: 170)
                    TableColumn("Core status") { proxy in
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
                .accessibilityLabel("Proxy nodes")
                .accessibilityIdentifier("proxy-node-inventory-table")
                .scrollIndicators(.hidden, axes: .horizontal)
                .environment(\.defaultMinListRowHeight, 36)
                .frame(height: min(CGFloat(visibleProxies.count * 36 + 34), 320))
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

    private var visibleProxies: [ProxyConfigurationSummary] {
        guard !searchText.isEmpty else { return proxies }
        return proxies.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.protocolName.localizedCaseInsensitiveContains(searchText)
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

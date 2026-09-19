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
                    title: AppLocalization.string("No proxies yet"),
                    detail: AppLocalization.string("Import a validated profile to inspect its endpoints and proxy groups.")
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
                        .transition(.opacity.combined(with: .scale(scale: 0.995, anchor: .top)))
                    }
                }

                // 3. 辅助折叠区域：节点底库清单与 Providers（高级选项）
                advancedInventorySection(summary: summary)

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
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(AppLocalization.string("Proxy configuration"))
            .accessibilityIdentifier("proxies-page-content")
        }
        .searchable(
            text: $searchText,
            placement: .toolbar,
            prompt: Text(AppLocalization.string("Search nodes"))
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
            HStack(alignment: .center) {
                HStack(spacing: AetherVisual.s2) {
                    Text(AppLocalization.string("Proxy groups"))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(verbatim: "\(groups.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: AetherVisual.s1) {
                    ForEach(groups) { group in
                        let isSelected = (currentGroup(from: groups)?.id == group.id)
                        let currentMember = tunnel.proxySelections[group.name]?.selectedMember

                        ProxyGroupTabButton(
                            group: group,
                            isSelected: isSelected,
                            currentMember: currentMember,
                            onSelect: {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.8)) {
                                    selectedGroupId = group.id
                                }
                            }
                        )
                    }
                }
                .padding(AetherVisual.sMicro)
                .background(
                    Color(nsColor: .controlBackgroundColor).opacity(0.55),
                    in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius + 2, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius + 2, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
                }
            }
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
                    FeatureSection(title: AppLocalization.string("Providers"), symbol: "shippingbox") {
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
            HStack(spacing: AetherVisual.sCompact) {
                Image(systemName: "wrench.and.screwdriver")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    HStack(spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Raw Node Inventory & Providers"))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.primary)

                        Text(verbatim: "(\(summary.proxyCount) \(AppLocalization.string("Endpoints")))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Text(AppLocalization.string("Diagnostic use only; inspects kernel protocol validation and raw endpoints."))
                        .font(.caption2)
                        .foregroundStyle(.secondary.opacity(0.85))
                }

                Spacer()
            }
        }
        .padding(AetherVisual.s3)
        .background(
            Color(nsColor: .controlBackgroundColor).opacity(0.4),
            in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius)
        )
    }
}

fileprivate func proxyGroupSymbol(_ strategy: String) -> String {
    switch strategy.lowercased() {
    case "select": return "square.stack.3d.up.fill"
    case "url-test": return "bolt.horizontal.fill"
    case "fallback": return "arrow.triangle.pull"
    case "load-balance": return "scale.3d"
    default: return "point.3.connected.trianglepath.dotted"
    }
}

// MARK: - 策略组 Tab 按钮组件
private struct ProxyGroupTabButton: View {
    let group: ProxyGroupConfigurationSummary
    let isSelected: Bool
    let currentMember: String?
    let onSelect: () -> Void
    @State private var isHovered = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: AetherVisual.s2) {
                Image(systemName: proxyGroupSymbol(group.strategy))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        (isSelected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08)),
                        in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    HStack(spacing: AetherVisual.s1) {
                        Text(group.name)
                            .font(.system(size: 13, weight: isSelected ? .bold : .medium))
                            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                            .lineLimit(1)

                        Text(group.strategy.uppercased())
                            .font(.system(size: 8.5, weight: .bold))
                            .padding(.horizontal, AetherVisual.s1)
                            .padding(.vertical, AetherVisual.sMicro)
                            .background(
                                (isSelected ? Color.accentColor.opacity(0.16) : Color.secondary.opacity(0.1)),
                                in: Capsule()
                            )
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    }

                    if let currentMember {
                        HStack(spacing: AetherVisual.s1) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 4.5, height: 4.5)
                            Text(currentMember)
                                .font(.system(size: 10.5))
                                .foregroundStyle(isSelected ? Color.primary.opacity(0.8) : Color.secondary.opacity(0.7))
                                .lineLimit(1)
                        }
                    } else {
                        Text(group.strategy.lowercased() == "url-test" ? AppLocalization.string("Auto select fastest") : group.strategy.uppercased())
                            .font(.system(size: 10.5))
                            .foregroundStyle(Color.secondary.opacity(0.65))
                            .lineLimit(1)
                    }
                }

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.leading, AetherVisual.sMicro)
                }
            }
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.sCompact)
            .contentShape(RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous))
            .background(
                isSelected
                    ? AnyShapeStyle(Color(nsColor: .controlBackgroundColor))
                    : AnyShapeStyle(isHovered ? Color.secondary.opacity(0.08) : Color.clear),
                in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
            )
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 1.2)
                }
            }
            .shadow(
                color: isSelected ? Color.black.opacity(colorScheme == .dark ? 0.3 : 0.08) : Color.clear,
                radius: 2.5,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(AetherVisual.quickFade) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - 当前选中策略组视图
private struct ActiveProxyGroupView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var filter: ProxyNodeFilter = .all
    @State private var sort: ProxyNodeSort = .default
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
                    Text(isTesting ? AppLocalization.string("Testing latency…") : AppLocalization.string("Latency results are local"))
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
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
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                // 左侧：当前选中的策略组身份标识与名称
                HStack(spacing: AetherVisual.s2) {
                    Image(systemName: proxyGroupSymbol(group.strategy))
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.accentColor)

                    Text(group.name)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(group.strategy.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                Spacer()

                if isManuallySelectable {
                    HStack(spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Selection mode"))
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
                            Text(AppLocalization.string("Manual")).tag(false)
                            Text(AppLocalization.string("Auto")).tag(true)
                        } label: {
                            EmptyView()
                        }
                        .pickerStyle(.segmented)
                        .controlSize(.small)
                        .frame(width: 120)
                        .disabled(tunnel.proxySelectionRequests.contains(group.name))
                        .accessibilityIdentifier("proxy-selection-mode-\(group.name)")
                    }
                } else {
                    HStack(spacing: AetherVisual.sCompact) {
                        Image(systemName: "bolt.horizontal.circle.fill")
                            .font(.caption)
                            .foregroundStyle(Color.accentColor)
                        Text(
                            tunnel.isConnected
                                ? AppLocalization.string("This group is automatically managed by latency tests.")
                                : AppLocalization.string("This automatic group is ready and will choose the fastest available node when you connect.")
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    }
                }
            }

            // 副标题说明
            HStack {
                if isManuallySelectable {
                    Text(
                        isAutomaticSelectionMode
                            ? AppLocalization.string("Retries the fastest available node")
                            : AppLocalization.string("Keeps the selected node pinned")
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }

                Spacer()

                if !tunnel.isConnected {
                    Label(
                        AppLocalization.string("The selected node will be used on the next connection."),
                        systemImage: "checkmark.circle"
                    )
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                }
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
                Picker(AppLocalization.string("Sort"), selection: $sort) {
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
                    AetherProgressButtonLabel(AppLocalization.string("Test latency"), isWorking: isTesting)
                        .fixedSize(horizontal: true, vertical: false)
                        .frame(minWidth: 72)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(isTesting)
                .help(AppLocalization.string("Test latency for current group nodes"))
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
        HStack(spacing: AetherVisual.s1) {
            ForEach(ProxyNodeFilter.allCases) { option in
                let isSelected = (filter == option)
                let count = members.filter { option.accepts(status(for: $0)) && matchesSearch($0) }.count

                Button {
                    withAnimation(AetherVisual.quickFade) {
                        filter = option
                    }
                } label: {
                    HStack(spacing: AetherVisual.sCompact) {
                        Text(option.localizedTitle)
                            .font(.system(size: 11.5, weight: isSelected ? .semibold : .regular))
                        Text(verbatim: "\(count)")
                            .font(.system(size: 9.5, weight: .bold, design: .rounded))
                            .padding(.horizontal, AetherVisual.s1)
                            .padding(.vertical, AetherVisual.sMicro)
                            .background(
                                isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12),
                                in: Capsule()
                            )
                    }
                    .padding(.horizontal, AetherVisual.s2)
                    .padding(.vertical, AetherVisual.s1)
                    .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
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
    }

    // MARK: - 节点网格展示 (现代卡片布局)
    private var nodeGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 270, maximum: 380), spacing: AetherVisual.s3)],
            spacing: AetherVisual.s3
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
                    confidence: tunnel.latencyConfidence(
                        group: group.name,
                        member: member
                    ),
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
                            await tunnel.testSingleProxyLatency(group: group.name, member: member)
                        }
                    }
                )
            }
        }
        .padding(.vertical, AetherVisual.s1)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Proxy group members"))
    }

    // MARK: - 节点列表展示 (Table 兼容已有测试标识)
    private var nodeList: some View {
        Table(memberRows) {
            TableColumn(AppLocalization.string("Name")) { row in
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
            TableColumn(AppLocalization.string("Protocol")) { row in
                Text(row.protocolName?.uppercased() ?? "—")
                    .font(.subheadline.monospaced().weight(.semibold))
                    .foregroundStyle(.primary)
            }
            .width(84)
            TableColumn(AppLocalization.string("Latency")) { row in
                ProxyLatencyBadge(
                    status: row.status,
                    name: nil,
                    confidence: row.confidence
                )
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(88)
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
        .accessibilityLabel(AppLocalization.string("Proxy group members"))
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
                confidence: tunnel.latencyConfidence(
                    group: group.name,
                    member: member
                ),
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
        let filtered = members.filter { filter.accepts(status(for: $0)) && matchesSearch($0) }
        return ProxyPageNodeOrder.sorted(members: filtered, by: sort) { latencyRank(status(for: $0)) }
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
            isTesting: tunnel.isTestingLatency(group: group.name, member: member)
        )
    }
}

// MARK: - 现代节点卡片组件 (对标 Clash Verge Rev & Surge 5 Mac)
private struct ProxyNodeModernCard: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    let protocolName: String
    let status: ProxyLatencyStatus
    let confidence: ProxyLatencyConfidence
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
            HStack(spacing: AetherVisual.sRow) {
                // 左侧 Accent Bar 指示 (仅在选中时点亮，未选中透明占位保持整齐对齐)
                Capsule()
                    .fill(isSelected ? Color.accentColor : Color.clear)
                    .frame(width: 3.5, height: 34)

                // 节点图标：匹配国旗或协议科技微晶
                AetherNodeIcon(name: name, protocolName: protocolName, size: 28)

                // 中间信息：节点名 (单行不折行) + 协议徽标与状态
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(name)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.primary : Color.primary.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(name)

                    HStack(spacing: AetherVisual.sCompact) {
                        AetherProtocolBadge(type: protocolName)

                        if isSelected {
                            HStack(spacing: AetherVisual.sMicro) {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 5, height: 5)
                                Text(AppLocalization.string("Active"))
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            Text(flagInfo.region)
                                .font(.system(size: 9.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary.opacity(0.8))
                        }
                    }
                }

                Spacer(minLength: AetherVisual.s1)

                // 右侧延迟测速胶囊
                AetherLatencyPill(
                    status: status,
                    confidence: confidence,
                    onTap: onTest
                )
            }
            .padding(.leading, AetherVisual.sCompact)
            .padding(.trailing, AetherVisual.sRow)
            .padding(.vertical, AetherVisual.sRow)
            .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
            .contentShape(RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .disabled(!canSelect || isBusy)
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .fill(cardBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .stroke(cardBorder, lineWidth: isSelected ? 1.2 : (isHovered ? 0.9 : 0.5))
        }
        .scaleEffect(isHovered ? 1.008 : 1.0)
        .shadow(
            color: isSelected
                ? Color.accentColor.opacity(colorScheme == .dark ? 0.25 : 0.15)
                : (isHovered ? Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08) : Color.clear),
            radius: isSelected ? 6 : (isHovered ? 4 : 0),
            y: isSelected ? 1.5 : (isHovered ? 1.5 : 0)
        )
        .animation(AetherVisual.gentleSpring, value: isHovered)
        .animation(AetherVisual.gentleSpring, value: isSelected)
        .onHover { hovering in
            isHovered = hovering
        }
        .contextMenu {
            Button(AppLocalization.string("Switch to this node")) { onSelect() }
                .disabled(!canSelect || isBusy)
            Button(AppLocalization.string("Test latency")) { onTest() }
            Divider()
            Button(AppLocalization.string("Copy node name")) {
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

}

// MARK: - 表格模型

private struct ProxyMemberTableItem: Identifiable {
    let member: String
    let protocolName: String?
    let status: ProxyLatencyStatus
    let confidence: ProxyLatencyConfidence
    let isSelected: Bool
    let isBusy: Bool

    var id: String { member }
}

private struct ProxyLatencyBadge: View {
    let status: ProxyLatencyStatus
    let name: String?
    /// Only meaningful for a measured number; an untested or timed-out row has
    /// nothing to qualify.
    var confidence: ProxyLatencyConfidence = .reachability

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

            if status.isMeasured {
                Image(systemName: confidence.symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(
                        confidence == .verified ? Color.accentColor : .secondary
                    )
                    .help(confidence.localizedHint)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityDescription)
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

    /// The badge's colour and glyph are never the only cue: the qualifier is
    /// spoken too, so a measured number is not mistaken for a verified one.
    private var accessibilityDescription: String {
        guard status.isMeasured else { return text }
        return "\(text), \(confidence.localizedHint)"
    }
}

private struct ProxyNodeInventory: View {
    let proxies: [ProxyConfigurationSummary]
    let groups: [ProxyGroupConfigurationSummary]
    let searchText: String

    var body: some View {
        FeatureSection(title: AppLocalization.string("Nodes"), symbol: "server.rack") {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(inventorySummary)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)

                Table(visibleProxies) {
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

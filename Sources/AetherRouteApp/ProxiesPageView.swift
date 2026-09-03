import AetherRouteKit
import SwiftUI

/// The proxies page answers three different questions, in descending order of
/// how often they are asked: which node am I on and what do I want instead,
/// which imported nodes can the core actually use, and where did this batch of
/// nodes come from. The groups stay collapsible so that a profile with hundreds
/// of nodes still shows every group's current choice on one screen.
struct ProxiesView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var searchText = ""

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

    private func content(
        summary: ProfileConfigurationSummary
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                if !summary.proxyGroups.isEmpty {
                    proxyGroupSection(summary.proxyGroups, proxies: summary.proxies)
                }

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

    private func defaultExpandedGroupID(
        _ groups: [ProxyGroupConfigurationSummary]
    ) -> Int? {
        groups.first { $0.strategy.lowercased() == "select" }?.id
            ?? groups.first?.id
    }

    private func proxyGroupSection(
        _ groups: [ProxyGroupConfigurationSummary],
        proxies: [ProxyConfigurationSummary]
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack {
                Text("Proxy groups")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("%lld groups"),
                        Int64(groups.count)
                    )
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
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
                .disabled(!tunnel.isConnected || !tunnel.proxyLatencyRequests.isEmpty)
                .accessibilityIdentifier("test-all-proxy-groups")
            }

            VStack(spacing: 0) {
                ForEach(groups) { group in
                    ProxyGroupDisclosure(
                        group: group,
                        protocols: Dictionary(
                            uniqueKeysWithValues: proxies.map { ($0.name, $0.protocolName) }
                        ),
                        searchText: searchText,
                        // Only the group you actually steer starts open. The
                        // rest stay collapsed so a many-group profile still
                        // fits on one screen.
                        isExpandedByDefault: group.id == defaultExpandedGroupID(groups)
                    )
                    if group.id != groups.last?.id {
                        Divider()
                    }
                }
            }
            .featureCard()
        }
    }
}

/// One collapsible group. Collapsed is the common case, so the closed row has
/// to carry the current selection and its latency — collapsing must not mean
/// hiding.
private struct ProxyGroupDisclosure: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @AppStorage private var isExpanded: Bool
    @State private var filter: ProxyNodeFilter = .all
    @State private var sort: ProxyNodeSort = .latency

    let group: ProxyGroupConfigurationSummary
    let protocols: [String: String]
    let searchText: String

    init(
        group: ProxyGroupConfigurationSummary,
        protocols: [String: String],
        searchText: String,
        isExpandedByDefault: Bool
    ) {
        self.group = group
        self.protocols = protocols
        self.searchText = searchText
        _isExpanded = AppStorage(
            wrappedValue: isExpandedByDefault,
            "proxy-group-expanded-\(group.name)"
        )
    }

    var body: some View {
        DisclosureGroup(isExpanded: effectiveExpansion) {
            expandedContent
                .padding(.horizontal, AetherVisual.s3)
                .padding(.bottom, AetherVisual.s3)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        } label: {
            collapsedSummary
        }
        .padding(.horizontal, AetherVisual.s3)
        .frame(minHeight: 46)
        .task(id: tunnel.isConnected) {
            guard isManuallySelectable else { return }
            await tunnel.refreshProxySelection(group: group.name)
        }
    }

    /// A search hit forces the group open so results are never hidden behind a
    /// collapsed row, without overwriting what the person chose manually.
    private var effectiveExpansion: Binding<Bool> {
        guard hasSearchMatch else { return $isExpanded }
        return .constant(true)
    }

    private var hasSearchMatch: Bool {
        guard !searchText.isEmpty else { return false }
        return members.contains { $0.localizedCaseInsensitiveContains(searchText) }
    }

    private var collapsedSummary: some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: groupSymbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 26, height: 26)
                .background(
                    Color.accentColor.opacity(0.08),
                    in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius)
                )
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(group.name)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("%@ · %lld members"),
                        group.strategy,
                        Int64(group.memberCount)
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: AetherVisual.s3)

            if let selected = selectedMember {
                HStack(spacing: AetherVisual.s2) {
                    Text(
                        isAutomaticSelectionMode || !isManuallySelectable
                            ? "Auto-selected"
                            : "In use"
                    )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ProxyLatencyBadge(
                        status: status(for: selected),
                        name: selected
                    )
                }
            } else if !tunnel.isConnected {
                Text("Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var groupSymbol: String {
        isManuallySelectable ? "square.stack.3d.up.fill" : "arrow.clockwise"
    }

    @ViewBuilder
    private var expandedContent: some View {
        if isManuallySelectable {
            selectableContent
        } else {
            automaticContent
        }

        if let message = tunnel.proxySelectionMessages[group.name] {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.top, AetherVisual.s2)
        }
    }

    private var selectableContent: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(spacing: AetherVisual.s3) {
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
                    Text("Automatic").tag(true)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.segmented)
                .accessibilityLabel(Text("Selection mode"))
                .frame(width: 190)
                .disabled(tunnel.proxySelectionRequests.contains(group.name))
                .accessibilityIdentifier(
                    "proxy-selection-mode-\(group.name)"
                )
                Spacer()
                Text(
                    isAutomaticSelectionMode
                        ? "Retries the fastest available node"
                        : "Keeps the selected node pinned"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            }

            HStack(spacing: AetherVisual.s2) {
                Picker("Filter", selection: $filter) {
                    ForEach(ProxyNodeFilter.allCases) { option in
                        Text(label(for: option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 340)

                Spacer(minLength: AetherVisual.s2)

                Picker("Sort", selection: $sort) {
                    ForEach(ProxyNodeSort.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("proxy-sort-picker")
                .frame(width: 108)

                Button {
                    Task { await tunnel.testProxyLatency(group: group.name) }
                } label: {
                    AetherProgressButtonLabel(
                        "Test latency",
                        isWorking: isTesting
                    )
                }
                .buttonStyle(.bordered)
                .disabled(!tunnel.isConnected || isTesting)
            }

            if !tunnel.isConnected {
                Label(
                    "The selected node will be used on the next connection.",
                    systemImage: "checkmark.circle"
                )
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            }

            if visibleMembers.isEmpty {
                FeatureEmptyState(
                    symbol: "line.3.horizontal.decrease.circle",
                    title: "No matching nodes",
                    detail: "Change the filter, or clear the search field."
                )
            } else {
                memberList

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
                .font(.caption2.weight(.medium))
                .foregroundStyle(.primary)
            }
        }
    }

    private var memberList: some View {
        Table(memberRows) {
            TableColumn("Name") { row in
                Button {
                    Task {
                        await tunnel.selectProxy(
                            group: group.name,
                            member: row.member
                        )
                    }
                } label: {
                    Text(row.member)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    row.isBusy
                        || !isManuallySelectable
                        || isAutomaticSelectionMode
                )
                .accessibilityAddTraits(row.isSelected ? [.isSelected] : [])
                .contextMenu {
                    Button("Switch to this node") {
                        Task {
                            await tunnel.selectProxy(
                                group: group.name,
                                member: row.member
                            )
                        }
                    }
                    .disabled(
                        !isManuallySelectable || isAutomaticSelectionMode
                    )
                    Button("Retest this group") {
                        Task { await tunnel.testProxyLatency(group: group.name) }
                    }
                    .disabled(!tunnel.isConnected)
                    Divider()
                    Button("Copy node name") { copy(row.member) }
                }
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
        .frame(height: min(CGFloat(memberRows.count * 28 + 34), 196))
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

    /// A url-test group is chosen by the core, so the expansion explains the
    /// rule rather than offering a control that would be ignored.
    private var automaticContent: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(
                tunnel.isConnected
                    ? "This group is chosen by the protocol core from its own latency tests, so it cannot be set by hand. Expand a manual group to choose a node."
                    : "This automatic group is ready and will choose the fastest available node when you connect."
            )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            memberList

            Button {
                Task { await tunnel.testProxyLatency(group: group.name) }
            } label: {
                AetherProgressButtonLabel("Test latency", isWorking: isTesting)
            }
            .buttonStyle(.bordered)
            .disabled(!tunnel.isConnected || isTesting)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
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

/// The status dot plus its text. The text is what makes this readable without
/// colour vision, so it is never dropped.
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

/// The node inventory answers availability, not speed. A node the core rejects
/// cannot be rescued by a faster measurement, so this table never shows latency.
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
                            .font(.subheadline)
                            .strikethrough(!proxy.recognition.isSelectable)
                            .lineLimit(1)
                    }
                    TableColumn("Protocol") { proxy in
                        Text(proxy.protocolName.uppercased())
                            .font(.subheadline.monospaced().weight(.semibold))
                            .foregroundStyle(.primary)
                    }
                    .width(92)
                    TableColumn("In groups") { proxy in
                        Text(membership(of: proxy.name))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }
                    .width(min: 120, ideal: 148, max: 170)
                    TableColumn("Core status") { proxy in
                        Label(
                            proxy.recognition.localizedTitle,
                            systemImage: proxy.recognition.symbol
                        )
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .labelStyle(.titleAndIcon)
                    }
                    .width(min: 104, ideal: 118, max: 132)
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

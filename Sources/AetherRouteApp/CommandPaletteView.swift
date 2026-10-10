import AetherRouteKit
import SwiftUI

extension Notification.Name {
    /// Posted by the Navigate menu (⇧⌘P) to toggle the command palette.
    static let aetherRouteToggleCommandPalette = Notification.Name(
        "com.aetherroute.desktop.toggle-command-palette"
    )
}

/// One runnable entry in the command palette.
struct CommandPaletteItem: Identifiable {
    enum Kind: Int {
        case action
        case node
        case page
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String
    let symbol: String
    var isCurrent = false
    var isEnabled = true
    let perform: () -> Void

    /// Every query word must appear in the title or subtitle. Titles that
    /// start with the query rank first, so typing "sing" puts "Singapore
    /// Edge" above a node that merely mentions it.
    func rank(for query: String) -> Int? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        let haystack = (title + " " + subtitle).lowercased()
        guard words.allSatisfy(haystack.contains) else { return nil }
        return title.lowercased().hasPrefix(words[0]) ? 0 : 1
    }
}

/// A keyboard-first launcher over the whole app: connect, switch modes,
/// jump to a page, or pick a node, without reaching for the pointer.
struct CommandPaletteView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.openSettings) private var openSettings
    let navigate: (AppSection) -> Void
    let dismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isSearchFocused: Bool

    var body: some View {
        let results = filteredItems
        VStack(spacing: 0) {
            HStack(spacing: AetherVisual.s3) {
                Image(systemName: "magnifyingglass")
                    .font(.title3)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .accessibilityHidden(true)
                TextField(AppLocalization.string("Search actions, pages and nodes"), text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit { run(results) }
                    .accessibilityIdentifier("command-palette-field")
            }
            .padding(AetherVisual.s4)

            Divider()

            if results.isEmpty {
                Text(AppLocalization.string("No matching commands"))
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity)
                    .padding(AetherVisual.s6)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                            ForEach(Array(results.enumerated()), id: \.element.id) { index, item in
                                if index == 0 || results[index - 1].kind != item.kind {
                                    sectionTitle(item.kind)
                                        .padding(.top, sectionGap(before: index))
                                }
                                CommandPaletteRow(item: item, isSelected: index == selection)
                                    .id(item.id)
                                    .onTapGesture {
                                        selection = index
                                        run(results)
                                    }
                                    .onHover { if $0 { selection = index } }
                            }
                        }
                        .padding(AetherVisual.s2)
                    }
                    .frame(maxHeight: 360)
                    .onChange(of: selection) { _, newValue in
                        guard results.indices.contains(newValue) else { return }
                        withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                            proxy.scrollTo(results[newValue].id)
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: AetherVisual.s4) {
                shortcutHint("↑↓", AppLocalization.string("Select"))
                shortcutHint("↩", AppLocalization.string("Run"))
                shortcutHint("esc", AppLocalization.string("Close"))
                Spacer()
            }
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.s2)
        }
        .frame(width: 560)
        // A floating panel over the page, so it keeps Liquid Glass; page
        // content uses the plain card surface (`aetherPanel`).
        .aetherGlass(in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous))
        .onAppear { isSearchFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
        .onKeyPress(.downArrow) {
            selection = min(selection + 1, max(results.count - 1, 0))
            return .handled
        }
        .onKeyPress(.upArrow) {
            selection = max(selection - 1, 0)
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("command-palette")
    }

    private func sectionTitle(_ kind: CommandPaletteItem.Kind) -> some View {
        let title: String = switch kind {
        case .action: AppLocalization.string("Actions")
        case .node: AppLocalization.string("Nodes")
        case .page: AppLocalization.string("Pages")
        }
        return Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(AetherVisual.secondaryText)
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.s1)
    }

    /// No gap above the first section; one step between later sections.
    private func sectionGap(before index: Int) -> CGFloat {
        index == 0 ? .zero : AetherVisual.s2
    }

    private func shortcutHint(_ key: String, _ title: String) -> some View {
        HStack(spacing: AetherVisual.s1) {
            Text(verbatim: key)
                .font(.caption.monospaced())
                .padding(.horizontal, AetherVisual.s1)
                .background(AetherVisual.neutralFill, in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius))
            Text(title)
        }
    }

    private func run(_ results: [CommandPaletteItem]) {
        guard results.indices.contains(selection) else { return }
        let item = results[selection]
        guard item.isEnabled else { return }
        dismiss()
        item.perform()
    }

    private var filteredItems: [CommandPaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        return allItems
            .compactMap { item in item.rank(for: trimmed).map { (item, $0) } }
            .sorted { lhs, rhs in
                if lhs.0.kind != rhs.0.kind { return lhs.0.kind.rawValue < rhs.0.kind.rawValue }
                return lhs.1 < rhs.1
            }
            .map(\.0)
            // An empty query lists actions and pages, not every node of a
            // large subscription.
            .filter { trimmed.isEmpty ? $0.kind != .node || $0.isCurrent : true }
    }

    private var allItems: [CommandPaletteItem] {
        var items: [CommandPaletteItem] = []

        items.append(CommandPaletteItem(
            id: "action.power",
            kind: .action,
            title: tunnel.primaryActionTitle,
            subtitle: tunnel.compactStatusTitle,
            symbol: "power",
            isEnabled: tunnel.canPerformPrimaryAction,
            perform: { Task { await tunnel.setEnabled(!tunnel.isEnabled) } }
        ))
        if tunnel.isConnected {
            items.append(CommandPaletteItem(
                id: "action.reconnect",
                kind: .action,
                title: AppLocalization.string("Reconnect"),
                subtitle: "",
                symbol: "arrow.clockwise",
                perform: { Task { await tunnel.reconnect() } }
            ))
        }
        for mode in RoutingMode.allCases {
            items.append(CommandPaletteItem(
                id: "action.routing.\(mode.rawValue)",
                kind: .action,
                title: routingTitle(mode),
                subtitle: AppLocalization.string("Routing mode"),
                symbol: mode.symbol,
                isCurrent: tunnel.routingMode == mode,
                isEnabled: tunnel.canChangeRoutingMode,
                perform: { Task { await tunnel.setRoutingMode(mode) } }
            ))
        }
#if AETHERROUTE_INDEPENDENT
        for mode in NetworkEngineMode.allCases {
            items.append(CommandPaletteItem(
                id: "action.engine.\(mode.rawValue)",
                kind: .action,
                title: mode.localizedTitle,
                subtitle: AppLocalization.string("Network engine"),
                symbol: mode == .tun ? "bolt.shield" : "network",
                isCurrent: tunnel.networkEngineMode == mode,
                isEnabled: tunnel.canChangeNetworkEngine,
                perform: { Task { await tunnel.setNetworkEngineMode(mode) } }
            ))
        }
#endif
        if let group = primaryGroup {
            items.append(CommandPaletteItem(
                id: "action.latency",
                kind: .action,
                title: AppLocalization.string("Test latency"),
                subtitle: group.name,
                symbol: "bolt",
                isEnabled: !tunnel.proxyLatencyRequests.contains(group.name),
                perform: { Task { await tunnel.testProxyLatency(group: group.name) } }
            ))
            let selected = tunnel.proxySelections[group.name]?.selectedMember
            let members = tunnel.proxySelections[group.name]?.members ?? group.members
            for member in members {
                items.append(CommandPaletteItem(
                    id: "node.\(group.name).\(member)",
                    kind: .node,
                    title: member,
                    subtitle: group.name,
                    symbol: "point.3.connected.trianglepath.dotted",
                    isCurrent: member == selected,
                    isEnabled: !tunnel.automaticProxySelectionGroups.contains(group.name),
                    perform: { Task { await tunnel.selectProxy(group: group.name, member: member) } }
                ))
            }
        }
        for section in AppSection.allCases {
            items.append(CommandPaletteItem(
                id: "page.\(section.rawValue)",
                kind: .page,
                title: section.title,
                subtitle: section.subtitle,
                symbol: section.symbol,
                perform: { navigate(section) }
            ))
        }
        items.append(CommandPaletteItem(
            id: "page.settings",
            kind: .page,
            title: AppLocalization.string("Settings"),
            subtitle: "",
            symbol: "gearshape",
            perform: { openSettings() }
        ))
        return items
    }

    private var primaryGroup: ProxyGroupConfigurationSummary? {
        let groups = tunnel.activeProfileSummary?.proxyGroups ?? []
        return groups.first { $0.strategy.lowercased() == "select" } ?? groups.first
    }

    private func routingTitle(_ mode: RoutingMode) -> String {
        switch mode {
        case .rule: AppLocalization.string("Rule mode")
        case .global: AppLocalization.string("Global mode")
        case .direct: AppLocalization.string("Direct mode")
        }
    }
}

private struct CommandPaletteRow: View {
    let item: CommandPaletteItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: item.symbol)
                .font(.body)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.white) : AnyShapeStyle(AetherVisual.secondaryText))
                .frame(width: AetherVisual.s5)
                .accessibilityHidden(true)
            Text(item.title)
                .font(.body)
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if item.isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : Color.accentColor)
                    .accessibilityLabel(AppLocalization.string("Current"))
            }
            Spacer(minLength: AetherVisual.s2)
            Text(item.subtitle)
                .font(.caption)
                .foregroundStyle(isSelected ? AnyShapeStyle(AetherVisual.selectedSecondaryText) : AnyShapeStyle(AetherVisual.secondaryText))
                .lineLimit(1)
        }
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.sCompact)
        .background(
            isSelected ? Color.accentColor : Color.clear,
            in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
        )
        .opacity(item.isEnabled ? 1 : 0.45)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
    }
}

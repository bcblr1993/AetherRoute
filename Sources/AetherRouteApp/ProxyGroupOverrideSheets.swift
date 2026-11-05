import AetherRouteKit
import SwiftUI

// Profile overrides (1.7.0): editors for custom groups, groups by region and
// hidden nodes. Each one previews its effect on the active profile before it
// is saved, and none changes the profile itself.

// MARK: - Custom group

struct CustomProxyGroupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    let initial: CustomProxyGroup?

    @State private var name: String
    @State private var regions: Set<String>
    @State private var includeText: String
    @State private var excludeText: String
    @State private var manualNodes: [String]
    @State private var mode: ProxySelectionMode
    @State private var parentGroup: String
    @State private var position: CustomProxyGroup.Position
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var requestsCancel = false
    @State private var confirmsDelete = false
    @State private var showsNodePicker = false

    /// "" means the group is not listed anywhere.
    private static let noParent = ""

    init(initial: CustomProxyGroup? = nil, defaultParent: String? = nil) {
        self.initial = initial
        _name = State(initialValue: initial?.name ?? "")
        _regions = State(initialValue: Set(initial?.regions ?? []))
        _includeText = State(initialValue: (initial?.includeKeywords ?? []).joined(separator: ", "))
        _excludeText = State(initialValue: (initial?.excludeKeywords ?? []).joined(separator: ", "))
        _manualNodes = State(initialValue: initial?.manualNodes ?? [])
        _mode = State(initialValue: initial?.mode ?? .fastest)
        _parentGroup = State(initialValue: initial.map { $0.parentGroup ?? Self.noParent } ?? defaultParent ?? Self.noParent)
        _position = State(initialValue: initial?.position ?? .top)
    }

    private var candidate: CustomProxyGroup {
        CustomProxyGroup(
            id: initial?.id ?? UUID(),
            name: name,
            regions: Array(regions),
            includeKeywords: Self.keywords(includeText),
            excludeKeywords: Self.keywords(excludeText),
            manualNodes: manualNodes,
            mode: mode,
            parentGroup: parentGroup == Self.noParent ? nil : parentGroup,
            position: position
        )
    }

    /// The override as it would be saved, or the reason it cannot be.
    private var proposed: Result<ProfileOverride, Error> {
        Result {
            var overrides = tunnel.activeProfileOverrides
            let group = try candidate.validated()
            if let initial, let index = overrides.groups.firstIndex(where: { $0.id == initial.id }) {
                overrides.groups[index] = group
            } else {
                overrides.groups.append(group)
            }
            return try overrides.validated()
        }
    }

    private var preview: (members: [String], conflict: Bool)? {
        guard case let .success(overrides) = proposed,
              let result = tunnel.activeOverrideResult(overrides) else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let conflict = result.diagnostics.contains(.nameConflict(group: trimmed))
        return (result.customGroupMembers[trimmed] ?? [], conflict)
    }

    private var nodes: [String] { tunnel.activeProfileNodeNames }

    private var regionOptions: [ProfileOverrideSuggestions.Region] {
        ProfileOverrideSuggestions.regions(in: nodes)
    }

    /// Groups this one can be listed in: the profile's own select groups.
    private var parentOptions: [String] {
        let custom = Set(tunnel.activeProfileOverrides.groups.map(\.name))
        return (tunnel.activeProfileSummary?.proxyGroups ?? [])
            .filter { $0.strategy.caseInsensitiveCompare("select") == .orderedSame && !custom.contains($0.name) }
            .map(\.name)
    }

    private var hasChanges: Bool {
        guard let initial else {
            return !name.isEmpty || !regions.isEmpty || !includeText.isEmpty
                || !excludeText.isEmpty || !manualNodes.isEmpty
        }
        return candidate != initial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "rectangle.stack.badge.plus",
                title: initial == nil
                    ? AppLocalization.string("New group")
                    : AppLocalization.string("Edit group"),
                subtitle: AppLocalization.string("Members follow the rules below, so nodes the subscription adds or removes join or leave on their own."),
                tint: AppSection.proxies.tileColor
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AetherVisual.s4) {
                    settingsCard
                    sourcesSection
                    previewSection
                }
            }
            .frame(minHeight: AetherVisual.sheetFormMinHeight, idealHeight: AetherVisual.sheetFormIdealHeight, maxHeight: AetherVisual.sheetFormMaxHeight)

            if saveFailed, let message = tunnel.profileMessage {
                AetherInlineMessage(text: message)
            }

            footer
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: parentGroup)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: preview?.members)
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
        .confirmationDialog(
            String.localizedStringWithFormat(AppLocalization.string("Delete the group %@?"), initial?.name ?? ""),
            isPresented: $confirmsDelete
        ) {
            Button(AppLocalization.string("Delete Group"), role: .destructive) { delete() }
                .accessibilityIdentifier("custom-group-confirm-delete")
        } message: {
            Text(AppLocalization.string("Groups that list it no longer do. The subscription itself is not changed."))
        }
        // A container's identifier would otherwise replace every child's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("custom-group-sheet")
    }

    private var settingsCard: some View {
        VStack(spacing: 0) {
            OverrideFormRow(AppLocalization.string("Name")) {
                TextField(AppLocalization.string("e.g. Hong Kong Auto"), text: $name)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Name"))
                    .accessibilityIdentifier("custom-group-name-field")
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Node selection")) {
                AetherSegmentedPicker(
                    selection: $mode,
                    options: ProxySelectionMode.allCases.map { .init(value: $0, title: $0.localizedTitle) },
                    accessibilityLabel: AppLocalization.string("Node selection"),
                    accessibilityIdentifier: "custom-group-mode"
                )
                .fixedSize()
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Show in")) {
                Picker(AppLocalization.string("Show in"), selection: $parentGroup) {
                    Text(AppLocalization.string("No other group")).tag(Self.noParent)
                    ForEach(parentOptions, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .accessibilityIdentifier("custom-group-parent")
            }
            if parentGroup != Self.noParent {
                Divider().padding(.leading, AetherVisual.s4)
                OverrideFormRow(AppLocalization.string("Position")) {
                    AetherSegmentedPicker(
                        selection: $position,
                        options: [
                            .init(value: .top, title: AppLocalization.string("First")),
                            .init(value: .bottom, title: AppLocalization.string("Last")),
                        ],
                        accessibilityLabel: AppLocalization.string("Position")
                    )
                    .fixedSize()
                }
                .transition(.opacity)
            }
        }
        .aetherPanel()
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Nodes to include"))
            VStack(alignment: .leading, spacing: 0) {
                if !regionOptions.isEmpty {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Regions"))
                        AetherFlowLayout(spacing: AetherVisual.s1) {
                            ForEach(regionOptions) { region in
                                RegionChip(region: region, isSelected: regions.contains(region.code)) {
                                    if regions.contains(region.code) {
                                        regions.remove(region.code)
                                    } else {
                                        regions.insert(region.code)
                                    }
                                }
                            }
                        }
                    }
                    .padding(AetherVisual.s4)
                    Divider().padding(.leading, AetherVisual.s4)
                }
                OverrideFormRow(AppLocalization.string("Name contains")) {
                    TextField(AppLocalization.string("Keywords, separated by commas"), text: $includeText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(AppLocalization.string("Name contains"))
                        .accessibilityIdentifier("custom-group-include-field")
                }
                Divider().padding(.leading, AetherVisual.s4)
                OverrideFormRow(AppLocalization.string("Leave out names containing")) {
                    TextField(AppLocalization.string("e.g. game, 0.1x"), text: $excludeText)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(AppLocalization.string("Leave out names containing"))
                        .accessibilityIdentifier("custom-group-exclude-field")
                }
                Divider().padding(.leading, AetherVisual.s4)
                OverrideFormRow(AppLocalization.string("Picked nodes")) {
                    Button {
                        showsNodePicker = true
                    } label: {
                        Text(manualNodes.isEmpty
                             ? AppLocalization.string("Choose…")
                             : String.localizedStringWithFormat(AppLocalization.string("%lld chosen"), Int64(manualNodes.count)))
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("custom-group-pick-nodes")
                    .popover(isPresented: $showsNodePicker, arrowEdge: .trailing) {
                        NodeChecklist(nodes: nodes, selection: $manualNodes)
                    }
                }
            }
            .aetherPanel()
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Preview"))
            switch proposed {
            case let .failure(error) where hasChanges:
                AetherInlineMessage(text: error.overrideMessage, kind: .warning, isCompact: true)
                    .padding(.horizontal, AetherVisual.sectionHeaderInset)
            case .failure:
                Text(AppLocalization.string("Choose regions, keywords or nodes for the group."))
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .padding(.horizontal, AetherVisual.sectionHeaderInset)
            case .success:
                if let preview {
                    if preview.conflict {
                        AetherInlineMessage(
                            text: AppLocalization.string("A node or group in this profile already has this name."),
                            kind: .warning,
                            isCompact: true
                        )
                        .padding(.horizontal, AetherVisual.sectionHeaderInset)
                    } else if preview.members.isEmpty {
                        AetherInlineMessage(
                            text: AppLocalization.string("No node matches yet. The group is kept and uses a direct connection until one does."),
                            kind: .warning,
                            isCompact: true
                        )
                        .padding(.horizontal, AetherVisual.sectionHeaderInset)
                    } else {
                        MemberPreviewList(
                            caption: String.localizedStringWithFormat(AppLocalization.string("%lld nodes match"), Int64(preview.members.count)),
                            members: preview.members
                        )
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: AetherVisual.s2) {
            if initial != nil {
                Button(AppLocalization.string("Delete Group"), role: .destructive) { confirmsDelete = true }
                    .aetherButton()
                    .accessibilityIdentifier("custom-group-delete")
            }
            Spacer()
            Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                .aetherButton()
                .keyboardShortcut(.cancelAction)
            Button {
                save()
            } label: {
                AetherProgressButtonLabel(AppLocalization.string("Save"), isWorking: isSaving)
            }
            .aetherButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
            .accessibilityIdentifier("custom-group-save")
        }
        .controlSize(.large)
    }

    private var canSave: Bool {
        guard case .success = proposed, let preview else { return false }
        return !preview.conflict && hasChanges
    }

    private func save() {
        guard case let .success(overrides) = proposed else { return }
        isSaving = true
        saveFailed = false
        Task {
            let saved = await tunnel.setProfileOverrides(overrides)
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }

    private func delete() {
        guard let initial else { return }
        var overrides = tunnel.activeProfileOverrides
        overrides.groups.removeAll { $0.id == initial.id }
        isSaving = true
        Task {
            let saved = await tunnel.setProfileOverrides(overrides)
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }

    /// Commas (either width), semicolons and new lines separate keywords.
    static func keywords(_ text: String) -> [String] {
        text.split(whereSeparator: { ",，;；\n".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Groups by region

struct RegionGroupsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    @State private var chosen: Set<String> = []
    @State private var parentGroup: String
    @State private var mode: ProxySelectionMode = .fastest
    @State private var isSaving = false
    @State private var saveFailed = false

    init(defaultParent: String?) {
        _parentGroup = State(initialValue: defaultParent ?? "")
    }

    /// Regions with at least two nodes: one node needs no group.
    private var regions: [ProfileOverrideSuggestions.Region] {
        ProfileOverrideSuggestions.regions(in: tunnel.activeProfileNodeNames, minimumNodes: 2)
    }

    private var takenNames: Set<String> {
        Set(tunnel.activeProfileNodeNames)
            .union(tunnel.activeProfileSummary?.proxyGroups.map(\.name) ?? [])
    }

    private var parentOptions: [String] {
        let custom = Set(tunnel.activeProfileOverrides.groups.map(\.name))
        return (tunnel.activeProfileSummary?.proxyGroups ?? [])
            .filter { $0.strategy.caseInsensitiveCompare("select") == .orderedSame && !custom.contains($0.name) }
            .map(\.name)
    }

    static func groupName(for region: ProfileOverrideSuggestions.Region) -> String {
        let flag = region.displayFlag
        return flag.isEmpty
            ? AppLocalization.regionName(region.code)
            : "\(flag) \(AppLocalization.regionName(region.code))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "globe.asia.australia",
                title: AppLocalization.string("Groups by region"),
                subtitle: AppLocalization.string("One group for each region, kept up to date as the subscription changes."),
                tint: AppSection.proxies.tileColor
            )

            if regions.isEmpty {
                ContentUnavailableView(
                    AppLocalization.string("No regions found"),
                    systemImage: "globe",
                    description: Text(AppLocalization.string("No two nodes in this profile name the same region. Use New Group with keywords instead."))
                )
                .frame(maxWidth: .infinity, minHeight: AetherVisual.sheetFormMinHeight)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(regions) { region in
                            let name = Self.groupName(for: region)
                            let exists = takenNames.contains(name)
                            Toggle(isOn: Binding(
                                get: { chosen.contains(region.code) && !exists },
                                set: { isOn in
                                    if isOn { chosen.insert(region.code) } else { chosen.remove(region.code) }
                                }
                            )) {
                                HStack {
                                    Text(name)
                                    Spacer()
                                    Text(exists
                                         ? AppLocalization.string("Already exists")
                                         : String.localizedStringWithFormat(AppLocalization.string("%lld nodes"), Int64(region.nodeCount)))
                                        .foregroundStyle(AetherVisual.secondaryText)
                                        .monospacedDigit()
                                }
                            }
                            .toggleStyle(.checkbox)
                            .disabled(exists)
                            .padding(.horizontal, AetherVisual.s4)
                            .frame(minHeight: AetherVisual.compactRowHeight)
                            .accessibilityIdentifier("region-group-\(region.code)")
                            if region.id != regions.last?.id {
                                Divider().padding(.leading, AetherVisual.s4)
                            }
                        }
                    }
                    .aetherPanel()
                }
                .frame(maxHeight: 300)

                VStack(spacing: 0) {
                    OverrideFormRow(AppLocalization.string("Node selection")) {
                        AetherSegmentedPicker(
                            selection: $mode,
                            options: ProxySelectionMode.allCases.map { .init(value: $0, title: $0.localizedTitle) },
                            accessibilityLabel: AppLocalization.string("Node selection")
                        )
                        .fixedSize()
                    }
                    Divider().padding(.leading, AetherVisual.s4)
                    OverrideFormRow(AppLocalization.string("Show in")) {
                        Picker(AppLocalization.string("Show in"), selection: $parentGroup) {
                            Text(AppLocalization.string("No other group")).tag("")
                            ForEach(parentOptions, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .fixedSize()
                        .accessibilityIdentifier("region-groups-parent")
                    }
                }
                .aetherPanel()
            }

            if saveFailed, let message = tunnel.profileMessage {
                AetherInlineMessage(text: message)
            }

            HStack(spacing: AetherVisual.s2) {
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
                    .aetherButton()
                    .keyboardShortcut(.cancelAction)
                Button {
                    create()
                } label: {
                    AetherProgressButtonLabel(
                        String.localizedStringWithFormat(AppLocalization.string("Create %lld groups"), Int64(selectedRegions.count)),
                        isWorking: isSaving
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedRegions.isEmpty || isSaving)
                .accessibilityIdentifier("region-groups-create")
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .disabled(isSaving)
        .onAppear {
            // Every region with a free name starts chosen.
            chosen = Set(regions.filter { !takenNames.contains(Self.groupName(for: $0)) }.map(\.code))
        }
        // A container's identifier would otherwise replace every child's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("region-groups-sheet")
    }

    private var selectedRegions: [ProfileOverrideSuggestions.Region] {
        regions.filter { chosen.contains($0.code) && !takenNames.contains(Self.groupName(for: $0)) }
    }

    private func create() {
        var overrides = tunnel.activeProfileOverrides
        // Listed in the parent in region order, after any earlier groups.
        for region in selectedRegions {
            overrides.groups.append(CustomProxyGroup(
                name: Self.groupName(for: region),
                regions: [region.code],
                mode: mode,
                parentGroup: parentGroup.isEmpty ? nil : parentGroup,
                position: .bottom
            ))
        }
        isSaving = true
        saveFailed = false
        Task {
            let saved = await tunnel.setProfileOverrides(overrides)
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }
}

// MARK: - Hidden nodes

struct HiddenNodesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    @State private var keywords: [String] = []
    @State private var draft = ""
    @State private var isSaving = false
    @State private var saveFailed = false

    private var nodes: [String] { tunnel.activeProfileNodeNames }

    private var hidden: [String] {
        let lowered = keywords.map { $0.lowercased() }
        return nodes.filter { node in lowered.contains { node.lowercased().contains($0) } }
    }

    private var suggestions: [String] {
        ProfileOverrideSuggestions.noticeKeywords(in: nodes).filter { !keywords.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "eye.slash",
                title: AppLocalization.string("Hide nodes"),
                subtitle: AppLocalization.string("Nodes whose names contain these words leave every group. The subscription itself is not changed."),
                tint: AppSection.proxies.tileColor
            )

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                HStack(spacing: AetherVisual.s2) {
                    TextField(AppLocalization.string("Add a word, e.g. Expire"), text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addDraft)
                        .accessibilityLabel(AppLocalization.string("Hide nodes"))
                        .accessibilityIdentifier("hidden-nodes-field")
                    Button(AppLocalization.string("Add"), action: addDraft)
                        .aetherButton()
                        .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !keywords.isEmpty {
                    AetherFlowLayout(spacing: AetherVisual.s1) {
                        ForEach(keywords, id: \.self) { keyword in
                            KeywordChip(title: keyword, systemImage: "xmark") {
                                keywords.removeAll { $0 == keyword }
                            }
                        }
                    }
                }
                if !suggestions.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Found in this profile:"))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                        AetherFlowLayout(spacing: AetherVisual.s1) {
                            ForEach(suggestions, id: \.self) { keyword in
                                KeywordChip(title: keyword, systemImage: "plus") {
                                    keywords.append(keyword)
                                }
                            }
                        }
                    }
                }
            }
            .padding(AetherVisual.s4)
            .aetherPanel()

            if hidden.isEmpty {
                Text(keywords.isEmpty
                     ? AppLocalization.string("No node is hidden.")
                     : AppLocalization.string("No node name contains these words."))
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .padding(.horizontal, AetherVisual.sectionHeaderInset)
            } else {
                MemberPreviewList(
                    caption: String.localizedStringWithFormat(AppLocalization.string("%lld nodes hidden"), Int64(hidden.count)),
                    members: hidden
                )
            }

            if saveFailed, let message = tunnel.profileMessage {
                AetherInlineMessage(text: message)
            }

            HStack(spacing: AetherVisual.s2) {
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
                    .aetherButton()
                    .keyboardShortcut(.cancelAction)
                Button {
                    save()
                } label: {
                    AetherProgressButtonLabel(AppLocalization.string("Save"), isWorking: isSaving)
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving || keywords == tunnel.activeProfileOverrides.hiddenNodeKeywords)
                .accessibilityIdentifier("hidden-nodes-save")
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .disabled(isSaving)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: keywords)
        .onAppear { keywords = tunnel.activeProfileOverrides.hiddenNodeKeywords }
        // A container's identifier would otherwise replace every child's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("hidden-nodes-sheet")
    }

    private func addDraft() {
        for word in CustomProxyGroupSheet.keywords(draft) where !keywords.contains(word) {
            keywords.append(word)
        }
        draft = ""
    }

    private func save() {
        var overrides = tunnel.activeProfileOverrides
        overrides.hiddenNodeKeywords = keywords
        isSaving = true
        saveFailed = false
        Task {
            let saved = await tunnel.setProfileOverrides(overrides)
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }
}

// MARK: - Chained proxy

struct ChainedProxySheet: View {
    enum LandingMode: String, CaseIterable, Hashable {
        case customNode
        case existingNode
    }

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    let initial: ChainedProxyOverride?

    @State private var name: String
    @State private var dialerProxy: String
    @State private var landingMode: LandingMode
    @State private var existingNodeName: String
    @State private var customNode: AetherNode
    @State private var portText: String
    @State private var parentGroup: String
    @State private var position: CustomProxyGroup.Position
    @State private var showsFullNodeEditor = false
    @State private var pasteFeedback: (message: String, isError: Bool)?
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var requestsCancel = false
    @State private var confirmsDelete = false

    private static let noParent = ""

    init(initial: ChainedProxyOverride? = nil, defaultParent: String? = nil) {
        self.initial = initial
        _name = State(initialValue: initial?.name ?? "")
        _dialerProxy = State(initialValue: initial?.dialerProxy ?? "")
        _parentGroup = State(
            initialValue: initial.map { $0.parentGroup ?? Self.noParent } ?? defaultParent ?? Self.noParent
        )
        _position = State(initialValue: initial?.position ?? .top)

        switch initial?.target {
        case let .existingNode(targetName):
            _landingMode = State(initialValue: .existingNode)
            _existingNodeName = State(initialValue: targetName)
            let seed = Self.defaultCustomNode()
            _customNode = State(initialValue: seed)
            _portText = State(initialValue: String(seed.port))
        case let .customNode(node):
            _landingMode = State(initialValue: .customNode)
            _existingNodeName = State(initialValue: "")
            _customNode = State(initialValue: node)
            _portText = State(initialValue: String(node.port))
        case nil:
            _landingMode = State(initialValue: .customNode)
            _existingNodeName = State(initialValue: "")
            let seed = Self.defaultCustomNode()
            _customNode = State(initialValue: seed)
            _portText = State(initialValue: String(seed.port))
        }
    }

    private static func defaultCustomNode() -> AetherNode {
        AetherNode(
            name: "Landing Node",
            protocolID: .socks5,
            server: "",
            port: 1080,
            tls: .init(enabled: false)
        )
    }

    private var syncedCustomNode: AetherNode {
        var copy = customNode
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmedName.isEmpty ? "Landing Node" : trimmedName
        copy.server = copy.server.trimmingCharacters(in: .whitespacesAndNewlines)
        if let parsedPort = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), parsedPort > 0 {
            copy.port = parsedPort
        } else {
            copy.port = 0
        }
        copy.dialerProxy = nil
        return copy
    }

    private var candidate: ChainedProxyOverride {
        let target: ChainedProxyOverride.Target = switch landingMode {
        case .customNode:
            .customNode(syncedCustomNode)
        case .existingNode:
            .existingNode(name: existingNodeName)
        }
        return ChainedProxyOverride(
            id: initial?.id ?? UUID(),
            name: name,
            dialerProxy: dialerProxy,
            target: target,
            parentGroup: parentGroup == Self.noParent ? nil : parentGroup,
            position: position
        )
    }

    private var proposed: Result<ProfileOverride, Error> {
        Result {
            if landingMode == .customNode {
                guard let parsedPort = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)), parsedPort > 0 else {
                    throw ProfileOverrideError.invalidChainedProxy
                }
                _ = parsedPort
            }
            var overrides = tunnel.activeProfileOverrides
            let item = try candidate.validated()
            if let initial, let index = overrides.chainedProxies.firstIndex(where: { $0.id == initial.id }) {
                overrides.chainedProxies[index] = item
            } else {
                overrides.chainedProxies.append(item)
            }
            return try overrides.validated()
        }
    }

    private var diagnosticsForCandidate: [ProfileOverrideDiagnostic] {
        guard case let .success(overrides) = proposed,
              let result = tunnel.activeOverrideResult(overrides) else { return [] }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.diagnostics.filter { diagnostic in
            switch diagnostic {
            case let .nameConflict(group):
                return group == trimmed
            case let .dialerProxyMissing(chainedProxy, _),
                 let .targetNodeMissing(chainedProxy, _):
                return chainedProxy == trimmed
            case .parentGroupMissing, .noMatchingNodes, .groupNotEditable, .unsupportedProfileLayout:
                return false
            }
        }
    }

    private var profileGroups: [String] {
        (tunnel.activeProfileSummary?.proxyGroups ?? [])
            .map(\.name)
            .filter { $0 != parentGroup }
    }

    private var profileNodes: [String] {
        let editingName = initial?.name
        return (tunnel.activeProfileSummary?.proxies ?? [])
            .map(\.name)
            .filter { $0 != editingName }
    }

    private var parentOptions: [String] {
        let custom = Set(tunnel.activeProfileOverrides.groups.map(\.name))
        return (tunnel.activeProfileSummary?.proxyGroups ?? [])
            .filter { $0.strategy.caseInsensitiveCompare("select") == .orderedSame && !custom.contains($0.name) }
            .map(\.name)
    }

    private var hasChanges: Bool {
        guard let initial else {
            return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !customNode.server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return candidate != initial
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "link.badge.plus",
                title: initial == nil
                    ? AppLocalization.string("New chained proxy")
                    : AppLocalization.string("Edit chained proxy"),
                subtitle: AppLocalization.string("Route traffic through a first-hop proxy or group before reaching the landing node, while keeping your subscription untouched."),
                tint: AppSection.proxies.tileColor
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AetherVisual.s4) {
                    chainDiagramCard
                    firstHopSection
                    secondHopSection
                    placementSection
                    statusSection
                }
            }
            .frame(
                minHeight: AetherVisual.sheetFormMinHeight,
                idealHeight: AetherVisual.sheetFormIdealHeight,
                maxHeight: AetherVisual.sheetFormMaxHeight
            )

            if saveFailed, let message = tunnel.profileMessage {
                AetherInlineMessage(text: message)
            }

            footer
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: landingMode)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: parentGroup)
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
        .onAppear(perform: seedDefaultSelectionsIfNeeded)
        .sheet(isPresented: $showsFullNodeEditor) {
            ManualNodeEditorSheet(
                initialNode: syncedCustomNode,
                save: { updated in
                    customNode = updated
                    portText = String(updated.port)
                    if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                       updated.name != "Landing Node" {
                        name = updated.name
                    }
                    return true
                }
            )
            .environmentObject(tunnel)
        }
        .confirmationDialog(
            String.localizedStringWithFormat(
                AppLocalization.string("Delete the chained proxy %@?"),
                initial?.name ?? ""
            ),
            isPresented: $confirmsDelete
        ) {
            Button(AppLocalization.string("Delete Chained Proxy"), role: .destructive) { delete() }
                .accessibilityIdentifier("chained-proxy-confirm-delete")
        } message: {
            Text(AppLocalization.string("Groups that list it no longer do. The subscription itself is not changed."))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("chained-proxy-sheet")
    }

    private var chainDiagramCard: some View {
        HStack(spacing: AetherVisual.s3) {
            chainHopStep(
                symbol: "laptopcomputer",
                tint: .secondary,
                label: AppLocalization.string("This Mac"),
                value: AppLocalization.string("Local apps")
            )
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AetherVisual.tertiaryText)
                .accessibilityHidden(true)
            chainHopStep(
                symbol: "bolt.horizontal.fill",
                tint: AppSection.proxies.tileColor,
                label: AppLocalization.string("First hop (entry)"),
                value: dialerProxy.isEmpty ? "—" : dialerProxy
            )
            Image(systemName: "arrow.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(AetherVisual.tertiaryText)
                .accessibilityHidden(true)
            chainHopStep(
                symbol: "globe",
                tint: AetherVisual.manualNodesTint,
                label: AppLocalization.string("Second hop (landing)"),
                value: secondHopSummary
            )
        }
        .padding(AetherVisual.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherPanel()
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("chained-proxy-flow-diagram")
    }

    private func chainHopStep(
        symbol: String,
        tint: Color,
        label: String,
        value: String
    ) -> some View {
        HStack(spacing: AetherVisual.s2) {
            AetherIconTile(symbol: symbol, color: tint, size: AetherVisual.rowTileSize)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(verbatim: label)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                Text(verbatim: value)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var secondHopSummary: String {
        switch landingMode {
        case .customNode:
            let host = customNode.server.trimmingCharacters(in: .whitespacesAndNewlines)
            if host.isEmpty {
                return customNode.protocolID.displayName
            }
            return "\(customNode.protocolID.displayName) · \(host)"
        case .existingNode:
            return existingNodeName.isEmpty ? "—" : existingNodeName
        }
    }

    private var firstHopSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Step 1 · First hop (entry proxy)"))
            VStack(spacing: 0) {
                OverrideFormRow(AppLocalization.string("Dial through")) {
                    Picker(AppLocalization.string("Dial through"), selection: $dialerProxy) {
                        if !profileGroups.isEmpty {
                            Section(AppLocalization.string("Proxy groups")) {
                                ForEach(profileGroups, id: \.self) { groupName in
                                    Text(verbatim: groupName).tag(groupName)
                                }
                            }
                        }
                        if !profileNodes.isEmpty {
                            Section(AppLocalization.string("Nodes")) {
                                ForEach(profileNodes, id: \.self) { nodeName in
                                    Text(verbatim: nodeName).tag(nodeName)
                                }
                            }
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 280, alignment: .trailing)
                    .accessibilityIdentifier("chained-proxy-dialer-picker")
                }
            }
            .aetherPanel()
        }
    }

    private var secondHopSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Step 2 · Second hop (landing node)"))
            VStack(spacing: 0) {
                OverrideFormRow(AppLocalization.string("Landing source")) {
                    AetherSegmentedPicker(
                        selection: $landingMode,
                        options: [
                            .init(value: .customNode, title: AppLocalization.string("External node")),
                            .init(value: .existingNode, title: AppLocalization.string("Node in profile")),
                        ],
                        accessibilityLabel: AppLocalization.string("Landing source"),
                        accessibilityIdentifier: "chained-proxy-landing-mode"
                    )
                    .fixedSize()
                }
                Divider().padding(.leading, AetherVisual.s4)

                switch landingMode {
                case .customNode:
                    customLandingFields
                case .existingNode:
                    OverrideFormRow(AppLocalization.string("Target node")) {
                        Picker(AppLocalization.string("Target node"), selection: $existingNodeName) {
                            ForEach(profileNodes, id: \.self) { nodeName in
                                Text(verbatim: nodeName).tag(nodeName)
                            }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 280, alignment: .trailing)
                        .accessibilityIdentifier("chained-proxy-existing-node-picker")
                    }
                }
            }
            .aetherPanel()

            if let pasteFeedback {
                if pasteFeedback.isError {
                    AetherInlineMessage(
                        text: pasteFeedback.message,
                        kind: .warning,
                        isCompact: true
                    )
                    .padding(.horizontal, AetherVisual.sectionHeaderInset)
                } else {
                    Label(pasteFeedback.message, systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AetherReadableTint(color: .green))
                        .padding(.horizontal, AetherVisual.sectionHeaderInset)
                }
            }
        }
    }

    @ViewBuilder
    private var customLandingFields: some View {
        OverrideFormRow(AppLocalization.string("Protocol")) {
            Picker(
                AppLocalization.string("Protocol"),
                selection: Binding(
                    get: { customNode.protocolID },
                    set: { newProtocol in
                        guard customNode.protocolID != newProtocol else { return }
                        customNode.protocolID = newProtocol
                        applyProtocolDefaults(for: newProtocol)
                    }
                )
            ) {
                ForEach(AetherNodeProtocol.allCases, id: \.self) { protocolID in
                    Text(verbatim: protocolID.displayName).tag(protocolID)
                }
            }
            .labelsHidden()
            .fixedSize()
            .accessibilityIdentifier("chained-proxy-protocol-picker")
        }
        Divider().padding(.leading, AetherVisual.s4)
        OverrideFormRow(AppLocalization.string("Server")) {
            TextField(AppLocalization.string("Host or IP address"), text: $customNode.server)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .accessibilityLabel(AppLocalization.string("Server"))
                .accessibilityIdentifier("chained-proxy-server-field")
        }
        Divider().padding(.leading, AetherVisual.s4)
        OverrideFormRow(AppLocalization.string("Port")) {
            TextField(AppLocalization.string("Port"), text: $portText)
                .textFieldStyle(.plain)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .accessibilityLabel(AppLocalization.string("Port"))
                .accessibilityIdentifier("chained-proxy-port-field")
        }
        Divider().padding(.leading, AetherVisual.s4)
        quickCredentialsRows
        Divider().padding(.leading, AetherVisual.s4)
        HStack(spacing: AetherVisual.s2) {
            Button {
                pasteShareLinkFromClipboard()
            } label: {
                Label(AppLocalization.string("Paste Node Link"), systemImage: "doc.on.clipboard")
            }
            .aetherButton()
            .controlSize(.small)
            .accessibilityIdentifier("chained-proxy-paste-link")

            Spacer(minLength: AetherVisual.s2)

            Button {
                showsFullNodeEditor = true
            } label: {
                Label(AppLocalization.string("TLS & Transport…"), systemImage: "slider.horizontal.3")
            }
            .aetherButton()
            .controlSize(.small)
            .accessibilityIdentifier("chained-proxy-advanced-editor")
        }
        .padding(.horizontal, AetherVisual.s4)
        .frame(minHeight: AetherVisual.compactRowHeight)
    }

    @ViewBuilder
    private var quickCredentialsRows: some View {
        switch customNode.protocolID {
        case .http, .socks5:
            OverrideFormRow(AppLocalization.string("Username (optional)")) {
                TextField(AppLocalization.string("Username (optional)"), text: $customNode.username)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Username (optional)"))
                    .accessibilityIdentifier("chained-proxy-username-field")
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Password (optional)")) {
                SecureField(AppLocalization.string("Password (optional)"), text: $customNode.password)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Password (optional)"))
                    .accessibilityIdentifier("chained-proxy-password-field")
            }
        case .vmess, .vless:
            OverrideFormRow(AppLocalization.string("UUID")) {
                TextField(AppLocalization.string("UUID"), text: $customNode.uuid)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("UUID"))
                    .accessibilityIdentifier("chained-proxy-uuid-field")
            }
        case .shadowsocks, .shadowsocksR:
            OverrideFormRow(AppLocalization.string("Cipher")) {
                TextField(AppLocalization.string("Cipher"), text: $customNode.cipher)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Cipher"))
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Password")) {
                SecureField(AppLocalization.string("Password"), text: $customNode.password)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Password"))
            }
        case .trojan, .hysteria, .hysteria2, .anyTLS, .snell:
            OverrideFormRow(AppLocalization.string("Password")) {
                SecureField(AppLocalization.string("Password"), text: $customNode.password)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Password"))
                    .accessibilityIdentifier("chained-proxy-password-field")
            }
        case .tuic:
            OverrideFormRow(AppLocalization.string("UUID")) {
                TextField(AppLocalization.string("UUID"), text: $customNode.uuid)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("UUID"))
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Password")) {
                SecureField(AppLocalization.string("Password"), text: $customNode.password)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Password"))
            }
        case .mieru, .ssh:
            OverrideFormRow(AppLocalization.string("Username")) {
                TextField(AppLocalization.string("Username"), text: $customNode.username)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Username"))
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Password")) {
                SecureField(AppLocalization.string("Password"), text: $customNode.password)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Password"))
            }
        case .wireGuard:
            OverrideFormRow(AppLocalization.string("Peer public key")) {
                TextField(AppLocalization.string("Peer public key"), text: $customNode.publicKey)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Peer public key"))
            }
        case .shadowQUIC:
            OverrideFormRow(AppLocalization.string("Username")) {
                TextField(AppLocalization.string("Username"), text: $customNode.username)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Username"))
            }
            Divider().padding(.leading, AetherVisual.s4)
            OverrideFormRow(AppLocalization.string("Password")) {
                SecureField(AppLocalization.string("Password"), text: $customNode.password)
                    .textFieldStyle(.plain)
                    .multilineTextAlignment(.trailing)
                    .accessibilityLabel(AppLocalization.string("Password"))
            }
        }
    }

    private var placementSection: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("Name & group placement"))
            VStack(spacing: 0) {
                OverrideFormRow(AppLocalization.string("Name")) {
                    TextField(AppLocalization.string("e.g. 🇺🇸 US Static Residential"), text: $name)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.trailing)
                        .accessibilityLabel(AppLocalization.string("Name"))
                        .accessibilityIdentifier("chained-proxy-name-field")
                }
                Divider().padding(.leading, AetherVisual.s4)
                OverrideFormRow(AppLocalization.string("Show in")) {
                    Picker(AppLocalization.string("Show in"), selection: $parentGroup) {
                        Text(AppLocalization.string("No other group")).tag(Self.noParent)
                        ForEach(parentOptions, id: \.self) { Text(verbatim: $0).tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("chained-proxy-parent")
                }
                if parentGroup != Self.noParent {
                    Divider().padding(.leading, AetherVisual.s4)
                    OverrideFormRow(AppLocalization.string("Position")) {
                        AetherSegmentedPicker(
                            selection: $position,
                            options: [
                                .init(value: .top, title: AppLocalization.string("First")),
                                .init(value: .bottom, title: AppLocalization.string("Last")),
                            ],
                            accessibilityLabel: AppLocalization.string("Position")
                        )
                        .fixedSize()
                    }
                    .transition(.opacity)
                }
            }
            .aetherPanel()
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        switch proposed {
        case let .failure(error) where hasChanges:
            AetherInlineMessage(text: error.overrideMessage, kind: .warning, isCompact: true)
                .padding(.horizontal, AetherVisual.sectionHeaderInset)
        case .failure:
            EmptyView()
        case .success:
            if diagnosticsForCandidate.contains(where: {
                if case .nameConflict = $0 { return true }
                return false
            }) {
                AetherInlineMessage(
                    text: AppLocalization.string("A node or group in this profile already has this name."),
                    kind: .warning,
                    isCompact: true
                )
                .padding(.horizontal, AetherVisual.sectionHeaderInset)
            } else if diagnosticsForCandidate.contains(where: {
                if case .dialerProxyMissing = $0 { return true }
                if case .targetNodeMissing = $0 { return true }
                return false
            }) {
                AetherInlineMessage(
                    text: AppLocalization.string("The chosen first-hop or target node is not in the current profile."),
                    kind: .warning,
                    isCompact: true
                )
                .padding(.horizontal, AetherVisual.sectionHeaderInset)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: AetherVisual.s2) {
            if initial != nil {
                Button(AppLocalization.string("Delete Chained Proxy"), role: .destructive) {
                    confirmsDelete = true
                }
                .aetherButton()
                .accessibilityIdentifier("chained-proxy-delete")
            }
            Spacer()
            Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                .aetherButton()
                .keyboardShortcut(.cancelAction)
            Button {
                save()
            } label: {
                AetherProgressButtonLabel(AppLocalization.string("Save"), isWorking: isSaving)
            }
            .aetherButton(prominent: true)
            .keyboardShortcut(.defaultAction)
            .disabled(!canSave)
            .accessibilityIdentifier("chained-proxy-save")
        }
        .controlSize(.large)
    }

    private var canSave: Bool {
        guard case .success = proposed else { return false }
        let hasConflict = diagnosticsForCandidate.contains {
            if case .nameConflict = $0 { return true }
            return false
        }
        return !hasConflict && hasChanges
    }

    private func seedDefaultSelectionsIfNeeded() {
        if dialerProxy.isEmpty {
            dialerProxy = profileGroups.first ?? profileNodes.first ?? ""
        }
        if existingNodeName.isEmpty {
            existingNodeName = profileNodes.first { $0 != dialerProxy } ?? profileNodes.first ?? ""
        }
    }

    private func applyProtocolDefaults(for protocolID: AetherNodeProtocol) {
        customNode.transport.kind = .tcp
        switch protocolID {
        case .http:
            customNode.tls.enabled = false
            portText = "8080"
        case .socks5:
            customNode.tls.enabled = false
            portText = "1080"
        case .shadowsocks:
            customNode.tls.enabled = false
            customNode.cipher = customNode.cipher.isEmpty ? "aes-128-gcm" : customNode.cipher
            portText = "8388"
        case .shadowsocksR:
            customNode.tls.enabled = false
            customNode.cipher = customNode.cipher.isEmpty ? "aes-256-cfb" : customNode.cipher
            customNode.ssrProtocol = customNode.ssrProtocol.isEmpty ? "origin" : customNode.ssrProtocol
            customNode.ssrObfs = customNode.ssrObfs.isEmpty ? "plain" : customNode.ssrObfs
            portText = "8388"
        case .snell:
            customNode.tls.enabled = false
            customNode.snellVersion = customNode.snellVersion ?? 4
            portText = "6160"
        case .mieru:
            customNode.tls.enabled = false
            customNode.mieruTransport = customNode.mieruTransport.isEmpty ? "TCP" : customNode.mieruTransport
            portText = "8443"
        case .ssh:
            customNode.tls.enabled = false
            portText = "22"
        case .wireGuard:
            customNode.tls.enabled = false
            portText = "51820"
        default:
            customNode.tls.enabled = [
                .vmess, .vless, .trojan, .hysteria, .hysteria2, .tuic, .anyTLS, .shadowQUIC,
            ].contains(protocolID)
            portText = "443"
        }
    }

    private func pasteShareLinkFromClipboard() {
        guard let raw = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            pasteFeedback = (
                AppLocalization.string("Clipboard is empty. Copy a vless://, ss://, hy2:// or socks5:// link first."),
                true
            )
            return
        }
        do {
            let parsed = try SubscriptionPayloadNormalizer.nodes(fromShareText: raw)
            guard let first = parsed.nodes.first else {
                pasteFeedback = (
                    AppLocalization.string("No valid node link was found in the clipboard."),
                    true
                )
                return
            }
            var imported = first
            imported.dialerProxy = nil
            customNode = imported
            portText = String(imported.port)
            if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                name = imported.name
            }
            pasteFeedback = (
                String.localizedStringWithFormat(
                    AppLocalization.string("Filled %@ (%@:%lld) from clipboard."),
                    imported.protocolID.displayName,
                    imported.server,
                    Int64(imported.port)
                ),
                false
            )
        } catch {
            pasteFeedback = (
                AppLocalization.string("No valid node link was found in the clipboard."),
                true
            )
        }
    }

    private func save() {
        guard case let .success(overrides) = proposed else { return }
        isSaving = true
        saveFailed = false
        Task {
            let saved = await tunnel.setProfileOverrides(overrides)
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }

    private func delete() {
        guard let initial else { return }
        var overrides = tunnel.activeProfileOverrides
        overrides.chainedProxies.removeAll { $0.id == initial.id }
        isSaving = true
        Task {
            let saved = await tunnel.setProfileOverrides(overrides)
            isSaving = false
            if saved { dismiss() } else { saveFailed = true }
        }
    }
}

// MARK: - Shared pieces

/// A grouped-card row: the name leading, the control trailing.
private struct OverrideFormRow<Control: View>: View {
    let title: String
    let control: Control

    init(_ title: String, @ViewBuilder control: () -> Control) {
        self.title = title
        self.control = control()
    }

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Text(title)
                .foregroundStyle(.primary)
                .fixedSize()
            Spacer(minLength: AetherVisual.s3)
            control
        }
        .padding(.horizontal, AetherVisual.s4)
        .frame(minHeight: AetherVisual.compactRowHeight)
    }
}

private struct RegionChip: View {
    let region: ProfileOverrideSuggestions.Region
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AetherVisual.sMicro) {
                if !region.displayFlag.isEmpty {
                    Text(verbatim: region.displayFlag)
                }
                Text(AppLocalization.regionName(region.code))
                Text(verbatim: "\(region.nodeCount)")
                    .foregroundStyle(AetherVisual.secondaryText)
                    .monospacedDigit()
            }
            .font(.callout)
            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
            .padding(.vertical, AetherVisual.pillVerticalPadding)
            .background(
                isSelected ? AetherVisual.tintFill(.accentColor) : AetherVisual.neutralFill,
                in: Capsule()
            )
            .overlay {
                Capsule().stroke(isSelected ? AetherVisual.tintBorder(.accentColor) : .clear, lineWidth: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.aetherPressable)
        .accessibilityLabel(AppLocalization.regionName(region.code))
        .accessibilityValue(isSelected ? AppLocalization.string("On") : AppLocalization.string("Off"))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityIdentifier("region-chip-\(region.code)")
    }
}

private struct KeywordChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AetherVisual.sMicro) {
                Text(verbatim: title)
                Image(systemName: systemImage)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            .font(.callout)
            .padding(.horizontal, AetherVisual.pillHorizontalPadding)
            .padding(.vertical, AetherVisual.pillVerticalPadding)
            .background(AetherVisual.neutralFill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.aetherPressable)
        .accessibilityLabel(title)
    }
}

/// Up to a screenful of names with a count above them.
private struct MemberPreviewList: View {
    let caption: String
    let members: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(caption)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, AetherVisual.sectionHeaderInset)
                .accessibilityIdentifier("override-preview-count")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(members.enumerated()), id: \.offset) { _, member in
                        HStack(spacing: AetherVisual.s2) {
                            AetherRegionCode(name: member)
                            Text(verbatim: member)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, AetherVisual.s3)
                        .frame(minHeight: AetherVisual.tableRowHeight)
                    }
                }
            }
            .frame(maxHeight: 180)
            .padding(AetherVisual.listCardInset)
            .aetherPanel()
        }
    }
}

/// Every node with a checkbox and a search field.
private struct NodeChecklist: View {
    let nodes: [String]
    @Binding var selection: [String]
    @State private var search = ""

    private var filtered: [String] {
        search.isEmpty ? nodes : nodes.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSearchField(text: $search, prompt: AppLocalization.string("Search nodes"), accessibilityIdentifier: "node-checklist-search")
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { node in
                        Toggle(isOn: Binding(
                            get: { selection.contains(node) },
                            set: { isOn in
                                if isOn { selection.append(node) } else { selection.removeAll { $0 == node } }
                            }
                        )) {
                            Text(verbatim: node).lineLimit(1).truncationMode(.middle)
                        }
                        .toggleStyle(.checkbox)
                        .frame(minHeight: AetherVisual.tableRowHeight)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(AetherVisual.s3)
        .frame(width: 320)
        // A container's identifier would otherwise replace every child's.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("node-checklist")
    }
}

extension ProfileOverrideError {
    /// The message in the app's language (the kit's own text is English).
    var localizedMessage: String {
        switch self {
        case .unsupportedFormat:
            AppLocalization.string("These customizations were saved by a newer version of AetherRoute.")
        case .tooManyGroups:
            String.localizedStringWithFormat(AppLocalization.string("A profile can have at most %lld custom groups."), Int64(ProfileOverride.maximumGroupCount))
        case .tooManyKeywords:
            String.localizedStringWithFormat(AppLocalization.string("Use at most %lld keywords."), Int64(ProfileOverride.maximumKeywordCount))
        case .tooManyNodes:
            String.localizedStringWithFormat(AppLocalization.string("Pick at most %lld nodes."), Int64(ProfileOverride.maximumManualNodeCount))
        case .invalidKeyword:
            AppLocalization.string("A keyword is too long or contains control characters.")
        case .invalidGroupName:
            AppLocalization.string("Enter a name without quotes or backslashes that is not DIRECT, REJECT or GLOBAL.")
        case let .duplicateGroupName(name):
            String.localizedStringWithFormat(AppLocalization.string("Another custom group is already named %@."), name)
        case .groupHasNoSource:
            AppLocalization.string("Choose regions, keywords or nodes for the group.")
        case .tooManyChainedProxies:
            String.localizedStringWithFormat(
                AppLocalization.string("A profile can have at most %lld chained proxies."),
                Int64(ProfileOverride.maximumChainedProxyCount)
            )
        case .invalidChainedProxy:
            AppLocalization.string("Choose a valid first-hop dialer proxy and landing node.")
        case .chainedProxyCycle:
            AppLocalization.string("The first-hop and second-hop proxies cannot form a loop.")
        }
    }
}

extension Error {
    /// Override errors in the app's language, anything else as it reports.
    var overrideMessage: String {
        (self as? ProfileOverrideError)?.localizedMessage ?? localizedDescription
    }
}

extension ProfileOverrideSuggestions.Region {
    /// The flag to draw, or nothing where macOS draws a placeholder box
    /// instead of the flag (Taiwan, on Macs set to mainland China).
    var displayFlag: String {
        code == "TW" ? "" : flag
    }
}

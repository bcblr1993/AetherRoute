import SwiftUI
import AetherRouteKit

struct NativeProfileEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    let profile: ManagedProfile
    @State private var nodes: [AetherNode]
    @State private var nodeToEdit: AetherNode?
    @State private var isAddingNode = false
    @State private var isSaving = false
    @State private var saveErrorMessage: String?
    @State private var requestsCancel = false
    @State private var removedNodeStack: [(index: Int, node: AetherNode)] = []

    init(profile: ManagedProfile) {
        self.profile = profile
        _nodes = State(initialValue: profile.profile.nativeNodes ?? [])
    }

    private var hasChanges: Bool {
        nodes != (profile.profile.nativeNodes ?? [])
    }

    private var canModify: Bool {
        tunnel.canModifyProfile(id: profile.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            nodeList
            Divider()
            footer
        }
        .aetherLargeSheetFrame()
        .disabled(isSaving)
        .onAppear {
            tunnel.clearProfileMessage()
        }
        .onChange(of: nodes) { _, _ in
            saveErrorMessage = nil
        }
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
        .sheet(isPresented: $isAddingNode) {
            ManualNodeEditorSheet(saveResult: append, dialerCandidates: nodes.map(\.name))
                .environmentObject(tunnel)
        }
        .sheet(item: $nodeToEdit) { node in
            ManualNodeEditorSheet(
                initialNode: node,
                saveResult: replace,
                dialerCandidates: nodes.filter { $0.id != node.id }.map(\.name)
            )
            .environmentObject(tunnel)
        }
    }

    private var header: some View {
        AetherSheetHeader(
            symbol: "point.3.connected.trianglepath.dotted",
            title: AppLocalization.string("Edit Native Profile"),
            subtitle: profile.profile.name,
            tint: AetherVisual.manualNodesTint
        ) {
            Button(AppLocalization.string("Add Node"), systemImage: "plus") {
                isAddingNode = true
            }
            .aetherButton()
            .disabled(
                !canModify
                    || nodes.count >= AetherNodeProfileCompiler.maximumNodes
            )
            .help(
                !canModify
                    ? (tunnel.profileEditLockReason ?? AppLocalization.string("Stop the secure connection before changing profiles."))
                    : AppLocalization.string("Add Node")
            )
        }
        .padding(AetherVisual.dialogPadding)
    }

    @ViewBuilder
    private var nodeList: some View {
        if nodes.isEmpty {
            ContentUnavailableView {
                Label(AppLocalization.string("No Nodes"), systemImage: "point.3.connected.trianglepath.dotted")
            } description: {
                Text(AppLocalization.string("Add a node to route traffic through this profile."))
            } actions: {
                Button(AppLocalization.string("Add Node")) { isAddingNode = true }
                    .disabled(!canModify)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            populatedNodeList
        }
    }

    private var populatedNodeList: some View {
        List {
            ForEach(nodes) { node in
                HStack(spacing: AetherVisual.s4) {
                    Image(systemName: "line.3.horizontal")
                        .foregroundStyle(AetherVisual.tertiaryText)
                        .help(AppLocalization.string("Drag to reorder"))
                        .accessibilityHidden(true)

                    AetherMonogramTile(
                        text: String(node.protocolID.displayName.prefix(1)),
                        color: AetherVisual.manualNodesTint
                    )

                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(node.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(verbatim: nodeSubtitle(for: node))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: AetherVisual.s3)

                    Button {
                        nodeToEdit = node
                    } label: {
                        AetherRowIconLabel(symbol: "pencil", tint: .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canModify)
                    .help(
                        !canModify
                            ? (tunnel.profileEditLockReason ?? AppLocalization.string("Stop the secure connection before changing profiles."))
                            : AppLocalization.string("Edit Node")
                    )
                    .accessibilityLabel(AppLocalization.string("Edit Node"))

                    Button(role: .destructive) {
                        removeNode(id: node.id)
                    } label: {
                        AetherRowIconLabel(symbol: "trash", tint: .red)
                    }
                    .buttonStyle(.plain)
                    .disabled(!tunnel.canModifyProfile(id: profile.id) || nodes.count <= 1)
                    .help(
                        !tunnel.canModifyProfile(id: profile.id)
                            ? (tunnel.profileEditLockReason ?? AppLocalization.string("Stop the secure connection before changing profiles."))
                            : (nodes.count <= 1
                                ? AppLocalization.string("A native profile must keep at least one node.")
                                : AppLocalization.string("Remove Node"))
                    )
                    .accessibilityLabel(AppLocalization.string("Remove Node"))
                }
                .padding(.vertical, AetherVisual.s2)
            }
            .onMove { offsets, destination in
                guard canModify else { return }
                nodes.move(fromOffsets: offsets, toOffset: destination)
            }
            .moveDisabled(!canModify)
        }
        .listStyle(.inset)
        .accessibilityIdentifier("native-profile-node-list")
    }

    private func removeNode(id: AetherNode.ID) {
        guard canModify,
              nodes.count > 1,
              let matchedIndex = nodes.firstIndex(where: { $0.id == id }) else {
            return
        }
        let removed = nodes.remove(at: matchedIndex)
        removedNodeStack.append((index: matchedIndex, node: removed))
    }

    private var footer: some View {
        let currentValidationMessage = validationMessage
        return VStack(alignment: .leading, spacing: AetherVisual.s3) {
            if !canModify {
                AetherInlineMessage(
                    text: tunnel.profileEditLockReason ?? AppLocalization.string("Stop the secure connection before changing profiles."),
                    kind: .warning,
                    systemImage: "lock"
                )
            }
            if let currentValidationMessage {
                AetherInlineMessage(text: currentValidationMessage, kind: .warning)
            } else {
                Label(
                    AppLocalization.format(
                        "%lld native nodes · encrypted on this Mac",
                        Int64(nodes.count)
                    ),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
            }

            if !removedNodeStack.isEmpty {
                Button(AppLocalization.string("Undo removal")) {
                    guard canModify, let entry = removedNodeStack.popLast() else { return }
                    nodes.insert(entry.node, at: min(entry.index, nodes.count))
                }
                .aetherButton()
                .disabled(!canModify)
                .accessibilityIdentifier("native-profile-undo-removal")
            }
            if let saveErrorMessage {
                AetherInlineMessage(text: saveErrorMessage)
            }
            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .aetherButton()
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    guard hasChanges else {
                        dismiss()
                        return
                    }
                    isSaving = true
                    saveErrorMessage = nil
                    tunnel.clearProfileMessage()
                    Task {
                        let didSave = await tunnel.updateNativeProfile(
                            id: profile.id,
                            nodes: nodes
                        )
                        isSaving = false
                        if didSave {
                            dismiss()
                        } else {
                            saveErrorMessage = tunnel.profileMessage
                                ?? AppLocalization.string("Could not save the profile. Try again.")
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Save Profile"),
                        isWorking: isSaving
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    currentValidationMessage != nil
                        || !canModify
                        || tunnel.isUpdatingProfiles
                        || isSaving
                )
                .accessibilityIdentifier("save-native-profile")
            }
        }
        .padding(AetherVisual.dialogPadding)
    }

    private var validationMessage: String? {
        do {
            _ = try AetherNodeProfileCompiler.compile(nodes: nodes)
            // Nodes may be added in any order, so a dialer can name a node
            // added later; the profile as a whole must resolve before Save.
            try AetherNodeProfileCompiler.validateDialerProxies(in: nodes)
            return nil
        } catch let error as AetherNodeProfileCompilerError {
            return error.localizedAppDescription
        } catch {
            return error.localizedDescription
        }
    }

    private func append(_ node: AetherNode) -> Result<Void, Error> {
        let candidate = nodes + [node]
        do {
            _ = try AetherNodeProfileCompiler.compile(nodes: candidate)
            nodes = candidate
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func replace(_ node: AetherNode) -> Result<Void, Error> {
        guard nodes.contains(where: { $0.id == node.id }) else {
            return .failure(AetherNodeProfileCompilerError.emptyProfile)
        }
        let candidate = AetherNode.replacing(node, in: nodes)
        do {
            _ = try AetherNodeProfileCompiler.compile(nodes: candidate)
            nodes = candidate
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private func nodeSubtitle(for node: AetherNode) -> String {
        let base = "\(node.protocolID.displayName) · \(node.transportDisplayName) · \(node.server):\(node.port)"
        guard let rawDialer = node.dialerProxy else { return base }
        let dialer = rawDialer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dialer.isEmpty else { return base }
        let via = AppLocalization.format("via %@", dialer)
        return "\(base) · \(via)"
    }
}

extension AetherNodeProfileCompilerError {
    /// The kit keeps English error text; the app shows it in the chosen
    /// language.
    var localizedAppDescription: String {
        switch self {
        case .emptyProfile:
            AppLocalization.string("Add at least one node.")
        case let .tooManyNodes(limit):
            AppLocalization.format(
                "A native profile supports at most %lld nodes.",
                Int64(limit)
            )
        case .duplicateName:
            AppLocalization.string("Node names must be unique.")
        case .reservedName:
            AppLocalization.string("A node name conflicts with a reserved routing name.")
        case let .unknownDialerProxy(node, dialer):
            AppLocalization.format(
                "%@ dials through %@, which is not another node of this profile.",
                node,
                dialer
            )
        }
    }
}

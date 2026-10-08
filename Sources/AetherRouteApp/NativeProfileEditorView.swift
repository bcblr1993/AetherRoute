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
    @State private var requestsCancel = false
    @State private var removedNode: (index: Int, node: AetherNode)?

    init(profile: ManagedProfile) {
        self.profile = profile
        _nodes = State(initialValue: profile.profile.nativeNodes ?? [])
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
        .modifier(DiscardChangesModifier(isDirty: nodes != (profile.profile.nativeNodes ?? []), isSaving: isSaving, requested: $requestsCancel))
        .sheet(isPresented: $isAddingNode) {
            ManualNodeEditorSheet(save: append)
                .environmentObject(tunnel)
        }
        .sheet(item: $nodeToEdit) { node in
            ManualNodeEditorSheet(initialNode: node, save: replace)
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
            .aetherGlassButton()
            .disabled(
                !tunnel.canModifyProfile(id: profile.id)
                    || nodes.count >= AetherNodeProfileCompiler.maximumNodes
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
                    .disabled(!tunnel.canModifyProfile(id: profile.id))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            populatedNodeList
        }
    }

    private var populatedNodeList: some View {
        List {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
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
                        Text(
                            verbatim: "\(node.protocolID.displayName) · \(node.server):\(node.port)"
                        )
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .lineLimit(1)
                    }

                    Spacer(minLength: AetherVisual.s3)

                    Button(AppLocalization.string("Edit"), systemImage: "pencil") {
                        nodeToEdit = node
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel(AppLocalization.string("Edit Node"))

                    Button(AppLocalization.string("Remove"), systemImage: "trash", role: .destructive) {
                        removedNode = (index, nodes[index])
                        nodes.remove(at: index)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(nodes.count == 1)
                    .help(AppLocalization.string("A native profile must keep at least one node."))
                    .accessibilityLabel(AppLocalization.string("Remove Node"))
                }
                .padding(.vertical, AetherVisual.s2)
            }
            .onMove { offsets, destination in
                nodes.move(fromOffsets: offsets, toOffset: destination)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("native-profile-node-list")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            if let validationMessage {
                AetherInlineMessage(text: validationMessage, kind: .warning)
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

            if let removedNode {
                Button(AppLocalization.string("Undo removal")) {
                    nodes.insert(removedNode.node, at: min(removedNode.index, nodes.count))
                    self.removedNode = nil
                }
            }
            if let message = tunnel.profileMessage, tunnel.profileMessageIsError {
                AetherInlineMessage(text: message)
            }
            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    isSaving = true
                    Task {
                        let didSave = await tunnel.updateNativeProfile(
                            id: profile.id,
                            nodes: nodes
                        )
                        isSaving = false
                        if didSave { dismiss() }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Save Profile"),
                        isWorking: isSaving
                    )
                }
                .aetherGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    validationMessage != nil
                        || !tunnel.canModifyProfile(id: profile.id)
                        || tunnel.isUpdatingProfiles
                        || isSaving
                )
                .accessibilityIdentifier("save-native-profile")
            }
        }
        .padding(AetherVisual.s5)
    }

    private var validationMessage: String? {
        do {
            _ = try AetherNodeProfileCompiler.compile(nodes: nodes)
            return nil
        } catch let error as AetherNodeProfileCompilerError {
            return error.localizedAppDescription
        } catch {
            return error.localizedDescription
        }
    }

    private func append(_ node: AetherNode) -> Bool {
        let candidate = nodes + [node]
        guard (try? AetherNodeProfileCompiler.compile(nodes: candidate)) != nil else {
            return false
        }
        nodes = candidate
        return true
    }

    private func replace(_ node: AetherNode) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else {
            return false
        }
        var candidate = nodes
        candidate[index] = node
        guard (try? AetherNodeProfileCompiler.compile(nodes: candidate)) != nil else {
            return false
        }
        nodes = candidate
        return true
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
            String.localizedStringWithFormat(
                AppLocalization.string("A native profile supports at most %lld nodes."),
                Int64(limit)
            )
        case .duplicateName:
            AppLocalization.string("Node names must be unique.")
        case .reservedName:
            AppLocalization.string("A node name conflicts with a reserved routing name.")
        }
    }
}

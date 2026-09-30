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
        .frame(
            minWidth: 560,
            idealWidth: 680,
            maxWidth: 900,
            minHeight: 480,
            idealHeight: 600,
            maxHeight: 760
        )
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: nodes != (profile.profile.nativeNodes ?? []), isSaving: isSaving, requested: $requestsCancel))
        .background(Color(nsColor: .windowBackgroundColor))
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
            subtitle: profile.profile.name
        ) {
            Button(AppLocalization.string("Add Node"), systemImage: "plus") {
                isAddingNode = true
            }
            .buttonStyle(.bordered)
            .disabled(
                !tunnel.canModifyProfile(id: profile.id)
                    || nodes.count >= AetherNodeProfileCompiler.maximumNodes
            )
        }
        .padding(AetherVisual.s6)
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
                        .foregroundStyle(.tertiary)
                        .help(AppLocalization.string("Drag to reorder"))
                        .accessibilityHidden(true)

                    Text(node.protocolID.displayName.prefix(1))
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.accentColor, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(node.name)
                            .font(.body.weight(.medium))
                            .lineLimit(1)
                        Text(
                            verbatim: "\(node.protocolID.displayName) · \(node.server):\(node.port)"
                        )
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
                Label(
                    validationMessage,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else {
                Label(
                    String.localizedStringWithFormat(
                        AppLocalization.string("%lld native nodes · encrypted on this Mac"),
                        Int64(nodes.count)
                    ),
                    systemImage: "lock.fill"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if let removedNode {
                Button(AppLocalization.string("Undo removal")) {
                    nodes.insert(removedNode.node, at: min(removedNode.index, nodes.count))
                    self.removedNode = nil
                }
            }
            if let message = tunnel.profileMessage, tunnel.profileMessageIsError {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
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
                .buttonStyle(.borderedProminent)
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

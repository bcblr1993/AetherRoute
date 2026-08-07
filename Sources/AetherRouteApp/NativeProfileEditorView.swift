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
            minWidth: 640,
            idealWidth: 680,
            maxWidth: 720,
            minHeight: 480,
            idealHeight: 600,
            maxHeight: 760
        )
        .background(AetherContentCanvas())
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
        HStack(spacing: 14) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(AetherVisual.blue)
                .frame(width: 50, height: 50)
                .background(
                    AetherVisual.blue.opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 13, style: .continuous)
                )
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Edit Native Profile")
                    .font(.title3.weight(.semibold))
                Text(profile.profile.name)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Add Node", systemImage: "plus") {
                isAddingNode = true
            }
            .buttonStyle(.bordered)
            .disabled(
                !tunnel.canModifyProfiles
                    || nodes.count >= AetherNodeProfileCompiler.maximumNodes
            )
        }
        .padding(22)
    }

    private var nodeList: some View {
        List {
            ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                HStack(spacing: 14) {
                    Text(node.protocolID.displayName.prefix(1))
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(AetherVisual.blue, in: Circle())
                        .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 3) {
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

                    Spacer(minLength: 12)

                    Button {
                        moveNode(at: index, offset: -1)
                    } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(index == nodes.startIndex)
                    .accessibilityLabel("Move Node Up")

                    Button {
                        moveNode(at: index, offset: 1)
                    } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(index == nodes.index(before: nodes.endIndex))
                    .accessibilityLabel("Move Node Down")

                    Button("Edit", systemImage: "pencil") {
                        nodeToEdit = node
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .accessibilityLabel("Edit Node")

                    Button("Remove", systemImage: "trash", role: .destructive) {
                        nodes.remove(at: index)
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .disabled(nodes.count == 1)
                    .help("A native profile must keep at least one node.")
                    .accessibilityLabel("Remove Node")
                }
                .padding(.vertical, 7)
            }
        }
        .listStyle(.inset)
        .accessibilityIdentifier("native-profile-node-list")
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
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

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
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
                        "Save Profile",
                        isWorking: isSaving
                    )
                }
                .aetherPrimaryActionStyle()
                .keyboardShortcut(.defaultAction)
                .disabled(
                    validationMessage != nil
                        || !tunnel.canModifyProfiles
                        || tunnel.isUpdatingProfiles
                        || isSaving
                )
                .accessibilityIdentifier("save-native-profile")
            }
        }
        .padding(18)
    }

    private var validationMessage: String? {
        do {
            _ = try AetherNodeProfileCompiler.compile(nodes: nodes)
            return nil
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

    private func moveNode(at index: Int, offset: Int) {
        let destination = index + offset
        guard nodes.indices.contains(index), nodes.indices.contains(destination) else {
            return
        }
        nodes.swapAt(index, destination)
    }
}

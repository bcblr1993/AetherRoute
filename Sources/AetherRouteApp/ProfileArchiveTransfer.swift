import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let aetherRouteProfileArchive = UTType(
        exportedAs: AppConstants.profileArchiveTypeIdentifier,
        conformingTo: .data
    )
}

struct ProfileArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.aetherRouteProfileArchive]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

enum ProfileArchivePasswordMode: Equatable {
    case export
    case `import`

    var title: LocalizedStringKey {
        switch self {
        case .export: "Export Profile Archive"
        case .import: "Import Profile Archive"
        }
    }

    var detail: LocalizedStringKey {
        switch self {
        case .export:
            "Create a password-encrypted copy of every profile for another Mac. The password is never stored."
        case .import:
            "Enter the archive password. Existing profiles stay in place and the profile currently in use will not change."
        }
    }

    var actionTitle: LocalizedStringKey {
        switch self {
        case .export: "Export Archive"
        case .import: "Import Archive"
        }
    }
}

struct ProfileArchivePasswordSheet: View {
    @Environment(\.dismiss) private var dismiss
    let mode: ProfileArchivePasswordMode
    let perform: (String) async -> Bool

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s6) {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 25, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 48, height: 48)
                    .background(
                        Color.teal.opacity(0.09),
                        in: RoundedRectangle(
                            cornerRadius: AetherVisual.insetRadius,
                            style: .continuous
                        )
                    )
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    Text(mode.title)
                        .font(.title2.weight(.semibold))
                    Text(mode.detail)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                SecureField("Archive password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("archive-password-field")
                if mode == .export {
                    SecureField("Confirm password", text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier(
                            "archive-password-confirmation-field"
                        )
                }
                Text(
                    String.localizedStringWithFormat(
                        AppLocalization.string("Use at least %lld characters. AetherRoute cannot recover this password."),
                        Int64(
                            PortableProfileArchiveCodec
                                .minimumPasswordCharacters
                        )
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Spacer()
                Button {
                    isWorking = true
                    Task {
                        if await perform(password) {
                            dismiss()
                        } else {
                            isWorking = false
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        mode.actionTitle,
                        isWorking: isWorking
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 500)
    }

    private var canSubmit: Bool {
        let longEnough = password.count >=
            PortableProfileArchiveCodec.minimumPasswordCharacters
        return longEnough && (mode == .import || password == confirmation)
    }
}

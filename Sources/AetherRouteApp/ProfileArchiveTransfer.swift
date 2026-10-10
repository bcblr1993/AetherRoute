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

    var title: String {
        switch self {
        case .export: AppLocalization.string("Export Profile Archive")
        case .import: AppLocalization.string("Import Profile Archive")
        }
    }

    var detail: String {
        switch self {
        case .export:
            AppLocalization.string("Create a password-encrypted copy of every profile for another Mac. The password is never stored.")
        case .import:
            AppLocalization.string("Enter the archive password. Existing profiles stay in place and the profile currently in use will not change.")
        }
    }

    var actionTitle: String {
        switch self {
        case .export: AppLocalization.string("Export Archive")
        case .import: AppLocalization.string("Import Archive")
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
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "lock.shield.fill",
                title: mode.title,
                subtitle: mode.detail,
                tint: AppSection.profiles.tileColor
            )

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                SecureField(AppLocalization.string("Archive password"), text: $password)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("archive-password-field")
                if mode == .export {
                    SecureField(AppLocalization.string("Confirm password"), text: $confirmation)
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
                .foregroundStyle(AetherVisual.secondaryText)
            }

            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
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
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(!canSubmit || isWorking)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(isWorking)
    }

    private var canSubmit: Bool {
        let longEnough = password.count >=
            PortableProfileArchiveCodec.minimumPasswordCharacters
        return longEnough && (mode == .import || password == confirmation)
    }
}

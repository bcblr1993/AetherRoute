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

    var defaultFailureMessage: String {
        switch self {
        case .export:
            AppLocalization.string("Could not create the encrypted archive. Check your profiles and try again.")
        case .import:
            AppLocalization.string("Could not unlock the profile archive. Check the password and try again.")
        }
    }
}

struct ProfileArchivePasswordSheet: View {
    private enum FocusField: Hashable {
        case password
        case confirmation
    }

    @Environment(\.dismiss) private var dismiss
    let mode: ProfileArchivePasswordMode
    let failureMessage: (() -> String?)?
    let perform: (String) async -> Bool

    @State private var password = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var errorMessage: String?
    @FocusState private var focusedField: FocusField?

    init(
        mode: ProfileArchivePasswordMode,
        failureMessage: (() -> String?)? = nil,
        perform: @escaping (String) async -> Bool
    ) {
        self.mode = mode
        self.failureMessage = failureMessage
        self.perform = perform
    }

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
                    .focused($focusedField, equals: .password)
                    .disabled(isWorking)
                    .onSubmit {
                        if mode == .export {
                            focusedField = .confirmation
                        } else if canSubmit && !isWorking {
                            submit()
                        }
                    }
                    .accessibilityIdentifier("archive-password-field")
                if mode == .export {
                    SecureField(AppLocalization.string("Confirm password"), text: $confirmation)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .confirmation)
                        .disabled(isWorking)
                        .onSubmit {
                            if canSubmit && !isWorking {
                                submit()
                            }
                        }
                        .accessibilityIdentifier(
                            "archive-password-confirmation-field"
                        )
                    if passwordsMismatch {
                        Label(
                            AppLocalization.string("Passwords do not match"),
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(AetherReadableTint(color: .orange))
                        .accessibilityIdentifier("archive-password-mismatch")
                    }
                }
                Text(
                    AppLocalization.format(
                        "Use at least %lld characters. AetherRoute cannot recover this password.",
                        Int64(
                            PortableProfileArchiveCodec
                                .minimumPasswordCharacters
                        )
                    )
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)

                if let errorMessage {
                    AetherInlineMessage(text: errorMessage)
                        .accessibilityIdentifier("archive-password-error")
                }
            }

            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isWorking)
                Button {
                    submit()
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
        .onAppear {
            focusedField = .password
        }
        .onChange(of: password) { _, _ in
            errorMessage = nil
        }
        .onChange(of: confirmation) { _, _ in
            errorMessage = nil
        }
    }

    private func submit() {
        guard canSubmit, !isWorking else { return }
        errorMessage = nil
        isWorking = true
        Task {
            if await perform(password) {
                dismiss()
            } else {
                isWorking = false
                errorMessage = failureMessage?() ?? mode.defaultFailureMessage
            }
        }
    }

    private var passwordsMismatch: Bool {
        mode == .export && !confirmation.isEmpty && password != confirmation
    }

    private var canSubmit: Bool {
        let longEnough = password.count >=
            PortableProfileArchiveCodec.minimumPasswordCharacters
        return longEnough && (mode == .import || password == confirmation)
    }
}

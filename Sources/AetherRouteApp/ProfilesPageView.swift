import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

struct EmptyProfileOnboardingCard: View {
    let onAddSubscription: () -> Void
    let onImportProfile: () -> Void
    var onCloudSync: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s4) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sparkles")
                        .font(.title.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 48, height: 48)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Welcome to AetherRoute"))
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)

                    Text(AppLocalization.string("Import a subscription URL or configuration file to get started with high-speed, secure routing."))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack(spacing: AetherVisual.s3) {
                Button {
                    onAddSubscription()
                } label: {
                    HStack(spacing: AetherVisual.sCompact) {
                        Image(systemName: "link.badge.plus")
                            .font(.body.weight(.semibold))
                        Text(AppLocalization.string("Add Subscription…"))
                            .font(.body.weight(.semibold))
                    }
                    .padding(.horizontal, AetherVisual.s1)
                }
                .aetherGlassButton(prominent: true)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-add-subscription-button")

                Button {
                    onImportProfile()
                } label: {
                    HStack(spacing: AetherVisual.sCompact) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.body.weight(.medium))
                        Text(AppLocalization.string("Import Profile…"))
                            .font(.body.weight(.medium))
                    }
                }
                .aetherGlassButton()
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-import-profile-button")

                if let onCloudSync {
                    Button {
                        onCloudSync()
                    } label: {
                        HStack(spacing: AetherVisual.sCompact) {
                            Image(systemName: "icloud")
                                .font(.body.weight(.medium))
                            Text(AppLocalization.string("iCloud Sync…"))
                                .font(.body.weight(.medium))
                        }
                    }
                    .aetherGlassButton()
                    .controlSize(.large)
                    .accessibilityIdentifier("onboarding-icloud-sync-button")
                }

                Spacer()
            }

            Divider().opacity(0.35)

            HStack(spacing: AetherVisual.s2) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(AppLocalization.string("Supports Clash YAML/Meta, V2Ray/Base64 share links (VMess, VLESS, Trojan, SS, Hysteria2), automatic latency testing, and smart rule routing."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(AetherVisual.s5)
        .aetherPanel()
        .accessibilityIdentifier("empty-profile-onboarding-card")
    }
}

struct ExternalSubscriptionConfirmationSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    let request: ExternalSubscriptionImportRequest
    @State private var isConfirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "link.badge.plus",
                title: AppLocalization.string("Review Subscription Link"),
                subtitle: AppLocalization.string("AetherRoute has not downloaded or changed anything yet.")
            )

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text("Address")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Label(request.providerHost, systemImage: "lock.fill")
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("external-subscription-host")
                Text("AetherRoute will not access this address until you confirm.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(AetherVisual.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                Color.secondary.opacity(0.06),
                in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
            )

            Label(
                "If you continue, AetherRoute will make one HTTPS request, validate the size and contents, store the subscription in encrypted profile storage, and activate it.",
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            if !tunnel.canImportOrAddProfileRegardlessOfPrivacy {
                Label(
                    AppLocalization.string("Wait for current profile operations to finish before importing."),
                    systemImage: "hourglass"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            } else if tunnel.isEnabled {
                Label(
                    AppLocalization.string("The subscription will be downloaded and safely added to your profile library without interrupting your connection."),
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            } else if !tunnel.hasAcceptedPrivacyDisclosure {
                Label(
                    AppLocalization.string("Confirming will accept the network privacy review and activate this subscription."),
                    systemImage: "checkmark.shield"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }

            if tunnel.profileMessageIsError,
               let message = tunnel.profileMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) {
                    tunnel.cancelExternalSubscriptionImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button {
                    isConfirming = true
                    Task {
                        if await tunnel.confirmExternalSubscriptionImport(
                            id: request.id
                        ) {
                            dismiss()
                        } else {
                            isConfirming = false
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string(tunnel.isEnabled ? "Download and Save" : "Download and Enable"),
                        isWorking: isConfirming
                            || tunnel.isRefreshingSubscription
                    )
                }
                .aetherGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !tunnel.canImportOrAddProfileRegardlessOfPrivacy
                        || isConfirming
                        || tunnel.isRefreshingSubscription
                )
                .accessibilityIdentifier("confirm-external-subscription")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: AetherVisual.sheetIdealWidth)
        .interactiveDismissDisabled(isConfirming)
    }
}

struct ProfilesView: View {
    private enum FileImporterKind {
        case profile
        case portableArchive

        var allowedContentTypes: [UTType] {
            switch self {
            case .profile:
                [.plainText, .data]
            case .portableArchive:
                [.aetherRouteProfileArchive, .data]
            }
        }
    }

    @EnvironmentObject private var tunnel: TunnelManager
    @State private var fileImporterKind: FileImporterKind = .profile
    /// Removal deletes the profile's encrypted data, so it asks first.
    @State private var profileToRemove: ManagedProfile?
    /// A file dragged over the page that can be dropped to import it.
    @State private var isDropTargeted = false
    @State private var isFileImporterPresented = false
    @State private var isManualNodeEditorPresented = false
    @State private var isSubscriptionEditorPresented = false
    @State private var subscriptionURL = ""
    @State private var searchText = ""
    @State private var profileToRename: ManagedProfile?
    @State private var nativeProfileToEdit: ManagedProfile?
    @State private var isArchivePasswordPresented = false
    @State private var isArchiveExporterPresented = false
    @State private var isExportPasswordPresented = false
    @State private var isCloudSyncSheetPresented = false
    @State private var archiveImportURL: URL?
    @State private var pendingArchiveData: Data?
    @State private var archiveDocument = ProfileArchiveDocument()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                pageHeader

                // A short library is faster to scan than to search.
                if tunnel.profiles.count > Self.searchThreshold {
                    AetherSearchField(
                        text: $searchText,
                        prompt: AppLocalization.string("Search profiles"),
                        accessibilityIdentifier: "profiles-search-field"
                    )
                }

                if let message = tunnel.profileMessage, !tunnel.isImportingProfile {
                    profileMessageBanner(message: message, isError: tunnel.profileMessageIsError)
                        .transition(AetherVisual.insertion)
                }

                if tunnel.isImportingProfile {
                    importProgressCard
                }

                if tunnel.profiles.isEmpty {
                    emptyOnboardingSection
                    supportedFormatsCard
                } else {
                    profileLibraryCard
                }
            }
            .aetherPageContent(.wide)
            .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.profileMessage)
        }
        .dropDestination(for: URL.self) { urls, _ in
            importDroppedFile(urls)
        } isTargeted: { targeted in
            withAnimation(AetherVisual.animation(AetherVisual.quickFade)) {
                isDropTargeted = targeted && tunnel.canImportOrAddProfile
            }
        }
        .overlay {
            if isDropTargeted {
                // Says where the file goes before it is let go.
                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(
                        Color.accentColor.opacity(0.06),
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    )
                    .overlay {
                        Label(AppLocalization.string("Drop to import the profile"), systemImage: "square.and.arrow.down")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                    .padding(AetherVisual.s3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .confirmationDialog(
            String.localizedStringWithFormat(
                AppLocalization.string("Remove “%@”?"),
                profileToRemove?.profile.name ?? ""
            ),
            isPresented: Binding(
                get: { profileToRemove != nil },
                set: { if !$0 { profileToRemove = nil } }
            ),
            titleVisibility: .visible,
            presenting: profileToRemove
        ) { managed in
            Button(AppLocalization.string("Remove"), role: .destructive) {
                Task { await tunnel.removeProfile(id: managed.id) }
            }
            .accessibilityIdentifier("confirm-remove-profile")
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: { _ in
            Text(AppLocalization.string("The profile and its encrypted nodes are deleted from this Mac. This cannot be undone."))
        }
        .fileImporter(
            isPresented: $isFileImporterPresented,
            allowedContentTypes: fileImporterKind.allowedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            handleFileImport(result, kind: fileImporterKind)
        }
        .fileExporter(
            isPresented: $isArchiveExporterPresented,
            document: archiveDocument,
            contentType: .aetherRouteProfileArchive,
            defaultFilename: "AetherRoute-Profiles"
        ) { result in
            switch result {
            case .success:
                tunnel.reportPortableArchiveSaved()
            case let .failure(error):
                tunnel.reportProfileImportError(error)
            }
        }
        .sheet(isPresented: $isSubscriptionEditorPresented) {
            SubscriptionEditorSheet(urlText: $subscriptionURL)
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $isManualNodeEditorPresented) {
            ManualNodeEditorSheet()
                .environmentObject(tunnel)
        }
        .sheet(isPresented: $isCloudSyncSheetPresented) {
            ProfileCloudSyncSheet()
                .environmentObject(tunnel)
        }
        .sheet(item: $profileToRename) { managed in
            ProfileRenameSheet(profile: managed) { name in
                await tunnel.renameProfile(id: managed.id, name: name)
            }
        }
        .sheet(item: $nativeProfileToEdit) { managed in
            NativeProfileEditorSheet(profile: managed)
                .environmentObject(tunnel)
        }
        .sheet(
            isPresented: $isExportPasswordPresented,
            onDismiss: presentPendingArchiveExporter
        ) {
            ProfileArchivePasswordSheet(mode: .export) { password in
                guard let data = await tunnel.makePortableArchive(
                    password: password
                ) else {
                    return false
                }
                pendingArchiveData = data
                return true
            }
        }
        .sheet(isPresented: $isArchivePasswordPresented) {
            ProfileArchivePasswordSheet(mode: .import) { password in
                guard let archiveImportURL else { return false }
                let imported = await tunnel.importPortableArchive(
                    from: archiveImportURL,
                    password: password
                )
                if imported { self.archiveImportURL = nil }
                return imported
            }
        }
        .accessibilityIdentifier("profiles-page")
#if DEBUG
        .task {
            // Isolated screenshot review only: open one sheet on launch.
            switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_SHEET"] {
            case "subscription": isSubscriptionEditorPresented = true
            case "manual-node": isManualNodeEditorPresented = true
            case "export": isExportPasswordPresented = true
            case "cloud": isCloudSyncSheetPresented = true
            case "rename": profileToRename = tunnel.profiles.first
            case "profile-editor": nativeProfileToEdit = tunnel.profiles.first
            default: break
            }
        }
#endif
    }

    /// One "Add" menu for every way a profile arrives, as in Apple's own
    /// apps; archives and sync sit in the overflow menu beside it.
    private var pageHeader: some View {
        AetherPageHeader(.profiles) {
            Menu {
                Button("Add Subscription…", systemImage: "link.badge.plus") {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    isSubscriptionEditorPresented = true
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .accessibilityIdentifier("add-subscription")

                Button("Import Profile…", systemImage: "square.and.arrow.down") {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .accessibilityIdentifier("import-profile")

                Button("Add Node…", systemImage: "plus.circle") {
                    tunnel.clearProfileMessage()
                    isManualNodeEditorPresented = true
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .accessibilityIdentifier("add-manual-node")
            } label: {
                Label(AppLocalization.string("Add"), systemImage: "plus")
            }
            .menuIndicator(.visible)
            .aetherGlassButton(prominent: true)
            .fixedSize()
            .accessibilityIdentifier("profiles-add-menu")

            Menu {
                Button(AppLocalization.string("iCloud Sync…"), systemImage: "icloud") {
                    tunnel.clearProfileMessage()
                    isCloudSyncSheetPresented = true
                }
                .accessibilityIdentifier("profiles-icloud-sync-button")

                Divider()

                Button("Export Portable Archive…", systemImage: "square.and.arrow.up") {
                    tunnel.clearProfileMessage()
                    isExportPasswordPresented = true
                }
                .disabled(tunnel.profiles.isEmpty || tunnel.isTransferringProfiles)

                Button("Import Portable Archive…", systemImage: "square.and.arrow.down") {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.portableArchive)
                }
                .disabled(!tunnel.canModifyProfiles)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuIndicator(.hidden)
            .aetherGlassButton()
            .fixedSize()
            .accessibilityLabel(AppLocalization.string("More"))
            .accessibilityIdentifier("profiles-more-menu")
        }
    }

    private func profileMessageBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title3.weight(.medium))
                .foregroundStyle(isError ? Color.orange : Color.green)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: AetherVisual.s2)

            Button {
                tunnel.clearProfileMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .background(
            (isError ? Color.orange : Color.green).opacity(0.08),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                .stroke((isError ? Color.orange : Color.green).opacity(0.2), lineWidth: 0.5)
        }
    }

    private var importProgressCard: some View {
        HStack(spacing: AetherVisual.s3) {
            ProgressView()
                .controlSize(.small)
            Text("Importing profile…")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: AetherVisual.s2)
            Button("Cancel", role: .cancel) {
                tunnel.cancelProfileImport()
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s4)
        .aetherPanel()
        .accessibilityIdentifier("profile-import-progress")
    }

    private var emptyOnboardingSection: some View {
        VStack(spacing: AetherVisual.s5) {
            VStack(spacing: AetherVisual.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor.opacity(0.18), Color.accentColor.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "doc.badge.plus")
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 60, height: 60)
                .padding(.top, AetherVisual.s3)

                Text(AppLocalization.string("No Profiles Added"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Add a subscription link or import a Clash-compatible configuration to get started."))
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            HStack(spacing: AetherVisual.s4) {
                Button {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    isSubscriptionEditorPresented = true
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                Image(systemName: "link.badge.plus")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(AppLocalization.string("Add Subscription…"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(AppLocalization.string("Import HTTPS subscription URL from your provider."))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AetherVisual.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aetherGlass(
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous),
                        interactive: true
                    )
                }
                .buttonStyle(.aetherPressable)

                Button {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                Image(systemName: "square.and.arrow.down")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(AppLocalization.string("Import Profile…"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(AppLocalization.string("Supports Clash-compatible YAML/JSON profiles."))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AetherVisual.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aetherGlass(
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous),
                        interactive: true
                    )
                }
                .buttonStyle(.aetherPressable)

                Button {
                    tunnel.clearProfileMessage()
                    isCloudSyncSheetPresented = true
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.12))
                                Image(systemName: "icloud.fill")
                                    .font(.title2.weight(.semibold))
                                    .foregroundStyle(Color.accentColor)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        Text(AppLocalization.string("iCloud Sync…"))
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text(AppLocalization.string("Sync profiles from your iPhone or Mac."))
                            .font(.caption)
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(AetherVisual.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .aetherGlass(
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous),
                        interactive: true
                    )
                }
                .buttonStyle(.aetherPressable)
                .accessibilityIdentifier("onboarding-icloud-sync-card-button")
            }
            .padding(.horizontal, AetherVisual.s2)

            HStack(spacing: AetherVisual.s5) {
                Label(AppLocalization.string("Encrypted on this Mac"), systemImage: "lock.shield.fill")
                Label(AppLocalization.string("Clash Compatible"), systemImage: "checkmark.circle.fill")
                Label(AppLocalization.string("Multi-Protocol"), systemImage: "bolt.horizontal.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.bottom, AetherVisual.s2)
        }
        .padding(AetherVisual.s6)
        .aetherPanel()
    }


    private var filteredProfiles: [ManagedProfile] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return tunnel.profiles.filter {
            query.isEmpty || $0.profile.name.localizedCaseInsensitiveContains(query)
                || $0.profile.importedAt.formatted(date: .abbreviated, time: .omitted).localizedCaseInsensitiveContains(query)
        }
    }

    private static let searchThreshold = 2

    private var profileLibraryCard: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(AppLocalization.string("My profiles"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AetherVisual.s2)
                .accessibilityAddTraits(.isHeader)

            VStack(spacing: 0) {
                if filteredProfiles.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                        .padding(AetherVisual.s4)
                }
                ForEach(Array(filteredProfiles.enumerated()), id: \.element.id) { index, managed in
                    ManagedProfileRow(
                        managed: managed,
                        isActive: managed.id == tunnel.activeProfileID,
                        canActivate: tunnel.canActivateProfile,
                        canModify: tunnel.canModifyProfile(id: managed.id),
                        activate: {
                            Task { await tunnel.activateProfile(id: managed.id) }
                        },
                        rename: {
                            profileToRename = managed
                        },
                        editNative: managed.profile.nativeNodes == nil ? nil : { nativeProfileToEdit = managed },
                        remove: {
                            profileToRemove = managed
                        }
                    )
                    .transition(AetherVisual.insertion)

                    if index < filteredProfiles.count - 1 {
                        Divider()
                            .padding(.leading, AetherVisual.s4 + ManagedProfileRow.tileSize + AetherVisual.s3)
                    }
                }
            }
            .aetherPanel()

            Label(
                AppLocalization.string("Profiles and nodes are encrypted on this Mac. You can also drop a profile file onto this window to import it."),
                systemImage: "lock.fill"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, AetherVisual.s2)
            .padding(.top, AetherVisual.s1)
        }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: filteredProfiles.map(\.id))
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: tunnel.activeProfileID)
    }

    private var supportedFormatsCard: some View {
        HStack(spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.accentColor.opacity(0.12))
                Image(systemName: "doc.text.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.string("Supported formats"))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Supports Clash-compatible YAML/JSON profiles, HTTPS subscriptions, and common node links."))
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AetherVisual.s2)
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
    }

    private func presentFileImporter(_ kind: FileImporterKind) {
        fileImporterKind = kind
        isFileImporterPresented = true
    }

    private func handleFileImport(
        _ result: Result<[URL], any Error>,
        kind: FileImporterKind
    ) {
        switch (kind, result) {
        case let (.profile, .success(urls)):
            guard let url = urls.first else { return }
            tunnel.importProfile(from: url)
        case let (.portableArchive, .success(urls)):
            guard let url = urls.first else { return }
            archiveImportURL = url
            Task { @MainActor in
                await Task.yield()
                isArchivePasswordPresented = true
            }
        case let (_, .failure(error)):
            tunnel.reportProfileImportError(error)
        }
    }

    /// A profile or portable archive dropped on the page goes through the
    /// same import as the Import buttons.
    private func importDroppedFile(_ urls: [URL]) -> Bool {
        guard tunnel.canImportOrAddProfile,
              let url = urls.first, url.isFileURL else { return false }
        tunnel.clearProfileMessage()
        let isArchive = UTType(filenameExtension: url.pathExtension)?
            .conforms(to: .aetherRouteProfileArchive) == true
        handleFileImport(.success([url]), kind: isArchive ? .portableArchive : .profile)
        return true
    }

    private func presentPendingArchiveExporter() {
        guard let pendingArchiveData else { return }
        archiveDocument = ProfileArchiveDocument(data: pendingArchiveData)
        self.pendingArchiveData = nil
        isArchiveExporterPresented = true
    }
}

struct RoutingResourcesCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let importResource: (RoutingResourceKind) -> Void

    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                Image(systemName: resourcesAreReady ? "checkmark.shield" : "map")
                    .font(.title3)
                    .foregroundStyle(resourcesAreReady ? Color.green : Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Rule resources"))
                        .font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("routing-rules-summary")
                }
                Spacer(minLength: 0)

                if tunnel.isUpdatingRoutingResources {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Preparing routing rules…")
                } else if tunnel.routingResourceMessageIsError {
                    Button("Retry") {
                        Task { await tunnel.prepareRequiredRoutingResources() }
                    }
                    .aetherGlassButton()
                    .disabled(!tunnel.canModifyProfiles)
                    .help(editLockReason ?? "")
                    .accessibilityIdentifier("retry-routing-rules")
                }
            }

            Button {
                withAnimation(AetherVisual.animation(AetherVisual.disclosure)) {
                    showsAdvanced.toggle()
                }
            } label: {
                HStack(spacing: AetherVisual.s1) {
                    AetherDisclosureChevron(isExpanded: showsAdvanced)
                        .foregroundStyle(.primary)
                    Text("Advanced")
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("routing-rules-advanced")
            .accessibilityAddTraits(showsAdvanced ? .isSelected : [])

            if showsAdvanced {
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    ForEach(tunnel.requiredRoutingResources, id: \.self) { kind in
                        resourceRow(kind)
                    }

                    if let message = tunnel.routingResourceMessage {
                        Label(
                            message,
                            systemImage: tunnel.routingResourceMessageIsError
                                ? "exclamationmark.triangle.fill"
                                : "checkmark.circle.fill"
                        )
                        .font(.callout)
                        .foregroundStyle(
                            tunnel.routingResourceMessageIsError
                                ? Color.red : Color.secondary
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await tunnel.downloadRequiredRoutingResources() }
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Download & Verify"),
                            systemImage: "arrow.down.shield",
                            isWorking: tunnel.isUpdatingRoutingResources
                        )
                    }
                    .aetherGlassButton()
                    .disabled(
                        !tunnel.canModifyProfiles
                            || tunnel.isUpdatingRoutingResources
                    )
                    .help(editLockReason ?? "")

                    if let editLockReason {
                        Label(editLockReason, systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("routing-resources-lock-reason")
                    }

                    Text("Bundled rules use DB-IP Lite and V2Fly data. Country rule updates may use MaxMind data through Loyalsoldier. See Open-Source Software for sources and licenses.")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(AetherVisual.insertion)
            }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-resources-card")
    }

    /// A running download already shows progress; only explain a lock the
    /// person cannot see the cause of.
    private var editLockReason: String? {
        tunnel.isUpdatingRoutingResources ? nil : tunnel.profileEditLockReason
    }

    private var resourcesAreReady: Bool {
        tunnel.requiredRoutingResources.allSatisfy { kind in
            tunnel.routingResourceStatuses[kind]?.isUsableForConnection == true
        }
    }

    private var summary: String {
        if tunnel.isUpdatingRoutingResources {
            return AppLocalization.string("Preparing routing rules…")
        }
        if tunnel.routingResourceMessageIsError {
            return AppLocalization.string("Routing rules need attention. Try preparing them again.")
        }
        // "Ready" under a "Routing rules" heading repeated the heading; the
        // age of the data is the one fact worth showing once it is usable.
        if resourcesAreReady, let installedAt = oldestResourceInstallDate {
            return String.localizedStringWithFormat(
                AppLocalization.string("Verified · updated %@"),
                AppLocalization.date(installedAt, date: .abbreviated, time: .omitted)
            )
        }
        return AppLocalization.string(
            resourcesAreReady
                ? "Routing rules are ready."
                : "AetherRoute prepares routing rules automatically when you connect."
        )
    }

    private var oldestResourceInstallDate: Date? {
        tunnel.requiredRoutingResources.compactMap { kind -> Date? in
            switch tunnel.routingResourceStatuses[kind] {
            case let .ready(record)?, let .stale(record)?: record.installedAt
            default: nil
            }
        }.min()
    }

    private func resourceRow(_ kind: RoutingResourceKind) -> some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: resourceSymbol(kind))
                .font(.title2.weight(.semibold))
                .foregroundStyle(resourceColor(kind))
                .frame(width: 42, height: 42)
                .background(
                    resourceColor(kind).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
                )

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(kind.fileName)
                    .font(.body.weight(.medium))
                Text(resourceStatusTitle(kind))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s3)

            Button("Import…", systemImage: "square.and.arrow.down") {
                importResource(kind)
            }
            .aetherGlassButton()
            .controlSize(.small)
            .disabled(
                !tunnel.canModifyProfiles
                    || tunnel.isUpdatingRoutingResources
            )
            .help(editLockReason ?? "")
        }
        .padding(.horizontal, AetherVisual.s5)
        .padding(.vertical, AetherVisual.s3)
    }

    private func resourceStatusTitle(_ kind: RoutingResourceKind) -> String {
        guard let status = tunnel.routingResourceStatuses[kind] else {
            return AppLocalization.string("Checking…")
        }
        switch status {
        case .missing:
            return AppLocalization.string("Required · not installed")
        case let .ready(record):
            return String.localizedStringWithFormat(
                AppLocalization.string("Verified · updated %@"),
                AppLocalization.date(
                    record.installedAt,
                    date: .abbreviated,
                    time: .omitted
                )
            )
        case let .stale(record):
            return String.localizedStringWithFormat(
                AppLocalization.string(
                    status.isUsableForConnection
                        ? "Update recommended · %@"
                        : "Update required · %@"
                ),
                AppLocalization.date(
                    record.installedAt,
                    date: .abbreviated,
                    time: .omitted
                )
            )
        case .invalid:
            return AppLocalization.string("Invalid · replace before connecting")
        }
    }

    private func resourceColor(_ kind: RoutingResourceKind) -> Color {
        switch tunnel.routingResourceStatuses[kind] {
        case .ready?: .green
        case .stale?, .invalid?: .orange
        case .missing?, nil: .secondary
        }
    }

    private func resourceSymbol(_ kind: RoutingResourceKind) -> String {
        switch tunnel.routingResourceStatuses[kind] {
        case .ready?: "checkmark.shield.fill"
        case .stale?: "clock.badge.exclamationmark"
        case .invalid?: "exclamationmark.shield.fill"
        case .missing?, nil: "arrow.down.doc.fill"
        }
    }
}

/// A profile as a System Settings row: kind tile, name, details, and on the
/// trailing edge either "Current" or a Use button.
private struct ManagedProfileRow: View {
    static let tileSize: CGFloat = 34
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var isHovered = false
    @State private var inspectedNodeCount: Int?
    let managed: ManagedProfile
    let isActive: Bool
    let canActivate: Bool
    let canModify: Bool
    let activate: () -> Void
    let rename: () -> Void
    let editNative: (() -> Void)?
    let remove: () -> Void

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: iconName, color: iconTint, size: Self.tileSize)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(managed.profile.name)
                    .help(managed.profile.name)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: AetherVisual.s2)

            if isActive && isSubscription {
                Button {
                    Task { await tunnel.refreshSubscription() }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Check for Updates"),
                        systemImage: "arrow.clockwise",
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .aetherGlassButton()
                .controlSize(.small)
                .disabled(!canModify || tunnel.isRefreshingSubscription)
            }

            if isActive {
                Label(AppLocalization.string("Current profile"), systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityIdentifier("profile-current-\(managed.id.uuidString)")
            } else {
                Button(AppLocalization.string("Use")) {
                    activate()
                }
                .aetherGlassButton()
                .controlSize(.small)
                .disabled(!canActivate)
                .transition(.opacity)
                .accessibilityIdentifier("radio-select-\(managed.id.uuidString)")
            }

            Menu {
                if let editNative {
                    Button(action: editNative) {
                        Label(AppLocalization.string("Edit Nodes…"), systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .disabled(!canModify)
                }

                Button(action: rename) {
                    Label(AppLocalization.string("Rename…"), systemImage: "pencil")
                }
                .disabled(!canModify)

                if isSubscription {
                    Menu(AppLocalization.string("Auto Update")) {
                        Button(AppLocalization.string("Manual only")) {
                            Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: nil) }
                        }
                        Button(AppLocalization.string("Every 6 Hours")) {
                            Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: 6 * 3600) }
                        }
                        Button(AppLocalization.string("Every 12 Hours")) {
                            Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: 12 * 3600) }
                        }
                        Button(AppLocalization.string("Every 24 Hours")) {
                            Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: 24 * 3600) }
                        }
                    }
                    .disabled(!canModify)
                }

                if !isActive {
                    Divider()
                    Button(role: .destructive, action: remove) {
                        Label(AppLocalization.string("Remove Profile"), systemImage: "trash")
                    }
                    .disabled(!canModify)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 26, height: 26)
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .accessibilityLabel("Profile actions")
            .accessibilityIdentifier("profile-actions-\(managed.id.uuidString)")
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .frame(minHeight: 60)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        .onHover { isHovered = $0 }
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: isActive)
        .onTapGesture(count: 2) {
            if !isActive && canActivate {
                activate()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activate-profile-\(managed.id.uuidString)")
        .task(id: managed.profile.yaml) {
            // Parsed once per profile version, not on every visit: a large
            // profile took over 100 ms to inspect each time the page opened.
            let key = ProfileNodeCountCache.key(for: managed)
            if let cached = ProfileNodeCountCache.counts[key] {
                inspectedNodeCount = cached
                return
            }
            let yaml = managed.profile.yaml
            let count = await Task.detached(priority: .utility) {
                ProfileConfigurationInspector.inspect(yaml: yaml).proxyCount
            }.value
            guard !Task.isCancelled else { return }
            ProfileNodeCountCache.counts[key] = count
            inspectedNodeCount = count
        }
        .contextMenu {
            if !isActive {
                Button(action: activate) {
                    Label(AppLocalization.string("Use"), systemImage: "play.circle")
                }
                .disabled(!canActivate)
                Divider()
            }
            if let editNative {
                Button(action: editNative) {
                    Label(AppLocalization.string("Edit Nodes…"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(!canModify)
            }
            Button(action: rename) {
                Label(AppLocalization.string("Rename…"), systemImage: "pencil")
            }
            .disabled(!canModify)
            if !isActive {
                Divider()
                Button(role: .destructive, action: remove) {
                    Label(AppLocalization.string("Remove Profile"), systemImage: "trash")
                }
                .disabled(!canModify)
            }
        }
    }

    private var isSubscription: Bool {
        managed.profile.subscription != nil
    }

    private var iconName: String {
        if isSubscription {
            return "link"
        }
        if managed.profile.nativeNodes != nil {
            return "point.3.connected.trianglepath.dotted"
        }
        return "doc.text.fill"
    }

    /// One tile colour per kind of profile, like System Settings' rows.
    private var iconTint: Color {
        if isSubscription { return .teal }
        if managed.profile.nativeNodes != nil { return .indigo }
        return .orange
    }

    private var detail: String {
        let source = isSubscription
            ? AppLocalization.string("HTTPS subscription")
            : (managed.profile.nativeNodes != nil
                ? AppLocalization.string("Manual nodes")
                : AppLocalization.string("Local profile"))
        let importedAt = String.localizedStringWithFormat(
            AppLocalization.string("Imported %@"),
            AppLocalization.date(
                managed.profile.importedAt,
                date: .abbreviated,
                time: .omitted
            )
        )
        let updatedAt = managed.profile.subscription?.lastUpdatedAt
        let updateDetail = updatedAt.map {
            " · " + AppLocalization.string("Updated") + " "
                + AppLocalization.date($0, date: .abbreviated, time: .shortened)
        } ?? ""
        let count = managed.profile.nativeNodes?.count ?? inspectedNodeCount
        let nodeDetail = count.map { " · " + AppLocalization.format("%lld nodes", Int64($0)) } ?? ""
        return "\(source) · \(importedAt)\(nodeDetail)\(updateDetail)"
    }
}

private struct ProfileRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager
    let profile: ManagedProfile
    let save: (String) async -> Bool
    @State private var name: String
    @State private var isSaving = false
    @State private var saveFailed = false
    @State private var requestsCancel = false

    init(
        profile: ManagedProfile,
        save: @escaping (String) async -> Bool
    ) {
        self.profile = profile
        self.save = save
        _name = State(initialValue: profile.profile.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "pencil",
                title: AppLocalization.string("Rename Profile"),
                subtitle: AppLocalization.string("Choose a short name that is easy to recognize in the menu bar.")
            )

            TextField(AppLocalization.string("Profile name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-name-field")

            if saveFailed {
                Text(tunnel.profileMessage ?? AppLocalization.string("Could not save the profile. Try again."))
                    .foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Cancel", role: .cancel) { requestsCancel = true }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Button {
                    guard !isSaving else { return }
                    isSaving = true
                    saveFailed = false
                    Task {
                        defer { isSaving = false }
                        if await save(name) { dismiss() } else { saveFailed = true }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Save"),
                        isWorking: isSaving
                    )
                }
                .aetherGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSaving
                )
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(minWidth: AetherVisual.sheetMinWidth, idealWidth: AetherVisual.sheetIdealWidth, maxWidth: AetherVisual.sheetMaxWidth)
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: name != profile.profile.name, isSaving: isSaving, requested: $requestsCancel))
    }
}

struct SubscriptionEditorSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Binding var urlText: String
    @State private var requestsCancel = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "link.badge.plus",
                title: AppLocalization.string("Add Profile Subscription"),
                subtitle: AppLocalization.string("Paste the HTTPS address supplied by your trusted provider.")
            )

            HStack(spacing: AetherVisual.s2) {
                TextField(AppLocalization.string("HTTPS subscription URL"), text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("subscription-url-field")
                    .onChange(of: urlText) { _, value in
                        // Pasted addresses often include a trailing line break.
                        // Normalize the editor as well as the submitted value so
                        // the field never scrolls to an apparently empty line.
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if normalized != value {
                            urlText = normalized
                        }
                    }

                Button {
                    if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !pasted.isEmpty {
                        urlText = pasted
                    }
                } label: {
                    Label(AppLocalization.string("Paste"), systemImage: "doc.on.clipboard")
                }
                .aetherGlassButton()
                .controlSize(.regular)
                .accessibilityIdentifier("subscription-paste-button")
            }

            if let message = tunnel.profileMessage {
                Label(
                    message,
                    systemImage: tunnel.profileMessageIsError
                        ? "exclamationmark.triangle.fill"
                        : "checkmark.circle.fill"
                )
                .font(.callout)
                .foregroundStyle(
                    tunnel.profileMessageIsError ? Color.red : Color.green
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("subscription-result-message")
            }

            Group {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
                Label(
                    "The download is size-limited and validated, then kept only for this preview session. It cannot enable system routing.",
                    systemImage: "checkmark.shield"
                )
#else
                Label(
                    "The address is stored inside the encrypted profile. Downloads are size-limited and validated before activation.",
                    systemImage: "lock.shield"
                )
#endif
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Cancel", role: .cancel) { requestsCancel = true }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    Task {
                        if await tunnel.addSubscription(urlText: urlText) {
                            dismiss()
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string(tunnel.isEnabled ? "Download and Save" : "Download and Activate"),
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .aetherGlassButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || tunnel.isRefreshingSubscription
                        || !tunnel.canImportOrAddProfile
                )
                .accessibilityIdentifier("activate-subscription-button")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(minWidth: AetherVisual.sheetMinWidth, idealWidth: AetherVisual.sheetIdealWidth, maxWidth: AetherVisual.sheetMaxWidth)
        .disabled(tunnel.isRefreshingSubscription)
        .modifier(DiscardChangesModifier(isDirty: !urlText.isEmpty, isSaving: tunnel.isRefreshingSubscription, requested: $requestsCancel))
        .onAppear {
            if urlText.isEmpty,
               let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               pasted.lowercased().hasPrefix("https://") {
                urlText = pasted
            }
        }
    }
}

/// Node counts of the profiles in the library, by profile and import date,
/// so the list does not re-parse every profile each time it appears.
@MainActor
private enum ProfileNodeCountCache {
    struct Key: Hashable {
        let id: UUID
        let importedAt: Date
        let length: Int
    }

    static var counts: [Key: Int] = [:]

    static func key(for managed: ManagedProfile) -> Key {
        Key(id: managed.id, importedAt: managed.profile.importedAt, length: managed.profile.yaml.utf8.count)
    }
}

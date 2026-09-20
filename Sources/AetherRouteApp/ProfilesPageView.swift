import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

struct EmptyProfileOnboardingCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
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
                                colors: [Color.accentColor.opacity(0.18), Color.blue.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "sparkles")
                        .font(.system(size: 22, weight: .semibold))
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
                            .font(.system(size: 13, weight: .semibold))
                        Text(AppLocalization.string("Add Subscription…"))
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, AetherVisual.s1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-add-subscription-button")

                Button {
                    onImportProfile()
                } label: {
                    HStack(spacing: AetherVisual.sCompact) {
                        Image(systemName: "square.and.arrow.down")
                            .font(.system(size: 13, weight: .medium))
                        Text(AppLocalization.string("Import Profile…"))
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-import-profile-button")

                if let onCloudSync {
                    Button {
                        onCloudSync()
                    } label: {
                        HStack(spacing: AetherVisual.sCompact) {
                            Image(systemName: "icloud")
                                .font(.system(size: 13, weight: .medium))
                            Text(AppLocalization.string("iCloud Sync…"))
                                .font(.system(size: 13, weight: .medium))
                        }
                    }
                    .buttonStyle(.bordered)
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
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 27, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 54, height: 54)
                    .background(
                        Color.accentColor.opacity(0.09),
                        in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius)
                    )

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Review Subscription Link")
                        .font(.title2.weight(.semibold))
                    Text("AetherRoute has not downloaded or changed anything yet.")
                        .foregroundStyle(.secondary)
                }
            }

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
                        tunnel.isEnabled ? "Download and Save" : "Download and Enable",
                        isWorking: isConfirming
                            || tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.borderedProminent)
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
        .frame(width: 540)
        .interactiveDismissDisabled(isConfirming)
    }
}

struct ProfilesView: View {
    private enum FileImporterKind {
        case profile
        case portableArchive
        case routingResource

        var allowedContentTypes: [UTType] {
            switch self {
            case .profile:
                [.plainText, .data]
            case .portableArchive:
                [.aetherRouteProfileArchive, .data]
            case .routingResource:
                [.data]
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var fileImporterKind: FileImporterKind = .profile
    @State private var isFileImporterPresented = false
    @State private var isManualNodeEditorPresented = false
    @State private var isSubscriptionEditorPresented = false
    @State private var subscriptionURL = ""
    @State private var profileToRename: ManagedProfile?
    @State private var nativeProfileToEdit: ManagedProfile?
    @State private var isArchivePasswordPresented = false
    @State private var isArchiveExporterPresented = false
    @State private var isExportPasswordPresented = false
    @State private var routingResourceImportKind: RoutingResourceKind?
    @State private var isCloudSyncSheetPresented = false
    @State private var archiveImportURL: URL?
    @State private var pendingArchiveData: Data?
    @State private var archiveDocument = ProfileArchiveDocument()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                pageHeader

                if let message = tunnel.profileMessage, !tunnel.isImportingProfile {
                    profileMessageBanner(message: message, isError: tunnel.profileMessageIsError)
                }

                if tunnel.isImportingProfile {
                    importProgressCard
                }

                if tunnel.profiles.isEmpty {
                    emptyOnboardingSection
                    supportedFormatsCard
                } else {
                    profileLibraryCard

                    if !tunnel.requiredRoutingResources.isEmpty {
                        RoutingResourcesCard(
                            importResource: { kind in
                                routingResourceImportKind = kind
                                presentFileImporter(.routingResource)
                            }
                        )
                        .environmentObject(tunnel)
                    }
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
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
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text("Profiles")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Manage proxy subscriptions, local files, and routing profiles."))
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s2)

            HStack(spacing: AetherVisual.s2) {
                Button("Add Subscription…", systemImage: "link.badge.plus") {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    isSubscriptionEditorPresented = true
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
                .disabled(!tunnel.canImportOrAddProfile)
                .accessibilityIdentifier("add-subscription")

                Button("Import Profile…", systemImage: "square.and.arrow.down") {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(!tunnel.canImportOrAddProfile)

                Menu("More", systemImage: "ellipsis.circle") {
                    Button(AppLocalization.string("iCloud Sync…"), systemImage: "icloud") {
                        tunnel.clearProfileMessage()
                        isCloudSyncSheetPresented = true
                    }
                    .accessibilityIdentifier("profiles-icloud-sync-button")

                    Button("Add Node…", systemImage: "plus") {
                        tunnel.clearProfileMessage()
                        isManualNodeEditorPresented = true
                    }
                    .disabled(!tunnel.canImportOrAddProfile)

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
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .accessibilityIdentifier("profiles-more-menu")
            }
        }
        .padding(.bottom, AetherVisual.s1)
    }

    private func profileMessageBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isError ? Color.orange : Color.green)

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: AetherVisual.s2)

            Button {
                tunnel.clearProfileMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
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
                                colors: [Color.accentColor.opacity(0.18), Color.blue.opacity(0.06)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "doc.badge.plus")
                        .font(.system(size: 28, weight: .semibold))
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
                                    .fill(Color.blue.opacity(0.12))
                                Image(systemName: "link.badge.plus")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.blue)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
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
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.indigo.opacity(0.12))
                                Image(systemName: "square.and.arrow.down")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.indigo)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
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
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)

                Button {
                    tunnel.clearProfileMessage()
                    isCloudSyncSheetPresented = true
                } label: {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack {
                            ZStack {
                                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                                    .fill(Color.teal.opacity(0.12))
                                Image(systemName: "icloud.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(Color.teal)
                            }
                            .frame(width: 34, height: 34)

                            Spacer(minLength: 0)

                            Image(systemName: "arrow.right")
                                .font(.system(size: 11, weight: .semibold))
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
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.6), in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                }
                .buttonStyle(.plain)
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


    private var profileLibraryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center) {
                HStack(spacing: AetherVisual.s2) {
                    Text("Profile Library")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Text(verbatim: "\(tunnel.profiles.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, AetherVisual.sCompact)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }

                Spacer()

                Label("Encrypted on this Mac", systemImage: "lock.shield.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
            }
            .padding(.horizontal, AetherVisual.s5)
            .padding(.vertical, AetherVisual.s4)

            Divider()
                .padding(.horizontal, AetherVisual.s5)

            ForEach(Array(tunnel.profiles.enumerated()), id: \.element.id) { index, managed in
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
                        Task { await tunnel.removeProfile(id: managed.id) }
                    }
                )

                if index < tunnel.profiles.count - 1 {
                    Divider()
                        .padding(.leading, AetherVisual.tableContentIndent)
                        .padding(.trailing, AetherVisual.s5)
                }
            }
        }
        .aetherPanel()
    }

    private var supportedFormatsCard: some View {
        HStack(spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.teal.opacity(0.12))
                Image(systemName: "doc.text.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.teal)
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

    private func subscriptionUpdateDetail(_ subscription: ProfileSubscription) -> String {
        guard let interval = subscription.autoUpdateInterval else {
            return AppLocalization.string("HTTPS subscription · manual updates")
        }
        let hours = max(1, Int(interval / 3_600))
        return String.localizedStringWithFormat(
            AppLocalization.string("HTTPS subscription · updates every %lld hours"),
            Int64(hours)
        )
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
        case let (.routingResource, .success(urls)):
            guard let kind = routingResourceImportKind,
                  let url = urls.first else { return }
            routingResourceImportKind = nil
            Task {
                await tunnel.importRoutingResource(kind, from: url)
            }
        case let (_, .failure(error)):
            routingResourceImportKind = nil
            tunnel.reportProfileImportError(error)
        }
    }

    private func presentPendingArchiveExporter() {
        guard let pendingArchiveData else { return }
        archiveDocument = ProfileArchiveDocument(data: pendingArchiveData)
        self.pendingArchiveData = nil
        isArchiveExporterPresented = true
    }
}

private struct RoutingResourcesCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let importResource: (RoutingResourceKind) -> Void

    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                Image(systemName: resourcesAreReady ? "checkmark.shield" : "map")
                    .font(.title3)
                    .foregroundStyle(resourcesAreReady ? Color.teal : Color.accentColor)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Routing rules")
                        .font(.headline)
                    Text(summary)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
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
                    .buttonStyle(.bordered)
                    .disabled(!tunnel.canModifyProfiles)
                    .accessibilityIdentifier("retry-routing-rules")
                }
            }

            Button {
                showsAdvanced.toggle()
            } label: {
                HStack(spacing: AetherVisual.s1) {
                    Image(systemName: showsAdvanced ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 12)
                        .accessibilityHidden(true)
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
                            "Download & Verify",
                            systemImage: "arrow.down.shield",
                            isWorking: tunnel.isUpdatingRoutingResources
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        !tunnel.canModifyProfiles
                            || tunnel.isUpdatingRoutingResources
                    )

                    Text("Bundled rules use DB-IP Lite and V2Fly data. Country rule updates may use MaxMind data through Loyalsoldier. See Open-Source Software for sources and licenses.")
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-resources-card")
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
        return AppLocalization.string(
            resourcesAreReady
                ? "Routing rules are ready."
                : "AetherRoute prepares routing rules automatically when you connect."
        )
    }

    private func resourceRow(_ kind: RoutingResourceKind) -> some View {
        HStack(spacing: AetherVisual.s4) {
            Image(systemName: resourceSymbol(kind))
                .font(.system(size: 17, weight: .semibold))
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
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(
                !tunnel.canModifyProfiles
                    || tunnel.isUpdatingRoutingResources
            )
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
        case .ready?: .teal
        case .stale?, .invalid?: .orange
        case .missing?, nil: .blue
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

private struct ManagedProfileRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var isHovered = false
    @State private var isActionHovered = false
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
            // 1. 左侧原生单选指示器 (Radio Indicator)
            Button(action: {
                if !isActive && canActivate {
                    activate()
                }
            }) {
                ZStack {
                    Circle()
                        .strokeBorder(
                            isActive ? Color.accentColor : Color.secondary.opacity(0.35),
                            lineWidth: 1.5
                        )
                        .frame(width: 16, height: 16)
                    if isActive {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 8, height: 8)
                    }
                }
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isActive || !canActivate)
            .accessibilityIdentifier("radio-select-\(managed.id.uuidString)")
            .accessibilityLabel(isActive ? "Selected" : "Select")

            // 2. 节点/配置图标 (磨砂色底 + 矢量图标)
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(iconGradient)
                Image(systemName: iconName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(iconTint)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            // 3. 配置名称与副标题
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(managed.profile.name)
                        .font(.system(size: 13.5, weight: isActive ? .bold : .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if isActive {
                        HStack(spacing: AetherVisual.s1) {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5, height: 5)
                            Text("In Use")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, AetherVisual.s2)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(Color.green.opacity(0.12), in: Capsule())
                    }
                }

                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }

            Spacer(minLength: AetherVisual.s2)

            // 4. 右侧操作区：如果是激活的订阅，展示检查更新按钮
            if isActive && isSubscription {
                Button {
                    Task { await tunnel.refreshSubscription() }
                } label: {
                    AetherProgressButtonLabel(
                        "Check for Updates",
                        systemImage: "arrow.clockwise",
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canModify || tunnel.isRefreshingSubscription)
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
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isActionHovered ? Color.primary : Color.secondary)
                    .frame(width: 26, height: 26)
                    .background(isActionHovered ? Color.secondary.opacity(0.18) : Color.clear, in: Circle())
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 26)
            .onHover { isActionHovered = $0 }
            .accessibilityLabel("Profile actions")
            .accessibilityIdentifier("profile-actions-\(managed.id.uuidString)")
        }
        .padding(.horizontal, AetherVisual.s5)
        .padding(.vertical, AetherVisual.sRow)
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive && canActivate {
                activate()
            }
        }
        .accessibilityIdentifier("activate-profile-\(managed.id.uuidString)")
        .background(
            isActive
                ? Color.accentColor.opacity(colorScheme == .dark ? 0.08 : 0.04)
                : (isHovered ? Color.primary.opacity(0.03) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive && canActivate {
                activate()
            }
        }
        .onHover { isHovered = $0 }
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

    private var iconTint: Color {
        if isSubscription {
            return .blue
        }
        if managed.profile.nativeNodes != nil {
            return .orange
        }
        return .teal
    }

    private var iconGradient: LinearGradient {
        LinearGradient(
            colors: [iconTint.opacity(0.18), iconTint.opacity(0.08)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var detail: String {
        let source = isSubscription
            ? AppLocalization.string("HTTPS subscription")
            : (managed.profile.nativeNodes != nil
                ? AppLocalization.string("Manual nodes")
                : AppLocalization.string("Local profile"))
        let importedAt = AppLocalization.date(
            managed.profile.importedAt,
            date: .abbreviated,
            time: .omitted
        )
        return "\(source) · \(importedAt)"
    }
}

private struct ProfileRenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let profile: ManagedProfile
    let save: (String) async -> Bool
    @State private var name: String
    @State private var isSaving = false

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
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text("Rename Profile")
                    .font(.title2.weight(.semibold))
                Text("Choose a short name that is easy to recognize in the menu bar.")
                    .foregroundStyle(.secondary)
            }

            TextField("Profile name", text: $name)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("profile-name-field")

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Spacer()
                Button {
                    Task {
                        isSaving = true
                        defer { isSaving = false }
                        if await save(name) { dismiss() }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        "Save",
                        isWorking: isSaving
                    )
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSaving
                )
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 460)
    }
}

struct SubscriptionEditorSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Binding var urlText: String

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            HStack(spacing: AetherVisual.s4) {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Add Profile Subscription")
                        .font(.title2.weight(.semibold))
                    Text("Paste the HTTPS address supplied by your trusted provider.")
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: AetherVisual.s2) {
                TextField("HTTPS subscription URL", text: $urlText)
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
                .buttonStyle(.bordered)
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
                Button("Cancel", role: .cancel) { dismiss() }
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
                        tunnel.isEnabled ? "Download and Save" : "Download and Activate",
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .buttonStyle(.borderedProminent)
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
        .frame(width: 540)
        .onAppear {
            if urlText.isEmpty,
               let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               pasted.lowercased().hasPrefix("https://") {
                urlText = pasted
            }
        }
    }
}


import AetherRouteKit
import SwiftUI
import UniformTypeIdentifiers

struct EmptyProfileOnboardingCard: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let onAddSubscription: () -> Void
    let onImportProfile: () -> Void
    var onCloudSync: (() -> Void)? = nil

    private var importLockReason: String? {
        guard !tunnel.canImportOrAddProfile else { return nil }
        return tunnel.profileEditLockReason
            ?? AppLocalization.string("Wait for current profile operations to finish before importing.")
    }

    private var isCloudSyncBusy: Bool {
        tunnel.isImportingProfile || tunnel.isUpdatingProfiles || tunnel.isTransferringProfiles
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s4) {
                AetherIconTile(symbol: "sparkles", color: AppSection.profiles.tileColor, size: AetherVisual.sheetIconSize)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Welcome to AetherRoute"))
                        .font(.headline)
                        .foregroundStyle(.primary)

                    Text(AppLocalization.string("Import a subscription URL or configuration file to get started with high-speed, secure routing."))
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            AetherFlowLayout(spacing: AetherVisual.s3) {
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
                .aetherButton(prominent: true)
                .controlSize(.large)
                .disabled(!tunnel.canImportOrAddProfile)
                .help(importLockReason ?? "")
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
                .aetherButton()
                .controlSize(.large)
                .disabled(!tunnel.canImportOrAddProfile)
                .help(importLockReason ?? "")
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
                    .aetherButton()
                    .controlSize(.large)
                    .disabled(isCloudSyncBusy)
                    .help(isCloudSyncBusy ? (importLockReason ?? "") : "")
                    .accessibilityIdentifier("onboarding-icloud-sync-button")
                }
            }

            Divider()

            HStack(spacing: AetherVisual.s2) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                Text(AppLocalization.string("Supports Clash YAML/Meta, V2Ray/Base64 share links (VMess, VLESS, Trojan, SS, Hysteria2), automatic latency testing, and smart rule routing."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
        }
        .padding(AetherVisual.heroCardPadding)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("empty-profile-onboarding-card")
    }
}

struct ExternalSubscriptionConfirmationSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    let request: ExternalSubscriptionImportRequest
    @State private var isConfirming = false
    @State private var errorMessage: String?
    @State private var downloadTask: Task<Void, Never>?

    private var isBusy: Bool {
        isConfirming || tunnel.isRefreshingSubscription
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "link.badge.plus",
                title: AppLocalization.string("Review Subscription Link"),
                subtitle: AppLocalization.string("AetherRoute has not downloaded or changed anything yet."),
                tint: AetherVisual.subscriptionTint
            )

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text(AppLocalization.string("Address"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AetherVisual.secondaryText)
                Label(request.providerHost, systemImage: "lock.fill")
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("external-subscription-host")
                Text(AppLocalization.string("AetherRoute will not access this address until you confirm."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            .padding(AetherVisual.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                AetherVisual.subtleFill,
                in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius)
            )

            Label(
                AppLocalization.string("If you continue, AetherRoute will make one HTTPS request, validate the size and contents, store the subscription in encrypted profile storage, and activate it."),
                systemImage: "checkmark.shield"
            )
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if !tunnel.canImportOrAddProfileRegardlessOfPrivacy {
                AetherInlineMessage(
                    text: AppLocalization.string("Wait for current profile operations to finish before importing."),
                    kind: .warning,
                    systemImage: "hourglass"
                )
            } else if tunnel.isEnabled {
                Label(
                    AppLocalization.string("The subscription will be downloaded and safely added to your profile library without interrupting your connection."),
                    systemImage: "checkmark.circle"
                )
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
            } else if !tunnel.hasAcceptedPrivacyDisclosure {
                Label(
                    AppLocalization.string("Confirming will accept the network privacy review and activate this subscription."),
                    systemImage: "checkmark.shield"
                )
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
            }

            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
            }

            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    downloadTask?.cancel()
                    downloadTask = nil
                    isConfirming = false
                    tunnel.cancelExternalSubscriptionImport()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    guard !isBusy else { return }
                    errorMessage = nil
                    tunnel.clearProfileMessage()
                    isConfirming = true
                    downloadTask?.cancel()
                    downloadTask = Task {
                        let didImport = await tunnel.confirmExternalSubscriptionImport(
                            id: request.id
                        )
                        guard !Task.isCancelled else { return }
                        downloadTask = nil
                        if didImport {
                            dismiss()
                        } else {
                            isConfirming = false
                            errorMessage = tunnel.profileMessage
                                ?? AppLocalization.string("The profile operation could not be completed.")
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string(tunnel.isEnabled ? "Download and Save" : "Download and Activate"),
                        isWorking: isBusy
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    !tunnel.canImportOrAddProfileRegardlessOfPrivacy
                        || isBusy
                )
                .accessibilityIdentifier("confirm-external-subscription")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(isBusy)
        .onAppear {
            errorMessage = nil
            tunnel.clearProfileMessage()
        }
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
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

    private enum PresentedSheet: Identifiable {
        case subscription
        case shareLinkImport
        case manualNode
        case cloudSync
        case mergeProfiles
        case globalOverride
        case rename(ManagedProfile)
        case editNative(ManagedProfile)
        case editSubscriptionURL(ManagedProfile)
        case exportPassword
        case importArchivePassword(URL)

        var id: String {
            switch self {
            case .subscription: "subscription"
            case .shareLinkImport: "shareLinkImport"
            case .manualNode: "manualNode"
            case .cloudSync: "cloudSync"
            case .mergeProfiles: "mergeProfiles"
            case .globalOverride: "globalOverride"
            case let .rename(profile): "rename-\(profile.id.uuidString)"
            case let .editNative(profile): "editNative-\(profile.id.uuidString)"
            case let .editSubscriptionURL(profile): "editSubscriptionURL-\(profile.id.uuidString)"
            case .exportPassword: "exportPassword"
            case let .importArchivePassword(url): "importArchivePassword-\(url.path)"
            }
        }
    }

    private struct ExternalProvidersReloadKey: Equatable {
        let activeProfileID: UUID?
        let updatedAt: Date?
        let activeYAML: String?
    }

    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var fileImporterKind: FileImporterKind = .profile
    /// Removal deletes the profile's encrypted data, so it asks first.
    @State private var profileToRemove: ManagedProfile?
    /// A file dragged over the page that can be dropped to import it.
    @State private var isDropTargeted = false
    @State private var isFileImporterPresented = false
    @State private var isArchiveExporterPresented = false
    @State private var presentedSheet: PresentedSheet?
    @State private var subscriptionURL = ""
    @State private var searchText = ""
    @State private var proxyProviders: [ProxyProviderMetadata] = []
    @State private var ruleProviders: [RuleProviderMetadata] = []
    @State private var isRefreshingProviders = false
    @State private var pendingArchiveData: Data?
    @State private var archiveDocument = ProfileArchiveDocument()

    private var hasActiveModal: Bool {
        presentedSheet != nil
            || profileToRemove != nil
            || isFileImporterPresented
            || isArchiveExporterPresented
    }

    private var externalProvidersReloadKey: ExternalProvidersReloadKey {
        let activeManaged = tunnel.profiles.first(where: { $0.id == tunnel.activeProfileID })
        return ExternalProvidersReloadKey(
            activeProfileID: tunnel.activeProfileID,
            updatedAt: activeManaged?.updatedAt,
            activeYAML: tunnel.activeProfile?.yaml
        )
    }

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
                    externalProvidersCard
                }
            }
            .aetherPageContent(.wide)
            .aetherAnimation(AetherVisual.gentleSpring, value: tunnel.profileMessage)
        }
        .onChange(of: tunnel.profiles.count) { _, newCount in
            if newCount <= Self.searchThreshold && !searchText.isEmpty {
                searchText = ""
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard presentedSheet == nil,
                  profileToRemove == nil,
                  !isFileImporterPresented,
                  !isArchiveExporterPresented,
                  !tunnel.isImportingProfile else {
                return false
            }
            return importDroppedFile(urls)
        } isTargeted: { targeted in
            let canTarget = targeted
                && presentedSheet == nil
                && profileToRemove == nil
                && !isFileImporterPresented
                && !isArchiveExporterPresented
                && !tunnel.isImportingProfile
                && tunnel.canImportOrAddProfile
            withAnimation(AetherVisual.animation(AetherVisual.quickFade, reduceMotion: reduceMotion)) {
                isDropTargeted = canTarget
            }
        }
        .overlay {
            if isDropTargeted {
                // Says where the file goes before it is let go.
                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .background(
                        AetherVisual.tintWash(.accentColor),
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
        .background {
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
                .fileImporter(
                    isPresented: $isFileImporterPresented,
                    allowedContentTypes: fileImporterKind.allowedContentTypes,
                    allowsMultipleSelection: false
                ) { result in
                    handleFileImport(result, kind: fileImporterKind)
                }

            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
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
                        reportFileTransferError(error)
                    }
                    archiveDocument = ProfileArchiveDocument()
                }
        }
        .onChange(of: isArchiveExporterPresented) { _, presented in
            if !presented {
                archiveDocument = ProfileArchiveDocument()
            }
        }
        .confirmationDialog(
            AppLocalization.format(
                "Remove “%@”?",
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
        .task(id: externalProvidersReloadKey) {
            let loaded = await tunnel.loadAllExternalProviders()
            ruleProviders = loaded.rules
            proxyProviders = loaded.proxies
        }
        .sheet(
            item: $presentedSheet,
            onDismiss: {
                if pendingArchiveData != nil {
                    Task { @MainActor in
                        await Task.yield()
                        presentPendingArchiveExporter()
                    }
                }
            }
        ) { sheet in
            switch sheet {
            case .subscription:
                SubscriptionEditorSheet(urlText: $subscriptionURL)
                    .environmentObject(tunnel)
            case .shareLinkImport:
                ShareLinkImportSheet()
                    .environmentObject(tunnel)
            case .manualNode:
                ManualNodeEditorSheet()
                    .environmentObject(tunnel)
            case .cloudSync:
                ProfileCloudSyncSheet()
                    .environmentObject(tunnel)
            case .mergeProfiles:
                MergeProfilesSheet()
                    .environmentObject(tunnel)
            case .globalOverride:
                GlobalOverrideSheet()
                    .environmentObject(tunnel)
            case let .rename(managed):
                ProfileRenameSheet(profile: managed) { name in
                    await tunnel.renameProfile(id: managed.id, name: name)
                }
                .environmentObject(tunnel)
            case let .editNative(managed):
                NativeProfileEditorSheet(profile: managed)
                    .environmentObject(tunnel)
            case let .editSubscriptionURL(managed):
                EditSubscriptionURLSheet(managed: managed)
                    .environmentObject(tunnel)
            case .exportPassword:
                ProfileArchivePasswordSheet(
                    mode: .export,
                    failureMessage: { tunnel.profileMessageIsError ? tunnel.profileMessage : nil }
                ) { password in
                    guard let data = await tunnel.makePortableArchive(
                        password: password
                    ) else {
                        return false
                    }
                    pendingArchiveData = data
                    return true
                }
            case let .importArchivePassword(archiveURL):
                ProfileArchivePasswordSheet(
                    mode: .import,
                    failureMessage: { tunnel.profileMessageIsError ? tunnel.profileMessage : nil }
                ) { password in
                    await tunnel.importPortableArchive(
                        from: archiveURL,
                        password: password
                    )
                }
            }
        }
        .accessibilityIdentifier("profiles-page")
#if DEBUG
        .task {
            // Isolated screenshot review only: open one sheet on launch.
            switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_SHEET"] {
            case "subscription": presentedSheet = .subscription
            case "manual-node": presentedSheet = .manualNode
            case "export": presentedSheet = .exportPassword
            case "cloud": presentedSheet = .cloudSync
            case "rename":
                if let first = tunnel.profiles.first {
                    presentedSheet = .rename(first)
                }
            case "profile-editor":
                if let first = tunnel.profiles.first {
                    presentedSheet = .editNative(first)
                }
            default: break
            }
        }
#endif
    }

    private var importLockReason: String {
        tunnel.profileEditLockReason
            ?? AppLocalization.string("Wait for current profile operations to finish before importing.")
    }

    /// One "Add" menu for every way a profile arrives, as in Apple's own
    /// apps; archives and sync sit in the overflow menu beside it.
    private var pageHeader: some View {
        AetherPageHeader(.profiles) {
            if tunnel.profiles.contains(where: { $0.profile.subscription != nil }) {
                Button {
                    tunnel.clearProfileMessage()
                    Task { await tunnel.refreshAllSubscriptions() }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Update All"),
                        systemImage: "arrow.triangle.2.circlepath",
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .aetherButton()
                .fixedSize()
                .disabled(!tunnel.canRefreshAnySubscription || tunnel.isRefreshingSubscription)
                .help(
                    !tunnel.canRefreshAnySubscription || tunnel.isRefreshingSubscription
                        ? importLockReason
                        : AppLocalization.string("Check all subscriptions for updates")
                )
                .accessibilityIdentifier("profiles-update-all-subscriptions")
            }

            Menu {
                Button(AppLocalization.string("Add Subscription…"), systemImage: "link.badge.plus") {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    presentedSheet = .subscription
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .help(!tunnel.canImportOrAddProfile ? importLockReason : "")
                .accessibilityIdentifier("add-subscription")

                Button(AppLocalization.string("Import Profile…"), systemImage: "square.and.arrow.down") {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .help(!tunnel.canImportOrAddProfile ? importLockReason : "")
                .accessibilityIdentifier("import-profile")

                Button(AppLocalization.string("Add Node…"), systemImage: "plus.circle") {
                    tunnel.clearProfileMessage()
                    presentedSheet = .manualNode
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .help(!tunnel.canImportOrAddProfile ? importLockReason : "")
                .accessibilityIdentifier("add-manual-node")

                Button(AppLocalization.string("Import Node Links…"), systemImage: "qrcode.viewfinder") {
                    tunnel.clearProfileMessage()
                    presentedSheet = .shareLinkImport
                }
                .disabled(!tunnel.canImportOrAddProfile)
                .help(!tunnel.canImportOrAddProfile ? importLockReason : "")
                .accessibilityIdentifier("import-share-links")

                Divider()

                let canMerge = tunnel.canImportOrAddProfile
                    && tunnel.canActivateProfile
                    && tunnel.profiles.filter { $0.mergedSpec == nil }.count >= 2
                Button {
                    tunnel.clearProfileMessage()
                    presentedSheet = .mergeProfiles
                } label: {
                    Label(
                        AppLocalization.string("Merge Profiles…"),
                        systemImage: "square.stack.3d.up"
                    )
                }
                .disabled(!canMerge)
                .help(
                    !canMerge
                        ? (tunnel.profiles.filter { $0.mergedSpec == nil }.count < 2
                            ? AppLocalization.string("Add at least two source profiles to create a merged profile.")
                            : importLockReason)
                        : ""
                )
                .accessibilityIdentifier("merge-profiles-button")
            } label: {
                Label(AppLocalization.string("Add"), systemImage: "plus")
                    // The page's main action keeps its name in the toolbar.
                    .labelStyle(.titleAndIcon)
            }
            .menuIndicator(.visible)
            .aetherButton(prominent: true)
            .fixedSize()
            .accessibilityIdentifier("profiles-add-menu")

            Menu {
                Button {
                    tunnel.clearProfileMessage()
                    presentedSheet = .globalOverride
                } label: {
                    Label(
                        AppLocalization.string("Global Override…"),
                        systemImage: "slider.horizontal.3"
                    )
                }
                .accessibilityIdentifier("profiles-global-override-button")

                Button(AppLocalization.string("iCloud Sync…"), systemImage: "icloud") {
                    tunnel.clearProfileMessage()
                    presentedSheet = .cloudSync
                }
                .accessibilityIdentifier("profiles-icloud-sync-button")

                Divider()

                Button(AppLocalization.string("Export Portable Archive…"), systemImage: "square.and.arrow.up") {
                    tunnel.clearProfileMessage()
                    presentedSheet = .exportPassword
                }
                .disabled(tunnel.profiles.isEmpty || tunnel.isTransferringProfiles || !tunnel.hasAcceptedPrivacyDisclosure)
                .help(
                    tunnel.profiles.isEmpty
                        ? AppLocalization.string("No profiles available to export.")
                        : (!tunnel.hasAcceptedPrivacyDisclosure || tunnel.isTransferringProfiles ? importLockReason : "")
                )

                Button(AppLocalization.string("Import Portable Archive…"), systemImage: "square.and.arrow.down") {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.portableArchive)
                }
                .disabled(!tunnel.canModifyProfiles)
                .help(!tunnel.canModifyProfiles ? (tunnel.profileEditLockReason ?? importLockReason) : "")
            } label: {
                // Named, like Add beside it: a lone ellipsis drew a button
                // half its height.
                Label(AppLocalization.string("More"), systemImage: "ellipsis.circle")
            }
            .menuIndicator(.hidden)
            .aetherButton()
            .fixedSize()
            .accessibilityLabel(AppLocalization.string("More"))
            .accessibilityIdentifier("profiles-more-menu")
        }
    }

    private func profileMessageBanner(message: String, isError: Bool) -> some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.title3.weight(.medium))
                .foregroundStyle(AetherReadableTint(color: isError ? .orange : .green))

            Text(message)
                .font(.subheadline)
                .foregroundStyle(.primary)

            Spacer(minLength: AetherVisual.s2)

            Button {
                tunnel.clearProfileMessage()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            .buttonStyle(.plain)
            .help(AppLocalization.string("Close"))
            .accessibilityLabel(AppLocalization.string("Close"))
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .aetherCallout(tint: isError ? .orange : .green)
    }

    private var importProgressCard: some View {
        HStack(spacing: AetherVisual.s3) {
            ProgressView()
                .controlSize(.small)
            Text(AppLocalization.string("Importing profile…"))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
            Spacer(minLength: AetherVisual.s2)
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                tunnel.cancelProfileImport()
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s4)
        .aetherPanel()
        .accessibilityIdentifier("profile-import-progress")
    }

    private var emptyOnboardingSection: some View {
        let isCloudSyncBusy = tunnel.isImportingProfile || tunnel.isUpdatingProfiles || tunnel.isTransferringProfiles
        return VStack(spacing: AetherVisual.s5) {
            VStack(spacing: AetherVisual.s3) {
                AetherIconTile(symbol: "sparkles", color: AppSection.profiles.tileColor, size: AetherVisual.heroTileSize)
                .padding(.top, AetherVisual.s3)

                Text(AppLocalization.string("No Profiles Added"))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Add a subscription link or import a Clash-compatible configuration to get started."))
                    .font(.subheadline)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            LazyVGrid(
                columns: [
                    GridItem(.adaptive(minimum: 180, maximum: 280), spacing: AetherVisual.s4, alignment: .top)
                ],
                alignment: .center,
                spacing: AetherVisual.s4
            ) {
                onboardingOptionTile(
                    symbol: "link.badge.plus",
                    tint: AetherVisual.subscriptionTint,
                    title: AppLocalization.string("Add Subscription…"),
                    subtitle: AppLocalization.string("Import HTTPS subscription URL from your provider."),
                    isDisabled: !tunnel.canImportOrAddProfile,
                    helpText: !tunnel.canImportOrAddProfile ? importLockReason : nil
                ) {
                    tunnel.clearProfileMessage()
                    subscriptionURL = ""
                    presentedSheet = .subscription
                }

                onboardingOptionTile(
                    symbol: "square.and.arrow.down",
                    tint: AetherVisual.localProfileTint,
                    title: AppLocalization.string("Import Profile…"),
                    subtitle: AppLocalization.string("Supports Clash-compatible YAML/JSON profiles."),
                    isDisabled: !tunnel.canImportOrAddProfile,
                    helpText: !tunnel.canImportOrAddProfile ? importLockReason : nil
                ) {
                    tunnel.clearProfileMessage()
                    presentFileImporter(.profile)
                }

                onboardingOptionTile(
                    symbol: "icloud.fill",
                    tint: AetherVisual.iCloudTint,
                    title: AppLocalization.string("iCloud Sync…"),
                    subtitle: AppLocalization.string("Sync profiles from your iPhone or Mac."),
                    isDisabled: isCloudSyncBusy,
                    helpText: isCloudSyncBusy ? importLockReason : nil
                ) {
                    tunnel.clearProfileMessage()
                    presentedSheet = .cloudSync
                }
                .accessibilityIdentifier("onboarding-icloud-sync-card-button")
            }
            .padding(.horizontal, AetherVisual.s2)

            AetherFlowLayout(spacing: AetherVisual.s5) {
                Label(AppLocalization.string("Encrypted on this Mac"), systemImage: "lock.shield.fill")
                Label(AppLocalization.string("Clash Compatible"), systemImage: "checkmark.circle.fill")
                Label(AppLocalization.string("Multi-Protocol"), systemImage: "bolt.horizontal.fill")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(AetherVisual.secondaryText)
            .padding(.bottom, AetherVisual.s2)
        }
        .padding(AetherVisual.heroCardPadding)
        .aetherPanel()
    }

    private func onboardingOptionTile(
        symbol: String,
        tint: Color,
        title: String,
        subtitle: String,
        isDisabled: Bool = false,
        helpText: String? = nil,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                HStack {
                    AetherIconTile(symbol: symbol, color: tint, size: AetherVisual.cardTileSize)

                    Spacer(minLength: 0)

                    Image(systemName: "arrow.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(AetherVisual.secondaryText)
                }

                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(AetherVisual.s4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                AetherVisual.cardFill,
                in: RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
        }
        .buttonStyle(.aetherPressable)
        .disabled(isDisabled)
        .help(helpText ?? "")
    }


    private var filteredProfiles: [ManagedProfile] {
        let query = tunnel.profiles.count > Self.searchThreshold
            ? searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        return tunnel.profiles.filter {
            query.isEmpty
                || $0.profile.name.localizedCaseInsensitiveContains(query)
                || AppLocalization.date(
                    $0.profile.importedAt,
                    date: .abbreviated,
                    time: .omitted
                ).localizedCaseInsensitiveContains(query)
        }
    }

    private static let searchThreshold = 2

    private var profileLibraryCard: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: AppLocalization.string("My profiles"))

            VStack(spacing: 0) {
                if filteredProfiles.isEmpty {
                    ContentUnavailableView {
                        Label(
                            AppLocalization.format("No Results for “%@”", searchText),
                            systemImage: "magnifyingglass"
                        )
                    } description: {
                        Text(AppLocalization.string("Check the spelling or clear the search filter."))
                    } actions: {
                        Button(AppLocalization.string("Clear Search")) {
                            searchText = ""
                        }
                        .aetherButton()
                        .accessibilityIdentifier("profiles-clear-search-button")
                    }
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
                            tunnel.clearProfileMessage()
                            presentedSheet = .rename(managed)
                        },
                        editNative: managed.profile.nativeNodes == nil ? nil : {
                            tunnel.clearProfileMessage()
                            presentedSheet = .editNative(managed)
                        },
                        editSubscriptionURL: managed.profile.subscription == nil ? nil : {
                            tunnel.clearProfileMessage()
                            presentedSheet = .editSubscriptionURL(managed)
                        },
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
            .foregroundStyle(AetherVisual.secondaryText)
            .padding(.horizontal, AetherVisual.s2)
            .padding(.top, AetherVisual.s1)
        }
        .aetherAnimation(AetherVisual.gentleSpring, value: filteredProfiles.map(\.id))
        .aetherAnimation(AetherVisual.gentleSpring, value: tunnel.activeProfileID)
    }

    private var supportedFormatsCard: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: "doc.text.fill", color: AetherVisual.localProfileTint, size: AetherVisual.cardTileSize)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(AppLocalization.string("Supported formats"))
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(AppLocalization.string("Supports Clash-compatible YAML/JSON profiles, HTTPS subscriptions, and common node links."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: AetherVisual.s2)
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
    }

    private func presentFileImporter(_ kind: FileImporterKind) {
        guard !hasActiveModal else { return }
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
            guard tunnel.canModifyProfiles else {
                tunnel.profileMessage = tunnel.profileEditLockReason
                    ?? AppLocalization.string("Stop the secure connection before changing profiles.")
                tunnel.profileMessageIsError = true
                return
            }
            Task { @MainActor in
                await Task.yield()
                presentedSheet = .importArchivePassword(url)
            }
        case let (_, .failure(error)):
            reportFileTransferError(error)
        }
    }

    private func reportFileTransferError(_ error: Error) {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
            return
        }
        if ProfileOperationIssue(error) != nil
            || error is ProfileCatalogStoreError
            || error is PortableProfileArchiveError
            || error is ActiveProfileStoreError {
            tunnel.reportProfileImportError(error)
        } else {
            tunnel.diagnosticEvents.record(.profileOperationFailed)
            tunnel.profileMessage = error.localizedDescription
            tunnel.profileMessageIsError = true
        }
    }

    /// A profile or portable archive dropped on the page goes through the
    /// same import as the Import buttons.
    private func importDroppedFile(_ urls: [URL]) -> Bool {
        guard !hasActiveModal,
              tunnel.canImportOrAddProfile,
              let url = urls.first, url.isFileURL else { return false }
        let isArchive = UTType(filenameExtension: url.pathExtension)?
            .conforms(to: .aetherRouteProfileArchive) == true
        if isArchive && !tunnel.canModifyProfiles {
            tunnel.profileMessage = tunnel.profileEditLockReason
                ?? AppLocalization.string("Stop the secure connection before changing profiles.")
            tunnel.profileMessageIsError = true
            return false
        }
        tunnel.clearProfileMessage()
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let importResource: (RoutingResourceKind) -> Void

    @State private var showsAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                Image(systemName: resourcesAreReady ? "checkmark.shield" : "map")
                    .font(.title3)
                    .foregroundStyle(resourcesAreReady ? AnyShapeStyle(AetherReadableTint(color: .green)) : AnyShapeStyle(Color.accentColor))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Rule resources"))
                        .font(.headline)
                    Text(summary)
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("routing-rules-summary")
                }
                Spacer(minLength: 0)

                if isWorking {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(AppLocalization.string("Preparing routing rules…"))
                } else if tunnel.routingResourceMessageIsError {
                    Button(AppLocalization.string("Retry")) {
                        Task { await tunnel.prepareRequiredRoutingResources() }
                    }
                    .aetherButton()
                    .disabled(!tunnel.canModifyProfiles)
                    .help(editLockReason ?? "")
                    .accessibilityIdentifier("retry-routing-rules")
                }
            }

            Button {
                withAnimation(AetherVisual.animation(AetherVisual.disclosure, reduceMotion: reduceMotion)) {
                    showsAdvanced.toggle()
                }
            } label: {
                HStack(spacing: AetherVisual.s1) {
                    AetherDisclosureChevron(isExpanded: showsAdvanced)
                        .foregroundStyle(.primary)
                    Text(AppLocalization.string("Advanced"))
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

                    Toggle(isOn: Binding(
                        get: { tunnel.isAutomaticRoutingResourceUpdateEnabled },
                        set: { tunnel.setAutomaticRoutingResourceUpdateEnabled($0) }
                    )) {
                        VStack(alignment: .leading, spacing: AetherVisual.s1) {
                            Text(AppLocalization.string("Check for updates automatically"))
                            Text(automaticUpdateDetail)
                                .font(.caption)
                                .foregroundStyle(AetherVisual.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .toggleStyle(AetherRowToggleStyle())
                    .disabled(!tunnel.hasAcceptedPrivacyDisclosure)
                    .accessibilityIdentifier("routing-resources-auto-update")

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
                                ? AnyShapeStyle(AetherReadableTint(color: .red))
                                : AnyShapeStyle(AetherVisual.secondaryText)
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    Button {
                        Task { await tunnel.downloadRequiredRoutingResources() }
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Download & Verify"),
                            systemImage: "arrow.down.circle",
                            isWorking: isWorking
                        )
                    }
                    .aetherButton()
                    .disabled(!tunnel.canDownloadRoutingResources)
                    .help(tunnel.canDownloadRoutingResources ? "" : editLockReason ?? "")
                    .accessibilityIdentifier("routing-resources-download")

                    if let editLockReason {
                        Label(editLockReason, systemImage: "lock")
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("routing-resources-lock-reason")
                    }

                    Text(AppLocalization.string("Bundled rules use DB-IP Lite and V2Fly data. Country rule updates may use MaxMind data through Loyalsoldier. See Open-Source Software for sources and licenses."))
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .transition(AetherVisual.insertion)
            }
        }
        .padding(AetherVisual.cardPadding)
        .aetherPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("routing-resources-card")
    }

    /// A running download already shows progress; only explain a lock the
    /// person cannot see the cause of. While connected only Import is locked.
    private var editLockReason: String? {
        guard !isWorking, let reason = tunnel.profileEditLockReason else { return nil }
        return tunnel.isConnected
            ? AppLocalization.string("Import is available after disconnecting. Downloaded updates apply on the next connection.")
            : reason
    }

    private var isWorking: Bool {
        tunnel.isUpdatingRoutingResources || tunnel.isRefreshingRoutingResources
    }

    private var installedRecords: [RoutingResourceRecord] {
        tunnel.requiredRoutingResources.compactMap { kind in
            switch tunnel.routingResourceStatuses[kind] {
            case let .ready(record)?, let .stale(record)?: record
            default: nil
            }
        }
    }

    private var automaticUpdateDetail: String {
        guard tunnel.isAutomaticRoutingResourceUpdateEnabled else {
            return AppLocalization.string("Off. Use Download & Verify to update manually.")
        }
        // The oldest check decides when the next weekly check is due.
        guard let lastChecked = installedRecords.map(\.verifiedCurrentAt).min() else {
            return AppLocalization.string("Checks weekly while connected. Updates apply on the next connection.")
        }
        return AppLocalization.format(
            "Checks weekly while connected. Last checked %@.",
            AppLocalization.date(lastChecked, date: .abbreviated, time: .omitted)
        )
    }

    private var isNearingExpiry: Bool {
        installedRecords.contains {
            $0.origin != .userProvided
                && RoutingResourceRefreshPolicy.isNearingExpiry($0, now: .now)
        }
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
        if tunnel.isRefreshingRoutingResources {
            return AppLocalization.string("Checking for rule updates…")
        }
        if tunnel.routingResourceMessageIsError {
            return AppLocalization.string("Routing rules need attention. Try preparing them again.")
        }
        // "Ready" under a "Routing rules" heading repeated the heading; the
        // age of the data is the one fact worth showing once it is usable.
        if resourcesAreReady, isNearingExpiry {
            return AppLocalization.string("Rule data is almost 30 days old. Choose Download & Verify to update it.")
        }
        if resourcesAreReady, let installedAt = oldestResourceInstallDate {
            return AppLocalization.format(
                "Verified · updated %@",
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
            AetherStatusSymbol(symbol: resourceSymbol(kind), color: resourceColor(kind))

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(kind.fileName)
                    .font(.body.weight(.medium))
                Text(resourceStatusTitle(kind))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: AetherVisual.s3)

            Button(AppLocalization.string("Import…"), systemImage: "square.and.arrow.down") {
                importResource(kind)
            }
            .aetherButton()
            .controlSize(.small)
            .disabled(!tunnel.canModifyProfiles || isWorking)
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
            return AppLocalization.format(
                "Verified · updated %@",
                AppLocalization.date(
                    record.installedAt,
                    date: .abbreviated,
                    time: .omitted
                )
            )
        case let .stale(record):
            return AppLocalization.format(
                status.isUsableForConnection
                    ? "Update recommended · %@"
                    : "Update required · %@",
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
private struct ManagedProfileRowHoverModifier: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(isHovered ? AetherVisual.hoverFill : Color.clear)
            .onHover { isHovered = $0 }
    }
}

private struct ManagedProfileRow: View {
    static let tileSize = AetherVisual.cardTileSize
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var inspectedNodeCount: Int?
    @State private var inspectedFallbackUsage: SubscriptionUsage?
    @State private var inspectedCompatibility: ProfileCompatibilityReport?
    let managed: ManagedProfile
    let isActive: Bool
    let canActivate: Bool
    let canModify: Bool
    let activate: () -> Void
    let rename: () -> Void
    let editNative: (() -> Void)?
    let editSubscriptionURL: (() -> Void)?
    let remove: () -> Void

    private var compatibilityReport: ProfileCompatibilityReport? {
        let key = ProfileNodeCountCache.key(for: managed)
        if isActive {
            return tunnel.activeProfileSummary?.compatibility
                ?? inspectedCompatibility
                ?? ProfileNodeCountCache.compatibilities[key]
        }
        return inspectedCompatibility ?? ProfileNodeCountCache.compatibilities[key]
    }

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: iconName, color: iconTint, size: Self.tileSize)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(managed.profile.name)
                        .help(managed.profile.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if let compatibilityReport {
                        ProfileCompatibilityBadge(report: compatibilityReport)
                            .layoutPriority(1)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                if let usage = managed.profile.subscription?.usage
                    ?? inspectedFallbackUsage
                    ?? ProfileNodeCountCache.fallbackUsages[ProfileNodeCountCache.key(for: managed)] {
                    SubscriptionUsageLine(usage: usage)
                }
                if let updateFailure = tunnel.subscriptionUpdateErrors[managed.id] {
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .accessibilityHidden(true)
                        Text(verbatim: updateFailure.message)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .font(.caption)
                    .foregroundStyle(AetherReadableTint(color: .orange))
                    .help(Text(verbatim: updateFailure.message))
                    .accessibilityIdentifier("profile-update-error-\(managed.id.uuidString)")
                }
            }

            Spacer(minLength: AetherVisual.s2)

            if isSubscription {
                Button {
                    Task { await tunnel.refreshSubscription(id: managed.id) }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Check for Updates"),
                        systemImage: "arrow.clockwise",
                        isWorking: tunnel.refreshingSubscriptionProfileIDs.contains(managed.id)
                    )
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(!tunnel.canRefreshSubscription(id: managed.id))
                .accessibilityIdentifier("refresh-subscription-\(managed.id.uuidString)")
            }

            if isActive {
                Label(AppLocalization.string("Current profile"), systemImage: "checkmark")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AetherReadableTint(color: .accentColor))
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                    .accessibilityIdentifier("profile-current-\(managed.id.uuidString)")
            } else {
                Button(AppLocalization.string("Use")) {
                    activate()
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(!canActivate)
                .help(
                    canActivate
                        ? AppLocalization.string("Use this profile")
                        : (tunnel.profileEditLockReason
                            ?? AppLocalization.string("Wait for the current network operation to finish before changing profiles."))
                )
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

                if let editSubscriptionURL {
                    Button(action: editSubscriptionURL) {
                        Label(AppLocalization.string("Edit Subscription URL…"), systemImage: "link")
                    }
                    .disabled(!canModify)
                    .accessibilityIdentifier("edit-subscription-url-\(managed.id.uuidString)")
                }

                Button(action: rename) {
                    Label(AppLocalization.string("Rename…"), systemImage: "pencil")
                }
                .disabled(!canModify)

                if managed.mergedSpec != nil {
                    Button {
                        Task { await tunnel.rebuildMergedProfile(id: managed.id) }
                    } label: {
                        Label(
                            AppLocalization.string("Rebuild Merged Profile"),
                            systemImage: "arrow.triangle.merge"
                        )
                    }
                    .disabled(!canModify)
                    .accessibilityIdentifier("rebuild-merged-\(managed.id.uuidString)")
                }

                if isSubscription {
                    Button {
                        Task { await tunnel.refreshSubscription(id: managed.id) }
                    } label: {
                        Label(AppLocalization.string("Check for Updates"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!tunnel.canRefreshSubscription(id: managed.id))

                    autoUpdateSubmenu
                }

                if !isActive {
                    Divider()
                    Button(role: .destructive, action: remove) {
                        Label(AppLocalization.string("Remove Profile"), systemImage: "trash")
                    }
                    .disabled(!canModify)
                }
            } label: {
                AetherRowIconLabel(symbol: "ellipsis")
                    .contentShape(Circle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: AetherVisual.iconButtonSize, height: AetherVisual.iconButtonSize)
            .help(AppLocalization.string("Profile actions"))
            .accessibilityLabel(AppLocalization.string("Profile actions"))
            .accessibilityIdentifier("profile-actions-\(managed.id.uuidString)")
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.sRow)
        .frame(minHeight: AetherVisual.twoLineRowHeight)
        .contentShape(Rectangle())
        .modifier(ManagedProfileRowHoverModifier())
        .aetherAnimation(AetherVisual.gentleSpring, value: isActive)
        .onTapGesture(count: 2) {
            if !isActive && canActivate {
                activate()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activate-profile-\(managed.id.uuidString)")
        .task(id: ProfileNodeCountCache.key(for: managed)) {
            // Parsed once per profile version, not on every visit: a large
            // profile took over 100 ms to inspect each time the page opened.
            guard managed.profile.nativeNodes == nil else {
                inspectedCompatibility = nil
                return
            }
            let key = ProfileNodeCountCache.key(for: managed)
            if let cached = ProfileNodeCountCache.counts[key] {
                if inspectedNodeCount != cached {
                    inspectedNodeCount = cached
                }
                let cachedUsage = ProfileNodeCountCache.fallbackUsages[key]
                if inspectedFallbackUsage != cachedUsage {
                    inspectedFallbackUsage = cachedUsage
                }
                let cachedCompatibility = ProfileNodeCountCache.compatibilities[key]
                if inspectedCompatibility != cachedCompatibility {
                    inspectedCompatibility = cachedCompatibility
                }
                return
            }
            let yaml = managed.profile.yaml
            let reportedAt = managed.profile.subscription?.lastUpdatedAt
                ?? managed.profile.subscription?.lastCheckedAt
                ?? managed.profile.importedAt
            let inspected = await Task.detached(priority: .utility) {
                let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
                return (
                    count: summary.proxyCount,
                    usage: SubscriptionUsage.fallback(from: summary, reportedAt: reportedAt),
                    compatibility: summary.compatibility
                )
            }.value
            guard !Task.isCancelled else { return }
            ProfileNodeCountCache.store(
                count: inspected.count,
                usage: inspected.usage,
                compatibility: inspected.compatibility,
                for: key
            )
            inspectedNodeCount = inspected.count
            inspectedFallbackUsage = inspected.usage
            inspectedCompatibility = inspected.compatibility
        }
        .contextMenu {
            if !isActive {
                Button(action: activate) {
                    Label(AppLocalization.string("Use"), systemImage: "play.circle")
                }
                .disabled(!canActivate)
                Divider()
            }
            if isSubscription {
                Button {
                    Task { await tunnel.refreshSubscription(id: managed.id) }
                } label: {
                    Label(AppLocalization.string("Check for Updates"), systemImage: "arrow.clockwise")
                }
                .disabled(!tunnel.canRefreshSubscription(id: managed.id))

                autoUpdateSubmenu
            }
            if let editNative {
                Button(action: editNative) {
                    Label(AppLocalization.string("Edit Nodes…"), systemImage: "point.3.connected.trianglepath.dotted")
                }
                .disabled(!canModify)
            }
            if let editSubscriptionURL {
                Button(action: editSubscriptionURL) {
                    Label(AppLocalization.string("Edit Subscription URL…"), systemImage: "link")
                }
                .disabled(!canModify)
            }
            Button(action: rename) {
                Label(AppLocalization.string("Rename…"), systemImage: "pencil")
            }
            .disabled(!canModify)
            if managed.mergedSpec != nil {
                Button {
                    Task { await tunnel.rebuildMergedProfile(id: managed.id) }
                } label: {
                    Label(
                        AppLocalization.string("Rebuild Merged Profile"),
                        systemImage: "arrow.triangle.merge"
                    )
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
        }
    }

    @ViewBuilder
    private var autoUpdateSubmenu: some View {
        if let subscription = managed.profile.subscription {
            Menu(AppLocalization.string("Auto Update")) {
                if let hint = subscription.providerUpdateInterval {
                    let followsProvider = subscription.autoUpdateInterval != nil
                        && subscription.isAutoUpdateIntervalCustomized != true
                    Toggle(isOn: Binding(
                        get: { followsProvider },
                        set: { _ in
                            Task {
                                await tunnel.updateSubscriptionInterval(
                                    id: managed.id,
                                    interval: nil,
                                    followProvider: true
                                )
                            }
                        }
                    )) {
                        Text(AppLocalization.format(
                            "Provider schedule (every %lld hours)",
                            Int64((hint / 3600).rounded())
                        ))
                    }
                    Divider()
                }
                autoUpdateIntervalOption(
                    title: AppLocalization.string("Manual only"),
                    isSelected: subscription.autoUpdateInterval == nil
                ) {
                    Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: nil) }
                }
                autoUpdateIntervalOption(
                    title: AppLocalization.string("Every 6 Hours"),
                    isSelected: isFixedIntervalSelected(6 * 3600, for: subscription)
                ) {
                    Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: 6 * 3600) }
                }
                autoUpdateIntervalOption(
                    title: AppLocalization.string("Every 12 Hours"),
                    isSelected: isFixedIntervalSelected(12 * 3600, for: subscription)
                ) {
                    Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: 12 * 3600) }
                }
                autoUpdateIntervalOption(
                    title: AppLocalization.string("Every 24 Hours"),
                    isSelected: isFixedIntervalSelected(24 * 3600, for: subscription)
                ) {
                    Task { await tunnel.updateSubscriptionInterval(id: managed.id, interval: 24 * 3600) }
                }
            }
            .disabled(!(canModify || tunnel.canRefreshAnySubscription))
        }
    }

    private func isFixedIntervalSelected(_ seconds: TimeInterval, for subscription: ProfileSubscription) -> Bool {
        guard let interval = subscription.autoUpdateInterval else { return false }
        if subscription.providerUpdateInterval != nil && subscription.isAutoUpdateIntervalCustomized != true {
            return false
        }
        return abs(interval - seconds) < 1
    }

    private func autoUpdateIntervalOption(
        title: String,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Toggle(isOn: Binding(
            get: { isSelected },
            set: { _ in action() }
        )) {
            Text(verbatim: title)
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
        if isSubscription { return AetherVisual.subscriptionTint }
        if managed.profile.nativeNodes != nil { return AetherVisual.manualNodesTint }
        return AetherVisual.localProfileTint
    }

    private var detail: String {
        let source = isSubscription
            ? AppLocalization.string("HTTPS subscription")
            : (managed.profile.nativeNodes != nil
                ? AppLocalization.string("Manual nodes")
                : AppLocalization.string("Local profile"))
        let importedAt = AppLocalization.format(
            "Imported %@",
            AppLocalization.date(
                managed.profile.importedAt,
                date: .abbreviated,
                time: .omitted
            )
        )
        let updatedAt = managed.profile.subscription?.lastUpdatedAt
        let updateDetail = updatedAt.map {
            " · " + AppLocalization.format(
                "Updated %@",
                AppLocalization.date($0, date: .abbreviated, time: .shortened)
            )
        } ?? ""
        let count = managed.profile.nativeNodes?.count
            ?? inspectedNodeCount
            ?? ProfileNodeCountCache.counts[ProfileNodeCountCache.key(for: managed)]
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
    @State private var errorMessage: String?
    @State private var requestsCancel = false
    @FocusState private var isNameFocused: Bool

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
                subtitle: AppLocalization.string("Choose a short name that is easy to recognize in the menu bar."),
                tint: AppSection.profiles.tileColor
            )

            TextField(AppLocalization.string("Profile name"), text: $name)
                .textFieldStyle(.roundedBorder)
                .focused($isNameFocused)
                .onAppear {
                    tunnel.clearProfileMessage()
                    isNameFocused = true
                }
                .onChange(of: name) { _, _ in
                    errorMessage = nil
                }
                .accessibilityIdentifier("profile-name-field")

            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
            }
            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) { requestsCancel = true }
                    .keyboardShortcut(.cancelAction)
                    .disabled(isSaving)
                Button {
                    guard !isSaving else { return }
                    isSaving = true
                    errorMessage = nil
                    tunnel.clearProfileMessage()
                    Task {
                        defer { isSaving = false }
                        if await save(name) {
                            dismiss()
                        } else {
                            errorMessage = tunnel.profileMessage
                                ?? AppLocalization.string("Could not save the profile. Try again.")
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Save"),
                        isWorking: isSaving
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    name.trimmingCharacters(in: .whitespacesAndNewlines)
                        .isEmpty || isSaving
                )
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: name != profile.profile.name, isSaving: isSaving, requested: $requestsCancel))
    }
}

struct SubscriptionEditorSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    @Binding var urlText: String
    @State private var requestsCancel = false
    @State private var errorMessage: String?
    @State private var downloadTask: Task<Void, Never>?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "link.badge.plus",
                title: AppLocalization.string("Add Profile Subscription"),
                subtitle: AppLocalization.string("Paste the HTTPS address supplied by your trusted provider."),
                tint: AetherVisual.subscriptionTint
            )

            HStack(spacing: AetherVisual.s2) {
                TextField(AppLocalization.string("HTTPS subscription URL"), text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isURLFieldFocused)
                    .disabled(tunnel.isRefreshingSubscription)
                    .accessibilityIdentifier("subscription-url-field")
                    .onChange(of: urlText) { _, value in
                        // Pasted addresses often include a trailing line break.
                        // Normalize the editor as well as the submitted value so
                        // the field never scrolls to an apparently empty line.
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if normalized != value {
                            urlText = normalized
                        }
                        errorMessage = nil
                    }

                Button {
                    pasteFromClipboard()
                } label: {
                    Label(AppLocalization.string("Paste"), systemImage: "doc.on.clipboard")
                }
                .aetherButton()
                .controlSize(.regular)
                .disabled(tunnel.isRefreshingSubscription)
                .accessibilityIdentifier("subscription-paste-button")
            }

            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
                    .accessibilityIdentifier("subscription-result-message")
            }

            Group {
#if AETHERROUTE_DEVELOPMENT_PREVIEW
                Label(
                    AppLocalization.string("The download is size-limited and validated, then kept only for this preview session. It cannot enable system routing."),
                    systemImage: "checkmark.shield"
                )
#else
                Label(
                    AppLocalization.string("The address is stored inside the encrypted profile. Downloads are size-limited and validated before activation."),
                    systemImage: "lock.shield"
                )
#endif
            }
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                // Cancel and the primary action share the trailing edge, as in
                // every macOS sheet.
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    if let downloadTask {
                        downloadTask.cancel()
                        self.downloadTask = nil
                        dismiss()
                    } else {
                        requestsCancel = true
                    }
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    errorMessage = nil
                    tunnel.clearProfileMessage()
                    downloadTask?.cancel()
                    downloadTask = Task {
                        let didAdd = await tunnel.addSubscription(urlText: urlText)
                        guard !Task.isCancelled else { return }
                        downloadTask = nil
                        if didAdd {
                            dismiss()
                        } else {
                            errorMessage = tunnel.profileMessage
                                ?? AppLocalization.string("The profile operation could not be completed.")
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string(tunnel.isEnabled ? "Download and Save" : "Download and Activate"),
                        isWorking: tunnel.isRefreshingSubscription
                    )
                }
                .aetherButton(prominent: true)
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
        .aetherSheetFrame()
        .modifier(DiscardChangesModifier(isDirty: !urlText.isEmpty, isSaving: tunnel.isRefreshingSubscription, requested: $requestsCancel))
        .onAppear {
            tunnel.clearProfileMessage()
            errorMessage = nil
            isURLFieldFocused = true
        }
        .onDisappear {
            downloadTask?.cancel()
            downloadTask = nil
        }
    }

    private func pasteFromClipboard() {
        if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pasted.isEmpty {
            urlText = pasted
            errorMessage = nil
        } else {
            errorMessage = AppLocalization.string("Clipboard does not contain text.")
        }
    }
}

private struct EditSubscriptionURLSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss

    let managed: ManagedProfile
    @State private var urlText: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var requestsCancel = false
    @FocusState private var isURLFieldFocused: Bool

    init(managed: ManagedProfile) {
        self.managed = managed
        _urlText = State(initialValue: managed.profile.subscription?.url.absoluteString ?? "")
    }

    private var trimmedURL: String {
        urlText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var initialURL: String {
        managed.profile.subscription?.url.absoluteString ?? ""
    }

    private var isDirty: Bool {
        trimmedURL != initialURL
    }

    private var canModify: Bool {
        tunnel.canModifyProfile(id: managed.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "link",
                title: AppLocalization.string("Edit Subscription URL"),
                subtitle: AppLocalization.string("Update the HTTPS subscription address while keeping this profile’s overrides and settings."),
                tint: AetherVisual.subscriptionTint
            )

            HStack(spacing: AetherVisual.s2) {
                TextField(AppLocalization.string("HTTPS subscription URL"), text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($isURLFieldFocused)
                    .onChange(of: urlText) { _, value in
                        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
                        if normalized != value {
                            urlText = normalized
                        }
                        errorMessage = nil
                    }
                    .accessibilityIdentifier("edit-subscription-url-field")

                Button {
                    pasteFromClipboard()
                } label: {
                    Label(AppLocalization.string("Paste"), systemImage: "doc.on.clipboard")
                }
                .aetherButton()
                .controlSize(.regular)
                .disabled(isSaving)
                .accessibilityIdentifier("edit-subscription-paste-button")
            }

            if !canModify {
                AetherInlineMessage(
                    text: tunnel.profileEditLockReason
                        ?? AppLocalization.string("Stop the secure connection before changing profiles."),
                    kind: .warning,
                    systemImage: "lock"
                )
            }

            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
                    .accessibilityIdentifier("edit-subscription-result-message")
            }

            Label(
                AppLocalization.string("The address is stored inside the encrypted profile. Downloads are size-limited and validated before activation."),
                systemImage: "lock.shield"
            )
            .font(.callout)
            .foregroundStyle(AetherVisual.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    requestsCancel = true
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                Button {
                    save()
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Save"),
                        isWorking: isSaving
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(
                    trimmedURL.isEmpty
                        || !isDirty
                        || isSaving
                        || !canModify
                        || tunnel.isRefreshingSubscription
                        || tunnel.isUpdatingProfiles
                )
                .accessibilityIdentifier("save-subscription-url-button")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .disabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: isDirty, isSaving: isSaving, requested: $requestsCancel))
        .onAppear {
            tunnel.clearProfileMessage()
            errorMessage = nil
            isURLFieldFocused = true
        }
    }

    private func pasteFromClipboard() {
        if let pasted = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !pasted.isEmpty {
            urlText = pasted
            errorMessage = nil
        } else {
            errorMessage = AppLocalization.string("Clipboard does not contain text.")
        }
    }

    private func save() {
        guard !isSaving else { return }
        guard isDirty else {
            dismiss()
            return
        }
        guard tunnel.ensurePrivacyConsent(), canModify else {
            errorMessage = tunnel.profileEditLockReason
                ?? AppLocalization.string("Stop the secure connection before changing profiles.")
            return
        }
        guard let existingSubscription = managed.profile.subscription else {
            errorMessage = AppLocalization.string("The active profile is not a subscription.")
            return
        }
        guard let url = URL(string: trimmedURL) else {
            errorMessage = AppLocalization.string("Enter a valid HTTPS subscription address without embedded credentials or a fragment.")
            return
        }

        isSaving = true
        errorMessage = nil
        tunnel.clearProfileMessage()
        tunnel.refreshingSubscriptionProfileIDs.insert(managed.id)
        tunnel.isRefreshingSubscription = !tunnel.refreshingSubscriptionProfileIDs.isEmpty

        Task {
            defer {
                tunnel.refreshingSubscriptionProfileIDs.remove(managed.id)
                tunnel.isRefreshingSubscription = !tunnel.refreshingSubscriptionProfileIDs.isEmpty
                isSaving = false
            }

            do {
                let candidateSubscription = try ProfileSubscription(
                    url: url,
                    autoUpdateInterval: existingSubscription.autoUpdateInterval,
                    isAutoUpdateIntervalCustomized: existingSubscription.isAutoUpdateIntervalCustomized
                )
                if tunnel.isUIReviewMode {
                    guard let index = tunnel.profiles.firstIndex(where: { $0.id == managed.id }) else {
                        throw ProfileCatalogStoreError.profileNotFound
                    }
                    let existing = tunnel.profiles[index].profile
                    var updatedProfiles = tunnel.profiles
                    updatedProfiles[index] = ManagedProfile(
                        id: managed.id,
                        profile: ActiveProfile(
                            name: existing.name,
                            yaml: existing.yaml,
                            importedAt: existing.importedAt,
                            subscription: candidateSubscription,
                            nativeNodes: existing.nativeNodes,
                            overrides: existing.overrides
                        ),
                        updatedAt: .now,
                        mergedSpec: tunnel.profiles[index].mergedSpec
                    )
                    tunnel.installReviewProfileCatalog(
                        ProfileCatalog(
                            activeProfileID: tunnel.activeProfileID,
                            profiles: updatedProfiles
                        ),
                        preserveConnectedRuntimeState: tunnel.state == .connected
                    )
                    tunnel.recordSubscriptionUpdateError(nil, for: managed.id)
                    tunnel.profileMessage = AppLocalization.string("Subscription URL updated.")
                    tunnel.profileMessageIsError = false
                    dismiss()
                    return
                }

                let update = try await tunnel.subscriptionClient.fetch(candidateSubscription)
                guard let currentManaged = tunnel.profiles.first(where: { $0.id == managed.id }) else {
                    throw ProfileCatalogStoreError.profileNotFound
                }
                let currentProfile = currentManaged.profile
                let updated: ActiveProfile
                let fetchedReport: SubscriptionPayloadReport?
                switch update {
                case let .updated(data, metadata, report):
                    try ProfileImportValidator.validate(data: data)
                    guard let yaml = String(data: data, encoding: .utf8) else {
                        throw ProfileImportError.notUTF8
                    }
                    updated = ActiveProfile(
                        name: currentProfile.name,
                        yaml: yaml,
                        importedAt: currentProfile.importedAt,
                        subscription: metadata,
                        overrides: currentProfile.overrides
                    )
                    fetchedReport = report
                case let .notModified(metadata):
                    updated = ActiveProfile(
                        name: currentProfile.name,
                        yaml: currentProfile.yaml,
                        importedAt: currentProfile.importedAt,
                        subscription: metadata,
                        overrides: currentProfile.overrides
                    )
                    fetchedReport = nil
                }

                nonisolated(unsafe) let defaults = tunnel.userDefaults
                let keepRuntime = tunnel.state == .connected
                let profileID = managed.id
                try await tunnel.performProductionProfileCatalogOperation(
                    preserveConnectedRuntimeState: keepRuntime
                ) {
                    let catalog = try TunnelManager.replaceProfileContents(
                        id: profileID,
                        previous: currentProfile,
                        with: updated,
                        defaults: defaults
                    )
                    return (try? ProfileCatalogStore.applicationGroup().rebuildDependentMergedProfiles(referencing: profileID))
                        ?? catalog
                }
                tunnel.recordSubscriptionUpdateError(nil, for: managed.id)

                let activeIsDependentMerge = tunnel.activeProfileID.flatMap { activeID in
                    tunnel.profiles.first(where: { $0.id == activeID })?.mergedSpec?.sourceProfileIDs.contains(managed.id)
                } ?? false
                if activeIsDependentMerge, tunnel.state == .connected {
                    let currentRoutingMode = tunnel.sessionRoutingMode ?? tunnel.routingMode
                    let preparedReload = try await tunnel.prepareReloadProfilePayload(
                        requestedMode: currentRoutingMode
                    )
                    let client = tunnel.makeProxySelectionProviderClient()
                    try await tunnel.reloadActiveProfileStagingResources(preparedReload, via: client)
                    await tunnel.finalizeLiveProfileReload(client: client)
                }

                if let fetchedReport {
                    tunnel.profileMessage = tunnel.subscriptionSuccessMessage(
                        base: "Subscription URL updated.",
                        partial: "Subscription URL updated. %lld usable nodes imported; %lld invalid nodes skipped.",
                        report: fetchedReport
                    )
                } else {
                    tunnel.profileMessage = AppLocalization.string("Subscription URL updated.")
                }
                tunnel.profileMessageIsError = false
                dismiss()
            } catch {
                errorMessage = tunnel.localizedProfileOperationError(error)
            }
        }
    }
}

/// Node counts of the profiles in the library, keyed by identity and lightweight
/// metadata so refreshes and override updates invalidate stale values without
/// hashing full multi-hundred-kilobyte YAML bodies during SwiftUI layout passes.
@MainActor
private enum ProfileNodeCountCache {
    struct Key: Hashable {
        let id: UUID
        let updatedAt: Date
        let importedAt: Date
        let lastUpdatedAt: Date?
        let length: Int
        let nativeNodeCount: Int?
        let overrideSummaryHash: Int
    }

    private static let maximumEntries = 128
    static var counts: [Key: Int] = [:]
    static var fallbackUsages: [Key: SubscriptionUsage] = [:]
    static var compatibilities: [Key: ProfileCompatibilityReport] = [:]

    static func key(for managed: ManagedProfile) -> Key {
        var hasher = Hasher()
        if let overrides = managed.profile.overrides {
            hasher.combine(overrides.groups.count)
            for group in overrides.groups {
                hasher.combine(group.name)
            }
            hasher.combine(overrides.hiddenNodeKeywords)
            hasher.combine(overrides.chainedProxies.count)
            hasher.combine(overrides.customHosts.count)
            hasher.combine(overrides.scenarioPresets.count)
        }
        return Key(
            id: managed.id,
            updatedAt: managed.updatedAt,
            importedAt: managed.profile.importedAt,
            lastUpdatedAt: managed.profile.subscription?.lastUpdatedAt,
            length: managed.profile.yaml.utf8.count,
            nativeNodeCount: managed.profile.nativeNodes?.count,
            overrideSummaryHash: hasher.finalize()
        )
    }

    static func store(
        count: Int,
        usage: SubscriptionUsage?,
        compatibility: ProfileCompatibilityReport,
        for key: Key
    ) {
        if counts.count >= maximumEntries && counts[key] == nil {
            counts.removeAll(keepingCapacity: true)
            fallbackUsages.removeAll(keepingCapacity: true)
            compatibilities.removeAll(keepingCapacity: true)
        }
        counts[key] = count
        fallbackUsages[key] = usage
        compatibilities[key] = compatibility
    }
}

/// Used and total traffic with the expiry date, coloured once the
/// subscription is running out or has ended.
struct SubscriptionUsageLine: View {
    let usage: SubscriptionUsage

    var body: some View {
        if usage.expiresAt != nil {
            TimelineView(.everyMinute) { context in
                content(now: context.date)
            }
        } else {
            content(now: .now)
        }
    }

    private func content(now: Date) -> some View {
        let alert = SubscriptionUsageAlert.evaluate(usage, now: now)
        return HStack(spacing: AetherVisual.s2) {
            if let fraction = usage.usedFraction {
                let clamped = min(max(fraction, 0), 1)
                // Drawn rather than ProgressView, which turns grey in an
                // inactive window and would hide the warning colour.
                Capsule()
                    .fill(AetherVisual.neutralFill)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(tint(for: alert))
                            .frame(width: clamped <= 0 ? 0 : max(4, 96 * clamped))
                    }
                    .frame(width: 96, height: 5)
                    .accessibilityHidden(true)
            }
            Text(Self.summary(usage, alert: alert, now: now))
                .font(.caption)
                .foregroundStyle(
                    alert == .none
                        ? AnyShapeStyle(AetherVisual.secondaryText)
                        : AnyShapeStyle(AetherReadableTint(color: tint(for: alert)))
                )
                // Two lines rather than cutting off the expiry in a
                // narrow window.
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help(AppLocalization.format(
            "Reported by the provider %@",
            AppLocalization.date(usage.reportedAt, date: .abbreviated, time: .shortened)
        ))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("subscription-usage")
    }

    private func tint(for alert: SubscriptionUsageAlert) -> Color {
        switch alert {
        case .none: .accentColor
        case .low, .expiring: .orange
        case .exhausted, .expired: .red
        }
    }

    static func summary(
        _ usage: SubscriptionUsage,
        alert: SubscriptionUsageAlert,
        now: Date
    ) -> String {
        var parts = [String]()
        if let total = usage.totalBytes, total > 0 {
            parts.append(AppLocalization.format(
                "%@ of %@ used",
                bytes(usage.usedBytes ?? 0),
                bytes(total)
            ))
            if let remaining = usage.remainingBytes, remaining > 0 {
                parts.append(AppLocalization.format("%@ left", bytes(remaining)))
            }
        } else if let used = usage.usedBytes {
            parts.append(AppLocalization.format("%@ used", bytes(used)))
        } else if let remaining = usage.remainingBytes {
            parts.append(AppLocalization.format("%@ left", bytes(remaining)))
        }
        switch alert {
        case .expired:
            parts.append(AppLocalization.string("Expired"))
        case .exhausted:
            parts.append(AppLocalization.string("Traffic used up"))
        default:
            if let expiresAt = usage.expiresAt,
               let days = usage.daysUntilExpiry(now: now) {
                parts.append(AppLocalization.format(
                    "Expires %@ (%lld days)",
                    AppLocalization.date(expiresAt, date: .abbreviated, time: .omitted),
                    Int64(days)
                ))
            }
        }
        return parts.joined(separator: " · ")
    }

    private static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(
            .byteCount(style: .binary).locale(AppLocalization.currentLocale)
        )
    }
}

private extension ProfilesView {
    private var canRefreshExternalProviders: Bool {
        tunnel.hasAcceptedPrivacyDisclosure
            && !isRefreshingProviders
            && !tunnel.isTransitioning
            && !tunnel.isUpdatingProfiles
            && !tunnel.isImportingProfile
            && !tunnel.isTransferringProfiles
    }

    var externalProvidersCard: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(
                title: AppLocalization.string("External Providers")
            ) {
                Button {
                    guard canRefreshExternalProviders else { return }
                    isRefreshingProviders = true
                    Task {
                        let refreshed = await tunnel.refreshAllExternalProviders()
                        ruleProviders = refreshed.rules
                        proxyProviders = refreshed.proxies
                        isRefreshingProviders = false
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Refresh Providers"),
                        systemImage: "arrow.clockwise",
                        isWorking: isRefreshingProviders
                    )
                }
                .aetherButton()
                .controlSize(.small)
                .disabled(!canRefreshExternalProviders)
                .help(!canRefreshExternalProviders ? importLockReason : "")
                .accessibilityIdentifier("refresh-external-providers")
            }

            VStack(spacing: 0) {
                if proxyProviders.isEmpty && ruleProviders.isEmpty {
                    HStack(spacing: AetherVisual.s3) {
                        AetherIconTile(
                            symbol: "shippingbox",
                            color: AetherVisual.localProfileTint,
                            size: AetherVisual.cardTileSize
                        )
                        VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                            Text(AppLocalization.string("No staged providers yet"))
                                .font(.body.weight(.semibold))
                            Text(AppLocalization.string("Remote rule-providers (.yaml, .txt, .mrs) and proxy-providers will be staged locally for TUN and Transparent Proxy."))
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, AetherVisual.s4)
                    .padding(.vertical, AetherVisual.sRow)
                } else {
                    ForEach(Array(proxyProviders.enumerated()), id: \.element.id) { index, provider in
                        HStack(spacing: AetherVisual.s3) {
                            AetherIconTile(
                                symbol: "server.rack",
                                color: AppSection.profiles.tileColor,
                                size: AetherVisual.cardTileSize
                            )
                            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                Text(verbatim: provider.name)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                Text(AppLocalization.format(
                                    "Proxy provider · %@",
                                    AppLocalization.format("%lld nodes", Int64(provider.proxyCount))
                                ))
                                .font(.caption)
                                .foregroundStyle(AetherVisual.secondaryText)
                                if let usage = provider.usage {
                                    SubscriptionUsageLine(usage: usage)
                                }
                                if let err = provider.lastError {
                                    Text(verbatim: err)
                                        .font(.caption)
                                        .foregroundStyle(AetherReadableTint(color: .orange))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(Text(verbatim: err))
                                }
                            }
                            Spacer()
                            if let updated = provider.lastUpdatedAt {
                                Text(verbatim: AppLocalization.date(updated, date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                        }
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.vertical, AetherVisual.sRow)
                        if index < proxyProviders.count - 1 || !ruleProviders.isEmpty {
                            Divider().padding(.leading, AetherVisual.s4 + AetherVisual.cardTileSize + AetherVisual.s3)
                        }
                    }
                    ForEach(Array(ruleProviders.enumerated()), id: \.element.id) { index, provider in
                        HStack(spacing: AetherVisual.s3) {
                            AetherIconTile(
                                symbol: "doc.badge.gearshape",
                                color: AetherVisual.localProfileTint,
                                size: AetherVisual.cardTileSize
                            )
                            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                Text(verbatim: provider.name)
                                    .font(.body.weight(.semibold))
                                    .lineLimit(1)
                                Text(AppLocalization.format(
                                    "Rule provider · %@ · %@",
                                    provider.format.rawValue.uppercased(),
                                    localizedRuleProviderBehavior(provider.behavior)
                                ))
                                    .font(.caption)
                                    .foregroundStyle(AetherVisual.secondaryText)
                                if let err = provider.lastError {
                                    Text(verbatim: err)
                                        .font(.caption)
                                        .foregroundStyle(AetherReadableTint(color: .orange))
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .help(Text(verbatim: err))
                                }
                            }
                            Spacer()
                            if let updated = provider.lastUpdatedAt {
                                Text(verbatim: AppLocalization.date(updated, date: .abbreviated, time: .shortened))
                                    .font(.caption)
                                    .foregroundStyle(AetherVisual.secondaryText)
                            }
                        }
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.vertical, AetherVisual.sRow)
                        if index < ruleProviders.count - 1 {
                            Divider().padding(.leading, AetherVisual.s4 + AetherVisual.cardTileSize + AetherVisual.s3)
                        }
                    }
                }
            }
            .aetherPanel()
        }
    }

    private func localizedRuleProviderBehavior(_ behavior: RuleProviderBehavior) -> String {
        switch behavior {
        case .domain: AppLocalization.string("Domain")
        case .ipcidr: AppLocalization.string("IP-CIDR")
        case .classical: AppLocalization.string("Classical")
        }
    }
}

private struct MergeProfilesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    @State private var name = ""
    @State private var selectedIDs: [UUID] = []
    @State private var prefixSourceName = true
    @State private var deduplicateByServerPort = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var requestsCancel = false
    @FocusState private var isNameFocused: Bool

    private var sourceProfiles: [ManagedProfile] {
        tunnel.profiles.filter { $0.mergedSpec == nil }
    }

    private var hasChanges: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedIDs.isEmpty
            || !prefixSourceName
            || !deduplicateByServerPort
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "square.stack.3d.up",
                title: AppLocalization.string("Merge Profiles"),
                subtitle: AppLocalization.string("Combine nodes from multiple profiles to build cross-subscription chains and unified routing."),
                tint: AppSection.profiles.tileColor
            )

            VStack(spacing: 0) {
                HStack {
                    Text(AppLocalization.string("Name"))
                        .foregroundStyle(AetherVisual.secondaryText)
                    Spacer()
                    TextField(AppLocalization.string("e.g. Combined Airports"), text: $name)
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .focused($isNameFocused)
                        .onChange(of: name) { _, _ in
                            errorMessage = nil
                        }
                        .accessibilityIdentifier("merge-profile-name-field")
                }
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.sRow)

                Divider().padding(.leading, AetherVisual.s4)

                Toggle(isOn: $prefixSourceName) {
                    Text(AppLocalization.string("Prefix node names with source profile"))
                }
                .toggleStyle(AetherRowToggleStyle())
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.sRow)

                Divider().padding(.leading, AetherVisual.s4)

                Toggle(isOn: $deduplicateByServerPort) {
                    Text(AppLocalization.string("Deduplicate identical server & port"))
                }
                .toggleStyle(AetherRowToggleStyle())
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.sRow)
            }
            .aetherPanel()

            Text(AppLocalization.string("Source Profiles"))
                .font(.headline)

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(sourceProfiles.enumerated()), id: \.element.id) { index, managed in
                        Toggle(isOn: Binding(
                            get: { selectedIDs.contains(managed.id) },
                            set: { isOn in
                                errorMessage = nil
                                if isOn {
                                    if !selectedIDs.contains(managed.id) {
                                        selectedIDs.append(managed.id)
                                    }
                                } else {
                                    selectedIDs.removeAll { $0 == managed.id }
                                }
                            }
                        )) {
                            Text(verbatim: managed.profile.name)
                                .lineLimit(1)
                        }
                        .toggleStyle(AetherRowToggleStyle())
                        .padding(.horizontal, AetherVisual.s4)
                        .padding(.vertical, AetherVisual.sRow)
                        if index < sourceProfiles.count - 1 {
                            Divider().padding(.leading, AetherVisual.s4)
                        }
                    }
                }
                .aetherPanel()
            }
            .frame(minHeight: AetherVisual.sheetFormMinHeight, maxHeight: AetherVisual.sheetFormIdealHeight)

            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
                    .accessibilityIdentifier("merge-profiles-error-message")
            }

            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    requestsCancel = true
                }
                .aetherButton()
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                Button {
                    errorMessage = nil
                    tunnel.clearProfileMessage()
                    isSaving = true
                    let spec = MergedProfileSpec(
                        sourceProfileIDs: selectedIDs,
                        prefixSourceName: prefixSourceName,
                        deduplicateByServerPort: deduplicateByServerPort
                    )
                    Task {
                        let ok = await tunnel.createMergedProfile(name: name, spec: spec)
                        isSaving = false
                        if ok {
                            dismiss()
                        } else {
                            errorMessage = tunnel.profileMessage
                                ?? AppLocalization.string("Could not create the merged profile. Check the selected profiles and try again.")
                        }
                    }
                } label: {
                    AetherProgressButtonLabel(
                        AppLocalization.string("Create Merged Profile"),
                        isWorking: isSaving
                    )
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedIDs.count < 2 || isSaving || !tunnel.canActivateProfile)
                .accessibilityIdentifier("confirm-merge-profiles")
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("merge-profiles-sheet")
        .onAppear {
            tunnel.clearProfileMessage()
            errorMessage = nil
            isNameFocused = true
        }
    }
}

private struct GlobalOverrideSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager

    @State private var hiddenKeywordsText = ""
    @State private var groupName = ""
    @State private var includeKeywordsText = ""
    @State private var groupKindTag: String = "url-test"
    @State private var customHostDomain = ""
    @State private var customHostIP = ""
    @State private var groups: [CustomProxyGroup] = []
    @State private var customHosts: [CustomHostMapping] = []
    @State private var initialOverride = ProfileOverride()
    @State private var errorMessage: String?
    @State private var isSaving = false
    @State private var requestsCancel = false
    @FocusState private var isHiddenKeywordsFocused: Bool

    private var currentHiddenKeywords: [String] {
        hiddenKeywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var hasPendingGroupDraft: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !includeKeywordsText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPendingHostDraft: Bool {
        !customHostDomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !customHostIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasPendingDrafts: Bool {
        hasPendingGroupDraft || hasPendingHostDraft
    }

    private var hasChanges: Bool {
        currentHiddenKeywords != initialOverride.hiddenNodeKeywords
            || groups != initialOverride.groups
            || customHosts != initialOverride.customHosts
            || hasPendingDrafts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "slider.horizontal.3",
                title: AppLocalization.string("Global Override Template"),
                subtitle: AppLocalization.string("Applied automatically before per-profile overrides across all profiles."),
                tint: AppSection.profiles.tileColor
            )

            ScrollView {
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Hidden Node Keywords (comma-separated)"))
                            .font(.subheadline.weight(.semibold))
                        TextField(AppLocalization.string("e.g. Expired, Traffic, Reset"), text: $hiddenKeywordsText)
                            .textFieldStyle(.roundedBorder)
                            .focused($isHiddenKeywordsFocused)
                    }
                    .padding(AetherVisual.s4)
                    .aetherPanel()

                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Global Custom Groups"))
                            .font(.subheadline.weight(.semibold))
                        ForEach(groups) { group in
                            HStack(alignment: .top, spacing: AetherVisual.s2) {
                                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                                    Text(verbatim: "\(group.name) (\(localizedGroupKindTitle(group.groupKind)))")
                                        .lineLimit(1)
                                    if !group.includeKeywords.isEmpty {
                                        Text(verbatim: group.includeKeywords.joined(separator: ", "))
                                            .font(.caption)
                                            .foregroundStyle(AetherVisual.secondaryText)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button(role: .destructive) {
                                    groups.removeAll { $0.id == group.id }
                                } label: {
                                    AetherRowIconLabel(symbol: "trash", tint: .red)
                                }
                                .buttonStyle(.plain)
                                .help(AppLocalization.string("Delete"))
                                .accessibilityLabel(AppLocalization.string("Delete"))
                            }
                        }
                        VStack(alignment: .leading, spacing: AetherVisual.s2) {
                            HStack(spacing: AetherVisual.s2) {
                                TextField(AppLocalization.string("Group name"), text: $groupName)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { _ = addGroup() }
                                Picker(AppLocalization.string("Type"), selection: $groupKindTag) {
                                    Text(AppLocalization.string("Strategy select")).tag("select")
                                    Text(AppLocalization.string("Auto Latency (url-test)")).tag("url-test")
                                    Text(AppLocalization.string("Strategy fallback")).tag("fallback")
                                    Text(AppLocalization.string("Load Balance")).tag("load-balance")
                                    Text(AppLocalization.string("Smart")).tag("smart")
                                }
                                .labelsHidden()
                                .fixedSize()
                            }
                            HStack(spacing: AetherVisual.s2) {
                                TextField(AppLocalization.string("Include keywords"), text: $includeKeywordsText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { _ = addGroup() }
                                Button(AppLocalization.string("Add")) {
                                    _ = addGroup()
                                }
                                .aetherButton()
                            }
                        }
                    }
                    .padding(AetherVisual.s4)
                    .aetherPanel()

                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        Text(AppLocalization.string("Global Custom Hosts"))
                            .font(.subheadline.weight(.semibold))
                        ForEach(customHosts) { host in
                            HStack {
                                Text(verbatim: "\(host.domain) → \(host.ip)")
                                    .lineLimit(1)
                                Spacer()
                                Button(role: .destructive) {
                                    customHosts.removeAll { $0.id == host.id }
                                } label: {
                                    AetherRowIconLabel(symbol: "trash", tint: .red)
                                }
                                .buttonStyle(.plain)
                                .help(AppLocalization.string("Delete"))
                                .accessibilityLabel(AppLocalization.string("Delete"))
                            }
                        }
                        HStack(spacing: AetherVisual.s2) {
                            TextField(AppLocalization.string("Domain (e.g. nas.local)"), text: $customHostDomain)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { _ = addHost() }
                            TextField(AppLocalization.string("IP address"), text: $customHostIP)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit { _ = addHost() }
                            Button(AppLocalization.string("Add")) {
                                _ = addHost()
                            }
                            .aetherButton()
                        }
                    }
                    .padding(AetherVisual.s4)
                    .aetherPanel()
                }
            }
            .frame(minHeight: AetherVisual.sheetFormMinHeight, maxHeight: AetherVisual.sheetFormMaxHeight)

            if let errorMessage {
                AetherInlineMessage(text: errorMessage)
            }

            HStack {
                Spacer()
                Button(AppLocalization.string("Cancel"), role: .cancel) {
                    requestsCancel = true
                }
                .aetherButton()
                .keyboardShortcut(.cancelAction)
                .disabled(isSaving)
                Button {
                    save()
                } label: {
                    AetherProgressButtonLabel(AppLocalization.string("Save"), isWorking: isSaving)
                }
                .aetherButton(prominent: true)
                .keyboardShortcut(.defaultAction)
                .disabled(isSaving)
                .accessibilityIdentifier("save-global-override-button")
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .disabled(isSaving)
        .interactiveDismissDisabled(isSaving)
        .modifier(DiscardChangesModifier(isDirty: hasChanges, isSaving: isSaving, requested: $requestsCancel))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("global-override-sheet")
        .onAppear {
            tunnel.clearProfileMessage()
            errorMessage = nil
            let current = tunnel.loadGlobalProfileOverride()
            initialOverride = current
            groups = current.groups
            customHosts = current.customHosts
            hiddenKeywordsText = current.hiddenNodeKeywords.joined(separator: ", ")
            isHiddenKeywordsFocused = true
        }
    }

    private func localizedGroupKindTitle(_ kind: CustomProxyGroupKind) -> String {
        switch kind {
        case .select: AppLocalization.string("Strategy select")
        case .urlTest: AppLocalization.string("Auto Latency (url-test)")
        case .fallback: AppLocalization.string("Strategy fallback")
        case .loadBalance: AppLocalization.string("Load Balance")
        case .smart: AppLocalization.string("Smart")
        }
    }

    @discardableResult
    private func addGroup() -> Bool {
        let keywords = includeKeywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let kind: CustomProxyGroupKind
        switch groupKindTag {
        case "url-test":
            kind = .urlTest(interval: CustomProxyGroupKind.defaultIntervalSeconds, tolerance: CustomProxyGroupKind.defaultToleranceMilliseconds)
        case "fallback":
            kind = .fallback(interval: CustomProxyGroupKind.defaultIntervalSeconds)
        case "load-balance":
            kind = .loadBalance(strategy: .roundRobin)
        case "smart":
            kind = .smart
        default:
            kind = .select
        }
        let candidate = CustomProxyGroup(
            name: groupName,
            includeKeywords: keywords,
            groupKind: kind
        )
        do {
            let validated = try candidate.validated()
            groups.append(validated)
            groupName = ""
            includeKeywordsText = ""
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.overrideMessage
            return false
        }
    }

    @discardableResult
    private func addHost() -> Bool {
        let candidate = CustomHostMapping(domain: customHostDomain, ip: customHostIP)
        do {
            let validated = try candidate.validated()
            customHosts.append(validated)
            customHostDomain = ""
            customHostIP = ""
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.overrideMessage
            return false
        }
    }

    private func save() {
        if hasPendingGroupDraft && !addGroup() {
            return
        }
        if hasPendingHostDraft && !addHost() {
            return
        }
        let hidden = hiddenKeywordsText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let override = ProfileOverride(
            groups: groups,
            hiddenNodeKeywords: hidden,
            customHosts: customHosts
        )
        isSaving = true
        errorMessage = nil
        tunnel.clearProfileMessage()
        Task {
            let ok = await tunnel.saveGlobalProfileOverride(override)
            isSaving = false
            if ok {
                dismiss()
            } else {
                errorMessage = tunnel.profileMessage
                    ?? AppLocalization.string("Could not save global overrides. Accept the privacy notice and try again.")
            }
        }
    }
}

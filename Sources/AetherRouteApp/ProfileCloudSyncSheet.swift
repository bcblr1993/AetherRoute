import AetherRouteKit
import AppKit
import SwiftUI

struct ProfileCloudSyncSheet: View {
    private enum ForceSyncAction: Identifiable {
        case pull
        case push

        var id: Self { self }
    }

    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject private var cloudSync = ProfileCloudSyncManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pendingForceAction: ForceSyncAction?
    @State private var actionErrorMessage: String?

    private var isTunnelProfileBusy: Bool {
        tunnel.isTransitioning
            || tunnel.isUpdatingProfiles
            || tunnel.isImportingProfile
            || tunnel.isRefreshingSubscription
            || tunnel.isTransferringProfiles
    }

    private var syncLockReason: String? {
        if !tunnel.hasAcceptedPrivacyDisclosure {
            return AppLocalization.string("Accept the privacy notice to make changes.")
        }
        if !cloudSync.diagnostics.isICloudAccountSignedIn {
            return AppLocalization.string("Sign in to iCloud in System Settings before syncing.")
        }
        if isTunnelProfileBusy {
            return tunnel.profileEditLockReason
                ?? AppLocalization.string("Wait for current profile operations to finish before syncing.")
        }
        return nil
    }

    private var canRunCloudSyncActions: Bool {
        !cloudSync.isSyncing && syncLockReason == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            AetherSheetHeader(
                symbol: "icloud.fill",
                title: AppLocalization.string("iCloud Profile Sync"),
                subtitle: AppLocalization.string("End-to-end encrypted synchronization across your Mac and iPhone devices."),
                tint: AetherVisual.iCloudTint
            )

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                Toggle(AppLocalization.string("Enable iCloud Sync"), isOn: $cloudSync.isCloudSyncEnabled)
                    .toggleStyle(AetherRowToggleStyle())
                    .disabled(cloudSync.isSyncing)
                    .disabled(
                        !tunnel.hasAcceptedPrivacyDisclosure
                            || (!cloudSync.diagnostics.isICloudAccountSignedIn && !cloudSync.isCloudSyncEnabled)
                            || isTunnelProfileBusy
                    )
                    .help(syncLockReason ?? "")
                    .accessibilityIdentifier("icloud-sync-toggle")

                Text(AppLocalization.string("Profiles are encrypted with AES-256-GCM before being stored in iCloud. The encryption key is protected by iCloud Keychain and synchronizes across devices with the same Apple ID."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                accountDiagnosticsSection

                Divider()

                AetherFlowLayout(spacing: AetherVisual.s2) {
                    Button {
                        revealLocalStorageFolder()
                    } label: {
                        HStack(spacing: AetherVisual.sCompact) {
                            Image(systemName: "folder")
                            Text(AppLocalization.string("Reveal Local Sync Folder"))
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("icloud-reveal-folder-button")

                    Button {
                        openSystemICloudSettings()
                    } label: {
                        HStack(spacing: AetherVisual.sCompact) {
                            Image(systemName: "gearshape")
                            Text(AppLocalization.string("Open System iCloud Settings"))
                        }
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .accessibilityIdentifier("icloud-open-settings-button")
                }

                if let actionErrorMessage {
                    AetherInlineMessage(text: actionErrorMessage, kind: .warning, isCompact: true)
                }
            }
            .padding(AetherVisual.s4)
            .aetherPanel()

            if let syncLockReason {
                AetherInlineMessage(text: syncLockReason, kind: .warning)
            }

            if cloudSync.isCloudSyncEnabled {
                if cloudSync.isSyncing && cloudSync.status == nil {
                    Label(AppLocalization.string("Syncing profiles…"), systemImage: "arrow.triangle.2.circlepath.icloud")
                } else if !cloudSync.isSyncing && cloudSync.lastSyncedAt == nil && cloudSync.status == nil {
                    Label(AppLocalization.string("Enabled · no completed sync yet"), systemImage: "clock")
                }
                Text(AppLocalization.string("Enabling sync does not confirm completion. Automatic sync merges profiles; review the result before using Force Pull or Force Push."))
                    .font(.caption).foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    if let status = cloudSync.status {
                        HStack(spacing: AetherVisual.s2) {
                            Image(systemName: status.isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(status.isFailure ? AnyShapeStyle(AetherReadableTint(color: .orange)) : AnyShapeStyle(Color.accentColor))
                            Text(status.localizedText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if let lastSync = cloudSync.lastSyncedAt {
                        HStack {
                            Text(AppLocalization.string("Last Synced:"))
                                .font(.caption)
                                .foregroundStyle(AetherVisual.secondaryText)
                            Text(AppLocalization.date(lastSync, date: .abbreviated, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(AetherVisual.secondaryText)
                        }
                    }

                    Divider()

                    AetherFlowLayout(spacing: AetherVisual.s2) {
                        Button {
                            actionErrorMessage = nil
                            Task {
                                do {
                                    _ = try await cloudSync.sync()
                                } catch {
                                    cloudSync.recordFailureIfUnexplained(error, operation: .sync)
                                }
                            }
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                if cloudSync.isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath.icloud")
                                }
                                Text(AppLocalization.string("Sync Now"))
                            }
                        }
                        .aetherButton(prominent: true)
                        .disabled(!canRunCloudSyncActions)
                        .help(syncLockReason ?? "")
                        .accessibilityIdentifier("icloud-sync-now-button")

                        Button {
                            actionErrorMessage = nil
                            pendingForceAction = .pull
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Image(systemName: "icloud.and.arrow.down")
                                Text(AppLocalization.string("Force Pull"))
                            }
                        }
                        .aetherButton()
                        .disabled(!canRunCloudSyncActions)
                        .help(syncLockReason ?? "")
                        .accessibilityIdentifier("icloud-force-pull-button")

                        Button {
                            actionErrorMessage = nil
                            pendingForceAction = .push
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Image(systemName: "icloud.and.arrow.up")
                                Text(AppLocalization.string("Force Push"))
                            }
                        }
                        .aetherButton()
                        .disabled(!canRunCloudSyncActions || tunnel.profiles.isEmpty)
                        .help(
                            syncLockReason
                                ?? (tunnel.profiles.isEmpty
                                    ? AppLocalization.string("Add at least one profile before pushing to iCloud.")
                                    : "")
                        )
                        .accessibilityIdentifier("icloud-force-push-button")
                    }
                }
                .padding(AetherVisual.s4)
                .aetherPanel()
            }

            HStack {
                Spacer()
                Button(AppLocalization.string("Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .aetherButton(prominent: true)
                .accessibilityIdentifier("icloud-sync-done-button")
                .disabled(cloudSync.isSyncing)
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(cloudSync.isSyncing)
        .onExitCommand {
            if !cloudSync.isSyncing && pendingForceAction == nil {
                dismiss()
            }
        }
        .confirmationDialog(
            pendingForceAction == .pull
                ? AppLocalization.string("Overwrite local profiles with iCloud?")
                : AppLocalization.string("Overwrite iCloud archive with this Mac?"),
            isPresented: Binding(
                get: { pendingForceAction != nil },
                set: { if !$0 { pendingForceAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingForceAction
        ) { action in
            switch action {
            case .pull:
                Button(AppLocalization.string("Force Pull"), role: .destructive) {
                    runForcePull()
                }
                .accessibilityIdentifier("icloud-confirm-force-pull")
            case .push:
                Button(AppLocalization.string("Force Push"), role: .destructive) {
                    runForcePush()
                }
                .accessibilityIdentifier("icloud-confirm-force-push")
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {
                pendingForceAction = nil
            }
        } message: { action in
            switch action {
            case .pull:
                Text(AppLocalization.string("This replaces or merges local profiles using the encrypted iCloud snapshot, including deletions from other devices. Unsaved local changes may be lost."))
            case .push:
                Text(AppLocalization.string("This overwrites the encrypted iCloud archive with this Mac’s current profiles and deletion records, replacing newer changes from other devices."))
            }
        }
        .onAppear {
            cloudSync.refreshDiagnostics()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            cloudSync.refreshDiagnostics()
        }
    }

    private func runForcePull() {
        guard canRunCloudSyncActions else { return }
        Task {
            do {
                _ = try await cloudSync.forcePullFromCloud()
            } catch {
                cloudSync.recordFailureIfUnexplained(error, operation: .pull)
            }
        }
    }

    private func runForcePush() {
        guard canRunCloudSyncActions, !tunnel.profiles.isEmpty else { return }
        Task {
            do {
                _ = try await cloudSync.forcePushToCloud()
            } catch {
                cloudSync.recordFailureIfUnexplained(error, operation: .push)
            }
        }
    }

    private var accountDiagnosticsSection: some View {
        let diag = cloudSync.diagnostics
        let archiveSummary = archiveSummaryText(for: diag)
        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(alignment: .center, spacing: AetherVisual.s2) {
                Circle()
                    .fill(diag.isICloudAccountSignedIn ? AnyShapeStyle(Color.green) : AnyShapeStyle(AetherVisual.tertiaryText))
                    .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                Text(AppLocalization.string("iCloud Account:"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                Text(accountStatusText(for: diag))
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: AetherVisual.s2)
                if let fingerprint = diag.pairingFingerprint {
                    Text(AppLocalization.format("Pairing Code %@", fingerprint))
                        .font(.caption2.monospaced().weight(.semibold))
                        .foregroundStyle(AetherReadableTint(color: .blue))
                        .padding(.horizontal, AetherVisual.s2)
                        .padding(.vertical, AetherVisual.sMicro)
                        .background(
                            AetherVisual.neutralFill,
                            in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous)
                        )
                        .help(AppLocalization.string("Devices signed into the same Apple ID with iCloud Keychain enabled display the exact same pairing code."))
                        .accessibilityIdentifier("icloud-pairing-code")
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                Text(AppLocalization.string("Cloud Archive:"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                Text(archiveSummary)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .help(archiveSummary)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("icloud-account-diagnostics")
    }

    private func accountStatusText(for diag: CloudSyncDiagnosticsSnapshot) -> String {
        guard diag.isICloudAccountSignedIn else {
            return AppLocalization.string("Not signed in to iCloud")
        }
        if diag.isEncryptionKeyAvailable {
            return AppLocalization.string("Signed in · Keychain ready")
        }
        return AppLocalization.string("Signed in · Key generated on first upload")
    }

    private func archiveSummaryText(for diag: CloudSyncDiagnosticsSnapshot) -> String {
        guard let archive = diag.remoteArchive else {
            return AppLocalization.string("No archive in iCloud yet")
        }
        let sizeText = Int64(archive.payloadByteCount).formatted(
            .byteCount(style: .file).locale(AppLocalization.currentLocale)
        )
        if let count = archive.profileCount {
            return AppLocalization.format("%lld profiles · %@ · from %@", Int64(count), sizeText, archive.sourceDeviceName)
        }
        return AppLocalization.format("Encrypted archive · %@ · from %@", sizeText, archive.sourceDeviceName)
    }

    private func revealLocalStorageFolder() {
        actionErrorMessage = nil
        guard let folderURL = cloudSync.localStorageDirectoryURL() else {
            actionErrorMessage = AppLocalization.string("Could not open the local sync folder.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        } catch {
            actionErrorMessage = AppLocalization.string("Could not open the local sync folder.")
            return
        }
        if !NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: folderURL.path) {
            actionErrorMessage = AppLocalization.string("Could not open the local sync folder.")
        }
    }

    private func openSystemICloudSettings() {
        actionErrorMessage = nil
        let candidates = [
            "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings",
            "x-apple.systempreferences:"
        ]
        for raw in candidates {
            if let url = URL(string: raw), NSWorkspace.shared.open(url) {
                return
            }
        }
        actionErrorMessage = AppLocalization.string("Could not open System Settings.")
    }
}

extension ProfileCloudSyncManager {
    /// Keeps the specific status the manager set for a failure (such as the
    /// keychain hint) instead of replacing it with the bare error.
    func recordFailureIfUnexplained(_ error: Error, operation: CloudSyncStatus.Operation) {
        guard status?.isFailure != true else { return }
        status = .failed(operation, cloudError: error as? CloudSyncError, detail: error.localizedDescription)
    }
}

extension CloudSyncStatus {
    var localizedText: String {
        switch self {
        case .enableSyncFirst:
            AppLocalization.string("Turn on end-to-end encrypted iCloud sync first.")
        case .syncing:
            AppLocalization.string("Syncing with iCloud…")
        case .pulling:
            AppLocalization.string("Pulling profiles from iCloud…")
        case .pushing:
            AppLocalization.string("Uploading profiles to iCloud…")
        case let .merged(count):
            AppLocalization.format("Merged and synced both ways with iCloud (%lld profiles).", Int64(count))
        case let .pulledLatest(count):
            AppLocalization.format("Synced the latest profiles from iCloud (%lld profiles).", Int64(count))
        case let .uploaded(count):
            AppLocalization.format("Encrypted and uploaded this Mac's profiles to iCloud (%lld profiles).", Int64(count))
        case let .forcePulled(count):
            AppLocalization.format("Pulled profiles from iCloud (%lld profiles).", Int64(count))
        case let .forcePushed(count):
            AppLocalization.format("Pushed profiles to iCloud (%lld profiles).", Int64(count))
        case .noCloudData:
            AppLocalization.string("iCloud has no profiles yet. Turn on sync and upload on a Mac that has them.")
        case .noCloudArchive:
            AppLocalization.string("No profile archive in iCloud yet, or it has not reached this Mac. Try again shortly.")
        case .nothingToUpload:
            AppLocalization.string("There are no local profiles to upload.")
        case .keychainUnavailable:
            AppLocalization.string("The encryption key is unavailable. Turn on iCloud Passwords & Keychain in System Settings and wait a moment.")
        case .decryptionFailed:
            AppLocalization.string("Decryption failed. Make sure this Mac uses the same Apple ID with iCloud Keychain turned on.")
        case let .failed(operation, cloudError, detail):
            Self.failureText(operation, cause: cloudError?.localizedAppDescription ?? detail)
        }
    }

    private static func failureText(_ operation: Operation, cause: String) -> String {
        switch operation {
        case .sync: AppLocalization.format("Sync failed: %@", cause)
        case .upload: AppLocalization.format("Uploading to iCloud failed: %@", cause)
        case .pull: AppLocalization.format("Pull failed: %@", cause)
        case .push: AppLocalization.format("Push failed: %@", cause)
        }
    }
}

extension CloudSyncError {
    var localizedAppDescription: String {
        switch self {
        case .cloudUnavailable:
            AppLocalization.string("iCloud storage is unavailable. Sign in to iCloud and try again.")
        case .encryptionFailed:
            AppLocalization.string("The profiles could not be encrypted for iCloud.")
        case .decryptionFailed:
            AppLocalization.string("The profiles from iCloud could not be decrypted with this Mac's key.")
        case .catalogCorrupted:
            AppLocalization.string("The profiles in iCloud are damaged or failed their checksum.")
        case .keychainUnavailable:
            AppLocalization.string("The encryption key is not available in the keychain.")
        case .payloadTooLarge:
            AppLocalization.string("The profiles exceed the 1 MB iCloud limit.")
        }
    }
}

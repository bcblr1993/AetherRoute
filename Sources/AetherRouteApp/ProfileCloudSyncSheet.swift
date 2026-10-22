import AetherRouteKit
import SwiftUI

struct ProfileCloudSyncSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject private var cloudSync = ProfileCloudSyncManager.shared
    @Environment(\.dismiss) private var dismiss

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
                    .accessibilityIdentifier("icloud-sync-toggle")

                Text(AppLocalization.string("Profiles are encrypted with AES-256-GCM before being stored in iCloud. The encryption key is protected by iCloud Keychain and synchronizes across devices with the same Apple ID."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AetherVisual.s4)
            .background(AetherVisual.subtleFill, in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))

            if cloudSync.isCloudSyncEnabled {
                if cloudSync.isSyncing {
                    Label(AppLocalization.string("Syncing profiles…"), systemImage: "arrow.triangle.2.circlepath.icloud")
                } else if cloudSync.lastSyncedAt == nil {
                    Label(AppLocalization.string("Enabled · no completed sync yet"), systemImage: "clock")
                }
                Text(AppLocalization.string("Enabling sync does not confirm completion. Automatic sync merges profiles; review the result before using Force Pull or Force Push."))
                    .font(.caption).foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: AetherVisual.s3) {
                    if let status = cloudSync.status {
                        HStack(spacing: AetherVisual.s2) {
                            Image(systemName: status.isFailure ? "exclamationmark.triangle.fill" : "info.circle.fill")
                                .foregroundStyle(status.isFailure ? Color.orange : Color.accentColor)
                            Text(status.localizedText)
                                .font(.callout)
                                .foregroundStyle(.primary)
                        }
                    }

                    if let lastSync = cloudSync.lastSyncedAt {
                        HStack {
                            Text(AppLocalization.string("Last Synced:"))
                                .font(.caption)
                                .foregroundStyle(AetherVisual.secondaryText)
                            Text(lastSync.formatted(date: .abbreviated, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(AetherVisual.secondaryText)
                        }
                    }

                    Divider()

                    HStack(spacing: AetherVisual.s3) {
                        Button {
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
                        .disabled(cloudSync.isSyncing)
                        .accessibilityIdentifier("icloud-sync-now-button")

                        Button {
                            Task {
                                do {
                                    _ = try await cloudSync.forcePullFromCloud()
                                } catch {
                                    cloudSync.recordFailureIfUnexplained(error, operation: .pull)
                                }
                            }
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Image(systemName: "icloud.and.arrow.down")
                                Text(AppLocalization.string("Force Pull"))
                            }
                        }
                        .aetherButton()
                        .disabled(cloudSync.isSyncing)
                        .accessibilityIdentifier("icloud-force-pull-button")

                        Button {
                            Task {
                                do {
                                    _ = try await cloudSync.forcePushToCloud()
                                } catch {
                                    cloudSync.recordFailureIfUnexplained(error, operation: .push)
                                }
                            }
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Image(systemName: "icloud.and.arrow.up")
                                Text(AppLocalization.string("Force Push"))
                            }
                        }
                        .aetherButton()
                        .disabled(cloudSync.isSyncing || tunnel.profiles.isEmpty)
                        .accessibilityIdentifier("icloud-force-push-button")
                    }
                }
                .padding(AetherVisual.s4)
                .background(AetherVisual.subtleFill, in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
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
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(cloudSync.isSyncing)
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

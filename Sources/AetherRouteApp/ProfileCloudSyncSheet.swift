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
                    if let status = cloudSync.statusMessage {
                        HStack(spacing: AetherVisual.s2) {
                            Image(systemName: "info.circle.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(status)
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
                                    cloudSync.statusMessage = error.localizedDescription
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
                        .aetherGlassButton(prominent: true)
                        .disabled(cloudSync.isSyncing)
                        .accessibilityIdentifier("icloud-sync-now-button")

                        Button {
                            Task {
                                do {
                                    _ = try await cloudSync.forcePullFromCloud()
                                } catch {
                                    cloudSync.statusMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Image(systemName: "icloud.and.arrow.down")
                                Text(AppLocalization.string("Force Pull"))
                            }
                        }
                        .aetherGlassButton()
                        .disabled(cloudSync.isSyncing)
                        .accessibilityIdentifier("icloud-force-pull-button")

                        Button {
                            Task {
                                do {
                                    _ = try await cloudSync.forcePushToCloud()
                                } catch {
                                    cloudSync.statusMessage = error.localizedDescription
                                }
                            }
                        } label: {
                            HStack(spacing: AetherVisual.sCompact) {
                                Image(systemName: "icloud.and.arrow.up")
                                Text(AppLocalization.string("Force Push"))
                            }
                        }
                        .aetherGlassButton()
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
                .aetherGlassButton(prominent: true)
                .accessibilityIdentifier("icloud-sync-done-button")
                .disabled(cloudSync.isSyncing)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(cloudSync.isSyncing)
    }
}

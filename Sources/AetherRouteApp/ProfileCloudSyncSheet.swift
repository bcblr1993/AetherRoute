import AetherRouteKit
import SwiftUI

struct ProfileCloudSyncSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject private var cloudSync = ProfileCloudSyncManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            HStack(spacing: AetherVisual.s4) {
                Image(systemName: "icloud.fill")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 52, height: 52)
                    .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("iCloud Profile Sync"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.string("End-to-end encrypted synchronization across your Mac and iPhone devices."))
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: AetherVisual.s3) {
                Toggle(AppLocalization.string("Enable iCloud Sync"), isOn: $cloudSync.isCloudSyncEnabled)
                    .toggleStyle(.switch)
                    .accessibilityIdentifier("icloud-sync-toggle")

                Text(AppLocalization.string("Profiles are encrypted with AES-256-GCM before being stored in iCloud. The encryption key is protected by iCloud Keychain and synchronizes across devices with the same Apple ID."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(AetherVisual.s4)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))

            if cloudSync.isCloudSyncEnabled {
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
                                .foregroundStyle(.secondary)
                            Text(lastSync.formatted(date: .abbreviated, time: .standard))
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }

                    Divider().opacity(0.4)

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
                        .buttonStyle(.borderedProminent)
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
                        .buttonStyle(.bordered)
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
                        .buttonStyle(.bordered)
                        .disabled(cloudSync.isSyncing || tunnel.profiles.isEmpty)
                        .accessibilityIdentifier("icloud-force-push-button")
                    }
                }
                .padding(AetherVisual.s4)
                .background(Color.secondary.opacity(0.04), in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius))
            }

            HStack {
                Spacer()
                Button(AppLocalization.string("Done")) {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("icloud-sync-done-button")
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(width: 520)
    }
}

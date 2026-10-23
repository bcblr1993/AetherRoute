import AetherRouteKit
import AppKit
import SwiftUI

/// Settings > About: removes the network extensions and configurations that
/// dragging the app to the Trash leaves behind, then the app itself.
struct AppUninstallSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var isConfirming = false

    var body: some View {
        Section {
            Button(role: .destructive) {
                isConfirming = true
            } label: {
                Label(AppLocalization.string("Uninstall AetherRoute…"), systemImage: "trash")
            }
            .accessibilityIdentifier("about-uninstall")
        } footer: {
            Text(AppLocalization.string("Removes the network extensions and their configurations, which moving the app to the Trash leaves behind."))
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
        }
        .sheet(isPresented: $isConfirming) {
            AppUninstallSheet()
                .environmentObject(tunnel)
        }
    }
}

struct AppUninstallSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var tunnel: TunnelManager
    @State private var deletesUserData = true
    @State private var isRunning = false
    @State private var report: UninstallReport?

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "trash",
                title: AppLocalization.string("Uninstall AetherRoute"),
                subtitle: AppLocalization.string("Disconnects, removes network extensions and configurations, and cleans up all data on this Mac."),
                tint: .red
            )
            if let report {
                resultView(report)
            } else {
                Toggle(
                    AppLocalization.string("Also delete profiles, rules and settings on this Mac"),
                    isOn: $deletesUserData
                )
                .toggleStyle(AetherRowToggleStyle())
                .disabled(isRunning)
                Text(AppLocalization.string("macOS may ask for an administrator password to remove the extensions. Profiles synced through iCloud stay in iCloud."))
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: AetherVisual.s2) {
                Spacer()
                if let report {
                    Button(report.networkRemovalFailed
                           ? AppLocalization.string("Close")
                           : AppLocalization.string("Done")) {
                        if !report.networkRemovalFailed {
                            AppUninstallPerformer.removeAppAndTerminate()
                        } else {
                            dismiss()
                        }
                    }
                    .aetherButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button(AppLocalization.string("Cancel"), role: .cancel) { dismiss() }
                        .aetherButton()
                        .keyboardShortcut(.cancelAction)
                        .disabled(isRunning)
                    Button(role: .destructive) {
                        uninstall()
                    } label: {
                        AetherProgressButtonLabel(AppLocalization.string("Uninstall"), isWorking: isRunning)
                    }
                    .aetherButton(prominent: true)
                    .disabled(isRunning)
                    .accessibilityIdentifier("uninstall-confirm")
                }
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherSheetFrame()
        .interactiveDismissDisabled(isRunning)
    }

    @ViewBuilder
    private func resultView(_ report: UninstallReport) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            if report.networkRemovalFailed {
                AetherInlineMessage(
                    text: AppLocalization.string("Some network components could not be removed, so AetherRoute was kept. Uninstall again; if it keeps failing, restart your Mac and retry."),
                    kind: .warning
                )
            } else {
                Label {
                    Text(Self.successText(report))
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(AetherReadableTint(color: .green))
                }
                .font(.callout)
            }
            ForEach(Array(report.failures.enumerated()), id: \.offset) { _, entry in
                if case let .failed(reason) = entry.outcome {
                    Text(verbatim: "• \(Self.title(of: entry.step)): \(reason)")
                        .font(.callout)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("uninstall-result")
    }

    private static func successText(_ report: UninstallReport) -> String {
        var text = AppLocalization.string("AetherRoute has been uninstalled. Click Done to close and remove the app.")
        if report.needsRestart {
            text += " " + AppLocalization.string("Restart your Mac to finish removing its network extensions.")
        }
        return text
    }

    private func uninstall() {
        isRunning = true
        let plan = AppUninstaller.plan(
            deletingUserData: deletesUserData,
            extensionIdentifiers: AppUninstallPerformer.extensionIdentifiers
        )
        let performer = AppUninstallPerformer(tunnel: tunnel)
        Task {
            report = await AppUninstaller.run(plan, performer: performer)
            isRunning = false
        }
    }

    private static func title(of step: UninstallStep) -> String {
        switch step {
        case .disconnect: AppLocalization.string("Disconnect")
        case .removeNetworkConfigurations: AppLocalization.string("Network configurations")
        case let .deactivateExtension(identifier):
            identifier.hasSuffix(".transparent-proxy")
                ? AppLocalization.string("Transparent proxy extension")
                : AppLocalization.string("TUN extension")
        case .unregisterLoginItem: AppLocalization.string("Login item")
        case .deleteUserData: AppLocalization.string("Profiles and settings")
        case .moveAppToTrash: AppLocalization.string("Move to Trash")
        }
    }
}

#if AETHERROUTE_INDEPENDENT
/// App menu entry: opens Settings > About, where Uninstall lives.
struct UninstallCommandButton: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(AppLocalization.string("Uninstall AetherRoute…")) {
            openSettings()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: .aetherRouteNavigateToSettings, object: "about")
            }
        }
    }
}
#endif

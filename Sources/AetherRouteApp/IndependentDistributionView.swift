import AetherRouteKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IndependentDistributionView: View {
    @EnvironmentObject private var distribution:
        IndependentDistributionController
    @State private var licenseKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                header
                if distribution.isFreeDistribution {
                    freeEditionCard
                } else {
                    licenseCard
                    updateCard
                    privacyFooter
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .task { distribution.loadLocalReceipt() }
        .accessibilityIdentifier("independent-distribution-view")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Text(AppLocalization.string(distribution.isFreeDistribution ? "Free Edition" : "License & Updates"))
                .font(.title2.weight(.semibold))
            Text(AppLocalization.string(distribution.isFreeDistribution
                 ? "AetherRoute is free to use. Import your own proxy configuration to get started."
                 : "AetherRoute verifies signed license receipts and update manifests without storing your activation key."))
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var freeEditionCard: some View {
        distributionCard {
            Label("No activation required", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
            Text("This edition does not contact a licensing service. Install a newer signed DMG to update; your saved configurations are kept.")
                .font(.body)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("free-edition-status")
    }

    private var licenseCard: some View {
        distributionCard {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                statusIcon(
                    symbol: licenseSymbol,
                    tint: licenseTint
                )
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("License")
                        .font(.headline)
                    Text(licenseTitle)
                        .font(.subheadline.weight(.medium))
                    Text(licenseDetail)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if hasStoredLicense {
                    Menu {
                        Button("Refresh License") {
                            Task { await distribution.refreshLicense() }
                        }
                        Button("Deactivate This Mac", role: .destructive) {
                            Task { await distribution.deactivate() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(distribution.isActivating)
                    .accessibilityLabel("License actions")
                }
            }

            if let message = distribution.licenseMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("license-service-message")
            }

            if distribution.isConfigured && !hasStoredLicense {
                Divider()
                HStack(spacing: AetherVisual.s3) {
                    SecureField("License key", text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("license-key-field")
                        .onSubmit { activate() }
                    Button {
                        activate()
                    } label: {
                        AetherProgressButtonLabel(
                            "Activate",
                            isWorking: distribution.isActivating
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        distribution.isActivating
                            || licenseKey.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty
                    )
                }
            }
        }
    }

    private var updateCard: some View {
        distributionCard {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                statusIcon(symbol: updateSymbol, tint: updateTint)
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text("Software Updates")
                        .font(.headline)
                    Text(updateTitle)
                        .font(.subheadline.weight(.medium))
                    Text(updateDetail)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if case let .available(manifest) = distribution.updateState {
                    Button {
                        saveVerifiedUpdate(manifest)
                    } label: {
                        AetherProgressButtonLabel(
                            "Download & Verify",
                            isWorking: distribution.isDownloadingUpdate
                        )
                    }
                    .buttonStyle(.bordered)
                    .disabled(distribution.isDownloadingUpdate)
                    .accessibilityIdentifier("download-update-button")
                } else {
                    Button {
                        Task { await distribution.checkForUpdates() }
                    } label: {
                        AetherProgressButtonLabel(
                            "Check Now",
                            isWorking: distribution.isCheckingForUpdates
                        )
                    }
                    .disabled(
                        !distribution.isConfigured
                            || distribution.isCheckingForUpdates
                    )
                    .accessibilityIdentifier("check-for-updates-button")
                }
            }
            if let message = distribution.updateDownloadMessage {
                Label(
                    message,
                    systemImage: distribution.updateDownloadSucceeded
                        ? "checkmark.shield.fill"
                        : "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(
                    distribution.updateDownloadSucceeded
                        ? Color.green
                        : Color.orange
                )
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("update-download-message")
            }
        }
    }

    private var privacyFooter: some View {
        Label {
            Text("The activation key is sent only to your configured HTTPS license service and is never saved, logged, exported, or included in diagnostics. Receipts stay in the Data Protection Keychain on this Mac.")
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.accentColor)
        }
        .font(.body.weight(.medium))
        .foregroundStyle(.primary)
        .padding(.horizontal, AetherVisual.s1)
    }

    private func distributionCard<Content: View>(
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4, content: content)
            .padding(AetherVisual.s5)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
            }
    }

    private func statusIcon(symbol: String, tint: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 36, height: 36)
            .background(
                tint.opacity(0.11),
                in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private func activate() {
        let submittedKey = licenseKey
        licenseKey = ""
        Task {
            let succeeded = await distribution.activate(
                licenseKey: submittedKey
            )
            if !succeeded {
                licenseKey = ""
            }
        }
    }

    private func saveVerifiedUpdate(_ manifest: SoftwareUpdateManifest) {
        let panel = NSSavePanel()
        panel.title = AppLocalization.string("Save Verified Update")
        panel.prompt = AppLocalization.string("Download & Verify")
        panel.allowedContentTypes = [.diskImage]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue =
            "AetherRoute-\(manifest.version)-arm64.dmg"
        guard panel.runModal() == .OK, let destinationURL = panel.url else {
            return
        }
        Task {
            guard let fileURL = await distribution.downloadUpdate(
                manifest,
                to: destinationURL
            ) else { return }
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    private var hasStoredLicense: Bool {
        switch distribution.licenseState {
        case .active, .restricted: true
        default: false
        }
    }

    private var licenseSymbol: String {
        switch distribution.licenseState {
        case .active: "checkmark.seal.fill"
        case .restricted: "exclamationmark.triangle.fill"
        case .failure: "xmark.octagon.fill"
        case .inactive: "key.fill"
        case .notConfigured: "wrench.and.screwdriver.fill"
        }
    }

    private var licenseTint: Color {
        switch distribution.licenseState {
        case .active: Color.green
        case .restricted: .orange
        case .failure: .red
        case .inactive: .blue
        case .notConfigured: .secondary
        }
    }

    private var licenseTitle: String {
        switch distribution.licenseState {
        case .notConfigured:
            AppLocalization.string("License service not configured")
        case .inactive:
            AppLocalization.string("No license is active on this Mac")
        case .active:
            AppLocalization.string("License active")
        case let .restricted(entitlement):
                String.localizedStringWithFormat(
                    AppLocalization.string("License %@"),
                    localizedLicenseState(entitlement.state)
            )
        case .failure:
            AppLocalization.string("License unavailable")
        }
    }

    private var licenseDetail: String {
        switch distribution.licenseState {
        case .notConfigured:
            AppLocalization.string("Development builds remain unlocked until your signed licensing service is configured for release.")
        case .inactive:
            AppLocalization.string("Enter a license key to activate this Mac. The key is cleared from memory after the request.")
        case let .active(entitlement):
            entitlement.expiresAt.map {
                String.localizedStringWithFormat(
                    AppLocalization.string("Valid until %@"),
                    AppLocalization.date(
                        $0,
                        date: .abbreviated,
                        time: .omitted
                    )
                )
            } ?? AppLocalization.string("No expiration date")
        case let .restricted(entitlement):
                String.localizedStringWithFormat(
                    AppLocalization.string("The signed receipt reports %@. Contact support before moving this license."),
                    localizedLicenseState(entitlement.state)
            )
        case let .failure(message):
            message
        }
    }

    private var updateSymbol: String {
        switch distribution.updateState {
        case .available: "arrow.down.circle.fill"
        case .current: "checkmark.circle.fill"
        case .failure: "exclamationmark.triangle.fill"
        case .idle: "arrow.triangle.2.circlepath"
        case .notConfigured: "wrench.and.screwdriver.fill"
        }
    }

    private var updateTint: Color {
        switch distribution.updateState {
        case .available: .blue
        case .current: Color.green
        case .failure: .red
        case .idle: .blue
        case .notConfigured: .secondary
        }
    }

    private var updateTitle: String {
        switch distribution.updateState {
        case .notConfigured:
            AppLocalization.string("Update service not configured")
        case .idle:
            AppLocalization.string("Ready to check")
        case .current:
            AppLocalization.string("AetherRoute is up to date")
        case let .available(manifest):
            String.localizedStringWithFormat(
                AppLocalization.string("AetherRoute %@ is available"),
                manifest.version
            )
        case .failure:
            AppLocalization.string("Update check failed")
        }
    }

    private var updateDetail: String {
        switch distribution.updateState {
        case .notConfigured:
            AppLocalization.string("Release builds require a signed HTTPS manifest owned by you.")
        case .idle:
            AppLocalization.string("Only a bounded, Ed25519-signed manifest is accepted. Downloads never install automatically.")
        case let .current(date):
            String.localizedStringWithFormat(
                AppLocalization.string("Last checked %@"),
                AppLocalization.date(
                    date,
                    date: .abbreviated,
                    time: .shortened
                )
            )
        case let .available(manifest):
            String.localizedStringWithFormat(
                AppLocalization.string("Build %lld · arm64 · published %@"),
                Int64(manifest.build),
                AppLocalization.date(
                    manifest.publishedAt,
                    date: .abbreviated,
                    time: .omitted
                )
            )
        case let .failure(message):
            message
        }
    }

    private func localizedLicenseState(
        _ state: LicenseEntitlementState
    ) -> String {
        switch state {
        case .active: AppLocalization.string("active")
        case .expired: AppLocalization.string("expired")
        case .revoked: AppLocalization.string("revoked")
        case .deviceLimit: AppLocalization.string("device limit reached")
        }
    }
}

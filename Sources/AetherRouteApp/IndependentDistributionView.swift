import AetherRouteKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IndependentDistributionView: View {
    @EnvironmentObject private var distribution:
        IndependentDistributionController
    @ObservedObject private var sparkle = SparkleUpdaterController.shared
    @State private var licenseKey = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                header
                if distribution.isFreeDistribution {
                    freeEditionCard
                    sparkleUpdateCard
                } else {
                    licenseCard
                    sparkleUpdateCard
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
            Label {
                Text(AppLocalization.string("No activation required"))
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }
            .font(.headline)
            .foregroundStyle(.primary)
            Text(AppLocalization.string("This edition does not contact a licensing service. Software updates are checked and verified automatically."))
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
                    Text(AppLocalization.string("License"))
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
                        Button(AppLocalization.string("Refresh License")) {
                            Task { await distribution.refreshLicense() }
                        }
                        Button(AppLocalization.string("Deactivate This Mac"), role: .destructive) {
                            Task { await distribution.deactivate() }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(distribution.isActivating)
                    .accessibilityLabel(AppLocalization.string("License actions"))
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
                    SecureField(AppLocalization.string("License key"), text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("license-key-field")
                        .onSubmit { activate() }
                    Button {
                        activate()
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Activate"),
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

    private var sparkleUpdateCard: some View {
        distributionCard {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                statusIcon(symbol: "arrow.triangle.2.circlepath", tint: Color.accentColor)
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Software Updates"))
                        .font(.headline)
                    Text(currentVersionDescription)
                        .font(.subheadline.weight(.medium))
                    Text(lastCheckDescription)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Button {
                    sparkle.checkForUpdates()
                } label: {
                    Text(AppLocalization.string("Check Now"))
                }
                .buttonStyle(.bordered)
                .disabled(!sparkle.canCheckForUpdates)
                .accessibilityIdentifier("check-for-updates-button")
            }

            Divider().opacity(0.3)

            Toggle(isOn: Binding(
                get: { sparkle.automaticallyChecksForUpdates },
                set: { sparkle.setAutomaticallyChecksForUpdates($0) }
            )) {
                Text(AppLocalization.string("Automatically check for updates"))
                    .font(.subheadline)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
        }
    }

    private var currentVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return String.localizedStringWithFormat(
            AppLocalization.string("Version %@ (Build %@)"),
            version,
            build
        )
    }

    private var lastCheckDescription: String {
        if let lastDate = sparkle.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: lastDate, relativeTo: Date())
            return String.localizedStringWithFormat(
                AppLocalization.string("Last checked %@. Updates are signed with Ed25519."),
                relative
            )
        } else {
            return AppLocalization.string("Automatic checks enabled. Updates are cryptographically signed with Ed25519.")
        }
    }

    private var privacyFooter: some View {
        Label {
            Text(AppLocalization.string("The activation key is sent only to your configured HTTPS license service and is never saved, logged, exported, or included in diagnostics. Receipts stay in the Data Protection Keychain on this Mac."))
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

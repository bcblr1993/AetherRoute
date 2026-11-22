import AetherRouteKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct IndependentDistributionView: View {
    @EnvironmentObject private var distribution:
        IndependentDistributionController
    @ObservedObject private var sparkle = SparkleUpdaterController.shared
    @State private var licenseKey = ""
    @State private var isConfirmingDeactivation = false
    @State private var hasStoredReceipt = false
    /// Embedded in About, which already names the product and version: the
    /// free edition then shows only software updates.
    var isEmbedded = false

    var body: some View {
#if AETHERROUTE_APP_STORE
        EmptyView()
#else
        Group {
            if isEmbedded {
                embeddedContent
            } else {
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
            }
        }
        .task {
            distribution.loadLocalReceipt()
            await refreshStoredReceiptPresence()
        }
        .onChange(of: distribution.licenseState) { _, _ in
            Task { await refreshStoredReceiptPresence() }
        }
        .confirmationDialog(
            AppLocalization.string("Deactivate this Mac?"),
            isPresented: $isConfirmingDeactivation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Deactivate"), role: .destructive) {
                Task { await distribution.deactivate() }
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("This releases this Mac's activation seat and removes the local license receipt. You will need to enter your license key again to connect."))
        }
        // No identifier here: embedded, this view is several form sections,
        // and one identifier was copied onto every row they contain.
#endif
    }

    /// About in Settings: grouped-form sections. The free edition shows only
    /// software updates; a licensed build adds its license first.
    @ViewBuilder
    private var embeddedContent: some View {
        if !distribution.isFreeDistribution {
            Section {
                licenseCard
                privacyFooter
            } header: {
                Text(AppLocalization.string("License"))
            }
        }
        Section {
            HStack(spacing: AetherVisual.s3) {
                // The section header already says "Software Updates".
                Text(lastCheckDescription)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: AetherVisual.s2)
                Button(AppLocalization.string("Check Now")) {
                    sparkle.checkForUpdates()
                }
                .disabled(!sparkle.canCheckOrFocusUpdateSession)
                .accessibilityIdentifier("check-for-updates-button")
            }
            Toggle(AppLocalization.string("Automatically check for updates"), isOn: Binding(
                get: { sparkle.automaticallyChecksForUpdates },
                set: { sparkle.setAutomaticallyChecksForUpdates($0) }
            ))
            .toggleStyle(AetherRowToggleStyle())
        } header: {
            Text(AppLocalization.string("Software Updates"))
        }
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
                    .foregroundStyle(AetherReadableTint(color: .green))
            }
            .font(.headline)
            .foregroundStyle(.primary)
            Text(AppLocalization.string("This edition does not contact a licensing service. Every software update is verified before it is installed."))
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
                Spacer(minLength: AetherVisual.s3)
                if hasStoredLicense {
                    Menu {
                        Button(AppLocalization.string("Refresh License")) {
                            Task { await distribution.refreshLicense() }
                        }
                        Button(AppLocalization.string("Deactivate This Mac"), role: .destructive) {
                            isConfirmingDeactivation = true
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
                AetherInlineMessage(text: message, kind: .warning, isCompact: true)
                    .accessibilityIdentifier("license-service-message")
            }

            if distribution.isConfigured && !hasStoredLicense {
                Divider()
                HStack(spacing: AetherVisual.s3) {
                    SecureField(AppLocalization.string("License key"), text: $licenseKey)
                        .textFieldStyle(.roundedBorder)
                        .disabled(distribution.isActivating)
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
                    .aetherButton(prominent: true)
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
                    // About already shows the version and build above.
                    if !isEmbedded {
                        Text(currentVersionDescription)
                            .font(.subheadline.weight(.medium))
                    }
                    Text(lastCheckDescription)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AetherVisual.s3)
                Button {
                    sparkle.checkForUpdates()
                } label: {
                    Text(AppLocalization.string("Check Now"))
                }
                .aetherButton()
                .disabled(!sparkle.canCheckOrFocusUpdateSession)
                .accessibilityIdentifier("check-for-updates-button")
            }

            Divider()

            Toggle(isOn: Binding(
                get: { sparkle.automaticallyChecksForUpdates },
                set: { sparkle.setAutomaticallyChecksForUpdates($0) }
            )) {
                Text(AppLocalization.string("Automatically check for updates"))
            }
            // A labelled switch is a row: label leading, regular switch
            // trailing, as in the Settings forms.
            .toggleStyle(AetherRowToggleStyle())
        }
    }

    private var currentVersionDescription: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return AppLocalization.format(
            "Version %@ (Build %@)",
            version,
            build
        )
    }

    private var lastCheckDescription: String {
        if let lastDate = sparkle.lastUpdateCheckDate {
            let formatter = RelativeDateTimeFormatter()
            formatter.locale = AppLocalization.currentLocale
            formatter.unitsStyle = .full
            let relative = formatter.localizedString(for: lastDate, relativeTo: Date())
            return AppLocalization.format(
                "Last checked %@. Updates are signed with Ed25519.",
                relative
            )
        } else {
            // Say what the toggle below actually says.
            return sparkle.automaticallyChecksForUpdates
                ? AppLocalization.string("Automatic checks enabled. Updates are cryptographically signed with Ed25519.")
                : AppLocalization.string("Automatic checks are off. Updates are cryptographically signed with Ed25519.")
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
            .padding(AetherVisual.cardPadding)
            .aetherPanel()
    }

    private func statusIcon(symbol: String, tint: Color) -> some View {
        AetherStatusSymbol(symbol: symbol, color: tint)
    }

    private func activate() {
        let submittedKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !distribution.isActivating, !submittedKey.isEmpty else { return }
        licenseKey = ""
        Task {
            let succeeded = await distribution.activate(
                licenseKey: submittedKey
            )
            if !succeeded {
                licenseKey = ""
            }
            await refreshStoredReceiptPresence()
        }
    }

    private var hasStoredLicense: Bool {
        switch distribution.licenseState {
        case .active, .restricted: true
        case .failure: hasStoredReceipt
        default: false
        }
    }

    private func refreshStoredReceiptPresence() async {
        let present = await Task.detached(priority: .utility) {
            (try? DataProtectionDistributionCredentialStore().loadReceipt()) != nil
        }.value
        hasStoredReceipt = present
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
        case .active: .green
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
            AppLocalization.format(
                "License %@",
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
                AppLocalization.format(
                    "Valid until %@",
                    AppLocalization.date(
                        $0,
                        date: .abbreviated,
                        time: .omitted
                    )
                )
            } ?? AppLocalization.string("No expiration date")
        case let .restricted(entitlement):
            AppLocalization.format(
                "The signed receipt reports %@. Contact support before moving this license.",
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

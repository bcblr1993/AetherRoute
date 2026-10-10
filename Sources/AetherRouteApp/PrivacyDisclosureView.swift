import SwiftUI

/// The privacy commitments. First run shows them as a welcome page with the
/// consent button; Settings shows one summary row whose "Show…" opens the
/// same page in a sheet.
struct PrivacyDisclosureView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let isOnboarding: Bool
    /// Settings: the one-row summary inside the Privacy & Diagnostics form.
    var isEmbedded = false
    /// The full page shown as a sheet from Settings: a Done button replaces
    /// the consent bar.
    var isSheet = false
    @Environment(\.dismiss) private var dismiss
    @State private var showsCommitments = false

    var body: some View {
        if isEmbedded {
            summaryRow
        } else {
            fullPage
        }
    }

    // MARK: Settings summary

    private var summaryRow: some View {
        Section {
            HStack(spacing: AetherVisual.s3) {
                AetherIconTile(symbol: "checkmark.shield.fill", color: .blue, size: AetherVisual.rowTileSize)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Privacy commitments"))
                        .foregroundStyle(.primary)
                    Text(AppLocalization.string("Privacy commitments summary"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: AetherVisual.s2)
                consentBadge
                Button(AppLocalization.string("Show…")) {
                    showsCommitments = true
                }
                .accessibilityIdentifier("privacy-commitments-show")
            }
            .padding(.vertical, AetherVisual.sMicro)
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $showsCommitments) {
                PrivacyDisclosureView(isOnboarding: false, isSheet: true)
                    .environmentObject(tunnel)
                    .aetherLargeSheetFrame()
            }
        } header: {
            Text(AppLocalization.string("Privacy"))
        }
    }

    @ViewBuilder
    private var consentBadge: some View {
        if tunnel.hasAcceptedPrivacyDisclosure {
            Label {
                Text(AppLocalization.string("Accepted"))
                    .foregroundStyle(.primary)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundStyle(AetherReadableTint(color: .green))
            }
            .font(.callout)
            .accessibilityIdentifier("privacy-consent-accepted")
        } else {
            Text(AppLocalization.string("Not accepted"))
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
        }
    }

    // MARK: Full page

    /// First-run page 1, and the same page as a sheet from Settings: the
    /// commitments as one card, in the shared first-run layout.
    private var fullPage: some View {
        OnboardingPage(
            page: isSheet ? nil : 0,
            title: AppLocalization.string("Private by default"),
            lead: AppLocalization.string("AetherRoute does one thing: forward your traffic by your rules."),
            footnote: AppLocalization.string("Subscription updates contact your provider; rule updates come from public sources after you connect.")
                + " " + AppLocalization.string("Only import subscriptions from providers you trust."),
            accessibilityIdentifier: "privacy-disclosure"
        ) {
            OnboardingPrivacyIllustration()
        } content: {
            OnboardingCard(rows: commitmentRows)
        } actions: {
            actionArea
        }
    }

    /// The four promises, then where data goes once connected: shown, not
    /// tucked behind a link.
    private var commitmentRows: [OnboardingCardRow] {
        PrivacyFact.allCases.map { fact in
            OnboardingCardRow(id: "privacy-\(fact.id)", symbol: fact.symbol, title: fact.title, detail: fact.detail)
        } + [
            OnboardingCardRow(
                id: "privacy-data-flow",
                symbol: "arrow.triangle.branch",
                title: AppLocalization.string("Your proxy and DNS"),
                detail: AppLocalization.string("They forward your traffic and queries, and can see your IP address.")
            ),
        ]
    }

    @ViewBuilder
    private var actionArea: some View {
        if isSheet {
            HStack(spacing: AetherVisual.s4) {
                consentBadge
                Button {
                    dismiss()
                } label: {
                    Text(AppLocalization.string("Done"))
                        .frame(minWidth: AetherVisual.onboardingButtonWidth / 3)
                }
                .aetherGlassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-sheet-done")
            }
        } else if isOnboarding && !tunnel.hasAcceptedPrivacyDisclosure {
            VStack(spacing: AetherVisual.s2) {
                OnboardingPrimaryButton(
                    title: AppLocalization.string("Agree and Continue"),
                    identifier: "privacy-consent-button",
                    action: {
                        Task { await tunnel.acceptPrivacyDisclosure() }
                    }
                )
                .accessibilityHint(Text(AppLocalization.string("Nothing is configured or connected until you continue.")))
                Text(AppLocalization.string("Nothing is configured or connected until you continue."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum PrivacyFact: CaseIterable, Identifiable {
    case onDevice
    case nothingReported
    case noAds
    case neverSold

    var id: Self { self }

    var symbol: String {
        switch self {
        case .onDevice: "laptopcomputer"
        case .nothingReported: "antenna.radiowaves.left.and.right.slash"
        case .noAds: "eye.slash"
        case .neverSold: "tag.slash"
        }
    }

    var title: String {
        switch self {
        case .onDevice: AppLocalization.string("On this Mac")
        case .nothingReported: AppLocalization.string("Nothing reported")
        case .noAds: AppLocalization.string("No ads")
        case .neverSold: AppLocalization.string("Never sold")
        }
    }

    var detail: String {
        switch self {
        case .onDevice: AppLocalization.string("Routing decisions happen on your Mac.")
        case .nothingReported: AppLocalization.string("Connection and traffic stats stay here.")
        case .noAds: AppLocalization.string("No profiling and no trackers.")
        case .neverSold: AppLocalization.string("Your network data is never sold.")
        }
    }
}

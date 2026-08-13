import SwiftUI

struct PrivacyDisclosureView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let isOnboarding: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: AetherVisual.s5) {
                disclosureHeader
                disclosurePoints
                destinationNotice
                if !usesPinnedConsent {
                    consentStatus
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(
                .top,
                isOnboarding
                    ? AetherVisual.onboardingTopPadding
                    : AetherVisual.pageTopPadding
            )
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: isOnboarding ? .infinity : AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesPinnedConsent {
                consentStatus
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AetherVisual.s6)
                    .padding(.vertical, AetherVisual.s3)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .overlay(alignment: .top) {
                        Divider()
                    }
            }
        }
    }

    private var usesPinnedConsent: Bool {
        isOnboarding && !tunnel.hasAcceptedPrivacyDisclosure
    }

    private var disclosureHeader: some View {
        VStack(spacing: AetherVisual.s4) {
            ZStack(alignment: .bottomTrailing) {
                AetherRouteBrandTile(size: 76)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 27, height: 27)
                    .background(.regularMaterial, in: Circle())
                    .offset(x: 4, y: 4)
            }
            .frame(width: 76, height: 76)
            .accessibilityHidden(true)

            VStack(spacing: AetherVisual.s2) {
                Text("Your Network Privacy")
                    .font(.title2.weight(.semibold))
                Text(disclosureSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var disclosureSubtitle: LocalizedStringKey {
        isOnboarding
            ? "Before AetherRoute can configure a network extension, review how your network data is handled."
            : "How AetherRoute handles network data"
    }

    @ViewBuilder
    private var disclosurePoints: some View {
        if isOnboarding {
            HStack(alignment: .top, spacing: AetherVisual.s4) {
                ForEach(NetworkPrivacyPoint.allCases) { point in
                    PrivacyPointCard(point: point)
                }
            }
        } else {
            VStack(spacing: AetherVisual.s3) {
                ForEach(NetworkPrivacyPoint.allCases) { point in
                    PrivacyPointRow(point: point)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var destinationNotice: some View {
        HStack(alignment: .top, spacing: AetherVisual.s4) {
            Image(systemName: "arrow.up.right.square")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                Text("Your selected services receive traffic")
                    .font(.headline)
                    .accessibilityValue(
                        Text("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in the profile you chose. Subscription updates contact the selected provider. If a release configures licensing, AetherRoute refreshes only its signed device receipt with the owner's HTTPS license service after you accept this disclosure. These services may observe your IP address. Review and trust a provider before importing it.")
                    )
                Text("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in the profile you chose. Subscription updates contact the selected provider. If a release configures licensing, AetherRoute refreshes only its signed device receipt with the owner's HTTPS license service after you accept this disclosure. These services may observe your IP address. Review and trust a provider before importing it.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s5)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var consentStatus: some View {
        if tunnel.hasAcceptedPrivacyDisclosure {
            // Consent granted is a passing state, so it takes the same green as
            // a connected route rather than the accent, which owns selection.
            Label("Privacy disclosure accepted on this Mac", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .padding(.top, AetherVisual.s1)
                .accessibilityIdentifier("privacy-consent-accepted")
        } else {
            VStack(spacing: AetherVisual.s3) {
                Button {
                    Task { await tunnel.acceptPrivacyDisclosure() }
                } label: {
                    Label("I Understand and Continue", systemImage: "checkmark.shield.fill")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 230)
                        .padding(.vertical, AetherVisual.s1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-consent-button")
                .accessibilityHint(
                    Text("AetherRoute will not create or save a network extension configuration, import or download a profile, or connect until you agree.")
                )

                Text("AetherRoute will not create or save a network extension configuration, import or download a profile, or connect until you agree.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityHidden(true)
            }
        }
    }
}

private enum NetworkPrivacyPoint: CaseIterable, Identifiable {
    case onDevice
    case noTracking
    case userControlled

    var id: Self { self }

    var symbol: String {
        switch self {
        case .onDevice: "macbook"
        case .noTracking: "eye.slash"
        case .userControlled: "slider.horizontal.3"
        }
    }

    var title: String {
        switch self {
        case .onDevice: AppLocalization.string("Processed on this Mac")
        case .noTracking: AppLocalization.string("No sale or tracking")
        case .userControlled: AppLocalization.string("You choose the route")
        }
    }

    var detail: String {
        switch self {
        case .onDevice:
            AppLocalization.string("AetherRoute processes proxy profiles, network destinations, addresses, and routing decisions locally on this Mac.")
        case .noTracking:
            AppLocalization.string("AetherRoute does not sell network data, build advertising profiles, or include behavioral trackers.")
        case .userControlled:
            AppLocalization.string("Only the proxy and DNS services in the profile you select receive forwarded traffic or queries.")
        }
    }
}

private struct PrivacyPointRow: View {
    let point: NetworkPrivacyPoint

    var body: some View {
        HStack(alignment: .top, spacing: AetherVisual.s4) {
            Image(systemName: point.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(point.title)
                    .font(.headline)
                    .accessibilityValue(Text(point.detail))
                Text(point.detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        // Fill before the panel is applied, so the three points share one right
        // edge with each other and with the notice below them.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s4)
        .aetherPanel()
    }
}

private struct PrivacyPointCard: View {
    let point: NetworkPrivacyPoint

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Image(systemName: point.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.secondary)
            Text(point.title)
                .font(.headline)
                .accessibilityValue(Text(point.detail))
            Text(point.detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(width: 185, alignment: .topLeading)
        .frame(minHeight: 156, alignment: .topLeading)
        .padding(AetherVisual.s5)
        .aetherPanel()
    }
}

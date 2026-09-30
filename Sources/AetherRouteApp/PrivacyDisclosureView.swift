import SwiftUI

struct PrivacyDisclosureView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let isOnboarding: Bool
    /// Settings shows the same commitments as a compact section, without the
    /// first-run hero or its own scroll view.
    var isEmbedded = false
    @State private var showsPrivacyDetails = false

    var body: some View {
        if isEmbedded {
            embeddedContent
        } else {
            fullPage
        }
    }

    private var embeddedContent: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Privacy"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.string("How AetherRoute handles network data"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            disclosurePoints
                .padding(AetherVisual.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .aetherPanel()
            HStack(spacing: AetherVisual.s4) {
                Button {
                    withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) {
                        showsPrivacyDetails.toggle()
                    }
                } label: {
                    Label("Privacy details", systemImage: "chevron.right")
                        .labelStyle(DisclosureLabelStyle(isExpanded: showsPrivacyDetails))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.accentColor)
                .accessibilityIdentifier("privacy-details-toggle")
                Spacer()
                consentStatus
            }
            if showsPrivacyDetails {
                destinationNotice
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var fullPage: some View {
        ScrollView {
            VStack(alignment: .center, spacing: AetherVisual.s6) {
                disclosureHeader
                // The three commitments are the page; hiding them behind a
                // toggle left two thirds of the first-run window empty.
                disclosurePoints
                VStack(spacing: AetherVisual.s3) {
                    Button {
                        withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) {
                            showsPrivacyDetails.toggle()
                        }
                    } label: {
                        Label("Privacy details", systemImage: "chevron.right")
                            .labelStyle(DisclosureLabelStyle(isExpanded: showsPrivacyDetails))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityIdentifier("privacy-details-toggle")
                    if showsPrivacyDetails {
                        destinationNotice
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                if !usesPinnedConsent {
                    consentStatus
                }
            }
            .padding(.horizontal, AetherVisual.s6)
            .padding(.top, isOnboarding ? AetherVisual.onboardingTopPadding : AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.s6)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesPinnedConsent {
                consentStatus
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AetherVisual.s6)
                    .padding(.vertical, AetherVisual.s4)
                    .background(.regularMaterial)
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
        VStack(spacing: AetherVisual.s3) {
            ZStack(alignment: .bottomTrailing) {
                AetherRouteBrandTile(size: 72)

                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [AetherVisual.portalLight, AetherVisual.portalMid],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.body.weight(.bold))
                        .foregroundStyle(.white)
                }
                .offset(x: 5, y: 5)
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)

            VStack(spacing: AetherVisual.s2) {
                Text(AppLocalization.string("Your Network Privacy"))
                    .font(.largeTitle.weight(.bold))
                    .foregroundStyle(.primary)
                Text(disclosureSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, AetherVisual.s1)
        }
        .frame(maxWidth: .infinity)
    }

    private var disclosureSubtitle: String {
        isOnboarding
            ? AppLocalization.string("Before AetherRoute can configure a network extension, review how your network data is handled.")
            : AppLocalization.string("How AetherRoute handles network data")
    }

    private var disclosurePoints: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s5) {
            ForEach(NetworkPrivacyPoint.allCases) { point in
                PrivacyPointRow(point: point)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    private var destinationNotice: some View {
        HStack(alignment: .top, spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.title2.weight(.medium))
                    .foregroundStyle(.orange)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Your selected services receive traffic"))
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .accessibilityValue(
                        Text(AppLocalization.string("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in your profile. Subscription updates contact your provider; routing rule updates contact public data sources after connection. These services may observe your IP address. Review and trust a provider before importing it."))
                    )
                Text(AppLocalization.string("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in your profile. Subscription updates contact your provider; routing rule updates contact public data sources after connection. These services may observe your IP address. Review and trust a provider before importing it."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AetherVisual.s4)
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .fill(Color.orange.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .stroke(Color.orange.opacity(0.15), lineWidth: 1)
        )
    }

    @ViewBuilder
    private var consentStatus: some View {
        if tunnel.hasAcceptedPrivacyDisclosure {
            Label(AppLocalization.string("Privacy disclosure accepted on this Mac"), systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.green)
                .padding(.top, AetherVisual.s1)
                .accessibilityIdentifier("privacy-consent-accepted")
        } else {
            VStack(spacing: AetherVisual.s2) {
                Button {
                    Task { await tunnel.acceptPrivacyDisclosure() }
                } label: {
                    HStack(spacing: AetherVisual.s2) {
                        Image(systemName: "checkmark.shield.fill")
                        Text(AppLocalization.string("I Understand and Continue"))
                    }
                    .font(.title3.weight(.semibold))
                    .frame(minWidth: 220)
                    .padding(.vertical, AetherVisual.s1)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-consent-button")
                .accessibilityHint(
                    Text(AppLocalization.string("AetherRoute will not create or save a network extension configuration, import or download a profile, or connect until you agree."))
                )

                Text(AppLocalization.string("AetherRoute will not create or save a network extension configuration, import or download a profile, or connect until you agree."))
                    .font(.caption)
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
        case .noTracking: "hand.raised.slash.fill"
        case .userControlled: "point.filled.topleft.down.curvedto.point.bottomright.up"
        }
    }

    var colors: [Color] {
        switch self {
        case .onDevice:
            [Color.blue, Color.blue.opacity(0.75)]
        case .noTracking:
            [Color.indigo, Color.indigo.opacity(0.75)]
        case .userControlled:
            [Color.teal, Color.teal.opacity(0.75)]
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
                .font(.title.weight(.regular))
                .foregroundStyle(point.colors[0])
                .frame(width: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(point.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .accessibilityValue(Text(point.detail))
                Text(point.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
    }
}

/// A plain disclosure label whose chevron turns as it opens.
private struct DisclosureLabelStyle: LabelStyle {
    let isExpanded: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AetherVisual.s1) {
            configuration.title
            configuration.icon
                .font(.caption.weight(.semibold))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .animation(AetherVisual.animation(AetherVisual.quickFade), value: isExpanded)
        }
    }
}

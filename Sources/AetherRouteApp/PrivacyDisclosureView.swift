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
                    .shadow(color: Color.accentColor.opacity(0.2), radius: 10, x: 0, y: 5)

                ZStack {
                    Circle()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .frame(width: 28, height: 28)
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.blue, Color(red: 0.0, green: 0.55, blue: 1.0)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 24, height: 24)
                    Image(systemName: "checkmark.shield.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .offset(x: 5, y: 5)
            }
            .frame(width: 72, height: 72)
            .accessibilityHidden(true)

            VStack(spacing: AetherVisual.s2) {
                Text(AppLocalization.string("Your Network Privacy"))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Text(disclosureSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
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
        VStack(spacing: 0) {
            ForEach(Array(NetworkPrivacyPoint.allCases.enumerated()), id: \.element.id) { index, point in
                PrivacyPointRow(point: point)
                if index < NetworkPrivacyPoint.allCases.count - 1 {
                    Divider()
                        .padding(.leading, AetherVisual.wideListIndent + AetherVisual.s4)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }

    private var destinationNotice: some View {
        HStack(alignment: .top, spacing: AetherVisual.s3) {
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                    .fill(Color.orange.opacity(0.12))
                Image(systemName: "arrow.up.right.square.fill")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
            }
            .frame(width: 32, height: 32)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(AppLocalization.string("Your selected services receive traffic"))
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityValue(
                        Text(AppLocalization.string("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in your profile. Subscription updates contact your provider; routing rule updates contact public data sources after connection. These services may observe your IP address. Review and trust a provider before importing it."))
                    )
                Text(AppLocalization.string("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in your profile. Subscription updates contact your provider; routing rule updates contact public data sources after connection. These services may observe your IP address. Review and trust a provider before importing it."))
                    .font(.system(size: 12))
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
                    .font(.system(size: 14, weight: .semibold))
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
            [Color(red: 0.12, green: 0.53, blue: 1.0), Color(red: 0.0, green: 0.68, blue: 0.95)]
        case .noTracking:
            [Color(red: 0.48, green: 0.38, blue: 0.96), Color(red: 0.68, green: 0.38, blue: 0.92)]
        case .userControlled:
            [Color(red: 0.02, green: 0.72, blue: 0.62), Color(red: 0.15, green: 0.82, blue: 0.50)]
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
            ZStack {
                RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: point.colors,
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: point.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 38, height: 38)
            .shadow(color: point.colors[0].opacity(0.3), radius: 4, x: 0, y: 2)

            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(point.title)
                    .font(.system(size: 14.5, weight: .semibold))
                    .foregroundStyle(.primary)
                    .accessibilityValue(Text(point.detail))
                Text(point.detail)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
    }
}

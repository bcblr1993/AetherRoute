import SwiftUI

struct PrivacyDisclosureView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let isOnboarding: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: isOnboarding ? 26 : 20) {
                disclosureHeader
                disclosurePoints
                destinationNotice
                if !usesPinnedConsent {
                    consentStatus
                }
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, isOnboarding ? 42 : AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if usesPinnedConsent {
                consentStatus
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
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
        VStack(spacing: 15) {
            ZStack(alignment: .bottomTrailing) {
                AetherRouteBrandTile(size: 78)
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 27, height: 27)
                    .background(.regularMaterial, in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
                    .offset(x: 4, y: 4)
            }
            .frame(width: 78, height: 78)
            .shadow(color: AetherVisual.blue.opacity(0.16), radius: 18, y: 9)
            .accessibilityHidden(true)

            VStack(spacing: 7) {
                Text("Your Network Privacy")
                    .font(isOnboarding ? .largeTitle.weight(.semibold) : .title2.weight(.semibold))
                Text(disclosureSubtitle)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var disclosureSubtitle: LocalizedStringKey {
        isOnboarding
            ? "Before AetherRoute can configure a network extension, review how your network data is handled."
            : "How AetherRoute handles network data"
    }

    @ViewBuilder
    private var disclosurePoints: some View {
        if isOnboarding {
            HStack(alignment: .top, spacing: 14) {
                ForEach(NetworkPrivacyPoint.allCases) { point in
                    PrivacyPointCard(point: point)
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(NetworkPrivacyPoint.allCases) { point in
                    PrivacyPointRow(point: point)
                }
            }
        }
    }

    private var destinationNotice: some View {
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: "arrow.up.right.square")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 26)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("Your selected services receive traffic")
                    .font(.headline)
                    .accessibilityValue(
                        Text("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in the profile you chose. Subscription updates contact the selected provider. If a release configures licensing, AetherRoute refreshes only its signed device receipt with the owner's HTTPS license service after you accept this disclosure. These services may observe your IP address. Review and trust a provider before importing it.")
                    )
                Text("When you connect, traffic and DNS queries may be sent to the proxy and DNS services in the profile you chose. Subscription updates contact the selected provider. If a release configures licensing, AetherRoute refreshes only its signed device receipt with the owner's HTTPS license service after you accept this disclosure. These services may observe your IP address. Review and trust a provider before importing it.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(18)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(Color.orange.opacity(0.18), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var consentStatus: some View {
        if tunnel.hasAcceptedPrivacyDisclosure {
            Label("Privacy disclosure accepted on this Mac", systemImage: "checkmark.seal.fill")
                .font(.headline)
                .foregroundStyle(.teal)
                .padding(.top, 2)
                .accessibilityIdentifier("privacy-consent-accepted")
        } else {
            VStack(spacing: 11) {
                Button {
                    Task { await tunnel.acceptPrivacyDisclosure() }
                } label: {
                    Label("I Understand and Continue", systemImage: "checkmark.shield.fill")
                        .font(.body.weight(.semibold))
                        .frame(minWidth: 230)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-consent-button")
                .accessibilityHint(
                    Text("AetherRoute will not create or save a network extension configuration, import or download a profile, or connect until you agree.")
                )

                Text("AetherRoute will not create or save a network extension configuration, import or download a profile, or connect until you agree.")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
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
        HStack(alignment: .top, spacing: 13) {
            Image(systemName: point.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.teal)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(point.title)
                    .font(.headline)
                    .accessibilityValue(Text(point.detail))
                Text(point.detail)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityHidden(true)
            }
        }
        .padding(15)
        .aetherPanel(radius: 13)
    }
}

private struct PrivacyPointCard: View {
    let point: NetworkPrivacyPoint

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Image(systemName: point.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(.teal)
            Text(point.title)
                .font(.headline)
                .accessibilityValue(Text(point.detail))
            Text(point.detail)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .frame(width: 185, alignment: .topLeading)
        .frame(minHeight: 156, alignment: .topLeading)
        .padding(18)
        .aetherPanel(radius: 15)
    }
}

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
    @State private var hasAppeared = false

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
                AetherIconTile(symbol: "checkmark.shield.fill", color: .blue, size: 28)
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
                    .frame(width: 620, height: 600)
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
                    .foregroundStyle(.green)
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

    /// Liquid Glass layout: plain content in glass cards, and the action as a
    /// floating glass capsule the content scrolls beneath — no opaque bar.
    private var fullPage: some View {
        ScrollView {
            VStack(spacing: AetherVisual.s5) {
                header
                factGrid
                dataFlow
                Text(AppLocalization.string("Only import subscriptions from providers you trust."))
                    .font(.footnote)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: 560)
            .padding(.horizontal, AetherVisual.s6)
            .padding(.top, isSheet ? AetherVisual.s5 : AetherVisual.s6)
            .padding(.bottom, AetherVisual.s4)
            .frame(maxWidth: .infinity)
        }
        .modifier(FloatingBottomBar { actionArea })
        .onAppear { hasAppeared = true }
    }

    private var header: some View {
        VStack(spacing: AetherVisual.s3) {
            AetherIconTile(symbol: "checkmark.shield.fill", color: .blue, size: 56)
                .scaleEffect(hasAppeared ? 1 : 0.8)
                .opacity(hasAppeared ? 1 : 0)
                .animation(AetherVisual.animation(AetherVisual.panelSpring), value: hasAppeared)
            Text(AppLocalization.string("Private by default"))
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(.primary)
            Text(AppLocalization.string("AetherRoute does one thing: forward your traffic by your rules."))
                .font(.body)
                .foregroundStyle(AetherVisual.secondaryText)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Four short facts, like an App Store privacy label, in cards of equal
    /// height that fit their text.
    private var factGrid: some View {
        HStack(alignment: .top, spacing: AetherVisual.s2) {
            ForEach(Array(PrivacyFact.allCases.enumerated()), id: \.element) { index, fact in
                VStack(spacing: AetherVisual.s2) {
                    AetherIconTile(symbol: fact.symbol, color: fact.color, size: 34)
                    VStack(spacing: AetherVisual.sMicro) {
                        Text(fact.title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(fact.detail)
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.vertical, AetherVisual.s3)
                .padding(.horizontal, AetherVisual.s2)
                .aetherGlass(in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous))
                .accessibilityElement(children: .contain)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 12)
                .animation(
                    AetherVisual.animation(AetherVisual.panelSpring.delay(0.1 + Double(index) * 0.06)),
                    value: hasAppeared
                )
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Where data goes once connected: shown, not tucked behind a link.
    private var dataFlow: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Text(AppLocalization.string("Once connected, data goes only here"))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AetherVisual.secondaryText)
                .accessibilityAddTraits(.isHeader)
            VStack(alignment: .leading, spacing: 0) {
                flowNode(
                    symbol: "laptopcomputer", color: .gray,
                    title: AppLocalization.string("Your Mac"),
                    detail: AppLocalization.string("AetherRoute decides where each connection goes.")
                )
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AetherVisual.tertiaryText)
                    .frame(width: 28)
                    .padding(.vertical, AetherVisual.s1)
                    .accessibilityHidden(true)
                flowNode(
                    symbol: "arrow.triangle.branch", color: .green,
                    title: AppLocalization.string("Your proxy and DNS"),
                    detail: AppLocalization.string("They forward your traffic and queries, and can see your IP address.")
                )
                Divider().padding(.vertical, AetherVisual.s3)
                Label {
                    Text(AppLocalization.string("Subscription updates contact your provider; rule updates come from public sources after you connect."))
                        .font(.callout)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .foregroundStyle(AetherVisual.secondaryText)
                }
            }
            .padding(AetherVisual.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .aetherGlass(in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous))
        }
        .opacity(hasAppeared ? 1 : 0)
        .animation(AetherVisual.animation(AetherVisual.panelSpring.delay(0.35)), value: hasAppeared)
    }

    private func flowNode(symbol: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            AetherIconTile(symbol: symbol, color: color, size: 28)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// The floating action: a glass capsule over the scrolling content.
    @ViewBuilder
    private var actionArea: some View {
        if isSheet {
            HStack {
                consentBadge
                    .padding(.horizontal, AetherVisual.s3)
                    .padding(.vertical, AetherVisual.s2)
                    .aetherGlass(in: Capsule())
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Text(AppLocalization.string("Done"))
                        .frame(minWidth: 80)
                }
                .aetherGlassButton(prominent: true)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-sheet-done")
            }
            .padding(.horizontal, AetherVisual.s5)
            .padding(.bottom, AetherVisual.s4)
        } else if isOnboarding && !tunnel.hasAcceptedPrivacyDisclosure {
            VStack(spacing: AetherVisual.s2) {
                Button {
                    Task { await tunnel.acceptPrivacyDisclosure() }
                } label: {
                    Text(AppLocalization.string("Agree and Continue"))
                        .font(.title3.weight(.semibold))
                        .frame(minWidth: 240)
                        .padding(.vertical, AetherVisual.s1)
                }
                .aetherGlassButton(prominent: true)
                .controlSize(.extraLarge)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("privacy-consent-button")
                .accessibilityHint(Text(AppLocalization.string("Nothing is configured or connected until you continue.")))

                Text(AppLocalization.string("Nothing is configured or connected until you continue."))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, AetherVisual.s5)
        }
    }
}

/// The floating action as a macOS 26 safe-area bar: content scrolls beneath
/// it and softly blurs out, as under the system's own glass toolbars.
private struct FloatingBottomBar<Bar: View>: ViewModifier {
    @ViewBuilder var bar: () -> Bar

    func body(content: Content) -> some View {
        if #available(macOS 26, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) { bar() }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                bar().background(.regularMaterial)
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
        case .noAds: "eye.slash.fill"
        case .neverSold: "tag.slash.fill"
        }
    }

    var color: Color {
        switch self {
        case .onDevice: .blue
        case .nothingReported: .purple
        case .noAds: .pink
        case .neverSold: .orange
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

import SwiftUI

/// The first-run pages share one layout: an illustration, a centred question
/// and lead, a card of what is being granted, a footnote, one primary action
/// and the page dots. The page centres in the window and scrolls when the
/// window is too short for it.
struct OnboardingPage<Illustration: View, Content: View, Actions: View>: View {
    /// Zero-based; `nil` hides the dots (the same page opened as a sheet).
    var page: Int?
    var pageCount = OnboardingPageDots.firstRunPageCount
    let title: String
    let lead: String
    var footnote: String?
    /// Names the page for UI automation; it lands on the scroll view, the
    /// page's one container that accessibility reports.
    var accessibilityIdentifier: String?
    @ViewBuilder var illustration: Illustration
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    /// Height of the floating action bar, so the rest centres above it.
    @State private var barHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: AetherVisual.s6) {
                    Spacer(minLength: AetherVisual.s4)
                    illustration
                        .accessibilityHidden(true)
                    VStack(spacing: AetherVisual.s2) {
                        Text(title)
                            .font(.largeTitle.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        Text(lead)
                            .font(.body)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        content
                        if let footnote {
                            Text(footnote)
                                .font(.caption)
                                .foregroundStyle(AetherVisual.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, AetherVisual.s3)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: AetherVisual.onboardingCardWidth)
                    Spacer(minLength: AetherVisual.s4)
                }
                .padding(.horizontal, AetherVisual.s6)
                .frame(maxWidth: .infinity)
                .frame(minHeight: max(0, proxy.size.height - barHeight))
            }
            .accessibilityIdentifier(accessibilityIdentifier ?? "")
            // The action stays in reach in the smallest window: the page
            // scrolls beneath it instead of pushing it out of sight.
            .modifier(OnboardingActionBar(barHeight: $barHeight) {
                VStack(spacing: AetherVisual.s3) {
                    actions
                    if let page {
                        OnboardingPageDots(page: page, count: pageCount)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, AetherVisual.s3)
                .padding(.bottom, AetherVisual.s5)
            })
        }
    }
}

/// The floating action as a macOS 26 safe-area bar: content scrolls beneath
/// it and softly blurs out, as under the system's own glass toolbars.
private struct OnboardingActionBar<Bar: View>: ViewModifier {
    @Binding var barHeight: CGFloat
    @ViewBuilder var bar: () -> Bar

    func body(content: Content) -> some View {
        let measured = bar()
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
        if #available(macOS 26, *) {
            content
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .safeAreaBar(edge: .bottom, spacing: 0) { measured }
        } else {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                measured.background(.regularMaterial)
            }
        }
    }
}

/// Where the first run stands, as dots under the primary action.
struct OnboardingPageDots: View {
    /// Privacy, network permissions, all set.
    static let firstRunPageCount = 3

    let page: Int
    let count: Int

    var body: some View {
        HStack(spacing: AetherVisual.s2) {
            ForEach(0..<count, id: \.self) { index in
                Circle()
                    .fill(index == page ? AnyShapeStyle(Color.primary) : AnyShapeStyle(AetherVisual.neutralFill))
                    .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
            }
        }
        // Read as text, so it has a role and says where the first run is.
        .accessibilityRepresentation {
            Text(AppLocalization.format("Page %lld of %lld", Int64(page + 1), Int64(count)))
        }
        .accessibilityIdentifier("onboarding-page-dots")
    }
}

/// The large primary action of a first-run page.
struct OnboardingPrimaryButton: View {
    let title: String
    var isWorking = false
    var isEnabled = true
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: AetherVisual.s2) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(title)
            }
            .font(.title3.weight(.semibold))
            .frame(minWidth: AetherVisual.onboardingButtonWidth)
            .padding(.vertical, AetherVisual.s1)
            .contentTransition(.opacity)
        }
        .aetherButton(prominent: true)
        .controlSize(.extraLarge)
        .keyboardShortcut(.defaultAction)
        .disabled(!isEnabled)
        .accessibilityIdentifier(identifier)
    }
}

/// One thing being granted or promised, drawn as a row of the card.
struct OnboardingCardRow: Identifiable {
    enum Accessory {
        case none
        case granted
        case waiting
        case action(title: String, identifier: String, perform: () -> Void)
        case retry(title: String, identifier: String, perform: () -> Void)
        case unavailable
        case restartNeeded
    }

    let id: String
    let symbol: String
    let title: String
    var detail: String?
    var detailIsError = false
    var accessory: Accessory = .none
}

/// The grouped card of a first-run page: rows separated by inset hairlines,
/// each with its state on the trailing edge.
struct OnboardingCard: View {
    let rows: [OnboardingCardRow]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Divider()
                        .padding(.leading, AetherVisual.onboardingRowDividerInset)
                }
                OnboardingCardRowView(row: row)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .aetherPanel()
    }
}

private struct OnboardingCardRowView: View {
    let row: OnboardingCardRow

    var body: some View {
        HStack(alignment: .center, spacing: AetherVisual.s3) {
            Image(systemName: row.symbol)
                .font(.title3)
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(width: AetherVisual.rowTileSize, height: AetherVisual.rowTileSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                Text(row.title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                if let detail = row.detail {
                    Text(detail)
                        .font(.callout)
                        .foregroundStyle(row.detailIsError
                            ? AnyShapeStyle(AetherReadableTint(color: .red))
                            : AnyShapeStyle(AetherVisual.secondaryText))
                        .fixedSize(horizontal: false, vertical: true)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: AetherVisual.s3)
            accessory
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .frame(minHeight: AetherVisual.twoLineRowHeight)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboarding-row-\(row.id)")
    }

    @ViewBuilder
    private var accessory: some View {
        switch row.accessory {
        case .none:
            EmptyView()
        case .granted:
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.green)
                .symbolEffect(.bounce, value: true)
                .accessibilityLabel(AppLocalization.string("Ready"))
                .accessibilityIdentifier("onboarding-row-\(row.id)-granted")
                .transition(.scale.combined(with: .opacity))
        case .waiting:
            ProgressView()
                .controlSize(.small)
                .accessibilityLabel(AppLocalization.string("Waiting for you"))
        case let .action(title, identifier, perform):
            Button(title, action: perform)
                .aetherButton(prominent: true)
                .controlSize(.regular)
                .accessibilityIdentifier(identifier)
        case let .retry(title, identifier, perform):
            Button(title, systemImage: "arrow.clockwise", action: perform)
                .aetherButton()
                .controlSize(.regular)
                .accessibilityIdentifier(identifier)
        case .unavailable:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(AetherReadableTint(color: .orange))
                .accessibilityLabel(AppLocalization.string("Unavailable"))
        case .restartNeeded:
            Image(systemName: "arrow.clockwise.circle.fill")
                .font(.title2)
                .foregroundStyle(AetherReadableTint(color: .orange))
                .accessibilityLabel(AppLocalization.string("Restart needed"))
        }
    }
}

// MARK: Illustrations

/// A small window drawn in outline: traffic lights and lines of content, for
/// the illustrations. `symbol` sits in the middle when given.
private struct OnboardingMiniWindow: View {
    var symbol: String?
    var symbolColor: Color = .accentColor
    var isHighlighted = false
    var width: CGFloat = 132
    var height: CGFloat = 92

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            HStack(spacing: AetherVisual.sMicro + AetherVisual.sMicro) {
                ForEach([Color.red, Color.orange, Color.green], id: \.self) { color in
                    Circle()
                        .fill(color)
                        .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                }
            }
            ZStack {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    ForEach(0..<4, id: \.self) { line in
                        Capsule()
                            .fill(AetherVisual.neutralFill)
                            .frame(width: width * (line.isMultiple(of: 2) ? 0.62 : 0.44), height: AetherVisual.s1)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if let symbol {
                    Image(systemName: symbol)
                        .font(.largeTitle.weight(.semibold))
                        .foregroundStyle(symbolColor.gradient)
                }
            }
        }
        .padding(AetherVisual.s2)
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(isHighlighted ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color(nsColor: .separatorColor)),
                        lineWidth: isHighlighted ? 2 : 1)
        }
    }
}

/// Page 1: a window that stays on this Mac, between two quieter ones.
struct OnboardingPrivacyIllustration: View {
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            OnboardingMiniWindow()
                .rotationEffect(.degrees(-8))
                .offset(x: -96, y: AetherVisual.s2)
            OnboardingMiniWindow()
                .rotationEffect(.degrees(8))
                .offset(x: 96, y: AetherVisual.s2)
            OnboardingMiniWindow(symbol: "lock.shield.fill", isHighlighted: true, width: 156, height: 108)
                .scaleEffect(hasAppeared ? 1 : 0.92)
        }
        .frame(height: AetherVisual.onboardingIllustrationHeight)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) { hasAppeared = true }
        }
    }
}

/// Page 2: AetherRoute between the two network engines it sets up.
struct OnboardingNetworkIllustration: View {
    @State private var hasAppeared = false

    var body: some View {
        HStack(spacing: -AetherVisual.s2) {
            AetherIconTile(symbol: "laptopcomputer", color: .gray, size: AetherVisual.sheetIconSize)
                .rotationEffect(.degrees(-10))
            AetherIconTile(symbol: "bolt.shield.fill", color: .blue, size: AetherVisual.heroTileSize)
                .rotationEffect(.degrees(-4))
            AetherRouteBrandTile(size: AetherVisual.brandHeroSize)
                .zIndex(1)
                .scaleEffect(hasAppeared ? 1 : 0.9)
            AetherIconTile(symbol: "server.rack", color: .indigo, size: AetherVisual.heroTileSize)
                .rotationEffect(.degrees(4))
            AetherIconTile(symbol: "globe", color: .teal, size: AetherVisual.sheetIconSize)
                .rotationEffect(.degrees(10))
        }
        .frame(height: AetherVisual.onboardingIllustrationHeight)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(AetherVisual.animation(AetherVisual.panelSpring)) { hasAppeared = true }
        }
    }
}

/// Page 3: AetherRoute with a check, ready to go.
struct OnboardingDoneIllustration: View {
    @State private var hasAppeared = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            AetherRouteBrandTile(size: AetherVisual.brandHeroSize)
            Image(systemName: "checkmark.circle.fill")
                .font(.largeTitle)
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.white, Color.green)
                .background(Color(nsColor: .windowBackgroundColor), in: Circle())
                .offset(x: AetherVisual.s2, y: AetherVisual.s2)
                .scaleEffect(hasAppeared ? 1 : 0.4)
                .opacity(hasAppeared ? 1 : 0)
        }
        .frame(height: AetherVisual.onboardingIllustrationHeight)
        .onAppear {
            withAnimation(AetherVisual.animation(AetherVisual.panelSpring.delay(0.15))) { hasAppeared = true }
        }
    }
}

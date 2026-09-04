import SwiftUI

enum AetherVisual {
    // Brand colors are identity-only. Runtime state always uses system
    // semantic colors so accessibility and accent-color preferences win.
    // The palette shares a family with the system accent so the app reads as a
    // native network tool; the known cost is that brand and selection sit close
    // together, which is why brand color appears only in the sidebar header and
    // never carries state.
    static let portalLight = Color(red: 0.298, green: 0.659, blue: 1.0)
    static let portalMid = Color(red: 0.039, green: 0.431, blue: 0.980)
    static let portalDark = Color(red: 0.035, green: 0.259, blue: 0.659)
    // Four-point spacing grid from the final design handoff.
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    static let controlRadius: CGFloat = 6
    static let insetRadius: CGFloat = 8
    static let panelRadius: CGFloat = 12

    // MARK: - Motion
    //
    // A shared motion vocabulary so state changes read as one system instead
    // of each view inventing its own timing. Durations stay short because this
    // is a utility app: motion should explain what changed, never make the
    // user wait for it. All of these respect Reduce Motion through
    // `AetherVisual.animation(_:)`.

    /// Status changes, badges, and inline text swaps.
    static let quickFade = Animation.easeOut(duration: 0.18)
    /// Default for layout and value changes that should feel physical.
    static let gentleSpring = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// Larger surfaces: panel swaps, list reflow, section reveals.
    static let panelSpring = Animation.spring(response: 0.42, dampingFraction: 0.88)

    /// Returns `animation` unless the user asked for reduced motion, in which
    /// case state still changes but does so without travel.
    static func animation(_ animation: Animation) -> Animation? {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            ? nil
            : animation
    }

    static let pageHorizontalPadding = s5
    static let pageTopPadding = s5
    static let pageBottomPadding = s6
    static let sectionSpacing = s4
    static let contentMaxWidth: CGFloat = 704
    static let formMaxWidth: CGFloat = 704
    static let sidebarWidth: CGFloat = 236
    static let windowWidth: CGFloat = 940
    static let windowHeight: CGFloat = 640
    static let popoverWidth: CGFloat = 330
    /// Sheet content follows the final dialog handoff rather than the page
    /// spacing grid.
    static let dialogPadding: CGFloat = 26
    static let onboardingTopPadding = s6 + s5
    static let wideListIndent = s6 * 2 + s2
    static let tableContentIndent = s6 * 3

    static let brandGradient = LinearGradient(
        colors: [portalLight, portalMid, portalDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Material.regular

    static func panelFill(for _: ColorScheme) -> Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func panelBorder(for _: ColorScheme) -> Color {
        Color(nsColor: .separatorColor)
    }
}

/// The adopted channel mark: two arcs forming a tunnel, with the route arrow
/// passing through and out. It is authored on the same grid and stroke weight
/// as the shipped app icon, so the sidebar, settings and status surfaces stay
/// in register with the icon in the Dock.
struct AetherRouteGlyph: View {
    var isActive = false
    var isOnColor = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let strokeWidth = max(1.4, side * Self.strokeUnits / Self.gridSide)

            ZStack {
                channelArc(side: side, rightSide: false)
                    .stroke(markStyle, style: channelStroke(strokeWidth))

                // The far wall of the channel is held back so the two arcs read
                // as one tunnel seen in perspective rather than as a ring.
                channelArc(side: side, rightSide: true)
                    .stroke(markStyle, style: channelStroke(strokeWidth))
                    .opacity(0.45)

                routeArrow(side: side)
                    .stroke(markStyle, style: channelStroke(strokeWidth))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .shadow(
                color: isActive ? glowColor.opacity(0.28) : .clear,
                radius: side * 0.055
            )
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    // The mark is authored on the same 96-unit grid as the app icon, so the
    // sidebar and the icon in the Dock stay in register.
    private static let gridSide: CGFloat = 96
    private static let strokeUnits: CGFloat = 13
    private static let arcTop: CGFloat = 14
    private static let arcRadius: CGFloat = 38

    private func channelArc(side: CGFloat, rightSide: Bool) -> Path {
        Path { path in
            let chordX: CGFloat = rightSide ? 64 : 32
            let halfChord = (Self.gridSide - 2 * Self.arcTop) / 2
            let offset = sqrt(
                Self.arcRadius * Self.arcRadius - halfChord * halfChord
            )
            let center = point(
                rightSide ? chordX - offset : chordX + offset,
                Self.gridSide / 2,
                side: side
            )
            // Half-sweep measured from the bulge direction out to the chord,
            // which picks the minor arc the icon specification calls for.
            let sweep = atan2(halfChord, offset)
            let through: CGFloat = rightSide ? 0 : .pi
            path.addRelativeArc(
                center: center,
                radius: Self.arcRadius / Self.gridSide * side,
                startAngle: .radians(through - sweep),
                delta: .radians(2 * sweep)
            )
        }
    }

    private func routeArrow(side: CGFloat) -> Path {
        Path { path in
            let axis = Self.gridSide / 2
            path.move(to: point(18, axis, side: side))
            path.addLine(to: point(58, axis, side: side))
            path.move(to: point(50, axis - 15, side: side))
            path.addLine(to: point(66, axis, side: side))
            path.addLine(to: point(50, axis + 15, side: side))
        }
    }

    private var markStyle: LinearGradient {
        LinearGradient(
            colors: isOnColor
                ? [Color.white, Color.white.opacity(0.90)]
                : [AetherVisual.portalLight, AetherVisual.portalMid, AetherVisual.portalDark],
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func channelStroke(_ width: CGFloat) -> StrokeStyle {
        StrokeStyle(
            lineWidth: width,
            lineCap: .round,
            lineJoin: .round
        )
    }

    private var glowColor: Color {
        isOnColor ? .white : AetherVisual.portalLight
    }

    /// Maps a point on the 96-unit design grid into the glyph's square box.
    private func point(
        _ x: CGFloat,
        _ y: CGFloat,
        side: CGFloat
    ) -> CGPoint {
        CGPoint(
            x: x / Self.gridSide * side,
            y: y / Self.gridSide * side
        )
    }
}

struct AetherRouteBrandTile: View {
    var size: CGFloat = 32
    var isActive = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.255, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            AetherVisual.portalLight,
                            AetherVisual.portalMid,
                            AetherVisual.portalDark,
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            // The highlight has to be painted *into* the tile shape. As a bare
            // RadialGradient it filled the square frame instead, so the part
            // outside the rounded corner showed up as a pale square nub against
            // the window background.
            RoundedRectangle(cornerRadius: size * 0.255, style: .continuous)
                .fill(
                    RadialGradient(
                        colors: [Color.white.opacity(0.30), Color.clear],
                        center: UnitPoint(x: 0.24, y: 0.16),
                        startRadius: 0,
                        endRadius: size * 0.68
                    )
                )
            // 664 graphic safe area inside an 824 tile, matching the exported
            // icon exactly so the sidebar mark and the Dock icon register.
            AetherRouteGlyph(isActive: isActive, isOnColor: true)
                .padding(size * 0.097)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.255, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.42), Color.white.opacity(0.08)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(0.55, size * 0.014)
                )
        }
        .shadow(color: AetherVisual.portalDark.opacity(0.20), radius: size * 0.10, y: size * 0.045)
        .accessibilityLabel("AetherRoute")
    }
}

/// A state-bearing rendition of the brand mark for connection surfaces. It
/// keeps status semantic (color plus label) and avoids repeating the app icon
/// as decoration inside the main window.
struct AetherRouteStatusLens: View {
    @Environment(\.colorScheme) private var colorScheme

    var size: CGFloat = 52
    var isActive = false

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            AetherVisual.portalLight.opacity(colorScheme == .dark ? 0.16 : 0.11),
                            AetherVisual.portalMid.opacity(colorScheme == .dark ? 0.10 : 0.055),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            AetherVisual.portalLight.opacity(isActive ? 0.42 : 0.20),
                            AetherVisual.portalDark.opacity(isActive ? 0.22 : 0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.75
                )

            AetherRouteGlyph(isActive: isActive)
                .padding(size * 0.17)
        }
        .frame(width: size, height: size)
        .shadow(
            color: AetherVisual.portalLight.opacity(isActive ? 0.13 : 0.035),
            radius: isActive ? 12 : 5
        )
        .accessibilityHidden(true)
    }
}

private struct AetherPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                AetherVisual.panelFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    .stroke(
                        AetherVisual.panelBorder(for: colorScheme),
                        lineWidth: 0.5
                    )
            }
    }
}

private struct AetherHeroPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                AetherVisual.panelFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
                    .stroke(
                        AetherVisual.panelBorder(for: colorScheme),
                        lineWidth: 0.5
                    )
            }
    }
}

/// A quiet content canvas. Brand color is used as atmosphere, not as another
/// control layer, and disappears almost entirely when Reduce Transparency is on.
struct AetherContentCanvas: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)

            if !reduceTransparency { Color.clear }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Keeps asynchronous actions visually stable while work is in progress.
/// The action title remains visible, so the control neither collapses to a
/// spinner nor makes people guess which operation is running.
struct AetherProgressButtonLabel: View {
    let title: LocalizedStringKey
    var systemImage: String?
    let isWorking: Bool

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isWorking: Bool
    ) {
        self.title = title
        self.systemImage = systemImage
        self.isWorking = isWorking
    }

    var body: some View {
        HStack(spacing: AetherVisual.s2) {
            if isWorking {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityHidden(true)
            } else if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
            }
            Text(title)
        }
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func aetherPanel() -> some View {
        modifier(AetherPanelModifier())
    }

    func aetherHeroPanel() -> some View {
        modifier(AetherHeroPanelModifier())
    }
}

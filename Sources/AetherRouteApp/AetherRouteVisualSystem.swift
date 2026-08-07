import SwiftUI

enum AetherVisual {
    static let cyan = Color(red: 0.18, green: 0.86, blue: 0.98)
    static let blue = Color(red: 0.04, green: 0.43, blue: 0.98)
    static let indigo = Color(red: 0.34, green: 0.24, blue: 0.91)
    static let success = Color(red: 0.03, green: 0.64, blue: 0.52)

    static let pageHorizontalPadding: CGFloat = 24
    static let pageTopPadding: CGFloat = 20
    static let pageBottomPadding: CGFloat = 28
    static let sectionSpacing: CGFloat = 16
    static let panelRadius: CGFloat = 16
    static let heroRadius: CGFloat = 24
    static let controlRadius: CGFloat = 12
    static let contentMaxWidth: CGFloat = 960
    static let formMaxWidth: CGFloat = 720

    static let brandGradient = LinearGradient(
        colors: [cyan, blue, indigo],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let pageBackground = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Material.regular

    static func panelFill(for colorScheme: ColorScheme) -> Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func panelBorder(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color.white.opacity(0.085)
            : Color.black.opacity(0.055)
    }
}

/// Aether Lens pairs a nearly complete portal with a route that exits through
/// its deliberate north-east opening. The quiet circular silhouette reads at
/// menu-bar size, while the open terminal and rising path communicate an
/// intentional route instead of the shield/globe clichés common to network
/// utilities.
struct AetherRouteGlyph: View {
    var isActive = false
    var isOnColor = false

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let gateWidth = max(1.55, side * 0.074)
            let routeWidth = max(1.25, side * 0.054)
            let gate = gatePath(in: proxy.size)
            let route = risingRoutePath(in: proxy.size)

            ZStack {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.white.opacity(isOnColor ? 0.14 : 0.035),
                                Color.clear,
                            ],
                            center: .topLeading,
                            startRadius: 0,
                            endRadius: side * 0.72
                        )
                    )
                    .padding(side * 0.12)

                gate
                    .stroke(
                        glowColor.opacity(isActive ? 0.30 : 0.10),
                        style: StrokeStyle(
                            lineWidth: gateWidth * 1.55,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .blur(radius: isActive ? side * 0.052 : side * 0.020)

                gate
                    .stroke(
                        gateGradient,
                        style: StrokeStyle(
                            lineWidth: gateWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                gate
                    .trim(from: 0.08, to: 0.56)
                    .stroke(
                        Color.white.opacity(isOnColor ? 0.58 : 0.22),
                        style: StrokeStyle(
                            lineWidth: max(0.55, gateWidth * 0.16),
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                route
                    .stroke(
                        routeGradient,
                        style: StrokeStyle(
                            lineWidth: routeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )

                Circle()
                    .fill(isOnColor ? Color.white : Color(nsColor: .windowBackgroundColor))
                    .overlay {
                        Circle()
                            .stroke(terminalColor.opacity(0.86), lineWidth: max(0.7, side * 0.018))
                    }
                    .frame(width: max(2.4, side * 0.080))
                    .shadow(
                        color: glowColor.opacity(isActive ? 0.72 : 0.36),
                        radius: isActive ? side * 0.065 : side * 0.030
                    )
                    .position(point(0.840, 0.300, in: proxy.size))
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func gatePath(in size: CGSize) -> Path {
        Path { path in
            path.move(to: point(0.675, 0.195, in: size))
            path.addCurve(
                to: point(0.255, 0.255, in: size),
                control1: point(0.555, 0.125, in: size),
                control2: point(0.370, 0.145, in: size)
            )
            path.addCurve(
                to: point(0.255, 0.755, in: size),
                control1: point(0.105, 0.395, in: size),
                control2: point(0.105, 0.625, in: size)
            )
            path.addCurve(
                to: point(0.755, 0.735, in: size),
                control1: point(0.395, 0.885, in: size),
                control2: point(0.620, 0.875, in: size)
            )
            path.addCurve(
                to: point(0.825, 0.590, in: size),
                control1: point(0.805, 0.685, in: size),
                control2: point(0.830, 0.635, in: size)
            )
        }
    }

    private func risingRoutePath(in size: CGSize) -> Path {
        Path { path in
            path.move(to: point(0.265, 0.700, in: size))
            path.addCurve(
                to: point(0.505, 0.625, in: size),
                control1: point(0.360, 0.745, in: size),
                control2: point(0.445, 0.695, in: size)
            )
            path.addCurve(
                to: point(0.705, 0.340, in: size),
                control1: point(0.585, 0.535, in: size),
                control2: point(0.620, 0.455, in: size)
            )
            path.addCurve(
                to: point(0.840, 0.300, in: size),
                control1: point(0.755, 0.310, in: size),
                control2: point(0.805, 0.300, in: size)
            )
        }
    }

    private var gateGradient: LinearGradient {
        LinearGradient(
            colors: isOnColor
                ? [Color.white, Color.white.opacity(0.96), Color.cyan.opacity(0.78)]
                : [AetherVisual.cyan, AetherVisual.blue, AetherVisual.indigo],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var routeGradient: LinearGradient {
        LinearGradient(
            colors: isOnColor
                ? [Color.white.opacity(0.78), AetherVisual.cyan, Color.white]
                : [AetherVisual.indigo, AetherVisual.blue, AetherVisual.cyan],
            startPoint: .bottomLeading,
            endPoint: .topTrailing
        )
    }

    private var glowColor: Color {
        isOnColor ? .white : AetherVisual.cyan
    }

    private var terminalColor: Color {
        isOnColor ? AetherVisual.cyan : AetherVisual.blue
    }

    private func point(
        _ x: CGFloat,
        _ y: CGFloat,
        in size: CGSize
    ) -> CGPoint {
        CGPoint(x: size.width * x, y: size.height * y)
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
                            Color(red: 0.17, green: 0.76, blue: 0.98),
                            Color(red: 0.04, green: 0.39, blue: 0.94),
                            Color(red: 0.21, green: 0.13, blue: 0.61),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RadialGradient(
                colors: [Color.white.opacity(0.30), Color.clear],
                center: UnitPoint(x: 0.24, y: 0.16),
                startRadius: 0,
                endRadius: size * 0.68
            )
            Circle()
                .stroke(Color.white.opacity(0.13), lineWidth: max(0.5, size * 0.012))
                .padding(size * 0.15)
            AetherRouteGlyph(isActive: isActive, isOnColor: true)
                .padding(size * 0.115)
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
        .shadow(color: AetherVisual.indigo.opacity(0.20), radius: size * 0.10, y: size * 0.045)
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
                            AetherVisual.cyan.opacity(colorScheme == .dark ? 0.16 : 0.11),
                            AetherVisual.blue.opacity(colorScheme == .dark ? 0.10 : 0.055),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            AetherVisual.cyan.opacity(isActive ? 0.42 : 0.20),
                            AetherVisual.indigo.opacity(isActive ? 0.22 : 0.10),
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
            color: AetherVisual.cyan.opacity(isActive ? 0.13 : 0.035),
            radius: isActive ? 12 : 5
        )
        .accessibilityHidden(true)
    }
}

private struct AetherPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    let radius: CGFloat
    let elevated: Bool

    func body(content: Content) -> some View {
        content
            .background(
                AetherVisual.panelFill(for: colorScheme),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(
                        AetherVisual.panelBorder(for: colorScheme),
                        lineWidth: 0.5
                    )
            }
            .shadow(
                color: elevated && colorScheme == .light
                    ? Color.black.opacity(0.035)
                    : .clear,
                radius: elevated ? 8 : 0,
                y: elevated ? 3 : 0
            )
    }
}

private struct AetherHeroPanelModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .glassEffect(
                    .regular.tint(AetherVisual.blue.opacity(0.045)),
                    in: RoundedRectangle(
                        cornerRadius: AetherVisual.heroRadius,
                        style: .continuous
                    )
                )
        } else {
            content
                .background(
                    reduceTransparency
                        ? AnyShapeStyle(AetherVisual.panelFill(for: colorScheme))
                        : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(
                        cornerRadius: AetherVisual.heroRadius,
                        style: .continuous
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: AetherVisual.heroRadius,
                        style: .continuous
                    )
                    .stroke(
                        LinearGradient(
                            colors: [
                                AetherVisual.blue.opacity(
                                    colorScheme == .dark ? 0.15 : 0.10
                                ),
                                AetherVisual.panelBorder(for: colorScheme),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.6
                    )
                }
                .shadow(
                    color: colorScheme == .light
                        ? Color.black.opacity(0.04)
                        : .clear,
                    radius: 12,
                    y: 4
                )
        }
    }
}

private struct AetherGlassSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    let radius: CGFloat
    let tint: Color?
    let interactive: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content.glassEffect(
                .regular.tint(tint).interactive(interactive),
                in: RoundedRectangle(cornerRadius: radius, style: .continuous)
            )
        } else {
            content
                .background(
                    reduceTransparency
                        ? AnyShapeStyle(AetherVisual.panelFill(for: colorScheme))
                        : AnyShapeStyle(.regularMaterial),
                    in: RoundedRectangle(cornerRadius: radius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .stroke(
                            AetherVisual.panelBorder(for: colorScheme),
                            lineWidth: 0.5
                        )
                }
        }
    }
}

private struct AetherPrimaryActionStyleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glassProminent)
        } else {
            content.buttonStyle(.borderedProminent)
        }
    }
}

private struct AetherSecondaryActionStyleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonStyle(.glass)
        } else {
            content.buttonStyle(.bordered)
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

            if !reduceTransparency {
                ZStack {
                    LinearGradient(
                        colors: [
                            AetherVisual.blue.opacity(
                                colorScheme == .dark ? 0.035 : 0.018
                            ),
                            Color.clear,
                        ],
                        startPoint: .topLeading,
                        endPoint: .center
                    )
                    RadialGradient(
                        colors: [
                            AetherVisual.cyan.opacity(
                                colorScheme == .dark ? 0.022 : 0.012
                            ),
                            Color.clear,
                        ],
                        center: .bottomTrailing,
                        startRadius: 0,
                        endRadius: 520
                    )
                }
            }
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
        HStack(spacing: 7) {
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
    func aetherPanel(
        radius: CGFloat = 16,
        elevated: Bool = false
    ) -> some View {
        modifier(AetherPanelModifier(radius: radius, elevated: elevated))
    }

    func aetherHeroPanel() -> some View {
        modifier(AetherHeroPanelModifier())
    }

    /// Applies Liquid Glass only to floating controls and top-level functional
    /// surfaces. Content cards intentionally continue to use `aetherPanel` so
    /// navigation remains visually distinct from data and settings content.
    func aetherGlassSurface(
        radius: CGFloat = AetherVisual.controlRadius,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        modifier(
            AetherGlassSurfaceModifier(
                radius: radius,
                tint: tint,
                interactive: interactive
            )
        )
    }

    func aetherPrimaryActionStyle() -> some View {
        modifier(AetherPrimaryActionStyleModifier())
    }

    func aetherSecondaryActionStyle() -> some View {
        modifier(AetherSecondaryActionStyleModifier())
    }
}

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
    static let windowWidth: CGFloat = 960
    static let windowHeight: CGFloat = 680
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

/// The adopted Scheme A (以太跃迁 · 蓝宝石晶体环) emblem. It renders the
/// luminous sapphire crystal mobius ring with forward portal energy arrow.
struct AetherRouteGlyph: View {
    var isActive = false
    var isOnColor = false

    var body: some View {
        Group {
            if let image = NSImage(named: "AetherSapphireEmblem") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let resourceUrl = Bundle.main.url(forResource: "AetherSapphireEmblem", withExtension: "png"),
                      let image = NSImage(contentsOf: resourceUrl) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                legacyGlyph
            }
        }
        .opacity(isOnColor ? 1.0 : (isActive ? 1.0 : 0.88))
        .shadow(
            color: isActive ? glowColor.opacity(0.38) : .clear,
            radius: 8
        )
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private var legacyGlyph: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let strokeWidth = max(1.4, side * Self.strokeUnits / Self.gridSide)

            ZStack {
                channelArc(side: side, rightSide: false)
                    .stroke(markStyle, style: channelStroke(strokeWidth))

                channelArc(side: side, rightSide: true)
                    .stroke(markStyle, style: channelStroke(strokeWidth))
                    .opacity(0.45)

                routeArrow(side: side)
                    .stroke(markStyle, style: channelStroke(strokeWidth))
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

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
        Group {
            if let image = NSImage(named: "AetherSapphireEmblem") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let resourceUrl = Bundle.main.url(forResource: "AetherSapphireEmblem", withExtension: "png"),
                      let image = NSImage(contentsOf: resourceUrl) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if let image = NSImage(named: "AppIcon") {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .shadow(
            color: AetherVisual.portalLight.opacity(isActive ? 0.35 : 0.12),
            radius: isActive ? size * 0.25 : size * 0.08
        )
        .accessibilityLabel("AetherRoute")
    }
}

/// A state-bearing rendition of the brand mark for connection surfaces.
/// Employs Scheme A: Sapphire crystal mobius ring with radial refraction halo.
struct AetherRouteStatusLens: View {
    @Environment(\.colorScheme) private var colorScheme

    var size: CGFloat = 52
    var isActive = false

    var body: some View {
        ZStack {
            // Ambient outer glow matching Scheme A
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            AetherVisual.portalLight.opacity(isActive ? 0.30 : (colorScheme == .dark ? 0.16 : 0.09)),
                            AetherVisual.portalMid.opacity(isActive ? 0.16 : (colorScheme == .dark ? 0.08 : 0.04)),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: size * 0.15,
                        endRadius: size * 0.52
                    )
                )

            // Precision refractive ring
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            AetherVisual.portalLight.opacity(isActive ? 0.55 : 0.22),
                            AetherVisual.portalDark.opacity(isActive ? 0.28 : 0.10),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )

            // Sapphire crystal ring emblem
            AetherRouteGlyph(isActive: isActive)
                .padding(size * 0.06)
        }
        .frame(width: size, height: size)
        .shadow(
            color: AetherVisual.portalLight.opacity(isActive ? 0.36 : 0.08),
            radius: isActive ? 14 : 5
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

    func aetherModernCard(
        isSelected: Bool = false,
        cornerRadius: CGFloat = 10,
        isHovered: Bool = false
    ) -> some View {
        modifier(
            AetherModernCardModifier(
                isSelected: isSelected,
                cornerRadius: cornerRadius,
                isHovered: isHovered
            )
        )
    }
}

private struct AetherModernCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let isSelected: Bool
    let cornerRadius: CGFloat
    let isHovered: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(cardFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderColor, lineWidth: isSelected ? 1.5 : (isHovered ? 1.0 : 0.5))
            }
            .shadow(
                color: isSelected
                    ? Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.22)
                    : (isHovered ? Color.black.opacity(colorScheme == .dark ? 0.25 : 0.08) : Color.clear),
                radius: isSelected ? 6 : 4,
                y: isSelected ? 2 : 1
            )
    }

    private var cardFill: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.12 : 0.07)
        }
        if isHovered {
            return Color(nsColor: .controlBackgroundColor).opacity(0.95)
        }
        return Color(nsColor: .controlBackgroundColor).opacity(0.65)
    }

    private var borderColor: Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovered {
            return Color.accentColor.opacity(0.45)
        }
        return Color(nsColor: .separatorColor).opacity(0.6)
    }
}

/// 协议微章组件：展示 SS, VMess, VLESS, Trojan, Hysteria2 等协议类型
struct AetherProtocolBadge: View {
    let type: String

    var body: some View {
        Text(displayType)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(badgeColor)
            .padding(.horizontal, 5)
            .padding(.vertical, 2.5)
            .background(badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }

    private var displayType: String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return "PROXY" }
        if trimmed == "HYSTERIA2" || trimmed == "HYSTERIA" { return "HY2" }
        if trimmed == "SHADOWSOCKS" { return "SS" }
        return trimmed
    }

    private var badgeColor: Color {
        switch displayType {
        case "SS", "SHADOWSOCKS": return .purple
        case "VMESS": return .blue
        case "VLESS": return .cyan
        case "TROJAN": return .pink
        case "HYSTERIA", "HYSTERIA2", "HY2": return .orange
        case "TUIC": return .indigo
        case "WIREGUARD", "WG": return .teal
        case "SOCKS5", "HTTP": return .gray
        case "DIRECT": return .green
        case "REJECT": return .red
        default: return .secondary
        }
    }
}

/// 现代测速延迟胶囊
struct AetherLatencyPill: View {
    let latency: Int?
    var isTesting: Bool = false
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 3.5) {
                if isTesting {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 9, height: 9)
                } else if let ms = latency, ms > 0 {
                    Circle()
                        .fill(pillColor)
                        .frame(width: 5, height: 5)
                }

                Text(displayText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(pillColor)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(pillColor.opacity(0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(pillColor.opacity(0.25), lineWidth: 0.5)
            }
        }
        .buttonStyle(.plain)
        .disabled(isTesting || onTap == nil)
    }

    private var displayText: String {
        if isTesting { return AppLocalization.string("Testing") }
        guard let latency, latency > 0 else { return AppLocalization.string("Timeout") }
        return "\(latency) ms"
    }

    private var pillColor: Color {
        if isTesting { return .secondary }
        guard let latency, latency > 0 else { return Color.secondary.opacity(0.7) }
        if latency < 180 { return Color(red: 0.20, green: 0.76, blue: 0.40) } // 翡翠绿
        if latency < 450 { return Color(red: 0.18, green: 0.65, blue: 0.95) } // 科技蓝
        if latency < 1200 { return Color(red: 0.95, green: 0.62, blue: 0.18) } // 琥珀橙
        return Color(red: 0.90, green: 0.38, blue: 0.35) // 柔和珊瑚红
    }
}

/// 现代节点晶核图标：优先匹配真实地域旗帜，未识别时呈现高质感协议几何微晶
public struct AetherNodeIcon: View {
    let name: String
    let protocolName: String
    var size: CGFloat = 28

    public init(name: String, protocolName: String, size: CGFloat = 28) {
        self.name = name
        self.protocolName = protocolName
        self.size = size
    }

    public var body: some View {
        let flagInfo = AetherRegionFlag.flagAndRegion(from: name)

        if flagInfo.flag != "🌐" {
            // 真实匹配到的国家/地区旗帜
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                Text(flagInfo.flag)
                    .font(.system(size: size * 0.55))
            }
            .frame(width: size, height: size)
        } else {
            // 通用/未知地域：呈现高质感协议专用科技晶核图标
            let config = iconConfig
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [config.color.opacity(0.24), config.color.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .stroke(config.color.opacity(0.4), lineWidth: 0.5)
                    }

                Image(systemName: config.symbol)
                    .font(.system(size: size * 0.44, weight: .semibold))
                    .foregroundStyle(config.color)
            }
            .frame(width: size, height: size)
        }
    }

    private var iconConfig: (symbol: String, color: Color) {
        let upperName = name.uppercased()
        let upperProto = protocolName.uppercased()

        if upperProto.contains("HY2") || upperProto.contains("HYSTERIA") || upperName.contains("HY2") || upperName.contains("HYSTERIA") {
            return ("bolt.fill", Color.orange)
        }
        if upperProto.contains("VLESS") || upperName.contains("VLESS") {
            return ("shield.checkered", Color.cyan)
        }
        if upperProto.contains("VMESS") || upperName.contains("VMESS") {
            return ("cube.fill", Color.blue)
        }
        if upperProto.contains("TROJAN") || upperName.contains("TROJAN") {
            return ("lock.shield.fill", Color.pink)
        }
        if upperProto.contains("DIRECT") || upperName.contains("DIRECT") {
            return ("arrow.trianglehead.branch", Color.green)
        }
        if upperProto.contains("SS") || upperProto.contains("SHADOWSOCKS") || upperName.contains("SS") {
            return ("paperplane.fill", Color.purple)
        }
        if upperProto.contains("WIREGUARD") || upperProto.contains("WG") {
            return ("shield.lefthalf.filled", Color.teal)
        }
        return ("point.3.filled.connected.trianglepath.dotted", Color.accentColor)
    }
}

// MARK: - Aether Design System 2.0 核心基础组件

public enum AetherElevation {
    case flat
    case raised
    case interactive
}

/// 统一的高质感卡片容器：支持分层材质、自适应微边框、Hover 浮动微动效与投影
public struct AetherSurface<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    var elevation: AetherElevation = .raised
    var isSelected: Bool = false
    var cornerRadius: CGFloat = 12
    var isHovered: Bool = false
    @ViewBuilder var content: () -> Content

    public init(
        elevation: AetherElevation = .raised,
        isSelected: Bool = false,
        cornerRadius: CGFloat = 12,
        isHovered: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.elevation = elevation
        self.isSelected = isSelected
        self.cornerRadius = cornerRadius
        self.isHovered = isHovered
        self.content = content
    }

    public var body: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(backgroundFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(borderStroke, lineWidth: isSelected ? 1.5 : (isHovered ? 1.0 : 0.5))
            }
            .shadow(
                color: shadowColor,
                radius: isSelected ? 8 : (isHovered ? 6 : (elevation == .raised ? 4 : 0)),
                y: isSelected ? 3 : (isHovered ? 2 : (elevation == .raised ? 1 : 0))
            )
    }

    private var backgroundFill: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(Color.accentColor.opacity(colorScheme == .dark ? 0.14 : 0.08))
        }
        switch elevation {
        case .flat:
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(colorScheme == .dark ? 0.5 : 0.65))
        case .raised:
            return AnyShapeStyle(Material.ultraThinMaterial)
        case .interactive:
            if isHovered {
                return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.92))
            }
            return AnyShapeStyle(Color(nsColor: .controlBackgroundColor).opacity(0.65))
        }
    }

    private var borderStroke: Color {
        if isSelected {
            return Color.accentColor
        }
        if isHovered {
            return Color.accentColor.opacity(0.4)
        }
        return Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.45 : 0.3)
    }

    private var shadowColor: Color {
        if isSelected {
            return Color.accentColor.opacity(colorScheme == .dark ? 0.35 : 0.2)
        }
        if isHovered {
            return Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08)
        }
        if elevation == .raised {
            return Color.black.opacity(colorScheme == .dark ? 0.18 : 0.04)
        }
        return Color.clear
    }
}

/// 现代网络状态呼吸信标：展示连通性、呼吸发光动画与微环形指示
public struct AetherStatusBeacon: View {
    @Environment(\.colorScheme) private var colorScheme
    let isConnected: Bool
    let isConnecting: Bool
    var size: CGFloat = 10

    @State private var isPulsing: Bool = false

    public init(isConnected: Bool, isConnecting: Bool = false, size: CGFloat = 10) {
        self.isConnected = isConnected
        self.isConnecting = isConnecting
        self.size = size
    }

    public var body: some View {
        ZStack {
            if isConnected {
                Circle()
                    .fill(Color.green.opacity(isPulsing ? 0.25 : 0.45))
                    .frame(width: size * 2.0, height: size * 2.0)
                    .scaleEffect(isPulsing ? 1.25 : 0.95)
                    .animation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true), value: isPulsing)
            } else if isConnecting {
                Circle()
                    .stroke(Color.orange.opacity(0.5), lineWidth: 1.5)
                    .frame(width: size * 1.8, height: size * 1.8)
                    .rotationEffect(.degrees(isPulsing ? 360 : 0))
                    .animation(.linear(duration: 1.5).repeatForever(autoreverses: false), value: isPulsing)
            }

            Circle()
                .fill(statusColor)
                .frame(width: size, height: size)
                .shadow(color: statusColor.opacity(0.5), radius: isConnected ? 4 : 1)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .onAppear {
            if isConnected || isConnecting {
                isPulsing = true
            }
        }
        .onChange(of: isConnected) { _, newValue in
            isPulsing = newValue
        }
        .onChange(of: isConnecting) { _, newValue in
            if newValue { isPulsing = true }
        }
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if isConnecting { return .orange }
        return .secondary.opacity(0.6)
    }
}

/// 智能国旗与地域解析器
public enum AetherRegionFlag {
    public static func flagAndRegion(from name: String) -> (flag: String, region: String) {
        let upper = name.uppercased()
        if upper.contains("HK") || upper.contains("HONG KONG") || name.contains("香港") {
            return ("🇭🇰", "HK")
        }
        if upper.contains("JP") || upper.contains("JAPAN") || upper.contains("TOKYO") || name.contains("日本") || name.contains("东京") {
            return ("🇯🇵", "JP")
        }
        if upper.contains("US") || upper.contains("USA") || upper.contains("UNITED STATES") || name.contains("美国") || name.contains("硅谷") {
            return ("🇺🇸", "US")
        }
        if upper.contains("SG") || upper.contains("SINGAPORE") || name.contains("新加坡") || name.contains("狮城") {
            return ("🇸🇬", "SG")
        }
        if upper.contains("TW") || upper.contains("TAIWAN") || name.contains("台湾") {
            return ("🇹🇼", "TW")
        }
        if upper.contains("KR") || upper.contains("KOREA") || upper.contains("SEOUL") || name.contains("韩国") || name.contains("首尔") {
            return ("🇰🇷", "KR")
        }
        if upper.contains("GB") || upper.contains("UK") || upper.contains("LONDON") || name.contains("英国") || name.contains("伦敦") {
            return ("🇬🇧", "UK")
        }
        if upper.contains("DE") || upper.contains("GERMANY") || upper.contains("FRANKFURT") || name.contains("德国") || name.contains("法兰克福") {
            return ("🇩🇪", "DE")
        }
        if upper.contains("FR") || upper.contains("FRANCE") || name.contains("法国") {
            return ("🇫🇷", "FR")
        }
        if upper.contains("CA") || upper.contains("CANADA") || name.contains("加拿大") {
            return ("🇨🇦", "CA")
        }
        if upper.contains("AU") || upper.contains("AUSTRALIA") || name.contains("澳大利亚") || name.contains("悉尼") {
            return ("🇦🇺", "AU")
        }
        return ("🌐", "GLOBAL")
    }
}

/// 实时上下行迷你双波形走势图 (30秒平滑动态波形图)
public struct AetherTrafficMiniGraph: View {
    @Environment(\.colorScheme) private var colorScheme
    let downloadSamples: [Double]
    let uploadSamples: [Double]
    var height: CGFloat = 46

    public init(downloadSamples: [Double], uploadSamples: [Double], height: CGFloat = 46) {
        self.downloadSamples = downloadSamples
        self.uploadSamples = uploadSamples
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let actualHeight = proxy.size.height
            let maxVal = max(
                (downloadSamples + uploadSamples).max() ?? 1024,
                1024
            )

            ZStack {
                // 背景微弱参考虚线
                VStack {
                    Divider().opacity(0.15)
                    Spacer()
                    Divider().opacity(0.15)
                }

                // 下行面积波形 (青蓝渐变)
                if downloadSamples.count > 1 {
                    waveformPath(samples: downloadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.35), Color.cyan.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    waveformLine(samples: downloadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .stroke(Color.cyan, lineWidth: 1.5)
                }

                // 上行面积波形 (紫粉渐变)
                if uploadSamples.count > 1 {
                    waveformPath(samples: uploadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.25), Color.purple.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    waveformLine(samples: uploadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .stroke(Color.purple.opacity(0.8), lineWidth: 1.2)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func waveformPath(samples: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let step = width / CGFloat(samples.count - 1)

        path.move(to: CGPoint(x: 0, y: height))
        for (i, val) in samples.enumerated() {
            let normalizedY = height - CGFloat(val / maxVal) * (height - 4)
            let x = CGFloat(i) * step
            if i == 0 {
                path.addLine(to: CGPoint(x: x, y: normalizedY))
            } else {
                path.addLine(to: CGPoint(x: x, y: normalizedY))
            }
        }
        path.addLine(to: CGPoint(x: width, y: height))
        path.closeSubpath()
        return path
    }

    private func waveformLine(samples: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> Path {
        var path = Path()
        guard samples.count > 1 else { return path }
        let step = width / CGFloat(samples.count - 1)

        for (i, val) in samples.enumerated() {
            let normalizedY = height - CGFloat(val / maxVal) * (height - 4)
            let x = CGFloat(i) * step
            if i == 0 {
                path.move(to: CGPoint(x: x, y: normalizedY))
            } else {
                path.addLine(to: CGPoint(x: x, y: normalizedY))
            }
        }
        return path
    }
}



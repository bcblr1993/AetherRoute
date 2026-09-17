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
    static let sMicro: CGFloat = 2
    static let s1: CGFloat = 4
    static let sCompact: CGFloat = 6
    static let s2: CGFloat = 8
    static let sRow: CGFloat = 10
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24

    static let badgeRadius: CGFloat = 4
    static let controlRadius: CGFloat = 6
    static let insetRadius: CGFloat = 8
    static let cardRadius: CGFloat = 10
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
    static let popoverWidth: CGFloat = 380
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

/// The asset catalog selects the light or dark Silver Flight artwork using
/// the current SwiftUI appearance, including live app-theme changes.
struct AetherRouteGlyph: View {
    var isActive = false
    var isOnColor = false

    var body: some View {
        Image("AetherSapphireEmblem")
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: .fit)
            .opacity(isOnColor || isActive ? 1 : 0.88)
            .accessibilityHidden(true)
    }
}

struct AetherRouteBrandTile: View {
    var size: CGFloat = 32
    var isActive = false

    var body: some View {
        Image("AetherSapphireEmblem")
            .resizable()
            .renderingMode(.original)
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityLabel("AetherRoute")
    }
}

/// Quiet, theme-matched branding. Connection state is presented with an
/// ambient breathing aura when connecting, settling into a serene emerald glow when active.
struct AetherRouteStatusLens: View {
    var size: CGFloat = 52
    var isActive = false
    var isConnecting = false

    @State private var pulse = false

    var body: some View {
        ZStack {
            if isConnecting {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.accentColor.opacity(0.35), Color.clear],
                            center: .center,
                            startRadius: size * 0.1,
                            endRadius: size * 0.65
                        )
                    )
                    .scaleEffect(pulse ? 1.15 : 0.88)
                    .opacity(pulse ? 0.9 : 0.45)
                    .animation(
                        .easeInOut(duration: 1.2).repeatForever(autoreverses: true),
                        value: pulse
                    )
            } else if isActive {
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [Color.green.opacity(0.22), Color.clear],
                            center: .center,
                            startRadius: size * 0.1,
                            endRadius: size * 0.62
                        )
                    )
                    .transition(.opacity)
            }

            AetherRouteGlyph(isActive: isActive)
                .padding(size * 0.06)
                .frame(width: size, height: size)
                .scaleEffect(isConnecting ? (pulse ? 1.03 : 0.97) : 1.0)
                .animation(
                    isConnecting ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default,
                    value: pulse
                )
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            if isConnecting { pulse = true }
        }
        .onChange(of: isConnecting) { _, newValue in
            pulse = newValue
        }
    }
}

/// 精致的顶部微型能量流光条：在连接中提供行云流水般的高级微动效，卡片高度零跳动
struct ConnectionLuminousBar: View {
    @State private var phase: CGFloat = -0.5

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            Rectangle()
                .fill(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: Color.accentColor.opacity(0.3), location: 0.2),
                            .init(color: Color.accentColor, location: 0.5),
                            .init(color: Color.cyan, location: 0.7),
                            .init(color: Color.accentColor.opacity(0.3), location: 0.8),
                            .init(color: .clear, location: 1.0),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: max(width * 0.45, 120), height: 2.5)
                .offset(x: phase * width)
        }
        .frame(height: 2.5)
        .clipped()
        .onAppear {
            withAnimation(
                .linear(duration: 1.3)
                    .repeatForever(autoreverses: false)
            ) {
                phase = 1.1
            }
        }
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
    let title: Text
    var systemImage: String?
    let isWorking: Bool

    init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        isWorking: Bool
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.isWorking = isWorking
    }

    init(
        _ titleString: String,
        systemImage: String? = nil,
        isWorking: Bool
    ) {
        self.title = Text(titleString)
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
            title
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

    func aetherHoverHighlight(
        _ isHovered: Bool,
        cornerRadius: CGFloat = AetherVisual.controlRadius,
        hoverColor: Color = Color.secondary.opacity(0.12)
    ) -> some View {
        aetherHoverHighlight(isHovered: isHovered, cornerRadius: cornerRadius, hoverColor: hoverColor)
    }

    func aetherHoverHighlight(
        isHovered: Bool,
        cornerRadius: CGFloat = AetherVisual.controlRadius,
        hoverColor: Color = Color.secondary.opacity(0.12)
    ) -> some View {
        background(
            isHovered ? hoverColor : Color.clear,
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
        .animation(AetherVisual.quickFade, value: isHovered)
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
            .foregroundStyle(.primary)
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
    let status: ProxyLatencyStatus
    /// Qualifies a measured number: a TCP handshake and a number measured
    /// through the node's real protocol handler are not the same claim.
    var confidence: ProxyLatencyConfidence = .reachability
    var onTap: (() -> Void)? = nil
    @State private var isHovered = false

    init(
        status: ProxyLatencyStatus,
        confidence: ProxyLatencyConfidence = .reachability,
        onTap: (() -> Void)? = nil
    ) {
        self.status = status
        self.confidence = confidence
        self.onTap = onTap
    }

    init(latency: Int?, isTesting: Bool = false, onTap: (() -> Void)? = nil) {
        if isTesting {
            self.status = .testing
        } else if let ms = latency, ms > 0 {
            self.status = .responded(UInt32(ms))
        } else if latency == nil {
            self.status = .untested
        } else {
            self.status = .timedOut
        }
        self.onTap = onTap
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 3.5) {
                if status == .testing {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.65)
                        .frame(width: 9, height: 9)
                } else if case .responded = status {
                    Circle()
                        .fill(pillColor)
                        .frame(width: 5, height: 5)
                        .shadow(color: pillColor.opacity(0.4), radius: 2)
                }

                Text(displayText)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.primary)

                if status.isMeasured, confidence == .verified {
                    // Only the stronger claim is marked. Reachability is the
                    // default, so badging it too would add noise to every row.
                    Image(systemName: confidence.symbol)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 7.5)
            .padding(.vertical, 3.5)
            .background(pillColor.opacity(isHovered ? 0.22 : 0.12), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(pillColor.opacity(isHovered ? 0.48 : 0.25), lineWidth: 0.5)
            }
            .scaleEffect(isHovered && onTap != nil ? 1.04 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if onTap != nil && status != .testing {
                isHovered = hovering
            }
        }
        .disabled(status == .testing || onTap == nil)
    }

    private var displayText: String {
        switch status {
        case .testing:
            return AppLocalization.string("Testing")
        case let .responded(ms):
            return "\(ms) ms"
        case .timedOut:
            return AppLocalization.string("Timeout")
        case .untested:
            return AppLocalization.string("Untested")
        }
    }

    private var pillColor: Color {
        switch status {
        case .testing:
            return .secondary
        case let .responded(latency):
            if latency < 200 { return Color(red: 0.20, green: 0.78, blue: 0.42) } // 翡翠绿 (高速)
            if latency < 500 { return Color(red: 0.18, green: 0.68, blue: 0.98) } // 科技蓝 (良好)
            if latency < 900 { return Color(red: 0.96, green: 0.64, blue: 0.18) } // 琥珀橙 (普通)
            return Color(red: 0.94, green: 0.40, blue: 0.38) // 珊瑚红 (慢速)
        case .timedOut:
            return Color(red: 0.94, green: 0.40, blue: 0.38).opacity(0.85)
        case .untested:
            return Color.secondary.opacity(0.6)
        }
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
                    .accessibilityHidden(true)
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
    let samplePositions: [Double]
    var height: CGFloat = 46

    public init(downloadSamples: [Double], uploadSamples: [Double], samplePositions: [Double] = [], height: CGFloat = 46) {
        self.downloadSamples = downloadSamples
        self.uploadSamples = uploadSamples
        self.samplePositions = samplePositions
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
                // 背景微弱参考网格线
                VStack {
                    Divider().opacity(0.12)
                    Spacer()
                    Divider().opacity(0.08)
                    Spacer()
                    Divider().opacity(0.12)
                }

                // 下行平滑面积波形 (青蓝霓虹渐变)
                if downloadSamples.count > 1 {
                    smoothWaveformPath(samples: downloadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .fill(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.38), Color.cyan.opacity(0.08), Color.cyan.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    smoothWaveformLine(samples: downloadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .stroke(
                            LinearGradient(
                                colors: [Color.cyan.opacity(0.7), Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: Color.cyan.opacity(0.4), radius: 3, x: 0, y: 1)
                }

                // 上行平滑面积波形 (紫粉霓虹渐变)
                if uploadSamples.count > 1 {
                    smoothWaveformPath(samples: uploadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.30), Color.purple.opacity(0.06), Color.purple.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    smoothWaveformLine(samples: uploadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .stroke(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.6), Color.purple.opacity(0.95)],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                        .shadow(color: Color.purple.opacity(0.35), radius: 2.5, x: 0, y: 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }

    private func smoothPoints(samples: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> [CGPoint] {
        guard !samples.isEmpty else { return [] }
        let baselineY = height - 3
        let count = samples.count

        var rawPoints: [CGPoint] = []
        let hasPositions = samplePositions.count == count
        let step = count > 1 ? width / CGFloat(count - 1) : width

        for (i, val) in samples.enumerated() {
            let normalizedY = height - CGFloat(min(val / maxVal, 1.0)) * (height - 6) - 3
            let x: CGFloat
            if hasPositions {
                x = CGFloat(samplePositions[i]) * width
            } else {
                x = CGFloat(i) * step
            }
            rawPoints.append(CGPoint(x: max(0, min(width, x)), y: normalizedY))
        }

        rawPoints.sort { $0.x < $1.x }
        var deduped: [CGPoint] = []
        for p in rawPoints {
            if let last = deduped.last {
                if p.x - last.x < 1.0 {
                    deduped[deduped.count - 1] = CGPoint(x: p.x, y: min(last.y, p.y))
                    continue
                }
            }
            deduped.append(p)
        }

        guard !deduped.isEmpty else { return [] }

        var result: [CGPoint] = []
        // 当左侧没有充满 30 秒时，平滑补充最左端零基线点，避免波形悬空截断
        if let first = deduped.first, first.x > 0 {
            result.append(CGPoint(x: 0, y: baselineY))
        }

        result.append(contentsOf: deduped)

        // 最右端延伸至视口边缘，保证波形饱满
        if let last = result.last, last.x < width {
            result.append(CGPoint(x: width, y: last.y))
        }

        return result
    }

    private func appendSmoothWaveformCurves(to path: inout Path, points: [CGPoint]) {
        guard points.count > 1 else { return }

        for i in 0..<(points.count - 1) {
            let p1 = points[i]
            let p2 = points[i + 1]
            let dx = p2.x - p1.x
            guard dx > 0.001 else {
                path.addLine(to: p2)
                continue
            }

            let s = (p2.y - p1.y) / dx
            let sPrev: CGFloat
            if i > 0 {
                let p0 = points[i - 1]
                let dxPrev = max(0.001, p1.x - p0.x)
                sPrev = (p1.y - p0.y) / dxPrev
            } else {
                sPrev = s
            }

            let sNext: CGFloat
            if i + 2 < points.count {
                let p3 = points[i + 2]
                let dxNext = max(0.001, p3.x - p2.x)
                sNext = (p3.y - p2.y) / dxNext
            } else {
                sNext = 0
            }

            // 单调三次斜率控制：局部极值点切线置平，杜绝过冲与回卷
            let m1: CGFloat
            if sPrev * s <= 0 {
                m1 = 0
            } else {
                let avg = (sPrev + s) * 0.5
                let sign: CGFloat = avg >= 0 ? 1 : -1
                m1 = sign * min(abs(avg), 2 * min(abs(sPrev), abs(s)))
            }

            let m2: CGFloat
            if s * sNext <= 0 {
                m2 = 0
            } else {
                let avg = (s + sNext) * 0.5
                let sign: CGFloat = avg >= 0 ? 1 : -1
                m2 = sign * min(abs(avg), 2 * min(abs(s), abs(sNext)))
            }

            // 控制点 x 严格保证在 p1.x 与 p2.x 之间且单调，绝不发生回环自相交
            let cp1 = CGPoint(
                x: p1.x + dx / 3.0,
                y: p1.y + m1 * (dx / 3.0)
            )
            let cp2 = CGPoint(
                x: p2.x - dx / 3.0,
                y: p2.y - m2 * (dx / 3.0)
            )

            path.addCurve(to: p2, control1: cp1, control2: cp2)
        }
    }

    private func smoothWaveformPath(samples: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> Path {
        var path = Path()
        let points = smoothPoints(samples: samples, width: width, height: height, maxVal: maxVal)
        guard points.count > 1 else { return path }

        path.move(to: CGPoint(x: points[0].x, y: height))
        path.addLine(to: points[0])
        appendSmoothWaveformCurves(to: &path, points: points)
        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
        path.closeSubpath()
        return path
    }

    private func smoothWaveformLine(samples: [Double], width: CGFloat, height: CGFloat, maxVal: Double) -> Path {
        var path = Path()
        let points = smoothPoints(samples: samples, width: width, height: height, maxVal: maxVal)
        guard points.count > 1 else { return path }

        path.move(to: points[0])
        appendSmoothWaveformCurves(to: &path, points: points)
        return path
    }
}


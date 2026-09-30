import AetherRouteKit
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
    /// A page arriving after sidebar navigation: quick enough to never delay
    /// reading, long enough to show where the content came from.
    static let pageEntrance = Animation.easeOut(duration: 0.22)

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
    /// Space between top-level blocks of a page, including after its header.
    static let sectionSpacing = s4
    /// Reading width for forms and settings-like pages.
    static let contentMaxWidth: CGFloat = 720
    static let formMaxWidth: CGFloat = 720
    /// Dashboard and list pages use more of a large window before centering,
    /// so a maximized window does not read as half-loaded.
    static let wideContentMaxWidth: CGFloat = 960
    static let sidebarWidth: CGFloat = 200
    static let windowWidth: CGFloat = 960
    static let windowHeight: CGFloat = 680
    static let popoverWidth: CGFloat = 380
    /// Sheet content follows the final dialog handoff rather than the page
    /// spacing grid.
    static let dialogPadding: CGFloat = 26
    static let onboardingTopPadding = s6 + s5
    static let wideListIndent = s6 * 2 + s2
    /// Distance from the window top to floating overlays (command palette).
    static let overlayTopInset = s6 * 3
    static let tableContentIndent = s6 * 3

    static let brandGradient = LinearGradient(
        colors: [portalLight, portalMid, portalDark],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let pageBackground = Color(nsColor: .windowBackgroundColor)

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

/// The connection state drawn around the brand glyph.
///
/// - Connecting: a short arc orbits the glyph. The angle is derived from the
///   clock, not from a repeating animation, so leaving the state can never
///   leave a stray animation running.
/// - Connected: the arc closes into a full green ring and a check mark pops
///   in at the corner.
/// - Failed: a red ring with a warning badge.
/// - Idle: no ring; the glyph alone.
///
/// The glyph itself never scales; only the ring and badge move. With Reduce
/// Motion the arc is drawn still and state changes are instant.
struct AetherRouteStatusLens: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var size: CGFloat = 52
    var isActive = false
    var isConnecting = false
    var isFailed = false

    private static let orbitPeriod: TimeInterval = 1.1

    var body: some View {
        let ringWidth = max(2, size * 0.05)
        ZStack {
            // Track: a faint full circle the arc travels on.
            Circle()
                .stroke(Color.secondary.opacity(isConnecting ? 0.15 : 0), lineWidth: ringWidth)

            TimelineView(.animation(paused: !isConnecting || reduceMotion)) { context in
                Circle()
                    .trim(from: 0, to: ringLength)
                    .stroke(ringColor, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(orbitAngle(at: context.date)))
            }

            AetherRouteGlyph(isActive: isActive)
                .padding(size * 0.16)
                .frame(width: size, height: size)

            if let badge {
                Image(systemName: badge.symbol)
                    .font(.system(size: size * 0.3, weight: .semibold))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, badge.color)
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
                    .symbolEffect(.bounce, value: badge.symbol)
                    .offset(x: size * 0.36, y: size * 0.36)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isActive)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isConnecting)
        .animation(AetherVisual.animation(AetherVisual.panelSpring), value: isFailed)
        .accessibilityHidden(true)
    }

    /// Connecting shows a short arc; connected and failed close the ring.
    private var ringLength: CGFloat {
        if isConnecting { return 0.28 }
        if isActive || isFailed { return 1 }
        return 0
    }

    private var ringColor: Color {
        if isFailed { return .red }
        if isActive && !isConnecting { return .green }
        return .accentColor
    }

    private func orbitAngle(at date: Date) -> Double {
        guard isConnecting, !reduceMotion else { return -90 }
        let phase = date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Self.orbitPeriod) / Self.orbitPeriod
        return -90 + phase * 360
    }

    private var badge: (symbol: String, color: Color)? {
        if isConnecting { return nil }
        if isFailed { return ("exclamationmark.circle.fill", .red) }
        if isActive { return ("checkmark.circle.fill", .green) }
        return nil
    }
}

/// Indeterminate progress sweep shown while connecting. It is an overlay
/// strip, so the card height never changes when it appears.
struct ConnectionLuminousBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            // Reduce Motion keeps the strip as a static progress cue.
            guard !reduceMotion else {
                phase = 0.275
                return
            }
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

// MARK: - Page skeleton
//
// Every primary page uses the same grammar: a header naming the page (the
// same word as its sidebar row) with page-level actions on the trailing edge,
// followed by content constrained by one of three width classes. Deciding the
// width here instead of per page is what keeps navigation from visibly
// reflowing the window.

enum AetherPageWidth {
    /// Forms and configuration: a comfortable reading measure.
    case reading
    /// Dashboards and card lists.
    case wide
    /// Tables that benefit from every available column.
    case full

    var maxWidth: CGFloat? {
        switch self {
        case .reading: AetherVisual.contentMaxWidth
        case .wide: AetherVisual.wideContentMaxWidth
        case .full: nil
        }
    }

    /// The centered column that holds the page. Reading content sits at the
    /// leading edge of the same column a wide page uses.
    var columnWidth: CGFloat? {
        switch self {
        case .reading, .wide: AetherVisual.wideContentMaxWidth
        case .full: nil
        }
    }
}

struct AetherPageHeader<Accessory: View>: View {
    let section: AppSection
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    init(
        _ section: AppSection,
        subtitle: String? = nil,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.section = section
        self.subtitle = subtitle
        self.accessory = accessory()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: AetherVisual.s3) {
                titles
                Spacer(minLength: AetherVisual.s2)
                accessoryRow
            }
            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                titles
                accessoryRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page-header-\(section.rawValue)")
    }

    private var titles: some View {
        VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
            Text(section.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.primary)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("page-header-title-\(section.rawValue)")
            // Two lines at most: an unbounded vertical fixedSize let the
            // stacked (narrow) header report a huge minimum height, which
            // pushed pages without a scroll view out of the window.
            Text(subtitle ?? section.subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .contentTransition(.opacity)
                .animation(AetherVisual.animation(AetherVisual.quickFade), value: subtitle)
        }
    }

    private var accessoryRow: some View {
        HStack(spacing: AetherVisual.s2) {
            accessory
        }
        .fixedSize()
    }
}

extension AetherPageHeader where Accessory == EmptyView {
    init(_ section: AppSection, subtitle: String? = nil) {
        self.init(section, subtitle: subtitle) { EmptyView() }
    }
}

private struct AetherPageContentModifier: ViewModifier {
    let width: AetherPageWidth

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: width.maxWidth, alignment: .leading)
            // Reading pages narrow only their trailing edge: every page title
            // starts on the same leading line, so switching pages never
            // shifts the header sideways.
            .frame(maxWidth: width.columnWidth, alignment: .leading)
            .frame(maxWidth: .infinity)
    }
}

extension View {
    /// Applies the shared page margins and width class to a page's scroll
    /// content. Use exactly once per primary page.
    func aetherPageContent(_ width: AetherPageWidth) -> some View {
        modifier(AetherPageContentModifier(width: width))
    }
}

/// The one search field style used by every page: magnifier, clear button,
/// and Escape to clear. Pages previously mixed a toolbar `.searchable` (which
/// was invisible because the window hides its toolbar) with plain text fields.
struct AetherSearchField: View {
    @Binding var text: String
    let prompt: String
    var accessibilityIdentifier: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: AetherVisual.sCompact) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .focused($isFocused)
                .onExitCommand { text = "" }
                .accessibilityIdentifier(accessibilityIdentifier ?? "")
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(AppLocalization.string("Clear"))
                .transition(.opacity)
            }
        }
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.sCompact)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.controlRadius, style: .continuous)
                .stroke(
                    isFocused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                    lineWidth: isFocused ? 1.5 : 0.5
                )
        }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isFocused)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: text.isEmpty)
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

/// Protocol label for a node (SS, VMess, VLESS, Trojan, Hysteria2, ...).
struct AetherProtocolBadge: View {
    let type: String

    var body: some View {
        Text(displayType)
            .font(.caption2.weight(.semibold).monospaced())
            .foregroundStyle(badgeColor == .secondary ? Color.secondary : badgeColor)
            .padding(.horizontal, AetherVisual.s1)
            .padding(.vertical, AetherVisual.sMicro)
            .background(badgeColor.opacity(0.12), in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
    }

    private var displayType: String {
        let trimmed = type.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        if trimmed.isEmpty { return "PROXY" }
        if trimmed == "HYSTERIA2" || trimmed == "HYSTERIA" { return "HY2" }
        if trimmed == "SHADOWSOCKS" { return "SS" }
        return trimmed
    }

    /// A protocol is not a state, so protocols share one neutral badge and
    /// leave colour to latency and connection state. DIRECT and REJECT are
    /// routing outcomes and keep the same colours the rule targets use.
    private var badgeColor: Color {
        switch displayType {
        case "DIRECT": return .green
        case "REJECT": return .red
        default: return .secondary
        }
    }
}

/// Latency result for one node; tapping it re-tests when an action is given.
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

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 3.5) {
                if status == .testing {
                    ProgressView()
                        .controlSize(.mini)
                } else if case .responded = status {
                    Circle()
                        .fill(pillColor)
                        .frame(width: 5, height: 5)
                }

                Text(displayText)
                    .font(.system(.caption, design: .monospaced, weight: .semibold))
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())

                if status.isMeasured, confidence == .verified {
                    // Only the stronger claim is marked. Reachability is the
                    // default, so badging it too would add noise to every row.
                    Image(systemName: confidence.symbol)
                        .font(.caption2.weight(.semibold))
                        .imageScale(.small)
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
            .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
            .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: status)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            String.localizedStringWithFormat(
                AppLocalization.string("Latency: %@"),
                status.localizedTitle
            )
        )
        .accessibilityHint(onTap == nil ? "" : AppLocalization.string("Tests this node again"))
        .onHover { hovering in
            if onTap != nil && status != .testing {
                isHovered = hovering
            }
        }
        .disabled(status == .testing || onTap == nil)
    }

    private var displayText: String {
        status.localizedTitle
    }

    /// Shares the latency bands every other latency surface uses, so a node
    /// never reads as fast in one place and slow in another.
    private var pillColor: Color {
        status.tint
    }
}

/// Node icon: the region flag when the name states one, otherwise a
/// protocol symbol.
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
        if let region = AetherRegionFlag.region(for: name) {
            // 真实匹配到的国家/地区旗帜
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }
                Text(verbatim: region.flag)
                    .font(.system(size: size * 0.55))
                    .accessibilityHidden(true)
            }
            .frame(width: size, height: size)
        } else {
            // 通用/未知地域：呈现高质感协议专用科技晶核图标
            let config = iconConfig
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.6))
                    .overlay {
                        RoundedRectangle(cornerRadius: size * 0.25, style: .continuous)
                            .stroke(Color(nsColor: .separatorColor).opacity(0.3), lineWidth: 0.5)
                    }

                // The symbol still tells protocols apart; colour is left to
                // state, so the list does not read as a rainbow.
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
            return ("bolt.fill", Color.secondary)
        }
        if upperProto.contains("VLESS") || upperName.contains("VLESS") {
            return ("shield.checkered", Color.secondary)
        }
        if upperProto.contains("VMESS") || upperName.contains("VMESS") {
            return ("cube.fill", Color.secondary)
        }
        if upperProto.contains("TROJAN") || upperName.contains("TROJAN") {
            return ("lock.shield.fill", Color.secondary)
        }
        if upperProto.contains("DIRECT") || upperName.contains("DIRECT") {
            return ("arrow.trianglehead.branch", Color.green)
        }
        if upperProto.contains("SS") || upperProto.contains("SHADOWSOCKS") || upperName.contains("SS") {
            return ("paperplane.fill", Color.secondary)
        }
        if upperProto.contains("WIREGUARD") || upperProto.contains("WG") {
            return ("shield.lefthalf.filled", Color.secondary)
        }
        return ("point.3.filled.connected.trianglepath.dotted", Color.secondary)
    }
}

// MARK: - Shared components

/// Connection state dot: steady when connected, a rotating ring while
/// connecting.
public struct AetherStatusBeacon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isConnected: Bool
    let isConnecting: Bool
    var size: CGFloat = 10

    public init(isConnected: Bool, isConnecting: Bool = false, size: CGFloat = 10) {
        self.isConnected = isConnected
        self.isConnecting = isConnecting
        self.size = size
    }

    public var body: some View {
        ZStack {
            if isConnected {
                Circle()
                    .fill(Color.green.opacity(0.22))
                    .frame(width: size * 1.8, height: size * 1.8)
                    .transition(.scale(scale: 0.5).combined(with: .opacity))
            } else if isConnecting {
                // A partial arc, so the rotation is actually visible; a full
                // circle turning in place looks identical to a still one.
                TimelineView(.animation(paused: reduceMotion)) { context in
                    Circle()
                        .trim(from: 0, to: 0.3)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                        .frame(width: size * 1.8, height: size * 1.8)
                        .rotationEffect(.degrees(angle(at: context.date)))
                }
                .transition(.opacity)
            }

            Circle()
                .fill(statusColor)
                .frame(width: size, height: size)
        }
        .frame(width: size * 2.2, height: size * 2.2)
        .animation(AetherVisual.animation(AetherVisual.gentleSpring), value: isConnected)
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isConnecting)
    }

    private func angle(at date: Date) -> Double {
        guard !reduceMotion else { return -90 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if isConnecting { return .orange }
        return .secondary.opacity(0.6)
    }
}

/// Region lookup for node names. The matching rules live in
/// `NodeRegion` so they can be unit tested; an unrecognized name yields `nil`
/// rather than a placeholder region.
enum AetherRegionFlag {
    static func region(for name: String) -> NodeRegion? {
        NodeRegion.resolve(from: name)
    }
}

/// A fixed-width flag for list rows: the region flag when the name clearly
/// states one, otherwise a neutral globe, so rows stay aligned without
/// claiming a region.
struct AetherNodeFlag: View {
    let name: String

    var body: some View {
        Group {
            if let region = AetherRegionFlag.region(for: name) {
                Text(verbatim: region.flag)
            } else {
                Image(systemName: "globe")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: AetherVisual.s4)
        .accessibilityHidden(true)
    }
}

/// Download and upload over the last 30 seconds.
public struct AetherTrafficMiniGraph: View {
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
                                colors: [Color.cyan.opacity(0.22), Color.cyan.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    smoothWaveformLine(samples: downloadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .stroke(
                            Color.cyan,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
                }

                // 上行平滑面积波形 (紫粉霓虹渐变)
                if uploadSamples.count > 1 {
                    smoothWaveformPath(samples: uploadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .fill(
                            LinearGradient(
                                colors: [Color.purple.opacity(0.18), Color.purple.opacity(0.0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    smoothWaveformLine(samples: uploadSamples, width: width, height: actualHeight, maxVal: maxVal)
                        .stroke(
                            Color.purple,
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
                        )
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


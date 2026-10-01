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
    static let panelRadius: CGFloat = 18
    static let sidebarRadius: CGFloat = 16

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
    /// Every capsule (status, count, latency) shares these insets so pills
    /// line up wherever they sit side by side.
    static let pillHorizontalPadding = s2
    static let pillVerticalPadding = s1
    /// Symbol tile at the top of every sheet.
    static let sheetIconSize: CGFloat = 44
    /// Width shared by the small single-purpose sheets (rename, subscription,
    /// archive password, iCloud, custom rule, connection details).
    static let sheetMinWidth: CGFloat = 460
    static let sheetIdealWidth: CGFloat = 520
    static let sheetMaxWidth: CGFloat = 680
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
    func body(content: Content) -> some View {
        content.aetherGlass(
            in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous)
        )
    }
}

extension View {
    /// System Liquid Glass from macOS 26, so every surface follows the
    /// person's Liquid Glass setting (clear or tinted) and Reduce
    /// Transparency exactly as Apple's own apps do. Earlier systems get the
    /// closest material with a hairline edge.
    @ViewBuilder
    func aetherGlass<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(Glass.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay { shape.stroke(Color(nsColor: .separatorColor), lineWidth: 0.5) }
        }
    }

    /// Glass buttons from macOS 26; bordered buttons before it.
    @ViewBuilder
    func aetherGlassButton(prominent: Bool = false) -> some View {
        if #available(macOS 26, *) {
            if prominent {
                buttonStyle(.glassProminent)
            } else {
                buttonStyle(.glass)
            }
        } else {
            if prominent {
                buttonStyle(.borderedProminent)
            } else {
                buttonStyle(.bordered)
            }
        }
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

/// A white symbol on a rounded colour tile, as in System Settings' sidebar
/// and rows. The colour identifies the item; it never carries state.
struct AetherIconTile: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 22

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.55, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// A large title and the page's actions, as in System Settings. The
/// section's one-line description stays available to VoiceOver only.
struct AetherPageHeader<Accessory: View>: View {
    let section: AppSection
    @ViewBuilder var accessory: Accessory

    init(
        _ section: AppSection,
        @ViewBuilder accessory: () -> Accessory
    ) {
        self.section = section
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
        Text(section.title)
            .font(.largeTitle.weight(.bold))
            .foregroundStyle(.primary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityHint(Text(section.subtitle))
            .accessibilityIdentifier("page-header-title-\(section.rawValue)")
    }

    private var accessoryRow: some View {
        HStack(spacing: AetherVisual.s2) {
            accessory
        }
        .fixedSize()
    }
}

extension AetherPageHeader where Accessory == EmptyView {
    init(_ section: AppSection) {
        self.init(section) { EmptyView() }
    }
}

private struct AetherPageContentModifier: ViewModifier {
    let width: AetherPageWidth

    func body(content: Content) -> some View {
        glassContainer(
            content
                .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                .padding(.top, AetherVisual.pageTopPadding)
                .padding(.bottom, AetherVisual.pageBottomPadding)
                .frame(maxWidth: width.maxWidth, alignment: .leading)
                // Reading pages narrow only their trailing edge: every page
                // title starts on the same leading line, so switching pages
                // never shifts the header sideways.
                .frame(maxWidth: width.columnWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        )
    }

    /// All of a page's glass renders in one container, as Apple recommends
    /// for several glass shapes: one pass instead of one per card. Zero
    /// spacing keeps neighbouring cards from merging into each other.
    @ViewBuilder
    private func glassContainer<V: View>(_ view: V) -> some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: 0) { view }
        } else {
            view
        }
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

    /// Takes an already-localized title. A `LocalizedStringKey` overload
    /// used to sit beside this one, but Swift resolves a bare literal to the
    /// `String` overload, so literal titles silently stayed in English.
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
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if let systemImage {
                Image(systemName: systemImage)
                    .accessibilityHidden(true)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
            title
        }
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isWorking)
        .accessibilityElement(children: .combine)
    }
}

/// A number in a gray capsule: sidebar counts and section counts.
struct AetherCountBadge: View {
    let count: Int

    var body: some View {
        Text(verbatim: "\(count)")
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .padding(.horizontal, AetherVisual.sCompact)
            .padding(.vertical, AetherVisual.sMicro)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .aetherNumericValue(count)
    }
}

/// The heading above a group of cards on every page: symbol, title, an
/// optional count and optional trailing actions. Pages used to mix plain
/// text headings, symbol headings and card titles repeating the heading.
struct AetherSectionHeader<Accessory: View>: View {
    let title: String
    let symbol: String
    var count: Int?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: AetherVisual.s2) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol)
            }
            .font(.headline)
            if let count {
                AetherCountBadge(count: count)
            }
            Spacer(minLength: AetherVisual.s2)
            accessory()
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isHeader)
    }
}

extension AetherSectionHeader where Accessory == EmptyView {
    init(title: String, symbol: String, count: Int? = nil) {
        self.init(title: title, symbol: symbol, count: count) { EmptyView() }
    }
}

/// The one header every sheet uses: a tinted symbol tile, the title, and a
/// single sentence saying what the sheet is for. Sheets used to size their
/// tiles, titles and subtitles independently, so opening two in a row read
/// like two different apps.
struct AetherSheetHeader<Accessory: View>: View {
    let symbol: String
    let title: String
    var subtitle: String?
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .center, spacing: AetherVisual.s4) {
            // The same colour tile as the sidebar and rows, larger.
            AetherIconTile(symbol: symbol, color: .blue, size: AetherVisual.sheetIconSize)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: AetherVisual.s2)
            accessory()
        }
    }
}

extension AetherSheetHeader where Accessory == EmptyView {
    init(symbol: String, title: String, subtitle: String? = nil) {
        self.init(symbol: symbol, title: title, subtitle: subtitle) { EmptyView() }
    }
}

extension View {
    /// Every Settings pane and form sheet: sections as glass cards, the same
    /// as the main window's pages, with an optional large page title.
    func aetherSettingsForm(title: String? = nil, isSheet: Bool = false) -> some View {
        formStyle(AetherGlassFormStyle(title: title, isSheet: isSheet))
    }

    func aetherPanel() -> some View {
        modifier(AetherPanelModifier())
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
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isHovered)
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

/// Connection state dot: steady when connected, a rotating ring while
/// connecting.
public struct AetherStatusBeacon: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isConnected: Bool
    let isConnecting: Bool
    let isFailed: Bool
    var size: CGFloat = 10

    public init(isConnected: Bool, isConnecting: Bool = false, isFailed: Bool = false, size: CGFloat = 10) {
        self.isConnected = isConnected
        self.isConnecting = isConnecting
        self.isFailed = isFailed
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
        .animation(AetherVisual.animation(AetherVisual.quickFade), value: isFailed)
    }

    private func angle(at date: Date) -> Double {
        guard !reduceMotion else { return -90 }
        return date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1) * 360
    }

    private var statusColor: Color {
        if isConnected { return .green }
        if isConnecting { return .orange }
        // Red like the menu bar panel and the overview lens, so a failure
        // never reads as a plain "not connected".
        if isFailed { return .red }
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

/// The region a node's name states, as a short code such as "SG". Text,
/// not a flag, so it reads the same in every font and on every glass tint.
/// Rows reserve the slot for unrecognised names so the names line up.
struct AetherRegionCode: View {
    let name: String
    var reservesSlot = true

    var body: some View {
        Group {
            if let region = AetherRegionFlag.region(for: name) {
                Text(verbatim: region.code)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 18)
                    .background(Color.secondary.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else if reservesSlot {
                Color.clear.frame(width: 26, height: 18)
            }
        }
        .accessibilityHidden(true)
    }
}

/// A capsule of system glass with full-contrast text. The menu bar panel
/// never activates the app, and AppKit draws its own buttons there as if
/// disabled; this keeps them reading as live controls.
struct AetherGlassCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        AetherGlassCapsuleLabel(configuration: configuration)
    }
}

private struct AetherGlassCapsuleLabel: View {
    @Environment(\.isEnabled) private var isEnabled
    let configuration: ButtonStyleConfiguration

    var body: some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, AetherVisual.s3 + AetherVisual.sMicro)
            .frame(minHeight: 32)
            .contentShape(Capsule())
            .aetherGlass(in: Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.45)
            .animation(AetherVisual.animation(AetherVisual.pressFeedback), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == AetherGlassCapsuleButtonStyle {
    static var aetherGlassCapsule: AetherGlassCapsuleButtonStyle { AetherGlassCapsuleButtonStyle() }
}

/// Download and upload over the last 30 seconds.
/// A single-series trend line, small enough to sit under a value. Fewer
/// than two samples draw nothing; the frame keeps its height either way.
struct AetherSparkline: View {
    let values: [Double]
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            if values.count > 1 {
                let peak = max(values.max() ?? 0, 1)
                let step = proxy.size.width / CGFloat(values.count - 1)
                let height = proxy.size.height
                Path { path in
                    for (index, value) in values.enumerated() {
                        let point = CGPoint(
                            x: CGFloat(index) * step,
                            y: height - 1 - CGFloat(value / peak) * (height - 2)
                        )
                        if index == 0 {
                            path.move(to: point)
                        } else {
                            path.addLine(to: point)
                        }
                    }
                }
                .stroke(tint, style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }
}

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
        // Until 30 seconds have been sampled, the first value extends flat to
        // the left edge. Dropping to the baseline there drew a cliff that
        // looked like a traffic spike.
        if let first = deduped.first, first.x > 0 {
            result.append(CGPoint(x: 0, y: first.y))
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



// MARK: - Glass forms

/// Settings drawn like the rest of the app: each section a caption over a
/// glass card whose rows are divided by inset hairlines. The panes keep
/// ordinary `Form`, `Section`, `Toggle` and `LabeledContent` content.
struct AetherGlassFormStyle: FormStyle {
    var title: String?
    /// Sheets use the dialog margins instead of a page's.
    var isSheet = false

    func makeBody(configuration: Configuration) -> some View {
        ScrollView {
            let stack = VStack(alignment: .leading, spacing: isSheet ? AetherVisual.s4 : AetherVisual.s5) {
                if let title {
                    Text(title)
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(.primary)
                        .accessibilityAddTraits(.isHeader)
                }
                ForEach(sections: configuration.content) { section in
                    AetherGlassFormSection(section: section)
                }
            }
            if isSheet {
                stack.padding(AetherVisual.dialogPadding)
            } else {
                stack.aetherPageContent(.reading)
            }
        }
        .toggleStyle(AetherRowToggleStyle())
        .labeledContentStyle(AetherRowLabeledContentStyle())
    }
}

private struct AetherGlassFormSection: View {
    let section: SectionConfiguration

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            if !section.header.isEmpty {
                HStack(spacing: AetherVisual.s2) {
                    section.header
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AetherVisual.s1)
                .accessibilityAddTraits(.isHeader)
            }
            if !section.content.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(section.content) { row in
                        row
                            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
                            .padding(.horizontal, AetherVisual.s4)
                            .padding(.vertical, AetherVisual.s3)
                        if row.id != section.content.last?.id {
                            Divider()
                                .padding(.leading, AetherVisual.s4)
                        }
                    }
                }
                .aetherGlass(in: RoundedRectangle(cornerRadius: AetherVisual.panelRadius, style: .continuous))
            }
            if !section.footer.isEmpty {
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    section.footer
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AetherVisual.s1)
            }
        }
    }
}

/// The label leading and a switch trailing, as in System Settings. The
/// accessibility representation keeps it one native switch, so identifiers
/// and VoiceOver land on the control.
struct AetherRowToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AetherVisual.s3) {
            configuration.label
                .foregroundStyle(.primary)
            Spacer(minLength: AetherVisual.s3)
            Toggle("", isOn: configuration.$isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .accessibilityRepresentation {
            // A hidden label becomes the switch's own name instead of a
            // separate text element it merely points to.
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// The label leading and the value or control trailing.
struct AetherRowLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: AetherVisual.s3) {
            configuration.label
            Spacer(minLength: AetherVisual.s3)
            configuration.content
                .multilineTextAlignment(.trailing)
        }
    }
}

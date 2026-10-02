import AetherRouteKit
import SwiftUI

struct FeatureSection<Content: View, Accessory: View>: View {
    let title: String
    let symbol: String
    var count: Int?
    let accessory: Accessory
    let content: Content

    init(
        title: String,
        symbol: String,
        count: Int? = nil,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.count = count
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            AetherSectionHeader(title: title, symbol: symbol, count: count) { accessory }
            content
        }
    }
}

extension FeatureSection where Accessory == EmptyView {
    init(title: String, symbol: String, count: Int? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, count: count, accessory: { EmptyView() }, content: content)
    }
}

struct ProviderRow: View {
    let provider: ProviderConfigurationSummary

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: "shippingbox.fill")
                .foregroundStyle(Color.accentColor)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(provider.name).fontWeight(.medium)
                Text(provider.sourceType.uppercased())
                    .font(.caption.monospaced())
                    .foregroundStyle(AetherVisual.secondaryText)
            }
            Spacer()
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s3)
        .accessibilityElement(children: .combine)
    }
}

func formattedRate(_ bytes: UInt64) -> String {
    if bytes < 1024 {
        return "\(bytes) B/s"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB/s", kb).replacingOccurrences(of: ".0 ", with: " ")
    } else if bytes < 1024 * 1024 * 1024 {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB/s", mb).replacingOccurrences(of: ".0 ", with: " ")
    } else {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return String(format: "%.2f GB/s", gb)
    }
}

func formattedBytes(_ bytes: UInt64) -> String {
    if bytes < 1024 {
        return "\(bytes) B"
    } else if bytes < 1024 * 1024 {
        let kb = Double(bytes) / 1024.0
        return String(format: "%.1f KB", kb).replacingOccurrences(of: ".0 ", with: " ")
    } else if bytes < 1024 * 1024 * 1024 {
        let mb = Double(bytes) / (1024.0 * 1024.0)
        return String(format: "%.1f MB", mb).replacingOccurrences(of: ".0 ", with: " ")
    } else {
        let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
        return String(format: "%.2f GB", gb)
    }
}

struct StatePill: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        HStack(spacing: AetherVisual.s1) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(title)
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .contain)
        .font(.caption.weight(.semibold))
        .padding(.horizontal, AetherVisual.pillHorizontalPadding)
        .padding(.vertical, AetherVisual.pillVerticalPadding)
        .background(
            color.opacity(0.12),
            in: Capsule()
        )
    }
}

struct FeatureEmptyState: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(detail)
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .aetherPanel()
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(detail))
    }
}

struct TruncationNotice: View {
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        if visibleCount < totalCount {
            Label(
                AppLocalization.format(
                    "Showing %lld of %lld items",
                    Int64(visibleCount),
                    Int64(totalCount)
                ),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(AetherVisual.secondaryText)
        }
    }
}

struct DiscardChangesModifier: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    let isDirty: Bool
    let isSaving: Bool
    @Binding var requested: Bool

    func body(content: Content) -> some View {
        content
            .interactiveDismissDisabled(isDirty || isSaving)
            .confirmationDialog("Discard unsaved changes?", isPresented: Binding(
                get: { requested && isDirty },
                set: { requested = $0 }
            ), titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) { requested = false }
            }
            .onChange(of: requested) { _, value in
                if value && !isDirty && !isSaving { dismiss() }
            }
    }
}

/// Keeps the host's traffic polling matched to what the person can actually
/// see: every 3 s while this surface is in a frontmost visible window, every
/// 10 s while it is visible behind another app, and not at all once it is
/// minimized, hidden, fully covered or navigated away from.
private struct TelemetryDemandModifier: ViewModifier {
    @EnvironmentObject private var tunnel: TunnelManager
    let source: String
    /// The strongest demand this surface may ask for.
    var ceiling: TunnelManager.TelemetryDemand = .realtime
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isPresented = true
                update()
            }
            .onDisappear {
                isPresented = false
                tunnel.setTelemetryDemand(.none, for: source)
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didMiniaturizeNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didDeminiaturizeNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeOcclusionStateNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didHideNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didUnhideNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in update() }
    }

    private func update() {
        // Window and occlusion state settle after the notification that
        // reported them, so read them on the next turn of the run loop.
        DispatchQueue.main.async {
            guard isPresented else { return }
            let app = NSApplication.shared
            let hasVisibleWindow = !app.isHidden && app.windows.contains { window in
                window.isVisible && !window.isMiniaturized && !(window is NSPanel)
                    && window.occlusionState.contains(.visible)
            }
            var demand: TunnelManager.TelemetryDemand =
                !hasVisibleWindow ? .none : (app.isActive ? .realtime : .background)
            if ceiling == .background && demand == .realtime { demand = .background }
            tunnel.setTelemetryDemand(demand, for: source)
        }
    }
}

extension View {
    /// Declares that this surface shows live traffic, identified by `source`.
    func telemetryDemand(source: String) -> some View {
        modifier(TelemetryDemandModifier(source: source))
    }

    /// Keeps a slow (10 s) traffic history while this surface is visible,
    /// without asking for the 3 s live cadence.
    func backgroundTelemetryDemand(source: String) -> some View {
        modifier(TelemetryDemandModifier(source: source, ceiling: .background))
    }
}

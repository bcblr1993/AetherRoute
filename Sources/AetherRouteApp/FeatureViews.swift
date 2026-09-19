import AetherRouteKit
import SwiftUI

struct FeatureSection<Content: View>: View {
    let title: Text
    let symbol: String
    @ViewBuilder let content: Content

    init(title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.symbol = symbol
        self.content = content()
    }

    init(title: LocalizedStringKey, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = Text(title)
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s3) {
            Label {
                title
            } icon: {
                Image(systemName: symbol)
            }
            .font(.headline)
            content
        }
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
                    .foregroundStyle(.secondary)
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

struct TargetPillView: View {
    let target: String
    var isHovered: Bool = false

    var body: some View {
        HStack(spacing: AetherVisual.s1) {
            Image(systemName: iconName)
                .font(.system(size: 9, weight: .bold))
                .accessibilityHidden(true)

            Text(target)
                .font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(foregroundColor)
        .padding(.horizontal, AetherVisual.s2)
        .padding(.vertical, AetherVisual.s1)
        .background(pillColor.opacity(0.12), in: Capsule())
        .overlay {
            Capsule()
                .stroke(pillColor.opacity(0.28), lineWidth: 0.6)
        }
        .lineLimit(1)
    }

    private var upperTarget: String {
        target.uppercased()
    }

    private var pillColor: Color {
        if upperTarget == "DIRECT" { return .green }
        if upperTarget == "REJECT" { return .red }
        return .indigo
    }

    private var foregroundColor: Color {
        if upperTarget == "DIRECT" { return .green }
        if upperTarget == "REJECT" { return .red }
        return .primary
    }

    private var iconName: String {
        if upperTarget == "DIRECT" { return "arrow.forward" }
        if upperTarget == "REJECT" { return "hand.raised.fill" }
        return "arrow.triangle.branch"
    }
}

struct StatePill: View {
    let title: String
    let color: Color
    let symbol: String

    var body: some View {
        Label {
            Text(title)
                .foregroundStyle(color)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(color)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, AetherVisual.s3)
        .padding(.vertical, AetherVisual.s1)
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
                String.localizedStringWithFormat(
                    AppLocalization.string("Showing %lld of %lld items."),
                    visibleCount,
                    totalCount
                ),
                systemImage: "info.circle"
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

extension View {
    func featureCard() -> some View {
        aetherPanel()
    }
}

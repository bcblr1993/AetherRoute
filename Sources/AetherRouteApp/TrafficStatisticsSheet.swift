import AetherRouteKit
import SwiftUI

/// Traffic over the last day, week or month, by app and by exit node. The
/// totals are the engine's own counters; the split is what the connection
/// list showed between samples, so very short connections count toward the
/// total but toward no app.
struct TrafficStatisticsSheet: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var statistics: TrafficStatisticsModel
    @Environment(\.dismiss) private var dismiss
    @State private var range: StatisticsRange = .today
    @State private var isClearConfirmationPresented = false

    enum StatisticsRange: Hashable, CaseIterable {
        case today
        case week
        case month

        var days: Int {
            switch self {
            case .today: 1
            case .week: 7
            case .month: 30
            }
        }

        var title: String {
            switch self {
            case .today: AppLocalization.string("Today")
            case .week: AppLocalization.string("7 Days")
            case .month: AppLocalization.string("30 Days")
            }
        }
    }

    private static let listedEntries = 10

    var body: some View {
        let summary = summary
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            AetherSheetHeader(
                symbol: "chart.bar.xaxis",
                title: AppLocalization.string("Traffic Statistics"),
                subtitle: AppLocalization.string("Counted on this Mac only. Nothing is uploaded."),
                tint: AppSection.overview.tileColor
            ) {
                AetherSegmentedPicker(
                    selection: $range,
                    options: StatisticsRange.allCases.map { .init(value: $0, title: $0.title) },
                    accessibilityLabel: AppLocalization.string("Period"),
                    accessibilityIdentifier: "traffic-statistics-range"
                )
                .fixedSize()
            }

            if !tunnel.isTrafficStatisticsEnabled {
                HStack(spacing: AetherVisual.s3) {
                    Label(
                        AppLocalization.string("Statistics are off, so nothing is being counted."),
                        systemImage: "pause.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: AetherVisual.s2)
                    Button(AppLocalization.string("Turn On")) {
                        tunnel.setTrafficStatisticsEnabled(true)
                    }
                    .aetherGlassButton()
                    .accessibilityIdentifier("traffic-statistics-enable")
                }
                .padding(AetherVisual.cardPadding)
                .aetherPanel()
            }

            HStack(spacing: AetherVisual.s6) {
                totalMetric(
                    title: AppLocalization.string("Download"),
                    value: summary.total.download
                )
                totalMetric(
                    title: AppLocalization.string("Upload"),
                    value: summary.total.upload
                )
                Spacer(minLength: 0)
            }
            .padding(AetherVisual.cardPadding)
            .aetherPanel()

            ScrollView {
                VStack(alignment: .leading, spacing: AetherVisual.sectionSpacing) {
                    breakdown(
                        title: AppLocalization.string("By app"),
                        entries: appEntries(summary),
                        total: summary.total.total
                    )
                    breakdown(
                        title: AppLocalization.string("By node"),
                        entries: nodeEntries(summary),
                        total: summary.total.total
                    )
                    Text(AppLocalization.string("Totals come from the network engine. The split by app and node is estimated from the connection list, so the parts can add up to less than the total."))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, AetherVisual.sectionHeaderInset)
                }
            }

            HStack {
                Button(AppLocalization.string("Clear Statistics…"), role: .destructive) {
                    isClearConfirmationPresented = true
                }
                .disabled(statistics.ledger.days.isEmpty)
                .confirmationDialog(
                    AppLocalization.string("Clear all traffic statistics?"),
                    isPresented: $isClearConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button(AppLocalization.string("Clear"), role: .destructive) {
                        tunnel.clearTrafficStatistics()
                    }
                }
                Spacer()
                Button(AppLocalization.string("Done")) { dismiss() }
                    .aetherGlassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .onAppear { tunnel.loadTrafficLedgerIfNeeded() }
        .accessibilityIdentifier("traffic-statistics")
    }

    private var summary: TrafficDay {
        statistics.ledger.summary(lastDays: range.days)
    }

    private struct Entry: Identifiable {
        let id: String
        let name: String
        let volume: TrafficVolume
    }

    private func appEntries(_ summary: TrafficDay) -> [Entry] {
        summary.apps
            .map { Entry(id: $0.key, name: summary.appNames[$0.key] ?? $0.key, volume: $0.value) }
            .sorted { $0.volume.total > $1.volume.total }
    }

    private func nodeEntries(_ summary: TrafficDay) -> [Entry] {
        summary.nodes
            .map { Entry(id: $0.key, name: $0.key, volume: $0.value) }
            .sorted { $0.volume.total > $1.volume.total }
    }

    private func totalMetric(title: String, value: UInt64) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
            Text(title)
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
            Text(verbatim: formattedBytes(value))
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func breakdown(title: String, entries: [Entry], total: UInt64) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            AetherSectionHeader(title: title, count: entries.isEmpty ? nil : entries.count)
            VStack(spacing: 0) {
                if entries.isEmpty {
                    Text(AppLocalization.string("No traffic recorded for this period."))
                        .font(.subheadline)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(AetherVisual.cardPadding)
                } else {
                    ForEach(entries.prefix(Self.listedEntries)) { entry in
                        StatisticsRow(name: entry.name, volume: entry.volume, total: total)
                        if entry.id != entries.prefix(Self.listedEntries).last?.id {
                            Divider().padding(.leading, AetherVisual.s4)
                        }
                    }
                }
            }
            .aetherPanel()
        }
    }
}

private struct StatisticsRow: View {
    let name: String
    let volume: TrafficVolume
    let total: UInt64

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(name)
                GeometryReader { proxy in
                    Capsule()
                        .fill(AetherVisual.neutralFill)
                        .overlay(alignment: .leading) {
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: proxy.size.width * share)
                        }
                }
                .frame(height: AetherVisual.statusDotSize)
                .accessibilityHidden(true)
            }
            Spacer(minLength: AetherVisual.s3)
            VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
                Text(verbatim: "↓ \(formattedBytes(volume.download))")
                Text(verbatim: "↑ \(formattedBytes(volume.upload))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AetherVisual.secondaryText)
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s2)
        .frame(minHeight: AetherVisual.listRowHeight)
        .accessibilityElement(children: .combine)
    }

    private var share: CGFloat {
        guard total > 0 else { return 0 }
        return min(1, CGFloat(Double(volume.total) / Double(total)))
    }
}

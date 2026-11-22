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
    @State private var showsAllApps = false
    @State private var showsAllNodes = false

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
                    .aetherButton()
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
                        total: summary.total.total,
                        showsAll: $showsAllApps
                    )
                    breakdown(
                        title: AppLocalization.string("By node"),
                        entries: nodeEntries(summary),
                        total: summary.total.total,
                        showsAll: $showsAllNodes
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
                .aetherButton()
                .disabled(statistics.ledger.days.isEmpty)
                .accessibilityIdentifier("traffic-statistics-clear")
                .confirmationDialog(
                    AppLocalization.string("Clear all traffic statistics?"),
                    isPresented: $isClearConfirmationPresented,
                    titleVisibility: .visible
                ) {
                    Button(AppLocalization.string("Clear"), role: .destructive) {
                        tunnel.clearTrafficStatistics()
                    }
                    Button(AppLocalization.string("Cancel"), role: .cancel) {}
                } message: {
                    Text(
                        AppLocalization.string(
                            "This clears all saved daily traffic records on this Mac, not just the selected period."
                        )
                    )
                }
                Spacer()
                Button(AppLocalization.string("Done")) { dismiss() }
                    .aetherButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("traffic-statistics-done")
            }
            .controlSize(.large)
        }
        .padding(AetherVisual.dialogPadding)
        .aetherLargeSheetFrame()
        .onAppear { tunnel.loadTrafficLedgerIfNeeded() }
        .onExitCommand {
            if !isClearConfirmationPresented {
                dismiss()
            }
        }
        // Without .contain, SwiftUI pushes the container identifier down onto
        // every child and overwrites theirs (traffic-statistics-clear, …).
        .accessibilityElement(children: .contain)
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
    private func breakdown(
        title: String,
        entries: [Entry],
        total: UInt64,
        showsAll: Binding<Bool>
    ) -> some View {
        let visibleEntries = showsAll.wrappedValue ? entries : Array(entries.prefix(Self.listedEntries))
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
                    ForEach(visibleEntries) { entry in
                        StatisticsRow(name: entry.name, volume: entry.volume, total: total)
                        if entry.id != visibleEntries.last?.id {
                            Divider().padding(.leading, AetherVisual.s4)
                        }
                    }
                }
            }
            .aetherPanel()
            if entries.count > Self.listedEntries {
                HStack(spacing: AetherVisual.s2) {
                    if !showsAll.wrappedValue {
                        TruncationNotice(visibleCount: Self.listedEntries, totalCount: entries.count)
                    }
                    Spacer(minLength: AetherVisual.s2)
                    Button {
                        showsAll.wrappedValue.toggle()
                    } label: {
                        Text(
                            showsAll.wrappedValue
                                ? AppLocalization.string("Show less")
                                : AppLocalization.format("Show all (%lld)", Int64(entries.count))
                        )
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
                .padding(.horizontal, AetherVisual.sectionHeaderInset)
            }
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
                Text(verbatim: name)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(Text(verbatim: name))
                Capsule()
                    .fill(AetherVisual.neutralFill)
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(Color.accentColor)
                            .scaleEffect(x: share.isFinite ? min(1, max(0, share)) : 0, y: 1, anchor: .leading)
                    }
                    .clipShape(Capsule())
                    .frame(height: AetherVisual.statusDotSize)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
                Text(verbatim: "↓ \(formattedBytes(volume.download))")
                Text(verbatim: "↑ \(formattedBytes(volume.upload))")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(AetherVisual.secondaryText)
            .fixedSize(horizontal: true, vertical: false)
            .layoutPriority(1)
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

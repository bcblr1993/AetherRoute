import AetherRouteKit
import SwiftUI

/// The connections page exists to show the flow list. State is compressed into
/// a single session bar so the table gets the screen: previously five separate
/// boxes all restated "not connected" while the one thing worth looking at had
/// nowhere to go.
struct ConnectionsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var telemetry: NetworkTelemetryViewModel
    @State private var filter: ConnectionOutletFilter = .all
    @State private var sort: ConnectionSort = .traffic

    var body: some View {
        let rows = connectionRows
        VStack(spacing: 0) {
            SessionBar(telemetry: telemetry)
                .environmentObject(tunnel)
                .padding(.horizontal, AetherVisual.s4)
                .padding(.top, AetherVisual.s3)

            if telemetry.snapshot.connections.isEmpty {
                emptyState
            } else {
                connectionList(rows: rows)
            }

            HStack {
                Text(footerText(visibleCount: rows.count))
                Spacer()
                Text("Only connections visible on this Mac are counted, and nothing is reported anywhere.")
            }
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .padding(.horizontal, AetherVisual.s4)
                .frame(height: 24)
                .overlay(alignment: .top) { Divider() }
        }
        .accessibilityIdentifier("connections-page")
    }

    /// The empty state explains what will appear here once connected, which
    /// also answers why it is empty now.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                tunnel.isConnected
                    ? "No active connections"
                    : "Connections appear here once you connect",
                systemImage: "arrow.left.arrow.right"
            )
        } description: {
            Text("Each row shows the destination, the rule that matched, which outlet carried it, and how much it moved. Nothing is fabricated while the session is stopped.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AetherVisual.s6)
    }

    private func connectionList(rows: [ConnectionTableItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: AetherVisual.s2) {
                Picker("Filter", selection: $filter) {
                    ForEach(ConnectionOutletFilter.allCases) { option in
                        Text(label(for: option)).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 330)

                Spacer(minLength: AetherVisual.s2)

                Picker("Sort", selection: $sort) {
                    ForEach(ConnectionSort.allCases) { option in
                        Text(option.localizedTitle).tag(option)
                    }
                }
                .labelsHidden()
                .accessibilityIdentifier("connections-sort-picker")
                .frame(width: 112)

                if tunnel.isConnected {
                    Button("Disconnect all") {
                        Task { await tunnel.setEnabled(false) }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.accentColor)
                    .disabled(tunnel.isTransitioning)
                    .accessibilityIdentifier("disconnect-all-connections")
                }
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.s2)

            Table(rows) {
                TableColumn("Destination") { row in
                    ConnectionDestinationCell(connection: row.connection)
                }
                TableColumn("Matched rule") { row in
                    ConnectionRuleCell(connection: row.connection)
                }
                .width(min: 120, ideal: 150, max: 170)
                TableColumn("Outlet") { row in
                    ConnectionOutletCell(connection: row.connection)
                }
                .width(min: 92, ideal: 104, max: 120)
                TableColumn("Traffic") { row in
                    ConnectionTrafficCell(connection: row.connection)
                }
                .width(min: 82, ideal: 88, max: 96)
                TableColumn("Duration") { row in
                    ConnectionDurationCell(connection: row.connection)
                }
                .width(min: 64, ideal: 68, max: 76)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .accessibilityLabel("Connections")
            .accessibilityIdentifier("connections-table")
            .scrollIndicators(.hidden, axes: .horizontal)
        }
    }

    private var connectionRows: [ConnectionTableItem] {
        ConnectionTableItem.identify(telemetry.snapshot.connections)
            .filter {
                ConnectionOutlet(proxyChain: $0.connection.proxyChain).matches(filter)
            }
            .sorted { lhs, rhs in
                switch sort {
                case .traffic:
                    return lhs.connection.downloadTotal + lhs.connection.uploadTotal
                        > rhs.connection.downloadTotal + rhs.connection.uploadTotal
                case .destination:
                    return lhs.connection.destination.localizedStandardCompare(
                        rhs.connection.destination
                    )
                        == .orderedAscending
                }
            }
    }

    private func footerText(visibleCount: Int) -> String {
        String.localizedStringWithFormat(
            AppLocalization.string("Showing %lld of %lld connections"),
            Int64(visibleCount),
            Int64(telemetry.snapshot.connections.count)
        )
    }

    private enum ConnectionSort: String, CaseIterable, Identifiable {
        case traffic
        case destination

        var id: Self { self }

        var localizedTitle: String {
            switch self {
            case .traffic: AppLocalization.string("By traffic")
            case .destination: AppLocalization.string("By destination")
            }
        }
    }

    private func label(for option: ConnectionOutletFilter) -> String {
        let count = telemetry.snapshot.connections.filter {
            ConnectionOutlet(proxyChain: $0.proxyChain).matches(option)
        }.count
        return "\(option.localizedTitle) \(count)"
    }
}

/// One 44pt row that is the only place this page reports state. Rates read as
/// an em dash when nothing is running: zero is a measurement, and claiming a
/// measurement that was never taken is what made the old page feel wrong.
private struct SessionBar: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s2) {
                Image(systemName: stateSymbol)
                    .font(.caption)
                    .foregroundStyle(stateTint)
                    .accessibilityHidden(true)
                Text(tunnel.statusTitle)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
            }

            if !tunnel.isConnected {
                Text("Traffic is using the normal network path")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let duration {
                Text(duration)
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Elapsed")
            }

            Divider().frame(height: 20)

            rate(symbol: "arrow.down", value: downloadText)
                .accessibilityIdentifier("connections-download-title")
            rate(symbol: "arrow.up", value: uploadText)
                .accessibilityIdentifier("connections-upload-title")

            Spacer(minLength: AetherVisual.s3)

            if let outlet {
                Divider().frame(height: 20)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Outlet")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text(outlet)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                }
            }

            if !tunnel.isConnected {
                Button(tunnel.primaryActionTitle) {
                    Task { await tunnel.setEnabled(!tunnel.isEnabled) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!tunnel.canPerformPrimaryAction)
                .accessibilityIdentifier("connections-primary-action")
            }
        }
        .padding(.horizontal, AetherVisual.pageHorizontalPadding)
        .frame(height: 44)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections-session-bar")
    }

    private func rate(symbol: String, value: String) -> some View {
        HStack(spacing: AetherVisual.s1) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(value)
                .font(.body.monospacedDigit())
        }
        .accessibilityElement(children: .combine)
    }

    private var downloadText: String {
        tunnel.isConnected
            ? formattedRate(telemetry.snapshot.downloadBytesPerSecond)
            : "—"
    }

    private var uploadText: String {
        tunnel.isConnected
            ? formattedRate(telemetry.snapshot.uploadBytesPerSecond)
            : "—"
    }

    private var outlet: String? {
        guard tunnel.isConnected else { return nil }
        return tunnel.proxySelections.values.compactMap(\.selectedMember).first
    }

    private var duration: String? {
        guard let since = tunnel.connectedSince, tunnel.isConnected else {
            return nil
        }
        let elapsed = Int(Date.now.timeIntervalSince(since))
        guard elapsed >= 0, elapsed <= 31 * 24 * 3_600 else { return nil }
        return String(
            format: "%02d:%02d:%02d",
            elapsed / 3_600,
            (elapsed % 3_600) / 60,
            elapsed % 60
        )
    }

    private var stateSymbol: String {
        switch tunnel.state {
        case .connected: "circle.fill"
        case .connecting, .disconnecting, .loading: "circle.dotted"
        case .failed: "exclamationmark.triangle.fill"
        case .privacyConsentRequired: "hand.raised.fill"
        case .disconnected: "circle"
        }
    }

    private var stateTint: Color {
        switch tunnel.state {
        case .connected: .green
        case .connecting, .disconnecting, .loading, .privacyConsentRequired: .orange
        case .failed: .red
        case .disconnected: .secondary
        }
    }
}

private struct ConnectionDestinationCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        HStack(spacing: AetherVisual.s3) {
            Circle()
                .fill(outlet == .rejected ? Color.red : Color.green)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: AetherVisual.s1) {
                Text(verbatim: "\(connection.destination):\(connection.destinationPort)")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(connection.transport == .tcp ? "TCP" : "UDP")
                    .font(.subheadline.monospaced().weight(.medium))
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 36)
        .foregroundStyle(.primary)
        .background(
            outlet == .rejected
                ? Color.red.opacity(0.08)
                : Color(nsColor: .controlBackgroundColor)
        )
        .accessibilityElement(children: .contain)
    }

    private var outlet: ConnectionOutlet {
        ConnectionOutlet(proxyChain: connection.proxyChain)
    }

}

private struct ConnectionRuleCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        Text(ruleText)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var ruleText: String {
        let payload = connection.rulePayload.trimmingCharacters(in: .whitespaces)
        guard !payload.isEmpty else { return connection.rule }
        return "\(connection.rule) \(payload)"
    }
}

private struct ConnectionOutletCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        Label(outlet.localizedTitle, systemImage: outletSymbol)
            .font(.caption.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
    }

    private var outlet: ConnectionOutlet {
        ConnectionOutlet(proxyChain: connection.proxyChain)
    }

    private var outletSymbol: String {
        switch outlet {
        case .proxied: "arrow.triangle.branch"
        case .direct: "arrow.forward"
        case .rejected: "hand.raised.fill"
        }
    }

}

private struct ConnectionTrafficCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        VStack(alignment: .trailing, spacing: AetherVisual.s1) {
            Text(verbatim: "↓ \(formattedBytes(connection.downloadTotal))")
            Text(verbatim: "↑ \(formattedBytes(connection.uploadTotal))")
        }
        .font(.caption.monospacedDigit())
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ConnectionDurationCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        Text(duration)
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var duration: String {
        let started = Double(connection.startedAtUnixMilliseconds) / 1_000
        let elapsed = Int(Date.now.timeIntervalSince1970 - started)
        // A stale or malformed provider timestamp must not turn into a
        // multi-thousand-hour duration in the table.
        guard elapsed >= 0, elapsed <= 31 * 24 * 3_600 else { return "—" }
        if elapsed >= 3_600 {
            return String(format: "%dh%02dm", elapsed / 3_600, (elapsed % 3_600) / 60)
        }
        if elapsed >= 60 {
            return String(format: "%dm%02ds", elapsed / 60, elapsed % 60)
        }
        return "\(elapsed)s"
    }
}

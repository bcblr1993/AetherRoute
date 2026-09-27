import AppKit
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
    @State private var showingDisconnectConfirmation = false
    @State private var searchText = ""
    @State private var pausedConnections: [ConnectionTelemetry]?
    @State private var inspectedConnection: ConnectionTableItem?

    private var displayedConnections: [ConnectionTelemetry] {
        pausedConnections ?? telemetry.snapshot.connections
    }

    var body: some View {
        let rows = connectionRows
        VStack(spacing: 0) {
            SessionBar(telemetry: telemetry)
                .environmentObject(tunnel)
                .padding(.horizontal, AetherVisual.s4)
                .padding(.top, AetherVisual.s3)

            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(AppLocalization.string("Search connections"), text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("connections-search-field")
            }
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.s2)

            if displayedConnections.isEmpty {
                emptyState
            } else {
                connectionList(rows: rows)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AetherVisual.s3) {
                    footerContents(visibleCount: rows.count)
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    footerContents(visibleCount: rows.count)
                }
            }
                .layoutPriority(1)
                .font(.body)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AetherVisual.s4)
                .padding(.vertical, AetherVisual.s2)
                .overlay(alignment: .top) { Divider() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Connections"))
        .accessibilityIdentifier("connections-page")
        .sheet(item: $inspectedConnection) { row in
            ConnectionInspector(connection: row.connection)
        }
        .onChange(of: tunnel.isConnected) { _, connected in
            if !connected { pausedConnections = nil }
        }
    }

    @ViewBuilder
    private func footerContents(visibleCount: Int) -> some View {
        if pausedConnections != nil {
            Label("List paused · session counters are live", systemImage: "pause.circle")
        }
        Text(footerText(visibleCount: visibleCount))
            .accessibilityIdentifier("connections-count-summary")
        Text(AppLocalization.string("Only connections visible on this Mac are counted, and nothing is reported anywhere."))
            .accessibilityIdentifier("connections-privacy-summary")
    }

    /// The empty state explains what will appear here once connected, which
    /// also answers why it is empty now.
    private var emptyState: some View {
        ContentUnavailableView {
            Label(
                tunnel.isConnected
                    ? AppLocalization.string("No active connections")
                    : AppLocalization.string("Connections appear here once you connect"),
                systemImage: "arrow.left.arrow.right"
            )
        } description: {
            Text(AppLocalization.string("Each row shows the destination, the rule that matched, which outlet carried it, and how much it moved. Nothing is fabricated while the session is stopped."))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(AetherVisual.s6)
    }

    private func connectionList(rows: [ConnectionTableItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AetherVisual.s2) {
                    segmentedFilter
                    connectionActions
                }
                .fixedSize(horizontal: true, vertical: false)

                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    ViewThatFits(in: .horizontal) {
                        segmentedFilter
                        NativeFilterPicker(
                            selection: $filter,
                            options: ConnectionOutletFilter.allCases,
                            title: label(for:),
                            accessibilityLabel: AppLocalization.string("Filter"),
                            accessibilityIdentifier: "connections-filter-picker"
                        )
                    }
                    HStack {
                        Spacer(minLength: 0)
                        connectionActions
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s4)
            .padding(.vertical, AetherVisual.s2)

            if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Table(rows) {
                TableColumn(AppLocalization.string("Destination")) { row in
                    ConnectionDestinationCell(connection: row.connection)
                        .help(Text(verbatim: row.connection.destinationAddress))
                        .contextMenu {
                            Button("Copy destination") { copyDestination(row.connection) }
                            Button("Connection details") { inspectedConnection = row }
                        }
                        .onTapGesture(count: 2) { inspectedConnection = row }
                }
                .width(min: 124, ideal: 144, max: 400)
                TableColumn(AppLocalization.string("Matched rule")) { row in
                    ConnectionRuleCell(connection: row.connection)
                }
                .width(min: 100, ideal: 120, max: 400)
                TableColumn(AppLocalization.string("Outlet")) { row in
                    ConnectionOutletCell(connection: row.connection)
                }
                .width(min: 100, ideal: 160, max: 320)
                TableColumn(AppLocalization.string("Traffic")) { row in
                    ConnectionTrafficCell(connection: row.connection)
                }
                .width(min: 76, ideal: 80, max: 120)
                TableColumn(AppLocalization.string("Duration")) { row in
                    ConnectionDurationCell(connection: row.connection)
                }
                .width(min: 64, ideal: 68, max: 76)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .accessibilityLabel(AppLocalization.string("Connections"))
            .accessibilityIdentifier("connections-table")
            .scrollIndicators(.hidden, axes: .horizontal)
        }
    }

    private var filterPicker: some View {
        Picker(AppLocalization.string("Filter"), selection: $filter) {
            ForEach(ConnectionOutletFilter.allCases) { option in
                Text(label(for: option)).tag(option)
            }
        }
        .labelsHidden()
        .accessibilityIdentifier("connections-filter-picker")
    }

    private var segmentedFilter: some View {
        filterPicker
            .pickerStyle(.segmented)
            .fixedSize(horizontal: true, vertical: false)
    }

    private var connectionActions: some View {
        HStack(spacing: AetherVisual.s2) {
            Button {
                pausedConnections = pausedConnections == nil ? telemetry.snapshot.connections : nil
            } label: {
                Label(AppLocalization.string(pausedConnections == nil ? "Pause list" : "Resume list"),
                      systemImage: pausedConnections == nil ? "pause" : "play")
            }
            .buttonStyle(.bordered)
            .help("Pauses the connection list only. Traffic and session counters remain live.")
            .accessibilityIdentifier("connections-pause-button")
            Picker(AppLocalization.string("Sort"), selection: $sort) {
                ForEach(ConnectionSort.allCases) { option in
                    Text(option.localizedTitle).tag(option)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("connections-sort-picker")
            .frame(width: 112)

            if tunnel.isConnected {
                Button(AppLocalization.string("Disconnect all"), systemImage: "xmark.circle") {
                    showingDisconnectConfirmation = true
                }
                .buttonStyle(.bordered)
                .disabled(tunnel.isTransitioning || telemetry.snapshot.connections.isEmpty)
                .accessibilityIdentifier("disconnect-all-connections")
                .confirmationDialog(
                    AppLocalization.string("Disconnect Tunnel"),
                    isPresented: $showingDisconnectConfirmation,
                    titleVisibility: .visible
                ) {
                    Button(AppLocalization.string("Disconnect"), role: .destructive) {
                        Task { await tunnel.setEnabled(false) }
                    }
                    Button(AppLocalization.string("Cancel"), role: .cancel) {}
                } message: {
                    Text(AppLocalization.string("Disconnecting the tunnel will stop proxy routing and terminate all active connections."))
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var connectionRows: [ConnectionTableItem] {
        ConnectionTableItem.identify(displayedConnections)
            .filter {
                ConnectionOutlet(proxyChain: $0.connection.proxyChain).matches(filter)
                    && (searchText.isEmpty
                        || $0.connection.destination.localizedCaseInsensitiveContains(searchText)
                        || $0.connection.rule.localizedCaseInsensitiveContains(searchText)
                        || $0.connection.rulePayload.localizedCaseInsensitiveContains(searchText)
                        || $0.connection.proxyChain.localizedCaseInsensitiveContains(searchText))
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

    private func copyDestination(_ connection: ConnectionTelemetry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connection.destinationAddress, forType: .string)
    }

    private func footerText(visibleCount: Int) -> String {
        String.localizedStringWithFormat(
            AppLocalization.string("Showing %lld of %lld connections"),
            Int64(visibleCount),
            Int64(displayedConnections.count)
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
        let count = displayedConnections.filter {
            ConnectionOutlet(proxyChain: $0.proxyChain).matches(option)
        }.count
        return "\(option.localizedTitle) \(count)"
    }
}

/// A compact row that grows for longer status text. Rates read as
/// an em dash when nothing is running: zero is a measurement, and claiming a
/// measurement that was never taken is what made the old page feel wrong.
private struct SessionBar: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        HStack(spacing: AetherVisual.s4) {
            HStack(spacing: AetherVisual.s2) {
                AetherStatusBeacon(
                    isConnected: tunnel.isConnected,
                    isConnecting: tunnel.state == .connecting,
                    size: 7
                )
                Text(tunnel.statusTitle)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !tunnel.isConnected {
                Text(AppLocalization.string("Traffic is using the normal network path"))
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

            Divider().frame(height: 18).opacity(0.4)

            rate(symbol: "arrow.down", value: downloadText, tint: .cyan)
                .accessibilityIdentifier("connections-download-title")
            rate(symbol: "arrow.up", value: uploadText, tint: .purple)
                .accessibilityIdentifier("connections-upload-title")

            Spacer(minLength: AetherVisual.s3)

            if let outlet {
                Divider().frame(height: 18).opacity(0.4)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Outlet"))
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.primary)
                    Text(outlet)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .help(outlet)
                }
            }

            if !tunnel.isConnected {
                Button(tunnel.primaryActionTitle) {
                    Task { await tunnel.setEnabled(!tunnel.isEnabled) }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!tunnel.canPerformPrimaryAction)
                .accessibilityIdentifier("connections-primary-action")
            }
        }
        .padding(.horizontal, AetherVisual.pageHorizontalPadding)
        .padding(.vertical, AetherVisual.s1)
        .frame(minHeight: 44)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections-session-bar")
    }

    private func rate(symbol: String, value: String, tint: Color) -> some View {
        HStack(spacing: AetherVisual.s1) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            Text(value)
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
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
        case .recovering, .connecting, .disconnecting, .loading: "circle.dotted"
        case .failed: "exclamationmark.triangle.fill"
        case .privacyConsentRequired: "hand.raised.fill"
        case .disconnected: "circle"
        }
    }

    private var stateTint: Color {
        switch tunnel.state {
        case .connected: .green
        case .recovering, .connecting, .disconnecting, .loading, .privacyConsentRequired: .orange
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
                Text(verbatim: connection.destinationAddress)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(connection.transport == .tcp ? "TCP" : "UDP")
                    .font(.body.monospaced().weight(.semibold))
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
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .help(ruleText)
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
            .font(.body.weight(.semibold))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(outlet.localizedTitle)
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
        .font(.body.monospacedDigit())
        .foregroundStyle(.primary)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

private struct ConnectionDurationCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        let elapsed = duration
        let text = elapsed ?? AppLocalization.string("Unknown")
        Text(text)
            .font(.body.monospacedDigit().weight(.medium))
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityIdentifier("connection-duration")
            .accessibilityLabel(Text("Connection duration"))
            .accessibilityValue(text)
            .accessibilityHint(Text(
                elapsed == nil
                    ? AppLocalization.string("The connection start time is unavailable.")
                    : ""
            ))
    }

    private var duration: String? {
        let started = Double(connection.startedAtUnixMilliseconds) / 1_000
        let elapsed = Int(Date.now.timeIntervalSince1970 - started)
        // A stale or malformed provider timestamp must not turn into a
        // multi-thousand-hour duration in the table.
        guard elapsed >= 0, elapsed <= 31 * 24 * 3_600 else { return nil }
        if elapsed >= 3_600 {
            return String(format: "%dh%02dm", elapsed / 3_600, (elapsed % 3_600) / 60)
        }
        if elapsed >= 60 {
            return String(format: "%dm%02ds", elapsed / 60, elapsed % 60)
        }
        return "\(elapsed)s"
    }
}

private struct ConnectionInspector: View {
    @Environment(\.dismiss) private var dismiss
    let connection: ConnectionTelemetry

    private var destination: String { connection.destinationAddress }

    var body: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            Text("Connection details").font(.title2.weight(.semibold))
            Text("Snapshot captured when opened. Values do not refresh here.")
                .font(.caption).foregroundStyle(.secondary)
            Form {
                LabeledContent("Destination", value: destination)
                LabeledContent("Transport", value: connection.transport == .tcp ? "TCP" : "UDP")
                LabeledContent("Matched rule", value: connection.rule)
                LabeledContent("Rule payload", value: connection.rulePayload)
                LabeledContent("Outlet chain", value: connection.proxyChain)
                LabeledContent("Download", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: connection.downloadTotal), countStyle: .file))
                LabeledContent("Upload", value: ByteCountFormatter.string(fromByteCount: Int64(clamping: connection.uploadTotal), countStyle: .file))
            }
            .textSelection(.enabled)
            HStack {
                Button("Copy destination") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(connection.destinationAddress, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(AetherVisual.dialogPadding)
        .frame(minWidth: 460, idealWidth: 540, maxWidth: 680)
    }
}

private extension ConnectionTelemetry {
    var destinationAddress: String {
        let host = destination.contains(":") && !destination.hasPrefix("[")
            ? "[\(destination)]" : destination
        return "\(host):\(destinationPort)"
    }
}

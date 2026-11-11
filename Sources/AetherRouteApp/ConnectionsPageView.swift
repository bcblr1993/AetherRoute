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
    @State private var groupsByApp = false
    @State private var groupingDimension: ConnectionTrafficDimension?
    @State private var showsRecentlyClosed = false
    /// Limits the list to one app (`SourceAppPresentation.groupingKey`).
    @State private var appFilter: AppFilter?
    /// Limits the list to one host or outbound hop selected from the leaderboard.
    @State private var dimensionFilter: DimensionFilter?

    private struct AppFilter: Equatable {
        let key: String
        let name: String
    }

    private struct DimensionFilter: Equatable {
        let dimension: ConnectionTrafficDimension
        let key: String
        let name: String
    }

    private var displayedConnections: [ConnectionTelemetry] {
        if let pausedConnections {
            return pausedConnections
        }
        return showsRecentlyClosed
            ? telemetry.recentlyClosed.connections
            : telemetry.snapshot.connections
    }

    var body: some View {
        let rows = connectionRows
        VStack(spacing: 0) {
            // Tables use the full width, so the header and bars carry the
            // page margins themselves instead of `aetherPageContent`.
            AetherPageHeader(.connections) {
                connectionActions
            }
                .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                .padding(.top, AetherVisual.pageTopPadding)
                .padding(.bottom, AetherVisual.s3)

            SessionBar(telemetry: telemetry)
                .environmentObject(tunnel)
                .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                .padding(.bottom, AetherVisual.s2)

            if displayedConnections.isEmpty {
                emptyState
            } else {
                connectionList(rows: rows, apps: groupsByApp ? appRows(rows) : nil)
                    .overlay {
                        // A search or filter that matches nothing says so
                        // instead of leaving a bare table.
                        if rows.isEmpty {
                            ContentUnavailableView(
                                AppLocalization.string("No matching connections"),
                                systemImage: "magnifyingglass",
                                description: Text(AppLocalization.string("Change the filter, or clear the search field."))
                            )
                            .transition(.opacity)
                        }
                    }
            }

            // One line at every width: the privacy note truncates (full text
            // on hover) rather than growing the footer past the window.
            HStack(spacing: AetherVisual.s3) {
                footerContents(visibleCount: rows.count)
            }
                .layoutPriority(1)
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                .padding(.vertical, AetherVisual.s2)
                .overlay(alignment: .top) { Divider() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(AppLocalization.string("Connections"))
        .accessibilityIdentifier("connections-page")
        // The table and session bar show live traffic too; without this the
        // list only refreshed while the overview or menu bar was open.
        .telemetryDemand(source: "connections")
#if DEBUG
        .task {
            switch ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_SHEET"] {
            case "inspector": inspectedConnection = connectionRows.first
            case "apps": groupsByApp = true
            default: break
            }
        }
#endif
        .sheet(item: $inspectedConnection) { row in
            ConnectionInspector(connection: row.connection)
                .environmentObject(tunnel)
        }
        .onChange(of: tunnel.isConnected) { _, connected in
            if !connected {
                pausedConnections = nil
                showsRecentlyClosed = false
                appFilter = nil
                dimensionFilter = nil
                groupingDimension = nil
            }
        }
    }

    @ViewBuilder
    private func footerContents(visibleCount: Int) -> some View {
        if showsRecentlyClosed {
            Label(AppLocalization.string("Recently closed"), systemImage: "clock.arrow.circlepath")
                .foregroundStyle(AetherReadableTint(color: .indigo))
                .lineLimit(1)
                .fixedSize()
                .transition(AetherVisual.insertion)
        } else if pausedConnections != nil {
            Label(AppLocalization.string("List paused · session counters are live"), systemImage: "pause.circle.fill")
                .foregroundStyle(AetherReadableTint(color: .orange))
                .lineLimit(1)
                .fixedSize()
                .transition(AetherVisual.insertion)
        }
        // "Showing 0 of 0" only repeats the empty state above it.
        if !displayedConnections.isEmpty {
            Text(footerText(visibleCount: visibleCount))
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("connections-count-summary")
        }
        Text(AppLocalization.string("Counted on this Mac only; nothing is reported."))
            .lineLimit(1)
            .truncationMode(.tail)
            .help(AppLocalization.string("Only connections visible on this Mac are counted, and nothing is reported anywhere."))
            .accessibilityIdentifier("connections-privacy-summary")
    }

    /// The empty state explains what will appear here once connected, which
    /// also answers why it is empty now.
    private var emptyState: some View {
        // The same empty-state card as Proxies, Rules and DNS.
        FeatureEmptyState(
            symbol: showsRecentlyClosed ? "clock.arrow.circlepath" : "arrow.left.arrow.right",
            title: showsRecentlyClosed
                ? AppLocalization.string("No recently closed connections")
                : (tunnel.isConnected
                    ? AppLocalization.string("No active connections")
                    : AppLocalization.string("No connections yet")),
            detail: showsRecentlyClosed
                ? AppLocalization.string("Connections that finish while the tunnel is running appear here so you can inspect them or create rules.")
                : (tunnel.isConnected
                    ? AppLocalization.string("Each live connection shows its destination, matched rule, outlet and traffic.")
                    : AppLocalization.string("Connect to see each connection's destination, matched rule, outlet and traffic."))
        )
        .padding(.horizontal, AetherVisual.pageHorizontalPadding)
        .padding(.top, AetherVisual.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func connectionList(
        rows: [ConnectionTableItem],
        apps: [ConnectionAppRow]?
    ) -> some View {
        // Counted once per sample, not once per filter and layout candidate:
        // with 2,000 flows that was 8 passes over every proxy chain.
        let counts = outletCounts
        return VStack(alignment: .leading, spacing: 0) {
            // The actions moved to the toolbar (1.5.2), so only the filter
            // is left here: segments, or a pop-up menu when a long
            // translation would draw them past the window. The old two-level
            // ViewThatFits built every control twice on each visit.
            // The filter leading and the search trailing, as on Rules; the
            // search narrows first when the row is tight.
            AetherFilterBarLayout {
                ViewThatFits(in: .horizontal) {
                    segmentedFilter(counts: counts)
                    menuFilter()
                }
                AetherSearchField(
                    text: $searchText,
                    prompt: AppLocalization.string("Search connections"),
                    accessibilityIdentifier: "connections-search-field"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s3)

            if let appFilter {
                appFilterBar(appFilter)
            }
            if let dimensionFilter {
                dimensionFilterBar(dimensionFilter)
            }

            if let apps {
                appTable(apps)
            } else if let dimension = groupingDimension, dimension != .application {
                let summary = ConnectionTrafficAggregator.summarize(
                    connections: rows.map(\.connection),
                    dimension: dimension,
                    limit: 100
                )
                leaderboardTable(summary.entries, dimension: dimension)
            } else {
                connectionTable(rows)
            }
        }
        .aetherPanel()
        .padding(.horizontal, AetherVisual.pageHorizontalPadding)
        .padding(.bottom, AetherVisual.s2)
    }

    private func appFilterBar(_ filter: AppFilter) -> some View {
        HStack(spacing: AetherVisual.s2) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(AppLocalization.format("Only connections from %@", filter.name))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(AppLocalization.string("Show all apps")) {
                withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                    appFilter = nil
                }
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("connections-clear-app-filter")
        }
        .font(.callout)
        .padding(.horizontal, AetherVisual.s4)
        .padding(.bottom, AetherVisual.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections-app-filter")
    }

    private func dimensionFilterBar(_ filter: DimensionFilter) -> some View {
        let formatKey = filter.dimension == .host
            ? "Only connections to %@"
            : "Only connections via %@"
        return HStack(spacing: AetherVisual.s2) {
            Image(systemName: "line.3.horizontal.decrease.circle.fill")
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            Text(AppLocalization.format(formatKey, filter.name))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button(AppLocalization.string("Show all connections")) {
                withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                    dimensionFilter = nil
                }
            }
            .buttonStyle(.link)
            .accessibilityIdentifier("connections-clear-dimension-filter")
        }
        .font(.callout)
        .padding(.horizontal, AetherVisual.s4)
        .padding(.bottom, AetherVisual.s2)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections-dimension-filter")
    }

    // Ideal widths sum to what fits the narrowest window inside the glass
    // panel (424 pt plus cell spacing in a 542 pt table at 780 pt); wider
    // windows spread the rest. The App column (1.3.0) had pushed six
    // columns 79 pt past the table. Duration keeps its 56/60/100 budget
    // (verify_ui_design_tokens.sh) for abbreviated Chinese durations.
    private func connectionTable(_ rows: [ConnectionTableItem]) -> some View {
        let showsLiveRates = pausedConnections == nil && !showsRecentlyClosed
        return Table(rows) {
            TableColumn(AppLocalization.string("App")) { row in
                let app = SourceAppDirectory.shared.presentation(for: row.connection)
                ConnectionAppCell(app: app)
                    .contextMenu { connectionRowContextMenu(for: row) }
                    .onTapGesture(count: 2) { inspectedConnection = row }
            }
            .width(min: 48, ideal: 64, max: 260)
            TableColumn(AppLocalization.string("Destination")) { row in
                ConnectionDestinationCell(connection: row.connection)
                    .help(Text(verbatim: row.connection.destinationAddress))
                    .contextMenu { connectionRowContextMenu(for: row) }
                    .onTapGesture(count: 2) { inspectedConnection = row }
            }
            .width(min: 80, ideal: 100, max: 520)
            // Table shares extra width in proportion to `ideal`. At 72 the
            // fixed-size kind badge ("DOMAIN-SUFFIX") left the value one
            // letter while Traffic and Duration took ~200 pt each.
            TableColumn(AppLocalization.string("Matched rule")) { row in
                ConnectionRuleCell(connection: row.connection)
                    .contextMenu { connectionRowContextMenu(for: row) }
                    .onTapGesture(count: 2) { inspectedConnection = row }
            }
            .width(min: 60, ideal: 108, max: 400)
            TableColumn(AppLocalization.string("Outlet")) { row in
                ConnectionOutletCell(connection: row.connection)
                    .contextMenu { connectionRowContextMenu(for: row) }
                    .onTapGesture(count: 2) { inspectedConnection = row }
            }
            .width(min: 64, ideal: 76, max: 320)
            TableColumn(AppLocalization.string("Traffic")) { row in
                ConnectionTrafficCell(
                    connection: row.connection,
                    rates: showsLiveRates ? telemetry.connectionRates[row.id] : nil
                )
                .contextMenu { connectionRowContextMenu(for: row) }
                .onTapGesture(count: 2) { inspectedConnection = row }
            }
            .width(min: 52, ideal: 68, max: 180)
            // Numbers sit on the right; the title follows them.
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Duration")) { row in
                durationColumnCell(for: row)
            }
            .width(min: 56, ideal: 60, max: 100)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityLabel(AppLocalization.string("Connections"))
        .accessibilityIdentifier("connections-table")
        .scrollIndicators(.hidden, axes: .horizontal)
    }

    private func durationColumnCell(for row: ConnectionTableItem) -> some View {
        HStack(spacing: AetherVisual.s1) {
            ConnectionDurationCell(connection: row.connection)
            if tunnel.isConnected, !showsRecentlyClosed {
                Button {
                    close(.init(row: row.connection))
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                .buttonStyle(.plain)
                .help(AppLocalization.string("Close Connection"))
                .accessibilityLabel(AppLocalization.string("Close Connection"))
                .accessibilityIdentifier("close-connection-row-button")
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: AetherVisual.tableRowHeight)
        .contentShape(Rectangle())
        .contextMenu { connectionRowContextMenu(for: row) }
        .onTapGesture(count: 2) { inspectedConnection = row }
    }

    @ViewBuilder
    private func connectionRowContextMenu(for row: ConnectionTableItem) -> some View {
        Button(AppLocalization.string("Copy destination")) { copyDestination(row.connection) }
        Button(AppLocalization.string("Connection details")) { inspectedConnection = row }
        if tunnel.isConnected, !showsRecentlyClosed {
            Button(AppLocalization.string("Close Connection")) {
                close(.init(row: row.connection))
            }
        }
        Divider()
        destinationRuleMenu(for: row.connection)
        appContextMenu(
            SourceAppDirectory.shared.presentation(for: row.connection)
        )
    }

    /// One row per app: how many connections it has open and their traffic.
    /// Double-click (or the context menu) lists that app's connections.
    private func appTable(_ apps: [ConnectionAppRow]) -> some View {
        Table(apps) {
            TableColumn(AppLocalization.string("App")) { row in
                ConnectionAppCell(app: row.app)
                    .contextMenu { appContextMenu(row.app) }
                    .onTapGesture(count: 2) { showOnly(row.app) }
            }
            .width(min: 140, ideal: 220, max: 520)
            TableColumn(AppLocalization.string("Connections")) { row in
                Text(verbatim: "\(row.connectionCount)")
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: AetherVisual.tableRowHeight)
                    .contextMenu { appContextMenu(row.app) }
            }
            .width(min: 72, ideal: 84, max: 120)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Outlet")) { row in
                Text(row.outletSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: AetherVisual.tableRowHeight)
                    .help(row.outletSummary)
                    .contextMenu { appContextMenu(row.app) }
            }
            .width(min: 84, ideal: 120, max: 320)
            TableColumn(AppLocalization.string("Traffic")) { row in
                Group {
                    if row.liveBytesPerSecond > 0 {
                        VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
                            Text(verbatim: "↓ \(formattedRate(row.liveDownloadBytesPerSecond)) · ↑ \(formattedRate(row.liveUploadBytesPerSecond))")
                                .font(.caption.monospacedDigit().weight(.semibold))
                                .foregroundStyle(AetherReadableTint(color: .accentColor))
                                .lineLimit(1)
                                .aetherLiveValue()
                            Text(verbatim: "↓ \(formattedBytes(row.downloadTotal)) · ↑ \(formattedBytes(row.uploadTotal))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AetherVisual.secondaryText)
                                .lineLimit(1)
                        }
                    } else {
                        VStack(alignment: .trailing, spacing: AetherVisual.s1) {
                            Text(verbatim: "↓ \(formattedBytes(row.downloadTotal))")
                            Text(verbatim: "↑ \(formattedBytes(row.uploadTotal))")
                        }
                        .font(.body.monospacedDigit())
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: AetherVisual.tableRowHeight)
                .contextMenu { appContextMenu(row.app) }
            }
            .width(min: 64, ideal: 96, max: 180)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityLabel(AppLocalization.string("Apps"))
        .accessibilityIdentifier("connections-app-table")
        .scrollIndicators(.hidden, axes: .horizontal)
    }

    private func leaderboardTable(
        _ entries: [ConnectionTrafficEntry],
        dimension: ConnectionTrafficDimension
    ) -> some View {
        let primaryColumnTitle = dimension == .host
            ? AppLocalization.string("Destination")
            : AppLocalization.string("Outlet")
        return Table(entries) {
            TableColumn(primaryColumnTitle) { entry in
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(verbatim: entry.displayName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !entry.subtitle.isEmpty, entry.subtitle != entry.displayName {
                        Text(verbatim: entry.subtitle)
                            .font(.caption)
                            .foregroundStyle(AetherVisual.secondaryText)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: AetherVisual.tableRowHeight)
                .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension) }
                .onTapGesture(count: 2) {
                    showOnlyDimension(entry)
                }
            }
            .width(min: 140, ideal: 220, max: 520)
            TableColumn(AppLocalization.string("Connections")) { entry in
                Text(verbatim: "\(entry.connectionCount)")
                    .font(.body.monospacedDigit())
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: AetherVisual.tableRowHeight)
                    .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension) }
            }
            .width(min: 72, ideal: 84, max: 120)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Share")) { entry in
                let percent = Int((entry.shareOfTotal * 100).rounded())
                Text(verbatim: "\(percent)%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: AetherVisual.tableRowHeight)
                    .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension) }
            }
            .width(min: 56, ideal: 68, max: 100)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Traffic")) { entry in
                VStack(alignment: .trailing, spacing: AetherVisual.s1) {
                    Text(verbatim: "↓ \(formattedBytes(entry.downloadTotal))")
                    Text(verbatim: "↑ \(formattedBytes(entry.uploadTotal))")
                }
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: AetherVisual.tableRowHeight)
                .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension) }
            }
            .width(min: 64, ideal: 80, max: 120)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityLabel(primaryColumnTitle)
        .accessibilityIdentifier("connections-leaderboard-table")
        .scrollIndicators(.hidden, axes: .horizontal)
    }

    @ViewBuilder
    private func leaderboardContextMenu(
        for entry: ConnectionTrafficEntry,
        dimension: ConnectionTrafficDimension
    ) -> some View {
        Button(AppLocalization.format("Show only %@", entry.displayName)) {
            showOnlyDimension(entry)
        }
        if tunnel.isConnected, !showsRecentlyClosed {
            Button {
                closeGroupConnections(entry: entry, dimension: dimension)
            } label: {
                Text(verbatim: aetherBilingualText(
                    en: "Close connections (\(entry.connectionCount))",
                    zhHans: "关闭该组连接（\(entry.connectionCount)）"
                ))
            }
        }
        if dimension == .host {
            Button(AppLocalization.string("Copy destination")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(entry.displayName, forType: .string)
            }
            Divider()
            destinationRuleMenu(for: entry.sampleConnection)
        }
    }

    private func closeGroupConnections(
        entry: ConnectionTrafficEntry,
        dimension: ConnectionTrafficDimension
    ) {
        let matching = displayedConnections.filter {
            ConnectionTrafficAggregator.matchesFilter($0, dimension: dimension, key: entry.key)
        }
        guard !matching.isEmpty else { return }
        var requests: [ConnectionCloseRequest] = []
        for connection in matching {
            let request = ConnectionCloseRequest(row: connection)
            if !requests.contains(request) {
                requests.append(request)
            }
        }
        Task {
            for request in requests {
                await tunnel.closeConnections(request)
            }
        }
    }

    private func showOnlyDimension(_ entry: ConnectionTrafficEntry) {
        withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
            dimensionFilter = DimensionFilter(
                dimension: entry.dimension,
                key: entry.key,
                name: entry.displayName
            )
            groupsByApp = false
            groupingDimension = nil
        }
    }

    @ViewBuilder
    private func destinationRuleMenu(for connection: ConnectionTelemetry) -> some View {
        let candidates = ConnectionDestinationRulePlanner.candidates(for: connection.destination)
        if !candidates.isEmpty {
            ForEach(candidates, id: \.self) { candidate in
                let existing = tunnel.destinationRule(kind: candidate.kind, value: candidate.value)
                Menu(AppLocalization.format("Rule for %@", candidate.value)) {
                    ForEach(applicationRuleTargets, id: \.rawString) { target in
                        Button {
                            Task {
                                let saved = await tunnel.setDestinationRule(
                                    kind: candidate.kind,
                                    value: candidate.value,
                                    noResolve: candidate.noResolve,
                                    target: target
                                )
                                if saved, tunnel.isConnected {
                                    await tunnel.closeConnections(.init(row: connection))
                                }
                            }
                        } label: {
                            if existing?.target == target {
                                Label(applicationTargetTitle(target), systemImage: "checkmark")
                            } else {
                                Text(applicationTargetTitle(target))
                            }
                        }
                    }
                    if let existing {
                        Divider()
                        Button(AppLocalization.string("Remove rule"), role: .destructive) {
                            Task {
                                let deleted = await tunnel.deleteCustomRule(id: existing.id)
                                if deleted, tunnel.isConnected {
                                    await tunnel.closeConnections(.init(row: connection))
                                }
                            }
                        }
                    }
                }
            }
            Divider()
        }
    }

    @ViewBuilder
    private func appContextMenu(_ app: SourceAppPresentation) -> some View {
        if let subject = SourceAppDirectory.shared.ruleSubject(for: app) {
            let existing = tunnel.applicationRule(
                bundleIdentifier: subject.bundleIdentifier,
                bundlePath: subject.bundlePath
            )
            Menu(AppLocalization.format("Rule for %@", app.displayName)) {
                ForEach(applicationRuleTargets, id: \.rawString) { target in
                    Button {
                        Task {
                            let saved = await tunnel.setApplicationRule(
                                bundleIdentifier: subject.bundleIdentifier,
                                bundlePath: subject.bundlePath,
                                displayName: app.displayName,
                                target: target
                            )
                            if saved, tunnel.isConnected {
                                closeConnections(of: app)
                            }
                        }
                    } label: {
                        if existing?.target == target {
                            Label(applicationTargetTitle(target), systemImage: "checkmark")
                        } else {
                            Text(applicationTargetTitle(target))
                        }
                    }
                }
                if let existing {
                    Divider()
                    Button(AppLocalization.string("Remove rule"), role: .destructive) {
                        Task {
                            let deleted = await tunnel.deleteCustomRule(id: existing.id)
                            if deleted, tunnel.isConnected {
                                closeConnections(of: app)
                            }
                        }
                    }
                }
            }
            Divider()
        }
        if tunnel.isConnected {
            Button(AppLocalization.format("Close Connections of %@", app.displayName)) {
                closeConnections(of: app)
            }
        }
        if !app.isUnknown {
            Button(AppLocalization.format("Show only %@", app.displayName)) {
                showOnly(app)
            }
            if let path = app.identity?.bundlePath ?? app.identity?.executablePath {
                Button(AppLocalization.string("Show in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting(
                        [URL(fileURLWithPath: path)]
                    )
                }
            }
        }
    }

    /// Direct, reject, and each proxy group of the active profile.
    private var applicationRuleTargets: [CustomRuleTarget] {
        let groups = (tunnel.activeProfileSummary?.proxyGroups ?? []).map(\.name)
        return [.direct] + groups.map { .proxy($0) } + [.reject]
    }

    private func applicationTargetTitle(_ target: CustomRuleTarget) -> String {
        switch target {
        case .direct: AppLocalization.string("Always connect directly")
        case .reject: AppLocalization.string("Always block")
        case let .proxy(group): AppLocalization.format("Always use %@", group)
        }
    }

    /// Sends one close request and leaves the list to the next telemetry
    /// sample; the apps that owned the connections reconnect on their own.
    private func close(_ request: ConnectionCloseRequest) {
        Task { await tunnel.closeConnections(request) }
    }

    /// An app here can stand for several processes (a browser and its
    /// helpers), each with its own signing identity, so every identity the
    /// list currently shows for it is closed.
    private func closeConnections(of app: SourceAppPresentation) {
        let directory = SourceAppDirectory.shared
        let apps = displayedConnections
            .filter { directory.presentation(for: $0).groupingKey == app.groupingKey }
            .map(ConnectionCloseApp.init(of:))
        let requests = ConnectionCloseRequest.closing(apps: apps)
        guard !requests.isEmpty else { return }
        Task {
            for request in requests {
                await tunnel.closeConnections(request)
            }
        }
    }

    private func showOnly(_ app: SourceAppPresentation) {
        withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
            appFilter = AppFilter(key: app.groupingKey, name: app.displayName)
            groupsByApp = false
        }
    }

    private func appRows(_ rows: [ConnectionTableItem]) -> [ConnectionAppRow] {
        let directory = SourceAppDirectory.shared
        let showsLiveRates = pausedConnections == nil && !showsRecentlyClosed
        var groups: [String: ConnectionAppRow] = [:]
        for row in rows {
            let app = directory.presentation(for: row.connection)
            let rates = showsLiveRates ? telemetry.connectionRates[row.id] : nil
            groups[app.groupingKey, default: ConnectionAppRow(app: app)]
                .add(row.connection, rates: rates)
        }
        return groups.values.sorted { lhs, rhs in
            switch sort {
            case .speed:
                if lhs.liveBytesPerSecond != rhs.liveBytesPerSecond {
                    return lhs.liveBytesPerSecond > rhs.liveBytesPerSecond
                }
                return lhs.downloadTotal + lhs.uploadTotal
                    > rhs.downloadTotal + rhs.uploadTotal
            case .traffic:
                return lhs.downloadTotal + lhs.uploadTotal
                    > rhs.downloadTotal + rhs.uploadTotal
            case .newest:
                return lhs.latestStartedAtUnixMilliseconds > rhs.latestStartedAtUnixMilliseconds
            case .destination:
                return lhs.app.displayName.localizedStandardCompare(
                    rhs.app.displayName
                ) == .orderedAscending
            }
        }
    }

    private func menuFilter() -> some View {
        Picker(AppLocalization.string("Filter"), selection: $filter) {
            ForEach(ConnectionOutletFilter.allCases, id: \.self) { option in
                Text(option.localizedTitle).tag(option)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(AppLocalization.string("Filter"))
        .accessibilityIdentifier("connections-filter-picker")
    }

    private func segmentedFilter(counts: [ConnectionOutletFilter: Int]) -> some View {
        AetherSegmentedPicker(
            selection: $filter,
            options: ConnectionOutletFilter.allCases.map {
                .init(value: $0, title: "\($0.localizedTitle) \(counts[$0, default: 0])")
            },
            accessibilityLabel: AppLocalization.string("Filter"),
            accessibilityIdentifier: "connections-filter-picker"
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The page's actions in three groups (1.5.2): how the list is shown,
    /// pausing it, and what acts on every flow. Seven loose buttons read as
    /// clutter; a menu per group keeps every name visible where it is chosen.
    @ViewBuilder
    private var connectionActions: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { groupsByApp },
                set: { value in
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        groupsByApp = value
                        groupingDimension = value ? .application : nil
                    }
                }
            )) {
                Label(AppLocalization.string("Group by app"), systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("connections-group-by-app")
            Toggle(isOn: Binding(
                get: { groupingDimension == .host },
                set: { value in
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        groupsByApp = false
                        groupingDimension = value ? .host : nil
                    }
                }
            )) {
                Label(AppLocalization.string("Group by host"), systemImage: "globe")
            }
            .accessibilityIdentifier("connections-group-by-host")
            Toggle(isOn: Binding(
                get: { groupingDimension == .outbound },
                set: { value in
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        groupsByApp = false
                        groupingDimension = value ? .outbound : nil
                    }
                }
            )) {
                Label(AppLocalization.string("Group by outbound"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("connections-group-by-outbound")
            Toggle(isOn: Binding(
                get: { showsRecentlyClosed },
                set: { value in
                    withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                        showsRecentlyClosed = value
                        pausedConnections = nil
                    }
                }
            )) {
                Label(AppLocalization.string("Recently closed"), systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("connections-recently-closed-toggle")
            Divider()
            Picker(AppLocalization.string("Sort"), selection: $sort) {
                ForEach(ConnectionSort.allCases) { option in
                    Text(verbatim: option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("connections-sort-picker")
        } label: {
            Label(
                AppLocalization.string("View"),
                systemImage: (groupsByApp || groupingDimension != nil || showsRecentlyClosed)
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .menuIndicator(.visible)
        .aetherButton()
        .fixedSize()
        .help(AppLocalization.string("Group and sort connections"))
        .accessibilityIdentifier("connections-view-menu")

        Button {
            withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                pausedConnections = pausedConnections == nil ? telemetry.snapshot.connections : nil
            }
        } label: {
            Label {
                Text(AppLocalization.string(pausedConnections == nil ? "Pause list" : "Resume list"))
            } icon: {
                Image(systemName: pausedConnections == nil ? "pause.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
            }
            // The symbol alone keeps the header on one line in the smallest
            // window; the name stays in the tooltip and for VoiceOver, and
            // a paused list turns the button orange.
            .labelStyle(.iconOnly)
        }
        // A frozen list must not pass for a live one: the button stays
        // tinted while the list is paused.
        .tint(pausedConnections == nil ? nil : .orange)
        .aetherButton(prominent: pausedConnections != nil)
        .help(AppLocalization.string(pausedConnections == nil ? "Pause list" : "Resume list"))
        .accessibilityIdentifier("connections-pause-button")

        Menu {
            // Ends every listed flow but keeps the tunnel up; apps open
            // fresh connections, which follow the current rules and nodes.
            Button(AppLocalization.string("Close All"), systemImage: "xmark.circle") {
                close(.all)
            }
            .disabled(!tunnel.isConnected || tunnel.isTransitioning || telemetry.snapshot.connections.isEmpty)
            .accessibilityIdentifier("close-all-connections")
            Divider()
            // This stops the tunnel, not only the listed flows, so it says
            // "Disconnect" like the overview and confirms first.
            Button(AppLocalization.string("Disconnect"), systemImage: "power", role: .destructive) {
                showingDisconnectConfirmation = true
            }
            .disabled(!tunnel.isConnected || tunnel.isTransitioning)
            .accessibilityIdentifier("disconnect-all-connections")
        } label: {
            // Named, like the actions beside it: a lone ellipsis drew a
            // button half their height.
            Label(AppLocalization.string("More"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .aetherButton()
        .fixedSize()
        .help(AppLocalization.string("Close all connections without disconnecting"))
        .accessibilityIdentifier("connections-more-menu")
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

    private var connectionRows: [ConnectionTableItem] {
        let usesLiveSnapshot = pausedConnections == nil && !showsRecentlyClosed
        let hasActiveFilter = filter != .all
            || appFilter != nil
            || dimensionFilter != nil
            || !searchText.isEmpty
        if usesLiveSnapshot && !hasActiveFilter && sort == .traffic {
            return telemetry.trafficSortedSnapshotConnections()
        }
        if usesLiveSnapshot && !hasActiveFilter && sort == .speed {
            return telemetry.speedSortedSnapshotConnections()
        }
        let identified = usesLiveSnapshot
            ? telemetry.identifiedSnapshotConnections()
            : ConnectionTableItem.identify(displayedConnections)
        let filtered: [ConnectionTableItem]
        if !hasActiveFilter {
            filtered = identified
        } else {
            let directory = SourceAppDirectory.shared
            let needsAppPresentation = appFilter != nil || !searchText.isEmpty
            filtered = identified.filter { item in
                guard ConnectionOutlet.matches(proxyChain: item.connection.proxyChain, filter: filter) else {
                    return false
                }
                if let dimensionFilter,
                   !ConnectionTrafficAggregator.matchesFilter(
                       item.connection,
                       dimension: dimensionFilter.dimension,
                       key: dimensionFilter.key
                   ) {
                    return false
                }
                guard needsAppPresentation else {
                    return true
                }
                let app = directory.presentation(for: item.connection)
                if let appFilter, appFilter.key != app.groupingKey {
                    return false
                }
                guard !searchText.isEmpty else {
                    return true
                }
                return app.displayName.localizedCaseInsensitiveContains(searchText)
                    || item.connection.destination.localizedCaseInsensitiveContains(searchText)
                    || item.connection.rule.localizedCaseInsensitiveContains(searchText)
                    || item.connection.ruleSummary.localizedCaseInsensitiveContains(searchText)
                    || item.connection.rulePayload.localizedCaseInsensitiveContains(searchText)
                    || item.connection.proxyChain.localizedCaseInsensitiveContains(searchText)
            }
        }
        return filtered.sorted { lhs, rhs in
            switch sort {
            case .speed:
                let lhsSpeed = usesLiveSnapshot ? (telemetry.connectionRates[lhs.id]?.totalBytesPerSecond ?? 0) : 0
                let rhsSpeed = usesLiveSnapshot ? (telemetry.connectionRates[rhs.id]?.totalBytesPerSecond ?? 0) : 0
                if lhsSpeed != rhsSpeed {
                    return lhsSpeed > rhsSpeed
                }
                return lhs.connection.downloadTotal + lhs.connection.uploadTotal
                    > rhs.connection.downloadTotal + rhs.connection.uploadTotal
            case .traffic:
                return lhs.connection.downloadTotal + lhs.connection.uploadTotal
                    > rhs.connection.downloadTotal + rhs.connection.uploadTotal
            case .newest:
                if lhs.connection.startedAtUnixMilliseconds != rhs.connection.startedAtUnixMilliseconds {
                    return lhs.connection.startedAtUnixMilliseconds > rhs.connection.startedAtUnixMilliseconds
                }
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
        AppLocalization.format(
            "Showing %lld of %lld connections",
            Int64(visibleCount),
            Int64(displayedConnections.count)
        )
    }

    private enum ConnectionSort: String, CaseIterable, Identifiable {
        case speed
        case traffic
        case newest
        case destination

        var id: Self { self }

        var localizedTitle: String {
            switch self {
            case .speed:
                aetherBilingualText(en: "By live speed", zhHans: "按实时速率")
            case .traffic: AppLocalization.string("By traffic")
            case .newest: AppLocalization.string("By newest")
            case .destination: AppLocalization.string("By destination")
            }
        }
    }

    /// Flows per outlet, in one pass over the list.
    private var outletCounts: [ConnectionOutletFilter: Int] {
        let tallied = (pausedConnections == nil && !showsRecentlyClosed)
            ? telemetry.snapshotOutletCounts()
            : ConnectionOutletClassifier.counts(for: displayedConnections)
        return [
            .all: tallied.all,
            .proxied: tallied.proxied,
            .direct: tallied.direct,
            .rejected: tallied.rejected,
        ]
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
            // Connected state is already on the sidebar and overview; here
            // the bar only names it when there is something to act on.
            if !tunnel.isConnected {
                HStack(spacing: AetherVisual.s2) {
                    AetherStatusBeacon(
                        isConnected: false,
                        isConnecting: tunnel.state == .connecting,
                        isFailed: tunnel.isFailed,
                        size: 7
                    )
                    Text(tunnel.compactStatusTitle)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !tunnel.isConnected {
                Text(AppLocalization.string("Traffic is using the normal network path"))
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
            }

            if let duration {
                Label {
                    Text(duration)
                        .font(.body.monospacedDigit())
                } icon: {
                    Image(systemName: "clock")
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                .accessibilityLabel(AppLocalization.string("Elapsed"))
                Divider().frame(height: AetherVisual.inlineSeparatorHeight)
            }

            rate(symbol: "arrow.down", value: downloadText, tint: .cyan)
                .accessibilityIdentifier("connections-download-title")
            rate(symbol: "arrow.up", value: uploadText, tint: .purple)
                .accessibilityIdentifier("connections-upload-title")

            ViewThatFits(in: .horizontal) {
                HStack(spacing: AetherVisual.s2) {
                    Divider().frame(height: AetherVisual.inlineSeparatorHeight)
                    HStack(spacing: AetherVisual.s1) {
                        Image(systemName: "memorychip")
                            .font(.caption2)
                            .foregroundStyle(.mint)
                            .accessibilityHidden(true)
                        Text(memorySummaryText)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(AetherVisual.secondaryText)
                            .lineLimit(1)
                            .fixedSize()
                            .aetherLiveValue()
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("connections-memory-title")
                }
                Color.clear.frame(width: 0, height: 0)
            }

            Spacer(minLength: AetherVisual.s3)

            if let outlet {
                Divider().frame(height: AetherVisual.inlineSeparatorHeight)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Outlet"))
                        .font(.caption2.weight(.bold))
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
                .aetherButton(prominent: true)
                .controlSize(.small)
                .disabled(!tunnel.canPerformPrimaryAction)
                .accessibilityIdentifier("connections-primary-action")
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s1)
        .frame(minHeight: AetherVisual.compactRowHeight)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.compactPanelRadius, style: .continuous)
        )
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
                .aetherLiveValue()
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

    private var memorySummaryText: String {
        if tunnel.isConnected, telemetry.snapshot.memoryBytes > 0 {
            return String.localizedStringWithFormat(
                AppLocalization.string("Core %@ · App %@"),
                formattedBytes(telemetry.snapshot.memoryBytes),
                formattedBytes(telemetry.appMemoryBytes)
            )
        }
        return String.localizedStringWithFormat(
            AppLocalization.string("App %@"),
            formattedBytes(telemetry.appMemoryBytes)
        )
    }

    private var outlet: String? {
        guard tunnel.isConnected else { return nil }
        let mode = tunnel.sessionRoutingMode ?? tunnel.routingMode
        switch mode {
        case .direct:
            return aetherBilingualText(
                en: "Direct outbound (no proxy)",
                zhHans: "直连出站（不经代理）"
            )
        case .global:
            let selected = tunnel.proxySelections["GLOBAL"]?.selectedMember
                ?? tunnel.activeProfileSummary.flatMap {
                    TunnelManager.resolvedGlobalTargetMember(in: $0)
                }
            return selected.map { tunnel.resolvedLeafNode(from: $0) }
        case .rule:
            guard let group = tunnel.resolvedPrimaryRoutingGroup(),
                  let selected = tunnel.proxySelections[group.name]?.selectedMember
                    ?? group.members.first
            else { return nil }
            return tunnel.resolvedLeafNode(from: selected)
        }
    }

    private var duration: String? {
        guard let since = tunnel.connectedSince, tunnel.isConnected else {
            return nil
        }
        let elapsed = Int(Date.now.timeIntervalSince(since))
        guard elapsed >= 0, elapsed <= 31 * 24 * 3_600 else { return nil }
        return AppLocalization.duration(TimeInterval(elapsed), includesSeconds: true)
    }

}

/// The app's icon and name; the identifier and path show on hover.
private struct ConnectionAppCell: View {
    let app: SourceAppPresentation

    var body: some View {
        HStack(spacing: AetherVisual.s2) {
            Image(nsImage: SourceAppDirectory.shared.icon(for: app))
                .resizable()
                .interpolation(.high)
                .frame(width: AetherVisual.appIconSize, height: AetherVisual.appIconSize)
                .opacity(app.isUnknown ? 0.45 : 1)
                .accessibilityHidden(true)
            Text(app.displayName)
                .font(.body.weight(.medium))
                .foregroundStyle(app.isUnknown ? AnyShapeStyle(AetherVisual.secondaryText) : AnyShapeStyle(.primary))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AetherVisual.tableRowHeight)
        .help(Text(verbatim: app.detail))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("connection-app")
    }
}

/// One app's connections, summed for the grouped view.
private struct ConnectionAppRow: Identifiable {
    let app: SourceAppPresentation
    private(set) var connectionCount = 0
    private(set) var uploadTotal: UInt64 = 0
    private(set) var downloadTotal: UInt64 = 0
    private(set) var liveUploadBytesPerSecond: UInt64 = 0
    private(set) var liveDownloadBytesPerSecond: UInt64 = 0
    private(set) var latestStartedAtUnixMilliseconds: UInt64 = 0
    private var outlets: [String] = []

    init(app: SourceAppPresentation) {
        self.app = app
    }

    var id: String { app.groupingKey }

    var liveBytesPerSecond: UInt64 {
        liveDownloadBytesPerSecond &+ liveUploadBytesPerSecond
    }

    /// The distinct outlets, most used first ("Tokyo, DIRECT").
    var outletSummary: String {
        var counts: [String: Int] = [:]
        for outlet in outlets { counts[outlet, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
            .joined(separator: ", ")
    }

    mutating func add(_ connection: ConnectionTelemetry, rates: ConnectionTransferRates?) {
        connectionCount += 1
        uploadTotal &+= connection.uploadTotal
        downloadTotal &+= connection.downloadTotal
        if let rates {
            liveUploadBytesPerSecond &+= rates.uploadBytesPerSecond
            liveDownloadBytesPerSecond &+= rates.downloadBytesPerSecond
        }
        latestStartedAtUnixMilliseconds = max(latestStartedAtUnixMilliseconds, connection.startedAtUnixMilliseconds)
        outlets.append(ConnectionOutlet(proxyChain: connection.proxyChain).localizedTitle)
    }
}

private struct ConnectionDestinationCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        let rejected = isRejected
        // The host name leads the cell so it lines up with the column
        // heading; the status dot marks the transport line beneath it.
        return VStack(alignment: .leading, spacing: AetherVisual.s1) {
            // The registrable domain sits at the right of a host name,
            // so truncate from the left and keep the port whole:
            // "…logs.datadoghq.com:443", not "http-intake.logs….com:443".
            HStack(spacing: 0) {
                Text(verbatim: connection.destinationHost)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(verbatim: ":\(connection.destinationPort)")
                    .lineLimit(1)
                    .fixedSize()
            }
            .font(.body.weight(.medium))
            HStack(spacing: AetherVisual.s1) {
                Circle()
                    .fill(rejected ? Color.red : Color.green)
                    .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                    .accessibilityHidden(true)
                Text(verbatim: connection.transport == .tcp ? "TCP" : "UDP")
                    .font(.caption.monospaced())
                    .foregroundStyle(AetherVisual.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AetherVisual.tableRowHeight)
        .foregroundStyle(.primary)
        // Only a rejected flow is tinted; a filled background on every
        // destination cell made one column look unlike the rest of the row.
        .background(rejected ? AetherVisual.tintWash(.red) : Color.clear)
        .accessibilityElement(children: .contain)
    }

    private var isRejected: Bool {
        ConnectionOutletClassifier.classify(connection.proxyChain) == .rejected
    }

}

/// The rule as its kind and its value side by side ("DOMAIN-SUFFIX
/// apple.com"), so a narrow column cuts the value, never the kind.
private struct ConnectionRuleCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        HStack(spacing: AetherVisual.s1) {
            Text(verbatim: ClashRuleKindName.display(connection.rule))
                .font(.caption2.monospaced().weight(.semibold))
                .foregroundStyle(AetherVisual.strongSecondaryText)
                .padding(.horizontal, AetherVisual.s1)
                .padding(.vertical, AetherVisual.sMicro)
                .background(AetherVisual.neutralFill, in: RoundedRectangle(cornerRadius: AetherVisual.badgeRadius, style: .continuous))
                .fixedSize()
            if !connection.rulePayload.isEmpty {
                Text(verbatim: connection.rulePayload)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AetherVisual.tableRowHeight)
        .help(connection.ruleSummary)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionOutletCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        let currentOutlet = outlet
        let title = currentOutlet.localizedTitle
        HStack(spacing: AetherVisual.s2) {
            AetherIconTile(symbol: outletSymbol(for: currentOutlet), color: outletTint(for: currentOutlet), size: AetherVisual.iconTileSize)
            Text(title)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AetherVisual.tableRowHeight)
        .help(title)
        .accessibilityElement(children: .combine)
    }

    private func outletTint(for currentOutlet: ConnectionOutlet) -> Color {
        switch currentOutlet {
        case .proxied: .indigo
        case .direct: .green
        case .rejected: .red
        }
    }

    private var outlet: ConnectionOutlet {
        ConnectionOutlet(proxyChain: connection.proxyChain)
    }

    private func outletSymbol(for currentOutlet: ConnectionOutlet) -> String {
        switch currentOutlet {
        case .proxied: "arrow.triangle.branch"
        case .direct: "arrow.forward"
        case .rejected: "hand.raised.fill"
        }
    }

}

private struct ConnectionTrafficCell: View {
    let connection: ConnectionTelemetry
    let rates: ConnectionTransferRates?

    var body: some View {
        Group {
            if let rates, rates.totalBytesPerSecond > 0 {
                VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
                    Text(verbatim: "↓ \(formattedRate(rates.downloadBytesPerSecond)) · ↑ \(formattedRate(rates.uploadBytesPerSecond))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(AetherReadableTint(color: .accentColor))
                        .lineLimit(1)
                        .aetherLiveValue()
                    Text(verbatim: "↓ \(formattedBytes(connection.downloadTotal)) · ↑ \(formattedBytes(connection.uploadTotal))")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
                }
            } else {
                VStack(alignment: .trailing, spacing: AetherVisual.s1) {
                    Text(verbatim: "↓ \(formattedBytes(connection.downloadTotal))")
                    Text(verbatim: "↑ \(formattedBytes(connection.uploadTotal))")
                }
                .font(.body.monospacedDigit())
                .foregroundStyle(.primary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: AetherVisual.tableRowHeight)
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
            .frame(height: AetherVisual.tableRowHeight)
            .accessibilityIdentifier("connection-duration")
            .accessibilityLabel(Text(AppLocalization.string("Connection duration")))
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
        return AppLocalization.duration(TimeInterval(elapsed), includesSeconds: true)
    }
}

private struct ConnectionInspector: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    let connection: ConnectionTelemetry

    private var destination: String { connection.destinationAddress }
    private var app: SourceAppPresentation {
        SourceAppDirectory.shared.presentation(for: connection)
    }

    private var decisionSteps: [ConnectionRouteDecisionStep] {
        ConnectionRouteDecisionTrace.evaluate(
            connection: connection,
            routingMode: tunnel.sessionRoutingMode ?? tunnel.routingMode,
            customHosts: tunnel.activeProfileOverrides.customHosts,
            customRules: tunnel.customRules,
            summary: tunnel.activeProfileSummary
        ).steps
    }

    private var quickRuleTargets: [CustomRuleTarget] {
        let groups = (tunnel.activeProfileSummary?.proxyGroups ?? []).map(\.name)
        return [.direct] + groups.map { .proxy($0) } + [.reject]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            AetherSheetHeader(
                symbol: connection.transport == .tcp ? "arrow.left.arrow.right" : "dot.radiowaves.left.and.right",
                title: destination,
                subtitle: AppLocalization.string("Snapshot captured when opened. Values do not refresh here."),
                tint: AppSection.connections.tileColor
            )
            .padding([.horizontal, .top], AetherVisual.dialogPadding)

            Form {
                Section(AppLocalization.string("App")) {
                    LabeledContent(AppLocalization.string("Name"), value: app.displayName)
                    if !connection.sourceAppIdentifier.isEmpty {
                        LabeledContent(
                            AppLocalization.string("Signing identifier"),
                            value: connection.sourceAppIdentifier
                        )
                    }
                    if !connection.sourceAppPath.isEmpty {
                        LabeledContent(
                            AppLocalization.string("Executable"),
                            value: connection.sourceAppPath
                        )
                    }
                }
                Section(AppLocalization.string("Route")) {
                    LabeledContent(AppLocalization.string("Transport"), value: connection.transport == .tcp ? "TCP" : "UDP")
                    LabeledContent(AppLocalization.string("Matched rule"), value: connection.ruleSummary)
                    LabeledContent(AppLocalization.string("Outlet chain"), value: connection.proxyChain)
                }
                Section(AppLocalization.string("Route decision trace")) {
                    ForEach(decisionSteps) { step in
                        LabeledContent {
                            HStack(spacing: AetherVisual.s1) {
                                Image(systemName: decisionStepSymbol(step.status))
                                    .foregroundStyle(decisionStepColor(step.status))
                                    .accessibilityHidden(true)
                                Text(step.summary)
                                    .font(.callout.monospaced())
                                    .foregroundStyle(
                                        step.status == .skipped
                                            ? AnyShapeStyle(AetherVisual.secondaryText)
                                            : AnyShapeStyle(.primary)
                                    )
                            }
                        } label: {
                            Text(decisionStageTitle(step.stage))
                        }
                    }
                }
                quickRulesSection
                Section(AppLocalization.string("Traffic")) {
                    LabeledContent(AppLocalization.string("Download"), value: bytes(connection.downloadTotal))
                    LabeledContent(AppLocalization.string("Upload"), value: bytes(connection.uploadTotal))
                }
                if let timing = ConnectionTimingBreakdown.resolve(for: connection) {
                    Section(AppLocalization.string("Timing")) {
                        LabeledContent(
                            AppLocalization.string("DNS lookup"),
                            value: String.localizedStringWithFormat(
                                AppLocalization.string("%lld ms"),
                                Int64(timing.dnsMilliseconds)
                            )
                        )
                        LabeledContent(
                            AppLocalization.string("Outbound handshake"),
                            value: String.localizedStringWithFormat(
                                AppLocalization.string("%lld ms"),
                                Int64(timing.connectMilliseconds)
                            )
                        )
                        LabeledContent(
                            AppLocalization.string("Total setup"),
                            value: String.localizedStringWithFormat(
                                AppLocalization.string("%lld ms"),
                                Int64(timing.totalMilliseconds)
                            )
                        )
                    }
                }
            }
            .aetherSettingsForm(isSheet: true)
            .textSelection(.enabled)
            // Scrolls within a bounded height, with Copy and Done pinned
            // below: sized to its whole content the sheet grew past a
            // 640 pt window under the 1.5.2 toolbar and put Done off screen.
            .frame(
                minHeight: AetherVisual.sheetFormMinHeight,
                idealHeight: AetherVisual.sheetFormIdealHeight,
                maxHeight: AetherVisual.sheetFormMaxHeight
            )

            HStack(spacing: AetherVisual.s2) {
                AetherCopyButton(title: Text(AppLocalization.string("Copy destination"))) {
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(connection.destinationAddress, forType: .string)
                }
                Button {
                    tunnel.pendingRuleTestDestination = connection.destinationHost
                    dismiss()
                    NotificationCenter.default.post(
                        name: .aetherRouteNavigateToSection,
                        object: AppSection.rules.rawValue
                    )
                } label: {
                    Label(AppLocalization.string("Locate in Rules"), systemImage: "scope")
                }
                .aetherButton()
                .accessibilityIdentifier("connection-inspector-locate-in-rules")
                Spacer()
                Button(AppLocalization.string("Done")) { dismiss() }
                    .aetherButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], AetherVisual.dialogPadding)
        }
        .aetherSheetFrame()
    }

    @ViewBuilder
    private var quickRulesSection: some View {
        let candidates = ConnectionDestinationRulePlanner.candidates(for: connection.destination)
        let appSubject = SourceAppDirectory.shared.ruleSubject(for: app)
        if !candidates.isEmpty || appSubject != nil {
            Section(AppLocalization.string("Quick rule actions")) {
                ForEach(candidates, id: \.self) { candidate in
                    let existing = tunnel.destinationRule(kind: candidate.kind, value: candidate.value)
                    LabeledContent {
                        Menu {
                            ForEach(quickRuleTargets, id: \.rawString) { target in
                                Button {
                                    Task {
                                        let saved = await tunnel.setDestinationRule(
                                            kind: candidate.kind,
                                            value: candidate.value,
                                            noResolve: candidate.noResolve,
                                            target: target
                                        )
                                        if saved, tunnel.isConnected {
                                            await tunnel.closeConnections(.init(row: connection))
                                        }
                                    }
                                } label: {
                                    if existing?.target == target {
                                        Label(quickTargetTitle(target), systemImage: "checkmark")
                                    } else {
                                        Text(quickTargetTitle(target))
                                    }
                                }
                            }
                            if let existing {
                                Divider()
                                Button(AppLocalization.string("Remove rule"), role: .destructive) {
                                    Task {
                                        let deleted = await tunnel.deleteCustomRule(id: existing.id)
                                        if deleted, tunnel.isConnected {
                                            await tunnel.closeConnections(.init(row: connection))
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(existing.map { quickTargetTitle($0.target) } ?? AppLocalization.string("Set rule…"))
                        }
                        .fixedSize()
                    } label: {
                        Text(verbatim: "\(candidate.kind.rawValue) · \(candidate.value)")
                            .font(.callout.monospaced())
                    }
                }
                if let subject = appSubject {
                    let existing = tunnel.applicationRule(
                        bundleIdentifier: subject.bundleIdentifier,
                        bundlePath: subject.bundlePath
                    )
                    LabeledContent {
                        Menu {
                            ForEach(quickRuleTargets, id: \.rawString) { target in
                                Button {
                                    Task {
                                        let saved = await tunnel.setApplicationRule(
                                            bundleIdentifier: subject.bundleIdentifier,
                                            bundlePath: subject.bundlePath,
                                            displayName: app.displayName,
                                            target: target
                                        )
                                        if saved, tunnel.isConnected {
                                            await closeInspectorAppConnections()
                                        }
                                    }
                                } label: {
                                    if existing?.target == target {
                                        Label(quickTargetTitle(target), systemImage: "checkmark")
                                    } else {
                                        Text(quickTargetTitle(target))
                                    }
                                }
                            }
                            if let existing {
                                Divider()
                                Button(AppLocalization.string("Remove rule"), role: .destructive) {
                                    Task {
                                        let deleted = await tunnel.deleteCustomRule(id: existing.id)
                                        if deleted, tunnel.isConnected {
                                            await closeInspectorAppConnections()
                                        }
                                    }
                                }
                            }
                        } label: {
                            Text(existing.map { quickTargetTitle($0.target) } ?? AppLocalization.string("Set rule…"))
                        }
                        .fixedSize()
                    } label: {
                        Text(AppLocalization.format("App · %@", app.displayName))
                    }
                }
            }
        }
    }

    private func closeInspectorAppConnections() async {
        let requests = ConnectionCloseRequest.closing(apps: [ConnectionCloseApp(of: connection)])
        for request in requests {
            await tunnel.closeConnections(request)
        }
    }

    private func decisionStageTitle(_ stage: ConnectionRouteDecisionStage) -> String {
        switch stage {
        case .routingMode: AppLocalization.string("Routing mode")
        case .hostsResolution: AppLocalization.string("Hosts override")
        case .applicationRule: AppLocalization.string("Application rule")
        case .customDestinationRule: AppLocalization.string("Custom rule")
        case .profileRule: AppLocalization.string("Profile rule")
        case .outboundChain: AppLocalization.string("Outbound chain")
        }
    }

    private func decisionStepSymbol(_ status: ConnectionRouteDecisionStatus) -> String {
        switch status {
        case .matched: "checkmark.circle.fill"
        case .passed: "arrow.right.circle.fill"
        case .skipped: "minus.circle"
        }
    }

    private func decisionStepColor(_ status: ConnectionRouteDecisionStatus) -> AnyShapeStyle {
        switch status {
        case .matched: AnyShapeStyle(AetherReadableTint(color: .green))
        case .passed: AnyShapeStyle(AetherReadableTint(color: .indigo))
        case .skipped: AnyShapeStyle(AetherVisual.secondaryText)
        }
    }

    private func quickTargetTitle(_ target: CustomRuleTarget) -> String {
        switch target {
        case .direct: AppLocalization.string("Always connect directly")
        case .reject: AppLocalization.string("Always block")
        case let .proxy(group): AppLocalization.format("Always use %@", group)
        }
    }

    private func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .file)
    }
}

private extension ConnectionTelemetry {
    /// "DOMAIN-SUFFIX apple.com", spelled the way the Rules page shows it.
    var ruleSummary: String {
        let kind = ClashRuleKindName.display(rule)
        let payload = rulePayload.trimmingCharacters(in: .whitespaces)
        return payload.isEmpty ? kind : "\(kind) \(payload)"
    }
}

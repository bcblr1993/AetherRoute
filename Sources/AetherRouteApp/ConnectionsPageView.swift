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
    /// Limits the list to one app (`SourceAppPresentation.groupingKey`).
    @State private var appFilter: AppFilter?

    private struct AppFilter: Equatable {
        let key: String
        let name: String
    }

    private var displayedConnections: [ConnectionTelemetry] {
        pausedConnections ?? telemetry.snapshot.connections
    }

    var body: some View {
        let rows = connectionRows
        VStack(spacing: 0) {
            // Tables use the full width, so the header and bars carry the
            // page margins themselves instead of `aetherPageContent`.
            // Search sits in the header, as on Proxies: a separate row made
            // the page taller than the 560 pt minimum window.
            AetherPageHeader(.connections) {
                AetherSearchField(
                    text: $searchText,
                    prompt: AppLocalization.string("Search connections"),
                    accessibilityIdentifier: "connections-search-field"
                )
                .frame(width: AetherVisual.searchFieldWidth)
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
        }
        .onChange(of: tunnel.isConnected) { _, connected in
            if !connected {
                pausedConnections = nil
                appFilter = nil
            }
        }
    }

    @ViewBuilder
    private func footerContents(visibleCount: Int) -> some View {
        if pausedConnections != nil {
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
            symbol: "arrow.left.arrow.right",
            title: tunnel.isConnected
                ? AppLocalization.string("No active connections")
                : AppLocalization.string("No connections yet"),
            detail: tunnel.isConnected
                ? AppLocalization.string("Each live connection shows its destination, matched rule, outlet and traffic.")
                : AppLocalization.string("Connect to see each connection's destination, matched rule, outlet and traffic.")
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
            ViewThatFits(in: .horizontal) {
                HStack(spacing: AetherVisual.s2) {
                    segmentedFilter(counts: counts)
                    connectionActions
                }
                .fixedSize(horizontal: true, vertical: false)

                // Narrower windows: the filter on its own line, actions as
                // icons beneath it (their names stay as tooltips and
                // VoiceOver labels).
                VStack(alignment: .leading, spacing: AetherVisual.s2) {
                    // Still too wide (a long translation): a pop-up menu
                    // instead of segments that would draw past the window.
                    ViewThatFits(in: .horizontal) {
                        segmentedFilter(counts: counts)
                        menuFilter()
                    }
                    HStack {
                        Spacer(minLength: 0)
                        connectionActions
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s3)

            if let appFilter {
                appFilterBar(appFilter)
            }

            if rows.isEmpty {
                ContentUnavailableView.search(text: searchText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let apps {
                appTable(apps)
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

    // Ideal widths sum to what fits the narrowest window inside the glass
    // panel (424 pt plus cell spacing in a 542 pt table at 780 pt); wider
    // windows spread the rest. The App column (1.3.0) had pushed six
    // columns 79 pt past the table.
    private func connectionTable(_ rows: [ConnectionTableItem]) -> some View {
        Table(rows) {
            TableColumn(AppLocalization.string("App")) { row in
                let app = SourceAppDirectory.shared.presentation(for: row.connection)
                ConnectionAppCell(app: app)
                    .contextMenu { appContextMenu(app) }
            }
            .width(min: 48, ideal: 64, max: 260)
            TableColumn(AppLocalization.string("Destination")) { row in
                ConnectionDestinationCell(connection: row.connection)
                    .help(Text(verbatim: row.connection.destinationAddress))
                    .contextMenu {
                        Button(AppLocalization.string("Copy destination")) { copyDestination(row.connection) }
                        Button(AppLocalization.string("Connection details")) { inspectedConnection = row }
                        if tunnel.isConnected {
                            Button(AppLocalization.string("Close Connection")) {
                                close(.init(row: row.connection))
                            }
                        }
                        Divider()
                        appContextMenu(
                            SourceAppDirectory.shared.presentation(for: row.connection)
                        )
                    }
                    .onTapGesture(count: 2) { inspectedConnection = row }
            }
            .width(min: 80, ideal: 96, max: 520)
            TableColumn(AppLocalization.string("Matched rule")) { row in
                ConnectionRuleCell(connection: row.connection)
            }
            .width(min: 60, ideal: 72, max: 400)
            TableColumn(AppLocalization.string("Outlet")) { row in
                ConnectionOutletCell(connection: row.connection)
            }
            .width(min: 64, ideal: 80, max: 320)
            TableColumn(AppLocalization.string("Traffic")) { row in
                ConnectionTrafficCell(connection: row.connection)
            }
            .width(min: 52, ideal: 60, max: 120)
            // Numbers sit on the right; the title follows them.
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Duration")) { row in
                ConnectionDurationCell(connection: row.connection)
            }
            .width(min: 44, ideal: 52, max: 100)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityLabel(AppLocalization.string("Connections"))
        .accessibilityIdentifier("connections-table")
        .scrollIndicators(.hidden, axes: .horizontal)
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
            }
            .width(min: 72, ideal: 84, max: 120)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Outlet")) { row in
                Text(row.outletSummary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(row.outletSummary)
            }
            .width(min: 84, ideal: 120, max: 320)
            TableColumn(AppLocalization.string("Traffic")) { row in
                VStack(alignment: .trailing, spacing: AetherVisual.s1) {
                    Text(verbatim: "↓ \(formattedBytes(row.downloadTotal))")
                    Text(verbatim: "↑ \(formattedBytes(row.uploadTotal))")
                }
                .font(.body.monospacedDigit())
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 64, ideal: 80, max: 120)
            .alignment(.numeric)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollContentBackground(.hidden)
        .accessibilityLabel(AppLocalization.string("Apps"))
        .accessibilityIdentifier("connections-app-table")
        .scrollIndicators(.hidden, axes: .horizontal)
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
                            await tunnel.setApplicationRule(
                                bundleIdentifier: subject.bundleIdentifier,
                                bundlePath: subject.bundlePath,
                                displayName: app.displayName,
                                target: target
                            )
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
                        Task { await tunnel.deleteCustomRule(id: existing.id) }
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
        return [.direct] + groups.prefix(8).map { .proxy($0) } + [.reject]
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
        var groups: [String: ConnectionAppRow] = [:]
        for row in rows {
            let app = directory.presentation(for: row.connection)
            groups[app.groupingKey, default: ConnectionAppRow(app: app)]
                .add(row.connection)
        }
        return groups.values.sorted { lhs, rhs in
            switch sort {
            case .traffic:
                return lhs.downloadTotal + lhs.uploadTotal
                    > rhs.downloadTotal + rhs.uploadTotal
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

    private var connectionActions: some View {
        HStack(spacing: AetherVisual.s2) {
            Button {
                withAnimation(AetherVisual.animation(AetherVisual.gentleSpring)) {
                    groupsByApp.toggle()
                }
            } label: {
                Label(
                    AppLocalization.string("Group by app"),
                    systemImage: "square.stack.3d.up"
                )
            }
            .aetherGlassButton()
            .tint(groupsByApp ? .accentColor : nil)
            .help(AppLocalization.string(groupsByApp ? "Show each connection" : "Group by app"))
            .accessibilityValue(Text(AppLocalization.string(groupsByApp ? "On" : "Off")))
            .accessibilityIdentifier("connections-group-by-app")
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
            }
            .aetherGlassButton()
            // A frozen list must not pass for a live one: the button stays
            // tinted while the list is paused.
            .tint(pausedConnections == nil ? nil : .orange)
            .help(AppLocalization.string(pausedConnections == nil ? "Pause list" : "Resume list"))
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
                // Ends every listed flow but keeps the tunnel up; apps open
                // fresh connections, which follow the current rules and nodes.
                Button(AppLocalization.string("Close All"), systemImage: "xmark.circle") {
                    close(.all)
                }
                .aetherGlassButton()
                .disabled(tunnel.isTransitioning || telemetry.snapshot.connections.isEmpty)
                .help(AppLocalization.string("Close all connections without disconnecting"))
                .accessibilityIdentifier("close-all-connections")
                // This stops the tunnel, not only the listed flows, so it says
                // "Disconnect" like the overview and confirms first.
                Button(AppLocalization.string("Disconnect"), systemImage: "power") {
                    showingDisconnectConfirmation = true
                }
                .aetherGlassButton()
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
        let directory = SourceAppDirectory.shared
        return ConnectionTableItem.identify(displayedConnections)
            .filter {
                let app = directory.presentation(for: $0.connection)
                return ConnectionOutlet(proxyChain: $0.connection.proxyChain).matches(filter)
                    && (appFilter == nil || appFilter?.key == app.groupingKey)
                    && (searchText.isEmpty
                        || app.displayName.localizedCaseInsensitiveContains(searchText)
                        || $0.connection.destination.localizedCaseInsensitiveContains(searchText)
                        || $0.connection.rule.localizedCaseInsensitiveContains(searchText)
                        || $0.connection.ruleSummary.localizedCaseInsensitiveContains(searchText)
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
        AppLocalization.format(
            "Showing %lld of %lld connections",
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

    /// Flows per outlet, in one pass over the list.
    private var outletCounts: [ConnectionOutletFilter: Int] {
        var counts: [ConnectionOutletFilter: Int] = [.all: displayedConnections.count]
        for connection in displayedConnections {
            switch ConnectionOutlet(proxyChain: connection.proxyChain) {
            case .proxied: counts[.proxied, default: 0] += 1
            case .direct: counts[.direct, default: 0] += 1
            case .rejected: counts[.rejected, default: 0] += 1
            }
        }
        return counts
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
                .aetherGlassButton(prominent: true)
                .controlSize(.small)
                .disabled(!tunnel.canPerformPrimaryAction)
                .accessibilityIdentifier("connections-primary-action")
            }
        }
        .padding(.horizontal, AetherVisual.s4)
        .padding(.vertical, AetherVisual.s1)
        .frame(minHeight: AetherVisual.compactRowHeight)
        .aetherGlass(in: RoundedRectangle(cornerRadius: AetherVisual.compactPanelRadius, style: .continuous))
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
                .aetherNumericValue(value)
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
    private var outlets: [String] = []

    init(app: SourceAppPresentation) {
        self.app = app
    }

    var id: String { app.groupingKey }

    /// The distinct outlets, most used first ("Tokyo, DIRECT").
    var outletSummary: String {
        var counts: [String: Int] = [:]
        for outlet in outlets { counts[outlet, default: 0] += 1 }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            .map(\.key)
            .joined(separator: ", ")
    }

    mutating func add(_ connection: ConnectionTelemetry) {
        connectionCount += 1
        uploadTotal &+= connection.uploadTotal
        downloadTotal &+= connection.downloadTotal
        outlets.append(ConnectionOutlet(proxyChain: connection.proxyChain).localizedTitle)
    }
}

private struct ConnectionDestinationCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        // The host name leads the cell so it lines up with the column
        // heading; the status dot marks the transport line beneath it.
        VStack(alignment: .leading, spacing: AetherVisual.s1) {
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
                    .fill(outlet == .rejected ? Color.red : Color.green)
                    .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
                    .accessibilityHidden(true)
                Text(connection.transport == .tcp ? "TCP" : "UDP")
                    .font(.caption.monospaced())
                    .foregroundStyle(AetherVisual.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: AetherVisual.tableRowHeight)
        .foregroundStyle(.primary)
        // Only a rejected flow is tinted; a filled background on every
        // destination cell made one column look unlike the rest of the row.
        .background(outlet == .rejected ? AetherVisual.tintWash(.red) : Color.clear)
        .accessibilityElement(children: .contain)
    }

    private var outlet: ConnectionOutlet {
        ConnectionOutlet(proxyChain: connection.proxyChain)
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
        .help(connection.ruleSummary)
        .accessibilityElement(children: .combine)
    }
}

private struct ConnectionOutletCell: View {
    let connection: ConnectionTelemetry

    var body: some View {
        HStack(spacing: AetherVisual.s2) {
            AetherIconTile(symbol: outletSymbol, color: outletTint, size: AetherVisual.iconTileSize)
            Text(outlet.localizedTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .help(outlet.localizedTitle)
        .accessibilityElement(children: .combine)
    }

    private var outletTint: Color {
        switch outlet {
        case .proxied: .indigo
        case .direct: .green
        case .rejected: .red
        }
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
    @Environment(\.dismiss) private var dismiss
    let connection: ConnectionTelemetry

    private var destination: String { connection.destinationAddress }
    private var app: SourceAppPresentation {
        SourceAppDirectory.shared.presentation(for: connection)
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
                Section(AppLocalization.string("Traffic")) {
                    LabeledContent(AppLocalization.string("Download"), value: bytes(connection.downloadTotal))
                    LabeledContent(AppLocalization.string("Upload"), value: bytes(connection.uploadTotal))
                }
            }
            .aetherSettingsForm(isSheet: true)
            .scrollDisabled(true)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                AetherCopyButton(title: Text(AppLocalization.string("Copy destination"))) {
                    NSPasteboard.general.clearContents()
                    return NSPasteboard.general.setString(connection.destinationAddress, forType: .string)
                }
                Spacer()
                Button(AppLocalization.string("Done")) { dismiss() }
                    .aetherGlassButton(prominent: true)
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], AetherVisual.dialogPadding)
        }
        .aetherSheetFrame()
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

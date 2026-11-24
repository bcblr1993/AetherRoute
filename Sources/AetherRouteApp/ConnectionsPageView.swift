import AppKit
import AetherRouteKit
import SwiftUI

@MainActor
private final class FrozenConnectionSnapshotCache {
    private struct FlowEdgeSignature: Equatable {
        let transport: UInt8
        let destination: String
        let destinationPort: UInt16
        let startedAtUnixMilliseconds: UInt64
        let downloadTotal: UInt64
        let uploadTotal: UInt64

        init(_ connection: ConnectionTelemetry) {
            self.transport = connection.transport.rawValue
            self.destination = connection.destination
            self.destinationPort = connection.destinationPort
            self.startedAtUnixMilliseconds = connection.startedAtUnixMilliseconds
            self.downloadTotal = connection.downloadTotal
            self.uploadTotal = connection.uploadTotal
        }
    }

    private struct Key: Equatable {
        let isPaused: Bool
        let showsRecentlyClosed: Bool
        let count: Int
        let first: FlowEdgeSignature?
        let samples: [FlowEdgeSignature]
        let middle: FlowEdgeSignature?
        let last: FlowEdgeSignature?
    }

    private var key: Key?
    private var identified: [ConnectionTableItem] = []
    private var outletCounts = ConnectionOutletClassifier.Counts(all: 0, proxied: 0, direct: 0, rejected: 0)

    private func makeKey(
        for connections: [ConnectionTelemetry],
        isPaused: Bool,
        showsRecentlyClosed: Bool
    ) -> Key {
        let middleIndex = connections.isEmpty ? nil : connections.count / 2
        let step = max(1, connections.count / 8)
        let samples = connections.isEmpty
            ? []
            : stride(from: 0, to: connections.count, by: step).map { FlowEdgeSignature(connections[$0]) }
        return Key(
            isPaused: isPaused,
            showsRecentlyClosed: showsRecentlyClosed,
            count: connections.count,
            first: connections.first.map(FlowEdgeSignature.init),
            samples: samples,
            middle: middleIndex.map { FlowEdgeSignature(connections[$0]) },
            last: connections.last.map(FlowEdgeSignature.init)
        )
    }

    private func refreshIfNeeded(
        for connections: [ConnectionTelemetry],
        isPaused: Bool,
        showsRecentlyClosed: Bool
    ) {
        let nextKey = makeKey(for: connections, isPaused: isPaused, showsRecentlyClosed: showsRecentlyClosed)
        guard key != nextKey else { return }
        key = nextKey
        identified = ConnectionTableItem.identify(connections)
        outletCounts = ConnectionOutletClassifier.counts(for: connections)
    }

    func identifiedItems(
        for connections: [ConnectionTelemetry],
        isPaused: Bool,
        showsRecentlyClosed: Bool
    ) -> [ConnectionTableItem] {
        refreshIfNeeded(for: connections, isPaused: isPaused, showsRecentlyClosed: showsRecentlyClosed)
        return identified
    }

    func counts(
        for connections: [ConnectionTelemetry],
        isPaused: Bool,
        showsRecentlyClosed: Bool
    ) -> ConnectionOutletClassifier.Counts {
        refreshIfNeeded(for: connections, isPaused: isPaused, showsRecentlyClosed: showsRecentlyClosed)
        return outletCounts
    }
}

struct ConnectionsAppFilter: Equatable {
    let key: String
    let name: String
}

struct ConnectionsDimensionFilter: Equatable {
    let dimension: ConnectionTrafficDimension
    let key: String
    let name: String
}

enum ConnectionSort: String, CaseIterable, Identifiable {
    case speed
    case traffic
    case newest
    case destination

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .speed:
            AppLocalization.string("By live speed")
        case .traffic: AppLocalization.string("By traffic")
        case .newest: AppLocalization.string("By newest")
        case .destination: AppLocalization.string("By destination")
        }
    }
}

@MainActor
private final class ConnectionsRowsModel: ObservableObject {
    struct SnapshotData {
        let displayedConnections: [ConnectionTelemetry]
        let isDisplayedEmpty: Bool
        let rows: [ConnectionTableItem]
        let appRows: [ConnectionAppRow]
        let leaderboardEntries: [ConnectionTrafficEntry]
        let outletCounts: [ConnectionOutletFilter: Int]
        let allCount: Int
        let snapshotBreakdownCount: Int
        let isSnapshotTruncated: Bool
        let totalCount: Int
    }

    private struct InputsKey: Equatable {
        let snapshot: NetworkTelemetrySnapshot?
        let displayedConnections: [ConnectionTelemetry]
        let filter: ConnectionOutletFilter
        let sort: ConnectionSort
        let searchText: String
        let isPaused: Bool
        let showsRecentlyClosed: Bool
        let appFilter: ConnectionsAppFilter?
        let dimensionFilter: ConnectionsDimensionFilter?
        let groupsByApp: Bool
        let groupingDimension: ConnectionTrafficDimension?

        @MainActor
        init(telemetry: NetworkTelemetryViewModel, drafts: ConnectionsPageDraftState) {
            let usesLive = drafts.pausedConnections == nil && !drafts.showsRecentlyClosed
            self.snapshot = usesLive ? telemetry.snapshot : nil
            if let paused = drafts.pausedConnections {
                self.displayedConnections = paused
            } else if drafts.showsRecentlyClosed {
                self.displayedConnections = telemetry.recentlyClosed.connections
            } else {
                self.displayedConnections = telemetry.snapshot.connections
            }
            self.filter = drafts.filter
            self.sort = drafts.sort
            self.searchText = drafts.searchText
            self.isPaused = drafts.pausedConnections != nil
            self.showsRecentlyClosed = drafts.showsRecentlyClosed
            self.appFilter = drafts.appFilter
            self.dimensionFilter = drafts.dimensionFilter
            self.groupsByApp = drafts.groupsByApp
            self.groupingDimension = drafts.groupingDimension
        }
    }

    @Published private(set) var data: SnapshotData
    private var lastInputs: InputsKey
    private var frozenCache = FrozenConnectionSnapshotCache()

    init(telemetry: NetworkTelemetryViewModel, drafts: ConnectionsPageDraftState) {
        var initialCache = FrozenConnectionSnapshotCache()
        self.lastInputs = InputsKey(telemetry: telemetry, drafts: drafts)
        self.data = Self.build(telemetry: telemetry, drafts: drafts, frozenCache: &initialCache)
        self.frozenCache = initialCache
    }

    func refresh(telemetry: NetworkTelemetryViewModel, drafts: ConnectionsPageDraftState) {
        let inputs = InputsKey(telemetry: telemetry, drafts: drafts)
        guard inputs != lastInputs else { return }
        lastInputs = inputs
        data = Self.build(telemetry: telemetry, drafts: drafts, frozenCache: &frozenCache)
    }

    private static func build(
        telemetry: NetworkTelemetryViewModel,
        drafts: ConnectionsPageDraftState,
        frozenCache: inout FrozenConnectionSnapshotCache
    ) -> SnapshotData {
        let displayedConnections: [ConnectionTelemetry]
        if let paused = drafts.pausedConnections {
            displayedConnections = paused
        } else if drafts.showsRecentlyClosed {
            displayedConnections = telemetry.recentlyClosed.connections
        } else {
            displayedConnections = telemetry.snapshot.connections
        }

        let usesLiveSnapshot = drafts.pausedConnections == nil && !drafts.showsRecentlyClosed
        let tallied = usesLiveSnapshot
            ? telemetry.snapshotOutletCounts()
            : frozenCache.counts(
                for: displayedConnections,
                isPaused: drafts.pausedConnections != nil,
                showsRecentlyClosed: drafts.showsRecentlyClosed
            )
        let allCount = usesLiveSnapshot
            ? max(tallied.all, telemetry.snapshot.totalActiveConnections)
            : tallied.all
        let breakdownCount = tallied.proxied + tallied.direct + tallied.rejected
        let outletCounts: [ConnectionOutletFilter: Int] = [
            .all: allCount,
            .proxied: tallied.proxied,
            .direct: tallied.direct,
            .rejected: tallied.rejected,
        ]
        let totalCount = usesLiveSnapshot
            ? max(displayedConnections.count, telemetry.snapshot.totalActiveConnections)
            : displayedConnections.count

        let rows = computeConnectionRows(
            displayedConnections: displayedConnections,
            usesLiveSnapshot: usesLiveSnapshot,
            telemetry: telemetry,
            drafts: drafts,
            frozenCache: &frozenCache
        )

        let computedAppRows: [ConnectionAppRow] = drafts.groupsByApp
            ? computeAppRows(rows: rows, usesLiveSnapshot: usesLiveSnapshot, telemetry: telemetry, sort: drafts.sort)
            : []

        let leaderboardEntries: [ConnectionTrafficEntry] = {
            guard !drafts.groupsByApp,
                  let dimension = drafts.groupingDimension,
                  dimension != .application else {
                return []
            }
            return ConnectionTrafficAggregator.summarize(
                connections: rows.map(\.connection),
                dimension: dimension,
                limit: 100
            ).entries
        }()

        return SnapshotData(
            displayedConnections: displayedConnections,
            isDisplayedEmpty: displayedConnections.isEmpty,
            rows: rows,
            appRows: computedAppRows,
            leaderboardEntries: leaderboardEntries,
            outletCounts: outletCounts,
            allCount: allCount,
            snapshotBreakdownCount: breakdownCount,
            isSnapshotTruncated: usesLiveSnapshot && allCount > breakdownCount,
            totalCount: totalCount
        )
    }

    private static func computeConnectionRows(
        displayedConnections: [ConnectionTelemetry],
        usesLiveSnapshot: Bool,
        telemetry: NetworkTelemetryViewModel,
        drafts: ConnectionsPageDraftState,
        frozenCache: inout FrozenConnectionSnapshotCache
    ) -> [ConnectionTableItem] {
        let hasActiveFilter = drafts.filter != .all
            || drafts.appFilter != nil
            || drafts.dimensionFilter != nil
            || !drafts.searchText.isEmpty
        if usesLiveSnapshot && !hasActiveFilter && drafts.sort == .traffic {
            return telemetry.trafficSortedSnapshotConnections()
        }
        if usesLiveSnapshot && !hasActiveFilter && drafts.sort == .speed {
            return telemetry.speedSortedSnapshotConnections()
        }
        let identified = usesLiveSnapshot
            ? telemetry.identifiedSnapshotConnections()
            : frozenCache.identifiedItems(
                for: displayedConnections,
                isPaused: drafts.pausedConnections != nil,
                showsRecentlyClosed: drafts.showsRecentlyClosed
            )
        let filtered: [ConnectionTableItem]
        if !hasActiveFilter {
            filtered = identified
        } else {
            let directory = SourceAppDirectory.shared
            let needsAppPresentation = drafts.appFilter != nil || !drafts.searchText.isEmpty
            filtered = identified.filter { item in
                guard ConnectionOutlet.matches(proxyChain: item.connection.proxyChain, filter: drafts.filter) else {
                    return false
                }
                if let dimensionFilter = drafts.dimensionFilter,
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
                if let appFilter = drafts.appFilter, appFilter.key != app.groupingKey {
                    return false
                }
                guard !drafts.searchText.isEmpty else {
                    return true
                }
                return app.displayName.localizedCaseInsensitiveContains(drafts.searchText)
                    || item.connection.destination.localizedCaseInsensitiveContains(drafts.searchText)
                    || item.connection.rule.localizedCaseInsensitiveContains(drafts.searchText)
                    || item.connection.ruleSummary.localizedCaseInsensitiveContains(drafts.searchText)
                    || item.connection.rulePayload.localizedCaseInsensitiveContains(drafts.searchText)
                    || item.connection.proxyChain.localizedCaseInsensitiveContains(drafts.searchText)
            }
        }
        return filtered.sorted { lhs, rhs in
            switch drafts.sort {
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

    private static func computeAppRows(
        rows: [ConnectionTableItem],
        usesLiveSnapshot: Bool,
        telemetry: NetworkTelemetryViewModel,
        sort: ConnectionSort
    ) -> [ConnectionAppRow] {
        let directory = SourceAppDirectory.shared
        var groups: [String: ConnectionAppRow] = [:]
        for row in rows {
            let app = directory.presentation(for: row.connection)
            let rates = usesLiveSnapshot ? telemetry.connectionRates[row.id] : nil
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
}

/// The connections page exists to show the flow list. State is compressed into
/// a single session bar so the table gets the screen: previously five separate
/// boxes all restated "not connected" while the one thing worth looking at had
/// nowhere to go.
struct ConnectionsView: View {
    let telemetry: NetworkTelemetryViewModel
    @Environment(\.pageSessionDrafts) private var pageDrafts

    var body: some View {
        if let drafts = pageDrafts?.connections {
            ConnectionsBodyView(
                telemetry: telemetry,
                drafts: drafts
            )
        } else {
            ConnectionsStandaloneView(telemetry: telemetry)
        }
    }
}

private struct ConnectionsStandaloneView: View {
    let telemetry: NetworkTelemetryViewModel
    @StateObject private var fallbackDrafts = ConnectionsPageDraftState()

    var body: some View {
        ConnectionsBodyView(
            telemetry: telemetry,
            drafts: fallbackDrafts
        )
    }
}

private struct ConnectionsBodyView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    let telemetry: NetworkTelemetryViewModel
    @ObservedObject var drafts: ConnectionsPageDraftState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDisconnectConfirmation = false
    @State private var showingCloseAllConfirmation = false
    @State private var closeConnectionsError: String?
    @State private var inspectedConnection: ConnectionTableItem?

    private var displayedConnections: [ConnectionTelemetry] {
        if let pausedConnections = drafts.pausedConnections {
            return pausedConnections
        }
        return drafts.showsRecentlyClosed
            ? telemetry.recentlyClosed.connections
            : telemetry.snapshot.connections
    }

    var body: some View {
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

            if let closeConnectionsError {
                AetherInlineMessage(text: closeConnectionsError, kind: .failure, isCompact: true)
                    .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                    .padding(.bottom, AetherVisual.s2)
            }

            ConnectionsListSection(
                telemetry: telemetry,
                drafts: drafts,
                inspectedConnection: $inspectedConnection,
                onCloseRequest: close,
                onCloseConnectionsOfApp: closeConnections(of:),
                onCloseGroupConnections: closeGroupConnections
            )
            .environmentObject(tunnel)
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
            case "inspector": inspectedConnection = telemetry.trafficSortedSnapshotConnections().first
            case "apps": drafts.groupsByApp = true
            default: break
            }
        }
#endif
        .sheet(item: $inspectedConnection) { row in
            ConnectionInspector(
                initialItem: row,
                initiallyClosed: drafts.showsRecentlyClosed,
                telemetry: telemetry
            )
            .environmentObject(tunnel)
        }
        .onChange(of: tunnel.isConnected) { _, connected in
            if !connected {
                drafts.resetForDisconnect()
                showingDisconnectConfirmation = false
                showingCloseAllConfirmation = false
                closeConnectionsError = nil
            }
        }
    }

    /// The page's actions in three groups (1.5.2): how the list is shown,
    /// pausing it, and what acts on every flow. Seven loose buttons read as
    /// clutter; a menu per group keeps every name visible where it is chosen.
    @ViewBuilder
    private var connectionActions: some View {
        Menu {
            Toggle(isOn: Binding(
                get: { drafts.groupsByApp },
                set: { value in
                    drafts.groupsByApp = value
                    drafts.groupingDimension = value ? .application : nil
                }
            )) {
                Label(AppLocalization.string("Group by app"), systemImage: "square.stack.3d.up")
            }
            .accessibilityIdentifier("connections-group-by-app")
            Toggle(isOn: Binding(
                get: { drafts.groupingDimension == .host },
                set: { value in
                    drafts.groupsByApp = false
                    drafts.groupingDimension = value ? .host : nil
                }
            )) {
                Label(AppLocalization.string("Group by host"), systemImage: "globe")
            }
            .accessibilityIdentifier("connections-group-by-host")
            Toggle(isOn: Binding(
                get: { drafts.groupingDimension == .outbound },
                set: { value in
                    drafts.groupsByApp = false
                    drafts.groupingDimension = value ? .outbound : nil
                }
            )) {
                Label(AppLocalization.string("Group by outbound"), systemImage: "point.3.connected.trianglepath.dotted")
            }
            .accessibilityIdentifier("connections-group-by-outbound")
            Toggle(isOn: Binding(
                get: { drafts.showsRecentlyClosed },
                set: { value in
                    drafts.showsRecentlyClosed = value
                    drafts.pausedConnections = nil
                    drafts.pausedAt = nil
                    drafts.recentlyClosedFrozenAt = value ? .now : nil
                }
            )) {
                Label(AppLocalization.string("Recently closed"), systemImage: "clock.arrow.circlepath")
            }
            .accessibilityIdentifier("connections-recently-closed-toggle")
            Divider()
            Picker(AppLocalization.string("Sort"), selection: $drafts.sort) {
                ForEach(ConnectionSort.allCases) { option in
                    Text(verbatim: option.localizedTitle).tag(option)
                }
            }
            .pickerStyle(.inline)
            .accessibilityIdentifier("connections-sort-picker")
        } label: {
            Label(
                AppLocalization.string("View"),
                systemImage: (drafts.groupsByApp || drafts.groupingDimension != nil || drafts.showsRecentlyClosed)
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease.circle"
            )
        }
        .menuIndicator(.visible)
        .aetherButton()
        .fixedSize()
        .help(AppLocalization.string("Group and sort connections"))
        .accessibilityIdentifier("connections-view-menu")

        if drafts.showsRecentlyClosed {
            ConnectionsClearRecentlyClosedButton(model: telemetry)
        }

        // The symbol alone keeps the header on one line in the smallest
        // window; the name stays in the tooltip and for VoiceOver, and
        // a paused list turns the button orange so it never passes for live.
        Button {
            if drafts.pausedConnections == nil {
                drafts.pausedConnections = telemetry.snapshot.connections
                drafts.pausedAt = .now
            } else {
                drafts.pausedConnections = nil
                drafts.pausedAt = nil
            }
        } label: {
            pauseButtonLabel
        }
        .help(AppLocalization.string(drafts.pausedConnections == nil ? "Pause list" : "Resume list"))
        .disabled(drafts.showsRecentlyClosed || (!tunnel.isConnected && drafts.pausedConnections == nil))
        .tint(drafts.pausedConnections == nil ? nil : .orange)
        .aetherButton(prominent: drafts.pausedConnections != nil)
        .accessibilityIdentifier("connections-pause-button")

        ConnectionsMoreMenuButton(
            model: telemetry,
            isConnected: tunnel.isConnected,
            isTransitioning: tunnel.isTransitioning,
            onRequestCloseAll: { showingCloseAllConfirmation = true },
            onRequestDisconnect: { showingDisconnectConfirmation = true }
        )
        .confirmationDialog(
            AppLocalization.string("Close All Active Connections"),
            isPresented: $showingCloseAllConfirmation,
            titleVisibility: .visible
        ) {
            Button(AppLocalization.string("Close All Connections"), role: .destructive) {
                close(.all)
            }
            Button(AppLocalization.string("Cancel"), role: .cancel) {}
        } message: {
            Text(AppLocalization.string("Active apps may immediately open new connections following the current rules."))
        }
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

    private var pauseButtonLabel: some View {
        Label {
            Text(AppLocalization.string(drafts.pausedConnections == nil ? "Pause list" : "Resume list"))
        } icon: {
            Image(systemName: drafts.pausedConnections == nil ? "pause.fill" : "play.fill")
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
        }
        .labelStyle(.iconOnly)
    }

    /// Sends one close request and leaves the list to the next telemetry
    /// sample; the apps that owned the connections reconnect on their own.
    private func close(_ request: ConnectionCloseRequest) {
        closeConnectionsError = nil
        Task {
            let closed = await tunnel.closeConnections(request)
            if !closed {
                closeConnectionsError = AppLocalization.string("Could not close the connection. Refresh or try again.")
            }
        }
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
        closeConnectionsError = nil
        Task {
            var allSucceeded = true
            for request in requests {
                let closed = await tunnel.closeConnections(request)
                if !closed {
                    allSucceeded = false
                }
            }
            if !allSucceeded {
                closeConnectionsError = AppLocalization.string("Some connections could not be closed. Refresh or try again.")
            }
        }
    }

    private func closeGroupConnections(
        entry: ConnectionTrafficEntry,
        dimension: ConnectionTrafficDimension,
        matching rows: [ConnectionTableItem]
    ) {
        let requests: [ConnectionCloseRequest]
        if dimension == .outbound {
            requests = [.proxyChainMember(entry.key)]
        } else {
            let filteredConnections = rows.map(\.connection).filter {
                ConnectionTrafficAggregator.matchesFilter($0, dimension: dimension, key: entry.key)
            }
            guard !filteredConnections.isEmpty else { return }
            var deduplicated: [ConnectionCloseRequest] = []
            for connection in filteredConnections {
                let request = ConnectionCloseRequest(row: connection)
                if !deduplicated.contains(request) {
                    deduplicated.append(request)
                }
            }
            requests = deduplicated
        }
        guard !requests.isEmpty else { return }
        closeConnectionsError = nil
        Task {
            var allSucceeded = true
            for request in requests {
                let ok = await tunnel.closeConnections(request)
                if !ok {
                    allSucceeded = false
                }
            }
            if !allSucceeded {
                closeConnectionsError = AppLocalization.string("Some connections could not be closed. Refresh or try again.")
            }
        }
    }
}

private struct ConnectionsClearRecentlyClosedButton: View {
    @ObservedObject var model: NetworkTelemetryViewModel

    var body: some View {
        if !model.recentlyClosed.connections.isEmpty {
            Button {
                model.clearRecentlyClosed()
            } label: {
                Label(AppLocalization.string("Clear"), systemImage: "trash")
            }
            .aetherButton()
            .fixedSize()
            .help(AppLocalization.string("Clear recently closed connections"))
            .accessibilityIdentifier("connections-clear-recently-closed")
        }
    }
}

private struct ConnectionsMoreMenuButton: View {
    @ObservedObject var model: NetworkTelemetryViewModel
    let isConnected: Bool
    let isTransitioning: Bool
    let onRequestCloseAll: () -> Void
    let onRequestDisconnect: () -> Void

    var body: some View {
        Menu {
            // Ends every listed flow but keeps the tunnel up; apps open
            // fresh connections, which follow the current rules and nodes.
            Button(AppLocalization.string("Close All Connections"), systemImage: "xmark.circle") {
                onRequestCloseAll()
            }
            .disabled(!isConnected || isTransitioning || model.snapshot.connections.isEmpty)
            .accessibilityIdentifier("close-all-connections")
            Divider()
            // This stops the tunnel, not only the listed flows, so it says
            // "Disconnect" like the overview and confirms first.
            Button(AppLocalization.string("Disconnect"), systemImage: "power", role: .destructive) {
                onRequestDisconnect()
            }
            .disabled(!isConnected || isTransitioning)
            .accessibilityIdentifier("disconnect-all-connections")
        } label: {
            // Named, like the actions beside it: a lone ellipsis drew a
            // button half their height.
            Label(AppLocalization.string("More"), systemImage: "ellipsis.circle")
        }
        .menuIndicator(.hidden)
        .aetherButton()
        .fixedSize()
        .help(AppLocalization.string("Close all active connections or disconnect"))
        .accessibilityIdentifier("connections-more-menu")
    }
}

private struct ConnectionsListSection: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var telemetry: NetworkTelemetryViewModel
    @ObservedObject var drafts: ConnectionsPageDraftState
    @Binding var inspectedConnection: ConnectionTableItem?
    let onCloseRequest: (ConnectionCloseRequest) -> Void
    let onCloseConnectionsOfApp: (SourceAppPresentation) -> Void
    let onCloseGroupConnections: (ConnectionTrafficEntry, ConnectionTrafficDimension, [ConnectionTableItem]) -> Void

    @StateObject private var rowsModel: ConnectionsRowsModel
    @State private var filterBarWidth: CGFloat = 0

    init(
        telemetry: NetworkTelemetryViewModel,
        drafts: ConnectionsPageDraftState,
        inspectedConnection: Binding<ConnectionTableItem?>,
        onCloseRequest: @escaping (ConnectionCloseRequest) -> Void,
        onCloseConnectionsOfApp: @escaping (SourceAppPresentation) -> Void,
        onCloseGroupConnections: @escaping (ConnectionTrafficEntry, ConnectionTrafficDimension, [ConnectionTableItem]) -> Void
    ) {
        self.telemetry = telemetry
        self.drafts = drafts
        self._inspectedConnection = inspectedConnection
        self.onCloseRequest = onCloseRequest
        self.onCloseConnectionsOfApp = onCloseConnectionsOfApp
        self.onCloseGroupConnections = onCloseGroupConnections
        _rowsModel = StateObject(wrappedValue: ConnectionsRowsModel(telemetry: telemetry, drafts: drafts))
    }

    private func refreshRows() {
        rowsModel.refresh(telemetry: telemetry, drafts: drafts)
    }

    var body: some View {
        let derived = rowsModel.data
        VStack(spacing: 0) {
            if derived.isDisplayedEmpty {
                emptyState
            } else {
                connectionList(derived: derived)
            }

            // One line at every width: the privacy note truncates (full text
            // on hover) rather than growing the footer past the window.
            HStack(spacing: AetherVisual.s3) {
                footerContents(derived: derived)
            }
                .layoutPriority(1)
                .font(.callout)
                .foregroundStyle(AetherVisual.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, AetherVisual.pageHorizontalPadding)
                .padding(.vertical, AetherVisual.s2)
                .overlay(alignment: .top) { Divider() }
        }
        .onAppear {
            refreshRows()
        }
        .onChange(of: telemetry.snapshot) { _, _ in
            guard drafts.pausedConnections == nil && !drafts.showsRecentlyClosed else { return }
            refreshRows()
        }
        .onChange(of: telemetry.recentlyClosed.connections) { _, _ in
            guard drafts.showsRecentlyClosed && drafts.pausedConnections == nil else { return }
            refreshRows()
        }
        .onChange(of: drafts.filter) { _, _ in refreshRows() }
        .onChange(of: drafts.sort) { _, _ in refreshRows() }
        .onChange(of: drafts.searchText) { _, _ in refreshRows() }
        .onChange(of: drafts.pausedConnections) { _, _ in refreshRows() }
        .onChange(of: drafts.showsRecentlyClosed) { _, _ in refreshRows() }
        .onChange(of: drafts.appFilter) { _, _ in refreshRows() }
        .onChange(of: drafts.dimensionFilter) { _, _ in refreshRows() }
        .onChange(of: drafts.groupsByApp) { _, _ in refreshRows() }
        .onChange(of: drafts.groupingDimension) { _, _ in refreshRows() }
    }

    @ViewBuilder
    private func footerContents(derived: ConnectionsRowsModel.SnapshotData) -> some View {
        if drafts.showsRecentlyClosed {
            Label(AppLocalization.string("Recently closed"), systemImage: "clock.arrow.circlepath")
                .foregroundStyle(AetherReadableTint(color: .indigo))
                .lineLimit(1)
                .fixedSize()
                .transition(AetherVisual.insertion)
        } else if drafts.pausedConnections != nil {
            Label(AppLocalization.string("List paused · session counters are live"), systemImage: "pause.circle.fill")
                .foregroundStyle(AetherReadableTint(color: .orange))
                .lineLimit(1)
                .fixedSize()
                .transition(AetherVisual.insertion)
        }
        // "Showing 0 of 0" only repeats the empty state above it.
        if !derived.isDisplayedEmpty {
            Text(
                AppLocalization.format(
                    "Showing %lld of %lld connections",
                    Int64(derived.rows.count),
                    Int64(derived.totalCount)
                )
            )
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
            symbol: drafts.showsRecentlyClosed ? "clock.arrow.circlepath" : "arrow.left.arrow.right",
            title: drafts.showsRecentlyClosed
                ? AppLocalization.string("No recently closed connections")
                : (tunnel.isConnected
                    ? AppLocalization.string("No active connections")
                    : AppLocalization.string("No connections yet")),
            detail: drafts.showsRecentlyClosed
                ? AppLocalization.string("Connections that finish while the tunnel is running appear here so you can inspect them or create rules.")
                : (tunnel.isConnected
                    ? AppLocalization.string("Each live connection shows its destination, matched rule, outlet and traffic.")
                    : AppLocalization.string("Connect to see each connection's destination, matched rule, outlet and traffic."))
        )
        .padding(.horizontal, AetherVisual.pageHorizontalPadding)
        .padding(.top, AetherVisual.s2)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private func connectionList(derived: ConnectionsRowsModel.SnapshotData) -> some View {
        let counts = derived.outletCounts
        let rows = derived.rows
        return VStack(alignment: .leading, spacing: 0) {
            // Single-instantiation filter bar: choose either segmented or menu
            // picker from the measured bar width rather than double-building via ViewThatFits.
            AetherFilterBarLayout {
                if shouldShowSegmentedFilter(counts: counts) {
                    segmentedFilter(counts: counts)
                } else {
                    menuFilter()
                }
                AetherSearchField(
                    text: $drafts.searchText,
                    prompt: AppLocalization.string("Search connections"),
                    accessibilityIdentifier: "connections-search-field"
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, AetherVisual.s3)
            .padding(.vertical, AetherVisual.s3)
            .onGeometryChange(for: CGFloat.self) { proxy in
                proxy.size.width
            } action: { newWidth in
                if abs(filterBarWidth - newWidth) >= 1 {
                    filterBarWidth = newWidth
                }
            }

            if derived.isSnapshotTruncated {
                HStack(spacing: AetherVisual.s1) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .accessibilityHidden(true)
                    Text(
                        AppLocalization.format(
                            "All counts %lld active flows; Proxied, Direct, and Rejected reflect the top %lld captured flows.",
                            Int64(derived.allCount),
                            Int64(derived.snapshotBreakdownCount)
                        )
                    )
                }
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, AetherVisual.s3)
                .padding(.bottom, AetherVisual.s2)
                .accessibilityIdentifier("connections-snapshot-cap-note")
            }

            if let appFilter = drafts.appFilter {
                appFilterBar(appFilter)
            }
            if let dimensionFilter = drafts.dimensionFilter {
                dimensionFilterBar(dimensionFilter)
            }

            if rows.isEmpty {
                ContentUnavailableView {
                    Label(AppLocalization.string("No matching connections"), systemImage: "magnifyingglass")
                } description: {
                    Text(AppLocalization.string("Change the filter, or clear the search field."))
                } actions: {
                    Button(AppLocalization.string("Clear Filters")) {
                        drafts.filter = .all
                        drafts.searchText = ""
                        drafts.appFilter = nil
                        drafts.dimensionFilter = nil
                    }
                    .aetherButton()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if drafts.groupsByApp {
                appTable(derived.appRows)
            } else if let dimension = drafts.groupingDimension, dimension != .application {
                leaderboardTable(derived.leaderboardEntries, dimension: dimension, matching: rows)
            } else {
                connectionTable(rows)
            }
        }
        .aetherPanel()
        .padding(.horizontal, AetherVisual.pageHorizontalPadding)
        .padding(.bottom, AetherVisual.s2)
    }

    private func appFilterBar(_ filter: ConnectionsAppFilter) -> some View {
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
                    drafts.appFilter = nil
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

    private func dimensionFilterBar(_ filter: ConnectionsDimensionFilter) -> some View {
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
                    drafts.dimensionFilter = nil
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
        let showsLiveRates = drafts.pausedConnections == nil && !drafts.showsRecentlyClosed
        return Table(rows, selection: $drafts.selectedConnectionID) {
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
        .onKeyPress(.return) {
            guard inspectedConnection == nil, let selected = selectedRow(in: rows) else {
                return .ignored
            }
            inspectedConnection = selected
            return .handled
        }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            guard inspectedConnection == nil,
                  tunnel.isConnected,
                  !drafts.showsRecentlyClosed,
                  let selected = selectedRow(in: rows) else {
                return .ignored
            }
            onCloseRequest(.init(row: selected.connection))
            return .handled
        }
        .onDeleteCommand {
            guard inspectedConnection == nil,
                  tunnel.isConnected,
                  !drafts.showsRecentlyClosed,
                  let selected = selectedRow(in: rows) else {
                return
            }
            onCloseRequest(.init(row: selected.connection))
        }
        .onCopyCommand {
            guard let selected = selectedRow(in: rows) else { return [] }
            return [NSItemProvider(object: selected.connection.destinationAddress as NSString)]
        }
        .onKeyPress(characters: CharacterSet(charactersIn: "cC")) { press in
            guard inspectedConnection == nil,
                  press.modifiers.contains(.command),
                  let selected = selectedRow(in: rows) else {
                return .ignored
            }
            copyDestination(selected.connection)
            return .handled
        }
    }

    private func selectedRow(in rows: [ConnectionTableItem]) -> ConnectionTableItem? {
        guard let selectedID = drafts.selectedConnectionID else { return nil }
        return rows.first(where: { $0.id == selectedID })
    }

    private func durationColumnCell(for row: ConnectionTableItem) -> some View {
        ConnectionDurationColumnCell(
            connection: row.connection,
            showsCloseButton: tunnel.isConnected && !drafts.showsRecentlyClosed,
            isSelected: drafts.selectedConnectionID == row.id,
            isPaused: drafts.pausedConnections != nil || drafts.showsRecentlyClosed,
            frozenAt: drafts.pausedAt ?? (drafts.showsRecentlyClosed ? drafts.recentlyClosedFrozenAt : nil),
            onClose: { onCloseRequest(.init(row: row.connection)) }
        )
        .contextMenu { connectionRowContextMenu(for: row) }
        .onTapGesture(count: 2) { inspectedConnection = row }
    }

    @ViewBuilder
    private func connectionRowContextMenu(for row: ConnectionTableItem) -> some View {
        Button(AppLocalization.string("Copy destination")) { copyDestination(row.connection) }
        Button(AppLocalization.string("Connection details")) { inspectedConnection = row }
        if tunnel.isConnected, !drafts.showsRecentlyClosed {
            Button(AppLocalization.string("Close Connection")) {
                onCloseRequest(.init(row: row.connection))
            }
        }
        Divider()
        destinationRuleMenu(for: row.connection)
        appContextMenu(
            SourceAppDirectory.shared.presentation(for: row.connection),
            allowsLiveClose: tunnel.isConnected && !drafts.showsRecentlyClosed
        )
    }

    /// One row per app: how many connections it has open and their traffic.
    /// Double-click (or the context menu) lists that app's connections.
    private func appTable(_ apps: [ConnectionAppRow]) -> some View {
        Table(apps, selection: $drafts.selectedAppKey) {
            TableColumn(AppLocalization.string("App")) { row in
                ConnectionAppCell(app: row.app)
                    .contextMenu { appContextMenu(row.app, allowsLiveClose: tunnel.isConnected && !drafts.showsRecentlyClosed) }
                    .onTapGesture(count: 2) { showOnly(row.app) }
            }
            .width(min: 140, ideal: 220, max: 520)
            TableColumn(AppLocalization.string("Connections")) { row in
                Text(verbatim: "\(row.connectionCount)")
                    .font(.body.monospacedDigit())
                    .aetherLiveValue()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: AetherVisual.tableRowHeight)
                    .contextMenu { appContextMenu(row.app, allowsLiveClose: tunnel.isConnected && !drafts.showsRecentlyClosed) }
            }
            .width(min: 72, ideal: 84, max: 120)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Outlet")) { row in
                let summary = row.outletSummary
                Text(summary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: AetherVisual.tableRowHeight)
                    .help(Text(verbatim: summary))
                    .contextMenu { appContextMenu(row.app, allowsLiveClose: tunnel.isConnected && !drafts.showsRecentlyClosed) }
            }
            .width(min: 84, ideal: 120, max: 320)
            TableColumn(AppLocalization.string("Traffic")) { row in
                Group {
                    if row.liveBytesPerSecond > 0 {
                        VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
                            Text(verbatim: "↓ \(formattedRate(row.liveDownloadBytesPerSecond))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(AetherReadableTint(color: .accentColor))
                                .lineLimit(1)
                                .aetherLiveValue()
                            Text(verbatim: "↑ \(formattedRate(row.liveUploadBytesPerSecond))")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(AetherReadableTint(color: .accentColor))
                                .lineLimit(1)
                                .aetherLiveValue()
                        }
                        .help(Text(verbatim: "↓ \(formattedBytes(row.downloadTotal)) · ↑ \(formattedBytes(row.uploadTotal))"))
                    } else {
                        VStack(alignment: .trailing, spacing: AetherVisual.s1) {
                            Text(verbatim: "↓ \(formattedBytes(row.downloadTotal))")
                            Text(verbatim: "↑ \(formattedBytes(row.uploadTotal))")
                        }
                        .font(.body.monospacedDigit())
                        .aetherLiveValue()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: AetherVisual.tableRowHeight)
                .contextMenu { appContextMenu(row.app, allowsLiveClose: tunnel.isConnected && !drafts.showsRecentlyClosed) }
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
        dimension: ConnectionTrafficDimension,
        matching rows: [ConnectionTableItem]
    ) -> some View {
        let primaryColumnTitle = dimension == .host
            ? AppLocalization.string("Destination")
            : AppLocalization.string("Outlet")
        return Table(entries, selection: $drafts.selectedDimensionKey) {
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
                .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension, matching: rows) }
                .onTapGesture(count: 2) {
                    showOnlyDimension(entry)
                }
            }
            .width(min: 140, ideal: 220, max: 520)
            TableColumn(AppLocalization.string("Connections")) { entry in
                Text(verbatim: "\(entry.connectionCount)")
                    .font(.body.monospacedDigit())
                    .aetherLiveValue()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: AetherVisual.tableRowHeight)
                    .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension, matching: rows) }
            }
            .width(min: 72, ideal: 84, max: 120)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Share")) { entry in
                let percent = Int((entry.shareOfTotal * 100).rounded())
                Text(verbatim: "\(percent)%")
                    .font(.body.monospacedDigit())
                    .aetherLiveValue()
                    .foregroundStyle(AetherVisual.secondaryText)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .frame(height: AetherVisual.tableRowHeight)
                    .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension, matching: rows) }
            }
            .width(min: 56, ideal: 68, max: 100)
            .alignment(.numeric)
            TableColumn(AppLocalization.string("Traffic")) { entry in
                VStack(alignment: .trailing, spacing: AetherVisual.s1) {
                    Text(verbatim: "↓ \(formattedBytes(entry.downloadTotal))")
                    Text(verbatim: "↑ \(formattedBytes(entry.uploadTotal))")
                }
                .font(.body.monospacedDigit())
                .aetherLiveValue()
                .frame(maxWidth: .infinity, alignment: .trailing)
                .frame(height: AetherVisual.tableRowHeight)
                .contextMenu { leaderboardContextMenu(for: entry, dimension: dimension, matching: rows) }
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
        dimension: ConnectionTrafficDimension,
        matching rows: [ConnectionTableItem]
    ) -> some View {
        Button(AppLocalization.format("Show only %@", entry.displayName)) {
            showOnlyDimension(entry)
        }
        if tunnel.isConnected, !drafts.showsRecentlyClosed {
            Button {
                onCloseGroupConnections(entry, dimension, rows)
            } label: {
                Text(AppLocalization.format(
                    "Close connections (%lld)",
                    Int64(entry.connectionCount)
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

    private func showOnlyDimension(_ entry: ConnectionTrafficEntry) {
        drafts.dimensionFilter = ConnectionsDimensionFilter(
            dimension: entry.dimension,
            key: entry.key,
            name: entry.displayName
        )
        drafts.groupsByApp = false
        drafts.groupingDimension = nil
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
                                if saved, tunnel.isConnected, !drafts.showsRecentlyClosed {
                                    onCloseRequest(.init(row: connection))
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
                                if deleted, tunnel.isConnected, !drafts.showsRecentlyClosed {
                                    onCloseRequest(.init(row: connection))
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
    private func appContextMenu(_ app: SourceAppPresentation, allowsLiveClose: Bool) -> some View {
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
                            if saved, allowsLiveClose {
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
                            if deleted, allowsLiveClose {
                                closeConnections(of: app)
                            }
                        }
                    }
                }
            }
            Divider()
        }
        if allowsLiveClose {
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

    private func closeConnections(of app: SourceAppPresentation) {
        onCloseConnectionsOfApp(app)
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

    private func showOnly(_ app: SourceAppPresentation) {
        drafts.appFilter = ConnectionsAppFilter(key: app.groupingKey, name: app.displayName)
        drafts.groupsByApp = false
        drafts.groupingDimension = nil
    }

    private func menuFilter() -> some View {
        Picker(AppLocalization.string("Filter"), selection: $drafts.filter) {
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

    private func shouldShowSegmentedFilter(counts: [ConnectionOutletFilter: Int]) -> Bool {
        guard filterBarWidth >= 1 else { return true }
        let titles = ConnectionOutletFilter.allCases.map {
            "\($0.localizedTitle) \(counts[$0, default: 0])"
        }
        let segmentsWidth = AetherSegmentedPicker<ConnectionOutletFilter>.measureTotalWidth(
            for: titles,
            controlSize: .regular
        )
        let horizontalInsets = AetherVisual.s3 * 2
        let needed = segmentsWidth + AetherVisual.s3 + AetherVisual.searchFieldMinWidth + horizontalInsets
        return needed <= filterBarWidth
    }

    private func segmentedFilter(counts: [ConnectionOutletFilter: Int]) -> some View {
        AetherSegmentedPicker(
            selection: $drafts.filter,
            options: ConnectionOutletFilter.allCases.map {
                .init(value: $0, title: "\($0.localizedTitle) \(counts[$0, default: 0])")
            },
            accessibilityLabel: AppLocalization.string("Filter"),
            accessibilityIdentifier: "connections-filter-picker"
        )
        .fixedSize(horizontal: true, vertical: false)
    }

    private func copyDestination(_ connection: ConnectionTelemetry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(connection.destinationAddress, forType: .string)
    }
}

/// A compact row that grows for longer status text. Rates read as
/// an em dash when nothing is running: zero is a measurement, and claiming a
/// measurement that was never taken is what made the old page feel wrong.
private struct SessionBar: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @ObservedObject var telemetry: NetworkTelemetryViewModel

    var body: some View {
        HStack(alignment: .center, spacing: AetherVisual.s4) {
            // Connected state is already on the sidebar and overview; here
            // the bar only names it when there is something to act on.
            if !tunnel.isConnected {
                HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
                    HStack(spacing: AetherVisual.s2) {
                        AetherStatusBeacon(
                            isConnected: false,
                            isConnecting: tunnel.state == .connecting || tunnel.state == .recovering,
                            isFailed: tunnel.isFailed,
                            size: 7
                        )
                        Text(tunnel.compactStatusTitle)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text(AppLocalization.string("Traffic is using the normal network path"))
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .lineLimit(1)
                }
            }

            if let since = tunnel.connectedSince, tunnel.isConnected {
                HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                        .accessibilityHidden(true)
                    SessionDurationText(since: since)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(AppLocalization.string("Elapsed"))
                Divider().frame(height: AetherVisual.inlineSeparatorHeight)
            }

            rate(symbol: "arrow.down", value: downloadText, tint: .cyan)
                .accessibilityIdentifier("connections-download-title")
            rate(symbol: "arrow.up", value: uploadText, tint: .purple)
                .accessibilityIdentifier("connections-upload-title")

            AetherSessionOptionalSlotLayout {
                HStack(alignment: .center, spacing: AetherVisual.s2) {
                    Divider().frame(height: AetherVisual.inlineSeparatorHeight)
                    HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
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
            }

            Spacer(minLength: AetherVisual.s3)

            if let outlet {
                Divider().frame(height: AetherVisual.inlineSeparatorHeight)
                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Outlet"))
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AetherVisual.secondaryText)
                    Text(outlet)
                        .font(.callout.weight(.medium))
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
        .padding(.vertical, AetherVisual.s2)
        .frame(minHeight: AetherVisual.compactRowHeight)
        .background(
            AetherVisual.cardFill,
            in: RoundedRectangle(cornerRadius: AetherVisual.compactPanelRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: AetherVisual.compactPanelRadius, style: .continuous)
                .strokeBorder(AetherVisual.cardStroke, lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connections-session-bar")
    }

    private func rate(symbol: String, value: String, tint: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s1) {
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
            return AppLocalization.format(
                "Core %@ · App %@",
                formattedBytes(telemetry.snapshot.memoryBytes),
                formattedBytes(telemetry.appMemoryBytes)
            )
        }
        return AppLocalization.format(
            "App %@",
            formattedBytes(telemetry.appMemoryBytes)
        )
    }

    private var outlet: String? {
        guard tunnel.isConnected else { return nil }
        switch tunnel.effectiveRoutingMode {
        case .direct:
            return AppLocalization.string("Direct outbound (no proxy)")
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

}

/// Leaf timer label so elapsed session seconds tick cleanly without re-evaluating `SessionBar`.
private struct SessionDurationText: View {
    let since: Date

    var body: some View {
        TimelineView(.periodic(from: since, by: 1)) { context in
            Text(formattedDuration(at: context.date))
                .font(.body.monospacedDigit())
                .aetherLiveValue()
        }
    }

    private func formattedDuration(at date: Date) -> String {
        let elapsed = Int(date.timeIntervalSince(since))
        guard elapsed >= 0, elapsed <= 31 * 24 * 3_600 else {
            return "—"
        }
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
struct ConnectionAppRow: Identifiable {
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
        VStack(alignment: .trailing, spacing: AetherVisual.sMicro) {
            if let rates, rates.totalBytesPerSecond > 0 {
                Text(verbatim: "↓ \(formattedRate(rates.downloadBytesPerSecond))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(AetherReadableTint(color: .accentColor))
                    .lineLimit(1)
                    .aetherLiveValue()
                Text(verbatim: "↑ \(formattedRate(rates.uploadBytesPerSecond))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AetherReadableTint(color: .accentColor))
                    .lineLimit(1)
                    .aetherLiveValue()
            } else {
                Text(verbatim: "↓ \(formattedBytes(connection.downloadTotal))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .aetherLiveValue()
                Text(verbatim: "↑ \(formattedBytes(connection.uploadTotal))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(AetherVisual.secondaryText)
                    .lineLimit(1)
                    .aetherLiveValue()
            }
        }
        .help(Text(verbatim: "↓ \(formattedBytes(connection.downloadTotal)) · ↑ \(formattedBytes(connection.uploadTotal))"))
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: AetherVisual.tableRowHeight)
    }
}

private struct ConnectionDurationColumnCell: View {
    let connection: ConnectionTelemetry
    let showsCloseButton: Bool
    let isSelected: Bool
    var isPaused: Bool = false
    var frozenAt: Date? = nil
    let onClose: () -> Void
    @State private var isHovered = false

    var body: some View {
        let revealClose = showsCloseButton && (isHovered || isSelected)
        ConnectionDurationCell(
            connection: connection,
            isPaused: isPaused,
            frozenAt: frozenAt
        )
        .opacity(revealClose ? 0.35 : 1)
        .overlay(alignment: .trailing) {
            if showsCloseButton {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(AetherVisual.secondaryText)
                }
                .buttonStyle(.plain)
                .background(.regularMaterial, in: Circle())
                .help(AppLocalization.string("Close Connection"))
                .accessibilityLabel(AppLocalization.string("Close Connection"))
                .accessibilityIdentifier("close-connection-row-button")
                .opacity(revealClose ? 1 : 0)
                .disabled(!revealClose)
                .focusable(revealClose)
                .allowsHitTesting(revealClose)
                .accessibilityHidden(!revealClose)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .frame(height: AetherVisual.tableRowHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .aetherAnimation(AetherVisual.quickFade, value: revealClose)
    }
}

private struct ConnectionDurationCell: View {
    let connection: ConnectionTelemetry
    var isPaused: Bool = false
    var frozenAt: Date? = nil

    var body: some View {
        let referenceDate = (isPaused ? frozenAt : nil) ?? frozenAt ?? Date.now
        let elapsed = duration(at: referenceDate)
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

    private func duration(at referenceDate: Date) -> String? {
        let started = Double(connection.startedAtUnixMilliseconds) / 1_000
        let elapsed = Int(referenceDate.timeIntervalSince1970 - started)
        // A stale or malformed provider timestamp must not turn into a
        // multi-thousand-hour duration in the table.
        guard elapsed >= 0, elapsed <= 31 * 24 * 3_600 else { return nil }
        return AppLocalization.duration(TimeInterval(elapsed), includesSeconds: true)
    }
}

private struct ConnectionInspector: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @Environment(\.dismiss) private var dismiss
    let initialItem: ConnectionTableItem
    let initiallyClosed: Bool
    @ObservedObject private var model: NetworkTelemetryViewModel
    @State private var lastSeenConnection: ConnectionTelemetry
    @State private var cachedDecisionTrace: ConnectionRouteDecisionTrace?
    @State private var httpCaptures: [MITMHTTPCaptureEntry] = []
    @State private var isLoadingHTTPCaptures = false

    init(
        initialItem: ConnectionTableItem,
        initiallyClosed: Bool,
        telemetry: NetworkTelemetryViewModel
    ) {
        self.initialItem = initialItem
        self.initiallyClosed = initiallyClosed
        self.model = telemetry
        _lastSeenConnection = State(initialValue: initialItem.connection)
    }

    /// Identity tracks `TunnelManager`'s `ConnectionLiveRateTracker` and uses
    /// `ConnectionTableItem.disambiguatedMatch` when peer flows shift occurrence indices.
    private func resolveLiveItem() -> ConnectionTableItem? {
        guard !initiallyClosed, tunnel.isConnected else { return nil }
        return ConnectionTableItem.disambiguatedMatch(
            for: initialItem,
            in: model.identifiedSnapshotConnections()
        )
    }

    private func timingValueText(_ milliseconds: UInt32, timing: ConnectionTimingBreakdown) -> String {
        let formatted = AppLocalization.format("%lld ms", Int64(milliseconds))
        if timing.isMeasuredByEngine {
            return formatted
        }
        return AppLocalization.format("%@ (Estimated)", formatted)
    }

    private func computeDecisionTrace(for conn: ConnectionTelemetry) -> ConnectionRouteDecisionTrace {
        ConnectionRouteDecisionTrace.evaluate(
            connection: conn,
            routingMode: tunnel.effectiveRoutingMode,
            customHosts: tunnel.effectiveCustomHosts,
            customRules: tunnel.effectiveRuntimeCustomRules,
            summary: tunnel.activeProfileSummary
        )
    }

    private var quickRuleTargets: [CustomRuleTarget] {
        let groups = (tunnel.activeProfileSummary?.proxyGroups ?? []).map(\.name)
        return [.direct] + groups.map { .proxy($0) } + [.reject]
    }

    var body: some View {
        let currentItem = resolveLiveItem()
        let currentLive = currentItem?.connection
        let connection = currentLive ?? lastSeenConnection
        let isClosed = initiallyClosed || currentLive == nil
        let liveRates: ConnectionTransferRates? = isClosed ? nil : (currentItem.flatMap { model.connectionRates[$0.id] })
        let destination = connection.destinationAddress
        let app = SourceAppDirectory.shared.presentation(for: connection)
        let trace = cachedDecisionTrace ?? computeDecisionTrace(for: initialItem.connection)
        VStack(alignment: .leading, spacing: 0) {
            AetherSheetHeader(
                symbol: connection.transport == .tcp ? "arrow.left.arrow.right" : "dot.radiowaves.left.and.right",
                title: destination,
                subtitle: isClosed
                    ? AppLocalization.string("Connection closed. Showing last captured snapshot.")
                    : AppLocalization.string("Live connection telemetry and route decision path."),
                tint: AppSection.connections.tileColor
            ) {
                inspectorStatusBadge(isClosed: isClosed)
            }
            .padding([.horizontal, .top], AetherVisual.dialogPadding)

            if let ruleMessage = tunnel.customRuleMessage {
                Group {
                    if tunnel.customRuleMessageIsError {
                        AetherInlineMessage(text: ruleMessage, kind: .failure, isCompact: true)
                    } else {
                        Label(ruleMessage, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AetherReadableTint(color: .green))
                    }
                }
                .padding(.horizontal, AetherVisual.dialogPadding)
                .padding(.top, AetherVisual.s2)
            }

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
                    ConnectionRoutePipelineView(
                        connection: connection,
                        appName: app.displayName,
                        trace: trace,
                        routingMode: tunnel.effectiveRoutingMode
                    )
                }
                quickRulesSection(connection: connection, app: app)
                Section(AppLocalization.string("Traffic")) {
                    if let liveRates, liveRates.totalBytesPerSecond > 0 {
                        LabeledContent(AppLocalization.string("Live rate")) {
                            Text(verbatim: "↓ \(formattedRate(liveRates.downloadBytesPerSecond)) · ↑ \(formattedRate(liveRates.uploadBytesPerSecond))")
                                .font(.callout.monospacedDigit())
                                .foregroundStyle(AetherReadableTint(color: .accentColor))
                                .aetherLiveValue()
                        }
                    }
                    LabeledContent(AppLocalization.string("Download")) {
                        Text(bytes(connection.downloadTotal))
                            .font(.callout.monospacedDigit())
                            .aetherLiveValue()
                    }
                    LabeledContent(AppLocalization.string("Upload")) {
                        Text(bytes(connection.uploadTotal))
                            .font(.callout.monospacedDigit())
                            .aetherLiveValue()
                    }
                }
                if let timing = ConnectionTimingBreakdown.resolve(for: connection) {
                    Section(AppLocalization.string("Timing")) {
                        LabeledContent(
                            AppLocalization.string("DNS lookup"),
                            value: timingValueText(timing.dnsMilliseconds, timing: timing)
                        )
                        LabeledContent(
                            AppLocalization.string("Outbound handshake"),
                            value: timingValueText(timing.connectMilliseconds, timing: timing)
                        )
                        LabeledContent(
                            AppLocalization.string("Total setup"),
                            value: timingValueText(timing.totalMilliseconds, timing: timing)
                        )
                    }
                }

                httpInspectionSection(for: connection)
            }
            .aetherSettingsForm(isSheet: true)
            .task(id: connection.destination) {
                await reloadHTTPCaptures(for: connection.destination)
            }
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
                    tunnel.pendingRuleTestDestination = connection.destinationAddress
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
        .onAppear {
            cachedDecisionTrace = computeDecisionTrace(for: currentLive ?? lastSeenConnection)
        }
        .onChange(of: tunnel.customRules) { _, _ in
            cachedDecisionTrace = computeDecisionTrace(for: currentLive ?? lastSeenConnection)
        }
        .onChange(of: tunnel.effectiveRoutingMode) { _, _ in
            cachedDecisionTrace = computeDecisionTrace(for: currentLive ?? lastSeenConnection)
        }
        .onChange(of: tunnel.effectiveCustomHosts) { _, _ in
            cachedDecisionTrace = computeDecisionTrace(for: currentLive ?? lastSeenConnection)
        }
        .onChange(of: tunnel.activeProfileID) { _, _ in
            cachedDecisionTrace = computeDecisionTrace(for: currentLive ?? lastSeenConnection)
        }
        .onChange(of: currentLive) { _, latest in
            if let latest {
                lastSeenConnection = latest
            } else if !initiallyClosed,
                      let closedMatch = model.recentlyClosed.connections.first(where: {
                          $0.transport == initialItem.connection.transport
                              && $0.destination == initialItem.connection.destination
                              && $0.destinationPort == initialItem.connection.destinationPort
                              && $0.startedAtUnixMilliseconds == initialItem.connection.startedAtUnixMilliseconds
                      }) {
                lastSeenConnection = closedMatch
            }
        }
    }

    private func inspectorStatusBadge(isClosed: Bool) -> some View {
        HStack(spacing: AetherVisual.s1) {
            Circle()
                .fill(isClosed ? AnyShapeStyle(AetherVisual.secondaryText) : AnyShapeStyle(AetherReadableTint(color: .green)))
                .frame(width: AetherVisual.statusDotSize, height: AetherVisual.statusDotSize)
            Text(isClosed ? AppLocalization.string("Closed") : AppLocalization.string("Live"))
                .font(.caption.weight(.semibold))
        }
        .foregroundStyle(isClosed ? AnyShapeStyle(AetherVisual.secondaryText) : AnyShapeStyle(AetherReadableTint(color: .green)))
        .padding(.horizontal, AetherVisual.pillHorizontalPadding)
        .padding(.vertical, AetherVisual.pillVerticalPadding)
        .background(
            isClosed ? AetherVisual.neutralFill : AetherVisual.tintFill(.green),
            in: Capsule()
        )
        .accessibilityIdentifier("connection-inspector-status-badge")
    }

    @ViewBuilder
    private func quickRulesSection(connection: ConnectionTelemetry, app: SourceAppPresentation) -> some View {
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
                                            await closeInspectorAppConnections(for: connection)
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
                                            await closeInspectorAppConnections(for: connection)
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

    private func closeInspectorAppConnections(for connection: ConnectionTelemetry) async {
        let directory = SourceAppDirectory.shared
        let groupingKey = directory.presentation(for: connection).groupingKey
        let siblingApps = model.snapshot.connections
            .filter { directory.presentation(for: $0).groupingKey == groupingKey }
            .map(ConnectionCloseApp.init(of:))
        let requests = ConnectionCloseRequest.closing(
            apps: siblingApps.isEmpty ? [ConnectionCloseApp(of: connection)] : siblingApps
        )
        for request in requests {
            _ = await tunnel.closeConnections(request)
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
        Int64(clamping: value).formatted(
            .byteCount(style: .file).locale(AppLocalization.currentLocale)
        )
    }

    @ViewBuilder
    private func httpInspectionSection(for connection: ConnectionTelemetry) -> some View {
        Section {
            if !tunnel.mitmConfiguration.isEnabled {
                Text(
                    AppLocalization.string(
                        "HTTPS decryption (MITM) is off. Enable it in Settings → Network to inspect decrypted HTTP requests and responses."
                    )
                )
                .font(.caption)
                .foregroundStyle(AetherVisual.secondaryText)
            } else {
                HStack {
                    if isLoadingHTTPCaptures {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(
                        httpCaptures.isEmpty
                            ? AppLocalization.string("No decrypted HTTP captures recorded for this host yet.")
                            : AppLocalization.format(
                                "Showing %@ decrypted HTTP captures",
                                String(min(httpCaptures.count, 20))
                            )
                    )
                    .font(.caption)
                    .foregroundStyle(AetherVisual.secondaryText)

                    Spacer()

                    Button(AppLocalization.string("Refresh")) {
                        Task { await reloadHTTPCaptures(for: connection.destination) }
                    }
                    .aetherButton()
                    .controlSize(.small)
                    .disabled(isLoadingHTTPCaptures)
                }

                ForEach(httpCaptures.prefix(20)) { entry in
                    VStack(alignment: .leading, spacing: AetherVisual.s2) {
                        HStack(spacing: AetherVisual.s2) {
                            Text(verbatim: "[\(entry.statusCode)] \(entry.method)")
                                .font(.system(.callout, design: .monospaced).weight(.semibold))
                                .foregroundStyle(
                                    entry.statusCode >= 400
                                        ? AnyShapeStyle(AetherReadableTint(color: .orange))
                                        : AnyShapeStyle(AetherReadableTint(color: .green))
                                )

                            Text(AppLocalization.format("%@ ms", String(entry.durationMs)))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(AetherVisual.secondaryText)

                            Spacer()

                            AetherCopyButton(
                                title: Text(AppLocalization.string("Copy as cURL")),
                                systemImage: "terminal",
                                copiedTitle: Text(AppLocalization.string("Copied")),
                                action: { copyCaptureAsCURL(entry) }
                            )
                            .aetherButton()
                            .controlSize(.small)
                        }

                        Text(entry.url)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)

                        if !entry.appliedRules.isEmpty {
                            Text(
                                AppLocalization.format(
                                    "Applied rules: %@",
                                    entry.appliedRules.joined(separator: ", ")
                                )
                            )
                            .font(.caption2)
                            .foregroundStyle(AetherReadableTint(color: .accentColor))
                        }

                        DisclosureGroup(AppLocalization.string("Headers & Body Preview")) {
                            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                                if !entry.requestHeaders.isEmpty {
                                    Text(AppLocalization.string("Request Headers"))
                                        .font(.caption2.weight(.semibold))
                                    Text(formattedHeaders(entry.requestHeaders))
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                if !entry.requestBodyPreview.isEmpty {
                                    Text(AppLocalization.string("Request Body"))
                                        .font(.caption2.weight(.semibold))
                                    Text(entry.requestBodyPreview)
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                if !entry.responseHeaders.isEmpty {
                                    Text(AppLocalization.string("Response Headers"))
                                        .font(.caption2.weight(.semibold))
                                    Text(formattedHeaders(entry.responseHeaders))
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                                if !entry.responseBodyPreview.isEmpty {
                                    Text(AppLocalization.string("Response Body"))
                                        .font(.caption2.weight(.semibold))
                                    Text(entry.responseBodyPreview)
                                        .font(.system(.caption2, design: .monospaced))
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, AetherVisual.s1)
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, AetherVisual.s1)
                }
            }
        } header: {
            Text(AppLocalization.string("HTTP Inspection (MITM)"))
        }
    }

    private func reloadHTTPCaptures(for destination: String) async {
        guard tunnel.mitmConfiguration.isEnabled, tunnel.isConnected else {
            httpCaptures = []
            return
        }
        isLoadingHTTPCaptures = true
        let entries = await tunnel.fetchMITMHTTPCaptures(matchingHost: destination)
        isLoadingHTTPCaptures = false
        httpCaptures = entries
    }

    private func copyCaptureAsCURL(_ entry: MITMHTTPCaptureEntry) -> Bool {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.cURLCommand(), forType: .string)
        return true
    }

    private func formattedHeaders(_ headers: [String: String]) -> String {
        headers.keys.sorted().compactMap { key in
            guard let value = headers[key] else { return nil }
            return "\(key): \(value)"
        }.joined(separator: "\n")
    }
}

private struct ConnectionRoutePipelineView: View {
    let connection: ConnectionTelemetry
    let appName: String
    let trace: ConnectionRouteDecisionTrace
    let routingMode: RoutingMode

    private struct PipelineHop: Identifiable {
        let id: String
        let stageTitle: String
        let value: String
        let detail: String?
        let symbol: String
        let tint: Color
    }

    private var hops: [PipelineHop] {
        var result: [PipelineHop] = []
        let timing = ConnectionTimingBreakdown.resolve(for: connection)

        // 1. App
        let transportLabel = connection.transport == .tcp ? "TCP" : "UDP"
        let appDetail = connection.sourceAppIdentifier.isEmpty
            ? transportLabel
            : "\(transportLabel) · \(connection.sourceAppIdentifier)"
        result.append(PipelineHop(
            id: "app",
            stageTitle: AppLocalization.string("App"),
            value: appName,
            detail: appDetail,
            symbol: "app.dashed",
            tint: .blue
        ))

        // 2. DNS / SNI
        let dnsValue = trace.resolvedHostAlias.map { "\(connection.destinationHost) → \($0)" }
            ?? connection.destinationAddress
        let dnsDetail: String? = if let timing {
            timing.isMeasuredByEngine
                ? AppLocalization.format("%lld ms", Int64(timing.dnsMilliseconds))
                : AppLocalization.format("~%lld ms", Int64(timing.dnsMilliseconds))
        } else if trace.resolvedHostAlias != nil {
            AppLocalization.string("Hosts override")
        } else {
            nil
        }
        result.append(PipelineHop(
            id: "dns",
            stageTitle: AppLocalization.string("DNS / SNI"),
            value: dnsValue,
            detail: dnsDetail,
            symbol: "network",
            tint: trace.resolvedHostAlias != nil ? .green : .indigo
        ))

        // 3. Matched Rule
        let ruleValue: String
        let ruleDetail: String
        if routingMode == .direct {
            ruleValue = AppLocalization.string("Direct mode")
            ruleDetail = AppLocalization.string("Routing mode")
        } else if routingMode == .global {
            ruleValue = trace.steps.first(where: { $0.stage == .routingMode })?.summary
                ?? AppLocalization.string("Global mode")
            ruleDetail = AppLocalization.string("Routing mode")
        } else if let appRule = trace.matchedApplicationRule {
            ruleValue = "\(appName) → \(appRule.target.rawString)"
            ruleDetail = AppLocalization.string("Application rule")
        } else if let customRule = trace.matchedCustomRule {
            ruleValue = "\(customRule.kind.rawValue) \(customRule.value) → \(customRule.target.rawString)"
            ruleDetail = AppLocalization.string("Custom rule")
        } else {
            ruleValue = trace.matchedRuleOrder.map { "#\($0) · \(trace.matchedRuleSummary)" }
                ?? trace.matchedRuleSummary
            ruleDetail = AppLocalization.string("Profile rule")
        }
        result.append(PipelineHop(
            id: "rule",
            stageTitle: AppLocalization.string("Matched rule"),
            value: ruleValue,
            detail: ruleDetail,
            symbol: "checklist",
            tint: .green
        ))

        // 4. Proxy Group (intermediate selector / relay hops when present)
        if trace.outboundHops.count > 1 {
            let groupChain = trace.outboundHops.dropLast().joined(separator: " → ")
            result.append(PipelineHop(
                id: "group",
                stageTitle: AppLocalization.string("Proxy Group"),
                value: groupChain,
                detail: nil,
                symbol: "arrow.triangle.branch",
                tint: .indigo
            ))
        }

        // 5. Exit Node
        let rawExitName = trace.outboundHops.last
            ?? (connection.proxyChain.isEmpty ? "DIRECT" : connection.proxyChain)
        let exitKind = ConnectionOutletClassifier.classify(rawExitName)
        let exitName: String
        let exitSymbol: String
        let exitTint: Color
        switch exitKind {
        case .direct:
            exitName = rawExitName.uppercased() == "DIRECT"
                ? AppLocalization.string("Direct")
                : rawExitName
            exitSymbol = "arrow.forward"
            exitTint = .green
        case .rejected:
            exitName = rawExitName.uppercased().hasPrefix("REJECT")
                ? AppLocalization.string("Reject")
                : rawExitName
            exitSymbol = "hand.raised.fill"
            exitTint = .red
        case .proxied:
            exitName = rawExitName
            exitSymbol = "globe"
            exitTint = .indigo
        }
        let exitDetail = timing.map {
            $0.isMeasuredByEngine
                ? AppLocalization.format("%lld ms", Int64($0.connectMilliseconds))
                : AppLocalization.format("~%lld ms", Int64($0.connectMilliseconds))
        }
        result.append(PipelineHop(
            id: "exit",
            stageTitle: AppLocalization.string("Exit Node"),
            value: exitName,
            detail: exitDetail,
            symbol: exitSymbol,
            tint: exitTint
        ))

        return result
    }

    var body: some View {
        let items = hops
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, hop in
                let isLast = index == items.count - 1
                HStack(alignment: .top, spacing: AetherVisual.s3) {
                    VStack(spacing: 0) {
                        ZStack {
                            Circle()
                                .fill(AetherVisual.tintFill(hop.tint))
                                .frame(width: AetherVisual.iconButtonSize, height: AetherVisual.iconButtonSize)
                            Image(systemName: hop.symbol)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AetherReadableTint(color: hop.tint))
                        }
                        if !isLast {
                            Rectangle()
                                .fill(AetherVisual.cardStroke)
                                .frame(width: AetherVisual.sMicro)
                                .frame(maxHeight: .infinity)
                                .padding(.vertical, AetherVisual.sMicro)
                        }
                    }
                    .frame(width: AetherVisual.iconButtonSize)

                    VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                        Text(hop.stageTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(AetherVisual.secondaryText)
                        Text(verbatim: hop.value)
                            .font(.callout.monospaced())
                            .foregroundStyle(.primary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let detail = hop.detail {
                            Text(verbatim: detail)
                                .font(.caption)
                                .foregroundStyle(AetherVisual.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.bottom, isLast ? .zero : AetherVisual.s3)
                    Spacer(minLength: 0)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, AetherVisual.s1)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-route-pipeline")
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

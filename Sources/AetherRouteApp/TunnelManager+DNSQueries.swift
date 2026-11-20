import AetherRouteKit
import Foundation
import OSLog

/// Page-scoped observable store for recent DNS queries and Fake-IP (`198.18.0.0/15`)
/// reverse lookups. Isolated from `TunnelManager` and `NetworkTelemetryViewModel` so
/// DNS diagnostics updates never trigger unnecessary window-wide SwiftUI invalidations.
@MainActor
final class DNSRecentQueriesViewModel: ObservableObject {
    @Published private(set) var store = DNSRecentQueryStore()
    @Published private(set) var lastCacheClearStatus: String?
    @Published private(set) var isClearingCache = false

    @discardableResult
    func recordLookupReport(
        _ report: DNSLookupReport,
        runtimePolicy: DNSRuntimePolicy?
    ) -> DNSRecentQueryRecord {
        lastCacheClearStatus = nil
        return store.recordLookupReport(report, runtimePolicy: runtimePolicy)
    }

    func ingestConnections(
        _ connections: [ConnectionTelemetry],
        runtimePolicy: DNSRuntimePolicy?
    ) {
        guard !connections.isEmpty else { return }
        var updated = store
        updated.ingestConnections(connections, runtimePolicy: runtimePolicy)
        if updated != store {
            store = updated
        }
    }

    func reverseLookup(fakeIP: String) -> FakeIPReverseLookupMatch? {
        store.reverseLookup(fakeIP: fakeIP)
    }

    func setClearing(_ clearing: Bool) {
        isClearingCache = clearing
    }

    func clearAll(statusMessage: String) {
        store.clearAll()
        lastCacheClearStatus = statusMessage
    }
}

@MainActor
private final class WeakTunnelManagerDNSBox {
    weak var manager: TunnelManager?
    let viewModel: DNSRecentQueriesViewModel

    init(manager: TunnelManager, viewModel: DNSRecentQueriesViewModel) {
        self.manager = manager
        self.viewModel = viewModel
    }
}

@MainActor
private var dnsQueriesViewModelRegistry: [ObjectIdentifier: WeakTunnelManagerDNSBox] = [:]

extension TunnelManager {
    /// Returns the bounded DNS query & Fake-IP reverse lookup view model scoped
    /// to this `TunnelManager` instance without adding stored properties to
    /// `TunnelManager.swift`.
    var dnsQueriesViewModel: DNSRecentQueriesViewModel {
        let key = ObjectIdentifier(self)
        if let existing = dnsQueriesViewModelRegistry[key], existing.manager === self {
            return existing.viewModel
        }
        dnsQueriesViewModelRegistry = dnsQueriesViewModelRegistry.filter { $0.value.manager != nil }
        let viewModel = DNSRecentQueriesViewModel()
        dnsQueriesViewModelRegistry[key] = WeakTunnelManagerDNSBox(manager: self, viewModel: viewModel)
        return viewModel
    }

    /// Pulls active connection telemetry into the bounded 64-entry DNS query store
    /// and Fake-IP reverse lookup index without observing high-frequency telemetry
    /// at the DNS page root.
    func syncRecentDNSQueriesFromTelemetry() {
        let connections = telemetryViewModel.snapshot.connections
        dnsQueriesViewModel.ingestConnections(
            connections,
            runtimePolicy: dnsRuntimePolicy
        )
    }

    /// Records a forward DNS lookup performed from the DNS diagnostics card.
    @discardableResult
    func recordDNSLookupReport(_ report: DNSLookupReport) -> DNSRecentQueryRecord {
        dnsQueriesViewModel.recordLookupReport(
            report,
            runtimePolicy: dnsRuntimePolicy
        )
    }

    /// Performs an O(1) Fake-IP (`198.18.0.0/15`) reverse lookup after refreshing
    /// the in-app index from current connection telemetry.
    func reverseLookupFakeIP(_ fakeIP: String) -> FakeIPReverseLookupMatch? {
        syncRecentDNSQueriesFromTelemetry()
        return dnsQueriesViewModel.reverseLookup(fakeIP: fakeIP)
    }

    /// Clears the in-app DNS query log and Fake-IP reverse lookup table, and when
    /// connected performs a reconnect-free telemetry refresh.
    @discardableResult
    func clearDNSCache() async -> String {
        let viewModel = dnsQueriesViewModel
        viewModel.setClearing(true)
        defer { viewModel.setClearing(false) }

        let status: String
        if state == .connected && !isUIReviewMode {
            viewModel.clearAll(
                statusMessage: AppLocalization.inline(
                    "Cleared DNS query history and Fake-IP reverse cache; refreshed live session without reconnecting.",
                    chinese: "已清空应用内 DNS 查询记录与 Fake-IP 反查缓存，并无感刷新当前会话。"
                )
            )
            await refreshTelemetry()
            status = viewModel.lastCacheClearStatus ?? ""
        } else {
            status = AppLocalization.inline(
                "Cleared DNS query history and Fake-IP reverse cache.",
                chinese: "已清空应用内 DNS 查询记录与 Fake-IP 反查缓存。"
            )
            viewModel.clearAll(statusMessage: status)
        }

        Self.runtimeLogger.info("stage=clearDNSCache connected=\(self.state == .connected, privacy: .public)")
        return status
    }
}

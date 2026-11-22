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
    @Published private(set) var lastCacheClearIsError = false
    @Published private(set) var isClearingCache = false

    @discardableResult
    func recordLookupReport(
        _ report: DNSLookupReport,
        runtimePolicy: DNSRuntimePolicy?
    ) -> DNSRecentQueryRecord {
        lastCacheClearStatus = nil
        lastCacheClearIsError = false
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

    func clearAll(
        statusMessage: String,
        isError: Bool = false,
        suppressingConnections: [ConnectionTelemetry] = []
    ) {
        store.clear(suppressingActiveConnections: suppressingConnections)
        lastCacheClearStatus = statusMessage
        lastCacheClearIsError = isError
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

    /// Clears the in-app DNS query log and Fake-IP reverse lookup table while
    /// suppressing already-active flows from bouncing back into the cleared log.
    /// The extension's internal DNS resolver cache resets on reconnect.
    @discardableResult
    func clearDNSCache() async -> String {
        let viewModel = dnsQueriesViewModel
        viewModel.setClearing(true)
        defer { viewModel.setClearing(false) }

        let preClearConnections = telemetryViewModel.snapshot.connections
        let status: String
        if state == .connected && !isUIReviewMode {
            let successMessage = AppLocalization.string(
                "Cleared local DNS log and Fake-IP lookup history; extension DNS cache resets on reconnect."
            )
            viewModel.clearAll(
                statusMessage: successMessage,
                isError: false,
                suppressingConnections: preClearConnections
            )
            do {
                let client = ProxySelectionProviderClient { [weak self] data in
                    guard let self else {
                        throw TunnelManagerError.providerSessionUnavailable
                    }
                    return try await self.sendProviderMessage(data)
                }
                let requestedLimit = effectiveTelemetryConnectionLimit
                let wireLimit = min(
                    requestedLimit,
                    UInt16(clamping: NetworkTelemetryCodec.maximumConnections)
                )
                let rawSnapshot = try await client.telemetry(
                    maximumConnections: wireLimit
                )
                let now = Date()
                let resolvedSnapshot = telemetryRateSampler.resolve(
                    snapshot: rawSnapshot,
                    at: now
                )
                viewModel.clearAll(
                    statusMessage: successMessage,
                    isError: false,
                    suppressingConnections: preClearConnections + resolvedSnapshot.connections
                )
                publishTelemetry(
                    resolvedSnapshot,
                    requestedConnectionLimit: requestedLimit,
                    at: now
                )
                status = successMessage
            } catch {
                let errorMessage = AppLocalization.string(
                    "Cleared local DNS log and Fake-IP lookup history, but could not refresh the live session."
                )
                viewModel.clearAll(
                    statusMessage: errorMessage,
                    isError: true,
                    suppressingConnections: preClearConnections
                )
                status = errorMessage
                Self.runtimeLogger.error("stage=clearDNSCache ipcRefreshFailed error=\(String(reflecting: error), privacy: .public)")
            }
        } else {
            status = AppLocalization.string("Cleared local DNS log and Fake-IP lookup history.")
            viewModel.clearAll(
                statusMessage: status,
                isError: false,
                suppressingConnections: preClearConnections
            )
        }

        Self.runtimeLogger.info("stage=clearDNSCache connected=\(self.state == .connected, privacy: .public)")
        return status
    }
}

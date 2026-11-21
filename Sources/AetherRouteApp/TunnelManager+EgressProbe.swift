import AetherRouteKit
import Foundation
import ObjectiveC

@MainActor
final class EgressProbeStore: ObservableObject {
    @Published private(set) var isProbing = false
    @Published private(set) var lastReport: EgressProbeReport?
    @Published private(set) var cache = EgressProbeCache(capacity: EgressProbeCache.defaultCapacity)

    var cachedReportsByNode: [String: EgressProbeReport] {
        cache.allReports
    }

    var aiAvailableNodeNames: Set<String> {
        cache.aiAvailableNodeNames
    }

    func report(forNode nodeName: String) -> EgressProbeReport? {
        cache.report(forNode: nodeName)
    }

    func beginProbe() {
        isProbing = true
    }

    func completeProbe(report: EgressProbeReport, nodeName: String?) {
        lastReport = report
        if let nodeName, !nodeName.isEmpty {
            cache.store(report, forNode: nodeName)
        }
        isProbing = false
    }
}

private enum EgressProbeStoreAssociation {
    nonisolated(unsafe) static var key: UInt8 = 0
}

extension TunnelManager {
    /// Per-instance observable store for on-demand egress probe state and
    /// bounded per-node cache (max 64 entries). Kept as an associated object so
    /// high-frequency egress updates only redraw views that observe it.
    var egressProbeStore: EgressProbeStore {
        if let existing = objc_getAssociatedObject(self, &EgressProbeStoreAssociation.key) as? EgressProbeStore {
            return existing
        }
        let store = EgressProbeStore()
        objc_setAssociatedObject(
            self,
            &EgressProbeStoreAssociation.key,
            store,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )
        return store
    }

    /// Resolves the currently active leaf exit node name, or `nil` in direct mode.
    var currentEgressProbeNodeName: String? {
        let mode = isConnected ? (sessionRoutingMode ?? routingMode) : routingMode
        switch mode {
        case .direct:
            return nil
        case .global:
            guard let summary = activeProfileSummary else { return nil }
            let selected = proxySelections["GLOBAL"]?.selectedMember
                ?? TunnelManager.resolvedGlobalTargetMember(in: summary)
            return selected.map { resolvedLeafNode(from: $0) }
        case .rule:
            guard let group = resolvedPrimaryRoutingGroup(),
                  let selected = proxySelections[group.name]?.selectedMember else {
                return nil
            }
            return resolvedLeafNode(from: selected)
        }
    }

    /// Returns the active local HTTP proxy configuration when enabled so probe
    /// requests route through the active proxy listener; otherwise `nil` so
    /// TUN / Transparent Proxy handles routing transparently.
    var currentEgressProxyConfiguration: EgressProxyConfiguration? {
        guard isConnected,
              localProxySettings.isEnabled || localProxySettings.allowLAN || localProxySettings.setAsSystemProxy,
              localProxySettings.httpPort > 0 else {
            return nil
        }
        return EgressProxyConfiguration(httpHost: "127.0.0.1", httpPort: localProxySettings.httpPort)
    }

    /// Runs an explicit, user-initiated egress IP & service availability probe.
    /// Never triggered automatically in the background.
    func runEgressAvailabilityProbe() async {
        guard isConnected else { return }
        let store = egressProbeStore
        guard !store.isProbing else { return }

        let nodeName = currentEgressProbeNodeName
        let proxyConfig = currentEgressProxyConfiguration
        store.beginProbe()

        let report = await Task.detached(priority: .userInitiated) {
            let probe = EgressAvailabilityProbe(proxy: proxyConfig)
            return await probe.run(nodeName: nodeName)
        }.value

        store.completeProbe(report: report, nodeName: nodeName)
    }

    func latestEgressReportForCurrentNode() -> EgressProbeReport? {
        if let node = currentEgressProbeNodeName {
            return egressProbeStore.report(forNode: node)
        }
        guard let last = egressProbeStore.lastReport, last.nodeName == nil else {
            return nil
        }
        return last
    }
}

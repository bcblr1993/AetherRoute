import AetherRouteKit
import Foundation
import OSLog

extension TunnelManager {
    static let closesConnectionsOnProxySwitchPreferenceKey =
        "closesConnectionsOnProxySwitch"
    static let testsLatencyWhenProxiesOpenPreferenceKey =
        "testsLatencyWhenProxiesOpen"

    func setClosesConnectionsOnProxySwitch(_ enabled: Bool) {
        closesConnectionsOnProxySwitch = enabled
        userDefaults.set(enabled, forKey: Self.closesConnectionsOnProxySwitchPreferenceKey)
    }

    func setTestsLatencyWhenProxiesOpen(_ enabled: Bool) {
        testsLatencyWhenProxiesOpen = enabled
        userDefaults.set(enabled, forKey: Self.testsLatencyWhenProxiesOpenPreferenceKey)
    }

    /// Closes the active connections the request selects and refreshes the
    /// list. Returns whether the extension confirmed the request; the apps
    /// that owned the connections reconnect on their own.
    @discardableResult
    func closeConnections(_ request: ConnectionCloseRequest) async -> Bool {
        guard state == .connected else { return false }
        if isUIReviewMode { return true }
        let connectionID = providerConnectionID
        let client = ProxySelectionProviderClient { [weak self] data in
            guard let self else {
                throw TunnelManagerError.providerSessionUnavailable
            }
            return try await self.sendProviderMessage(data, for: connectionID)
        }
        do {
            let closed = try await client.closeConnections(request)
            Self.runtimeLogger.info(
                "stage=closeConnections closed=\(closed, privacy: .public)"
            )
            await refreshTelemetry()
            return true
        } catch {
            Self.runtimeLogger.error(
                "stage=closeConnections failed error=\(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// After a group's node changed, drops what still runs through the group
    /// so new traffic and reconnecting apps use the new node. Best effort: a
    /// failure leaves those connections on the old node until they end.
    func closeConnectionsAfterProxySwitch(group groupName: String) async {
        guard closesConnectionsOnProxySwitch else { return }
        await closeConnections(.proxyChainMember(groupName))
    }

    /// Tests a group's latency because the Proxies page showed it, if the
    /// person turned this on, the tunnel is up and the group was not tested
    /// this way in the last minute. Leaving the page cancels the test with
    /// the page's task.
    func testLatencyOnOpenIfDue(group groupName: String, now: Date = .now) async {
        guard testsLatencyWhenProxiesOpen,
              state == .connected,
              !proxyLatencyRequests.contains(groupName)
        else { return }
        if let last = latencyOnOpenTestedAt[groupName],
           now.timeIntervalSince(last) < Self.latencyOnOpenInterval {
            return
        }
        latencyOnOpenTestedAt[groupName] = now
        await testProxyLatency(group: groupName)
    }

    static let latencyOnOpenInterval: TimeInterval = 60
}

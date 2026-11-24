import AetherRouteKit
import Foundation

final class ExternalControllerTunnelAdapter: ExternalControllerDelegate, @unchecked Sendable {
    private weak var tunnel: TunnelManager?
    private let connectionLock = NSLock()
    private var connectionsByID: [String: ConnectionTelemetry] = [:]

    init(tunnel: TunnelManager) {
        self.tunnel = tunnel
    }

    func controllerVersion() async -> ExternalControllerVersionPayload {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "3.2.0"
        return ExternalControllerVersionPayload(version: version, meta: true, premium: false)
    }

    func controllerConfigs() async -> ExternalControllerConfigsPayload {
        await MainActor.run {
            guard let tunnel else {
                return ExternalControllerConfigsPayload(
                    port: 0,
                    socksPort: 0,
                    mixedPort: 0,
                    allowLan: false,
                    mode: "rule",
                    logLevel: "info",
                    ipv6: false,
                    tunEnabled: false
                )
            }
            let local = tunnel.localProxySettings
            let activeLocalPort = (local.isEnabled || local.allowLAN || local.setAsSystemProxy) ? local.httpPort : 0
            let activeSocksPort = (local.isEnabled || local.allowLAN || local.setAsSystemProxy) ? local.socksPort : 0
            let logLevel = switch DiagnosticLogCenter.current.level {
            case .off: "silent"
            case .standard: "info"
            case .verbose: "debug"
            }
            let ipv6 = tunnel.activeProfileSummary?.allowsIPv6 ?? false
            let tunEnabled = tunnel.state == .connected && tunnel.networkEngineMode == .tun
            return ExternalControllerConfigsPayload(
                port: activeLocalPort,
                socksPort: activeSocksPort,
                mixedPort: activeLocalPort,
                allowLan: local.allowLAN,
                mode: tunnel.effectiveRoutingMode.rawValue,
                logLevel: logLevel,
                ipv6: ipv6,
                tunEnabled: tunEnabled
            )
        }
    }

    func patchControllerConfigs(_ patch: ExternalControllerConfigPatch) async throws {
        if let rawMode = patch.mode {
            guard let mode = RoutingMode(rawValue: rawMode.lowercased()) else {
                throw ExternalControllerRouteError.badRequest("Unsupported routing mode: \(rawMode)")
            }
            let target = await MainActor.run { tunnel }
            if let target {
                await target.setRoutingMode(mode)
            }
        }
    }

    func controllerProxies() async -> [String: ExternalControllerProxyInfo] {
        await MainActor.run {
            guard let tunnel, let summary = tunnel.activeProfileSummary else {
                return [
                    "DIRECT": ExternalControllerProxyInfo(name: "DIRECT", type: "Direct", udp: true),
                    "REJECT": ExternalControllerProxyInfo(name: "REJECT", type: "Reject", udp: true),
                ]
            }

            let nowTimestamp = Date.now.ISO8601Format()
            var delayByMember: [String: UInt32] = [:]
            for latencyState in tunnel.proxyLatencies.values {
                for result in latencyState.results {
                    if let delay = result.delayMilliseconds, delayByMember[result.member] == nil {
                        delayByMember[result.member] = delay
                    }
                }
            }

            var result: [String: ExternalControllerProxyInfo] = [
                "DIRECT": ExternalControllerProxyInfo(name: "DIRECT", type: "Direct", udp: true),
                "REJECT": ExternalControllerProxyInfo(name: "REJECT", type: "Reject", udp: true),
            ]

            for proxy in summary.proxies {
                let history: [ExternalControllerDelayHistory] = if let ms = delayByMember[proxy.name] {
                    [ExternalControllerDelayHistory(time: nowTimestamp, delay: ms)]
                } else {
                    []
                }
                result[proxy.name] = ExternalControllerProxyInfo(
                    name: proxy.name,
                    type: Self.clashProxyType(for: proxy.protocolName),
                    now: nil,
                    all: nil,
                    history: history,
                    udp: true
                )
            }

            var groups = summary.proxyGroups
            if let globalGroup = tunnel.globalProxyGroup,
               !groups.contains(where: { $0.name == globalGroup.name }) {
                groups.append(globalGroup)
            }

            for group in groups {
                let members = tunnel.proxySelections[group.name]?.members ?? group.members
                let selected = tunnel.proxySelections[group.name]?.selectedMember
                    ?? tunnel.automaticGroupLeaves[group.name]
                    ?? members.first
                let history: [ExternalControllerDelayHistory] = if let selected,
                                                                  let ms = delayByMember[selected] {
                    [ExternalControllerDelayHistory(time: nowTimestamp, delay: ms)]
                } else {
                    []
                }
                result[group.name] = ExternalControllerProxyInfo(
                    name: group.name,
                    type: Self.clashGroupType(for: group.strategy),
                    now: selected,
                    all: members,
                    history: history,
                    udp: true
                )
            }

            return result
        }
    }

    func selectProxy(group: String, name: String) async throws {
        let tunnelRef: TunnelManager? = await MainActor.run { tunnel }
        guard let tunnel = tunnelRef else {
            throw ExternalControllerRouteError.internalError("Tunnel unavailable")
        }

        let isValidTarget: Bool = await MainActor.run {
            let groupMatches = (tunnel.activeProfileSummary?.proxyGroups ?? [])
                + (tunnel.globalProxyGroup.map { [$0] } ?? [])
            guard let targetGroup = groupMatches.first(where: { $0.name == group }) else {
                return false
            }
            let members = tunnel.proxySelections[group]?.members ?? targetGroup.members
            return members.contains(name)
        }
        guard isValidTarget else {
            throw ExternalControllerRouteError.notFound("Proxy group or member not found")
        }
        await tunnel.selectProxy(group: group, member: name)
    }

    func measureProxyDelay(name: String, url: String, timeoutMs: Int) async throws -> UInt32 {
        _ = url
        _ = timeoutMs
        let tunnelRef: TunnelManager? = await MainActor.run { tunnel }
        guard let tunnel = tunnelRef else {
            throw ExternalControllerRouteError.internalError("Tunnel unavailable")
        }

        let target: (group: String, member: String)? = await MainActor.run {
            let snapshots = tunnel.latencyGroupsSnapshot()
            if let containing = snapshots.first(where: { $0.members.contains(name) }) {
                return (containing.name, name)
            }
            if let group = snapshots.first(where: { $0.name == name }) {
                let selected = tunnel.proxySelections[group.name]?.selectedMember
                    ?? tunnel.automaticGroupLeaves[group.name]
                    ?? group.members.first
                if let selected {
                    return (group.name, selected)
                }
            }
            return nil
        }

        guard let target else {
            throw ExternalControllerRouteError.notFound("Proxy not found: \(name)")
        }

        await tunnel.testSingleProxyLatency(group: target.group, member: target.member)

        let measured: UInt32? = await MainActor.run {
            tunnel.proxyLatencies[target.group]?.resultsByMember[target.member]?.delayMilliseconds
        }
        guard let measured else {
            throw ExternalControllerRouteError.gatewayTimeout("Delay measurement timed out")
        }
        return measured
    }

    func controllerRules() async -> [ExternalControllerRuleInfo] {
        await MainActor.run {
            guard let summary = tunnel?.activeProfileSummary else { return [] }
            return summary.allRules.map { rule in
                ExternalControllerRuleInfo(
                    type: rule.kind,
                    payload: rule.criteria ?? "",
                    proxy: rule.target
                )
            }
        }
    }

    func controllerConnectionsSnapshot() async -> ExternalControllerConnectionsPayload {
        let snapshot: NetworkTelemetrySnapshot? = await MainActor.run {
            tunnel?.telemetryViewModel.snapshot
        }
        guard let snapshot else {
            return ExternalControllerConnectionsPayload(
                downloadTotal: 0,
                uploadTotal: 0,
                connections: [],
                memory: 0
            )
        }

        var indexed: [String: ConnectionTelemetry] = [:]
        indexed.reserveCapacity(snapshot.connections.count)
        let mapped = snapshot.connections.enumerated().map { idx, conn -> ExternalControllerConnectionInfo in
            let id = Self.connectionIdentifier(for: conn, disambiguator: idx)
            indexed[id] = conn
            let chains = conn.proxyChain
                .components(separatedBy: " → ")
                .filter { !$0.isEmpty }
            let startDate = Date(timeIntervalSince1970: Double(conn.startedAtUnixMilliseconds) / 1000.0)
            let isIP = conn.destination.contains(":") || conn.destination.split(separator: ".").allSatisfy { Int($0) != nil }
            return ExternalControllerConnectionInfo(
                id: id,
                metadata: ExternalControllerConnectionMetadata(
                    network: conn.transport == .udp ? "udp" : "tcp",
                    type: conn.transport == .udp ? "UDP" : "TCP",
                    sourceIP: "127.0.0.1",
                    destinationIP: isIP ? conn.destination : "",
                    sourcePort: "0",
                    destinationPort: String(conn.destinationPort),
                    host: isIP ? "" : conn.destination,
                    dnsMode: "normal",
                    processPath: conn.sourceAppPath.isEmpty ? conn.sourceAppIdentifier : conn.sourceAppPath
                ),
                upload: conn.uploadTotal,
                download: conn.downloadTotal,
                start: startDate.ISO8601Format(),
                chains: chains.isEmpty ? [conn.proxyChain] : chains,
                rule: conn.rule,
                rulePayload: conn.rulePayload
            )
        }

        connectionLock.withLock {
            connectionsByID = indexed
        }

        return ExternalControllerConnectionsPayload(
            downloadTotal: snapshot.downloadTotal,
            uploadTotal: snapshot.uploadTotal,
            connections: mapped,
            memory: snapshot.memoryBytes
        )
    }

    func closeConnection(id: String) async throws {
        let row = connectionLock.withLock { connectionsByID[id] }
        let tunnelRef: TunnelManager? = await MainActor.run { tunnel }
        guard let tunnel = tunnelRef else { return }
        if let row {
            _ = await tunnel.closeConnections(ConnectionCloseRequest(row: row))
        } else {
            throw ExternalControllerRouteError.notFound("Connection not found")
        }
    }

    func closeAllConnections() async throws {
        let tunnelRef: TunnelManager? = await MainActor.run { tunnel }
        guard let tunnel = tunnelRef else { return }
        _ = await tunnel.closeConnections(.all)
    }

    func controllerTrafficSample() async -> ExternalControllerTrafficSample {
        await MainActor.run {
            guard let snap = tunnel?.telemetryViewModel.snapshot else {
                return ExternalControllerTrafficSample(up: 0, down: 0)
            }
            return ExternalControllerTrafficSample(
                up: snap.uploadBytesPerSecond,
                down: snap.downloadBytesPerSecond
            )
        }
    }

    func controllerMemorySample() async -> ExternalControllerMemorySample {
        await MainActor.run {
            guard let snap = tunnel?.telemetryViewModel.snapshot else {
                return ExternalControllerMemorySample(inuse: 0, oslimit: 0)
            }
            return ExternalControllerMemorySample(inuse: snap.memoryBytes, oslimit: 0)
        }
    }

    func controllerRecentLogs() async -> [ExternalControllerLogSample] {
        let raw = DiagnosticLogCenter.current.recentLog(maximumBytes: 16_384)
        guard !raw.isEmpty else { return [] }
        return raw
            .split(separator: "\n", omittingEmptySubsequences: true)
            .suffix(64)
            .map { line in
                let text = String(line)
                let lowered = text.lowercased()
                let level: String = if lowered.contains("error") || lowered.contains("fail") {
                    "error"
                } else if lowered.contains("warn") {
                    "warning"
                } else {
                    "info"
                }
                return ExternalControllerLogSample(type: level, payload: text)
            }
    }

    private static func connectionIdentifier(for conn: ConnectionTelemetry, disambiguator: Int) -> String {
        let raw = "\(conn.transport.rawValue)-\(conn.destination)-\(conn.destinationPort)-\(conn.startedAtUnixMilliseconds)-\(disambiguator)"
        return Data(raw.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func clashGroupType(for strategy: String) -> String {
        switch strategy.lowercased() {
        case "select", "selector": return "Selector"
        case "url-test", "urltest": return "URLTest"
        case "fallback": return "Fallback"
        case "load-balance", "loadbalance": return "LoadBalance"
        default: return strategy.capitalized
        }
    }

    private static func clashProxyType(for protocolName: String) -> String {
        switch protocolName.lowercased() {
        case "ss", "shadowsocks": return "Shadowsocks"
        case "ssr": return "ShadowsocksR"
        case "vmess": return "Vmess"
        case "vless": return "Vless"
        case "trojan": return "Trojan"
        case "hysteria2", "hy2": return "Hysteria2"
        case "tuic": return "Tuic"
        case "wireguard", "wg": return "WireGuard"
        case "ssh": return "SSH"
        case "socks5", "socks": return "Socks5"
        case "http": return "Http"
        default: return protocolName.capitalized
        }
    }
}

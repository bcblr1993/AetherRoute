import Darwin
import Foundation

/// Structured diagnostic check categories benchmarked against Surge 5 (`Diagnostics`)
/// and Clash Verge Rev (`NetCheck`).
public enum DiagnosticCheckKind: String, CaseIterable, Sendable, Equatable, Identifiable {
    case localProxyListener = "local_proxy_listener"
    case loopbackDirectBypass = "loopback_direct_bypass"
    case dnsResolutionHealth = "dns_resolution_health"
    case domesticDirectConnectivity = "domestic_direct_connectivity"
    case proxyOutboundConnectivity = "proxy_outbound_connectivity"
    case subscriptionAndRuleProviderHealth = "subscription_and_rule_provider_health"

    public var id: String { rawValue }
}

public enum DiagnosticCheckStatus: String, Sendable, Equatable {
    case passed = "passed"
    case warning = "warning"
    case failed = "failed"
    case skipped = "skipped"
}

public struct DiagnosticCheckResult: Identifiable, Sendable, Equatable {
    public let kind: DiagnosticCheckKind
    public let status: DiagnosticCheckStatus
    public let latencyMilliseconds: Int?
    public let detail: String

    public var id: String { kind.rawValue }

    public init(
        kind: DiagnosticCheckKind,
        status: DiagnosticCheckStatus,
        latencyMilliseconds: Int? = nil,
        detail: String
    ) {
        self.kind = kind
        self.status = status
        self.latencyMilliseconds = latencyMilliseconds
        self.detail = detail
    }
}

public struct NetworkDiagnosticInputSnapshot: Sendable, Equatable {
    public let isConnected: Bool
    public let engineMode: String
    public let routingMode: String
    public let localProxyEnabled: Bool
    public let localProxyPort: Int
    public let localProxyListening: Bool
    public let loopbackBypassIntact: Bool
    public let dnsEnhancedMode: String
    public let dnsResolvedCount: Int
    public let dnsLatencyMilliseconds: Int?
    public let domesticLatencyMilliseconds: Int?
    public let proxyLatencyMilliseconds: Int?
    public let activeProfileNodeCount: Int
    public let ruleProviderCount: Int
    public let staleRuleProviderCount: Int

    public init(
        isConnected: Bool,
        engineMode: String,
        routingMode: String,
        localProxyEnabled: Bool,
        localProxyPort: Int,
        localProxyListening: Bool,
        loopbackBypassIntact: Bool,
        dnsEnhancedMode: String,
        dnsResolvedCount: Int,
        dnsLatencyMilliseconds: Int?,
        domesticLatencyMilliseconds: Int?,
        proxyLatencyMilliseconds: Int?,
        activeProfileNodeCount: Int,
        ruleProviderCount: Int,
        staleRuleProviderCount: Int
    ) {
        self.isConnected = isConnected
        self.engineMode = engineMode
        self.routingMode = routingMode
        self.localProxyEnabled = localProxyEnabled
        self.localProxyPort = localProxyPort
        self.localProxyListening = localProxyListening
        self.loopbackBypassIntact = loopbackBypassIntact
        self.dnsEnhancedMode = dnsEnhancedMode
        self.dnsResolvedCount = dnsResolvedCount
        self.dnsLatencyMilliseconds = dnsLatencyMilliseconds
        self.domesticLatencyMilliseconds = domesticLatencyMilliseconds
        self.proxyLatencyMilliseconds = proxyLatencyMilliseconds
        self.activeProfileNodeCount = activeProfileNodeCount
        self.ruleProviderCount = ruleProviderCount
        self.staleRuleProviderCount = staleRuleProviderCount
    }
}

public struct NetworkDiagnosticReport: Sendable, Equatable {
    public let generatedAtUnixSeconds: Int64
    public let engineMode: String
    public let routingMode: String
    public let checks: [DiagnosticCheckResult]

    public init(
        generatedAtUnixSeconds: Int64,
        engineMode: String,
        routingMode: String,
        checks: [DiagnosticCheckResult]
    ) {
        self.generatedAtUnixSeconds = generatedAtUnixSeconds
        self.engineMode = engineMode
        self.routingMode = routingMode
        self.checks = checks
    }

    public var passedCount: Int {
        checks.filter { $0.status == .passed }.count
    }

    public var warningCount: Int {
        checks.filter { $0.status == .warning }.count
    }

    public var failedCount: Int {
        checks.filter { $0.status == .failed }.count
    }

    public var overallStatus: DiagnosticCheckStatus {
        if failedCount > 0 { return .failed }
        if warningCount > 0 { return .warning }
        if passedCount > 0 { return .passed }
        return .skipped
    }

    /// Generates a zero-secret Markdown diagnostic report suitable for bug reports or support.
    public func formattedMarkdownReport() -> String {
        var lines: [String] = [
            "# AetherRoute Network Diagnostic Report",
            "- Timestamp (UTC): \(generatedAtUnixSeconds)",
            "- Engine: \(engineMode)",
            "- Routing Mode: \(routingMode)",
            "- Overall Status: \(overallStatus.rawValue.uppercased()) (passed=\(passedCount), warning=\(warningCount), failed=\(failedCount))",
            "",
            "## Checks",
        ]
        for check in checks {
            let latencySuffix = check.latencyMilliseconds.map { " (\($0) ms)" } ?? ""
            lines.append("- \(check.kind.rawValue): \(check.status.rawValue.uppercased())\(latencySuffix) — \(check.detail)")
        }
        return lines.joined(separator: "\n")
    }
}

public enum NetworkDiagnosticDoctor {
    public static func evaluate(
        snapshot: NetworkDiagnosticInputSnapshot,
        generatedAtUnixSeconds: Int64 = Int64(Date().timeIntervalSince1970)
    ) -> NetworkDiagnosticReport {
        var results: [DiagnosticCheckResult] = []
        results.reserveCapacity(6)

        // 1. Local proxy listener check
        if !snapshot.isConnected || !snapshot.localProxyEnabled {
            results.append(
                DiagnosticCheckResult(
                    kind: .localProxyListener,
                    status: .skipped,
                    detail: "127.0.0.1:\(snapshot.localProxyPort) inactive"
                )
            )
        } else if snapshot.localProxyListening {
            results.append(
                DiagnosticCheckResult(
                    kind: .localProxyListener,
                    status: .passed,
                    detail: "127.0.0.1:\(snapshot.localProxyPort) listening"
                )
            )
        } else {
            results.append(
                DiagnosticCheckResult(
                    kind: .localProxyListener,
                    status: .failed,
                    detail: "127.0.0.1:\(snapshot.localProxyPort) unreachable"
                )
            )
        }

        // 2. 5-Layer Loopback & RFC 6761 localhost direct bypass check
        if snapshot.loopbackBypassIntact {
            results.append(
                DiagnosticCheckResult(
                    kind: .loopbackDirectBypass,
                    status: .passed,
                    detail: "127.0.0.0/8, ::1, localhost -> DIRECT"
                )
            )
        } else {
            results.append(
                DiagnosticCheckResult(
                    kind: .loopbackDirectBypass,
                    status: .failed,
                    detail: "Loopback bypass rules missing"
                )
            )
        }

        // 3. DNS resolution & Fake-IP health
        if snapshot.dnsResolvedCount > 0 {
            results.append(
                DiagnosticCheckResult(
                    kind: .dnsResolutionHealth,
                    status: .passed,
                    latencyMilliseconds: snapshot.dnsLatencyMilliseconds,
                    detail: "mode=\(snapshot.dnsEnhancedMode), resolved=\(snapshot.dnsResolvedCount)"
                )
            )
        } else {
            results.append(
                DiagnosticCheckResult(
                    kind: .dnsResolutionHealth,
                    status: .failed,
                    latencyMilliseconds: snapshot.dnsLatencyMilliseconds,
                    detail: "mode=\(snapshot.dnsEnhancedMode), system resolution failed"
                )
            )
        }

        // 4. Domestic direct connectivity check
        if let domesticMs = snapshot.domesticLatencyMilliseconds {
            results.append(
                DiagnosticCheckResult(
                    kind: .domesticDirectConnectivity,
                    status: domesticMs <= 1_500 ? .passed : .warning,
                    latencyMilliseconds: domesticMs,
                    detail: "Apple / domestic direct probe reachable"
                )
            )
        } else {
            results.append(
                DiagnosticCheckResult(
                    kind: .domesticDirectConnectivity,
                    status: .warning,
                    detail: "Direct probe timed out"
                )
            )
        }

        // 5. Proxy outbound connectivity check
        if !snapshot.isConnected || snapshot.routingMode.lowercased() == "direct" {
            results.append(
                DiagnosticCheckResult(
                    kind: .proxyOutboundConnectivity,
                    status: .skipped,
                    detail: snapshot.isConnected ? "Direct mode active" : "Tunnel disconnected"
                )
            )
        } else if let proxyMs = snapshot.proxyLatencyMilliseconds {
            results.append(
                DiagnosticCheckResult(
                    kind: .proxyOutboundConnectivity,
                    status: proxyMs <= 2_500 ? .passed : .warning,
                    latencyMilliseconds: proxyMs,
                    detail: "Proxy outbound reachable"
                )
            )
        } else {
            results.append(
                DiagnosticCheckResult(
                    kind: .proxyOutboundConnectivity,
                    status: .failed,
                    detail: "Proxy outbound probe timed out"
                )
            )
        }

        // 6. Active subscription & rule provider health
        if snapshot.activeProfileNodeCount <= 0 {
            results.append(
                DiagnosticCheckResult(
                    kind: .subscriptionAndRuleProviderHealth,
                    status: .failed,
                    detail: "No proxy nodes in active profile"
                )
            )
        } else if snapshot.staleRuleProviderCount > 0 {
            results.append(
                DiagnosticCheckResult(
                    kind: .subscriptionAndRuleProviderHealth,
                    status: .warning,
                    detail: "nodes=\(snapshot.activeProfileNodeCount), providers=\(snapshot.ruleProviderCount) (stale=\(snapshot.staleRuleProviderCount))"
                )
            )
        } else {
            results.append(
                DiagnosticCheckResult(
                    kind: .subscriptionAndRuleProviderHealth,
                    status: .passed,
                    detail: "nodes=\(snapshot.activeProfileNodeCount), providers=\(snapshot.ruleProviderCount)"
                )
            )
        }

        return NetworkDiagnosticReport(
            generatedAtUnixSeconds: generatedAtUnixSeconds,
            engineMode: snapshot.engineMode,
            routingMode: snapshot.routingMode,
            checks: results
        )
    }

    /// Non-blocking POSIX TCP loopback probe for `127.0.0.1:<port>`.
    public static func probeLoopbackTCPPort(
        _ port: Int,
        timeoutMilliseconds: Int = 350
    ) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        let currentFlags = Darwin.fcntl(fd, F_GETFL, 0)
        if currentFlags >= 0 {
            _ = Darwin.fcntl(fd, F_SETFL, currentFlags | O_NONBLOCK)
        }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connectResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connectResult == 0 {
            return true
        }
        guard errno == EINPROGRESS else {
            return false
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let pollReady = Darwin.poll(&pfd, 1, Int32(max(timeoutMilliseconds, 50)))
        guard pollReady > 0, (pfd.revents & Int16(POLLOUT)) != 0 else {
            return false
        }

        var socketError: Int32 = 0
        var errorLen = socklen_t(MemoryLayout<Int32>.size)
        guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLen) == 0 else {
            return false
        }
        return socketError == 0
    }
}

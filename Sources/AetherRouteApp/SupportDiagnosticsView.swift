import AetherRouteKit
import Darwin
import Foundation
import Network
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Diagnostic Data Models

public enum DiagnosticStageStatus: String, Sendable, Equatable {
    case pending
    case running
    case passed
    case warning
    case failed
}

public struct TunnelDiagnosticResult: Sendable, Equatable {
    public let isConnected: Bool
    public let routingMode: RoutingMode
    public let activeNodeName: String?
    public let protocolName: String?
    public let status: DiagnosticStageStatus
    public let detail: String
}

public struct DNSDiagnosticResult: Sendable, Equatable {
    public let domain: String
    public let resolvedIP: String?
    public let isFakeIP: Bool
    public let latencyMs: Double
    public let status: DiagnosticStageStatus
    public let detail: String
}

public struct DomesticDiagnosticResult: Sendable, Equatable {
    public let targetURL: String
    public let httpCode: Int?
    public let latencyMs: Double
    public let status: DiagnosticStageStatus
    public let detail: String
}

public struct ProxyDiagnosticResult: Sendable, Equatable {
    public let targetURL: String
    public let httpCode: Int?
    public let connectMs: Double?
    public let tlsMs: Double?
    public let totalMs: Double
    public let status: DiagnosticStageStatus
    public let detail: String
}

public enum DiagnosticVerdict: String, Sendable, Equatable {
    case allHealthy
    case proxyDegraded
    case proxyBlocked
    case offlineOrCaptive
    case tunnelDisconnected
    case dnsFailed
    case unknown

    public var titleKey: String {
        switch self {
        case .allHealthy:
            return "All Systems Operational"
        case .proxyDegraded:
            return "Proxy Latency Degraded"
        case .proxyBlocked:
            return "Proxy Connection Blocked"
        case .offlineOrCaptive:
            return "Local Network Offline / Captive Portal"
        case .tunnelDisconnected:
            return "Tunnel Disconnected"
        case .dnsFailed:
            return "DNS Resolution Failed"
        case .unknown:
            return "Diagnosis Inconclusive"
        }
    }

    public var recommendationKey: String {
        switch self {
        case .allHealthy:
            return "All network layers, Fake-IP resolution, domestic and outbound proxy tunnels are working properly."
        case .proxyDegraded:
            return "Outbound proxy handshake latency is high. Consider switching to a lower latency node in Proxies."
        case .proxyBlocked:
            return "Direct domestic network is fine, but the outbound proxy node failed to respond. The node port may be blocked. Please switch to an alternate proxy node."
        case .offlineOrCaptive:
            return "Both direct and proxy targets failed. Please check your physical Wi-Fi/Ethernet or complete the public Wi-Fi login portal."
        case .tunnelDisconnected:
            return "AetherRoute tunnel is currently disconnected. Please turn on connection to enable protected routing."
        case .dnsFailed:
            return "DNS queries timed out or failed. Please check your DNS settings or toggle connection to refresh resolver."
        case .unknown:
            return "Diagnostics finished with mixed results. Re-running diagnostics is recommended."
        }
    }
}

public struct ConnectivityDiagnosticReport: Sendable, Equatable {
    public let timestamp: Date
    public let tunnel: TunnelDiagnosticResult
    public let dns: DNSDiagnosticResult
    public let domestic: DomesticDiagnosticResult
    public let proxy: ProxyDiagnosticResult
    public let verdict: DiagnosticVerdict
    public let totalDurationMs: Double
}

// MARK: - Diagnostic Engine

@MainActor
public final class ConnectivityDiagnosticsEngine: ObservableObject {
    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var currentStage: Int = 0 // 0: idle, 1: tunnel, 2: dns, 3: domestic, 4: proxy, 5: completed
    @Published public private(set) var report: ConnectivityDiagnosticReport?

    private final class MetricsDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var collectedMetrics: URLSessionTaskMetrics?

        var metrics: URLSessionTaskMetrics? {
            lock.withLock { collectedMetrics }
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didFinishCollecting metrics: URLSessionTaskMetrics
        ) {
            lock.withLock {
                self.collectedMetrics = metrics
            }
        }
    }

    public init() {}

    public func runDiagnostics(
        isConnected: Bool,
        isConnecting: Bool,
        routingMode: RoutingMode,
        activeNodeName: String?,
        protocolName: String?
    ) async {
        guard !isRunning else { return }
        isRunning = true
        currentStage = 1
        let startTime = CFAbsoluteTimeGetCurrent()

        let tunnelResult = inspectTunnel(
            isConnected: isConnected,
            isConnecting: isConnecting,
            routingMode: routingMode,
            activeNodeName: activeNodeName,
            protocolName: protocolName
        )
        currentStage = 2

        let dnsResult = await inspectDNS(domain: "www.google.com")
        currentStage = 3

        let domesticResult = await inspectDomestic(targetURL: "https://connect.rom.miui.com/generate_204")
        currentStage = 4

        let proxyResult = await inspectProxy(targetURL: "https://www.google.com/generate_204")
        currentStage = 5

        let totalDuration = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0

        let verdict = evaluateVerdict(
            tunnel: tunnelResult,
            dns: dnsResult,
            domestic: domesticResult,
            proxy: proxyResult
        )

        let finalReport = ConnectivityDiagnosticReport(
            timestamp: Date(),
            tunnel: tunnelResult,
            dns: dnsResult,
            domestic: domesticResult,
            proxy: proxyResult,
            verdict: verdict,
            totalDurationMs: totalDuration
        )

        self.report = finalReport
        self.isRunning = false
    }

    private func inspectTunnel(
        isConnected: Bool,
        isConnecting: Bool,
        routingMode: RoutingMode,
        activeNodeName: String?,
        protocolName: String?
    ) -> TunnelDiagnosticResult {
        let status: DiagnosticStageStatus = isConnected ? .passed : (isConnecting ? .warning : .failed)
        let nodeDesc = activeNodeName ?? AppLocalization.string("Auto (Strategy Group)")
        let protoDesc = protocolName.map { " [\($0)]" } ?? ""

        let detail: String
        if isConnected {
            detail = "\(nodeDesc)\(protoDesc) · \(routingMode.localizedTitle)"
        } else if isConnecting {
            detail = AppLocalization.string("Tunnel connecting...")
        } else {
            detail = AppLocalization.string("Tunnel inactive")
        }

        return TunnelDiagnosticResult(
            isConnected: isConnected,
            routingMode: routingMode,
            activeNodeName: activeNodeName,
            protocolName: protocolName,
            status: status,
            detail: detail
        )
    }

    private func inspectDNS(domain: String) async -> DNSDiagnosticResult {
        await Task.detached(priority: .userInitiated) {
            let start = CFAbsoluteTimeGetCurrent()
            var hints = addrinfo(
                ai_flags: AI_ADDRCONFIG,
                ai_family: AF_INET,
                ai_socktype: SOCK_STREAM,
                ai_protocol: IPPROTO_TCP,
                ai_addrlen: 0,
                ai_canonname: nil,
                ai_addr: nil,
                ai_next: nil
            )
            var res: UnsafeMutablePointer<addrinfo>?
            let err = getaddrinfo(domain, nil, &hints, &res)
            let latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            defer {
                if let res { freeaddrinfo(res) }
            }

            guard err == 0, let first = res else {
                return DNSDiagnosticResult(
                    domain: domain,
                    resolvedIP: nil,
                    isFakeIP: false,
                    latencyMs: latencyMs,
                    status: .failed,
                    detail: AppLocalization.string("Resolution timeout or host not found")
                )
            }

            var addr = sockaddr_in()
            memcpy(&addr, first.pointee.ai_addr, Int(first.pointee.ai_addrlen))
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &addr.sin_addr, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let ipString = ipBuffer.withUnsafeBufferPointer { ptr in
                ptr.baseAddress.map { String(cString: $0) } ?? ""
            }

            let isFakeIP = Self.isFakeIPAddress(addr.sin_addr.s_addr)
            let status: DiagnosticStageStatus = (isFakeIP || !ipString.isEmpty) ? .passed : .warning
            let detail = isFakeIP
                ? "\(ipString) · Fake-IP (\(String(format: "%.1f ms", latencyMs)))"
                : "\(ipString) · Direct (\(String(format: "%.1f ms", latencyMs)))"

            return DNSDiagnosticResult(
                domain: domain,
                resolvedIP: ipString,
                isFakeIP: isFakeIP,
                latencyMs: latencyMs,
                status: status,
                detail: detail
            )
        }.value
    }

    nonisolated private static func isFakeIPAddress(_ s_addr: in_addr_t) -> Bool {
        // 198.18.0.0/15 -> host byte order mask 0xFFFE0000 == 0xC6120000
        let hostOrder = CFSwapInt32BigToHost(s_addr)
        return (hostOrder & 0xFFFE0000) == 0xC6120000
    }

    private func inspectDomestic(targetURL: String) async -> DomesticDiagnosticResult {
        guard let url = URL(string: targetURL) else {
            return DomesticDiagnosticResult(
                targetURL: targetURL,
                httpCode: nil,
                latencyMs: 0,
                status: .failed,
                detail: "Invalid URL"
            )
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 4.0
        config.timeoutIntervalForResource = 5.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            let latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let passed = (statusCode == 200 || statusCode == 204)
            return DomesticDiagnosticResult(
                targetURL: targetURL,
                httpCode: statusCode,
                latencyMs: latencyMs,
                status: passed ? .passed : .warning,
                detail: "HTTP \(statusCode) · \(String(format: "%.0f ms", latencyMs))"
            )
        } catch {
            let latencyMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return DomesticDiagnosticResult(
                targetURL: targetURL,
                httpCode: nil,
                latencyMs: latencyMs,
                status: .failed,
                detail: AppLocalization.string("Direct connection failed: ") + error.localizedDescription
            )
        }
    }

    private func inspectProxy(targetURL: String) async -> ProxyDiagnosticResult {
        guard let url = URL(string: targetURL) else {
            return ProxyDiagnosticResult(
                targetURL: targetURL,
                httpCode: nil,
                connectMs: nil,
                tlsMs: nil,
                totalMs: 0,
                status: .failed,
                detail: "Invalid URL"
            )
        }

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 6.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.waitsForConnectivity = false

        let delegate = MetricsDelegate()
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let start = CFAbsoluteTimeGetCurrent()
        do {
            let (_, response) = try await session.data(for: request)
            let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            var connectMs: Double?
            var tlsMs: Double?
            if let transaction = delegate.metrics?.transactionMetrics.last {
                if let cStart = transaction.connectStartDate, let cEnd = transaction.connectEndDate {
                    connectMs = cEnd.timeIntervalSince(cStart) * 1000.0
                }
                if let sStart = transaction.secureConnectionStartDate, let sEnd = transaction.secureConnectionEndDate {
                    tlsMs = sEnd.timeIntervalSince(sStart) * 1000.0
                }
            }

            let isDegraded = totalMs > 2000.0 || (tlsMs ?? 0) > 1500.0
            let status: DiagnosticStageStatus = (statusCode == 204 || statusCode == 200)
                ? (isDegraded ? .warning : .passed)
                : .failed

            var detailParts: [String] = ["HTTP \(statusCode)"]
            if let tls = tlsMs {
                detailParts.append("TLS \(String(format: "%.0f ms", tls))")
            }
            detailParts.append("Total \(String(format: "%.0f ms", totalMs))")

            return ProxyDiagnosticResult(
                targetURL: targetURL,
                httpCode: statusCode,
                connectMs: connectMs,
                tlsMs: tlsMs,
                totalMs: totalMs,
                status: status,
                detail: detailParts.joined(separator: " · ")
            )
        } catch {
            let totalMs = (CFAbsoluteTimeGetCurrent() - start) * 1000.0
            return ProxyDiagnosticResult(
                targetURL: targetURL,
                httpCode: nil,
                connectMs: nil,
                tlsMs: nil,
                totalMs: totalMs,
                status: .failed,
                detail: AppLocalization.string("Proxy probe failed: ") + error.localizedDescription
            )
        }
    }

    private func evaluateVerdict(
        tunnel: TunnelDiagnosticResult,
        dns: DNSDiagnosticResult,
        domestic: DomesticDiagnosticResult,
        proxy: ProxyDiagnosticResult
    ) -> DiagnosticVerdict {
        if !tunnel.isConnected {
            return .tunnelDisconnected
        }
        if dns.status == .failed {
            return .dnsFailed
        }
        if domestic.status == .failed && proxy.status == .failed {
            return .offlineOrCaptive
        }
        if domestic.status == .passed && proxy.status == .failed {
            return .proxyBlocked
        }
        if proxy.status == .warning {
            return .proxyDegraded
        }
        if proxy.status == .passed {
            return .allHealthy
        }
        return .unknown
    }
}

// MARK: - Support Diagnostics View

struct DiagnosticReportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct SupportDiagnosticsView: View {
    @EnvironmentObject private var tunnel: TunnelManager
    @StateObject private var diagnosticsEngine = ConnectivityDiagnosticsEngine()
    @State private var document: DiagnosticReportDocument?
    @State private var isExporterPresented = false
    @State private var statusMessage: String?
    @State private var statusIsError = false
    @State private var isCreatingReport = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AetherVisual.s5) {
                // Page Header
                VStack(alignment: .leading, spacing: AetherVisual.s1) {
                    Text(AppLocalization.string("Diagnostics"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.string("Inspect end-to-end network health or generate a bounded support report."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 1. Interactive Live Connectivity Diagnostics Card
                liveDiagnosticsCard

                // 3. Export Support Report Card
                HStack {
                    VStack(alignment: .leading, spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("Support report"))
                            .font(.subheadline.weight(.semibold))
                        Text(AppLocalization.string("Maximum 64 KiB. Review the file before sharing it."))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        Task { await createReport() }
                    } label: {
                        AetherProgressButtonLabel(
                            AppLocalization.string("Export Diagnostic Report"),
                            systemImage: "square.and.arrow.up",
                            isWorking: isCreatingReport
                        )
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isCreatingReport)
                    .accessibilityIdentifier("export-diagnostics")
                }
                .padding(AetherVisual.s4)
                .aetherPanel()

                if let statusMessage {
                    Label(
                        statusMessage,
                        systemImage: statusIsError
                            ? "exclamationmark.triangle.fill"
                            : "checkmark.circle.fill"
                    )
                    .font(.callout)
                    .foregroundStyle(statusIsError ? .red : .green)
                    .accessibilityIdentifier("diagnostics-status")
                }

                diagnosticSection(
                    title: "Included",
                    symbol: "checkmark.circle.fill",
                    tint: .green,
                    items: [
                        "App, build, macOS, and Apple silicon version",
                        "Connection, engine, and routing state",
                        "Profile item counts and aggregate traffic totals",
                        "Fixed aggregate provider error counters when available",
                        "Up to 128 fixed lifecycle event codes",
                    ]
                )

                diagnosticSection(
                    title: "Always omitted",
                    symbol: "minus.circle",
                    tint: .secondary,
                    items: [
                        "Profile names, YAML, subscription URLs, and credentials",
                        "Source and destination addresses",
                        "Rule payloads, proxy chains, and account identifiers",
                    ]
                )
            }
            .padding(.horizontal, AetherVisual.pageHorizontalPadding)
            .padding(.top, AetherVisual.pageTopPadding)
            .padding(.bottom, AetherVisual.pageBottomPadding)
            .frame(maxWidth: AetherVisual.formMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .fileExporter(
            isPresented: $isExporterPresented,
            document: document,
            contentType: .json,
            defaultFilename: Self.defaultFilename
        ) { result in
            switch result {
            case .success:
                statusMessage = AppLocalization.string(
                    "Diagnostic report saved."
                )
                statusIsError = false
            case .failure:
                statusMessage = AppLocalization.string(
                    "The diagnostic report could not be saved."
                )
                statusIsError = true
            }
            document = nil
        }
    }

    // MARK: - Live Diagnostics Card

    private var liveDiagnosticsCard: some View {
        VStack(alignment: .leading, spacing: AetherVisual.s4) {
            // Card Header
            HStack(spacing: AetherVisual.s3) {
                ZStack {
                    RoundedRectangle(cornerRadius: AetherVisual.insetRadius, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: "stethoscope")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                    Text(AppLocalization.string("Live Connectivity Diagnostics"))
                        .font(.headline)
                    Text(AppLocalization.string("Real-time inspection of tunnel adapter, Fake-IP DNS, and outbound TLS path."))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if diagnosticsEngine.isRunning {
                    HStack(spacing: AetherVisual.s2) {
                        ProgressView()
                            .controlSize(.small)
                        Text(AppLocalization.string("Diagnosing..."))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, AetherVisual.s2)
                } else if diagnosticsEngine.report != nil {
                    Button {
                        triggerDiagnostics()
                    } label: {
                        HStack(spacing: AetherVisual.s1) {
                            Image(systemName: "arrow.clockwise")
                            Text(AppLocalization.string("Re-run Diagnostics"))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .accessibilityIdentifier("rerun-diagnostics")
                } else {
                    Button {
                        triggerDiagnostics()
                    } label: {
                        HStack(spacing: AetherVisual.s1) {
                            Image(systemName: "play.fill")
                            Text(AppLocalization.string("Run Diagnostics"))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .accessibilityIdentifier("run-diagnostics")
                }
            }

            // Current state, with a way to the live flow list: context for
            // the checks above rather than a card of its own.
            HStack(spacing: AetherVisual.s2) {
                AetherStatusBeacon(
                    isConnected: tunnel.isConnected,
                    isConnecting: tunnel.state == .connecting,
                    size: 6
                )
                Text(tunnel.compactStatusTitle)
                    .font(.callout.weight(.medium))
                Text(tunnel.statusDetail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: AetherVisual.s2)
                Button {
                    NotificationCenter.default.post(
                        name: .aetherRouteNavigateToSection,
                        object: AppSection.connections.rawValue
                    )
                    AppWindowManager.shared.showMainWindow()
                } label: {
                    HStack(spacing: AetherVisual.s1) {
                        Text(AppLocalization.string("View connections"))
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                }
                .buttonStyle(.link)
            }

            // Staged Pipeline Visualization
            if diagnosticsEngine.isRunning || diagnosticsEngine.report != nil {
                Divider()

                VStack(spacing: AetherVisual.s3) {
                    stageRow(
                        index: 1,
                        title: AppLocalization.string("Tunnel & Node"),
                        symbol: "network",
                        status: stageStatus(stageIndex: 1, resultStatus: diagnosticsEngine.report?.tunnel.status),
                        detail: diagnosticsEngine.report?.tunnel.detail ?? (diagnosticsEngine.currentStage == 1 ? AppLocalization.string("Inspecting tunnel adapter and active profile...") : AppLocalization.string("Pending"))
                    )

                    stageRow(
                        index: 2,
                        title: AppLocalization.string("DNS & Fake-IP"),
                        symbol: "wand.and.stars",
                        status: stageStatus(stageIndex: 2, resultStatus: diagnosticsEngine.report?.dns.status),
                        detail: diagnosticsEngine.report?.dns.detail ?? (diagnosticsEngine.currentStage == 2 ? AppLocalization.string("Testing Fake-IP pool (198.18.0.0/15) resolution...") : AppLocalization.string("Pending"))
                    )

                    stageRow(
                        index: 3,
                        title: AppLocalization.string("Domestic Direct"),
                        symbol: "bolt.fill",
                        status: stageStatus(stageIndex: 3, resultStatus: diagnosticsEngine.report?.domestic.status),
                        detail: diagnosticsEngine.report?.domestic.detail ?? (diagnosticsEngine.currentStage == 3 ? AppLocalization.string("Probing domestic high-speed connectivity endpoint...") : AppLocalization.string("Pending"))
                    )

                    stageRow(
                        index: 4,
                        title: AppLocalization.string("Outbound Proxy Path"),
                        symbol: "globe.americas.fill",
                        status: stageStatus(stageIndex: 4, resultStatus: diagnosticsEngine.report?.proxy.status),
                        detail: diagnosticsEngine.report?.proxy.detail ?? (diagnosticsEngine.currentStage == 4 ? AppLocalization.string("Testing proxy node TCP connect and TLS handshake...") : AppLocalization.string("Pending"))
                    )
                }

                // Verdict Banner
                if let report = diagnosticsEngine.report {
                    verdictBanner(report: report)
                }
            }
        }
        .padding(AetherVisual.s4)
        .aetherPanel()
    }

    private func stageStatus(stageIndex: Int, resultStatus: DiagnosticStageStatus?) -> DiagnosticStageStatus {
        if let result = resultStatus {
            return result
        }
        if diagnosticsEngine.currentStage == stageIndex {
            return .running
        } else if diagnosticsEngine.currentStage > stageIndex {
            return .passed
        }
        return .pending
    }

    private func stageRow(
        index: Int,
        title: String,
        symbol: String,
        status: DiagnosticStageStatus,
        detail: String
    ) -> some View {
        HStack(spacing: AetherVisual.s3) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: AetherVisual.sMicro) {
                HStack(spacing: AetherVisual.s2) {
                    Text(title)
                        .font(.body.weight(.medium))
                    Spacer()
                    stageStatusBadge(status: status)
                }
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, AetherVisual.sMicro)
    }

    @ViewBuilder
    private func stageStatusBadge(status: DiagnosticStageStatus) -> some View {
        switch status {
        case .pending:
            Circle()
                .fill(Color.secondary.opacity(0.3))
                .frame(width: 10, height: 10)
        case .running:
            ProgressView()
                .controlSize(.mini)
        case .passed:
            Image(systemName: "checkmark.circle.fill")
                .font(.body)
                .foregroundStyle(.green)
        case .warning:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.body)
                .foregroundStyle(.orange)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.body)
                .foregroundStyle(.red)
        }
    }

    private func verdictBanner(report: ConnectivityDiagnosticReport) -> some View {
        let tintColor: Color
        let symbol: String
        switch report.verdict {
        case .allHealthy:
            tintColor = .green
            symbol = "checkmark.seal.fill"
        case .proxyDegraded:
            tintColor = .orange
            symbol = "exclamationmark.triangle.fill"
        case .proxyBlocked:
            tintColor = .red
            symbol = "xmark.octagon.fill"
        case .offlineOrCaptive:
            tintColor = .red
            symbol = "wifi.slash"
        case .tunnelDisconnected:
            tintColor = .secondary
            symbol = "power"
        case .dnsFailed:
            tintColor = .red
            symbol = "exclamationmark.circle.fill"
        case .unknown:
            tintColor = .secondary
            symbol = "questionmark.circle.fill"
        }

        return VStack(alignment: .leading, spacing: AetherVisual.s2) {
            HStack(spacing: AetherVisual.s2) {
                Image(systemName: symbol)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tintColor)
                Text(AppLocalization.string(report.verdict.titleKey))
                    .font(.body.weight(.bold))
                    .foregroundStyle(tintColor)
                Spacer()
                Text(String(format: "%.0f ms", report.totalDurationMs))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Text(AppLocalization.string(report.verdict.recommendationKey))
                .font(.caption)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(AetherVisual.s3)
        .background(
            RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                .fill(tintColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: AetherVisual.cardRadius, style: .continuous)
                        .stroke(tintColor.opacity(0.25), lineWidth: 1)
                )
        )
    }

    private func triggerDiagnostics() {
        var activeNode: String?
        var protocolName: String?
        if let summary = tunnel.activeProfileSummary,
           let primaryGroup = summary.proxyGroups.first(where: { $0.strategy.lowercased() == "select" }) ?? summary.proxyGroups.first {
            activeNode = tunnel.proxySelections[primaryGroup.name]?.selectedMember
            if let node = activeNode {
                protocolName = summary.proxies.first(where: { $0.name == node })?.protocolName
            }
        }

        let isConnected = tunnel.isConnected
        let isConnecting = (tunnel.state == .connecting)
        let routingMode = tunnel.routingMode

        Task {
            await diagnosticsEngine.runDiagnostics(
                isConnected: isConnected,
                isConnecting: isConnecting,
                routingMode: routingMode,
                activeNodeName: activeNode,
                protocolName: protocolName
            )
        }
    }

    // MARK: - Support Report Details

    private func diagnosticSection(
        title: String,
        symbol: String,
        tint: Color,
        items: [String]
    ) -> some View {
        VStack(alignment: .leading, spacing: AetherVisual.s2) {
            Text(verbatim: AppLocalization.string(title))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, AetherVisual.s1)

            VStack(alignment: .leading, spacing: AetherVisual.s2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    Label {
                        Text(verbatim: AppLocalization.string(item))
                    } icon: {
                        Image(systemName: symbol)
                    }
                    .labelStyle(DiagnosticItemLabelStyle(tint: tint))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AetherVisual.s4)
            .aetherPanel()
        }
    }

    @MainActor
    private func createReport() async {
        guard !isCreatingReport else { return }
        isCreatingReport = true
        defer { isCreatingReport = false }
        do {
            document = DiagnosticReportDocument(
                data: try await tunnel.makeDiagnosticReport()
            )
            statusMessage = nil
            statusIsError = false
            isExporterPresented = true
        } catch {
            document = nil
            statusMessage = AppLocalization.string(
                "The diagnostic report could not be created."
            )
            statusIsError = true
        }
    }

    private static var defaultFilename: String {
        let day = Date.now.formatted(
            .iso8601.year().month().day().dateSeparator(.dash)
        )
        return "AetherRoute-Diagnostics-" + day
    }
}

private struct DiagnosticItemLabelStyle: LabelStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AetherVisual.s2) {
            configuration.icon
                .foregroundStyle(tint)
            configuration.title
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.subheadline)
    }
}

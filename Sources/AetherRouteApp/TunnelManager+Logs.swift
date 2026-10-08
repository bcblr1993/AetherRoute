import AetherRouteKit
import Foundation

extension TunnelManager {
    /// How much each process returns to the log viewer.
    static let logViewerKilobytesPerProcess: UInt16 = 256

    var diagnosticLogLevel: DiagnosticLogLevel {
        (try? DiagnosticLogLevelStore.applicationGroup())?.load() ?? .off
    }

    /// Saves the level. The app picks it up within a few seconds; a running
    /// network extension receives it with its next connection.
    func setDiagnosticLogLevel(_ level: DiagnosticLogLevel) {
        try? DiagnosticLogLevelStore.applicationGroup().save(level)
        objectWillChange.send()
    }

    /// This app's log and, while connected, the network extension's, merged
    /// in time order. Nothing leaves this Mac.
    func loadDiagnosticLogLines() async -> [DiagnosticLogLine] {
        let maximumBytes = Int(Self.logViewerKilobytesPerProcess) * 1_024
        let appText = await Task.detached(priority: .userInitiated) {
            DiagnosticLogCenter.current.recentLog(maximumBytes: maximumBytes)
        }.value
        let appLines = DiagnosticLogLine.parse(appText, process: "app")

        var extensionLines: [DiagnosticLogLine] = []
        if state == .connected, !isUIReviewMode {
            let connectionID = providerConnectionID
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data, for: connectionID)
            }
            if let text = try? await client.recentLog(
                maximumKilobytes: Self.logViewerKilobytesPerProcess
            ) {
                extensionLines = DiagnosticLogLine.parse(
                    text,
                    process: networkEngineMode == .transparent ? "transparent-proxy" : "tunnel",
                    firstID: appLines.count
                )
            }
        }
        return DiagnosticLogLine.merged([appLines, extensionLines])
    }
}

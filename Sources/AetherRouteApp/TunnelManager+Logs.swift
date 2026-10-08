import AetherRouteKit
import Foundation
import OSLog

extension TunnelManager {
    /// How much each process returns to the log viewer.
    static let logViewerKilobytesPerProcess: UInt16 = 256

    var diagnosticLogLevel: DiagnosticLogLevel {
        (try? DiagnosticLogLevelStore.applicationGroup())?.load() ?? .off
    }

    /// Saves the level. The app picks it up within a few seconds; a running
    /// network extension is told at once, and every later connection carries
    /// it in the launch snapshot.
    func setDiagnosticLogLevel(_ level: DiagnosticLogLevel) {
        try? DiagnosticLogLevelStore.applicationGroup().save(level)
        objectWillChange.send()
        guard state == .connected, !isUIReviewMode else { return }
        let connectionID = providerConnectionID
        Task { [weak self] in
            guard let self else { return }
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data, for: connectionID)
            }
            do {
                try await client.setDiagnosticLogLevel(level)
            } catch {
                // An older extension does not know the message; it uses the
                // level from its next connection.
                Self.runtimeLogger.warning(
                    "stage=setDiagnosticLogLevel failed error=\(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// This app's log and, while connected, the network extension's, merged
    /// in time order. Nothing leaves this Mac.
    func loadDiagnosticLogLines() async -> [DiagnosticLogLine] {
        let maximumBytes = Int(Self.logViewerKilobytesPerProcess) * 1_024
        let appLines = await Task.detached(priority: .userInitiated) {
            DiagnosticLogLine.parse(
                DiagnosticLogCenter.current.recentLog(maximumBytes: maximumBytes),
                process: "app"
            )
        }.value

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
                let process = networkEngineMode == .transparent ? "transparent-proxy" : "tunnel"
                let firstID = appLines.count
                extensionLines = await Task.detached(priority: .userInitiated) {
                    DiagnosticLogLine.parse(text, process: process, firstID: firstID)
                }.value
            }
        }
        let parts = [appLines, extensionLines]
        return await Task.detached(priority: .userInitiated) {
            DiagnosticLogLine.merged(parts)
        }.value
    }
}

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

    /// Captures a bounded snapshot of the active extension's diagnostic log while
    /// connected so post-disconnect or post-crash diagnostics remain viewable.
    func snapshotExtensionDiagnosticLogIfNeeded(timeout: Duration = .milliseconds(1_200)) async {
        guard state == .connected,
              !isUIReviewMode,
              diagnosticLogLevel != .off else {
            return
        }
        let connectionID = providerConnectionID
        let process = networkEngineMode == .transparent ? "transparent-proxy" : "tunnel"
        let client = ProxySelectionProviderClient { [weak self] data in
            guard let self else {
                throw TunnelManagerError.providerSessionUnavailable
            }
            return try await self.sendProviderMessage(
                data,
                for: connectionID,
                timeout: timeout
            )
        }
        if let text = try? await client.recentLog(
            maximumKilobytes: Self.logViewerKilobytesPerProcess
        ), !text.isEmpty {
            storeCachedExtensionDiagnosticLog(process: process, text: text)
        }
    }

    private func storeCachedExtensionDiagnosticLog(process: String, text: String) {
        cachedExtensionDiagnosticLog = (process: process, text: text)
        let maximumBytes = Int(Self.logViewerKilobytesPerProcess) * 1_024
        Task.detached(priority: .utility) {
            Self.writeCachedExtensionDiagnosticLogToDisk(
                process: process,
                text: text,
                maximumBytes: maximumBytes
            )
        }
    }

    private nonisolated static var cachedExtensionDiagnosticLogURL: URL? {
        guard NSClassFromString("XCTestCase") == nil,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
              let container = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: AppConstants.appGroup
              ) else {
            return nil
        }
        return container
            .appendingPathComponent("Library/Caches/AetherRoute", isDirectory: true)
            .appendingPathComponent("extension-last-diagnostic.log", isDirectory: false)
    }

    private nonisolated static func writeCachedExtensionDiagnosticLogToDisk(
        process: String,
        text: String,
        maximumBytes: Int
    ) {
        guard let url = cachedExtensionDiagnosticLogURL else { return }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let utf8 = Data(text.utf8).suffix(maximumBytes)
        var payload = Data("# process=\(process)\n".utf8)
        payload.append(utf8)
        try? payload.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var resourceURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? resourceURL.setResourceValues(values)
    }

    private nonisolated static func loadCachedExtensionDiagnosticLogFromDisk(
        maximumBytes: Int
    ) -> (process: String, text: String)? {
        guard let url = cachedExtensionDiagnosticLogURL,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
              let content = String(data: data.suffix(maximumBytes + 128), encoding: .utf8),
              let firstNewline = content.firstIndex(of: "\n") else {
            return nil
        }
        let header = content[..<firstNewline]
        let prefix = "# process="
        guard header.hasPrefix(prefix) else { return nil }
        let process = String(header.dropFirst(prefix.count))
        guard process == "tunnel" || process == "transparent-proxy" else { return nil }
        let body = String(content[content.index(after: firstNewline)...])
        guard !body.isEmpty else { return nil }
        return (process: process, text: body)
    }

    /// This app's log and, while connected (or from the last cached snapshot
    /// when disconnected), the network extension's, merged in time order.
    /// Nothing leaves this Mac.
    func loadDiagnosticLogLines() async -> [DiagnosticLogLine] {
        let maximumBytes = Int(Self.logViewerKilobytesPerProcess) * 1_024
        let appLines = await Task.detached(priority: .userInitiated) {
            DiagnosticLogLine.parse(
                DiagnosticLogCenter.current.recentLog(maximumBytes: maximumBytes),
                process: "app"
            )
        }.value

        var extensionLines: [DiagnosticLogLine] = []
        var loadedLiveExtensionLog = false
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
                if !text.isEmpty {
                    storeCachedExtensionDiagnosticLog(process: process, text: text)
                }
                let firstID = appLines.count
                extensionLines = await Task.detached(priority: .userInitiated) {
                    DiagnosticLogLine.parse(text, process: process, firstID: firstID)
                }.value
                loadedLiveExtensionLog = !extensionLines.isEmpty
            }
        }
        if !loadedLiveExtensionLog, !isUIReviewMode {
            let cached = cachedExtensionDiagnosticLog
                ?? Self.loadCachedExtensionDiagnosticLogFromDisk(maximumBytes: maximumBytes)
            if let cached, !cached.text.isEmpty {
                let firstID = appLines.count
                extensionLines = await Task.detached(priority: .userInitiated) {
                    DiagnosticLogLine.parse(
                        cached.text,
                        process: cached.process,
                        firstID: firstID
                    )
                }.value
            }
        }
        let parts = [appLines, extensionLines]
        return await Task.detached(priority: .userInitiated) {
            DiagnosticLogLine.merged(parts)
        }.value
    }
}

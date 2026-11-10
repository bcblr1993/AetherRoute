import AetherRouteKit
import AppKit
import Darwin
import NetworkExtension
import OSLog
import ServiceManagement
@preconcurrency import SystemExtensions

/// Carries out `AppUninstaller` steps on this Mac.
@MainActor
final class AppUninstallPerformer: UninstallStepPerforming {
    private static let logger = AppLog.logger(category: AppLog.Category.appRuntime)
    private static var isTerminatingForUninstall = false
    private let tunnel: TunnelManager

    init(tunnel: TunnelManager) {
        self.tunnel = tunnel
    }

    /// Both engines' extensions, whichever is in use: either may have been
    /// activated by an earlier session.
    static var extensionIdentifiers: [String] {
        [AppConstants.tunnelBundleIdentifier, AppConstants.transparentProxyBundleIdentifier]
    }

    func perform(_ step: UninstallStep) async -> UninstallStepOutcome {
        Self.logger.info("stage=uninstall step=\(String(describing: step), privacy: .public) begin")
        let outcome: UninstallStepOutcome
        switch step {
        case .disconnect:
            await tunnel.tearDownForUninstall()
            outcome = .completed
        case .removeNetworkConfigurations:
            outcome = await removeNetworkConfigurations()
        case let .deactivateExtension(identifier):
            outcome = await SystemExtensionDeactivator.deactivate(identifier: identifier)
        case .unregisterLoginItem:
            outcome = await unregisterLoginItem()
        case .deleteUserData:
            outcome = deleteUserData()
        case .moveAppToTrash:
            outcome = await moveAppToTrash()
        }
        Self.logger.info(
            "stage=uninstall step=\(String(describing: step), privacy: .public) outcome=\(String(describing: outcome), privacy: .public)"
        )
        return outcome
    }

    /// Both kinds, enabled or not: the transparent proxy's configuration is
    /// the one macOS leaves behind when the app is deleted.
    private func removeNetworkConfigurations() async -> UninstallStepOutcome {
        do {
            var managers: [NEVPNManager] = try await NETransparentProxyManager.loadAllFromPreferences()
            managers += try await NETunnelProviderManager.loadAllFromPreferences()
            for manager in managers {
                try await manager.removeFromPreferences()
            }
            tunnel.invalidateCachedManager()
            tunnel.state = .disconnected
            return .completed
        } catch {
            tunnel.invalidateCachedManager()
            return .failed(error.localizedDescription)
        }
    }

    private func unregisterLoginItem() async -> UninstallStepOutcome {
        let service = SMAppService.mainApp
        guard service.status != .notRegistered, service.status != .notFound else {
            return .completed
        }
        do {
            try await service.unregister()
            return .completed
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Profiles, rules, routing databases and settings on this Mac. Run after
    /// the extensions are gone: they read the shared container.
    private func deleteUserData() -> UninstallStepOutcome {
        var problems: [String] = []
        let fileManager = FileManager.default

        // 1. Group Containers (~/Library/Group Containers/group.com.aetherroute.desktop)
        if let container = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: AppConstants.appGroup
        ) {
            let items = (try? fileManager.contentsOfDirectory(
                at: container,
                includingPropertiesForKeys: nil
            )) ?? []
            for item in items {
                do {
                    try fileManager.removeItem(at: item)
                } catch {
                    problems.append(item.lastPathComponent)
                }
            }
        }

        // 2. Clear shared App Group user defaults
        UserDefaults(suiteName: AppConstants.appGroup)?
            .removePersistentDomain(forName: AppConstants.appGroup)

        // 3. Delete local keychain items
        for service in AppUninstaller.localKeychainServices {
            do {
                try DataProtectionProfileKeyStore(service: service).deleteAllKeys()
            } catch {
                problems.append(service)
            }
        }
        return problems.isEmpty ? .completed : .failed(problems.joined(separator: ", "))
    }

    /// Cleans local user Library residuals (Caches, Application Support, Containers, etc.)
    private static func cleanHostResiduals() {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aetherroute.desktop"
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        UserDefaults(suiteName: AppConstants.appGroup)?
            .removePersistentDomain(forName: AppConstants.appGroup)
        let pathsToDelete: [URL] = [
            home.appendingPathComponent("Library/Containers/\(bundleID)"),
            home.appendingPathComponent("Library/Application Support/AetherRoute"),
            home.appendingPathComponent("Library/Caches/\(bundleID)"),
            home.appendingPathComponent("Library/Preferences/\(bundleID).plist"),
            home.appendingPathComponent("Library/HTTPStorages/\(bundleID)"),
            home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState"),
        ]
        for url in pathsToDelete {
            guard fileManager.fileExists(atPath: url.path) else { continue }
            do {
                try fileManager.removeItem(at: url)
            } catch {
                Self.logger.notice("stage=uninstall cleanResidual failed path=\(url.path, privacy: .public) reason=\(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Defers physical `.app` bundle removal until `removeAppAndTerminate()` so
    /// the running application keeps its bundle resources intact while
    /// presenting the completion sheet.
    private func moveAppToTrash() async -> UninstallStepOutcome {
        Self.logger.info("stage=uninstall moveToTrash preparedForTermination")
        return .completed
    }

    /// Closes all windows, removes the application bundle and residual files,
    /// and exits the process immediately without re-entering AppKit termination
    /// hooks.
    static func removeAppAndTerminate() {
        guard !isTerminatingForUninstall else { return }
        isTerminatingForUninstall = true

        let appURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = appURL.path

        Self.logger.info("stage=uninstall removeAppAndTerminate begin path=\(appPath, privacy: .public)")

        AppWindowManager.shared.isTerminating = true
        for window in NSApplication.shared.windows {
            window.orderOut(nil)
        }
        NSApplication.shared.hide(nil)

        cleanHostResiduals()

        AppUninstaller.finalizeUninstall(
            appURL: appURL,
            pid: pid,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            trashItem: { url in
                do {
                    try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                    Self.logger.info("stage=uninstall removeAppAndTerminate trashItem succeeded")
                } catch {
                    Self.logger.notice("stage=uninstall trashItem fallback reason=\(error.localizedDescription, privacy: .public)")
                    throw error
                }
            },
            removeItem: { url in
                do {
                    try FileManager.default.removeItem(at: url)
                    Self.logger.info("stage=uninstall removeAppAndTerminate removeItem succeeded")
                } catch {
                    Self.logger.notice("stage=uninstall removeItem fallback reason=\(error.localizedDescription, privacy: .public)")
                    throw error
                }
            },
            spawnDetachedCleanup: { processID, bundlePath in
                let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.05; done; rm -rf -- \"$2\""
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/bin/sh")
                task.arguments = ["-c", script, "sh", String(processID), bundlePath]
                task.standardInput = FileHandle.nullDevice
                task.standardOutput = FileHandle.nullDevice
                task.standardError = FileHandle.nullDevice
                do {
                    try task.run()
                    Self.logger.info("stage=uninstall spawned detached cleanup process")
                    return true
                } catch {
                    Self.logger.notice("stage=uninstall detached process launch skipped: \(error.localizedDescription, privacy: .public)")
                    return false
                }
            },
            revealInFinder: { url in
                NSWorkspace.shared.activateFileViewerSelecting([url])
            },
            exitProcess: { code in
                if code == 0 {
                    Darwin.exit(EXIT_SUCCESS)
                }
                Darwin.exit(code)
            }
        )
        Darwin._exit(EXIT_SUCCESS)
    }
}

/// Asks macOS to deactivate one system extension and waits for the answer.
@MainActor
final class SystemExtensionDeactivator: NSObject, OSSystemExtensionRequestDelegate {
    private static var activeDeactivators: Set<SystemExtensionDeactivator> = []
    private var continuation: CheckedContinuation<UninstallStepOutcome, Never>?
    private var request: OSSystemExtensionRequest?

    static func deactivate(identifier: String) async -> UninstallStepOutcome {
        let deactivator = SystemExtensionDeactivator()
        activeDeactivators.insert(deactivator)
        return await deactivator.run(identifier: identifier)
    }

    private func run(identifier: String) async -> UninstallStepOutcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: identifier,
                queue: .main
            )
            request.delegate = self
            self.request = request
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ outcome: UninstallStepOutcome) {
        request = nil
        Self.activeDeactivators.remove(self)
        continuation?.resume(returning: outcome)
        continuation = nil
    }

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        actionForReplacingExtension existing: OSSystemExtensionProperties,
        withExtension ext: OSSystemExtensionProperties
    ) -> OSSystemExtensionRequest.ReplacementAction {
        .cancel
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {}

    nonisolated func request(
        _ request: OSSystemExtensionRequest,
        didFinishWithResult result: OSSystemExtensionRequest.Result
    ) {
        let outcome: UninstallStepOutcome = result == .willCompleteAfterReboot
            ? .completesAfterRestart
            : .completed
        Task { @MainActor in self.finish(outcome) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        // Never activated on this Mac (or already removed): nothing to do.
        let outcome: UninstallStepOutcome =
            nsError.domain == OSSystemExtensionErrorDomain
                && nsError.code == OSSystemExtensionError.extensionNotFound.rawValue
            ? .completed
            : .failed(error.localizedDescription)
        Task { @MainActor in self.finish(outcome) }
    }
}

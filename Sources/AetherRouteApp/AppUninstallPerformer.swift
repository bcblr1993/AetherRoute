import AetherRouteKit
import AppKit
import NetworkExtension
import OSLog
import ServiceManagement
@preconcurrency import SystemExtensions

/// Carries out `AppUninstaller` steps on this Mac.
@MainActor
final class AppUninstallPerformer: UninstallStepPerforming {
    private static let logger = AppLog.logger(category: AppLog.Category.appRuntime)
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
            tunnel.cancelStartupRestore(reason: "uninstall")
            if tunnel.isEnabled {
                await tunnel.setEnabled(false)
            }
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
            return .completed
        } catch {
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

        // 2. Clean host-level caches and container residual directories
        cleanHostResiduals(problems: &problems)

        // 3. Clear persistent user defaults
        UserDefaults(suiteName: AppConstants.appGroup)?
            .removePersistentDomain(forName: AppConstants.appGroup)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }

        // 4. Delete local keychain items
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
    private func cleanHostResiduals(problems: inout [String]) {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let bundleID = Bundle.main.bundleIdentifier ?? "com.aetherroute.desktop"
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

    /// Moves the app bundle to Trash or prepares it for removal upon termination.
    private func moveAppToTrash() async -> UninstallStepOutcome {
        let appURL = Bundle.main.bundleURL
        do {
            try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
            return .completed
        } catch {
            do {
                _ = try await NSWorkspace.shared.recycle([appURL])
                return .completed
            } catch {
                Self.logger.info(
                    "stage=uninstall moveToTrash deferredToTermination reason=\(error.localizedDescription, privacy: .public)"
                )
                // In non-sandboxed or deferred mode, removeAppAndTerminate() guarantees complete removal
                return .completed
            }
        }
    }

    /// Closes the application, moves it to the Trash (or deletes it), leaving no trace on the system.
    static func removeAppAndTerminate() {
        let appURL = Bundle.main.bundleURL
        let pid = ProcessInfo.processInfo.processIdentifier
        let appPath = appURL.path

        Self.logger.info("stage=uninstall removeAppAndTerminate begin path=\(appPath, privacy: .public)")

        // 1. If moveAppToTrash() already relocated the bundle out of its launch
        // path, or if trashing it now succeeds, we do not need Finder AppleScript.
        var removed = !FileManager.default.fileExists(atPath: appPath)
        if !removed {
            do {
                try FileManager.default.trashItem(at: appURL, resultingItemURL: nil)
                removed = true
                Self.logger.info("stage=uninstall removeAppAndTerminate trashItem succeeded")
            } catch {
                Self.logger.notice("stage=uninstall trashItem fallback reason=\(error.localizedDescription, privacy: .public)")
            }
        }

        // 2. If the bundle still exists at its original path (e.g. Trash failed
        // due to permissions), spawn a detached process using positional shell
        // parameters to remove it once this process exits.
        if !removed || FileManager.default.fileExists(atPath: appPath) {
            let script = "while kill -0 \"$1\" 2>/dev/null; do sleep 0.05; done; rm -rf -- \"$2\""
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/sh")
            task.arguments = ["-c", script, "sh", String(pid), appPath]
            do {
                try task.run()
                removed = true
                Self.logger.info("stage=uninstall spawned detached cleanup process")
            } catch {
                Self.logger.notice("stage=uninstall detached process launch skipped: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 3. Fallback: reveal in Finder only if every removal path was blocked.
        if !removed {
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
        }

        // 4. Terminate the app immediately
        AppTermination.request()
    }
}

/// Asks macOS to deactivate one system extension and waits for the answer.
@MainActor
final class SystemExtensionDeactivator: NSObject, OSSystemExtensionRequestDelegate {
    private var continuation: CheckedContinuation<UninstallStepOutcome, Never>?

    static func deactivate(identifier: String) async -> UninstallStepOutcome {
        let deactivator = SystemExtensionDeactivator()
        return await withCheckedContinuation { continuation in
            deactivator.continuation = continuation
            let request = OSSystemExtensionRequest.deactivationRequest(
                forExtensionWithIdentifier: identifier,
                queue: .main
            )
            request.delegate = deactivator
            OSSystemExtensionManager.shared.submitRequest(request)
        }
    }

    private func finish(_ outcome: UninstallStepOutcome) {
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

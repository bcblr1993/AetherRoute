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
        UserDefaults(suiteName: AppConstants.appGroup)?
            .removePersistentDomain(forName: AppConstants.appGroup)
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
        }
        for service in AppUninstaller.localKeychainServices {
            do {
                try DataProtectionProfileKeyStore(service: service).deleteAllKeys()
            } catch {
                problems.append(service)
            }
        }
        return problems.isEmpty ? .completed : .failed(problems.joined(separator: ", "))
    }

    /// The sandbox does not let the app move itself out of /Applications
    /// (seen on the Mac mini, 1.8.8). The network components are gone by
    /// now, so selecting the app in the Finder for the user to drag to the
    /// Trash leaves nothing behind.
    private func moveAppToTrash() async -> UninstallStepOutcome {
        let appURL = Bundle.main.bundleURL
        do {
            _ = try await NSWorkspace.shared.recycle([appURL])
            return .completed
        } catch {
            Self.logger.info(
                "stage=uninstall moveToTrash handedToUser reason=\(error.localizedDescription, privacy: .public)"
            )
            NSWorkspace.shared.activateFileViewerSelecting([appURL])
            return .handedToUser
        }
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

import AetherRouteKit
import AppKit
import Foundation
import NetworkExtension

/// First-run network setup: both engines' system extensions switched on and
/// both configurations allowed before the main window opens, so connecting
/// or switching engines later never stops for a system prompt.
extension TunnelManager {
    static let networkSetupCompletedKey = "AetherRoute.NetworkSetupCompleted"

    /// Engines this build offers, in the order they are set up and shown.
    var networkSetupEngines: [NetworkEngineMode] { NetworkEngineMode.allCases }

    var orderedNetworkSetupStates: [NetworkSetupStepState] {
        networkSetupEngines.map { networkSetupStates[$0] ?? .checking }
    }

    /// Decides at launch whether setup blocks the main window, and records
    /// the answer so a user who quits halfway is asked again next launch.
    func resolveNetworkSetupGate() -> Bool {
        let stored = userDefaults.object(forKey: Self.networkSetupCompletedKey) as? Bool
        var isAutomation = false
#if AETHERROUTE_QA_AUTOMATION
        isAutomation = qaAutomationEnvironment["AETHERROUTE_QA_AUTOCONNECT"] == "1"
#endif
        // Without a stored answer, a user who accepted the privacy disclosure
        // in an earlier version is an existing install and keeps going.
        let isExistingInstall = stored == nil && hasAcceptedPrivacyDisclosure
        let required = NetworkSetupProgress.requiresGate(
            hasCompletedSetup: stored ?? false,
            isExistingInstall: isExistingInstall,
            isAutomation: isAutomation
        )
        if stored == nil {
            userDefaults.set(!required, forKey: Self.networkSetupCompletedKey)
        }
        Self.runtimeLogger.info(
            "stage=networkSetup gate required=\(required, privacy: .public) existing=\(isExistingInstall, privacy: .public)"
        )
        return required
    }

    /// Reads what the system already granted, without prompting. Engines
    /// that are mid-request or failed keep their state so a refresh (for
    /// example when the app becomes active) does not hide an error.
    func refreshNetworkSetupStatus() async {
        guard !isRunningNetworkSetup else { return }
        if isUIReviewMode { return }
        for mode in networkSetupEngines where networkSetupStates[mode] == nil {
            networkSetupStates[mode] = .checking
        }
        for mode in networkSetupEngines {
            if let current = networkSetupStates[mode], Self.keepsStateOnRefresh(current) {
                continue
            }
            let probe = await SystemExtensionStatusProbe.probe(
                identifier: mode.providerBundleIdentifier
            )
            let hasConfiguration = ((try? await loadExistingManager(for: mode)) ?? nil) != nil
            networkSetupStates[mode] = NetworkSetupProgress.detectedState(
                extension: probe,
                hasConfiguration: hasConfiguration
            )
        }
    }

    private static func keepsStateOnRefresh(_ state: NetworkSetupStepState) -> Bool {
        switch state {
        case .installingExtension, .awaitingConfigurationConsent, .rebootRequired, .failed:
            true
        default:
            false
        }
    }

    /// Installs every engine's extension at once, so the user switches them
    /// on in a single visit to System Settings, then saves the configurations
    /// one after another because macOS shows one consent dialog at a time.
    func runNetworkSetup() async {
        guard !isRunningNetworkSetup, ensurePrivacyConsent() else { return }
        if isUIReviewMode {
            for mode in networkSetupEngines { networkSetupStates[mode] = .ready }
            return
        }
        isRunningNetworkSetup = true
        defer { isRunningNetworkSetup = false }

        let targets = networkSetupEngines.filter { mode in
            let state = networkSetupStates[mode] ?? .pending
            return !state.isReady && !state.isBlockedPermanently
        }
        Self.runtimeLogger.info(
            "stage=networkSetup run engines=\(targets.map(\.rawValue).joined(separator: ","), privacy: .public)"
        )

        // Started together so both requests are pending at once; each runs
        // on the main actor and interleaves at its suspension points.
        let installs = targets.map { mode in
            (mode, Task { @MainActor in await self.installExtensionForSetup(mode) })
        }
        var installed: [NetworkEngineMode] = []
        for (mode, install) in installs where await install.value {
            installed.append(mode)
        }
        for mode in networkSetupEngines where installed.contains(mode) {
            await saveConfigurationForSetup(mode)
        }
    }

    private func installExtensionForSetup(_ mode: NetworkEngineMode) async -> Bool {
        networkSetupStates[mode] = .installingExtension
        // A coordinator per engine: the shared one serves one request at a
        // time, and both requests must be pending together.
        let coordinator = SystemExtensionActivationCoordinator()
        do {
            try await coordinator.activate(identifier: mode.providerBundleIdentifier) { [weak self] in
                self?.networkSetupStates[mode] = .awaitingApproval
            }
            return true
        } catch let error as SystemExtensionActivationError {
            networkSetupStates[mode] = error == .rebootRequired
                ? .rebootRequired
                : .failed(reason: error.localizedDescription, isRetryable: error.isRetryable)
        } catch {
            networkSetupStates[mode] = .failed(reason: error.localizedDescription, isRetryable: true)
        }
        Self.runtimeLogger.error(
            "stage=networkSetup extension failed engine=\(mode.rawValue, privacy: .public)"
        )
        return false
    }

    private func saveConfigurationForSetup(_ mode: NetworkEngineMode) async {
        networkSetupStates[mode] = .awaitingConfigurationConsent
        do {
            if try await loadExistingManager(for: mode) == nil {
                let manager = makeProviderManager(for: mode, isEnabled: false)
                try await manager.saveToPreferences()
            }
            networkSetupStates[mode] = .ready
        } catch {
            let nsError = error as NSError
            let denied = nsError.domain == NEVPNErrorDomain
                && nsError.code == NEVPNError.configurationReadWriteFailed.rawValue
            networkSetupStates[mode] = .failed(
                reason: denied
                    ? AppLocalization.string("Permission to add the configuration was not given. Choose Retry, then Allow in the dialog.")
                    : error.localizedDescription,
                isRetryable: true
            )
            Self.runtimeLogger.error(
                "stage=networkSetup configuration failed engine=\(mode.rawValue, privacy: .public) denied=\(denied, privacy: .public)"
            )
        }
    }

    /// Leaves setup. The first-run gate is lifted and remembered; an engine
    /// that ended up unavailable is not left selected.
    func finishNetworkSetup() async {
        guard NetworkSetupProgress.canFinish(orderedNetworkSetupStates) else { return }
        if !(networkSetupStates[networkEngineMode]?.isReady ?? false),
           let usable = networkSetupEngines.first(where: { networkSetupStates[$0]?.isReady ?? false }) {
            networkEngineMode = usable
            if !isUIReviewMode {
                userDefaults.set(usable.rawValue, forKey: Self.networkEnginePreferenceKey)
            }
        }
        let wasGated = isNetworkSetupRequired
        isNetworkSetupRequired = false
        guard !isUIReviewMode else { return }
        userDefaults.set(true, forKey: Self.networkSetupCompletedKey)
        Self.runtimeLogger.info("stage=networkSetup finished firstRun=\(wasGated, privacy: .public)")
        // Re-setup from Overview follows a failed or withdrawn permission;
        // drop the cached configuration so prepare() reads the new one. A
        // live session is left alone.
        switch state {
        case .connected, .connecting, .recovering, .disconnecting:
            return
        default:
            break
        }
        if !wasGated { invalidateCachedManager() }
        state = .loading
        await prepare()
    }

    func openNetworkExtensionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

#if DEBUG
    /// Isolated screenshot review: "start", "waiting", "failed" or "done".
    func installReviewNetworkSetup(_ scenario: String?) {
        guard let scenario else { return }
        isNetworkSetupRequired = true
        let engines = networkSetupEngines
        func set(_ states: [NetworkSetupStepState]) {
            for (mode, state) in zip(engines, states) { networkSetupStates[mode] = state }
        }
        switch scenario {
        case "waiting": set([.ready, .awaitingApproval])
        case "consent": set([.ready, .awaitingConfigurationConsent])
        case "failed": set([.ready, .failed(reason: AppLocalization.string("Permission to add the configuration was not given. Choose Retry, then Allow in the dialog."), isRetryable: true)])
        case "done": set([.ready, .ready])
        default: set([.pending, .pending])
        }
    }
#else
    func installReviewNetworkSetup(_ scenario: String?) {}
#endif
}

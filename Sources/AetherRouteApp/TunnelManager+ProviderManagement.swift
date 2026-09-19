import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    func setNetworkEngineMode(_ mode: NetworkEngineMode) async {
        guard !isSwitchingNetworkEngine, mode != networkEngineMode, canChangeNetworkEngine else { return }
        if isUIReviewMode {
            networkEngineMode = mode
            userDefaults.set(mode.rawValue, forKey: Self.networkEnginePreferenceKey)
            networkEngineMessage = AppLocalization.string("Network engine updated.")
            networkEngineMessageIsError = false
            return
        }
        let previousMode = networkEngineMode
        let shouldReconnect = isEnabled || managerConnectionIsActive
        let currentRoutingMode = sessionRoutingMode ?? routingMode
        isSwitchingNetworkEngine = true
        networkEngineMessage = shouldReconnect
            ? AppLocalization.string("Switching network engine…") : nil
        networkEngineMessageIsError = false
        defer {
            isSwitchingNetworkEngine = false
            if case .failed = state {} else {
                lastObservedProviderStatus = manager?.connection.status
                updateState()
            }
        }
        guard shouldReconnect else {
            await applyNetworkEngineMode(mode)
            networkEngineMessage = AppLocalization.string("Network engine updated.")
            return
        }
        state = .connecting
        connectedSince = nil
        cancelConnectionReadiness()
        cancelAutomaticReconnect(reason: "switchingEngine")
        stopTelemetryPolling()
        var launchPayload: Data?
        do {
            let outcome = try await engineReconnect.run(
                stop: { [self] in
                    if let connection = manager?.connection, Self.isActiveProviderStatus(connection.status) {
                        connection.stopVPNTunnel()
                    }
                    return await waitForProviderToBecomeInactive(timeout: Self.networkEngineSwitchDrainTimeout)
                },
                prepare: { [self] restoringPrevious in
                    launchPayload = try await prepareNetworkEngineReconnect(
                        mode: restoringPrevious ? previousMode : mode,
                        routingMode: currentRoutingMode
                    )
                },
                start: { [self] in
                    guard distributionConnectionAccess.permitsNewConnection,
                          let launchPayload,
                          let session = manager?.connection as? NETunnelProviderSession else {
                        throw CancellationError()
                    }
                    try session.startVPNTunnel(options: [
                        ProviderLaunchSnapshotCodec.startOptionsKey: launchPayload as NSData
                    ])
                },
                waitUntilConnected: { [self] in
                    await waitForProviderConnectionStatus(.connected, timeout: Self.networkEngineSwitchSettleTimeout)
                }
            )
            connectedSince = manager?.connection.connectedDate ?? .now
            sessionRoutingMode = currentRoutingMode
            sessionNetworkEngineMode = outcome == .switched ? mode : previousMode
            state = .connected
            startTelemetryPollingIfNeeded()
            networkEngineMessage = AppLocalization.string(outcome == .switched
                ? "Network engine switched without manual disconnection."
                : "The new network engine could not connect. The previous engine was restored.")
            networkEngineMessageIsError = outcome != .switched
        } catch is CancellationError {
            manager?.connection.stopVPNTunnel()
        } catch {
            // A failed rollback must not leave an unobserved connecting provider.
            beginDisconnectionWatchdog(selfInitiated: true)
            manager?.connection.stopVPNTunnel()
            networkEngineMessage = AppLocalization.string("The new network engine and automatic rollback both failed.")
            networkEngineMessageIsError = true
            recordFailure(error, context: .provider)
        }
    }

    func prepareNetworkEngineReconnect(
        mode: NetworkEngineMode,
        routingMode: RoutingMode
    ) async throws -> Data {
        try engineReconnect.checkActive()
        detachManagerObserver()
        networkEngineMode = mode
        userDefaults.set(mode.rawValue, forKey: Self.networkEnginePreferenceKey)
        try await systemExtensionActivator.activate(identifier: mode.providerBundleIdentifier) { [weak self] in
            guard let self else { return }
            self.failureContext = .configuration
            self.systemExtensionApprovalRequired = true
        }
        try engineReconnect.checkActive()
        await deactivateOpposingNetworkEngineManagers(for: mode)
        try engineReconnect.checkActive()
        let newManager = try await loadOrCreateManager()
        try engineReconnect.checkActive()
        installManager(newManager)
        let (_, payload) = try await prepareLaunchSnapshotPayload(requestedMode: routingMode)
        try engineReconnect.checkActive()
        try await persistProviderConfiguration(routingMode, localProxy: providerLocalProxySettings, in: newManager)
        try engineReconnect.checkActive()
        return payload
    }

    func detachManagerObserver() {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
        resetManagerScopedLifecycleState()
        self.manager = nil
    }

    func waitForProviderConnectionStatus(
        _ targetStatus: NEVPNStatus,
        timeout: Duration
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if manager?.connection.status == targetStatus { return true }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    func applyNetworkEngineMode(_ mode: NetworkEngineMode) async {
        invalidateCachedManager()
        networkEngineMode = mode

        if isUIReviewMode {
            state = .disconnected
            return
        }

        userDefaults.set(mode.rawValue, forKey: Self.networkEnginePreferenceKey)
        state = .loading
        await prepare()
    }

    func loadOrCreateManager() async throws -> NEVPNManager {
        Self.runtimeLogger.info(
            "stage=loadOrCreateManager begin engine=\(self.networkEngineMode.rawValue, privacy: .public)"
        )
        try privacyConsentStore.requireCurrentConsent()
        Self.runtimeLogger.info("stage=loadExistingManager begin")
        if let existing = try await loadExistingManager() {
            Self.runtimeLogger.info("stage=loadExistingManager success result=existing")
            return existing
        }
        Self.runtimeLogger.info("stage=loadExistingManager success result=none")

        let manager: NEVPNManager = switch networkEngineMode {
        case .transparent: NETransparentProxyManager()
#if AETHERROUTE_INDEPENDENT
        case .tun: NETunnelProviderManager()
#endif
        }
        let provider = NETunnelProviderProtocol()
        provider.providerBundleIdentifier = networkEngineMode.providerBundleIdentifier
        provider.serverAddress = networkEngineMode.serverAddress
        provider.providerConfiguration = TunnelProviderConfigurationCodec.setting(
            routingMode: routingMode,
            localProxy: providerLocalProxySettings,
            enableIPv6: providerAllowsIPv6
        )
        manager.protocolConfiguration = provider
        manager.localizedDescription = AppConstants.localizedDescription
        manager.isEnabled = true
        Self.runtimeLogger.info("stage=createManager save begin")
        try await manager.saveToPreferences()
        Self.runtimeLogger.info("stage=createManager save success")
        Self.runtimeLogger.info("stage=createManager reload begin")
        try await manager.loadFromPreferences()
        Self.runtimeLogger.info("stage=createManager reload success")
        return manager
    }

    func persistProviderConfiguration(
        _ requestedMode: RoutingMode,
        localProxy: LocalProxySettings,
        in manager: NEVPNManager
    ) async throws {
        isPersistingConfiguration = true
        defer { isPersistingConfiguration = false }

        Self.runtimeLogger.info("stage=persistConfiguration reloadBeforeSave begin")
        try await manager.loadFromPreferences()
        Self.runtimeLogger.info("stage=persistConfiguration reloadBeforeSave success")
        guard let provider = manager.protocolConfiguration
            as? NETunnelProviderProtocol else {
            Self.runtimeLogger.error("stage=persistConfiguration failed reason=invalidProtocol")
            throw TunnelManagerError.invalidProtocolConfiguration
        }
        let enableIPv6 = providerAllowsIPv6
        guard TunnelProviderConfigurationCodec.requiresPersistence(
            routingMode: requestedMode,
            localProxy: localProxy,
            enableIPv6: enableIPv6,
            configuration: provider.providerConfiguration,
            isEnabled: manager.isEnabled
        ) else {
            Self.runtimeLogger.info("stage=persistConfiguration skipped reason=unchanged")
            return
        }

        guard let updatedProvider = provider.copy()
            as? NETunnelProviderProtocol else {
            throw TunnelManagerError.invalidProtocolConfiguration
        }

        updatedProvider.providerConfiguration = TunnelProviderConfigurationCodec.setting(
            routingMode: requestedMode,
            localProxy: localProxy,
            enableIPv6: enableIPv6,
            in: provider.providerConfiguration
        )
        manager.protocolConfiguration = updatedProvider
        manager.isEnabled = true
        Self.runtimeLogger.info("stage=persistConfiguration save begin")
        try await manager.saveToPreferences()
        Self.runtimeLogger.info("stage=persistConfiguration save success")
        Self.runtimeLogger.info("stage=persistConfiguration reloadAfterSave begin")
        try await manager.loadFromPreferences()
        Self.runtimeLogger.info("stage=persistConfiguration reloadAfterSave success")

        guard manager.isEnabled,
              let persistedProvider = manager.protocolConfiguration
                as? NETunnelProviderProtocol,
              TunnelProviderConfigurationCodec.isPrimaryConfiguration(
                  persistedProvider.providerConfiguration
              ),
              try TunnelProviderConfigurationCodec.routingMode(
                  from: persistedProvider.providerConfiguration
              ) == requestedMode,
              try TunnelProviderConfigurationCodec.localProxySettings(
                  from: persistedProvider.providerConfiguration
              ) == localProxy else {
            Self.runtimeLogger.error("stage=persistConfiguration failed reason=verification")
            throw TunnelManagerError.configurationDidNotPersist
        }
        Self.runtimeLogger.info("stage=persistConfiguration verification success")
    }

    var providerLocalProxySettings: LocalProxySettings {
#if AETHERROUTE_INDEPENDENT
        networkEngineMode == .tun ? localProxySettings : LocalProxySettings()
#else
        LocalProxySettings()
#endif
    }

    /// Only a profile that opts into IPv6 may have the tunnel claim `::/0`.
    /// A profile without the switch is IPv4-only, and hijacking IPv6 for it
    /// strands every flow the system prefers over IPv6 rather than letting it
    /// fall back to the IPv4 path that actually works.
    var providerAllowsIPv6: Bool {
        activeProfileSummary?.allowsIPv6 ?? false
    }

    func updateLocalProxySettings(
        _ update: (inout LocalProxySettings) -> Void
    ) {
        guard canModifyLocalProxySettings else {
            localProxySettingsMessage = AppLocalization.string(
                "Disconnect before changing the local proxy."
            )
            return
        }
        var updated = localProxySettings
        update(&updated)
        do {
            let validated = try updated.validated()
            if !isUIReviewMode {
                try localProxySettingsStore.save(validated)
            }
            localProxySettings = validated
            localProxySettingsMessage = validated.isEnabled
                ? AppLocalization.string(
                    "The loopback proxy will start with the next TUN connection."
                )
                : AppLocalization.string("The loopback proxy is off.")
        } catch {
            localProxySettingsMessage = error.localizedDescription
        }
    }

    func requireManager() async throws -> NEVPNManager {
        try privacyConsentStore.requireCurrentConsent()
        if let manager {
            Self.runtimeLogger.info("stage=requireManager source=cache")
            return manager
        }
        Self.runtimeLogger.info("stage=requireManager source=preferences")
        let loaded = try await loadOrCreateManager()
        installManager(loaded)
        observeConfigurationChanges()
        return loaded
    }

    func loadExistingManager() async throws -> NEVPNManager? {
        Self.runtimeLogger.info(
            "stage=queryManagers begin engine=\(self.networkEngineMode.rawValue, privacy: .public)"
        )
        let loaded: [NEVPNManager] = switch networkEngineMode {
        case .transparent:
            try await NETransparentProxyManager.loadAllFromPreferences().map { $0 }
#if AETHERROUTE_INDEPENDENT
        case .tun:
            try await NETunnelProviderManager.loadAllFromPreferences().map { $0 }
#endif
        }
        let matching = loaded
            .filter { manager in
                (manager.protocolConfiguration as? NETunnelProviderProtocol)?
                    .providerBundleIdentifier ==
                    networkEngineMode.providerBundleIdentifier
            }
        Self.runtimeLogger.info(
            "stage=queryManagers success total=\(loaded.count, privacy: .public) matching=\(matching.count, privacy: .public)"
        )
        guard matching.count <= 1 else {
            Self.runtimeLogger.error("stage=queryManagers failed reason=duplicates")
            throw TunnelManagerError.duplicateConfigurations
        }
        return matching.first
    }

    func deactivateOpposingNetworkEngineManagers(
        for activeMode: NetworkEngineMode
    ) async {
        do {
            let opposingManagers: [NEVPNManager] = switch activeMode {
            case .transparent:
#if AETHERROUTE_INDEPENDENT
                try await NETunnelProviderManager.loadAllFromPreferences().map { $0 }
#else
                []
#endif
#if AETHERROUTE_INDEPENDENT
            case .tun:
                try await NETransparentProxyManager.loadAllFromPreferences().map { $0 }
#endif
            }
            for opposing in opposingManagers {
                if opposing.connection.status != .disconnected && opposing.connection.status != .invalid {
                    Self.runtimeLogger.info(
                        "stage=deactivateOpposing stopVPNTunnel opposing=\(opposing.description, privacy: .public)"
                    )
                    opposing.connection.stopVPNTunnel()
                }
            }
        } catch {
            Self.runtimeLogger.error(
                "stage=deactivateOpposing failed reason=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func installManager(_ manager: NEVPNManager) {
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
        resetManagerScopedLifecycleState()
        self.manager = manager
        observeStatus()
    }

    func invalidateCachedManager() {
        invalidateConnectionRequest()
        cancelConnectionWatchdog()
        cancelDisconnectionWatchdog()
        cancelRecoveryWatchdog()
        if let statusObserver {
            NotificationCenter.default.removeObserver(statusObserver)
            self.statusObserver = nil
        }
        resetManagerScopedLifecycleState()
        manager = nil
        connectedSince = nil
        sessionRoutingMode = nil
        sessionNetworkEngineMode = nil
        clearProxySelectionRuntimeState()
    }

    func observeStatus() {
        guard statusObserver == nil, let manager else { return }
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNStatusDidChange,
            object: manager.connection,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.updateState() }
        }
    }

    func observeConfigurationChanges() {
        guard configurationObserver == nil else { return }
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .NEVPNConfigurationChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.reloadAfterConfigurationChange()
            }
        }
    }

    func reloadAfterConfigurationChange() async {
        guard !isUIReviewMode,
              !isPersistingConfiguration,
              !isReloadingConfiguration,
              !isSwitchingNetworkEngine else {
            Self.runtimeLogger.info("stage=configurationChange ignored reason=busyOrReview")
            return
        }
        Self.runtimeLogger.info("stage=configurationChange reload begin")
        isReloadingConfiguration = true
        defer { isReloadingConfiguration = false }

        do {
            guard let reloaded = try await loadExistingManager() else {
                Self.runtimeLogger.info("stage=configurationChange reload result=missing")
                invalidateCachedManager()
                state = .disconnected
                return
            }
            installManager(reloaded)
            updateState()
            Self.runtimeLogger.info("stage=configurationChange reload success")
        } catch {
            Self.runtimeLogger.error(
                "stage=configurationChange reload failed error=\(String(reflecting: error), privacy: .public)"
            )
            invalidateCachedManager()
            recordFailure(error, context: .configuration)
        }
    }

    func updateState() {
        guard let connection = manager?.connection else {
            Self.runtimeLogger.info("stage=updateState status=missing")
            if isSwitchingNetworkEngine {
                return
            }
            state = .disconnected
            connectedSince = nil
            sessionRoutingMode = nil
            sessionNetworkEngineMode = nil
            clearProxySelectionRuntimeState()
            return
        }
        let status = connection.status
        let previousProviderStatus = lastObservedProviderStatus
        if isSwitchingNetworkEngine {
            // A reconnect is a new session, not uninterrupted connectivity.
            state = .connecting
            connectedSince = nil
            lastObservedProviderStatus = status
            Self.runtimeLogger.info(
                "stage=updateState switchingNetworkEngine transientStatus=\(status.rawValue, privacy: .public)"
            )
            return
        }
        if status == .connected, previousProviderStatus != .connected {
            providerConnectionID = UUID()
            readinessVerifiedConnectionID = nil
        } else if status != .connected {
            if providerConnectionID != nil {
                // Requests belong to one connected generation. Reasserting
                // invalidates them too, even without a full disconnect.
                proxySelectionRequests = []
            }
            providerConnectionID = nil
            readinessVerifiedConnectionID = nil
        }
        lastObservedProviderStatus = status

        if readinessFailureStopPending {
            if Self.isTerminalProviderStatus(status) {
                readinessFailureStopPending = false
                cancelConnectionReadiness()
                cancelDisconnectionWatchdog()
                connectedSince = nil
                sessionRoutingMode = nil
                sessionNetworkEngineMode = nil
                clearProxySelectionRuntimeState()
                Self.runtimeLogger.info(
                    "stage=updateState readinessFailureStop completed"
                )
                return
            }
            if status == .disconnecting {
                if disconnectionAttemptID == nil {
                    // The readiness failure is our own stop request working its
                    // way through, so this terminal status is expected.
                    beginDisconnectionWatchdog(selfInitiated: true)
                }
                Self.runtimeLogger.info(
                    "stage=updateState readinessFailureStop pending"
                )
                return
            }
        }

        if TunnelLifecycleTransitionPolicy.shouldArmDisconnectionWatchdog(
            providerIsDisconnecting: status == .disconnecting,
            disconnectionAttemptPending: disconnectionAttemptID != nil
        ) {
            Self.runtimeLogger.info(
                "stage=updateState adoptingDisconnectingStatus"
            )
            // Nobody here asked for this. The provider is going down on its
            // own — killed by macOS for an unanswered IPC, or failed outright —
            // so the watchdog guards the transition but the terminal status it
            // arrives at must still count as unexpected.
            beginDisconnectionWatchdog(selfInitiated: false)
        }

        if disconnectionAttemptID != nil,
           status != .invalid,
           status != .disconnected {
            Self.runtimeLogger.info(
                "stage=updateState preservingDisconnectRequest status=\(status.rawValue, privacy: .public)"
            )
            cancelConnectionReadiness()
            state = .disconnecting
            return
        }

        let readinessGroups = activeProfileSummary.map {
            ProxyConnectionReadinessPolicy.groupsToVerify(summary: $0)
        } ?? []
        let requiresReadiness = status == .connected
            && !readinessGroups.isEmpty
            && providerConnectionID != readinessVerifiedConnectionID

        Self.runtimeLogger.info(
            "stage=updateState status=\(status.rawValue, privacy: .public)"
        )
        if ProviderTerminationPolicy.isUnexpectedTerminalState(
            currentIsTerminal: Self.isTerminalProviderStatus(status),
            previousWasActive: previousProviderStatus.map {
                Self.isActiveProviderStatus($0)
            } ?? false,
            connectionAttemptPending: connectionAttemptID != nil,
            // Only a stop this host requested makes a terminal status expected.
            // Adopting the provider's own `.disconnecting` also arms the
            // watchdog, and counting that as a pending request is what used to
            // classify a macOS-killed extension as a normal disconnect.
            disconnectionAttemptPending: disconnectionAttemptID != nil
                && disconnectionWasSelfInitiated
        ) {
            Self.runtimeLogger.error(
                "stage=updateState unexpectedTerminal status=\(status.rawValue, privacy: .public) previous=\(previousProviderStatus?.rawValue ?? -1, privacy: .public)"
            )
            handleUnexpectedProviderTermination(connection)
            return
        }
        // Once the provider reports connected its network settings are
        // installed and the tunnel already carries traffic. Holding the UI in
        // `.connecting` until the readiness probe returns made a working
        // tunnel look broken for as long as the slowest node took to answer.
        // Readiness is now a background quality signal, so surface the usable
        // connection immediately and let `connectionQuality` report the rest.
        state = switch status {
        case .invalid, .disconnected: .disconnected
        case .connecting: .connecting
        case .reasserting: .recovering
        case .connected: .connected
        case .disconnecting: .disconnecting
        @unknown default: .failed(AppLocalization.string("Unknown network extension status"))
        }
        if status == .reasserting {
            connectedSince = connection.connectedDate ?? connectedSince
        }
        connectionStage = ConnectionStagePolicy.stage(
            providerPhase: Self.providerLifecyclePhase(status),
            isVerifyingReadiness: requiresReadiness || isVerifyingProxyReadiness
        )
        if status == .connected {
            refreshOlderRoutingResourcesAfterConnection()
            cancelConnectionWatchdog()
            // The tunnel carries traffic again, so the next unexpected drop
            // starts from a full budget rather than inheriting this one's.
            if automaticReconnectAttempt != 0 {
                Self.runtimeLogger.info(
                    "stage=automaticReconnect recovered afterAttempts=\(self.automaticReconnectAttempt, privacy: .public)"
                )
                automaticReconnectAttempt = 0
            }
            cancelAutomaticReconnect(reason: "connected")
        }
        switch state {
        case .connected, .recovering, .disconnected, .failed:
            cancelConnectionWatchdog()
            cancelDisconnectionWatchdog()
        case .privacyConsentRequired, .loading, .connecting, .disconnecting:
            break
        }
        if state == .recovering {
            beginRecoveryWatchdogIfNeeded()
        } else {
            cancelRecoveryWatchdog()
        }
        if !distributionConnectionAccess.permitsNewConnection,
           state == .connecting || state == .connected || state == .recovering {
            invalidateConnectionRequest()
            cancelConnectionWatchdog()
            cancelConnectionReadiness()
            // A licensing stop is ours, and must not be undone by a reconnect.
            beginDisconnectionWatchdog(selfInitiated: true)
            manager?.connection.stopVPNTunnel()
            state = .disconnecting
            connectedSince = nil
            sessionRoutingMode = nil
            sessionNetworkEngineMode = nil
            clearProxySelectionRuntimeState()
            return
        }
        if case .failed = state, failureContext == nil {
            failureContext = .provider
        }
        if status == .connected {
            connectedSince = manager?.connection.connectedDate ?? connectedSince ?? .now
            let provider = manager?.protocolConfiguration as? NETunnelProviderProtocol
            do {
                sessionRoutingMode = try TunnelProviderConfigurationCodec.routingMode(
                    from: provider?.providerConfiguration
                )
                sessionNetworkEngineMode = NetworkEngineMode(
                    providerBundleIdentifier: provider?.providerBundleIdentifier
                )
            } catch {
                manager?.connection.stopVPNTunnel()
                connectedSince = nil
                sessionRoutingMode = nil
                sessionNetworkEngineMode = nil
                recordFailure(error, context: .configuration)
            }
            // Telemetry starts with the usable tunnel rather than waiting on
            // the quality probe, so the dashboard is live immediately.
            startTelemetryPollingIfNeeded()
            if requiresReadiness, let connectionID = providerConnectionID {
                startConnectionReadinessCheck(
                    groups: readinessGroups,
                    connectionID: connectionID
                )
            } else {
                isVerifyingProxyReadiness = false
            }
            return
        }

        cancelConnectionReadiness()
        switch state {
        case .disconnected, .failed:
            connectedSince = nil
            sessionRoutingMode = nil
            sessionNetworkEngineMode = nil
            clearProxySelectionRuntimeState()
        case .privacyConsentRequired, .loading, .connecting, .recovering, .connected,
             .disconnecting:
            break
        }
    }
}

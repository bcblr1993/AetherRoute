import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    func setRealtimeTelemetryPreferred(_ preferred: Bool, for source: String = "overview") {
        if preferred {
            realtimeTelemetrySources.insert(source)
        } else {
            realtimeTelemetrySources.remove(source)
        }
        let shouldBeRealtime = !realtimeTelemetrySources.isEmpty
        guard isRealtimeTelemetryPreferred != shouldBeRealtime else { return }
        isRealtimeTelemetryPreferred = shouldBeRealtime
        if shouldBeRealtime && state == .connected {
            Task { [weak self] in
                await self?.refreshTelemetry()
            }
        }
        restartTelemetryPolling()
    }
    func restartTelemetryPolling() {
        stopTelemetryPolling()
        startTelemetryPollingIfNeeded()
    }

    func startTelemetryPollingIfNeeded() {
        guard
            state == .connected,
            !isUIReviewMode,
            telemetryPollingTask == nil
        else { return }
        let isRealtime = isRealtimeTelemetryPreferred
        telemetryPollingTask = Task { [weak self] in
            if isRealtime {
                var secondsUntilAutomaticHealthCheck =
                    TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for: .seconds(TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds)
                        )
                    } catch {
                        break
                    }
                    guard let self, !Task.isCancelled else { break }
                    await self.refreshTelemetry()
                    secondsUntilAutomaticHealthCheck -= TunnelStartupTimingPolicy.activeTelemetryPollingIntervalSeconds
                    if secondsUntilAutomaticHealthCheck <= 0 {
                        await self.refreshAutomaticRouteHealth()
                        secondsUntilAutomaticHealthCheck =
                            TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds
                    }
                }
            } else {
                while !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for: .seconds(TunnelStartupTimingPolicy.automaticRouteHealthIntervalSeconds)
                        )
                    } catch {
                        break
                    }
                    guard let self, !Task.isCancelled else { break }
                    await self.refreshAutomaticRouteHealth()
                }
            }
        }
    }

    func stopTelemetryPolling() {
        telemetryPollingTask?.cancel()
        telemetryPollingTask = nil
    }

    func handleRuntimeEnvironmentEvent(
        _ event: RuntimeEnvironmentEvent
    ) async {
        guard !isUIReviewMode else { return }

        diagnosticEvents.record(event.diagnosticEventCode)

        switch event {
        case .systemWillSleep:
            isSystemSleeping = true
            automaticRouteFailureCounts.removeAll()
            runtimeEnvironmentResetTask?.cancel()
            runtimeEnvironmentResetTask = nil
            stopTelemetryPolling()
            Self.runtimeLogger.info("stage=handleRuntimeEnvironmentEvent sleep entered")
        case .systemDidWake:
            isSystemSleeping = false
            lastSystemWakeAt = Date()
            automaticRouteFailureCounts.removeAll()
            Self.runtimeLogger.info(
                "stage=handleRuntimeEnvironmentEvent wake entered gracePeriod=\(self.wakeGracePeriodDuration, privacy: .public)"
            )
        case .networkPathChanged:
            if isSystemSleeping {
                Self.runtimeLogger.info(
                    "stage=handleRuntimeEnvironmentEvent networkPathChanged ignored while sleeping"
                )
                return
            }
            if isInWakeGracePeriod {
                automaticRouteFailureCounts.removeAll()
            }
        }

        let decision = RuntimeEnvironmentPolicy.decision(
            for: event,
            activity: runtimeConnectionActivity
        )
        if decision.shouldPauseTelemetry {
            stopTelemetryPolling()
        }
        guard decision.shouldRefreshProviderState else { return }

        // Force the next connected-state pass to request a fresh sample. This
        // never calls startVPNTunnel and never changes routes, DNS, or proxies.
        stopTelemetryPolling()
        updateState()

        if event == .systemDidWake {
            // One successful request is enough. The provider answers it by
            // starting a converging recovery run that retries with backoff and
            // stops on its own health check. If the IPC fails transiently (e.g.
            // provider waking up or IPC timeout), retry up to 3 attempts.
            runtimeEnvironmentResetTask?.cancel()
            runtimeEnvironmentResetTask = Task { [weak self] in
                guard let self, self.state == .connected else { return }
                var lastError: Error?
                for attempt in 1...3 {
                    try? await Task.sleep(nanoseconds: attempt == 1 ? 500_000_000 : 1_000_000_000)
                    guard !Task.isCancelled, self.state == .connected else { return }
                    do {
                        let client = self.makeProxySelectionProviderClient()
                        try await client.resetNetwork()
                        Self.runtimeLogger.info(
                            "stage=handleRuntimeEnvironmentEvent resetNetwork success event=systemDidWake attempt=\(attempt, privacy: .public)"
                        )
                        return
                    } catch {
                        lastError = error
                        Self.runtimeLogger.warning(
                            "stage=handleRuntimeEnvironmentEvent resetNetwork attempt=\(attempt, privacy: .public) failed error=\(String(reflecting: error), privacy: .public)"
                        )
                    }
                }
                if let lastError {
                    Self.runtimeLogger.error(
                        "stage=handleRuntimeEnvironmentEvent resetNetwork failed error=\(String(reflecting: lastError), privacy: .public)"
                    )
                }
            }
        }
    }

    func refreshTelemetry() async {
        guard state == .connected, !Task.isCancelled else { return }
        do {
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data)
            }
            let refreshed = try await client.telemetry(
                maximumConnections: Self.telemetryConnectionLimit
            )
            telemetryUpdatedAt = .now
            telemetryViewModel.update(refreshed)
        } catch {
            // A transient provider-message failure must not disconnect a healthy
            // tunnel or replace the last truthful sample with fabricated zeros.
        }
    }

    /// Revalidates only automatic routes. When an active leaf fails, the host
    /// refreshes the delegated automatic child (or explicitly automatic
    /// selector) before retrying the parent route. Manual selections are
    /// intentionally excluded and therefore never fall back.
    func refreshAutomaticRouteHealth() async {
        guard !isSystemSleeping else { return }
        guard routingMode != .direct else { return }
        guard state == .connected,
              !Task.isCancelled,
              proxyLatencyRequests.isEmpty,
              !automaticReadinessGroupNames.isEmpty else { return }

        let client = ProxySelectionProviderClient { [weak self] data in
            guard let self else {
                throw TunnelManagerError.providerSessionUnavailable
            }
            return try await self.sendProviderMessage(
                data,
                timeout: TunnelStartupTimingPolicy
                    .automaticRouteProviderMessageTimeout
            )
        }

        for group in automaticReadinessGroupNames.sorted() {
            guard state == .connected, !Task.isCancelled else { return }
            var responsiveLatency: ProxyLatencyState?
            var recoveryAttempted = false
            for _ in 0..<TunnelStartupTimingPolicy
                .automaticRouteFailoverAttemptCount
            {
                do {
                    let latency = try await client.activeLatency(
                        group: group,
                        url: Self.selectorLatencyTestURL,
                        timeoutMilliseconds: TunnelStartupTimingPolicy
                            .selectorReadinessPerMemberTimeoutMilliseconds
                    )
                    if latency.results.count == 1,
                       latency.results[0].delayMilliseconds != nil {
                        do {
                            try await verifyCurrentRouteDataPlane()
                            responsiveLatency = latency
                            break
                        } catch {
                            try Task.checkCancellation()
                            Self.runtimeLogger.error(
                                "stage=automaticRouteHealth dataPlane unavailable"
                            )
                        }
                    }
                } catch is CancellationError {
                    return
                } catch {
                    // A missing or late reply consumes this bounded attempt.
                }

                let recovery = AutomaticRouteHealthRecoveryPolicy.action(
                    automaticChildGroup:
                        automaticReadinessChildGroups[group],
                    explicitlyAutomatic:
                        automaticProxySelectionGroups.contains(group),
                    recoveryAlreadyAttempted: recoveryAttempted
                )
                guard recovery != .none else { continue }
                recoveryAttempted = true
                do {
                    switch recovery {
                    case let .rescanAutomaticChild(childGroup):
                        let latency = try await client.latency(
                            group: childGroup,
                            url: Self.selectorLatencyTestURL,
                            timeoutMilliseconds: TunnelStartupTimingPolicy
                                .selectorReadinessPerMemberTimeoutMilliseconds
                        )
                        let responsiveCount = latency.results.lazy.filter {
                            $0.delayMilliseconds != nil
                        }.count
                        guard responsiveCount > 0 else {
                            throw TunnelManagerError.noResponsiveProxy
                        }
                        adoptProviderLatency(latency, forGroup: childGroup)
                        Self.runtimeLogger.info(
                            "stage=automaticRouteHealth childRescan responsive=\(responsiveCount, privacy: .public)"
                        )
                    case .reselectExplicitGroup:
                        guard let summary = activeProfileSummary?.proxyGroups
                            .first(where: { $0.name == group }) else {
                            throw TunnelManagerError
                                .providerSelectorUnavailable
                        }
                        _ = try await selectFastestAvailableProxy(
                            group: summary,
                            client: client
                        )
                        proxySelectionMessages[group] = nil
                        Self.runtimeLogger.info(
                            "stage=automaticRouteHealth explicitReselection success"
                        )
                    case .none:
                        break
                    }
                } catch is CancellationError {
                    return
                } catch {
                    Self.runtimeLogger.error(
                        "stage=automaticRouteHealth recoveryScan unavailable"
                    )
                }
            }

            if responsiveLatency != nil {
                let recovered = (automaticRouteFailureCounts[group] ?? 0) > 0
                automaticRouteFailureCounts[group] = nil
                updateAutomaticRouteRecoveryPresentation()
                if recovered {
                    Self.runtimeLogger.info(
                        "stage=automaticRouteHealth recovered"
                    )
                }
                Self.runtimeLogger.info(
                    "stage=automaticRouteHealth success attemptsMax=\(TunnelStartupTimingPolicy.automaticRouteFailoverAttemptCount, privacy: .public)"
                )
                continue
            }

            let previousFailures = automaticRouteFailureCounts[group] ?? 0
            let failures = previousFailures == Int.max
                ? Int.max
                : previousFailures + 1
            automaticRouteFailureCounts[group] = failures
            updateAutomaticRouteRecoveryPresentation()
            Self.runtimeLogger.error(
                "stage=automaticRouteHealth failed consecutive=\(failures, privacy: .public)"
            )
            if isInWakeGracePeriod {
                Self.runtimeLogger.info(
                    "stage=automaticRouteHealth transientFailureInGracePeriod consecutive=\(failures, privacy: .public)"
                )
                continue
            }
            guard failures
                    >= TunnelStartupTimingPolicy.automaticRouteFailureThreshold,
                  state == .connected else { continue }
            // Probe failure is route quality, not proof of a broken provider.
            // Keep monitoring even when the first readiness probe never passed.
            switch AutomaticRouteHealthRecoveryPolicy.exhaustionAction(
                connectionWasReady: readinessVerifiedConnectionID == providerConnectionID,
                isInGracePeriod: isInWakeGracePeriod
            ) {
            case .continueMonitoring:
                connectionQuality = .degraded
                Self.runtimeLogger.error(
                    "stage=automaticRouteHealth degraded action=continueMonitoring"
                )
            }
        }
    }

    func updateAutomaticRouteRecoveryPresentation() {
        isAutomaticRouteRecovering = automaticRouteFailureCounts.values
            .contains(where: { $0 > 0 })
    }

    func installReviewTelemetry() {
        let reviewNow = Date.now.timeIntervalSince1970
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS || AETHERROUTE_DEVELOPMENT_PREVIEW
        let useInvalidTimestamps = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_CONNECTION_TIMESTAMPS"
        ] == "invalid"
#else
        let useInvalidTimestamps = false
#endif
        telemetryViewModel.update(NetworkTelemetrySnapshot(
            uploadBytesPerSecond: 384_000,
            downloadBytesPerSecond: 2_480_000,
            uploadTotal: 18_430_000,
            downloadTotal: 142_700_000,
            memoryBytes: 12_240_000,
            connections: [
                ConnectionTelemetry(
                    transport: .tcp,
                    destination: "developer.apple.com",
                    destinationPort: 443,
                    uploadTotal: 148_000,
                    downloadTotal: 2_840_000,
                    startedAtUnixMilliseconds: useInvalidTimestamps
                        ? 0
                        : UInt64(max(0, reviewNow - 140) * 1_000),
                    rule: "DomainSuffix",
                    rulePayload: "apple.com",
                    proxyChain: "Balanced → Singapore Edge"
                ),
                ConnectionTelemetry(
                    transport: .udp,
                    destination: "dns.google",
                    destinationPort: 53,
                    uploadTotal: 1_240,
                    downloadTotal: 2_880,
                    startedAtUnixMilliseconds: UInt64(
                        max(0, reviewNow + (useInvalidTimestamps ? 86_400 : -10)) * 1_000
                    ),
                    rule: "Match",
                    rulePayload: "",
                    proxyChain: "DIRECT"
                ),
            ]
        ))
        telemetryUpdatedAt = .now
    }

}

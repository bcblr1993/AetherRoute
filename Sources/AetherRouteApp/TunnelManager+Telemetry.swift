import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    /// How often a surface needs traffic numbers.
    enum TelemetryDemand: Equatable {
        /// Nothing showing traffic is visible; only route health is checked.
        case none
        /// Visible, but the app is not frontmost.
        case background
        /// Visible and frontmost.
        case realtime
    }

    /// Registers what one surface needs. The strongest demand across all
    /// surfaces decides the polling cadence: 3 s, 10 s, or health checks only.
    func setTelemetryDemand(_ demand: TelemetryDemand, for source: String) {
        if demand == .realtime {
            realtimeTelemetrySources.insert(source)
        } else {
            realtimeTelemetrySources.remove(source)
        }
        if demand == .background {
            backgroundTelemetrySources.insert(source)
        } else {
            backgroundTelemetrySources.remove(source)
        }
        let cadence = TelemetryCadence.resolve(
            realtimeSources: realtimeTelemetrySources.count,
            backgroundSources: backgroundTelemetrySources.count
        )
        let shouldBeRealtime = cadence == .realtime
        let shouldBeBackground = cadence == .background
        guard isRealtimeTelemetryPreferred != shouldBeRealtime
                || isBackgroundTelemetryPreferred != shouldBeBackground
        else { return }
        let gainedCadence = (shouldBeRealtime && !isRealtimeTelemetryPreferred)
            || (shouldBeBackground && !isRealtimeTelemetryPreferred && !isBackgroundTelemetryPreferred)
        isRealtimeTelemetryPreferred = shouldBeRealtime
        isBackgroundTelemetryPreferred = shouldBeBackground
        if gainedCadence && state == .connected {
            // Coming back into view: refresh now rather than showing numbers
            // that may be minutes old until the next tick.
            Task { [weak self] in
                await self?.refreshTelemetry()
            }
        }
        restartTelemetryPolling()
    }

    func setRealtimeTelemetryPreferred(_ preferred: Bool, for source: String = "overview") {
        setTelemetryDemand(preferred ? .realtime : .none, for: source)
    }

    /// A cadence change (a page with live traffic opened or closed). Unlike
    /// a real stop it keeps the statistics baseline and does not write the
    /// ledger, so switching pages costs nothing beyond the new schedule.
    func restartTelemetryPolling() {
        cancelTelemetryPollingTask()
        startTelemetryPollingIfNeeded()
    }

    private func cancelTelemetryPollingTask() {
        telemetryPollingTask?.cancel()
        telemetryPollingTask = nil
    }

    func startTelemetryPollingIfNeeded() {
        guard
            state == .connected,
            !isUIReviewMode,
            telemetryPollingTask == nil
        else { return }
        // Statistics need a sample now and then even with no traffic view
        // open; once a minute is enough because the engine keeps exact
        // lifetime totals between samples.
        let cadence: TelemetryCadence = if isRealtimeTelemetryPreferred {
            .realtime
        } else if isBackgroundTelemetryPreferred {
            .background
        } else if isTrafficStatisticsEnabled {
            .statistics
        } else {
            .healthOnly
        }
        telemetryPollingTask = Task { [weak self] in
            var schedule = TelemetryPollingSchedule(cadence: cadence)
            while !Task.isCancelled {
                let step = schedule.next()
                do {
                    try await Task.sleep(for: .seconds(step.sleepSeconds))
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                if step.refreshesTelemetry {
                    await self.refreshTelemetry()
                }
                if step.checksRouteHealth {
                    await self.refreshAutomaticRouteHealth()
                }
            }
        }
    }

    func stopTelemetryPolling() {
        cancelTelemetryPollingTask()
        // The engine's counters are lifetime totals, so a gap between samples
        // loses nothing and an engine restart is detected from them; the
        // baseline is kept. Write what was counted so far.
        saveTrafficLedgerIfNeeded(force: true)
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
            publishTelemetry(refreshed)
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
                            .activeRouteProbeTimeoutMilliseconds
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
#if DEBUG
        telemetryViewModel.seedReviewHistory(endingAt: Date(timeIntervalSince1970: reviewNow))
#endif
#if DEBUG
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "large" {
            // 2,000 flows for measuring the Connections table.
            publishTelemetry(NetworkTelemetrySnapshot(
                uploadBytesPerSecond: 384_000,
                downloadBytesPerSecond: 2_480_000,
                uploadTotal: 18_430_000,
                downloadTotal: 142_700_000,
                memoryBytes: 12_240_000,
                connections: Self.largeReviewConnections(now: reviewNow)
            ))
            return
        }
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW_PROFILE"] == "showcase" {
            publishTelemetry(NetworkTelemetrySnapshot(
                // The same rates the seeded history ends on, so the graph
                // reads as one continuous curve.
                uploadBytesPerSecond: 384_000,
                downloadBytesPerSecond: 2_480_000,
                uploadTotal: 86_430_000,
                downloadTotal: 1_942_700_000,
                memoryBytes: 12_240_000,
                connections: Self.showcaseReviewConnections(now: reviewNow)
            ))
            return
        }
#endif
        publishTelemetry(NetworkTelemetrySnapshot(
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
                    proxyChain: "Balanced → Singapore Edge",
                    sourceAppIdentifier: "com.apple.WebKit.Networking",
                    sourceAppPath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
                ),
                ConnectionTelemetry(
                    transport: .tcp,
                    destination: "api.github.com",
                    destinationPort: 443,
                    uploadTotal: 24_000,
                    downloadTotal: 310_000,
                    startedAtUnixMilliseconds: UInt64(max(0, reviewNow - 32) * 1_000),
                    rule: "GeoSite",
                    rulePayload: "github",
                    proxyChain: "Balanced → Singapore Edge",
                    sourceAppIdentifier: "com.apple.curl",
                    sourceAppPath: "/usr/bin/curl"
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
    }

}

extension TunnelManager {
    /// Hands a sample to the telemetry view model and refreshes the
    /// automatic-group leaves derived from it.
    func publishTelemetry(_ snapshot: NetworkTelemetrySnapshot) {
        telemetryViewModel.update(snapshot)
        recordTrafficStatistics(snapshot)
        let automaticGroups = (activeProfileSummary?.proxyGroups ?? [])
            .filter { $0.strategy.lowercased() != "select" }
            .map(\.name)
        let chains = snapshot.connections.map(\.proxyChain)
        var leaves: [String: String] = [:]
        for group in automaticGroups {
            if let leaf = GroupLeafResolver.leaf(throughGroup: group, chains: chains) {
                leaves[group] = leaf
            }
        }
        if leaves != automaticGroupLeaves {
            automaticGroupLeaves = leaves
        }
    }
}

#if DEBUG
extension TunnelManager {
    /// 2,000 flows for the "large" review profile.
    static func largeReviewConnections(now: TimeInterval) -> [ConnectionTelemetry] {
        var connections: [ConnectionTelemetry] = []
        connections.reserveCapacity(2_000)
        for index in 0..<2_000 {
            let isUDP = index % 5 == 0
            let isRule = index % 2 == 0
            let age = Double(index % 3_600)
            let chain: String = index % 3 == 0 ? "DIRECT" : "Balanced → Singapore \(index % 500 + 1)"
            let started = UInt64(max(0, now - age) * 1_000)
            connections.append(ConnectionTelemetry(
                transport: isUDP ? .udp : .tcp,
                destination: "host\(index).example",
                destinationPort: isUDP ? 53 : 443,
                uploadTotal: UInt64(1_000 + index * 37),
                downloadTotal: UInt64(10_000 + index * 911),
                startedAtUnixMilliseconds: started,
                rule: isRule ? "DomainSuffix" : "Match",
                rulePayload: isRule ? "site\(index).example" : "",
                proxyChain: chain
            ))
        }
        return connections
    }

    /// Rules for the showcase screenshots, never the user's own.
    static var showcaseReviewCustomRules: [CustomRule] {
        [
            CustomRule.application(
                bundleIdentifier: "com.anthropic.claudefordesktop",
                bundlePath: "/Applications/Claude.app",
                displayName: "Claude",
                target: .proxy("Balanced")
            ),
            CustomRule.application(
                bundleIdentifier: nil,
                bundlePath: "/usr/bin/git",
                displayName: "git",
                target: .proxy("Auto")
            ),
            CustomRule.application(
                bundleIdentifier: "com.apple.WebKit.Networking",
                bundlePath: nil,
                displayName: "Safari (web)",
                target: .direct
            ),
            CustomRule(kind: .domainSuffix, value: "corp.example", target: .direct),
        ].compactMap { $0 }
    }

    /// A believable set of flows for the website's screenshots.
    static func showcaseReviewConnections(now: TimeInterval) -> [ConnectionTelemetry] {
        let flows: [(NetworkTelemetryTransport, String, UInt16, UInt64, UInt64, Double, String, String, String)] = [
            (.tcp, "rr4---sn-i3b7knld.googlevideo.com", 443, 1_820_000, 486_300_000, 412, "DomainSuffix", "youtube.com", "Streaming → Hong Kong 02"),
            (.tcp, "claude.ai", 443, 3_140_000, 18_900_000, 1_284, "DomainSuffix", "claude.ai", "Balanced → Hong Kong 01"),
            (.tcp, "api.anthropic.com", 443, 6_220_000, 41_700_000, 2_706, "DomainSuffix", "anthropic.com", "Balanced → Hong Kong 01"),
            (.tcp, "github.com", 443, 412_000, 9_860_000, 845, "GeoSite", "github", "Auto → Hong Kong 01"),
            (.tcp, "objects.githubusercontent.com", 443, 96_000, 128_400_000, 96, "GeoSite", "github", "Auto → Hong Kong 01"),
            (.tcp, "www.google.com", 443, 84_000, 1_240_000, 37, "GeoSite", "google", "Auto → Hong Kong 01"),
            (.udp, "www.youtube.com", 443, 2_410_000, 64_200_000, 380, "DomainSuffix", "youtube.com", "Streaming → Hong Kong 02"),
            (.tcp, "chatgpt.com", 443, 1_120_000, 7_480_000, 563, "DomainKeyword", "openai", "Balanced → Hong Kong 01"),
            (.tcp, "gateway.icloud.com", 443, 238_000, 1_960_000, 3_904, "DomainSuffix", "icloud.com", "DIRECT"),
            (.tcp, "swcdn.apple.com", 443, 62_000, 384_500_000, 210, "DomainSuffix", "apple.com", "DIRECT"),
            (.tcp, "www.bilibili.com", 443, 128_000, 22_600_000, 156, "DomainSuffix", "bilibili.com", "DIRECT"),
            (.udp, "dns.google", 53, 2_480, 6_120, 4, "Match", "", "Balanced → Hong Kong 01"),
            (.tcp, "192.168.1.10", 8080, 18_000, 92_000, 67, "IPCIDR", "192.168.0.0/16", "DIRECT"),
            (.tcp, "fonts.gstatic.com", 443, 21_000, 864_000, 12, "GeoSite", "google", "Auto → Hong Kong 01"),
        ]
        // The app behind each flow above, as the transparent proxy reports it.
        let apps: [(String, String)] = [
            ("com.google.Chrome.helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            ("com.anthropic.claudefordesktop", "/Applications/Claude.app/Contents/MacOS/Claude"),
            ("com.anthropic.claudefordesktop", "/Applications/Claude.app/Contents/MacOS/Claude"),
            ("com.apple.WebKit.Networking", ""),
            ("com.apple.git", "/usr/bin/git"),
            ("com.google.Chrome.helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            ("com.google.Chrome.helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
            ("com.apple.WebKit.Networking", ""),
            ("com.apple.cloudd", "/System/Library/PrivateFrameworks/CloudKitDaemon.framework/Support/cloudd"),
            ("com.apple.nsurlsessiond", "/usr/libexec/nsurlsessiond"),
            ("com.apple.WebKit.Networking", ""),
            ("", ""),
            ("com.apple.Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal"),
            ("com.google.Chrome.helper", "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"),
        ]
        return zip(flows, apps).map { flow, app in
            ConnectionTelemetry(
                transport: flow.0,
                destination: flow.1,
                destinationPort: flow.2,
                uploadTotal: flow.3,
                downloadTotal: flow.4,
                startedAtUnixMilliseconds: UInt64(max(0, now - flow.5) * 1_000),
                rule: flow.6,
                rulePayload: flow.7,
                proxyChain: flow.8,
                sourceAppIdentifier: app.0,
                sourceAppPath: app.1
            )
        }
    }
}
#endif

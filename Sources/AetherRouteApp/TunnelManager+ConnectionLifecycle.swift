import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    func makeDiagnosticReport() async throws -> Data {
        diagnosticEvents.record(.diagnosticExportRequested)
        let providerDiagnostics = await currentProviderDiagnostics()
        let summary = activeProfileSummary
        let report = DiagnosticReport(
            generatedAtUnixMilliseconds: UInt64(
                max(0, Date.now.timeIntervalSince1970 * 1_000)
            ),
            build: DiagnosticReport.Build(
                applicationVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "unknown",
                buildNumber: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String ?? "unknown",
                operatingSystemVersion:
                    ProcessInfo.processInfo.operatingSystemVersionString,
                architecture: Self.diagnosticArchitecture,
                distribution: Self.diagnosticDistribution
            ),
            session: DiagnosticReport.Session(
                state: Self.diagnosticState(for: state),
                engine: diagnosticEngine,
                routingMode: sessionRoutingMode ?? routingMode
            ),
            profile: DiagnosticReport.Profile(
                isLoaded: activeProfile != nil,
                usesSubscription: activeProfile?.subscription != nil,
                proxyCount: summary?.proxyCount ?? 0,
                proxyGroupCount: summary?.proxyGroupCount ?? 0,
                proxyProviderCount: summary?.proxyProviderCount ?? 0,
                ruleCount: summary?.ruleCount ?? 0,
                ruleProviderCount: summary?.ruleProviderCount ?? 0
            ),
            telemetry: DiagnosticReport.Telemetry(
                uploadBytesPerSecond: telemetry.uploadBytesPerSecond,
                downloadBytesPerSecond: telemetry.downloadBytesPerSecond,
                uploadTotal: telemetry.uploadTotal,
                downloadTotal: telemetry.downloadTotal,
                memoryBytes: telemetry.memoryBytes,
                activeConnectionCount: telemetry.connections.count,
                requestedConnectionLimit: Int(Self.telemetryConnectionLimit)
            ),
            provider: providerDiagnostics,
            resolver: currentResolverPrecedence(),
            events: diagnosticEvents.snapshot()
        )
        return try DiagnosticReportEncoder.encode(report)
    }

    /// Only the packet tunnel installs a resolver, so only it can be preempted.
    /// A transparent proxy leaves system DNS alone and keeps the hostname on
    /// the flow, which is why it survives a network that poisons DNS.
    func currentResolverPrecedence() -> SystemResolverPrecedence {
        guard state == .connected,
              networkEngineMode == .tun,
              !isUIReviewMode
        else { return .unavailable }
        return SystemResolverReader.precedence(
            tunnelServers: TunnelConfiguration.packetFlowDNSServers
        )
    }

    func currentProviderDiagnostics() async -> DiagnosticReport.Provider {
        guard state == .connected, !isUIReviewMode else {
            return .unavailable
        }
        do {
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(data)
            }
            return DiagnosticReport.Provider(
                isAvailable: true,
                counters: try await client.diagnostics()
            )
        } catch {
            return .unavailable
        }
    }

    func startConnectionReadinessCheck(
        groups: [ProxyGroupConfigurationSummary],
        connectionID: UUID
    ) {
        guard connectionReadinessTask == nil,
              !groups.isEmpty,
              providerConnectionID == connectionID else { return }
        isVerifyingProxyReadiness = true
        connectionQuality = .verifying
        connectionStage = .readinessCheck
        Self.runtimeLogger.info(
            "stage=connectionReadiness begin groups=\(groups.count, privacy: .public)"
        )
        connectionReadinessTask = Task { [weak self] in
            await self?.verifyConnectionReadiness(
                groups: groups,
                connectionID: connectionID
            )
        }
    }

    func verifyConnectionReadiness(
        groups: [ProxyGroupConfigurationSummary],
        connectionID: UUID
    ) async {
        defer {
            if providerConnectionID == connectionID {
                connectionReadinessTask = nil
            }
        }
        do {
            let client = ProxySelectionProviderClient { [weak self] data in
                guard let self else {
                    throw TunnelManagerError.providerSessionUnavailable
                }
                return try await self.sendProviderMessage(
                    data,
                    timeout: TunnelStartupTimingPolicy
                        .selectorReadinessProviderMessageTimeout
                )
            }
            guard let summary = activeProfileSummary else {
                throw TunnelManagerError.providerSelectorUnavailable
            }
            var selectedRoutes: [(
                group: String,
                member: String,
                behavior: ProxyConnectionReadinessPolicy.GroupBehavior,
                automaticGroup: ProxyGroupConfigurationSummary?
            )] = []
            for group in groups {
                try Task.checkCancellation()
                let explicitlyAutomatic = automaticProxySelectionGroups
                    .contains(group.name)
                let snapshot = explicitlyAutomatic
                    ? try await selectFastestAvailableProxy(
                        group: group,
                        client: client
                    )
                    : try await client.snapshot(group: group.name)
                guard let selectedMember = snapshot.selectedMember else {
                    throw TunnelManagerError.providerSelectorUnavailable
                }
                let intent = ProxyConnectionReadinessPolicy
                    .effectiveRouteIntent(
                        selectedMember: selectedMember,
                        summary: summary,
                        explicitlyAutomatic: explicitlyAutomatic
                    )
                let effectiveBehavior = intent.behavior
                let effectiveAutomaticGroup = explicitlyAutomatic
                    ? nil
                    : intent.automaticGroup
                let behaviorLabel = effectiveBehavior == .automatic
                    ? "automatic"
                    : "manual"
                let automaticChildLabel = effectiveAutomaticGroup == nil
                    ? "absent"
                    : "present"
                Self.runtimeLogger.info(
                    "stage=connectionReadiness route behavior=\(behaviorLabel, privacy: .public) automaticChild=\(automaticChildLabel, privacy: .public)"
                )
                // A leaf selection is manual and must remain pinned. A group
                // selection delegates fastest/failover choice to that core
                // strategy. In both cases the host probes only the selected
                // route through its parent selector; duplicating an automatic
                // group's full leaf health check here can race the group's own
                // startup check on large subscriptions.
                selectedRoutes.append(
                    (
                        group.name,
                        selectedMember,
                        effectiveBehavior,
                        effectiveAutomaticGroup
                    )
                )
                proxySelections[group.name] = snapshot
                if let yaml = activeProfile?.yaml {
                    try await Task.detached(priority: .utility) {
                        try ProxySelectionStore.applicationGroup()
                            .recordVerified(
                                snapshot: snapshot,
                                group: group.name,
                                profileYAML: yaml
                            )
                    }.value
                }
            }
            for selection in selectedRoutes {
                try Task.checkCancellation()
                let maximumAttempts = selection.behavior == .automatic
                    ? TunnelStartupTimingPolicy
                        .automaticRouteFailoverAttemptCount
                    : TunnelStartupTimingPolicy
                        .manualRouteReadinessAttemptCount
                var routeIsResponsive = false
                for attempt in 0..<maximumAttempts {
                    if selection.behavior == .automatic,
                       let automaticGroup = selection.automaticGroup {
                        // The selected parent delegates routing to this
                        // url-test/fallback child. Probe every child member on
                        // each bounded startup attempt so a cold-start default
                        // cannot keep retrying one dead leaf while a sibling
                        // has already recovered. This is required in both TUN
                        // and flow-only engines; their background health-task
                        // timing is intentionally not part of host readiness.
                        let latency = try await client.latency(
                            group: automaticGroup.name,
                            url: Self.selectorLatencyTestURL,
                            timeoutMilliseconds: TunnelStartupTimingPolicy
                                .selectorReadinessPerMemberTimeoutMilliseconds
                        )
                        let responsiveCount = latency.results.lazy.filter {
                            $0.delayMilliseconds != nil
                        }.count
                        Self.runtimeLogger.info(
                            "stage=connectionReadiness automaticScan attempt=\(attempt + 1, privacy: .public) results=\(latency.results.count, privacy: .public) responsive=\(responsiveCount, privacy: .public)"
                        )
                        adoptProviderLatency(latency, forGroup: automaticGroup.name)
                        if responsiveCount > 0 {
                            routeIsResponsive = true
                            break
                        }
                    } else {
                        let latency = try await client.activeLatency(
                            group: selection.group,
                            url: Self.selectorLatencyTestURL,
                            timeoutMilliseconds: TunnelStartupTimingPolicy
                                .selectorReadinessPerMemberTimeoutMilliseconds
                        )
                        if latency.results.count == 1 {
                            let result = latency.results[0]
                            let responsiveLabel = result.delayMilliseconds == nil
                                ? "false"
                                : "true"
                            Self.runtimeLogger.info(
                                "stage=connectionReadiness activeProbe attempt=\(attempt + 1, privacy: .public) resultCount=1 responsive=\(responsiveLabel, privacy: .public)"
                            )
                            if selection.behavior == .manual,
                               result.member != selection.member {
                                throw TunnelManagerError.noResponsiveProxy
                            }
                            if result.delayMilliseconds != nil {
                                adoptProviderLatency(latency, forGroup: selection.group)
                                routeIsResponsive = true
                                break
                            }
                        } else {
                            Self.runtimeLogger.info(
                                "stage=connectionReadiness activeProbe attempt=\(attempt + 1, privacy: .public) resultCount=\(latency.results.count, privacy: .public) responsive=false"
                            )
                        }
                    }
                    guard attempt + 1 < maximumAttempts else { break }
                    try await Task.sleep(
                        for: .milliseconds(
                            TunnelStartupTimingPolicy
                                .activeRouteReadinessRetryDelayMilliseconds
                        )
                    )
                }
                guard routeIsResponsive else {
                    throw TunnelManagerError.noResponsiveProxy
                }
                if groups.first?.name == selection.group {
                    _ = try? await client.select(group: "GLOBAL", member: selection.group)
                }
            }
            Self.runtimeLogger.info(
                "stage=connectionReadiness dataPlane begin"
            )
            try await verifyCurrentRouteDataPlaneForReadiness()
            Self.runtimeLogger.info(
                "stage=connectionReadiness dataPlane success"
            )
            guard providerConnectionID == connectionID else { return }
            automaticReadinessGroupNames = Set(
                selectedRoutes.compactMap { selection in
                    selection.behavior == .automatic
                        ? selection.group
                        : nil
                }
            )
            automaticReadinessChildGroups = Dictionary(
                uniqueKeysWithValues: selectedRoutes.compactMap { selection in
                    guard selection.behavior == .automatic,
                          let automaticGroup = selection.automaticGroup else {
                        return nil
                    }
                    return (selection.group, automaticGroup.name)
                }
            )
            automaticRouteFailureCounts = [:]
            readinessVerifiedConnectionID = connectionID
            isVerifyingProxyReadiness = false
            connectionQuality = .verified
            startTelemetryPollingIfNeeded()
            Self.runtimeLogger.info("stage=connectionReadiness success")
        } catch is CancellationError {
            Self.runtimeLogger.info("stage=connectionReadiness cancelled")
        } catch {
            guard providerConnectionID == connectionID else { return }
            // A failed probe means the selected route looks slow or blocked —
            // not necessarily that the tunnel is broken. Tearing it down here
            // used to kill sessions that were already carrying traffic, and on
            // a slow node it made the app impossible to connect at all.
            //
            // Distinguish the two cases with one last data-plane request. If
            // traffic still gets through, the route is merely slow: keep the
            // tunnel and mark it usable so the health monitor treats a later
            // outage as transient. If nothing gets through, leave it
            // unverified — the tunnel is fail-closed, so the health monitor
            // must stay free to stop it and give the user their direct
            // connection back rather than blackholing every request.
            Self.runtimeLogger.error(
                "stage=connectionReadiness degraded error=\(String(reflecting: error), privacy: .public)"
            )
            // Readiness measures the selected route; it must not replace it.
            // A link outage can fail this probe while the provider recovers.
            // Switching GLOBAL to DIRECT here strands proxy-only destinations
            // after the link returns and contradicts the user's pinned route.
            Self.runtimeLogger.info("stage=connectionReadiness selectedRoute preserved")
            isVerifyingProxyReadiness = false
            let outcome = ConnectionQualityPolicy.outcome(
                probeSucceeded: false,
                trafficReachesInternet:
                    await routeCarriesTrafficAfterDegradation()
            )
            guard providerConnectionID == connectionID else { return }
            connectionQuality = outcome.quality
            if outcome.marksConnectionUsable {
                readinessVerifiedConnectionID = connectionID
            }
            Self.runtimeLogger.info(
                "stage=connectionReadiness degradedTraffic carries=\(outcome.marksConnectionUsable, privacy: .public)"
            )
            startTelemetryPollingIfNeeded()
        }
    }

    /// Last-chance check used only after readiness has already been judged
    /// degraded: does the tunnel still move real traffic? Any answer at all
    /// counts, including HTTP errors — the question is reachability, not the
    /// status code.
    func routeCarriesTrafficAfterDegradation() async -> Bool {
        do {
            _ = try await currentRouteDataPlaneStatus(
                timeoutInterval: TimeInterval(
                    TunnelStartupTimingPolicy
                        .automaticRouteCandidateProbeTimeoutSeconds
                )
            )
            return true
        } catch {
            return false
        }
    }

    func cancelConnectionReadiness() {
        connectionReadinessTask?.cancel()
        connectionReadinessTask = nil
        Self.probeSession.getAllTasks { tasks in
            tasks.forEach { $0.cancel() }
        }
        isVerifyingProxyReadiness = false
        connectionQuality = .unknown
    }

    func verifyCurrentRouteDataPlane() async throws {
        let statusCode = try await currentRouteDataPlaneStatus()
        guard ProxyConnectionReadinessPolicy.acceptsProbeStatus(statusCode) else {
            throw TunnelManagerError.noResponsiveProxy
        }
    }

    func verifyCurrentRouteDataPlaneForReadiness() async throws {
        var lastError: Error = TunnelManagerError.noResponsiveProxy
        let maximumAttempts = TunnelStartupTimingPolicy
            .routeDataPlaneReadinessAttemptCount
        for attempt in 0..<maximumAttempts {
            do {
                try await verifyCurrentRouteDataPlane()
                Self.runtimeLogger.info(
                    "stage=connectionReadiness dataPlane attempt=\(attempt + 1, privacy: .public) responsive=true"
                )
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                Self.runtimeLogger.info(
                    "stage=connectionReadiness dataPlane attempt=\(attempt + 1, privacy: .public) responsive=false"
                )
                guard attempt + 1 < maximumAttempts else { break }
                try await Task.sleep(
                    for: .milliseconds(
                        TunnelStartupTimingPolicy
                            .routeReadinessRetryDelayMilliseconds
                    )
                )
            }
        }
        throw lastError
    }

    /// One shared session for every data-plane probe.
    ///
    /// A fresh `URLSession` per probe rebuilt the connection pool and repeated
    /// the TLS handshake on each health tick, which made the probe slower than
    /// the route it was measuring. Cache policy and a unique query item keep
    /// each request honest without paying that cost. The resource timeout is
    /// the outer bound for the slowest caller; individual requests still carry
    /// their own, shorter `timeoutInterval`.
    private static let probeSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest =
            TimeInterval(TunnelStartupTimingPolicy
                .automaticRouteCandidateProbeTimeoutSeconds) + 5
        configuration.timeoutIntervalForResource =
            TimeInterval(TunnelStartupTimingPolicy
                .automaticRouteCandidateProbeTimeoutSeconds) + 10
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.httpShouldSetCookies = false
        return URLSession(configuration: configuration)
    }()

    func currentRouteDataPlaneStatus(
        timeoutInterval: TimeInterval = 10
    ) async throws -> Int {
        guard var components = URLComponents(
            string: Self.defaultLatencyTestURL
        ) else {
            throw TunnelManagerError.noResponsiveProxy
        }
        components.queryItems = [
            URLQueryItem(name: "aetherroute", value: UUID().uuidString),
        ]
        guard let url = components.url else {
            throw TunnelManagerError.noResponsiveProxy
        }
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = timeoutInterval
        request.assumesHTTP3Capable = false
        request.httpMethod = "GET"
        let (_, response) = try await Self.probeSession.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TunnelManagerError.noResponsiveProxy
        }
        return http.statusCode
    }

    func resetConnectionReadiness() {
        cancelConnectionReadiness()
        if providerConnectionID != nil {
            proxySelectionRequests = []
        }
        providerConnectionID = nil
        readinessVerifiedConnectionID = nil
        readinessFailureStopPending = false
        connectionQuality = .unknown
        lastObservedProviderStatus = nil
    }

    func resetManagerScopedLifecycleState() {
        disconnectErrorLookupID = nil
        resetConnectionReadiness()
    }

    func beginConnectionRequest() -> UUID {
        let requestID = UUID()
        connectionRequestID = requestID
        Self.runtimeLogger.info("stage=connectionRequest began")
        return requestID
    }

    func invalidateConnectionRequest() {
        if connectionRequestID != nil {
            Self.runtimeLogger.info("stage=connectionRequest invalidated")
        }
        connectionRequestID = nil
    }

    func completeConnectionRequest(_ requestID: UUID) {
        guard connectionRequestID == requestID else { return }
        connectionRequestID = nil
        Self.runtimeLogger.info("stage=connectionRequest completed")
    }

    func isCurrentConnectionRequest(_ requestID: UUID) -> Bool {
        connectionRequestID == requestID
    }

    func shouldContinueConnectionPreparation(
        _ requestID: UUID
    ) -> Bool {
        TunnelLifecycleTransitionPolicy.shouldContinueConnectionPreparation(
            generationMatches: isCurrentConnectionRequest(requestID),
            hostIsConnecting: state == .connecting,
            providerPermitsStart: managerConnectionPermitsStart
        )
    }

    func handleUnexpectedProviderTermination(
        _ connection: NEVPNConnection
    ) {
        let lookupID = UUID()
        disconnectErrorLookupID = lookupID
        cancelConnectionReadiness()
        connectedSince = nil
        sessionRoutingMode = nil
        sessionNetworkEngineMode = nil
        clearProxySelectionRuntimeState()
        recordFailure(
            LocalizedConnectionError(
                message: AppLocalization.string(
                    "The network extension stopped before it became ready. Another active proxy or VPN may be using the required network channel, or the active profile may have failed. Turn off conflicting network extensions, then retry."
                )
            ),
            context: .provider
        )
        connection.fetchLastDisconnectError { [weak self] error in
            let nsError = error as NSError?
            let kind = ProviderDisconnectErrorClassifier.classify(nsError)
            let domain = nsError?.domain ?? "none"
            let code = nsError?.code ?? 0
            Task { @MainActor [weak self] in
                self?.applyDisconnectError(
                    kind,
                    domain: domain,
                    code: code,
                    lookupID: lookupID
                )
            }
        }
        scheduleAutomaticReconnect()
    }

    /// Brings the tunnel back after the provider went down on its own.
    ///
    /// macOS terminates an extension that stops answering IPC, which a blocked
    /// engine call can cause on any uplink change. Without this the host simply
    /// sat in `.failed` until the user noticed and pressed Connect — the tunnel
    /// was recoverable the whole time, nothing was trying.
    func scheduleAutomaticReconnect() {
        let attempt = automaticReconnectAttempt
        guard ProviderAutoReconnectPolicy.shouldReconnect(
            terminationWasUnexpected: true,
            userWantsConnection: userIntendsToConnect,
            attempt: attempt
        ), let delay = ProviderAutoReconnectPolicy.delay(forAttempt: attempt)
        else {
            Self.runtimeLogger.info(
                "stage=automaticReconnect declined attempt=\(attempt, privacy: .public) userIntendsToConnect=\(self.userIntendsToConnect, privacy: .public)"
            )
            return
        }
        automaticReconnectAttempt = attempt + 1
        Self.runtimeLogger.info(
            "stage=automaticReconnect scheduled attempt=\(attempt, privacy: .public) delaySeconds=\(delay, privacy: .public)"
        )
        automaticReconnectTask?.cancel()
        automaticReconnectTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await self?.performAutomaticReconnect(attempt: attempt)
        }
    }

    func performAutomaticReconnect(attempt: Int) async {
        // Re-checked after the delay: the user may have disconnected, or the
        // provider may have recovered on its own, while this was waiting.
        guard userIntendsToConnect else {
            Self.runtimeLogger.info(
                "stage=automaticReconnect abandoned attempt=\(attempt, privacy: .public) reason=userNoLongerWantsConnection"
            )
            return
        }
        guard !isEnabled else {
            Self.runtimeLogger.info(
                "stage=automaticReconnect abandoned attempt=\(attempt, privacy: .public) reason=alreadyActive"
            )
            return
        }
        Self.runtimeLogger.info(
            "stage=automaticReconnect attempting attempt=\(attempt, privacy: .public)"
        )
        await setEnabled(true, isAutomaticReconnect: true)
        // `setEnabled` can bail out before reaching the provider — the host may
        // still be transitioning, or licensing may refuse a new connection — and
        // nothing calls back in that case. A start that *was* submitted leaves
        // the tunnel connecting, and a later failure re-enters through
        // `handleUnexpectedProviderTermination`, so only re-arm when neither
        // happened.
        if !isEnabled {
            scheduleAutomaticReconnect()
        }
    }

    func cancelAutomaticReconnect(reason: String) {
        guard automaticReconnectTask != nil else { return }
        Self.runtimeLogger.info(
            "stage=automaticReconnect cancelled reason=\(reason, privacy: .public)"
        )
        automaticReconnectTask?.cancel()
        automaticReconnectTask = nil
    }

    func applyDisconnectError(
        _ kind: ProviderDisconnectErrorKind,
        domain: String,
        code: Int,
        lookupID: UUID
    ) {
        guard disconnectErrorLookupID == lookupID else {
            Self.runtimeLogger.info(
                "stage=disconnectError ignored reason=stale"
            )
            return
        }
        disconnectErrorLookupID = nil
        Self.runtimeLogger.error(
            "stage=disconnectError resolved domain=\(domain, privacy: .public) code=\(code, privacy: .public) classification=\(String(describing: kind), privacy: .public)"
        )
        guard kind == .competingNetworkExtension else { return }
        diagnosticEvents.record(.networkExtensionConflict)
        failureContext = .provider
        state = .failed(
            AppLocalization.string(
                "Another network extension is already controlling this traffic. Turn off the conflicting proxy or VPN extension, then retry."
            )
        )
    }

    static func isTerminalProviderStatus(_ status: NEVPNStatus) -> Bool {
        status == .invalid || status == .disconnected
    }

    /// Narrows the provider status to the phases the stage policy reasons
    /// about, so the policy itself stays free of NetworkExtension types.
    static func providerLifecyclePhase(
        _ status: NEVPNStatus?
    ) -> ProviderLifecyclePhase {
        switch status {
        case nil, .invalid, .disconnected, .disconnecting: .inactive
        case .connecting, .reasserting: .starting
        case .connected: .established
        @unknown default: .inactive
        }
    }

    static func isActiveProviderStatus(_ status: NEVPNStatus) -> Bool {
        switch status {
        case .connecting, .connected, .reasserting, .disconnecting:
            true
        case .invalid, .disconnected:
            false
        @unknown default:
            true
        }
    }

    func waitForProviderToBecomeInactive(
        timeout: Duration = .seconds(20)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            guard let status = manager?.connection.status else { return true }
            if Self.isTerminalProviderStatus(status) {
                updateState()
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    func waitForConnectionToSettle(
        timeout: Duration = TunnelStartupTimingPolicy
            .hostConnectionWatchdogTimeout
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if state == .connected { return true }
            if case .failed = state { return false }
            do {
                try await Task.sleep(for: .milliseconds(100))
            } catch {
                return false
            }
        }
        return false
    }

    func recordFailure(
        _ error: Error,
        context: ConnectionFailureContext
    ) {
        Self.runtimeLogger.error(
            "stage=recordFailure context=\(String(describing: context), privacy: .public) error=\(String(reflecting: error), privacy: .public)"
        )
        invalidateConnectionRequest()
        cancelConnectionWatchdog()
        cancelDisconnectionWatchdog()
        cancelRecoveryWatchdog()
        failureContext = context
        state = .failed(localizedConnectionError(error).localizedDescription)
    }

    /// A provider that never reaches a terminal Network Extension state must
    /// not leave the host UI in an unbounded ``Connecting`` state. The
    /// watchdog is armed only after configuration and runtime resources have
    /// been persisted, immediately before the OS start request.
    func beginConnectionWatchdog() {
        cancelConnectionWatchdog()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        Self.runtimeLogger.info(
            "stage=connectionWatchdog armed timeoutSeconds=\(TunnelStartupTimingPolicy.hostConnectionWatchdogTimeoutSeconds, privacy: .public)"
        )
        connectionWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TunnelStartupTimingPolicy.hostConnectionWatchdogTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.connectionWatchdogFired(attemptID)
        }
    }

    func cancelConnectionWatchdog() {
        if connectionWatchdogTask != nil {
            Self.runtimeLogger.info("stage=connectionWatchdog cancelled")
        }
        connectionWatchdogTask?.cancel()
        connectionWatchdogTask = nil
        connectionAttemptID = nil
    }

    /// - Parameter selfInitiated: `true` when this host asked the provider to
    ///   stop. `false` when the provider reported `.disconnecting` on its own —
    ///   the watchdog still guards the transition, but the stop is not ours and
    ///   the terminal status it leads to must be treated as unexpected.
    func beginDisconnectionWatchdog(selfInitiated: Bool) {
        cancelDisconnectionWatchdog()
        let attemptID = UUID()
        disconnectionAttemptID = attemptID
        disconnectionWasSelfInitiated = selfInitiated
        Self.runtimeLogger.info(
            "stage=disconnectionWatchdog armed selfInitiated=\(selfInitiated, privacy: .public) timeoutSeconds=\(TunnelStartupTimingPolicy.hostDisconnectionWatchdogTimeoutSeconds, privacy: .public)"
        )
        disconnectionWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TunnelStartupTimingPolicy
                        .hostDisconnectionWatchdogTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.disconnectionWatchdogFired(attemptID)
        }
    }

    func cancelDisconnectionWatchdog() {
        if disconnectionWatchdogTask != nil {
            Self.runtimeLogger.info(
                "stage=disconnectionWatchdog cancelled"
            )
        }
        disconnectionWatchdogTask?.cancel()
        disconnectionWatchdogTask = nil
        disconnectionAttemptID = nil
        disconnectionWasSelfInitiated = false
    }

    func disconnectionWatchdogFired(_ attemptID: UUID) {
        guard disconnectionAttemptID == attemptID else {
            Self.runtimeLogger.info(
                "stage=disconnectionWatchdog ignored reason=stale"
            )
            return
        }
        if readinessFailureStopPending, case .failed = state {
            let status = manager?.connection.status
            if status.map(Self.isTerminalProviderStatus) == true {
                cancelDisconnectionWatchdog()
                readinessFailureStopPending = false
                return
            }
            Self.runtimeLogger.error(
                "stage=disconnectionWatchdog fired reason=readinessFailureStop"
            )
            manager?.connection.stopVPNTunnel()
            cancelDisconnectionWatchdog()
            return
        }
        guard case .disconnecting = state else {
            Self.runtimeLogger.info(
                "stage=disconnectionWatchdog ignored reason=stateChanged"
            )
            return
        }
        Self.runtimeLogger.error("stage=disconnectionWatchdog fired")
        reconcileDisconnectionStatus()
        let resolution = TunnelLifecycleTransitionPolicy
            .disconnectionWatchdogResolution(
                hostIsDisconnectingAfterReconciliation: state == .disconnecting
            )
        guard resolution == .timedOut else {
            cancelDisconnectionWatchdog()
            return
        }
        cancelDisconnectionWatchdog()
        recordFailure(
            LocalizedConnectionError(
                message: AppLocalization.string(
                    "The network extension did not finish stopping. Wait a moment, then retry; macOS will update the status when shutdown completes."
                )
            ),
            context: .provider
        )
    }

    func reconcileDisconnectionStatus() {
        guard let status = manager?.connection.status else {
            state = .disconnected
            return
        }
        Self.runtimeLogger.info(
            "stage=reconcileDisconnection status=\(status.rawValue, privacy: .public)"
        )
        if status == .invalid || status == .disconnected {
            updateState()
        } else {
            state = .disconnecting
        }
    }

    func connectionWatchdogFired(_ attemptID: UUID) {
        guard connectionAttemptID == attemptID,
              case .connecting = state else {
            Self.runtimeLogger.info("stage=connectionWatchdog ignored reason=stale")
            return
        }
        Self.runtimeLogger.error("stage=connectionWatchdog fired")
        cancelConnectionWatchdog()
        manager?.connection.stopVPNTunnel()
        invalidateCachedManager()
        recordFailure(
            LocalizedConnectionError(
                message: AppLocalization.string(
                    "The network extension stopped before it could report ready. Retry once, then review the active profile."
                )
            ),
            context: .provider
        )
    }

    func beginRecoveryWatchdogIfNeeded() {
        guard recoveryWatchdogTask == nil else { return }
        let attemptID = UUID()
        recoveryAttemptID = attemptID
        Self.runtimeLogger.info(
            "stage=recoveryWatchdog armed timeoutSeconds=\(TunnelStartupTimingPolicy.hostRecoveryWatchdogTimeoutSeconds, privacy: .public)"
        )
        recoveryWatchdogTask = Task { [weak self] in
            do {
                try await Task.sleep(
                    for: TunnelStartupTimingPolicy.hostRecoveryWatchdogTimeout
                )
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.recoveryWatchdogFired(attemptID)
        }
    }

    func cancelRecoveryWatchdog() {
        if recoveryWatchdogTask != nil {
            Self.runtimeLogger.info("stage=recoveryWatchdog cancelled")
        }
        recoveryWatchdogTask?.cancel()
        recoveryWatchdogTask = nil
        recoveryAttemptID = nil
    }

    func recoveryWatchdogFired(_ attemptID: UUID) {
        guard recoveryAttemptID == attemptID,
              case .recovering = state else {
            Self.runtimeLogger.info("stage=recoveryWatchdog ignored reason=stale")
            return
        }
        Self.runtimeLogger.error(
            "stage=recoveryWatchdog fired tunnelStuckInRecovery attempting restart"
        )
        cancelRecoveryWatchdog()
        Task { [weak self] in
            guard let self else { return }
            await self.setEnabled(false)
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self.setEnabled(true)
        }
    }

    func localizedConnectionError(_ error: Error) -> Error {
        if error is BundledRoutingResourceError {
            return LocalizedConnectionError(
                message: AppLocalization.string(
                    "The routing databases included with this app could not be verified. Reinstall AetherRoute and try again."
                )
            )
        }
        if (error as? ActiveProfileStoreError) == .appGroupUnavailable {
            return LocalizedConnectionError(
                message: AppLocalization.string(
                    "AetherRoute could not access its shared storage. Quit and reopen the app, then try again. If the problem continues, export diagnostics."
                )
            )
        }
        if let keyError = error as? ProfileKeyStoreError {
            let message: String
            switch keyError {
            case .keyNotFound:
                message = AppLocalization.string(
                    "The encryption key for saved profiles is unavailable. Export a report from Settings > Diagnostics for troubleshooting."
                )
            case .invalidKeyLength:
                message = AppLocalization.string(
                    "The profile encryption key is invalid. Export a report from Settings > Diagnostics for troubleshooting."
                )
            case .randomGenerationFailed:
                message = AppLocalization.string(
                    "A profile encryption key could not be created. Quit and reopen AetherRoute, then try again. If the problem continues, export diagnostics."
                )
            case .securityError:
                message = AppLocalization.string(
                    "AetherRoute could not access the profile encryption key in Keychain. Quit and reopen the app, then try again. If the problem continues, export diagnostics."
                )
            }
            return LocalizedConnectionError(message: message)
        }
        if let accessGroupError = error as? KeychainAccessGroupResolutionError {
            switch accessGroupError {
            case .missingInfoValue, .emptyValue, .unresolvedBuildSetting,
                 .unexpectedSuffix, .invalidValue:
                return LocalizedConnectionError(
                    message: AppLocalization.string(
                        "AetherRoute's Keychain access configuration is invalid. Reinstall AetherRoute and try again."
                    )
                )
            }
        }
        guard let resourceError = error as? RoutingResourceError else {
            return error
        }
        let message: String
        switch resourceError {
        case let .missing(kind):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ is required by this profile. Add it in Profiles before connecting."
                ),
                kind.fileName
            )
        case let .stale(kind, _):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ is more than 30 days old. Update it in Profiles before connecting."
                ),
                kind.fileName
            )
        case let .checksumMismatch(kind),
             let .invalidResourceFormat(kind),
             let .metadataDateInFuture(kind),
             let .metadataEncodingFailed(kind),
             let .metadataUnreadable(kind),
             let .metadataTooLarge(kind),
             let .metadataMismatch(kind):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ failed validation. Replace it in Profiles before connecting."
                ),
                kind.fileName
            )
        case let .resourceTooSmall(kind, _),
             let .resourceTooLarge(kind, _):
            message = String.localizedStringWithFormat(
                AppLocalization.string(
                    "%@ has an invalid size. Replace it in Profiles before connecting."
                ),
                kind.fileName
            )
        case .writeFailed:
            message = AppLocalization.string(
                "Routing rules could not be saved. Check available disk space and try again."
            )
        case .temporaryCleanupFailed:
            message = AppLocalization.string(
                "Temporary routing rule files could not be cleaned up. Check available disk space and try again."
            )
        case .rollbackFailed:
            message = AppLocalization.string(
                "The routing rule update could not be restored. Recovery files were kept. Export diagnostics if retrying does not help."
            )
        default:
            message = AppLocalization.string(
                "Routing resources could not be prepared securely. Review them in Profiles before connecting."
            )
        }
        return LocalizedConnectionError(message: message)
    }

}

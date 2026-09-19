import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    func refreshProxySelection(group groupName: String) async {
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: nil
        )
    }

    func selectProxy(group groupName: String, member: String) async {
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: member
        )
    }

    var canCycleManualProxySelection: Bool {
        guard let group = preferredManualProxyGroupForCycling else {
            return false
        }
        let members = proxySelections[group.name]?.members ?? group.members
        return members.count > 1
            && !proxySelectionRequests.contains(group.name)
    }

    func cycleManualProxySelection(
        _ direction: ProxySelectionCyclePolicy.Direction
    ) async {
        guard let group = preferredManualProxyGroupForCycling,
              !proxySelectionRequests.contains(group.name) else {
            return
        }
        let snapshot = proxySelections[group.name]
        let members = snapshot?.members ?? group.members
        guard let member = ProxySelectionCyclePolicy.adjacentMember(
            members: members,
            selectedMember: snapshot?.selectedMember,
            direction: direction
        ) else {
            return
        }
        await performProxySelectionRequest(
            group: group.name,
            requestedMember: member
        )
    }

    func setProxySelectionAutomatic(
        group groupName: String,
        isAutomatic: Bool
    ) async {
        guard let group = activeProfileSummary?.proxyGroups.first(where: {
            $0.name == groupName
                && $0.strategy.caseInsensitiveCompare("select") == .orderedSame
        }), group.memberCount > 1, let yaml = activeProfile?.yaml else { return }

        let previous = automaticProxySelectionGroups.contains(groupName)
        guard previous != isAutomatic else { return }
        let key = automaticProxySelectionPreferenceKey(
            profileYAML: yaml,
            group: groupName
        )
        userDefaults.set(isAutomatic, forKey: key)
        if isAutomatic {
            automaticProxySelectionGroups.insert(groupName)
        } else {
            automaticProxySelectionGroups.remove(groupName)
            automaticReadinessGroupNames.remove(groupName)
            automaticReadinessChildGroups[groupName] = nil
            automaticRouteFailureCounts[groupName] = nil
            updateAutomaticRouteRecoveryPresentation()
            proxySelectionMessages[groupName] = nil
            return
        }

        guard isConnected else {
            proxySelectionMessages[groupName] = nil
            return
        }

        do {
            let client = makeProxySelectionProviderClient()
            _ = try await selectFastestAvailableProxy(
                group: group,
                client: client
            )
            automaticReadinessGroupNames.insert(groupName)
            proxySelectionMessages[groupName] = nil
        } catch {
            userDefaults.set(previous, forKey: key)
            automaticProxySelectionGroups.remove(groupName)
            proxySelectionMessages[groupName] = AppLocalization.string(
                "No proxy node in this group passed the automatic connection check."
            )
        }
    }

    func makeProxySelectionProviderClient()
        -> ProxySelectionProviderClient
    {
        ProxySelectionProviderClient { [weak self] data in
            guard let self else {
                throw TunnelManagerError.providerSessionUnavailable
            }
            return try await self.sendProviderMessage(
                data,
                timeout: TunnelStartupTimingPolicy
                    .automaticRouteProviderMessageTimeout
            )
        }
    }

    @discardableResult
    func selectFastestAvailableProxy(
        group: ProxyGroupConfigurationSummary,
        client: ProxySelectionProviderClient
    ) async throws -> ProxySelectionState {
        let previous = try await client.snapshot(group: group.name)
        let latency = try await client.latency(
            group: group.name,
            url: Self.selectorLatencyTestURL,
            timeoutMilliseconds: TunnelStartupTimingPolicy
                .selectorReadinessPerMemberTimeoutMilliseconds
        )
        adoptProviderLatency(latency, forGroup: group.name)
        let responsiveMembers = Set(
            latency.results.compactMap { result in
                result.delayMilliseconds == nil ? nil : result.member
            }
        )
        let candidates = ProxyConnectionReadinessPolicy
            .orderedRouteCandidates(
                selectedMember: previous.selectedMember,
                summaryMembers: group.members,
                snapshotMembers: previous.members,
                latency: latency
            )
            .filter(responsiveMembers.contains)
        guard !candidates.isEmpty else {
            throw TunnelManagerError.noResponsiveProxy
        }

        var measurements: [
            ProxyConnectionReadinessPolicy.ProbeMeasurement
        ] = []
        do {
            for candidate in candidates {
                try Task.checkCancellation()
                let candidateDelay = UInt64(
                    latency.results.first(where: {
                        $0.member == candidate
                    })?.delayMilliseconds ?? .max
                )
                do {
                    let selected = try await client.select(
                        group: group.name,
                        member: candidate
                    )
                    guard selected.selectedMember == candidate else {
                        throw TunnelManagerError.providerSelectorUnavailable
                    }
                } catch {
                    try Task.checkCancellation()
                    measurements.append(.init(
                        member: candidate,
                        elapsedMilliseconds: candidateDelay,
                        statusCode: nil
                    ))
                    continue
                }
                do {
                    let statusCode = try await currentRouteDataPlaneStatus(
                        timeoutInterval: TimeInterval(
                            TunnelStartupTimingPolicy
                                .automaticRouteCandidateProbeTimeoutSeconds
                        )
                    )
                    measurements.append(.init(
                        member: candidate,
                        elapsedMilliseconds: candidateDelay,
                        statusCode: statusCode
                    ))
                    // Candidates share one provider latency batch and are
                    // sorted fastest first. Once the first real 204 succeeds,
                    // every faster candidate has already failed its data-plane
                    // check; probing slower siblings would only delay
                    // connection.
                    if ProxyConnectionReadinessPolicy.acceptsProbeStatus(
                        statusCode
                    ) {
                        break
                    }
                } catch {
                    try Task.checkCancellation()
                    measurements.append(.init(
                        member: candidate,
                        elapsedMilliseconds: candidateDelay,
                        statusCode: nil
                    ))
                }
            }

            try Task.checkCancellation()
            guard let winner = ProxyConnectionReadinessPolicy
                .fastestSuccessfulProbe(measurements) else {
                throw TunnelManagerError.noResponsiveProxy
            }

            let snapshot = try await client.select(
                group: group.name,
                member: winner.member
            )
            guard snapshot.selectedMember == winner.member else {
                throw TunnelManagerError.providerSelectorUnavailable
            }
            Self.runtimeLogger.info(
                "stage=automaticRouteSelection success candidates=\(candidates.count, privacy: .public) verified=\(measurements.lazy.filter { ProxyConnectionReadinessPolicy.acceptsProbeStatus($0.statusCode) }.count, privacy: .public)"
            )
            proxySelections[group.name] = snapshot
            if let yaml = activeProfile?.yaml {
                try await Task.detached(priority: .utility) {
                    try ProxySelectionStore.applicationGroup().recordVerified(
                        snapshot: snapshot,
                        group: group.name,
                        profileYAML: yaml
                    )
                }.value
            }
            return snapshot
        } catch {
            let selectionError = error
            if let previousMember = previous.selectedMember {
                do {
                    proxySelections[group.name] = try await client.select(
                        group: group.name,
                        member: previousMember
                    )
                    Self.runtimeLogger.info(
                        "stage=automaticRouteSelection rollback success"
                    )
                } catch {
                    Self.runtimeLogger.error(
                        "stage=automaticRouteSelection rollback failed"
                    )
                }
            }
            throw selectionError
        }
    }

    func performProxySelectionRequest(
        group groupName: String,
        requestedMember: String?
    ) async {
        guard let group = selectableProxyGroup(named: groupName),
              !proxySelectionRequests.contains(groupName) else {
            return
        }
        if state != .connected {
            await performOfflineProxySelectionRequest(
                group: group,
                requestedMember: requestedMember
            )
            return
        }
        proxySelectionRequests.insert(groupName)
        let connectionID = providerConnectionID
        Self.runtimeLogger.debug(
            "stage=proxySelection request operation=\(requestedMember == nil ? "snapshot" : "select", privacy: .public)"
        )
        proxySelectionMessages[groupName] = nil
        defer {
            if providerConnectionID == connectionID {
                proxySelectionRequests.remove(groupName)
            }
        }

        do {
            let snapshot: ProxySelectionState
            if isUIReviewMode {
                snapshot = try reviewSelectionSnapshot(
                    group: group,
                    requestedMember: requestedMember
                )
            } else {
                let client = ProxySelectionProviderClient { [weak self] data in
                    guard let self else {
                        throw TunnelManagerError.providerSessionUnavailable
                    }
                    return try await self.sendProviderMessage(data, for: connectionID)
                }
                if let requestedMember {
                    let previous = try await client.snapshot(group: groupName)
                    let candidate = try await client.select(
                        group: groupName,
                        member: requestedMember
                    )
                    do {
                        guard let summary = activeProfileSummary else {
                            throw TunnelManagerError
                                .providerSelectorUnavailable
                        }
                        let latency = try await client.activeLatency(
                            group: groupName,
                            url: Self.selectorLatencyTestURL,
                            timeoutMilliseconds: TunnelStartupTimingPolicy
                                .selectorReadinessPerMemberTimeoutMilliseconds
                        )
                        guard ProxySelectionHotSwitchPolicy.accepts(
                            requestedMember: requestedMember,
                            summary: summary,
                            latency: latency
                        ) else {
                            throw TunnelManagerError.noResponsiveProxy
                        }
                        try await verifyCurrentRouteDataPlane()
                        adoptProviderLatency(latency, forGroup: groupName)
                        snapshot = candidate
                        if let summary = activeProfileSummary,
                           ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary).first?.name == groupName {
                            _ = try? await client.select(group: "GLOBAL", member: groupName)
                        }
                    } catch {
                        if let previousMember = previous.selectedMember,
                           previousMember != requestedMember {
                            do {
                                let restored = try await client.select(
                                    group: groupName,
                                    member: previousMember
                                )
                                proxySelections[groupName] = restored
                                Self.runtimeLogger.info(
                                    "stage=proxySelection hotSwitch rollback success"
                                )
                            } catch {
                                Self.runtimeLogger.error(
                                    "stage=proxySelection hotSwitch rollback failed"
                                )
                            }
                        }
                        throw TunnelManagerError.noResponsiveProxy
                    }
                } else {
                    snapshot = try await client.snapshot(group: groupName)
                }
            }

            guard state == .connected, providerConnectionID == connectionID
            else { return }
            proxySelections[groupName] = snapshot
            if let selectedMember = snapshot.selectedMember,
               let summary = activeProfileSummary {
                let intent = ProxyConnectionReadinessPolicy
                    .effectiveRouteIntent(
                        selectedMember: selectedMember,
                        summary: summary,
                        explicitlyAutomatic: automaticProxySelectionGroups
                            .contains(groupName)
                    )
                if intent.behavior == .automatic {
                    automaticReadinessGroupNames.insert(groupName)
                    automaticReadinessChildGroups[groupName] =
                        intent.automaticGroup?.name
                } else {
                    automaticReadinessGroupNames.remove(groupName)
                    automaticReadinessChildGroups[groupName] = nil
                    automaticRouteFailureCounts[groupName] = nil
                    updateAutomaticRouteRecoveryPresentation()
                }
            }
            Self.runtimeLogger.debug(
                "stage=proxySelection success members=\(snapshot.members.count, privacy: .public) selected=\(snapshot.selectedMember == nil ? "none" : "present", privacy: .public)"
            )
            guard !isUIReviewMode,
                  snapshot.selectedMember != nil,
                  let yaml = activeProfile?.yaml else {
                return
            }
            do {
                try await Task.detached(priority: .utility) {
                    try ProxySelectionStore.applicationGroup()
                        .recordVerified(
                            snapshot: snapshot,
                            group: groupName,
                            profileYAML: yaml
                        )
                }.value
            } catch {
                // The runtime selection remains truthful even if durable
                // storage fails. Surface the persistence failure instead of
                // pretending the choice will survive the next start.
                proxySelectionMessages[groupName] = localizedProxySelectionError(
                    error
                )
            }
        } catch {
            guard state == .connected, providerConnectionID == connectionID
            else { return }
            Self.runtimeLogger.error(
                "stage=proxySelection failed error=\(String(reflecting: error), privacy: .public)"
            )
            proxySelectionMessages[groupName] = error.localizedDescription
        }
    }

    func performOfflineProxySelectionRequest(
        group: ProxyGroupConfigurationSummary,
        requestedMember: String?
    ) async {
        let mayEdit: Bool = switch state {
        case .disconnected, .failed: true
        case .privacyConsentRequired, .loading, .connecting, .recovering, .connected,
             .disconnecting: false
        }
        guard mayEdit, canModifyProfiles,
              let profileYAML = activeProfile?.yaml else { return }
        proxySelectionRequests.insert(group.name)
        proxySelectionMessages[group.name] = nil
        defer { proxySelectionRequests.remove(group.name) }

        do {
            if isUIReviewMode {
                proxySelections[group.name] = try reviewSelectionSnapshot(
                    group: group,
                    requestedMember: requestedMember
                )
                return
            }
            let store = try ProxySelectionStore.applicationGroup()
            if let requestedMember {
                try await Task.detached(priority: .userInitiated) {
                    try store.recordUserSelection(
                        group: group.name,
                        member: requestedMember,
                        allowedMembers: group.members,
                        profileYAML: profileYAML
                    )
                }.value
            }
            let persisted = try await Task.detached(priority: .utility) {
                try store.selections(forProfileYAML: profileYAML)
            }.value
            let selected = InitialProxySelectionPolicy.selections(
                persisted: persisted,
                summary: activeProfileSummary ?? ProfileConfigurationInspector
                    .inspect(yaml: profileYAML)
            )[group.name]
            proxySelections[group.name] = ProxySelectionState(
                selectedMember: selected,
                members: group.members
            )
            Self.runtimeLogger.debug(
                "stage=proxySelection offline success selected=\(selected == nil ? "none" : "present", privacy: .public)"
            )
        } catch {
            Self.runtimeLogger.error(
                "stage=proxySelection offline failed error=\(String(reflecting: error), privacy: .public)"
            )
            proxySelectionMessages[group.name] = localizedProxySelectionError(
                error
            )
        }
    }

    func localizedProxySelectionError(_ error: Error) -> String {
        if error is ProfileKeyStoreError || error is ProxySelectionStoreError {
            return AppLocalization.string(
                "The selected node could not be saved securely."
            )
        }
        return error.localizedDescription
    }

    func selectableProxyGroup(
        named name: String
    ) -> ProxyGroupConfigurationSummary? {
        activeProfileSummary?.proxyGroups.first {
            $0.name == name
                && $0.strategy.lowercased() == "select"
        }
    }

    var preferredManualProxyGroupForCycling:
        ProxyGroupConfigurationSummary? {
        activeProfileSummary?.proxyGroups.first {
            $0.strategy.caseInsensitiveCompare("select") == .orderedSame
                && $0.memberCount > 1
                && !automaticProxySelectionGroups.contains($0.name)
        }
    }

    func reviewSelectionSnapshot(
        group: ProxyGroupConfigurationSummary,
        requestedMember: String?
    ) throws -> ProxySelectionState {
        guard !group.members.isEmpty else {
            throw TunnelManagerError.providerSelectorUnavailable
        }
        if let requestedMember, !group.members.contains(requestedMember) {
            throw ProxySelectionProviderClientError.selectionNotApplied
        }
        let selected = requestedMember
            ?? proxySelections[group.name]?.selectedMember
            ?? group.members.first
        return ProxySelectionState(
            selectedMember: selected,
            members: group.members
        )
    }

    func sendProviderMessage(
        _ data: Data,
        for connectionID: UUID?
    ) async throws -> Data {
        guard state == .connected, providerConnectionID == connectionID else {
            throw TunnelManagerError.providerSessionUnavailable
        }
        return try await sendProviderMessage(data)
    }

    func sendProviderMessage(
        _ data: Data,
        timeout: Duration = .seconds(5)
    ) async throws -> Data {
        guard state == .connected
                || (state == .connecting && isVerifyingProxyReadiness),
              let session = manager?.connection as? NETunnelProviderSession,
              session.status == .connected else {
            throw TunnelManagerError.providerSessionUnavailable
        }

        Self.runtimeLogger.debug(
            "stage=providerMessage hostSend begin bytes=\(data.count, privacy: .public)"
        )
        let connectionID = providerConnectionID
        let replyHolder = ProviderMessageReplyHolder()
        do {
            let response = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation {
                    (continuation: CheckedContinuation<Data, Error>) in
                    let reply = ProviderMessageReply(continuation)
                    replyHolder.reply = reply
                    do {
                        try session.sendProviderMessage(data) { response in
                            reply.receive(response)
                        }
                    } catch {
                        reply.fail(error)
                    }
                    reply.startTimeout(after: timeout)
                }
            } onCancel: {
                replyHolder.cancel()
            }
            guard providerConnectionID == connectionID,
                  manager?.connection === session,
                  session.status == .connected else {
                throw TunnelManagerError.providerSessionUnavailable
            }
            Self.runtimeLogger.debug(
                "stage=providerMessage hostSend success bytes=\(response.count, privacy: .public)"
            )
            return response
        } catch {
            Self.runtimeLogger.error(
                "stage=providerMessage hostSend failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
    }

    func clearProxySelectionRuntimeState() {
        stopTelemetryPolling()
        connectionQuality = .unknown
        automaticReadinessGroupNames = []
        automaticReadinessChildGroups = [:]
        automaticRouteFailureCounts = [:]
        isAutomaticRouteRecovering = false
        proxySelections = [:]
        proxySelectionMessages = [:]
        proxySelectionRequests = []
        proxyLatencies = [:]
        proxyLatencyRequests = []
        memberLatencyRequests = []
        latencyIndex = ProxyLatencyIndex()
        latencyIndexToken = nil
        pendingLatencyFlush = []
        lastLatencyFlushAt = nil
        telemetryViewModel.reset()
        telemetryUpdatedAt = nil
    }

}

private final class ProviderMessageReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?

    init(_ continuation: CheckedContinuation<Data, Error>) {
        self.continuation = continuation
    }

    func receive(_ data: Data?) {
        guard let data else {
            fail(TunnelManagerError.providerReplyMissing)
            return
        }
        finish(.success(data))
    }

    func fail(_ error: Error) {
        finish(.failure(error))
    }

    func cancel() {
        finish(.failure(CancellationError()))
    }

    func startTimeout(after timeout: Duration) {
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: timeout)
            fail(TunnelManagerError.providerMessageTimedOut)
        }
    }

    private func finish(_ result: Result<Data, Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, Error>? in
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}

private final class ProviderMessageReplyHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var _reply: ProviderMessageReply?

    var reply: ProviderMessageReply? {
        get { lock.withLock { _reply } }
        set { lock.withLock { _reply = newValue } }
    }

    func cancel() {
        let current = lock.withLock { () -> ProviderMessageReply? in
            defer { _reply = nil }
            return _reply
        }
        current?.cancel()
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

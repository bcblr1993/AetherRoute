import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    /// Rereads a group's selection from the provider. The Proxies page asks
    /// on every visit; a group read moments ago on the same connection is
    /// skipped, because each read updates several published values and so
    /// redraws the whole window while the page is still appearing.
    func refreshProxySelection(group groupName: String, now: Date = .now) async {
        if state == .connected,
           let last = proxySelectionRefreshedAt[groupName],
           last.connectionID == providerConnectionID,
           now.timeIntervalSince(last.at) < Self.proxySelectionRefreshInterval {
            return
        }
        if state != .connected, proxySelections[groupName] != nil {
            return
        }
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: nil
        )
        if state == .connected {
            proxySelectionRefreshedAt[groupName] = (providerConnectionID, now)
        }
    }

    static let proxySelectionRefreshInterval: TimeInterval = 10

    /// A node picked by the person. In failover mode it becomes the
    /// preferred node; a group picking the fastest node ignores the pick.
    func selectProxy(group groupName: String, member: String) async {
        switch proxySelectionMode(for: groupName) {
        case .manual: break
        case .fastest: return
        case .failover:
            await setPreferredProxy(group: groupName, member: member)
            return
        }
        await performProxySelectionRequest(
            group: groupName,
            requestedMember: member
        )
    }

    var globalProxyGroup: ProxyGroupConfigurationSummary? {
        guard let summary = activeProfileSummary else { return nil }
        let globalName = ProxyConnectionReadinessPolicy.globalGroupName
        let snapshotMembers = proxySelections[globalName]?.members ?? []
        let fallbackMembers = InitialProxySelectionPolicy.globalMembers(summary: summary)
        var seen: Set<String> = []
        var merged: [String] = []
        for member in snapshotMembers + fallbackMembers where seen.insert(member).inserted {
            merged.append(member)
        }
        guard !merged.isEmpty else { return nil }
        return ProxyGroupConfigurationSummary(
            id: -1,
            name: globalName,
            strategy: "select",
            memberCount: merged.count,
            members: merged
        )
    }

    var canCycleManualProxySelection: Bool {
        guard let group = preferredManualProxyGroupForCycling else {
            return false
        }
        let members = (proxySelections[group.name]?.members ?? group.members)
            .filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }
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
        let members = (snapshot?.members ?? group.members)
            .filter { !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }
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

    /// Streams readiness probes across all leaf route candidates in `group`
    /// without the 64-member `client.latency(group:)` cap, skipping nested
    /// strategy groups and subscription notice pseudo-nodes.
    func probeRouteCandidatesLatency(
        group: ProxyGroupConfigurationSummary,
        snapshotMembers: [String],
        groupNames: Set<String>
    ) async -> ProxyLatencyState {
        var seen: Set<String> = []
        var probeMembers: [String] = []
        for member in snapshotMembers + group.members
        where InitialProxySelectionPolicy.isRouteCandidate(member)
            && !groupNames.contains(member)
            && seen.insert(member).inserted {
            probeMembers.append(member)
        }
        guard !probeMembers.isEmpty else {
            return ProxyLatencyState(results: [])
        }
        let timeoutMilliseconds = TunnelStartupTimingPolicy
            .selectorReadinessPerMemberTimeoutMilliseconds
        let probeClient = makeLatencyProbeProviderClient(
            timeoutMilliseconds: timeoutMilliseconds
        )
        let maxConcurrent = 8
        var delaysByMember: [String: UInt32?] = [:]
        delaysByMember.reserveCapacity(probeMembers.count)

        await withTaskGroup(
            of: (member: String, delay: UInt32?).self
        ) { taskGroup in
            var iterator = probeMembers.makeIterator()
            var activeCount = 0

            while activeCount < maxConcurrent, let member = iterator.next() {
                activeCount += 1
                taskGroup.addTask {
                    let delay = try? await probeClient.displayLatency(
                        member: member,
                        url: Self.selectorLatencyTestURL,
                        timeoutMilliseconds: timeoutMilliseconds
                    ).delayMilliseconds
                    return (member, delay)
                }
            }

            while let result = await taskGroup.next() {
                delaysByMember[result.member] = result.delay
                if Task.isCancelled {
                    taskGroup.cancelAll()
                    break
                }
                if let nextMember = iterator.next() {
                    taskGroup.addTask {
                        let delay = try? await probeClient.displayLatency(
                            member: nextMember,
                            url: Self.selectorLatencyTestURL,
                            timeoutMilliseconds: timeoutMilliseconds
                        ).delayMilliseconds
                        return (nextMember, delay)
                    }
                }
            }
        }

        let results = probeMembers.map { member in
            ProxyLatencyResult(
                member: member,
                delayMilliseconds: delaysByMember[member] ?? nil
            )
        }
        return ProxyLatencyState(results: results)
    }

    /// Selects the fastest node that passes a real 204 probe. With a
    /// preferred node (failover mode) that node is tried first and wins
    /// whenever it passes.
    @discardableResult
    func selectFastestAvailableProxy(
        group: ProxyGroupConfigurationSummary,
        client: ProxySelectionProviderClient,
        preferredMember: String? = nil
    ) async throws -> ProxySelectionState {
        let previous = try await client.snapshot(group: group.name)
        let groupNames = Set((activeProfileSummary?.proxyGroups ?? []).map(\.name))
        let latency = await probeRouteCandidatesLatency(
            group: group,
            snapshotMembers: previous.members,
            groupNames: groupNames
        )
        adoptProviderLatency(latency, forGroup: group.name)
        let responsiveMembers = Set(
            latency.results.compactMap { result in
                result.delayMilliseconds == nil ? nil : result.member
            }
        )
        let candidates = ProxyFailoverPolicy.orderedCandidates(
            ProxyConnectionReadinessPolicy
                .orderedRouteCandidates(
                    selectedMember: previous.selectedMember,
                    summaryMembers: group.members,
                    snapshotMembers: previous.members,
                    latency: latency,
                    groupNames: groupNames
                )
                .filter(responsiveMembers.contains),
            preferred: preferredMember
        )
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
                    // Only the catch-all group's node carries the 204
                    // request; another group's candidate is accepted on its
                    // provider probe, which it has already passed.
                    let statusCode = isCatchAllRouteGroup(group.name)
                        ? try await currentRouteDataPlaneStatus(
                            timeoutInterval: TimeInterval(
                                TunnelStartupTimingPolicy
                                    .automaticRouteCandidateProbeTimeoutSeconds
                            )
                        )
                        : 204
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
        let isPassiveSnapshot = requestedMember == nil
        guard let group = selectableProxyGroup(named: groupName),
              !proxySelectionRequests.contains(groupName),
              !(isPassiveSnapshot && proxySnapshotRefreshRequests.contains(groupName)) else {
            return
        }
        if state != .connected {
            await performOfflineProxySelectionRequest(
                group: group,
                requestedMember: requestedMember
            )
            return
        }
        if isPassiveSnapshot {
            proxySnapshotRefreshRequests.insert(groupName)
        } else {
            proxySelectionRequests.insert(groupName)
        }
        let connectionID = providerConnectionID
        Self.runtimeLogger.debug(
            "stage=proxySelection request operation=\(requestedMember == nil ? "snapshot" : "select", privacy: .public)"
        )
        if !isPassiveSnapshot, proxySelectionMessages[groupName] != nil {
            proxySelectionMessages[groupName] = nil
        }
        defer {
            if isPassiveSnapshot {
                proxySnapshotRefreshRequests.remove(groupName)
            } else if providerConnectionID == connectionID {
                proxySelectionRequests.remove(groupName)
            }
        }

        let previousSelectionState = proxySelections[groupName]
        let previousSelectedMember = previousSelectionState?.selectedMember
        if let requestedMember {
            let baseMembers = previousSelectionState?.members ?? group.members
            let optimisticState = ProxySelectionState(
                selectedMember: requestedMember,
                members: baseMembers.contains(requestedMember)
                    ? baseMembers
                    : baseMembers + [requestedMember]
            )
            if proxySelections[groupName] != optimisticState {
                proxySelections[groupName] = optimisticState
            }
            let aggregated = latencyIndex.aggregateChildGroups(
                selectedMembers: latencySelectedMembers
            )
            if !aggregated.isEmpty {
                publishLatency(groups: aggregated, force: true)
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
                    let priorMember: String?
                    if let previousSelectedMember {
                        priorMember = previousSelectedMember
                    } else {
                        priorMember = (try? await client.snapshot(group: groupName))?.selectedMember
                    }
                    snapshot = try await client.select(
                        group: groupName,
                        member: requestedMember
                    )
                    let globalName = ProxyConnectionReadinessPolicy.globalGroupName
                    if groupName != globalName, shouldSyncGlobalSelector(to: groupName) {
                        if let globalSnapshot = try? await client.select(
                            group: globalName,
                            member: groupName
                        ), proxySelections[globalName] != nil {
                            proxySelections[globalName] = globalSnapshot
                        }
                    }
                    if priorMember != requestedMember {
                        Task { @MainActor [weak self] in
                            guard let self,
                                  self.state == .connected,
                                  self.providerConnectionID == connectionID else { return }
                            await self.closeConnectionsAfterProxySwitch(
                                group: groupName,
                                previousMember: priorMember,
                                newMember: requestedMember
                            )
                        }
                    }
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        await self.refreshSelectedMemberDisplayLatency(
                            group: groupName,
                            member: requestedMember,
                            connectionID: connectionID
                        )
                    }
                } else {
                    snapshot = try await client.snapshot(group: groupName)
                }
            }

            guard state == .connected, providerConnectionID == connectionID
            else { return }
            let didChangeSelection = proxySelections[groupName] != snapshot
            if didChangeSelection {
                proxySelections[groupName] = snapshot
            }
            let aggregated = latencyIndex.aggregateChildGroups(
                selectedMembers: latencySelectedMembers
            )
            if !aggregated.isEmpty {
                publishLatency(groups: aggregated, force: true)
            }
            if isPassiveSnapshot, proxySelectionMessages[groupName] != nil {
                proxySelectionMessages[groupName] = nil
            }
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
                    let childGroup = intent.automaticGroup?.name
                    if automaticReadinessChildGroups[groupName] != childGroup {
                        automaticReadinessChildGroups[groupName] = childGroup
                    }
                } else {
                    let hadAutomaticState = automaticReadinessGroupNames.contains(groupName)
                        || automaticReadinessChildGroups[groupName] != nil
                        || automaticRouteFailureCounts[groupName] != nil
                    if hadAutomaticState {
                        automaticReadinessGroupNames.remove(groupName)
                        automaticReadinessChildGroups[groupName] = nil
                        automaticRouteFailureCounts[groupName] = nil
                        updateAutomaticRouteRecoveryPresentation()
                    }
                }
            }
            Self.runtimeLogger.debug(
                "stage=proxySelection success members=\(snapshot.members.count, privacy: .public) selected=\(snapshot.selectedMember == nil ? "none" : "present", privacy: .public)"
            )
            guard !isUIReviewMode,
                  (!isPassiveSnapshot || didChangeSelection || previousSelectionState != snapshot),
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
            if !isPassiveSnapshot {
                if let previousSelectionState {
                    proxySelections[groupName] = previousSelectionState
                } else {
                    proxySelections.removeValue(forKey: groupName)
                }
                let aggregated = latencyIndex.aggregateChildGroups(
                    selectedMembers: latencySelectedMembers
                )
                if !aggregated.isEmpty {
                    publishLatency(groups: aggregated, force: true)
                }
            }
            Self.runtimeLogger.error(
                "stage=proxySelection failed error=\(String(reflecting: error), privacy: .public)"
            )
            proxySelectionMessages[groupName] = error.localizedDescription
        }
    }

    private func shouldSyncGlobalSelector(to groupName: String) -> Bool {
        guard let summary = activeProfileSummary else { return false }
        let customGroupNames = Set(activeProfileOverrides.groups.map(\.name))
        let primary = summary.primaryOutboundGroup(excluding: customGroupNames)
            ?? ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary).first?.name
        guard primary == groupName else { return false }
        let currentGlobal = proxySelections[ProxyConnectionReadinessPolicy.globalGroupName]?.selectedMember
        return currentGlobal == nil
            || currentGlobal?.caseInsensitiveCompare("DIRECT") == .orderedSame
            || currentGlobal == groupName
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
        let isPassiveSnapshot = requestedMember == nil
        if isPassiveSnapshot {
            proxySnapshotRefreshRequests.insert(group.name)
        } else {
            proxySelectionRequests.insert(group.name)
            if proxySelectionMessages[group.name] != nil {
                proxySelectionMessages[group.name] = nil
            }
        }
        defer {
            if isPassiveSnapshot {
                proxySnapshotRefreshRequests.remove(group.name)
            } else {
                proxySelectionRequests.remove(group.name)
            }
        }

        do {
            if isUIReviewMode {
                let updated = try reviewSelectionSnapshot(
                    group: group,
                    requestedMember: requestedMember
                )
                if proxySelections[group.name] != updated {
                    proxySelections[group.name] = updated
                }
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
            let summary = activeProfileSummary ?? ProfileConfigurationInspector
                .inspect(yaml: profileYAML)
            let customGroupNames = Set(activeProfileOverrides.groups.map(\.name))
            let includeGlobal = group.name == ProxyConnectionReadinessPolicy.globalGroupName
            let selected = InitialProxySelectionPolicy.selections(
                persisted: persisted,
                summary: summary,
                includeGlobal: includeGlobal,
                excludingCustomGroups: customGroupNames
            )[group.name]
            let newState = ProxySelectionState(
                selectedMember: selected,
                members: group.members
            )
            if proxySelections[group.name] != newState {
                proxySelections[group.name] = newState
            }
            let aggregated = latencyIndex.aggregateChildGroups(
                selectedMembers: latencySelectedMembers
            )
            if !aggregated.isEmpty {
                publishLatency(groups: aggregated, force: true)
            }
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

    /// Whether the catch-all rule routes through this group, so the
    /// external 204 probe actually passes through its node.
    func isCatchAllRouteGroup(_ groupName: String) -> Bool {
        guard let summary = activeProfileSummary else { return true }
        return ProxyConnectionReadinessPolicy.groupsToVerify(summary: summary)
            .first?.name == groupName
    }

    func selectableProxyGroup(
        named name: String
    ) -> ProxyGroupConfigurationSummary? {
        if name == ProxyConnectionReadinessPolicy.globalGroupName {
            return globalProxyGroup
        }
        return activeProfileSummary?.proxyGroups.first {
            $0.name == name
                && $0.strategy.lowercased() == "select"
        }
    }

    var preferredManualProxyGroupForCycling:
        ProxyGroupConfigurationSummary? {
        let isEligible: (ProxyGroupConfigurationSummary) -> Bool = { group in
            group.strategy.caseInsensitiveCompare("select") == .orderedSame
                && group.members.filter({ !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }).count > 1
                && !self.automaticProxySelectionGroups.contains(group.name)
        }
        if routingMode == .global,
           let global = globalProxyGroup,
           isEligible(global) {
            return global
        }
        guard let summary = activeProfileSummary else { return nil }
        let customGroupNames = Set(activeProfileOverrides.groups.map(\.name))
        if let primaryName = summary.primaryOutboundGroup(excluding: customGroupNames),
           let primaryGroup = summary.proxyGroups.first(where: { $0.name == primaryName }),
           isEligible(primaryGroup) {
            return primaryGroup
        }
        return summary.proxyGroups.first(where: isEligible)
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
        timeout: Duration = TunnelStartupTimingPolicy.standardProviderMessageTimeout
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
            consecutiveProviderUnresponsiveCount = 0
            return response
        } catch {
            if let tunnelError = error as? TunnelManagerError,
               tunnelError == .providerReplyMissing || tunnelError == .providerMessageTimedOut,
               ProviderMessageClass.of(messageData: data).countsTowardUnresponsiveProvider {
                consecutiveProviderUnresponsiveCount += 1
            }
            if error is CancellationError {
                Self.runtimeLogger.debug(
                    "stage=providerMessage hostSend cancelled"
                )
            } else {
                Self.runtimeLogger.error(
                    "stage=providerMessage hostSend failed error=\(String(reflecting: error), privacy: .public) consecutiveUnresponsive=\(self.consecutiveProviderUnresponsiveCount, privacy: .public)"
                )
            }
            throw error
        }
    }

    func clearProxySelectionRuntimeState() {
        consecutiveProviderUnresponsiveCount = 0
        latencyMeasuredAt = [:]
        stopTelemetryPolling()
        connectionQuality = .unknown
        automaticReadinessGroupNames = []
        automaticReadinessChildGroups = [:]
        automaticRouteFailureCounts = [:]
        isAutomaticRouteRecovering = false
        failoverRecoveryTracker.resetAll()
        failoverRecoveryScannedAt = [:]
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
        MenuBarTrafficController.shared.reset()
        automaticGroupLeaves = [:]
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

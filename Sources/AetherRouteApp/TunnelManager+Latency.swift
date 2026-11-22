import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    static var effectiveUILatencyTimeoutMilliseconds: UInt32 {
        max(uiLatencyTimeoutMilliseconds, 5_000)
    }

    public func isTestingLatency(group groupName: String, member memberName: String? = nil) -> Bool {
        if let memberName {
            return memberLatencyRequests.contains("\(groupName):\(memberName)")
                || proxyLatencyRequests.contains(groupName)
        }
        return proxyLatencyRequests.contains(groupName)
    }

    func latencyGroupsSnapshot() -> [(name: String, members: [String])] {
        var groups = (activeProfileSummary?.proxyGroups ?? []).map { group in
            (
                name: group.name,
                members: proxySelections[group.name]?.members ?? group.members
            )
        }
        if let globalGroup = globalProxyGroup,
           !groups.contains(where: { $0.name == globalGroup.name }) {
            groups.insert(
                (
                    name: globalGroup.name,
                    members: proxySelections[globalGroup.name]?.members ?? globalGroup.members
                ),
                at: 0
            )
        }
        return groups
    }

    private func hasLatencyTestableGroup(
        named groupName: String,
        containing memberName: String? = nil
    ) -> Bool {
        latencyGroupsSnapshot().contains { entry in
            guard entry.name == groupName else { return false }
            if let memberName {
                return entry.members.contains(memberName)
            }
            return true
        }
    }

    /// Rebuilds the reverse index for a run and returns its token.
    @discardableResult
    func prepareLatencyIndex() -> LatencyRunToken? {
        let token = currentLatencyRunToken
        if token != latencyIndexToken {
            latencyIndex = ProxyLatencyIndex()
            latencyIndexToken = token
            // Groups queued against the discarded index would otherwise be
            // flushed from the new one and publish empty rows.
            pendingLatencyFlush.removeAll(keepingCapacity: true)
            lastLatencyFlushAt = nil
        }
        latencyIndex.beginRun(
            groups: latencyGroupsSnapshot(),
            testURL: Self.defaultLatencyTestURL,
            selectedMembers: latencySelectedMembers
        )
        return token
    }

    /// Publishing every arriving result reassigns a `@Published` dictionary
    /// and invalidates the node list once per node. Coalescing into ~100 ms
    /// windows keeps the list visibly streaming while bounding main-actor work
    /// to the number of windows rather than the number of nodes.
    private static let latencyFlushInterval = Duration.milliseconds(100)

    func publishLatency(
        groups dirty: some Sequence<String>,
        force: Bool
    ) {
        pendingLatencyFlush.formUnion(dirty)
        guard !pendingLatencyFlush.isEmpty else { return }
        let now = ContinuousClock.now
        if !force,
           let last = lastLatencyFlushAt,
           now - last < Self.latencyFlushInterval {
            if latencyFlushTask == nil {
                latencyFlushTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: Self.latencyFlushInterval)
                    } catch { return }
                    guard let self, !self.pendingLatencyFlush.isEmpty else { return }
                    self.latencyFlushTask = nil
                    self.flushPendingLatency()
                }
            }
            return
        }
        latencyFlushTask?.cancel()
        latencyFlushTask = nil
        flushPendingLatency()
    }

    func flushPendingLatency() {
        lastLatencyFlushAt = ContinuousClock.now
        let aggregated = latencyIndex.aggregateChildGroups(
            selectedMembers: latencySelectedMembers
        )
        pendingLatencyFlush.formUnion(aggregated)
        guard !pendingLatencyFlush.isEmpty else { return }

        var nextLatencies = proxyLatencies
        var nextDates = latencyMeasuredAt
        for group in pendingLatencyFlush {
            nextLatencies[group] = latencyIndex.state(for: group)
            nextDates[group] = latencyIndex.measurementDates(for: group)
        }
        if nextLatencies != proxyLatencies {
            proxyLatencies = nextLatencies
        }
        if nextDates != latencyMeasuredAt {
            latencyMeasuredAt = nextDates
        }
        pendingLatencyFlush.removeAll(keepingCapacity: true)
    }

    /// Records one measurement in every group that lists the member, skipping
    /// any group currently running an isolated single-member probe for that member.
    func recordLatency(
        member: String,
        measurement: ProxyLatencyMeasurement,
        runToken: LatencyRunToken?,
        force: Bool = false
    ) {
        guard runToken == currentLatencyRunToken else { return }
        if !memberLatencyRequests.isEmpty {
            let listingGroups = latencyIndex.groups(containing: member)
            let blockedGroups = listingGroups.filter {
                memberLatencyRequests.contains("\($0):\(member)")
            }
            if !blockedGroups.isEmpty {
                let allowed = listingGroups.filter { !blockedGroups.contains($0) }
                for group in allowed {
                    latencyIndex.recordDirect(
                        member: member,
                        measurement: measurement,
                        in: group
                    )
                }
                if !allowed.isEmpty {
                    publishLatency(groups: allowed, force: force)
                }
                return
            }
        }
        let affected = latencyIndex.merge(
            member: member,
            measurement: measurement
        )
        publishLatency(groups: affected, force: force)
    }

    /// Records a single-member probe result without disturbing an active group
    /// sweep in another group that happens to share the same member.
    private func recordSingleMemberLatency(
        member: String,
        measurement: ProxyLatencyMeasurement,
        group groupName: String,
        runToken: LatencyRunToken?
    ) {
        guard runToken == currentLatencyRunToken else { return }
        let listingGroups = latencyIndex.groups(containing: member)
        let hasActiveOtherSweep = listingGroups.contains {
            $0 != groupName && proxyLatencyRequests.contains($0)
        }
        if hasActiveOtherSweep {
            latencyIndex.recordDirect(
                member: member,
                measurement: measurement,
                in: groupName
            )
            publishLatency(groups: [groupName], force: true)
        } else {
            recordLatency(
                member: member,
                measurement: measurement,
                runToken: runToken,
                force: true
            )
        }
    }

    /// Whether a row's number came from the protocol core rather than a bare
    /// TCP handshake.
    func latencyConfidence(
        group groupName: String,
        member memberName: String
    ) -> ProxyLatencyConfidence {
        if isUIReviewMode {
            // The visual matrix has to exercise both badges, so the seeded
            // selected member reads as verified.
            return proxySelections[groupName]?.selectedMember == memberName
                ? .verified
                : .reachability
        }
        return latencyIndex.isVerified(member: memberName, in: groupName)
            ? .verified
            : .reachability
    }

    /// Readiness and route recovery use a stricter, different destination.
    /// Their results must never overwrite a user-facing latency test.
    func adoptProviderLatency(
        _ latency: ProxyLatencyState,
        forGroup groupName: String
    ) {
        prepareLatencyIndex()
        latencyIndex.recordRouteHealth(latency, group: groupName)
    }

    var latencySelectedMembers: [String: String] {
        proxySelections.compactMapValues(\.selectedMember)
            .merging(automaticGroupLeaves) { _, leaf in leaf }
    }

    func refreshProxyLatencyIfNeeded(group groupName: String) async {
        guard state == .connected, !Task.isCancelled, !isUIReviewMode else { return }
        prepareLatencyIndex()
        guard latencyIndex.needsRefresh(group: groupName) else { return }
        await testProxyLatency(group: groupName)
    }

    static func uiReviewMeasurement(
        member: String,
        index: Int
    ) -> ProxyLatencyMeasurement {
        if member.uppercased() == "DIRECT" { return .reachable(3) }
        if index == 2 { return .timedOut }
        return .reachable(UInt32(28 + index * 32))
    }

    func testProxyLatency(group groupName: String) async {
        guard hasLatencyTestableGroup(named: groupName),
              !proxyLatencyRequests.contains(groupName) else {
            return
        }
        let memberPrefix = "\(groupName):"
        let overlappingKeys = memberLatencyRequests.filter { $0.hasPrefix(memberPrefix) }
        for key in overlappingKeys {
            memberLatencyRequests.remove(key)
            if let memberToken = activeMemberLatencyTokens.removeValue(forKey: key) {
                activeLatencyRunTasks.removeValue(forKey: memberToken)?.cancel()
            }
        }
        let epoch = latencyRuntimeEpoch
        let batchToken = UUID()
        let runToken = prepareLatencyIndex()
        proxyLatencyRequests.insert(groupName)
        let snapshotMembers = latencyGroupsSnapshot()
            .first(where: { $0.name == groupName })?
            .members ?? []
        Self.runtimeLogger.info(
            "stage=proxyLatency request members=\(snapshotMembers.count, privacy: .public)"
        )
        proxySelectionMessages[groupName] = nil
        latencyIndex.clear(group: groupName)
        // Clearing to `nil` rather than an empty state is deliberate: rows
        // fall back to "testing" while the run is in flight, and a run that
        // produces nothing leaves the group unmeasured so the menu's
        // first-open probe retries it instead of treating a failure as a
        // measured result.
        proxyLatencies[groupName] = nil
        defer {
            activeLatencyRunTasks.removeValue(forKey: batchToken)
            if latencyRuntimeEpoch == epoch {
                proxyLatencyRequests.remove(groupName)
            }
        }

        let batchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let members = snapshotMembers.filter {
                !InitialProxySelectionPolicy.isSubscriptionMetadata($0)
            }

            if self.isUIReviewMode {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled, self.latencyRuntimeEpoch == epoch else { return }
                for (index, member) in members.enumerated() {
                    self.recordLatency(
                        member: member,
                        measurement: Self.uiReviewMeasurement(
                            member: member,
                            index: index
                        ),
                        runToken: runToken
                    )
                }
                self.publishLatency(groups: [groupName], force: true)
                return
            }

            if self.state == .connected {
                switch await self.measureVerifiedLatencyOutcome(
                    group: groupName,
                    members: members,
                    runToken: runToken
                ) {
                case .completed:
                    guard !Task.isCancelled,
                          runToken == self.currentLatencyRunToken,
                          self.latencyRuntimeEpoch == epoch else { return }
                    let aggregated = self.latencyIndex.aggregateChildGroups(selectedMembers: self.latencySelectedMembers)
                    self.publishLatency(groups: aggregated.union([groupName]), force: true)
                    let measured = self.proxyLatencies[groupName]?.results ?? []
                    Self.runtimeLogger.info(
                        "stage=proxyLatency success results=\(measured.count, privacy: .public) responsive=\(measured.lazy.filter { $0.delayMilliseconds != nil }.count, privacy: .public)"
                    )
                    return
                case let .failed(error):
                    guard !Task.isCancelled,
                          runToken == self.currentLatencyRunToken,
                          self.latencyRuntimeEpoch == epoch else { return }
                    Self.runtimeLogger.error(
                        "stage=proxyLatency providerFailed group=\(groupName, privacy: .public) fallingBackToReachability=false error=\(String(reflecting: error), privacy: .public)"
                    )
                    self.proxySelectionMessages[groupName] = self.localizedLatencyProbeError(error)
                    self.latencyIndex.clear(group: groupName)
                    self.proxyLatencies[groupName] = nil
                    self.latencyMeasuredAt[groupName] = nil
                    return
                case .unsupportedSelector:
                    guard !Task.isCancelled,
                          runToken == self.currentLatencyRunToken,
                          self.latencyRuntimeEpoch == epoch else { return }
                    Self.runtimeLogger.error(
                        "stage=proxyLatency providerUnsupportedSelector group=\(groupName, privacy: .public) fallingBackToReachability=true"
                    )
                }
            }

            guard !Task.isCancelled,
                  runToken == self.currentLatencyRunToken,
                  self.latencyRuntimeEpoch == epoch else { return }

            // Offline / unsupported selector fallback: resolve nested child
            // groups down to their active leaves and run bare TCP reachability.
            let offlineTargets = self.resolvedOfflineProbeTargets(for: members)
            let probeTargets = Set(self.latencyIndex.probeTargets)
            await self.measureReachability(
                members: offlineTargets.leaves.filter(probeTargets.contains),
                runToken: runToken
            )
            guard !Task.isCancelled,
                  runToken == self.currentLatencyRunToken,
                  self.latencyRuntimeEpoch == epoch else { return }
            let aggregated = self.latencyIndex.aggregateChildGroups(selectedMembers: offlineTargets.selections)
            self.publishLatency(groups: aggregated.union([groupName]), force: true)

            let measured = self.proxyLatencies[groupName]?.results ?? []
            Self.runtimeLogger.info(
                "stage=proxyLatency offlineSuccess results=\(measured.count, privacy: .public) responsive=\(measured.lazy.filter { $0.delayMilliseconds != nil }.count, privacy: .public)"
            )

            // Upgrade the selected member to a verified number if possible.
            await self.verifySelectedMemberLatency(
                group: groupName,
                runToken: runToken
            )
        }
        activeLatencyRunTasks[batchToken] = batchTask
        await withTaskCancellationHandler {
            await batchTask.value
        } onCancel: {
            batchTask.cancel()
        }
    }

    func makeLatencyProbeProviderClient(
        timeoutMilliseconds: UInt32 = TunnelManager.effectiveUILatencyTimeoutMilliseconds
    ) -> ProxySelectionProviderClient {
        let messageTimeout = Duration.milliseconds(
            Int(timeoutMilliseconds) + 2_000
        )
        return ProxySelectionProviderClient { [weak self] data in
            guard let self else {
                throw TunnelManagerError.providerSessionUnavailable
            }
            return try await self.sendProviderMessage(
                data,
                timeout: messageTimeout
            )
        }
    }

    /// Probes one member or child strategy group through the protocol core's
    /// real outbound handler (`selector_active_url_test`).
    ///
    /// Unlike `client.latency(group:)`, which blocks behind a group-wide
    /// `FuturesOrdered::collect` barrier and rejects any group above the
    /// 64-member readiness cap, `activeLatency` measures a single outbound (or
    /// resolves a nested group to its active leaf) and returns as soon as that
    /// one node finishes.
    private static func probeVerifiedMemberLatency(
        member: String,
        client: ProxySelectionProviderClient,
        timeoutMilliseconds: UInt32 = TunnelManager.effectiveUILatencyTimeoutMilliseconds
    ) async throws -> ProxyLatencyMeasurement {
        try await client.displayLatency(
            member: member,
            url: Self.defaultLatencyTestURL,
            timeoutMilliseconds: timeoutMilliseconds,
            unifiedDelay: LatencyTestPreferences.isUnifiedDelayEnabled
        )
    }

    private enum VerifiedLatencyOutcome {
        case completed
        case unsupportedSelector
        case failed(Error)
    }

    private static func isUnsupportedSelectorLatencyError(_ error: Error) -> Bool {
        guard let clientError = error as? ProxySelectionProviderClientError else {
            return false
        }
        if case .providerFailure(.rejected) = clientError {
            return true
        }
        return false
    }

    private func localizedLatencyProbeError(_ error: Error) -> String {
        if let clientError = error as? ProxySelectionProviderClientError {
            switch clientError {
            case let .providerFailure(failure):
                switch failure {
                case .invalidRequest:
                    return AppLocalization.string("The network extension rejected an invalid latency request.")
                case .unavailable:
                    return AppLocalization.string("The live proxy selector is not available.")
                case .rejected:
                    return AppLocalization.string("This proxy group does not support verified latency checks.")
                case .responseTooLarge:
                    return AppLocalization.string("The proxy group is too large to measure safely.")
                case .internalFailure:
                    return AppLocalization.string("The network extension could not measure proxy latency.")
                }
            case .selectionNotApplied:
                return AppLocalization.string("The network extension did not confirm the selected proxy.")
            case .routingModeNotApplied:
                return AppLocalization.string("The network extension did not confirm the routing mode.")
            case .unexpectedResponse:
                return AppLocalization.string("The network extension returned an unexpected latency response.")
            }
        }
        return localizedConnectionError(error).localizedDescription
    }

    /// Streams protocol-verified latency for a group's members using a bounded
    /// sliding window of per-member `activeLatency` probes.
    ///
    /// Nodes, DIRECT and nested groups all use the same bounded URL test.
    /// Each result streams without waiting for slower neighbours; group names
    /// resolve through the core's current active leaf rather than a minimum.
    func measureVerifiedLatency(
        group groupName: String,
        members: [String],
        runToken: LatencyRunToken?
    ) async -> Bool {
        if case .completed = await measureVerifiedLatencyOutcome(
            group: groupName,
            members: members,
            runToken: runToken
        ) {
            return true
        }
        return false
    }

    private func measureVerifiedLatencyOutcome(
        group groupName: String,
        members: [String],
        runToken: LatencyRunToken?
    ) async -> VerifiedLatencyOutcome {
        let testableMembers = members.filter {
            !InitialProxySelectionPolicy.isSubscriptionMetadata($0)
        }
        guard !testableMembers.isEmpty else { return .completed }
        let selected = proxySelections[groupName]?.selectedMember
        var orderedTargets: [String] = []
        orderedTargets.reserveCapacity(testableMembers.count)
        if let selected, testableMembers.contains(selected) {
            orderedTargets.append(selected)
        }
        for member in testableMembers where member != selected {
            orderedTargets.append(member)
        }

        let timeoutMilliseconds = Self.effectiveUILatencyTimeoutMilliseconds
        let client = makeLatencyProbeProviderClient(
            timeoutMilliseconds: timeoutMilliseconds
        )
        let maxConcurrent = 8
        var anyProviderProbeSucceeded = false
        var hadRemoteProbes = false
        var sawUnsupportedSelector = false
        var firstFailureError: Error?

        for member in orderedTargets {
            let upper = member.uppercased()
            if upper == "REJECT" {
                recordLatency(
                    member: member,
                    measurement: .timedOut,
                    runToken: runToken
                )
            } else {
                hadRemoteProbes = true
            }
        }

        let epoch = latencyRuntimeEpoch
        let remoteTargets = orderedTargets.filter { member in
            let upper = member.uppercased()
            return upper != "REJECT"
        }

        guard !Task.isCancelled,
              runToken == currentLatencyRunToken,
              latencyRuntimeEpoch == epoch,
              state == .connected else {
            return .failed(TunnelManagerError.providerSessionUnavailable)
        }

        if !remoteTargets.isEmpty {
            await withTaskGroup(
                of: (member: String, measurement: ProxyLatencyMeasurement?, error: Error?).self
            ) { taskGroup in
                var iterator = remoteTargets.makeIterator()
                var activeCount = 0

                while activeCount < maxConcurrent, let member = iterator.next() {
                    if Task.isCancelled || runToken != currentLatencyRunToken || latencyRuntimeEpoch != epoch || state != .connected {
                        taskGroup.cancelAll()
                        return
                    }
                    activeCount += 1
                    taskGroup.addTask {
                        do {
                            let measurement = try await Self.probeVerifiedMemberLatency(
                                member: member,
                                client: client,
                                timeoutMilliseconds: timeoutMilliseconds
                            )
                            return (member, measurement, nil)
                        } catch {
                            return (member, nil, error)
                        }
                    }
                }

                while let result = await taskGroup.next() {
                    if runToken != currentLatencyRunToken || latencyRuntimeEpoch != epoch || Task.isCancelled || state != .connected {
                        taskGroup.cancelAll()
                        break
                    }
                    if let measurement = result.measurement {
                        anyProviderProbeSucceeded = true
                        recordLatency(
                            member: result.member,
                            measurement: measurement,
                            runToken: runToken
                        )
                    } else if let error = result.error {
                        if Self.isUnsupportedSelectorLatencyError(error) {
                            sawUnsupportedSelector = true
                        } else if !(error is CancellationError) {
                            firstFailureError = firstFailureError ?? error
                        }
                    }
                    if let nextMember = iterator.next() {
                        taskGroup.addTask {
                            do {
                                let measurement = try await Self.probeVerifiedMemberLatency(
                                    member: nextMember,
                                    client: client,
                                    timeoutMilliseconds: timeoutMilliseconds
                                )
                                return (nextMember, measurement, nil)
                            } catch {
                                return (nextMember, nil, error)
                            }
                        }
                    }
                }
            }
        }

        guard runToken == currentLatencyRunToken, state == .connected else {
            if anyProviderProbeSucceeded || !hadRemoteProbes {
                return .completed
            }
            return .failed(firstFailureError ?? TunnelManagerError.providerSessionUnavailable)
        }

        // Propagate measured leaf nodes up to any child strategy groups first.
        let aggregated = latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
        if !aggregated.isEmpty {
            publishLatency(groups: aggregated, force: false)
        }

        if anyProviderProbeSucceeded || !hadRemoteProbes {
            return .completed
        }
        if let firstFailureError {
            return .failed(firstFailureError)
        }
        if sawUnsupportedSelector {
            return .unsupportedSelector
        }
        return .failed(TunnelManagerError.providerSessionUnavailable)
    }

    /// Upgrades the group's selected member from "reachable" to "verified" by
    /// measuring it through the core's real protocol handler.
    func verifySelectedMemberLatency(
        group groupName: String,
        runToken: LatencyRunToken?
    ) async {
        guard state == .connected, !isUIReviewMode else { return }
        guard let selected = proxySelections[groupName]?.selectedMember,
              !selected.isEmpty else { return }
        _ = await verifyMemberLatency(
            group: groupName,
            member: selected,
            runToken: runToken,
            recordTimeoutOnFailure: false
        )
    }

    /// Non-blocking display latency refresh after an optimistic manual switch.
    func refreshSelectedMemberDisplayLatency(
        group groupName: String,
        member memberName: String,
        connectionID: UUID?
    ) async {
        guard state == .connected,
              providerConnectionID == connectionID,
              !isUIReviewMode,
              InitialProxySelectionPolicy.isRouteCandidate(memberName) else {
            return
        }
        let runToken = prepareLatencyIndex()
        let timeoutMilliseconds = Self.effectiveUILatencyTimeoutMilliseconds
        let client = makeLatencyProbeProviderClient(
            timeoutMilliseconds: timeoutMilliseconds
        )
        do {
            let measurement = try await Self.probeVerifiedMemberLatency(
                member: memberName,
                client: client,
                timeoutMilliseconds: timeoutMilliseconds
            )
            guard state == .connected,
                  providerConnectionID == connectionID else {
                return
            }
            recordLatency(
                member: memberName,
                measurement: measurement,
                runToken: runToken,
                force: true
            )
        } catch {
            Self.runtimeLogger.debug(
                "stage=proxyLatency postSwitchRefreshSkipped group=\(groupName, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
        }
    }

    @discardableResult
    func verifyMemberLatency(
        group groupName: String,
        member memberName: String,
        runToken: LatencyRunToken?,
        recordTimeoutOnFailure: Bool
    ) async -> Bool {
        if case .completed = await verifyMemberLatencyOutcome(
            group: groupName,
            member: memberName,
            runToken: runToken,
            recordTimeoutOnFailure: recordTimeoutOnFailure,
            isolateToGroupOnActiveSweep: false
        ) {
            return true
        }
        return false
    }

    private func verifyMemberLatencyOutcome(
        group groupName: String,
        member memberName: String,
        runToken: LatencyRunToken?,
        recordTimeoutOnFailure: Bool,
        isolateToGroupOnActiveSweep: Bool
    ) async -> VerifiedLatencyOutcome {
        guard state == .connected, !isUIReviewMode else {
            return .failed(TunnelManagerError.providerSessionUnavailable)
        }
        let timeoutMilliseconds = Self.effectiveUILatencyTimeoutMilliseconds
        let client = makeLatencyProbeProviderClient(
            timeoutMilliseconds: timeoutMilliseconds
        )
        do {
            let measurement = try await Self.probeVerifiedMemberLatency(
                member: memberName,
                client: client,
                timeoutMilliseconds: timeoutMilliseconds
            )
            if case .timedOut = measurement, !recordTimeoutOnFailure {
                return .completed
            }
            if isolateToGroupOnActiveSweep {
                recordSingleMemberLatency(
                    member: memberName,
                    measurement: measurement,
                    group: groupName,
                    runToken: runToken
                )
            } else {
                recordLatency(
                    member: memberName,
                    measurement: measurement,
                    runToken: runToken,
                    force: true
                )
            }
            Self.runtimeLogger.info(
                "stage=proxyLatency verified group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) delay=\(measurement.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
            )
            return .completed
        } catch {
            // When upgrading an offline reachability number, a failed
            // verification leaves the reachability number alone.
            Self.runtimeLogger.error(
                "stage=proxyLatency verifyFailed group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
            if Self.isUnsupportedSelectorLatencyError(error) {
                return .unsupportedSelector
            }
            return .failed(error)
        }
    }

    private func resolvedLatencyChainSelections(
        for member: String,
        existingSelections: [String: String]? = nil
    ) -> (leaf: String, fallbackSelections: [String: String])? {
        let groupsByName = Dictionary(
            uniqueKeysWithValues: latencyGroupsSnapshot().map { ($0.name, $0) }
        )
        var current = member
        var visited: Set<String> = [current]
        var selections = existingSelections ?? latencySelectedMembers
        while let group = groupsByName[current] {
            let next = selections[current]
                ?? group.members.first { !InitialProxySelectionPolicy.isSubscriptionMetadata($0) }
            guard let next, visited.insert(next).inserted else {
                return nil
            }
            if selections[current] == nil {
                selections[current] = next
            }
            current = next
        }
        return (current, selections)
    }

    private func resolvedOfflineProbeTargets(
        for members: [String]
    ) -> (leaves: [String], selections: [String: String]) {
        let groupsByName = Dictionary(
            uniqueKeysWithValues: latencyGroupsSnapshot().map { ($0.name, $0) }
        )
        var leaves: [String] = []
        var seenLeaves: Set<String> = []
        var selections = latencySelectedMembers

        for member in members where !InitialProxySelectionPolicy.isSubscriptionMetadata(member) {
            if groupsByName[member] != nil {
                if let resolved = resolvedLatencyChainSelections(
                    for: member,
                    existingSelections: selections
                ) {
                    for (group, chosen) in resolved.fallbackSelections where selections[group] == nil {
                        selections[group] = chosen
                    }
                    if !InitialProxySelectionPolicy.isSubscriptionMetadata(resolved.leaf),
                       seenLeaves.insert(resolved.leaf).inserted {
                        leaves.append(resolved.leaf)
                    }
                }
            } else if seenLeaves.insert(member).inserted {
                leaves.append(member)
            }
        }
        return (leaves, selections)
    }

    func testSingleProxyLatency(group groupName: String, member memberName: String) async {
        let memberKey = "\(groupName):\(memberName)"
        guard !InitialProxySelectionPolicy.isSubscriptionMetadata(memberName),
              hasLatencyTestableGroup(named: groupName, containing: memberName),
              !proxyLatencyRequests.contains(groupName),
              !memberLatencyRequests.contains(memberKey) else {
            return
        }
        let epoch = latencyRuntimeEpoch
        let currentSingleLatencyToken = UUID()
        let runToken = prepareLatencyIndex()
        memberLatencyRequests.insert(memberKey)
        activeMemberLatencyTokens[memberKey] = currentSingleLatencyToken
        // Clear only this group's row so a single-node test on GroupB/SharedNode
        // never erases or corrupts an active group sweep running on GroupA.
        latencyIndex.clear(member: memberName, in: groupName)
        publishLatency(groups: [groupName], force: true)
        proxySelectionMessages[groupName] = nil
        defer {
            activeLatencyRunTasks.removeValue(forKey: currentSingleLatencyToken)
            if activeMemberLatencyTokens[memberKey] == currentSingleLatencyToken {
                activeMemberLatencyTokens.removeValue(forKey: memberKey)
                if latencyRuntimeEpoch == epoch {
                    memberLatencyRequests.remove(memberKey)
                }
            }
        }

        Self.runtimeLogger.info(
            "stage=proxyLatency memberRequest group=\(groupName, privacy: .public) member=\(memberName, privacy: .public)"
        )

        let batchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isCurrentSingleProbe: () -> Bool = {
                !Task.isCancelled
                    && runToken == self.currentLatencyRunToken
                    && self.latencyRuntimeEpoch == epoch
                    && self.activeMemberLatencyTokens[memberKey] == currentSingleLatencyToken
            }
            let publishUpdatedGroups: ([String: String]) -> Void = { selections in
                let aggregated = self.latencyIndex.aggregateChildGroups(selectedMembers: selections)
                let nonSweepingGroups = self.latencyGroupsSnapshot()
                    .map(\.name)
                    .filter { $0 == groupName || !self.proxyLatencyRequests.contains($0) }
                let dirty = aggregated.union([groupName]).intersection(Set(nonSweepingGroups))
                self.publishLatency(groups: dirty, force: true)
            }

            let measurement: ProxyLatencyMeasurement
            if self.isUIReviewMode {
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled,
                      self.latencyRuntimeEpoch == epoch,
                      self.activeMemberLatencyTokens[memberKey] == currentSingleLatencyToken else { return }
                measurement = memberName.uppercased() == "DIRECT"
                    ? .reachable(3)
                    : .reachable(36)
                self.recordSingleMemberLatency(
                    member: memberName,
                    measurement: measurement,
                    group: groupName,
                    runToken: runToken
                )
                Self.runtimeLogger.info(
                    "stage=proxyLatency memberSuccess group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) delay=\(measurement.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
                )
                guard isCurrentSingleProbe() else { return }
                publishUpdatedGroups(self.latencySelectedMembers)
                return
            }

            if self.state == .connected {
                switch await self.verifyMemberLatencyOutcome(
                    group: groupName,
                    member: memberName,
                    runToken: runToken,
                    recordTimeoutOnFailure: true,
                    isolateToGroupOnActiveSweep: true
                ) {
                case .completed:
                    guard isCurrentSingleProbe() else { return }
                    publishUpdatedGroups(self.latencySelectedMembers)
                    return
                case let .failed(error):
                    guard isCurrentSingleProbe() else { return }
                    Self.runtimeLogger.error(
                        "stage=proxyLatency singleMemberProviderFailed group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) fallingBackToReachability=false error=\(String(reflecting: error), privacy: .public)"
                    )
                    self.proxySelectionMessages[groupName] = self.localizedLatencyProbeError(error)
                    self.latencyIndex.clear(member: memberName, in: groupName)
                    self.publishLatency(groups: [groupName], force: true)
                    return
                case .unsupportedSelector:
                    guard isCurrentSingleProbe() else { return }
                    Self.runtimeLogger.error(
                        "stage=proxyLatency singleMemberProviderUnsupportedSelector group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) fallingBackToReachability=true"
                    )
                }
            }

            guard isCurrentSingleProbe(),
                  memberName.uppercased() != "DIRECT" else { return }
            let resolvedChain = self.resolvedLatencyChainSelections(for: memberName)
            let targetMember = resolvedChain?.leaf ?? memberName
            guard targetMember.uppercased() != "DIRECT" else { return }
            let endpoints = self.activeProfile
                .map { ProfileNamedEndpointInspector.inspect(yaml: self.effectiveProfileYAML(for: $0)) } ?? [:]
            measurement = await Self.probeDirectMemberLatency(
                member: targetMember,
                endpoints: endpoints,
                excludingVirtualInterfaces: self.shouldExcludeVirtualInterfaces
            )
            guard isCurrentSingleProbe() else { return }
            self.recordSingleMemberLatency(
                member: targetMember,
                measurement: measurement,
                group: groupName,
                runToken: runToken
            )
            Self.runtimeLogger.info(
                "stage=proxyLatency memberSuccess group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) target=\(targetMember, privacy: .public) delay=\(measurement.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
            )

            publishUpdatedGroups(resolvedChain?.fallbackSelections ?? self.latencySelectedMembers)
        }
        activeLatencyRunTasks[currentSingleLatencyToken] = batchTask
        await withTaskCancellationHandler {
            await batchTask.value
        } onCancel: {
            batchTask.cancel()
        }
    }

    /// Drives the bounded probe pool and streams each result into the index.
    ///
    /// Results land in the index in O(1) and publish on a flush window.
    /// DIRECT stays unmeasured offline: it has no node endpoint to TCP-ping.
    func measureReachability(
        members: [String],
        runToken: LatencyRunToken?
    ) async {
        let epoch = latencyRuntimeEpoch
        let members = members.filter {
            $0.uppercased() != "DIRECT"
                && !InitialProxySelectionPolicy.isSubscriptionMetadata($0)
        }
        guard !members.isEmpty,
              !Task.isCancelled,
              runToken == currentLatencyRunToken,
              latencyRuntimeEpoch == epoch else { return }
        let endpoints = activeProfile
            .map { ProfileNamedEndpointInspector.inspect(yaml: effectiveProfileYAML(for: $0)) } ?? [:]
        let excludeVirtual = shouldExcludeVirtualInterfaces
        let maxConcurrent = 12

        await withTaskGroup(
            of: (member: String, measurement: ProxyLatencyMeasurement).self
        ) { taskGroup in
            var iterator = members.makeIterator()
            var activeCount = 0

            while activeCount < maxConcurrent, let member = iterator.next() {
                if Task.isCancelled || runToken != currentLatencyRunToken || latencyRuntimeEpoch != epoch {
                    taskGroup.cancelAll()
                    return
                }
                activeCount += 1
                taskGroup.addTask {
                    (
                        member,
                        await Self.probeDirectMemberLatency(
                            member: member,
                            endpoints: endpoints,
                            excludingVirtualInterfaces: excludeVirtual
                        )
                    )
                }
            }

            while let result = await taskGroup.next() {
                // A profile switch mid-sweep invalidates everything still in
                // flight; stop rather than writing stale numbers into the
                // new profile's groups.
                if Task.isCancelled || runToken != currentLatencyRunToken || latencyRuntimeEpoch != epoch {
                    taskGroup.cancelAll()
                    break
                }
                recordLatency(
                    member: result.member,
                    measurement: result.measurement,
                    runToken: runToken
                )
                if let nextMember = iterator.next() {
                    taskGroup.addTask {
                        (
                            nextMember,
                            await Self.probeDirectMemberLatency(
                                member: nextMember,
                                endpoints: endpoints,
                                excludingVirtualInterfaces: excludeVirtual
                            )
                        )
                    }
                }
            }
        }
    }

    /// Whether a reachability probe must refuse virtual interfaces.
    ///
    /// In TUN mode the app's own outbound packets enter `utun` unless the
    /// node's address happens to sit in an excluded route, so a plain probe
    /// measures `host -> current node -> target node` and can loop back on the
    /// node currently carrying the tunnel until it times out. Restricting the
    /// probe to physical interfaces measures the hop that was asked for.
    ///
    /// Transparent Proxy is left alone: it does not change routes, its
    /// self-identity guard already excludes the app's own flows, and
    /// prohibiting virtual interfaces there would break hosts whose real
    /// uplink is itself a virtual interface.
    var shouldExcludeVirtualInterfaces: Bool {
#if AETHERROUTE_INDEPENDENT
        guard state == .connected || state == .recovering else { return false }
        return networkEngineMode == .tun
#else
        return false
#endif
    }

    /// Measures one member's TCP reachability.
    ///
    /// Every number this returns is `.reachable`: it is a handshake against
    /// the node's advertised endpoint, not proof that the node's protocol or
    /// egress works. `verifySelectedMemberLatency` is what produces a
    /// `.verified` number.
    nonisolated static func probeDirectMemberLatency(
        member: String,
        endpoints: [String: ProfileUpstreamEndpoint],
        excludingVirtualInterfaces: Bool
    ) async -> ProxyLatencyMeasurement {
        if member.uppercased() == "REJECT" { return .timedOut }
        guard let endpoint = endpoints[member] else { return .timedOut }
        let delay = await probeTCPLatency(
            host: endpoint.host,
            port: endpoint.port,
            excludingVirtualInterfaces: excludingVirtualInterfaces
        )
        return delay.map { .reachable($0) } ?? .timedOut
    }

    nonisolated private static let probeQueue = DispatchQueue(
        label: "com.aetherroute.desktop.latency-probe",
        qos: .userInitiated,
        attributes: .concurrent
    )

    nonisolated static func probeTCPLatency(
        host: String,
        port: UInt16,
        timeoutMilliseconds: UInt32 = 1500,
        excludingVirtualInterfaces: Bool = false
    ) async -> UInt32? {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        let endpoint = NWEndpoint.Host(host)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.connectionTimeout = max(1, Int((timeoutMilliseconds + 999) / 1000))
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        if excludingVirtualInterfaces {
            // `utun` reports as `.other`. Refusing that type keeps a TUN
            // session from carrying the probe it is supposed to be measured
            // against.
            parameters.prohibitedInterfaceTypes = [.other]
        }
        let connection = NWConnection(host: endpoint, port: nwPort, using: parameters)

        final class ProbeContext: @unchecked Sendable {
            var hasCompleted = false
            let lock = NSLock()
            var connection: NWConnection?
            var timer: (any DispatchSourceTimer)?
            let continuation: CheckedContinuation<UInt32?, Never>

            init(
                connection: NWConnection,
                timer: any DispatchSourceTimer,
                continuation: CheckedContinuation<UInt32?, Never>
            ) {
                self.connection = connection
                self.timer = timer
                self.continuation = continuation
            }

            func complete(delay: UInt32?) {
                let (shouldComplete, activeTimer, activeConnection): (Bool, (any DispatchSourceTimer)?, NWConnection?) = lock.withLock {
                    if !hasCompleted {
                        hasCompleted = true
                        let timerRef = timer
                        let connectionRef = connection
                        timer = nil
                        connection = nil
                        return (true, timerRef, connectionRef)
                    }
                    return (false, nil, nil)
                }
                guard shouldComplete else { return }
                if let activeTimer {
                    activeTimer.setEventHandler {}
                    activeTimer.cancel()
                }
                if let activeConnection {
                    activeConnection.stateUpdateHandler = nil
                    activeConnection.cancel()
                }
                continuation.resume(returning: delay)
            }
        }

        final class CancellationBridge: @unchecked Sendable {
            private let lock = NSLock()
            private var cancelled = false
            private var context: ProbeContext?

            func attach(_ context: ProbeContext) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                if cancelled {
                    return false
                }
                self.context = context
                return true
            }

            func cancel() {
                let contextToCancel: ProbeContext? = lock.withLock {
                    cancelled = true
                    return context
                }
                contextToCancel?.complete(delay: nil)
            }
        }

        let bridge = CancellationBridge()

        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let timer = DispatchSource.makeTimerSource(queue: probeQueue)
                timer.schedule(deadline: .now() + .milliseconds(Int(timeoutMilliseconds)))

                let context = ProbeContext(
                    connection: connection,
                    timer: timer,
                    continuation: continuation
                )
                timer.setEventHandler {
                    context.complete(delay: nil)
                }
                timer.resume()

                if !bridge.attach(context) {
                    context.complete(delay: nil)
                    return
                }
                let startTime = DispatchTime.now()

                connection.stateUpdateHandler = { connState in
                    switch connState {
                    case .ready:
                        let elapsed = DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds
                        let ms = UInt32(elapsed / 1_000_000)
                        context.complete(delay: max(1, ms))
                    case .failed, .cancelled:
                        context.complete(delay: nil)
                    default:
                        break
                    }
                }
                connection.start(queue: probeQueue)
            }
        } onCancel: {
            bridge.cancel()
        }
    }

}

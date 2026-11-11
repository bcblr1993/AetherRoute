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
        for group in pendingLatencyFlush {
            proxyLatencies[group] = latencyIndex.state(for: group)
            latencyMeasuredAt[group] = latencyIndex.measurementDates(for: group)
        }
        pendingLatencyFlush.removeAll(keepingCapacity: true)
    }

    /// Records one measurement in every group that lists the member.
    func recordLatency(
        member: String,
        measurement: ProxyLatencyMeasurement,
        runToken: LatencyRunToken?,
        force: Bool = false
    ) {
        guard runToken == currentLatencyRunToken else { return }
        let affected = latencyIndex.merge(
            member: member,
            measurement: measurement
        )
        publishLatency(groups: affected, force: force)
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
        defer { proxyLatencyRequests.remove(groupName) }

        let members = snapshotMembers.filter {
            !InitialProxySelectionPolicy.isSubscriptionMetadata($0)
        }

        if isUIReviewMode {
            try? await Task.sleep(nanoseconds: 120_000_000)
            for (index, member) in members.enumerated() {
                recordLatency(
                    member: member,
                    measurement: Self.uiReviewMeasurement(
                        member: member,
                        index: index
                    ),
                    runToken: runToken
                )
            }
            publishLatency(groups: [groupName], force: true)
            return
        }

        if state == .connected {
            if await measureVerifiedLatency(
                group: groupName,
                members: members,
                runToken: runToken
            ) {
                guard runToken == currentLatencyRunToken else { return }
                let aggregated = latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
                publishLatency(groups: aggregated.union([groupName]), force: true)
                let measured = proxyLatencies[groupName]?.results ?? []
                Self.runtimeLogger.info(
                    "stage=proxyLatency success results=\(measured.count, privacy: .public) responsive=\(measured.lazy.filter { $0.delayMilliseconds != nil }.count, privacy: .public)"
                )
                return
            }
            Self.runtimeLogger.error(
                "stage=proxyLatency providerFailed group=\(groupName, privacy: .public) fallingBackToReachability=true"
            )
        }

        // Offline / fallback: bare TCP reachability, streamed.
        let probeTargets = Set(latencyIndex.probeTargets)
        await measureReachability(
            members: members.filter(probeTargets.contains),
            runToken: runToken
        )
        guard runToken == currentLatencyRunToken else { return }
        let aggregated = latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
        publishLatency(groups: aggregated.union([groupName]), force: true)

        let measured = proxyLatencies[groupName]?.results ?? []
        Self.runtimeLogger.info(
            "stage=proxyLatency offlineSuccess results=\(measured.count, privacy: .public) responsive=\(measured.lazy.filter { $0.delayMilliseconds != nil }.count, privacy: .public)"
        )

        // Upgrade the selected member to a verified number if possible.
        await verifySelectedMemberLatency(
            group: groupName,
            runToken: runToken
        )
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
        let testableMembers = members.filter {
            !InitialProxySelectionPolicy.isSubscriptionMetadata($0)
        }
        guard !testableMembers.isEmpty else { return true }
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

        let remoteTargets = orderedTargets.filter { member in
            let upper = member.uppercased()
            return upper != "REJECT"
        }

        if !remoteTargets.isEmpty {
            await withTaskGroup(
                of: (member: String, measurement: ProxyLatencyMeasurement?, succeeded: Bool).self
            ) { taskGroup in
                var iterator = remoteTargets.makeIterator()
                var activeCount = 0

                while activeCount < maxConcurrent, let member = iterator.next() {
                    activeCount += 1
                    taskGroup.addTask {
                        do {
                            let measurement = try await Self.probeVerifiedMemberLatency(
                                member: member,
                                client: client,
                                timeoutMilliseconds: timeoutMilliseconds
                            )
                            return (member, measurement, true)
                        } catch {
                            return (member, nil, false)
                        }
                    }
                }

                while let result = await taskGroup.next() {
                    if runToken != currentLatencyRunToken || Task.isCancelled || state != .connected {
                        taskGroup.cancelAll()
                        break
                    }
                    if result.succeeded, let measurement = result.measurement {
                        anyProviderProbeSucceeded = true
                        recordLatency(
                            member: result.member,
                            measurement: measurement,
                            runToken: runToken
                        )
                    } else {
                        recordLatency(
                            member: result.member,
                            measurement: .timedOut,
                            runToken: runToken
                        )
                    }
                    if let nextMember = iterator.next() {
                        taskGroup.addTask {
                            do {
                                let measurement = try await Self.probeVerifiedMemberLatency(
                                    member: nextMember,
                                    client: client,
                                    timeoutMilliseconds: timeoutMilliseconds
                                )
                                return (nextMember, measurement, true)
                            } catch {
                                return (nextMember, nil, false)
                            }
                        }
                    }
                }
            }
        }

        guard runToken == currentLatencyRunToken, state == .connected else {
            return anyProviderProbeSucceeded || !hadRemoteProbes
        }

        // Propagate measured leaf nodes up to any child strategy groups first.
        let aggregated = latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
        if !aggregated.isEmpty {
            publishLatency(groups: aggregated, force: false)
        }

        // Child groups were probed alongside nodes, through their active
        // handler. No fastest-child estimate may replace those readings.
        return anyProviderProbeSucceeded || !hadRemoteProbes
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
        guard state == .connected, !isUIReviewMode else { return false }
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
                return true
            }
            recordLatency(
                member: memberName,
                measurement: measurement,
                runToken: runToken,
                force: true
            )
            Self.runtimeLogger.info(
                "stage=proxyLatency verified group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) delay=\(measurement.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
            )
            return true
        } catch {
            // When upgrading an offline reachability number, a failed
            // verification leaves the reachability number alone.
            Self.runtimeLogger.error(
                "stage=proxyLatency verifyFailed group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
            return false
        }
    }

    func testSingleProxyLatency(group groupName: String, member memberName: String) async {
        let memberKey = "\(groupName):\(memberName)"
        guard !InitialProxySelectionPolicy.isSubscriptionMetadata(memberName),
              hasLatencyTestableGroup(named: groupName, containing: memberName),
              !proxyLatencyRequests.contains(groupName),
              !memberLatencyRequests.contains(memberKey) else {
            return
        }
        let runToken = prepareLatencyIndex()
        memberLatencyRequests.insert(memberKey)
        // Clear the member in every group that lists it, so all of its rows
        // read as "testing" instead of one row testing while the others keep
        // showing a number that is about to change.
        let affected = latencyIndex.groups(containing: memberName)
        for group in affected {
            latencyIndex.clear(member: memberName, in: group)
        }
        publishLatency(groups: affected, force: true)
        proxySelectionMessages[groupName] = nil
        defer { memberLatencyRequests.remove(memberKey) }

        Self.runtimeLogger.info(
            "stage=proxyLatency memberRequest group=\(groupName, privacy: .public) member=\(memberName, privacy: .public)"
        )

        let measurement: ProxyLatencyMeasurement
        if isUIReviewMode {
            try? await Task.sleep(nanoseconds: 120_000_000)
            measurement = memberName.uppercased() == "DIRECT"
                ? .reachable(3)
                : .reachable(36)
            recordLatency(
                member: memberName,
                measurement: measurement,
                runToken: runToken,
                force: true
            )
            Self.runtimeLogger.info(
                "stage=proxyLatency memberSuccess group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) delay=\(measurement.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
            )
            guard runToken == currentLatencyRunToken else { return }
            latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
            let allGroups = latencyGroupsSnapshot().map(\.name)
            publishLatency(groups: allGroups, force: true)
            return
        }

        if state == .connected {
            if await verifyMemberLatency(
                group: groupName,
                member: memberName,
                runToken: runToken,
                recordTimeoutOnFailure: true
            ) {
                guard runToken == currentLatencyRunToken else { return }
                latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
                let allGroups = latencyGroupsSnapshot().map(\.name)
                publishLatency(groups: allGroups, force: true)
                return
            }
            Self.runtimeLogger.error(
                "stage=proxyLatency singleMemberProviderFailed group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) fallingBackToReachability=true"
            )
        }

        guard memberName.uppercased() != "DIRECT" else { return }
        let endpoints = activeProfile
            .map { ProfileNamedEndpointInspector.inspect(yaml: $0.yaml) } ?? [:]
        measurement = await Self.probeDirectMemberLatency(
            member: memberName,
            endpoints: endpoints,
            excludingVirtualInterfaces: shouldExcludeVirtualInterfaces
        )
        recordLatency(
            member: memberName,
            measurement: measurement,
            runToken: runToken,
            force: true
        )
        Self.runtimeLogger.info(
            "stage=proxyLatency memberSuccess group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) delay=\(measurement.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
        )

        guard runToken == currentLatencyRunToken else { return }
        latencyIndex.aggregateChildGroups(selectedMembers: latencySelectedMembers)
        let allGroups = latencyGroupsSnapshot().map(\.name)
        publishLatency(groups: allGroups, force: true)
    }

    /// Drives the bounded probe pool and streams each result into the index.
    ///
    /// Results land in the index in O(1) and publish on a flush window.
    /// DIRECT stays unmeasured offline: it has no node endpoint to TCP-ping.
    func measureReachability(
        members: [String],
        runToken: LatencyRunToken?
    ) async {
        let members = members.filter {
            $0.uppercased() != "DIRECT"
                && !InitialProxySelectionPolicy.isSubscriptionMetadata($0)
        }
        guard !members.isEmpty else { return }
        let endpoints = activeProfile
            .map { ProfileNamedEndpointInspector.inspect(yaml: $0.yaml) } ?? [:]
        let excludeVirtual = shouldExcludeVirtualInterfaces
        let maxConcurrent = 12

        await withTaskGroup(
            of: (member: String, measurement: ProxyLatencyMeasurement).self
        ) { taskGroup in
            var iterator = members.makeIterator()
            var activeCount = 0

            while activeCount < maxConcurrent, let member = iterator.next() {
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
                if runToken != currentLatencyRunToken {
                    taskGroup.cancelAll()
                    break
                }
                recordLatency(
                    member: result.member,
                    measurement: result.measurement,
                    runToken: runToken
                )
                if Task.isCancelled {
                    taskGroup.cancelAll()
                    break
                }
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
    nonisolated private static func probeDirectMemberLatency(
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

    nonisolated private static func probeTCPLatency(
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

        return await withCheckedContinuation { continuation in
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
                    let shouldComplete: Bool = lock.withLock {
                        if !hasCompleted {
                            hasCompleted = true
                            return true
                        }
                        return false
                    }
                    guard shouldComplete else { return }
                    if let timer {
                        timer.setEventHandler {}
                        timer.cancel()
                        self.timer = nil
                    }
                    if let connection {
                        connection.stateUpdateHandler = nil
                        connection.cancel()
                        self.connection = nil
                    }
                    continuation.resume(returning: delay)
                }
            }

            let timer = DispatchSource.makeTimerSource(queue: probeQueue)
            timer.schedule(deadline: .now() + .milliseconds(Int(timeoutMilliseconds)))

            let context = ProbeContext(
                connection: connection,
                timer: timer,
                continuation: continuation
            )
            let startTime = DispatchTime.now()

            timer.setEventHandler {
                context.complete(delay: nil)
            }
            timer.resume()

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
    }

}

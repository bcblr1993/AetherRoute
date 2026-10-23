import AetherRouteKit
import Foundation
import Network
import NetworkExtension
import OSLog

extension TunnelManager {
    public func isTestingLatency(group groupName: String, member memberName: String? = nil) -> Bool {
        if let memberName {
            return memberLatencyRequests.contains("\(groupName):\(memberName)")
                || proxyLatencyRequests.contains(groupName)
        }
        return proxyLatencyRequests.contains(groupName)
    }
    func latencyGroupsSnapshot() -> [(name: String, members: [String])] {
        (activeProfileSummary?.proxyGroups ?? []).map { group in
            (
                name: group.name,
                members: proxySelections[group.name]?.members ?? group.members
            )
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
        latencyIndex.beginRun(groups: latencyGroupsSnapshot())
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
        for group in pendingLatencyFlush {
            proxyLatencies[group] = latencyIndex.state(for: group)
            latencyMeasuredAt[group] = pendingLatencyMeasuredAt[group]
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
        for group in affected { pendingLatencyMeasuredAt[group, default: [:]][member] = .now }
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

    /// Folds a provider-measured result into the index.
    ///
    /// These come from the core's real handlers, so they are recorded as
    /// verified. Routing them through the index is also what stops a later
    /// manual flush from overwriting them, and it keeps a single-result
    /// `activeLatency` reply from shrinking the whole group down to one row
    /// the way a direct assignment did.
    func adoptProviderLatency(
        _ latency: ProxyLatencyState,
        forGroup groupName: String
    ) {
        prepareLatencyIndex()
        var affected: Set<String> = [groupName]
        for result in latency.results {
            let merged = latencyIndex.merge(
                member: result.member,
                measurement: result.delayMilliseconds
                    .map { .verified($0) } ?? .timedOut
            )
            affected.formUnion(merged)
            if merged.isEmpty {
                latencyIndex.recordDirect(
                    member: result.member,
                    measurement: result.delayMilliseconds
                        .map { .verified($0) } ?? .timedOut,
                    in: groupName
                )
            }
        }
        publishLatency(groups: affected, force: true)
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
        guard activeProfileSummary?.proxyGroups.contains(where: {
                  $0.name == groupName
              }) == true,
              !proxyLatencyRequests.contains(groupName) else {
            return
        }
        let runToken = prepareLatencyIndex()
        proxyLatencyRequests.insert(groupName)
        Self.runtimeLogger.info(
            "stage=proxyLatency request members=\(self.activeProfileSummary?.proxyGroups.first(where: { $0.name == groupName })?.memberCount ?? 0, privacy: .public)"
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

        let members = latencyGroupsSnapshot()
            .first(where: { $0.name == groupName })?
            .members ?? []

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
                let aggregated = latencyIndex.aggregateChildGroups()
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
        let aggregated = latencyIndex.aggregateChildGroups()
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
        timeoutMilliseconds: UInt32 = TunnelManager.uiLatencyTimeoutMilliseconds
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
        timeoutMilliseconds: UInt32 = TunnelManager.uiLatencyTimeoutMilliseconds
    ) async throws -> ProxyLatencyMeasurement {
        let upper = member.uppercased()
        if upper == "DIRECT" { return .verified(1) }
        if upper == "REJECT" { return .timedOut }
        let latency = try await client.activeLatency(
            group: member,
            url: Self.defaultLatencyTestURL,
            timeoutMilliseconds: timeoutMilliseconds
        )
        let delay = latency.results
            .first(where: { $0.member == member })?.delayMilliseconds
            ?? latency.results.first?.delayMilliseconds
        return delay.map { .verified($0) } ?? .timedOut
    }

    /// Streams protocol-verified latency for a group's members using a bounded
    /// sliding window of per-member `activeLatency` probes.
    ///
    /// Fast nodes update the UI within ~100 ms as they respond instead of
    /// waiting for dead nodes in the group to hit the 3,000 ms timeout, and
    /// groups with more than 64 members no longer fail `selector_url_test` and
    /// fall back to bare TCP.
    func measureVerifiedLatency(
        group groupName: String,
        members: [String],
        runToken: LatencyRunToken?
    ) async -> Bool {
        guard !members.isEmpty else { return true }
        let probeTargets = Set(latencyIndex.probeTargets)
        let selected = proxySelections[groupName]?.selectedMember
        var orderedTargets: [String] = []
        orderedTargets.reserveCapacity(members.count)
        if let selected,
           probeTargets.contains(selected),
           members.contains(selected) {
            orderedTargets.append(selected)
        }
        for member in members where probeTargets.contains(member) && member != selected {
            orderedTargets.append(member)
        }

        let client = makeLatencyProbeProviderClient(
            timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
        )
        let timeoutMilliseconds = Self.uiLatencyTimeoutMilliseconds
        let maxConcurrent = 8
        var anyProviderProbeSucceeded = false
        var hadRemoteProbes = false

        for member in orderedTargets {
            let upper = member.uppercased()
            if upper == "DIRECT" {
                recordLatency(
                    member: member,
                    measurement: .verified(1),
                    runToken: runToken
                )
            } else if upper == "REJECT" {
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
            return upper != "DIRECT" && upper != "REJECT"
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
        let aggregated = latencyIndex.aggregateChildGroups()
        if !aggregated.isEmpty {
            publishLatency(groups: aggregated, force: false)
        }

        // Any child strategy group listed in `members` whose own leaf nodes were
        // not part of `members` is probed directly through its active leaf.
        let unresolvedChildGroups = members.filter { member in
            !probeTargets.contains(member)
                && latencyIndex.measurement(for: member, in: groupName) == nil
        }
        for childGroup in unresolvedChildGroups {
            if runToken != currentLatencyRunToken || Task.isCancelled || state != .connected {
                break
            }
            hadRemoteProbes = true
            do {
                let measurement = try await Self.probeVerifiedMemberLatency(
                    member: childGroup,
                    client: client,
                    timeoutMilliseconds: timeoutMilliseconds
                )
                anyProviderProbeSucceeded = true
                recordLatency(
                    member: childGroup,
                    measurement: measurement,
                    runToken: runToken
                )
            } catch {
                recordLatency(
                    member: childGroup,
                    measurement: .timedOut,
                    runToken: runToken
                )
            }
        }

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

    @discardableResult
    func verifyMemberLatency(
        group groupName: String,
        member memberName: String,
        runToken: LatencyRunToken?,
        recordTimeoutOnFailure: Bool
    ) async -> Bool {
        guard state == .connected, !isUIReviewMode else { return false }
        let client = makeLatencyProbeProviderClient(
            timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
        )
        do {
            let measurement = try await Self.probeVerifiedMemberLatency(
                member: memberName,
                client: client,
                timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
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
        guard activeProfileSummary?.proxyGroups.contains(where: {
                  $0.name == groupName && $0.members.contains(memberName)
              }) == true,
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
            latencyIndex.aggregateChildGroups()
            let allGroups = (activeProfileSummary?.proxyGroups ?? []).map(\.name)
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
                latencyIndex.aggregateChildGroups()
                let allGroups = (activeProfileSummary?.proxyGroups ?? []).map(\.name)
                publishLatency(groups: allGroups, force: true)
                return
            }
            Self.runtimeLogger.error(
                "stage=proxyLatency singleMemberProviderFailed group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) fallingBackToReachability=true"
            )
        }

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
        latencyIndex.aggregateChildGroups()
        let allGroups = (activeProfileSummary?.proxyGroups ?? []).map(\.name)
        publishLatency(groups: allGroups, force: true)
    }

    /// Drives the bounded probe pool and streams each result into the index.
    ///
    /// The 16-worker sliding window is unchanged; what changed is that results
    /// land in the index in O(1) and reach the published property on a flush
    /// window instead of rebuilding every group's array per result.
    func measureReachability(
        members: [String],
        runToken: LatencyRunToken?
    ) async {
        guard !members.isEmpty else { return }
        let endpoints = activeProfile
            .map { ProfileNamedEndpointInspector.inspect(yaml: $0.yaml) } ?? [:]
        let excludeVirtual = shouldExcludeVirtualInterfaces
        let maxConcurrent = 32

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
        if member.uppercased() == "DIRECT" { return .reachable(5) }
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

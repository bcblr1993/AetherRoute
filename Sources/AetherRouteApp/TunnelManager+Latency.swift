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
            do {
                let latency = try await makeProxySelectionProviderClient()
                    .latency(
                        group: groupName,
                        url: Self.defaultLatencyTestURL,
                        timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
                    )
                guard runToken == currentLatencyRunToken else { return }
                adoptProviderLatency(latency, forGroup: groupName)
                let aggregated = latencyIndex.aggregateChildGroups()
                publishLatency(groups: aggregated.union([groupName]), force: true)
                let measured = proxyLatencies[groupName]?.results ?? []
                Self.runtimeLogger.info(
                    "stage=proxyLatency success results=\(measured.count, privacy: .public) responsive=\(measured.lazy.filter { $0.delayMilliseconds != nil }.count, privacy: .public)"
                )
                return
            } catch {
                Self.runtimeLogger.error(
                    "stage=proxyLatency providerFailed group=\(groupName, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
                )
            }
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

    /// Upgrades the group's selected member from "reachable" to "verified" by
    /// measuring it through the core's real protocol handler.
    ///
    /// Only the selected member is measured. `activeLatency` returns a single
    /// result and does not walk the group, so it stays clear of both the
    /// 64-member `selectorReadinessMaximumMemberCount` ceiling and the engine
    /// lock a full-group `latency` request holds for the length of an entire
    /// sweep. That lock is why measuring every member through the provider
    /// blocked selector traffic for as long as the sweep ran.
    func verifySelectedMemberLatency(
        group groupName: String,
        runToken: LatencyRunToken?
    ) async {
        guard state == .connected, !isUIReviewMode else { return }
        guard let selected = proxySelections[groupName]?.selectedMember,
              !selected.isEmpty else { return }

        do {
            let latency = try await makeProxySelectionProviderClient()
                .activeLatency(
                    group: groupName,
                    url: Self.defaultLatencyTestURL,
                    timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
                )
            guard let result = latency.results
                .first(where: { $0.member == selected })
                ?? latency.results.first
            else { return }
            recordLatency(
                member: selected,
                measurement: result.delayMilliseconds
                    .map { .verified($0) } ?? .timedOut,
                runToken: runToken,
                force: true
            )
            Self.runtimeLogger.info(
                "stage=proxyLatency verified group=\(groupName, privacy: .public) member=\(selected, privacy: .public) delay=\(result.delayMilliseconds.map(String.init) ?? "timeout", privacy: .public)"
            )
        } catch {
            // A failed verification leaves the reachability number alone. It
            // does not manufacture a timeout for a node that answered TCP.
            Self.runtimeLogger.error(
                "stage=proxyLatency verifyFailed group=\(groupName, privacy: .public) member=\(selected, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
            )
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
            if proxySelections[groupName]?.selectedMember == memberName {
                await verifySelectedMemberLatency(
                    group: groupName,
                    runToken: runToken
                )
            } else {
                do {
                    let latency = try await makeProxySelectionProviderClient()
                        .latency(
                            group: groupName,
                            url: Self.defaultLatencyTestURL,
                            timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
                        )
                    guard runToken == currentLatencyRunToken else { return }
                    adoptProviderLatency(latency, forGroup: groupName)
                } catch {
                    Self.runtimeLogger.error(
                        "stage=proxyLatency singleMemberProviderFailed group=\(groupName, privacy: .public) member=\(memberName, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
                    )
                }
            }
            guard runToken == currentLatencyRunToken else { return }
            latencyIndex.aggregateChildGroups()
            let allGroups = (activeProfileSummary?.proxyGroups ?? []).map(\.name)
            publishLatency(groups: allGroups, force: true)
            return
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

    func testAllProxyGroupsLatency() async {
        guard let groups = activeProfileSummary?.proxyGroups, !groups.isEmpty else { return }
        let runToken = prepareLatencyIndex()
        // Only claim the groups this run actually owns, and release exactly
        // those. Releasing every group would clear a testing flag some other
        // in-flight run still depends on.
        let claimed = groups
            .map(\.name)
            .filter { !proxyLatencyRequests.contains($0) }
        guard !claimed.isEmpty else { return }
        proxyLatencyRequests.formUnion(claimed)
        for group in claimed {
            latencyIndex.clear(group: group)
            proxyLatencies[group] = nil
        }
        defer { proxyLatencyRequests.subtract(claimed) }

        if isUIReviewMode {
            try? await Task.sleep(nanoseconds: 120_000_000)
            for group in latencyGroupsSnapshot() {
                for (index, member) in group.members.enumerated() {
                    recordLatency(
                        member: member,
                        measurement: Self.uiReviewMeasurement(
                            member: member,
                            index: index
                        ),
                        runToken: runToken
                    )
                }
            }
            let aggregated = latencyIndex.aggregateChildGroups()
            publishLatency(groups: aggregated.union(claimed), force: true)
            return
        }

        if state == .connected {
            let client = makeProxySelectionProviderClient()
            for group in claimed {
                guard runToken == currentLatencyRunToken else { return }
                do {
                    let latency = try await client.latency(
                        group: group,
                        url: Self.defaultLatencyTestURL,
                        timeoutMilliseconds: Self.uiLatencyTimeoutMilliseconds
                    )
                    guard runToken == currentLatencyRunToken else { return }
                    adoptProviderLatency(latency, forGroup: group)
                } catch {
                    Self.runtimeLogger.error(
                        "stage=allProxyLatency providerFailed group=\(group, privacy: .public) error=\(String(reflecting: error), privacy: .public)"
                    )
                }
            }
            guard runToken == currentLatencyRunToken else { return }
            let aggregated = latencyIndex.aggregateChildGroups()
            publishLatency(groups: aggregated.union(claimed), force: true)
            return
        }

        // Strategy-group names are excluded here rather than probed and
        // repaired afterwards: probing one looks up an endpoint that does not
        // exist, reports a timeout, and showed the row red until aggregation
        // overwrote it.
        await measureReachability(
            members: latencyIndex.probeTargets,
            runToken: runToken
        )

        guard runToken == currentLatencyRunToken else { return }
        let aggregated = latencyIndex.aggregateChildGroups()
        publishLatency(groups: aggregated.union(claimed), force: true)
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

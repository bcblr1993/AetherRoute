import AetherRouteKit
import Darwin
import Foundation
@preconcurrency import NetworkExtension
import OSLog

private enum PacketCoreRuntimeLog {
    static let logger = AppLog.logger(category: AppLog.Category.tunnelCore)
}

protocol CoreBridge: Sendable {
    var isBridgeRunning: Bool { get }
    func start(
        configuration: TunnelConfiguration,
        snapshot: ProviderLaunchSnapshot,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws
    func reloadRules(
        configuration: TunnelConfiguration,
        snapshot: ProviderLaunchSnapshot,
        reloadOutbounds: Bool
    ) throws
    func setMITMConfig(_ configJSON: Data) throws
    func httpCapturesJSON() throws -> Data
    func selectorSnapshot(group: String) throws -> ProxySelectionState
    func setRoutingMode(_ mode: RoutingMode) throws
    func selectProxy(group: String, member: String) throws -> ProxySelectionState
    func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32,
        unifiedDelay: Bool
    ) throws -> ProxyLatencyState
    func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32,
        unifiedDelay: Bool
    ) throws -> ProxyLatencyState
    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot
    func dataPlaneDiagnosticsSnapshot() throws -> DataPlaneDiagnosticSnapshot
    func resetNetworkState(interfaceIndex: UInt32) throws
    /// Closes the active connections an `ARC1` request selects and returns
    /// how many the engine was told to close.
    func closeConnections(request: Data) throws -> UInt64
    /// Signals the engine to stop and calls `completion` as soon as the tunnel
    /// is safe to tear down — it does **not** wait for the engine to unwind.
    /// The join continues on a background queue; see `RustCoreBridge.stop`.
    func stop(completion: @escaping @Sendable () -> Void)
}

extension CoreBridge {
    func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        try testProxyLatency(
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            unifiedDelay: true
        )
    }

    func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        try testActiveProxyLatency(
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds,
            unifiedDelay: true
        )
    }
}

final class RustCoreBridge: CoreBridge, @unchecked Sendable {
    private struct State {
        /// Hot-path gate for packet I/O. Deliberately per-instance and read
        /// under this bridge's own lock: the packet queues must never contend
        /// on the process-wide `EngineLifecycleGate`.
        var isActive = false
        var enableIPv6Output = false
        var bridgeInstalled = false
        var startupFinished = false
        var retainedContext: UnsafeMutableRawPointer?
        var failure: Error?
        /// The process-wide generation this bridge owns, or `nil` before
        /// admission and after the slot is handed back. Every stop request
        /// carries it so a stale bridge cannot cancel its successor's engine.
        var generation: UInt64?
    }

    private let packetFlow: NEPacketTunnelFlow
    private let engineQueue = DispatchQueue(
        label: "com.aetherroute.engine",
        qos: .userInitiated
    )
    private let packetQueue = DispatchQueue(
        label: "com.aetherroute.packet-output",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem
    )
    private let stateLock = NSLock()
    private let lifecycleLock = NSLock()
    private let controlLock = NSLock()
    /// Runs the network-state reset off `controlLock`.
    ///
    /// That lock serializes this bridge's selector buffers and telemetry, and
    /// the host polls telemetry once a second. A reset that blocks while
    /// holding it therefore stalls *every* provider message until macOS decides
    /// the extension is hung and kills it — which is exactly what happened when
    /// the uplink disappeared: one attempt took 4.75s, the next never returned,
    /// and the extension was terminated with the tunnel still installed.
    private let resetQueue = DispatchQueue(
        label: "com.aetherroute.engine-reset",
        qos: .userInitiated
    )
    private let resetLock = NSLock()
    /// True while a submitted reset has not returned. A reset that outran its
    /// caller's budget still occupies the engine, so the next attempt is
    /// refused rather than stacking a second blocked call behind it.
    private var resetInFlight = false
    private var state = State()
    // Telemetry is polled every five seconds while connected. Keeping the
    // trust-boundary-sized destination alive for the bridge lifetime avoids a
    // query snapshot followed by a second copy snapshot on every poll. The
    // control lock serializes all access to this mutable storage.
    private var telemetryOutputBuffer = Data(
        count: NetworkTelemetryCodec.maximumMessageBytes
    )
    private let outgoingPacketLock = NSLock()
    private var outgoingBuffer = PacketTunnelOutputRingBuffer(
        capacity: RustCoreBridge.maximumPendingPackets,
        maxBatchRetries: 2
    )
    private let onUnexpectedExit: (@Sendable (Error) -> Void)?

    var isBridgeRunning: Bool {
        isRunning()
    }

    init(
        packetFlow: NEPacketTunnelFlow,
        onUnexpectedExit: (@Sendable (Error) -> Void)? = nil
    ) {
        self.packetFlow = packetFlow
        self.onUnexpectedExit = onUnexpectedExit
    }

    private struct PreparedEnvironment {
        let profileYAML: String
        let runtimeDirectory: URL
        let restorableSelections: [String: String]
        let defaultGlobalOutbound: String?
    }

    private func prepareEnvironment(
        snapshot: ProviderLaunchSnapshot
    ) throws -> PreparedEnvironment {
        PacketCoreRuntimeLog.logger.info("stage=validateLaunchSnapshot begin")
        try snapshot.validate()
        PacketCoreRuntimeLog.logger.info("stage=validateLaunchSnapshot success")
        PacketCoreRuntimeLog.logger.info("stage=resolveRuntimeStore begin")
        let store = try ActiveProfileStore.applicationGroup()
        PacketCoreRuntimeLog.logger.info("stage=resolveRuntimeStore success")
        let profileYAML = snapshot.bypassPolicy.applyingPacketTunnelDomainBypass(
            to: snapshot.profileYAML
        )
        PacketCoreRuntimeLog.logger.info(
            "stage=installLaunchResources begin count=\(snapshot.routingResources.count, privacy: .public)"
        )
        let resourceStore = RoutingResourceStore(
            applicationSupportDirectory: store.directoryURL
        )
        for (kind, data) in snapshot.routingResources {
            _ = try resourceStore.installUserProvided(data: data, kind: kind)
        }
        _ = try resourceStore.prepareRuntimeResources(for: profileYAML)
        PacketCoreRuntimeLog.logger.info("stage=installLaunchResources success")
        let savedSelections = snapshot.proxySelections
        let profileSummary = ProfileConfigurationInspector.inspect(yaml: profileYAML)
        let seededSelections = InitialProxySelectionPolicy.selections(
            persisted: savedSelections,
            summary: profileSummary
        )
        let manualGroups = Set(
            profileSummary
                .proxyGroups
                .filter { $0.strategy.caseInsensitiveCompare("select") == .orderedSame }
                .map(\.name)
        )
        let restorableSelections = seededSelections.filter {
            manualGroups.contains($0.key) || $0.key == "GLOBAL"
        }
        let defaultGlobalOutbound = Self.resolveDefaultGlobalOutbound(
            summary: profileSummary
        )
        PacketCoreRuntimeLog.logger.info(
            "stage=loadSelections success saved=\(savedSelections.count, privacy: .public) restorable=\(restorableSelections.count, privacy: .public)"
        )
        let runtimeDirectory = store.directoryURL.appendingPathComponent(
            "Runtime",
            isDirectory: true
        )
        PacketCoreRuntimeLog.logger.info("stage=prepareRuntimeDirectory begin")
        do {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            PacketCoreRuntimeLog.logger.error(
                "stage=prepareRuntimeDirectory failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        PacketCoreRuntimeLog.logger.info("stage=prepareRuntimeDirectory success")
        return PreparedEnvironment(
            profileYAML: profileYAML,
            runtimeDirectory: runtimeDirectory,
            restorableSelections: restorableSelections,
            defaultGlobalOutbound: defaultGlobalOutbound
        )
    }

    func start(
        configuration: TunnelConfiguration,
        snapshot: ProviderLaunchSnapshot,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }

        let env = try prepareEnvironment(snapshot: snapshot)
        let profileYAML = env.profileYAML
        let runtimeDirectory = env.runtimeDirectory
        let restorableSelections = env.restorableSelections
        let defaultGlobalOutbound = env.defaultGlobalOutbound
        let dnsPolicy = snapshot.dnsPolicy
        // The host supplies the stable key in ephemeral start options because
        // the Developer ID system extension cannot read the user's Keychain.
        let fakeIPCacheKey = snapshot.fakeIPCacheKey ?? Data()
        guard fakeIPCacheKey.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw ProfileKeyStoreError.invalidKeyLength(fakeIPCacheKey.count)
        }

        // Admission is process-wide, not per-bridge. A replacement provider
        // instance starts with pristine state but inherits whatever engine the
        // previous one left running, so this is the only check that can keep
        // the handle-free engine ABI to one live instance.
        let engineGeneration: UInt64
        switch EngineLifecycleGate.shared.acquireForStart(
            waitingUpTo: .seconds(
                TunnelStartupTimingPolicy.providerEngineHandoffWaitTimeoutSeconds
            )
        ) {
        case let .admitted(generation):
            engineGeneration = generation
        case .rejected:
            PacketCoreRuntimeLog.logger.error(
                "stage=startCore rejected reason=lifecycleBusy schedulingRelaunch"
            )
            EngineLifecycleGate.shared.scheduleProcessRelaunch(
                reason: "lifecycleBusyResidual"
            )
            throw PacketTunnelError.lifecycleBusy
        case let .handoffTimedOut(stuckGeneration):
            PacketCoreRuntimeLog.logger.error(
                "stage=startCore failed reason=engineHandoffTimedOut stuckGeneration=\(stuckGeneration, privacy: .public) timeoutSeconds=\(TunnelStartupTimingPolicy.providerEngineHandoffWaitTimeoutSeconds, privacy: .public)"
            )
            EngineLifecycleGate.shared.scheduleProcessRelaunch(
                reason: "engineHandoffTimedOut"
            )
            throw PacketTunnelError.engineHandoffTimedOut
        }
        stateLock.withLock {
            state = State(
                isActive: true,
                enableIPv6Output: configuration.enableIPv6,
                generation: engineGeneration
            )
        }
        outgoingPacketLock.withLock {
            outgoingBuffer.clear()
        }

        let retainedContext = Unmanaged.passRetained(self).toOpaque()
        PacketCoreRuntimeLog.logger.info("stage=installPacketBridge begin")
        let installed = clash_install_packet_flow(
            aetherRoutePacketOutput,
            retainedContext
        )
        guard installed == 1 else {
            PacketCoreRuntimeLog.logger.error(
                "stage=installPacketBridge failed status=\(installed, privacy: .public)"
            )
            Unmanaged<RustCoreBridge>.fromOpaque(retainedContext).release()
            stateLock.withLock {
                state.isActive = false
                state.generation = nil
            }
            EngineLifecycleGate.shared.abandonStart(generation: engineGeneration)
            throw PacketTunnelError.bridgeInstallationFailed
        }
        PacketCoreRuntimeLog.logger.info("stage=installPacketBridge success")
        stateLock.withLock {
            state.bridgeInstalled = true
            state.retainedContext = retainedContext
        }

        guard let engineCompletion = EngineLifecycleGate.shared.claimEngineCompletion(
            generation: engineGeneration
        ) else {
            PacketCoreRuntimeLog.logger.info(
                "stage=startEngine cancelledBeforeSubmission generation=\(engineGeneration, privacy: .public)"
            )
            stateLock.withLock {
                state.isActive = false
                state.bridgeInstalled = false
                state.retainedContext = nil
                state.generation = nil
            }
            if EngineLifecycleGate.shared.canSafelyUninstallPacketFlow(
                ownedGeneration: engineGeneration
            ) {
                controlLock.withLock { clash_uninstall_packet_flow() }
            }
            releaseContext(retainedContext)
            throw PacketTunnelError.startupCancelled
        }
        beginReadingPackets()
        PacketCoreRuntimeLog.logger.info("stage=startEngine begin")
        startEngine(
            profile: profileYAML,
            runtimeDirectory: runtimeDirectory,
            mtu: configuration.mtu,
            routingMode: configuration.mode,
            enableIPv6: configuration.enableIPv6,
            dnsPolicy: dnsPolicy,
            localProxy: configuration.localProxy,
            controlledListeners: configuration.controlledListeners,
            fakeIPCacheKey: fakeIPCacheKey,
            generation: engineGeneration,
            completionGroup: engineCompletion
        )
        PacketCoreRuntimeLog.logger.info("stage=startEngine submitted")
        PacketCoreRuntimeLog.logger.info(
            "stage=readiness begin timeoutSeconds=\(TunnelStartupTimingPolicy.providerCoreReadinessTimeoutSeconds, privacy: .public)"
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now
                + TunnelStartupTimingPolicy.providerCoreReadinessTimeout
            while ContinuousClock.now < deadline {
                if clash_packet_flow_ready() == 1 {
                    PacketCoreRuntimeLog.logger.info("stage=readiness success")
                    do {
                        PacketCoreRuntimeLog.logger.info("stage=restoreSelections begin")
                        try self.restoreSelections(
                            restorableSelections,
                            defaultGlobalOutbound: defaultGlobalOutbound
                        )
                        PacketCoreRuntimeLog.logger.info("stage=restoreSelections success")
                    } catch {
                        PacketCoreRuntimeLog.logger.error(
                            "stage=restoreSelections failed error=\(String(reflecting: error), privacy: .public)"
                        )
                        if self.finishStartup() {
                            completion(error)
                        }
                        self.stop {}
                        return
                    }
                    if self.finishStartup() {
                        completion(nil)
                    }
                    return
                }
                if let failure = self.currentFailure() {
                    if case let PacketTunnelError.engineFailed(errMsg) = failure {
                        let tail = errMsg.count > 500 ? String(errMsg.suffix(500)) : errMsg
                        PacketCoreRuntimeLog.logger.error(
                            "stage=readiness failed errorTail=\(tail, privacy: .public)"
                        )
                    }
                    PacketCoreRuntimeLog.logger.error(
                        "stage=readiness failed error=\(String(reflecting: failure), privacy: .public)"
                    )
                    if self.finishStartup() {
                        completion(failure)
                    }
                    self.stop {}
                    return
                }
                if !self.isRunning() {
                    PacketCoreRuntimeLog.logger.info("stage=readiness cancelled")
                    if self.finishStartup() {
                        completion(PacketTunnelError.startupCancelled)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }

            if self.finishStartup() {
                PacketCoreRuntimeLog.logger.error("stage=readiness failed reason=timeout")
                completion(PacketTunnelError.readinessTimedOut)
            }
            self.stop {}
        }
    }

    /// Signals the engine to stop and returns as soon as the tunnel is safe to
    /// tear down.
    ///
    /// `completion` fires from the synchronous section, which is bounded by a
    /// few non-blocking FFI calls. This matters because macOS does not remove
    /// the tunnel's interface, routes or DNS until `stopTunnel`'s completion
    /// handler returns: any wait here is time the user spends disconnected
    /// *and* offline. Joining the engine worker is emphatically not bounded —
    /// against an unresponsive node its tasks have taken minutes to unwind — so
    /// it happens afterwards on `EngineLifecycleGate`'s own queue.
    func stop(completion: @escaping @Sendable () -> Void) {
        let handle = beginStop()
        completion()
        guard let handle else { return }
        EngineLifecycleGate.shared.joinStoppedEngine(handle)
    }

    private func beginStop() -> EngineLifecycleGate.StopHandle? {
        lifecycleLock.lock()
        defer { lifecycleLock.unlock() }
        PacketCoreRuntimeLog.logger.info("stage=stopCore requested")

        let owned = stateLock.withLock {
            () -> (generation: UInt64?, context: UnsafeMutableRawPointer?) in
            let generation = state.generation
            let context = state.retainedContext
            state.isActive = false
            state.bridgeInstalled = false
            state.retainedContext = nil
            state.generation = nil
            return (generation, context)
        }
        outgoingPacketLock.withLock {
            outgoingBuffer.clear()
        }

        // The gate rejects a request whose generation is no longer live. That
        // is what stops a stale bridge — a readiness task outliving its
        // provider, say — from draining the engine's process-wide cancellation
        // registry and killing whichever tunnel replaced it.
        guard let handle = EngineLifecycleGate.shared.beginStop(
            requestedBy: owned.generation
        ) else {
            PacketCoreRuntimeLog.logger.info(
                "stage=stopCore skipped reason=notEngineOwner"
            )
            // Normally there is no context here: a bridge only holds one while
            // it owns a generation. The exception is a stop that lands between
            // installing the packet bridge and submitting the engine, where no
            // shutdown is owed but the callback must still be severed before
            // the context it borrows goes away — provided no newer generation
            // has since claimed the packet bridge.
            if owned.context != nil,
               EngineLifecycleGate.shared.canSafelyUninstallPacketFlow(
                   ownedGeneration: owned.generation
               ) {
                controlLock.withLock { clash_uninstall_packet_flow() }
            }
            releaseContext(owned.context)
            return nil
        }

        PacketCoreRuntimeLog.logger.info(
            "stage=shutdownEngine begin generation=\(handle.generation, privacy: .public)"
        )
        // Deliberately outside `controlLock`. That lock serializes this
        // bridge's selector buffers, and a latency probe can hold it for its
        // full timeout against a dead node — the exact situation where the
        // shutdown is most urgently needed. `clash_shutdown` touches none of
        // those buffers; the Rust side guards its own globals.
        let status = clash_shutdown()
        PacketCoreRuntimeLog.logger.info(
            "stage=shutdownEngine status=\(status, privacy: .public)"
        )
        // `clash_shutdown` uninstalls the packet flow itself, so no further
        // callback can reach the retained context once it returns.
        releaseContext(owned.context)
        return handle
    }

    private func releaseContext(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<RustCoreBridge>.fromOpaque(context).release()
    }

    func reloadRules(
        configuration: TunnelConfiguration,
        snapshot: ProviderLaunchSnapshot,
        reloadOutbounds: Bool
    ) throws {
        let env = try prepareEnvironment(snapshot: snapshot)
        let effectiveDNSIPv6: Int32 = configuration.enableIPv6
            ? snapshot.dnsPolicy.ipv6.rawValue
            : DNSRuntimeBoolean.disabled.rawValue
        var dnsPolicyABI = clash_packet_dns_policy_v1_t(
            struct_size: UInt32(
                MemoryLayout<clash_packet_dns_policy_v1_t>.size
            ),
            resolution_mode: snapshot.dnsPolicy.resolutionMode.rawValue,
            ipv6: effectiveDNSIPv6,
            respect_rules: snapshot.dnsPolicy.respectsRules.rawValue
        )
        var localProxyABI = clash_packet_local_proxy_v1_t(
            struct_size: UInt32(
                MemoryLayout<clash_packet_local_proxy_v1_t>.size
            ),
            enabled: configuration.localProxy.isEnabled ? 1 : 0,
            http_port: configuration.localProxy.isEnabled
                ? UInt32(configuration.localProxy.httpPort)
                : 0,
            socks_port: configuration.localProxy.isEnabled
                ? UInt32(configuration.localProxy.socksPort)
                : 0
        )
        let status = try controlLock.withLock { () -> Int32 in
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            return withUnsafePointer(to: &dnsPolicyABI) { policyPointer in
                withUnsafePointer(to: &localProxyABI) { localProxyPointer in
                    env.profileYAML.withCString { profilePointer in
                        env.runtimeDirectory.path.withCString { cwdPointer in
                            clash_packet_reload_rules_v1(
                                profilePointer,
                                cwdPointer,
                                Int32(configuration.mtu),
                                configuration.mode.packetFlowABIValue,
                                policyPointer,
                                localProxyPointer,
                                reloadOutbounds ? 1 : 0
                            )
                        }
                    }
                }
            }
        }
        guard status == CLASH_FLOW_OK else {
            throw Self.selectorError(status, selecting: false)
        }
        if reloadOutbounds {
            try? restoreSelections(
                env.restorableSelections,
                defaultGlobalOutbound: env.defaultGlobalOutbound
            )
        }
    }

    func setMITMConfig(_ configJSON: Data) throws {
        guard configJSON.count <= 4 * 1_024 * 1_024 else {
            throw PacketTunnelSelectorError.rejected
        }
        let status: Int32 = try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            return configJSON.withUnsafeBytes { bytes in
                clash_packet_set_mitm_config_v1(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    configJSON.count
                )
            }
        }
        guard status == CLASH_FLOW_OK else {
            throw Self.selectorError(status, selecting: false)
        }
    }

    func httpCapturesJSON() throws -> Data {
        try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            var required = 0
            let queryStatus = clash_packet_http_captures_v1(nil, 0, &required)
            guard queryStatus == CLASH_FLOW_OK else {
                throw Self.selectorError(queryStatus, selecting: false)
            }
            guard required <= ProxySelectionProviderMessageCodec.maximumMessageBytes - 64 else {
                throw PacketTunnelSelectorError.responseTooLarge
            }
            var capacity = max(required, 2)
            var attempt = 0
            while attempt < 2 {
                defer { attempt += 1 }
                var output = Data(count: capacity)
                var copiedRequired = 0
                let copyStatus = output.withUnsafeMutableBytes { outputBytes in
                    clash_packet_http_captures_v1(
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputBytes.count,
                        &copiedRequired
                    )
                }
                if copyStatus == CLASH_FLOW_OK, copiedRequired <= output.count {
                    output.count = copiedRequired
                    return output
                }
                if copyStatus == CLASH_FLOW_TOO_LARGE,
                   copiedRequired > output.count,
                   copiedRequired <= ProxySelectionProviderMessageCodec.maximumMessageBytes - 64 {
                    capacity = copiedRequired
                    continue
                }
                throw Self.selectorError(copyStatus, selecting: false)
            }
            throw PacketTunnelSelectorError.responseTooLarge
        }
    }

    func selectorSnapshot(group: String) throws -> ProxySelectionState {
        let groupData = try Self.selectorNameData(group)
        return try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            return try selectorSnapshotLocked(group: groupData)
        }
    }

    func setRoutingMode(_ mode: RoutingMode) throws {
        try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            let status = clash_packet_set_routing_mode_v1(
                mode.packetFlowABIValue
            )
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: true)
            }
        }
    }

    func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionState {
        let groupData = try Self.selectorNameData(group)
        let memberData = try Self.selectorNameData(member)
        return try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            let status = groupData.withUnsafeBytes { groupBytes in
                memberData.withUnsafeBytes { memberBytes in
                    clash_packet_selector_select_v1(
                        groupBytes.bindMemory(to: UInt8.self).baseAddress,
                        groupBytes.count,
                        memberBytes.bindMemory(to: UInt8.self).baseAddress,
                        memberBytes.count
                    )
                }
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: true)
            }
            let snapshot = try selectorSnapshotLocked(group: groupData)
            guard snapshot.selectedMember == member else {
                throw PacketTunnelSelectorError.selectionNotApplied
            }
            return snapshot
        }
    }

    func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32,
        unifiedDelay: Bool = true
    ) throws -> ProxyLatencyState {
        let groupData = try Self.selectorNameData(group)
        let urlData = try Self.latencyURLData(url)
        guard
            timeoutMilliseconds >= ProxySelectionProviderMessageCodec
                .minimumLatencyTimeoutMilliseconds,
            timeoutMilliseconds <= ProxySelectionProviderMessageCodec
                .maximumLatencyTimeoutMilliseconds
        else { throw PacketTunnelSelectorError.invalidLatency }
        let packedTimeoutMilliseconds = ProxySelectionProviderMessageCodec
            .packLatencyTimeoutMilliseconds(
                timeoutMilliseconds,
                unifiedDelay: unifiedDelay
            )
        return try {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            guard let outputCapacity = ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(
                    memberCount: TunnelStartupTimingPolicy
                        .selectorReadinessMaximumMemberCount
                )
            else { throw PacketTunnelSelectorError.responseTooLarge }
            var requiredLength = 0
            var output = Data(count: outputCapacity)
            let status = output.withUnsafeMutableBytes { outputBytes in
                groupData.withUnsafeBytes { groupBytes in
                    urlData.withUnsafeBytes { urlBytes in
                        clash_packet_selector_latency_v1(
                            groupBytes.bindMemory(to: UInt8.self).baseAddress,
                            groupBytes.count,
                            urlBytes.bindMemory(to: UInt8.self).baseAddress,
                            urlBytes.count,
                            packedTimeoutMilliseconds,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputBytes.count,
                            &requiredLength
                        )
                    }
                }
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: false)
            }
            guard (8...output.count).contains(requiredLength) else {
                throw PacketTunnelSelectorError.responseTooLarge
            }
            output.count = requiredLength
            return try PacketSelectorLatencyCodec.decode(output)
        }()
    }

    func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32,
        unifiedDelay: Bool = true
    ) throws -> ProxyLatencyState {
        let groupData = try Self.selectorNameData(group)
        let urlData = try Self.latencyURLData(url)
        guard
            timeoutMilliseconds >= ProxySelectionProviderMessageCodec
                .minimumLatencyTimeoutMilliseconds,
            timeoutMilliseconds <= ProxySelectionProviderMessageCodec
                .maximumLatencyTimeoutMilliseconds
        else { throw PacketTunnelSelectorError.invalidLatency }
        let packedTimeoutMilliseconds = ProxySelectionProviderMessageCodec
            .packLatencyTimeoutMilliseconds(
                timeoutMilliseconds,
                unifiedDelay: unifiedDelay
            )
        return try {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            guard let outputCapacity = ProxySelectionProviderMessageCodec
                .maximumSelectorLatencyPayloadBytes(memberCount: 1)
            else { throw PacketTunnelSelectorError.responseTooLarge }
            var requiredLength = 0
            var output = Data(count: outputCapacity)
            let status = output.withUnsafeMutableBytes { outputBytes in
                groupData.withUnsafeBytes { groupBytes in
                    urlData.withUnsafeBytes { urlBytes in
                        clash_packet_selector_active_latency_v1(
                            groupBytes.bindMemory(to: UInt8.self).baseAddress,
                            groupBytes.count,
                            urlBytes.bindMemory(to: UInt8.self).baseAddress,
                            urlBytes.count,
                            packedTimeoutMilliseconds,
                            outputBytes.bindMemory(to: UInt8.self).baseAddress,
                            outputBytes.count,
                            &requiredLength
                        )
                    }
                }
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: false)
            }
            guard (8...output.count).contains(requiredLength) else {
                throw PacketTunnelSelectorError.responseTooLarge
            }
            output.count = requiredLength
            return try PacketSelectorLatencyCodec.decode(output)
        }()
    }

    private static let maximumPacketTunnelTelemetryWireConnections: UInt32 = 160

    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        guard
            maximumConnections > 0,
            Int(maximumConnections) <= NetworkTelemetryCodec.maximumConnections
        else { throw PacketTunnelSelectorError.rejected }
        let boundedConnections = min(
            UInt32(maximumConnections),
            Self.maximumPacketTunnelTelemetryWireConnections
        ) | (1 << 31)
        return try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            var requiredLength = 0
            let status = telemetryOutputBuffer.withUnsafeMutableBytes {
                outputBytes in
                clash_packet_telemetry_snapshot_v4(
                    boundedConnections,
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.count,
                    &requiredLength
                )
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: false)
            }
            guard (48...telemetryOutputBuffer.count).contains(requiredLength)
            else { throw PacketTunnelSelectorError.responseTooLarge }
            return try NetworkTelemetryCodec.decode(
                telemetryOutputBuffer.prefix(requiredLength)
            )
        }
    }

    func closeConnections(request: Data) throws -> UInt64 {
        guard ConnectionCloseRequestCodec.isValid(request) else {
            throw PacketTunnelSelectorError.rejected
        }
        return try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            var closed: UInt64 = 0
            let status = request.withUnsafeBytes { bytes in
                clash_packet_close_connections_v1(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &closed
                )
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: false)
            }
            return closed
        }
    }

    func dataPlaneDiagnosticsSnapshot() throws -> DataPlaneDiagnosticSnapshot {
        try controlLock.withLock {
            guard isRunning(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            var requiredLength = 0
            let sizeStatus = clash_packet_diagnostics_snapshot_v1(nil, 0, &requiredLength)
            guard sizeStatus == CLASH_FLOW_OK, requiredLength == 104 else {
                throw PacketTunnelSelectorError.responseTooLarge
            }
            var output = Data(count: requiredLength)
            let status = output.withUnsafeMutableBytes { bytes in
                clash_packet_diagnostics_snapshot_v1(
                    bytes.bindMemory(to: UInt8.self).baseAddress,
                    bytes.count,
                    &requiredLength
                )
            }
            guard status == CLASH_FLOW_OK, requiredLength == output.count else {
                throw PacketTunnelSelectorError.unavailable
            }
            let bytes = [UInt8](output)
            guard Array(bytes[0..<4]) == [0x41, 0x52, 0x44, 0x31],
                  Array(bytes[4..<8]) == [0, 0, 0, 12] else {
                throw PacketTunnelSelectorError.rejected
            }
            let values = (0..<12).map { index -> UInt64 in
                bytes[(8 + index * 8)..<(16 + index * 8)].reduce(0) {
                    ($0 << 8) | UInt64($1)
                }
            }
            return try DataPlaneDiagnosticSnapshot(values: values)
        }
    }

    /// Rebuilds the engine's view of the host network after the path moved.
    ///
    /// The readiness check runs under `controlLock` like every other engine
    /// query — it is cheap and never touches the network. The reset itself does
    /// not: it is submitted to `resetQueue` and waited on with a bound, so a
    /// call that blocks inside the engine costs this attempt and nothing else.
    /// Recovery treats a `timedOut` the same as any other failure and carries
    /// on to reinstall the tunnel's settings, which does not need the engine.
    func resetNetworkState(interfaceIndex: UInt32) throws {
        // No controlLock: active URL probes can hold it for seconds on a
        // dead uplink. Readiness is atomic in the engine and under stateLock here.
        guard interfaceIndex > 0, isRunning(), clash_packet_flow_ready() == 1 else {
            throw PacketTunnelSelectorError.unavailable
        }
        let admitted = resetLock.withLock { () -> Bool in
            guard !resetInFlight else { return false }
            resetInFlight = true
            return true
        }
        guard admitted else { throw PacketTunnelSelectorError.busy }

        let outcome = EngineResetOutcome()
        // `weak self` deliberately: if the reset never returns, the bridge must
        // still be able to deallocate once the provider lets go of it.
        resetQueue.async { [weak self] in
            guard let self, self.isRunning() else {
                self?.finishReset()
                outcome.complete(Int32(CLASH_FLOW_INVALID_STATE))
                return
            }
            let status = clash_packet_reset_network_state_on_interface_v1(interfaceIndex)
            self.finishReset()
            outcome.complete(status)
        }
        guard outcome.wait(
            seconds: TunnelStartupTimingPolicy.providerNetworkResetWaitSeconds
        ) else {
            throw PacketTunnelSelectorError.timedOut
        }
        guard let status = outcome.status else {
            throw PacketTunnelSelectorError.internalFailure
        }
        guard status == CLASH_FLOW_OK else {
            throw Self.selectorError(status, selecting: false)
        }
    }

    private func finishReset() {
        resetLock.withLock { resetInFlight = false }
    }

    private static let maximumPacketBatchSize: Int = 32
    private static let maximumPendingPackets: Int = 4_096

    fileprivate func writePacket(
        _ data: Data,
        ipVersion: UInt8
    ) {
        let (active, allowIPv6) = stateLock.withLock {
            (state.isActive, state.enableIPv6Output)
        }
        guard active else { return }

        let shouldSchedule: Bool = outgoingPacketLock.withLock {
            outgoingBuffer.enqueue(
                packet: data,
                ipVersion: ipVersion,
                enableIPv6: allowIPv6
            )
        }

        if shouldSchedule {
            packetQueue.async { [weak self] in
                self?.flushPendingPackets()
            }
        }
    }

    private func flushPendingPackets() {
        while true {
            guard isRunning() else {
                outgoingPacketLock.withLock {
                    outgoingBuffer.clear()
                }
                return
            }

            guard let slice = outgoingPacketLock.withLock({
                outgoingBuffer.nextWriteSlice(maxBatchSize: Self.maximumPacketBatchSize)
            }) else {
                return
            }

            let success = autoreleasepool {
                self.packetFlow.writePackets(
                    slice.packets,
                    withProtocols: slice.protocols
                )
            }

            let disposition = outgoingPacketLock.withLock {
                outgoingBuffer.completeWriteSlice(
                    succeeded: success,
                    sliceCount: slice.packets.count
                )
            }

            switch disposition {
            case .continueImmediately:
                continue
            case .drained:
                return
            case .retryAfterBackoff:
                packetQueue.asyncAfter(deadline: .now() + .milliseconds(2)) { [weak self] in
                    self?.flushPendingPackets()
                }
                return
            }
        }
    }

    private func startEngine(
        profile: String,
        runtimeDirectory: URL,
        mtu: Int,
        routingMode: RoutingMode,
        enableIPv6: Bool,
        dnsPolicy: DNSRuntimePolicy,
        localProxy: LocalProxySettings,
        controlledListeners: [ControlledListenerSpec],
        fakeIPCacheKey: Data,
        generation: UInt64,
        completionGroup: DispatchGroup
    ) {
        let cwd = runtimeDirectory.path
        let routingModeABI = routingMode.packetFlowABIValue
        let effectiveDNSIPv6: Int32 = enableIPv6
            ? dnsPolicy.ipv6.rawValue
            : DNSRuntimeBoolean.disabled.rawValue

        engineQueue.async { [weak self] in
            defer { completionGroup.leave() }
            guard let self else { return }
            PacketCoreRuntimeLog.logger.info(
                "stage=engineWorker entered generation=\(generation, privacy: .public)"
            )
            var dnsPolicyABI = clash_packet_dns_policy_v1_t(
                struct_size: UInt32(
                    MemoryLayout<clash_packet_dns_policy_v1_t>.size
                ),
                resolution_mode: dnsPolicy.resolutionMode.rawValue,
                ipv6: effectiveDNSIPv6,
                respect_rules: dnsPolicy.respectsRules.rawValue
            )
            var localProxyABI = clash_packet_local_proxy_v1_t(
                struct_size: UInt32(
                    MemoryLayout<clash_packet_local_proxy_v1_t>.size
                ),
                enabled: localProxy.isEnabled ? 1 : 0,
                http_port: localProxy.isEnabled
                    ? UInt32(localProxy.httpPort)
                    : 0,
                socks_port: localProxy.isEnabled
                    ? UInt32(localProxy.socksPort)
                    : 0
            )
            let result = withUnsafePointer(to: &dnsPolicyABI) { policyPointer in
                withUnsafePointer(to: &localProxyABI) { localProxyPointer in
                    profile.withCString { profilePointer in
                        // Embedded release mode is intentionally silent. Keep
                        // the non-null parameter only for C ABI compatibility;
                        // Rust never opens or writes a packet-flow log file.
                        "".withCString { logPointer in
                            cwd.withCString { cwdPointer in
                                fakeIPCacheKey.withUnsafeBytes { keyBytes in
                                    Self.withControlledListenerABIs(
                                        controlledListeners
                                    ) { listenerPointer, listenerCount in
                                        clash_start_packet_flow_with_policy_local_proxy_cache_and_listeners_v3(
                                            profilePointer,
                                            logPointer,
                                            cwdPointer,
                                            Int32(mtu),
                                            routingModeABI,
                                            policyPointer,
                                            localProxyPointer,
                                            keyBytes.bindMemory(to: UInt8.self).baseAddress,
                                            keyBytes.count,
                                            listenerPointer,
                                            listenerCount,
                                            1
                                        )
                                    }
                                }
                            }
                        }
                    }
                }
            }
            guard let result else {
                PacketCoreRuntimeLog.logger.error("stage=engineWorker failed reason=noResult")
                let failure = PacketTunnelError.engineReturnedNoResult
                let shouldNotifyUnexpectedExit = self.markUnexpectedEngineTermination(
                    failure,
                    generation: generation
                )
                EngineLifecycleGate.shared.retireUnexpectedlyTerminatedEngine(
                    generation: generation
                )
                if shouldNotifyUnexpectedExit {
                    self.onUnexpectedExit?(failure)
                }
                return
            }
            let message = String(cString: result)
            clash_free_string(result)
            if !self.isExpectedStop(generation: generation) {
                let tail = message.count > 500 ? String(message.suffix(500)) : message
                PacketCoreRuntimeLog.logger.error(
                    "stage=engineWorker returned generation=\(generation, privacy: .public) hasMessage=\(!message.isEmpty, privacy: .public) errorTail=\(tail, privacy: .public)"
                )
                let failure: Error = message.isEmpty
                    ? PacketTunnelError.engineStoppedUnexpectedly
                    : PacketTunnelError.engineFailed(message)
                let shouldNotifyUnexpectedExit = self.markUnexpectedEngineTermination(
                    failure,
                    generation: generation
                )
                EngineLifecycleGate.shared.retireUnexpectedlyTerminatedEngine(
                    generation: generation
                )
                if shouldNotifyUnexpectedExit {
                    self.onUnexpectedExit?(failure)
                }
            } else {
                PacketCoreRuntimeLog.logger.info(
                    "stage=engineWorker stopped generation=\(generation, privacy: .public)"
                )
            }
        }
    }

    private func beginReadingPackets() {
        guard isRunning() else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning() else { return }
            autoreleasepool {
                for packet in packets {
                    packet.withUnsafeBytes { bytes in
                        guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
                            return
                        }
                        _ = clash_packet_input(base, bytes.count)
                    }
                }
            }
            self.beginReadingPackets()
        }
    }

    private func restoreSelections(
        _ selections: [String: String],
        defaultGlobalOutbound: String?
    ) throws {
        for (group, member) in selections.sorted(by: { $0.key < $1.key }) where group != "GLOBAL" {
            do {
                _ = try selectProxy(group: group, member: member)
            } catch PacketTunnelSelectorError.rejected {
                // A subscription can keep a selector name while replacing one
                // of its members. Ignore only that stale, profile-bound choice.
            }
        }
        var globalApplied = false
        if let explicitGlobal = selections["GLOBAL"] {
            do {
                _ = try selectProxy(group: "GLOBAL", member: explicitGlobal)
                globalApplied = true
            } catch PacketTunnelSelectorError.rejected {
                globalApplied = false
            }
        }
        if !globalApplied, let defaultGlobalOutbound {
            do {
                _ = try selectProxy(group: "GLOBAL", member: defaultGlobalOutbound)
                globalApplied = true
            } catch PacketTunnelSelectorError.rejected {
                globalApplied = false
            }
        }
        if !globalApplied,
           let globalSnapshot = try? selectorSnapshot(group: "GLOBAL"),
           let candidate = globalSnapshot.members.first(where: InitialProxySelectionPolicy.isRouteCandidate)
        {
            do {
                _ = try selectProxy(group: "GLOBAL", member: candidate)
                globalApplied = true
            } catch PacketTunnelSelectorError.rejected {
                globalApplied = false
            }
        }
        if !globalApplied {
            do {
                _ = try selectProxy(group: "GLOBAL", member: "DIRECT")
            } catch PacketTunnelSelectorError.rejected {
                // Profile defines a custom GLOBAL group without DIRECT; leave its initial member intact.
            }
        }
    }

    static func resolveDefaultGlobalOutbound(
        summary: ProfileConfigurationSummary
    ) -> String? {
        let nonGlobalGroups = summary.proxyGroups.filter {
            $0.name.caseInsensitiveCompare("GLOBAL") != .orderedSame
        }
        let groupNames = Set(nonGlobalGroups.map(\.name))
        let usableProxies = summary.proxies.filter(\.recognition.isUsable)
        let usableProxyNames = Set(usableProxies.map(\.name))

        if let matchTarget = summary.allRules.last(where: {
            let kind = $0.kind.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            return kind == "MATCH" || kind == "FINAL"
        })?.target,
           InitialProxySelectionPolicy.isRouteCandidate(matchTarget),
           groupNames.contains(matchTarget) || usableProxyNames.contains(matchTarget)
        {
            return matchTarget
        }

        if let primarySelectGroup = nonGlobalGroups.first(where: {
            $0.strategy.caseInsensitiveCompare("select") == .orderedSame
                && InitialProxySelectionPolicy.isRouteCandidate($0.name)
        }) {
            return primarySelectGroup.name
        }

        if let primaryGroup = nonGlobalGroups.first(where: {
            InitialProxySelectionPolicy.isRouteCandidate($0.name)
        }) ?? nonGlobalGroups.first {
            return primaryGroup.name
        }

        if let primaryProxy = usableProxies.first(where: {
            InitialProxySelectionPolicy.isRouteCandidate($0.name)
        }) ?? usableProxies.first {
            return primaryProxy.name
        }

        return nil
    }

    private func selectorSnapshotLocked(
        group: Data
    ) throws -> ProxySelectionState {
        var requiredLength = 0
        var status = group.withUnsafeBytes { groupBytes in
            clash_packet_selector_snapshot_v1(
                groupBytes.bindMemory(to: UInt8.self).baseAddress,
                groupBytes.count,
                nil,
                0,
                &requiredLength
            )
        }
        guard status == CLASH_FLOW_OK else {
            throw Self.selectorError(status, selecting: false)
        }

        for _ in 0..<3 {
            guard (12...ProxySelectionProviderMessageCodec.maximumMessageBytes)
                .contains(requiredLength) else {
                throw PacketTunnelSelectorError.responseTooLarge
            }
            var snapshot = Data(count: requiredLength)
            status = snapshot.withUnsafeMutableBytes { outputBytes in
                group.withUnsafeBytes { groupBytes in
                    clash_packet_selector_snapshot_v1(
                        groupBytes.bindMemory(to: UInt8.self).baseAddress,
                        groupBytes.count,
                        outputBytes.bindMemory(to: UInt8.self).baseAddress,
                        outputBytes.count,
                        &requiredLength
                    )
                }
            }
            if status == CLASH_FLOW_TOO_LARGE {
                continue
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: false)
            }
            guard requiredLength == snapshot.count else {
                throw PacketTunnelSelectorError.invalidSnapshot
            }
            return try PacketSelectorSnapshotCodec.decode(snapshot)
        }
        throw PacketTunnelSelectorError.responseTooLarge
    }

    private static func selectorNameData(_ value: String) throws -> Data {
        guard let data = value.data(using: .utf8),
              (1...ProxySelectionProviderMessageCodec.maximumNameBytes)
                .contains(data.count),
              !data.contains(0) else {
            throw PacketTunnelSelectorError.invalidName
        }
        return data
    }

    private static func latencyURLData(_ value: String) throws -> Data {
        guard let data = value.data(using: .utf8),
              (1...ProxySelectionProviderMessageCodec.maximumURLBytes)
                .contains(data.count),
              !data.contains(0),
              value.hasPrefix("https://") || value.hasPrefix("http://") else {
            throw PacketTunnelSelectorError.invalidLatency
        }
        return data
    }

    private static func selectorError(
        _ status: Int32,
        selecting: Bool
    ) -> PacketTunnelSelectorError {
        switch Int(status) {
        case CLASH_FLOW_INVALID_ARGUMENT:
            selecting ? .rejected : .unavailable
        case CLASH_FLOW_INVALID_STATE, CLASH_FLOW_CLOSED, CLASH_FLOW_CANCELLED:
            .unavailable
        case CLASH_FLOW_BACKPRESSURE:
            .busy
        case CLASH_FLOW_TOO_LARGE:
            .responseTooLarge
        default:
            .internalFailure
        }
    }

    private func markUnexpectedEngineTermination(
        _ error: Error,
        generation: UInt64
    ) -> Bool {
        let (matched, contextToRelease, wasPostStartup) = stateLock.withLock {
            () -> (Bool, UnsafeMutableRawPointer?, Bool) in
            guard state.generation == generation else {
                return (false, nil, false)
            }
            let wasPostStartup = state.startupFinished
            let context = state.retainedContext
            state.failure = error
            state.isActive = false
            state.bridgeInstalled = false
            state.retainedContext = nil
            state.generation = nil
            return (true, context, wasPostStartup)
        }
        guard matched else { return false }
        outgoingPacketLock.withLock {
            outgoingBuffer.clear()
        }
        releaseContext(contextToRelease)
        return wasPostStartup
    }

    private func currentFailure() -> Error? {
        stateLock.withLock { state.failure }
    }

    private func isRunning() -> Bool {
        stateLock.withLock { state.isActive }
    }

    /// True when this bridge asked for the engine to stop. `stop` clears both
    /// fields together, so a cleared generation is the stop signal — the engine
    /// worker uses it to tell a requested shutdown from an unexpected exit.
    private func isExpectedStop(generation: UInt64) -> Bool {
        stateLock.withLock { state.generation != generation }
    }

    private func finishStartup() -> Bool {
        stateLock.withLock {
            guard !state.startupFinished else { return false }
            state.startupFinished = true
            return true
        }
    }

    private static func withControlledListenerABIs<T>(
        _ listeners: [ControlledListenerSpec],
        body: (UnsafePointer<clash_packet_controlled_listener_v1_t>?, Int) -> T
    ) -> T {
        guard !listeners.isEmpty else {
            return body(nil, 0)
        }
        var allocatedNames: [UnsafeMutablePointer<CChar>] = []
        allocatedNames.reserveCapacity(listeners.count)
        defer {
            for pointer in allocatedNames {
                free(pointer)
            }
        }
        var abiEntries: [clash_packet_controlled_listener_v1_t] = []
        abiEntries.reserveCapacity(listeners.count)
        for listener in listeners {
            var namePointer: UnsafePointer<CChar>?
            if let duplicated = strdup(listener.name) {
                allocatedNames.append(duplicated)
                namePointer = UnsafePointer(duplicated)
            }
            abiEntries.append(
                clash_packet_controlled_listener_v1_t(
                    struct_size: UInt32(MemoryLayout<clash_packet_controlled_listener_v1_t>.stride),
                    kind: listener.kind.abiKind,
                    port: UInt16(listener.port),
                    reserved: 0,
                    name: namePointer
                )
            )
        }
        return abiEntries.withUnsafeBufferPointer { buffer in
            body(buffer.baseAddress, buffer.count)
        }
    }
}

private func aetherRoutePacketOutput(
    packet: UnsafePointer<UInt8>?,
    length: Int,
    ipVersion: UInt8,
    context: UnsafeMutableRawPointer?
) {
    guard let packet, length > 0, let context else { return }
    let bridge = Unmanaged<RustCoreBridge>
        .fromOpaque(context)
        .takeUnretainedValue()
    bridge.writePacket(Data(bytes: packet, count: length), ipVersion: ipVersion)
}

enum PacketTunnelError: LocalizedError {
    case bridgeInstallationFailed
    case coreUnavailable
    case lifecycleBusy
    case engineFailed(String)
    case engineReturnedNoResult
    case engineStoppedUnexpectedly
    case readinessTimedOut
    case engineHandoffTimedOut
    case startupCancelled

    var errorDescription: String? {
        switch self {
        case .bridgeInstallationFailed:
            "The bounded packet bridge could not be installed."
        case .coreUnavailable:
            "The packet tunnel provider became unavailable during startup."
        case .lifecycleBusy:
            "The previous packet tunnel protocol core is still stopping."
        case let .engineFailed(message):
            "The protocol engine failed: \(message)"
        case .engineReturnedNoResult:
            "The protocol engine stopped without a result."
        case .engineStoppedUnexpectedly:
            "The protocol engine stopped before the tunnel was closed."
        case .readinessTimedOut:
            "The packet tunnel protocol core did not become ready before its bounded startup deadline."
        case .engineHandoffTimedOut:
            "The previous protocol core has not finished stopping. The network extension will restart; try connecting again."
        case .startupCancelled:
            "Packet tunnel startup was cancelled."
        }
    }
}

/// Carries one network-state reset's result across the queue boundary.
///
/// The submitting thread may stop waiting before the engine answers, so the
/// status has to outlive that stack frame — and the late completion must find
/// somewhere safe to land rather than touching an abandoned caller.
private final class EngineResetOutcome: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value: Int32?

    func complete(_ status: Int32) {
        lock.withLock { value = status }
        semaphore.signal()
    }

    /// Returns `true` when the engine answered inside the budget.
    func wait(seconds: TimeInterval) -> Bool {
        semaphore.wait(timeout: .now() + seconds) == .success
    }

    var status: Int32? {
        lock.withLock { value }
    }
}

enum PacketTunnelSelectorError: Error, Sendable, Equatable {
    case invalidName
    case unavailable
    case rejected
    case busy
    case responseTooLarge
    case invalidSnapshot
    case invalidLatency
    case selectionNotApplied
    case internalFailure
    /// The engine did not finish within the caller's budget. The call is still
    /// running on its own queue; the caller has simply stopped waiting.
    case timedOut
}

private enum PacketSelectorSnapshotCodec {
    private static let magic: [UInt8] = [0x41, 0x52, 0x53, 0x31]
    private static let noSelection = UInt32.max

    static func decode(_ data: Data) throws -> ProxySelectionState {
        let bytes = [UInt8](data)
        guard bytes.count >= 12,
              Array(bytes[0..<4]) == magic,
              let selectedIndex = readUInt32(bytes, at: 4),
              let memberCount = readUInt32(bytes, at: 8),
              memberCount <= ProxySelectionProviderMessageCodec.maximumMemberCount else {
            throw PacketTunnelSelectorError.invalidSnapshot
        }
        var offset = 12
        var members: [String] = []
        members.reserveCapacity(Int(memberCount))
        for _ in 0..<memberCount {
            guard let length = readUInt32(bytes, at: offset),
                  (1...ProxySelectionProviderMessageCodec.maximumNameBytes)
                    .contains(Int(length)) else {
                throw PacketTunnelSelectorError.invalidSnapshot
            }
            offset += 4
            let (end, overflow) = offset.addingReportingOverflow(Int(length))
            guard !overflow, end <= bytes.count else {
                throw PacketTunnelSelectorError.invalidSnapshot
            }
            let valueBytes = bytes[offset..<end]
            guard !valueBytes.contains(0),
                  let value = String(bytes: valueBytes, encoding: .utf8) else {
                throw PacketTunnelSelectorError.invalidSnapshot
            }
            members.append(value)
            offset = end
        }
        guard offset == bytes.count else {
            throw PacketTunnelSelectorError.invalidSnapshot
        }
        let selectedMember: String?
        if selectedIndex == noSelection {
            selectedMember = nil
        } else {
            guard Int(selectedIndex) < members.count else {
                throw PacketTunnelSelectorError.invalidSnapshot
            }
            selectedMember = members[Int(selectedIndex)]
        }
        return ProxySelectionState(
            selectedMember: selectedMember,
            members: members
        )
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

private enum PacketSelectorLatencyCodec {
    private static let magic: [UInt8] = [0x41, 0x52, 0x4c, 0x31]

    static func decode(_ data: Data) throws -> ProxyLatencyState {
        let bytes = [UInt8](data)
        guard bytes.count >= 8,
              Array(bytes[0..<4]) == magic,
              let count = readUInt32(bytes, at: 4),
              count <= ProxySelectionProviderMessageCodec.maximumMemberCount else {
            throw PacketTunnelSelectorError.invalidLatency
        }
        var offset = 8
        var results: [ProxyLatencyResult] = []
        results.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let length = readUInt32(bytes, at: offset),
                  (1...ProxySelectionProviderMessageCodec.maximumNameBytes)
                    .contains(Int(length)) else {
                throw PacketTunnelSelectorError.invalidLatency
            }
            offset += 4
            let (end, overflow) = offset.addingReportingOverflow(Int(length))
            guard !overflow, end + 4 <= bytes.count else {
                throw PacketTunnelSelectorError.invalidLatency
            }
            let nameBytes = bytes[offset..<end]
            guard !nameBytes.contains(0),
                  let member = String(bytes: nameBytes, encoding: .utf8),
                  let delay = readUInt32(bytes, at: end) else {
                throw PacketTunnelSelectorError.invalidLatency
            }
            results.append(
                ProxyLatencyResult(
                    member: member,
                    delayMilliseconds: delay == UInt32.max ? nil : delay
                )
            )
            offset = end + 4
        }
        guard offset == bytes.count else {
            throw PacketTunnelSelectorError.invalidLatency
        }
        return ProxyLatencyState(results: results)
    }

    private static func readUInt32(
        _ bytes: [UInt8],
        at offset: Int
    ) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        return UInt32(bytes[offset]) << 24
            | UInt32(bytes[offset + 1]) << 16
            | UInt32(bytes[offset + 2]) << 8
            | UInt32(bytes[offset + 3])
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try operation()
    }
}

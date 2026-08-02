import AetherRouteKit
import Darwin
import Foundation
@preconcurrency import NetworkExtension

protocol CoreBridge: Sendable {
    func start(
        configuration: TunnelConfiguration,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws
    func selectorSnapshot(group: String) throws -> ProxySelectionState
    func selectProxy(group: String, member: String) throws -> ProxySelectionState
    func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState
    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot
    func stop()
}

final class RustCoreBridge: CoreBridge, @unchecked Sendable {
    private struct State {
        var running = false
        var stopping = false
        var bridgeInstalled = false
        var startupFinished = false
        var retainedContext: UnsafeMutableRawPointer?
        var failure: Error?
    }

    private let packetFlow: NEPacketTunnelFlow
    private let engineQueue = DispatchQueue(
        label: "com.aetherroute.engine",
        qos: .userInitiated
    )
    private let packetQueue = DispatchQueue(
        label: "com.aetherroute.packet-output",
        qos: .userInitiated
    )
    private let stateLock = NSLock()
    private let controlLock = NSLock()
    private var state = State()

    init(packetFlow: NEPacketTunnelFlow) {
        self.packetFlow = packetFlow
    }

    func start(
        configuration: TunnelConfiguration,
        completion: @escaping @Sendable (Error?) -> Void
    ) throws {
        let store = try ActiveProfileStore.applicationGroup()
        let profile = try store.loadValidated()
        let dnsPolicy = try DNSRuntimePolicyStore.applicationGroup().load(
            forProfileYAML: profile.yaml
        )
        let savedSelections = try ProxySelectionStore.applicationGroup()
            .selections(forProfileYAML: profile.yaml)
        let manualGroups = Set(
            ProfileConfigurationInspector.inspect(yaml: profile.yaml)
                .proxyGroups
                .filter { $0.strategy.caseInsensitiveCompare("select") == .orderedSame }
                .map(\.name)
        )
        let restorableSelections = savedSelections.filter {
            manualGroups.contains($0.key)
        }
        let runtimeDirectory = store.directoryURL.appendingPathComponent(
            "Runtime",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )

        stateLock.withLock {
            state = State(running: true)
        }

        let retainedContext = Unmanaged.passRetained(self).toOpaque()
        let installed = clash_install_packet_flow(
            aetherRoutePacketOutput,
            retainedContext
        )
        guard installed == 1 else {
            Unmanaged<RustCoreBridge>.fromOpaque(retainedContext).release()
            stateLock.withLock { state.running = false }
            throw PacketTunnelError.bridgeInstallationFailed
        }
        stateLock.withLock {
            state.bridgeInstalled = true
            state.retainedContext = retainedContext
        }

        beginReadingPackets()
        startEngine(
            profile: profile.yaml,
            runtimeDirectory: runtimeDirectory,
            mtu: configuration.mtu,
            routingMode: configuration.mode,
            dnsPolicy: dnsPolicy,
            localProxy: configuration.localProxy
        )

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now + .seconds(8)
            while ContinuousClock.now < deadline {
                if clash_packet_flow_ready() == 1 {
                    do {
                        try self.restoreSelections(restorableSelections)
                    } catch {
                        if self.finishStartup() {
                            completion(error)
                        }
                        self.stop()
                        return
                    }
                    if self.finishStartup() {
                        completion(nil)
                    }
                    return
                }
                if let failure = self.currentFailure() {
                    if self.finishStartup() {
                        completion(failure)
                    }
                    self.stop()
                    return
                }
                if !self.isRunning() {
                    if self.finishStartup() {
                        completion(PacketTunnelError.startupCancelled)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(25))
            }

            if self.finishStartup() {
                completion(PacketTunnelError.readinessTimedOut)
            }
            self.stop()
        }
    }

    func stop() {
        let retainedContext = stateLock.withLock {
            guard state.bridgeInstalled, !state.stopping else {
                return Optional<UnsafeMutableRawPointer>.none
            }
            state.running = false
            state.stopping = true
            state.bridgeInstalled = false
            let context = state.retainedContext
            state.retainedContext = nil
            return context
        }
        guard let retainedContext else { return }

        controlLock.withLock {
            _ = clash_shutdown()
            clash_uninstall_packet_flow()
        }
        stateLock.withLock { state.stopping = false }
        Unmanaged<RustCoreBridge>.fromOpaque(retainedContext).release()
    }

    func selectorSnapshot(group: String) throws -> ProxySelectionState {
        let groupData = try Self.selectorNameData(group)
        return try controlLock.withLock {
            guard isRunning(), !isStopping(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            return try selectorSnapshotLocked(group: groupData)
        }
    }

    func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionState {
        let groupData = try Self.selectorNameData(group)
        let memberData = try Self.selectorNameData(member)
        return try controlLock.withLock {
            guard isRunning(), !isStopping(), clash_packet_flow_ready() == 1 else {
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
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        let groupData = try Self.selectorNameData(group)
        let urlData = try Self.latencyURLData(url)
        guard
            timeoutMilliseconds >= ProxySelectionProviderMessageCodec
                .minimumLatencyTimeoutMilliseconds,
            timeoutMilliseconds <= ProxySelectionProviderMessageCodec
                .maximumLatencyTimeoutMilliseconds
        else { throw PacketTunnelSelectorError.invalidLatency }
        return try controlLock.withLock {
            guard isRunning(), !isStopping(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            var requiredLength = 0
            var output = Data(
                count: ProxySelectionProviderMessageCodec.maximumMessageBytes
            )
            let status = output.withUnsafeMutableBytes { outputBytes in
                groupData.withUnsafeBytes { groupBytes in
                    urlData.withUnsafeBytes { urlBytes in
                        clash_packet_selector_latency_v1(
                            groupBytes.bindMemory(to: UInt8.self).baseAddress,
                            groupBytes.count,
                            urlBytes.bindMemory(to: UInt8.self).baseAddress,
                            urlBytes.count,
                            timeoutMilliseconds,
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
        }
    }

    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        guard
            maximumConnections > 0,
            Int(maximumConnections) <= NetworkTelemetryCodec.maximumConnections
        else { throw PacketTunnelSelectorError.rejected }
        return try controlLock.withLock {
            guard isRunning(), !isStopping(), clash_packet_flow_ready() == 1 else {
                throw PacketTunnelSelectorError.unavailable
            }
            var requiredLength = 0
            var output = Data(count: NetworkTelemetryCodec.maximumMessageBytes)
            let status = output.withUnsafeMutableBytes { outputBytes in
                clash_packet_telemetry_snapshot_v1(
                    UInt32(maximumConnections),
                    outputBytes.bindMemory(to: UInt8.self).baseAddress,
                    outputBytes.count,
                    &requiredLength
                )
            }
            guard status == CLASH_FLOW_OK else {
                throw Self.selectorError(status, selecting: false)
            }
            guard (48...output.count).contains(requiredLength) else {
                throw PacketTunnelSelectorError.responseTooLarge
            }
            output.count = requiredLength
            return try NetworkTelemetryCodec.decode(output)
        }
    }

    fileprivate func writePacket(
        _ data: Data,
        ipVersion: UInt8
    ) {
        guard ipVersion == 4 || ipVersion == 6 else { return }
        let family = NSNumber(value: ipVersion == 6 ? AF_INET6 : AF_INET)
        packetQueue.async { [weak self] in
            guard let self, self.isRunning() else { return }
            _ = self.packetFlow.writePackets([data], withProtocols: [family])
        }
    }

    private func startEngine(
        profile: String,
        runtimeDirectory: URL,
        mtu: Int,
        routingMode: RoutingMode,
        dnsPolicy: DNSRuntimePolicy,
        localProxy: LocalProxySettings
    ) {
        let cwd = runtimeDirectory.path
        let routingModeABI = routingMode.packetFlowABIValue

        engineQueue.async { [weak self] in
            guard let self else { return }
            var dnsPolicyABI = clash_packet_dns_policy_v1_t(
                struct_size: UInt32(
                    MemoryLayout<clash_packet_dns_policy_v1_t>.size
                ),
                resolution_mode: dnsPolicy.resolutionMode.rawValue,
                ipv6: dnsPolicy.ipv6.rawValue,
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
                                clash_start_packet_flow_with_policy_and_local_proxy_v1(
                                    profilePointer,
                                    logPointer,
                                    cwdPointer,
                                    Int32(mtu),
                                    routingModeABI,
                                    policyPointer,
                                    localProxyPointer,
                                    1
                                )
                            }
                        }
                    }
                }
            }
            guard let result else {
                self.recordFailure(PacketTunnelError.engineReturnedNoResult)
                return
            }
            let message = String(cString: result)
            clash_free_string(result)
            if !self.isStopping() {
                self.recordFailure(
                    message.isEmpty
                        ? PacketTunnelError.engineStoppedUnexpectedly
                        : PacketTunnelError.engineFailed(message)
                )
            }
        }
    }

    private func beginReadingPackets() {
        guard isRunning() else { return }
        packetFlow.readPackets { [weak self] packets, _ in
            guard let self, self.isRunning() else { return }
            for packet in packets {
                packet.withUnsafeBytes { bytes in
                    guard let base = bytes.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    _ = clash_packet_input(base, bytes.count)
                }
            }
            self.beginReadingPackets()
        }
    }

    private func restoreSelections(_ selections: [String: String]) throws {
        for (group, member) in selections.sorted(by: { $0.key < $1.key }) {
            do {
                _ = try selectProxy(group: group, member: member)
            } catch PacketTunnelSelectorError.rejected {
                // A subscription can keep a selector name while replacing one
                // of its members. Ignore only that stale, profile-bound choice.
            }
        }
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

    private func recordFailure(_ error: Error) {
        stateLock.withLock {
            state.failure = error
        }
    }

    private func currentFailure() -> Error? {
        stateLock.withLock { state.failure }
    }

    private func isRunning() -> Bool {
        stateLock.withLock { state.running }
    }

    private func isStopping() -> Bool {
        stateLock.withLock { state.stopping }
    }

    private func finishStartup() -> Bool {
        stateLock.withLock {
            guard !state.startupFinished else { return false }
            state.startupFinished = true
            return true
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
    case engineFailed(String)
    case engineReturnedNoResult
    case engineStoppedUnexpectedly
    case readinessTimedOut
    case startupCancelled

    var errorDescription: String? {
        switch self {
        case .bridgeInstallationFailed:
            "The bounded packet bridge could not be installed."
        case .coreUnavailable:
            "The packet tunnel provider became unavailable during startup."
        case let .engineFailed(message):
            "The protocol engine failed: \(message)"
        case .engineReturnedNoResult:
            "The protocol engine stopped without a result."
        case .engineStoppedUnexpectedly:
            "The protocol engine stopped before the tunnel was closed."
        case .readinessTimedOut:
            "The packet tunnel did not become ready within eight seconds."
        case .startupCancelled:
            "Packet tunnel startup was cancelled."
        }
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

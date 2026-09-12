import AetherRouteKit
import AetherRouteTransparentProxySupport
import Foundation
import OSLog

private enum FlowCoreRuntimeLog {
    static let logger = AppLog.logger(category: AppLog.Category.flowEngine)
}

public struct FlowCoreEngineConfiguration: Sendable, Equatable {
    public static let `default` = FlowCoreEngineConfiguration()

    public let workerThreads: Int
    public let queueDepth: Int
    public let maximumTCPChunkBytes: Int
    public let maximumUDPPayloadBytes: Int
    public let routingMode: RoutingMode?

    public init(
        workerThreads: Int = 2,
        queueDepth: Int = 32,
        maximumTCPChunkBytes: Int = 64 * 1_024,
        maximumUDPPayloadBytes: Int = UDPBatchPolicy.maximumPayloadBytes,
        routingMode: RoutingMode? = nil
    ) {
        self.workerThreads = workerThreads
        self.queueDepth = queueDepth
        self.maximumTCPChunkBytes = maximumTCPChunkBytes
        self.maximumUDPPayloadBytes = maximumUDPPayloadBytes
        self.routingMode = routingMode
    }

    @discardableResult
    public func validated() throws -> FlowCoreEngineConfiguration {
        guard (1...8).contains(workerThreads) else {
            throw FlowCoreEngineError.invalidConfiguration
        }
        guard (1...64).contains(queueDepth) else {
            throw FlowCoreEngineError.invalidConfiguration
        }
        guard (1...(1_024 * 1_024)).contains(maximumTCPChunkBytes) else {
            throw FlowCoreEngineError.invalidConfiguration
        }
        guard
            (1...UDPBatchPolicy.maximumPayloadBytes)
                .contains(maximumUDPPayloadBytes)
        else {
            throw FlowCoreEngineError.invalidConfiguration
        }
        return self
    }
}

public enum FlowCoreEngineError: Error, Sendable, Equatable {
    case flowABIUnavailable
    case invalidConfiguration
    case invalidProfile
    case unsupportedProfile
    case startupFailed
    case engineClosed
    case invalidEndpoint
    case resourceExhausted
    case selectorUnavailable
    case selectionRejected
    case invalidSelectorSnapshot
    case invalidLatencyResult
    case internalFailure
}

public typealias ProxySelectionSnapshot = ProxySelectionState

/// One independent, listener-free Rust FlowOnly runtime.
///
/// The object owns every staged flow it creates. `shutdown` first crosses all
/// per-flow callback barriers and only then destroys this engine. Dropping the
/// Swift facade starts the same safe shutdown path; no process-global runtime
/// or protocol state is used by this bridge.
public final class FlowCoreEngine: @unchecked Sendable {
    private let storage: FlowCoreEngineStorage

    public convenience init(
        profile: Data,
        runtimeDirectory: URL,
        configuration: FlowCoreEngineConfiguration = .default
    ) throws {
        FlowCoreRuntimeLog.logger.info("stage=loadFlowABI begin")
        let backend: LiveFlowCoreABIBackend
        do {
            backend = try LiveFlowCoreABIBackend()
        } catch {
            FlowCoreRuntimeLog.logger.error(
                "stage=loadFlowABI failed error=\(String(reflecting: error), privacy: .public)"
            )
            throw error
        }
        FlowCoreRuntimeLog.logger.info("stage=loadFlowABI success")
        try self.init(
            profile: profile,
            runtimeDirectory: runtimeDirectory,
            configuration: configuration,
            backend: backend
        )
    }

    init(
        profile: Data,
        runtimeDirectory: URL,
        configuration: FlowCoreEngineConfiguration,
        backend: any FlowCoreABIBackend
    ) throws {
        let validated = try configuration.validated()
        guard !profile.isEmpty, profile.count <= 8 * 1_024 * 1_024 else {
            throw FlowCoreEngineError.invalidProfile
        }
        guard
            runtimeDirectory.isFileURL,
            runtimeDirectory.path.hasPrefix("/"),
            let directory = runtimeDirectory.path.data(using: .utf8),
            !directory.isEmpty,
            directory.count <= 4_096,
            !directory.contains(0)
        else {
            throw FlowCoreEngineError.invalidConfiguration
        }

        let created = backend.engineCreate(
            profile: profile,
            workingDirectory: directory,
            configuration: validated
        )
        FlowCoreRuntimeLog.logger.info(
            "stage=createEngine status=\(created.status, privacy: .public)"
        )
        guard
            created.status == FlowCoreABIStatus.success,
            let handle = created.handle
        else {
            FlowCoreRuntimeLog.logger.error(
                "stage=createEngine failed status=\(created.status, privacy: .public)"
            )
            throw Self.engineError(for: created.status)
        }
        storage = FlowCoreEngineStorage(backend: backend, handle: handle)
        FlowCoreRuntimeLog.logger.info("stage=createEngine success")
    }

    public func makeTCPFlow(
        source: FlowEndpoint?,
        destination: FlowEndpoint
    ) throws -> any RustTCPFlowBridge {
        try storage.makeTCPFlow(source: source, destination: destination)
    }

    public func makeUDPFlow(
        source: FlowEndpoint
    ) throws -> any RustUDPFlowBridge {
        try storage.makeUDPFlow(source: source)
    }

    public func selectorSnapshot(group: String) throws -> ProxySelectionSnapshot {
        try storage.selectorSnapshot(group: group)
    }

    public func setRoutingMode(_ mode: RoutingMode) throws {
        try storage.setRoutingMode(mode)
    }

    @discardableResult
    public func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionSnapshot {
        try storage.selectProxy(group: group, member: member)
    }

    public func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        try storage.testProxyLatency(
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        try storage.testActiveProxyLatency(
            group: group,
            url: url,
            timeoutMilliseconds: timeoutMilliseconds
        )
    }

    public func telemetrySnapshot(
        maximumConnections: UInt16 = 50
    ) throws -> NetworkTelemetrySnapshot {
        try storage.telemetrySnapshot(maximumConnections: maximumConnections)
    }

    /// Idempotent engine callback barrier. Completion is never invoked from a
    /// Rust callback and runs only after all child flow destroy barriers.
    public func shutdown(completion: @escaping @Sendable () -> Void) {
        storage.shutdown(completion: completion)
    }

    deinit {
        storage.shutdown {}
    }

    private static func engineError(for status: Int32) -> FlowCoreEngineError {
        switch status {
        case FlowCoreABIStatus.invalidProfile:
            .invalidProfile
        case FlowCoreABIStatus.unsupportedProfile:
            .unsupportedProfile
        case FlowCoreABIStatus.startupFailed:
            .startupFailed
        case FlowCoreABIStatus.invalidArgument:
            .invalidConfiguration
        case FlowCoreABIStatus.closed, FlowCoreABIStatus.cancelled:
            .engineClosed
        case FlowCoreABIStatus.backpressure:
            .resourceExhausted
        default:
            .internalFailure
        }
    }
}

private final class FlowCoreEngineStorage: @unchecked Sendable {
    private enum Phase {
        case running
        case shuttingDown
        case destroyed
    }

    private let backend: any FlowCoreABIBackend
    private let queue = DispatchQueue(
        label: "com.example.aetherroute.flow-core.engine",
        qos: .userInitiated
    )
    private let gate = NSLock()
    private var acceptsFlows = true
    private var shutdownStarted = false
    private var shutdownFinished = false
    private var shutdownSelfRetain: FlowCoreEngineStorage?
    private var phase: Phase = .running
    private var handle: FlowCoreABIHandle?
    private var flows: [UUID: FlowCoreFlowStorage] = [:]
    private var shutdownCompletions: [@Sendable () -> Void] = []
    private var pendingShutdownFlows: Set<UUID> = []

    init(backend: any FlowCoreABIBackend, handle: FlowCoreABIHandle) {
        self.backend = backend
        self.handle = handle
    }

    func makeTCPFlow(
        source: FlowEndpoint?,
        destination: FlowEndpoint
    ) throws -> any RustTCPFlowBridge {
        let destination = try validatedEndpoint(
            destination,
            transport: .tcp,
            requiresIPAddress: false
        )
        let source = try source.map {
            try validatedEndpoint(
                $0,
                transport: .tcp,
                requiresIPAddress: true
            )
        }
        let destinationData = try FlowEndpointCodec.encode(destination)
        let sourceData = try source.map(FlowEndpointCodec.encode)

        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let created = backend.tcpCreate(
                    engine: handle,
                    source: sourceData,
                    destination: destinationData
                )
                FlowCoreRuntimeLog.logger.debug(
                    "stage=createFlow transport=tcp status=\(created.status, privacy: .public)"
                )
                guard
                    created.status == FlowCoreABIStatus.success,
                    let flowHandle = created.handle
                else {
                    throw Self.flowCreationError(created.status)
                }
                let storage = FlowCoreFlowStorage(
                    kind: .tcp,
                    backend: backend,
                    handle: flowHandle,
                    owner: self
                )
                flows[storage.id] = storage
                return FlowCoreTCPBridge(storage: storage)
            }
        }
    }

    func makeUDPFlow(
        source: FlowEndpoint
    ) throws -> any RustUDPFlowBridge {
        let source = try validatedEndpoint(
            source,
            transport: .udp,
            requiresIPAddress: true
        )
        let sourceData = try FlowEndpointCodec.encode(source)

        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let created = backend.udpCreate(
                    engine: handle,
                    source: sourceData
                )
                FlowCoreRuntimeLog.logger.debug(
                    "stage=createFlow transport=udp status=\(created.status, privacy: .public)"
                )
                guard
                    created.status == FlowCoreABIStatus.success,
                    let flowHandle = created.handle
                else {
                    throw Self.flowCreationError(created.status)
                }
                let storage = FlowCoreFlowStorage(
                    kind: .udp,
                    backend: backend,
                    handle: flowHandle,
                    owner: self
                )
                flows[storage.id] = storage
                return FlowCoreUDPBridge(storage: storage)
            }
        }
    }

    func selectorSnapshot(group: String) throws -> ProxySelectionSnapshot {
        let group = try Self.selectorNameData(group)
        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let result = backend.selectorSnapshot(
                    engine: handle,
                    group: group
                )
                guard
                    result.status == FlowCoreABIStatus.success,
                    let snapshot = result.snapshot
                else {
                    throw Self.selectorError(result.status, selecting: false)
                }
                return try ProxySelectionSnapshotCodec.decode(snapshot)
            }
        }
    }

    func setRoutingMode(_ mode: RoutingMode) throws {
        try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let status = backend.engineSetRoutingMode(handle, mode: mode)
                guard status == FlowCoreABIStatus.success else {
                    throw Self.routingModeError(status)
                }
            }
        }
    }

    func selectProxy(
        group: String,
        member: String
    ) throws -> ProxySelectionSnapshot {
        let group = try Self.selectorNameData(group)
        let member = try Self.selectorNameData(member)
        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let status = backend.selectorSelect(
                    engine: handle,
                    group: group,
                    member: member
                )
                guard status == FlowCoreABIStatus.success else {
                    throw Self.selectorError(status, selecting: true)
                }
                let result = backend.selectorSnapshot(
                    engine: handle,
                    group: group
                )
                guard
                    result.status == FlowCoreABIStatus.success,
                    let snapshot = result.snapshot
                else {
                    throw Self.selectorError(result.status, selecting: false)
                }
                return try ProxySelectionSnapshotCodec.decode(snapshot)
            }
        }
    }

    func testProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        let group = try Self.selectorNameData(group)
        let url = try Self.latencyURLData(url)
        guard
            timeoutMilliseconds >= ProxySelectionProviderMessageCodec
                .minimumLatencyTimeoutMilliseconds,
            timeoutMilliseconds <= ProxySelectionProviderMessageCodec
                .maximumLatencyTimeoutMilliseconds
        else { throw FlowCoreEngineError.selectorUnavailable }
        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let result = backend.selectorLatency(
                    engine: handle,
                    group: group,
                    url: url,
                    timeoutMilliseconds: timeoutMilliseconds
                )
                guard
                    result.status == FlowCoreABIStatus.success,
                    let latencies = result.latencies
                else {
                    throw Self.selectorError(result.status, selecting: false)
                }
                return try ProxyLatencyResultCodec.decode(latencies)
            }
        }
    }

    func testActiveProxyLatency(
        group: String,
        url: String,
        timeoutMilliseconds: UInt32
    ) throws -> ProxyLatencyState {
        let group = try Self.selectorNameData(group)
        let url = try Self.latencyURLData(url)
        guard
            timeoutMilliseconds >= ProxySelectionProviderMessageCodec
                .minimumLatencyTimeoutMilliseconds,
            timeoutMilliseconds <= ProxySelectionProviderMessageCodec
                .maximumLatencyTimeoutMilliseconds
        else { throw FlowCoreEngineError.selectorUnavailable }
        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let result = backend.selectorActiveLatency(
                    engine: handle,
                    group: group,
                    url: url,
                    timeoutMilliseconds: timeoutMilliseconds
                )
                guard
                    result.status == FlowCoreABIStatus.success,
                    let latencies = result.latencies
                else {
                    throw Self.selectorError(result.status, selecting: false)
                }
                return try ProxyLatencyResultCodec.decode(latencies)
            }
        }
    }

    func telemetrySnapshot(
        maximumConnections: UInt16
    ) throws -> NetworkTelemetrySnapshot {
        guard
            maximumConnections > 0,
            Int(maximumConnections) <= NetworkTelemetryCodec.maximumConnections
        else { throw FlowCoreEngineError.selectorUnavailable }
        return try gate.withLock {
            guard acceptsFlows else { throw FlowCoreEngineError.engineClosed }
            return try queue.sync {
                guard phase == .running, let handle else {
                    throw FlowCoreEngineError.engineClosed
                }
                let result = backend.telemetrySnapshot(
                    engine: handle,
                    maximumConnections: UInt32(maximumConnections)
                )
                guard
                    result.status == FlowCoreABIStatus.success,
                    let snapshot = result.snapshot
                else {
                    throw Self.selectorError(result.status, selecting: false)
                }
                return try NetworkTelemetryCodec.decode(snapshot)
            }
        }
    }

    func shutdown(completion: @escaping @Sendable () -> Void) {
        let action = gate.withLock { () -> ShutdownAdmission in
            if shutdownFinished {
                return .complete
            }
            if shutdownStarted {
                shutdownCompletions.append(completion)
                return .none
            }
            acceptsFlows = false
            shutdownStarted = true
            // The public facade may be deinitialized immediately after it
            // requests shutdown. Retain this storage through every child and
            // engine callback barrier, then break the cycle at completion.
            shutdownSelfRetain = self
            shutdownCompletions.append(completion)
            queue.async { [self] in beginShutdown() }
            return .none
        }
        if action == .complete {
            queue.async(execute: completion)
        }
    }

    func flowDidDestroy(_ id: UUID) {
        queue.async { [self] in
            flows.removeValue(forKey: id)
        }
    }

    private func beginShutdown() {
        guard phase == .running else { return }
        phase = .shuttingDown
        let activeFlows = Array(flows.values)
        pendingShutdownFlows = Set(activeFlows.map(\.id))
        guard !activeFlows.isEmpty else {
            destroyEngine()
            return
        }
        for flow in activeFlows {
            flow.destroy { [weak self] in
                guard let self else { return }
                queue.async { [self] in
                    flowBarrierCompleted(flow.id)
                }
            }
        }
    }

    private func flowBarrierCompleted(_ id: UUID) {
        flows.removeValue(forKey: id)
        pendingShutdownFlows.remove(id)
        if pendingShutdownFlows.isEmpty {
            destroyEngine()
        }
    }

    private func destroyEngine() {
        guard phase == .shuttingDown, let handle else { return }
        let status = backend.engineDestroy(handle)
        guard status == FlowCoreABIStatus.success else {
            // A failed native barrier is intentionally fail-closed: releasing
            // Swift ownership here could let callbacks target freed contexts.
            assertionFailure("FlowCore engine destroy barrier failed")
            return
        }
        self.handle = nil
        phase = .destroyed
        let completions = gate.withLock { () -> [@Sendable () -> Void] in
            shutdownFinished = true
            shutdownSelfRetain = nil
            defer { shutdownCompletions.removeAll(keepingCapacity: false) }
            return shutdownCompletions
        }
        completions.forEach { $0() }
    }

    private func validatedEndpoint(
        _ endpoint: FlowEndpoint,
        transport: FlowTransport,
        requiresIPAddress: Bool
    ) throws -> FlowEndpoint {
        let validated: FlowEndpoint
        do {
            validated = try endpoint.validated()
        } catch {
            throw FlowCoreEngineError.invalidEndpoint
        }
        guard validated.transport == transport else {
            throw FlowCoreEngineError.invalidEndpoint
        }
        if requiresIPAddress {
            switch validated.host {
            case .ipv4, .ipv6:
                break
            case .name:
                throw FlowCoreEngineError.invalidEndpoint
            }
        }
        return validated
    }

    private static func flowCreationError(_ status: Int32) -> FlowCoreEngineError {
        switch status {
        case FlowCoreABIStatus.invalidArgument:
            .invalidEndpoint
        case FlowCoreABIStatus.backpressure:
            .resourceExhausted
        case FlowCoreABIStatus.closed, FlowCoreABIStatus.cancelled:
            .engineClosed
        default:
            .internalFailure
        }
    }

    private static func selectorNameData(_ value: String) throws -> Data {
        guard
            let data = value.data(using: .utf8),
            (1...1_024).contains(data.count),
            !data.contains(0)
        else {
            throw FlowCoreEngineError.selectorUnavailable
        }
        return data
    }

    private static func latencyURLData(_ value: String) throws -> Data {
        guard
            let data = value.data(using: .utf8),
            (1...ProxySelectionProviderMessageCodec.maximumURLBytes)
                .contains(data.count),
            !data.contains(0),
            value.hasPrefix("https://") || value.hasPrefix("http://")
        else { throw FlowCoreEngineError.selectorUnavailable }
        return data
    }

    private static func selectorError(
        _ status: Int32,
        selecting: Bool
    ) -> FlowCoreEngineError {
        switch status {
        case FlowCoreABIStatus.invalidArgument:
            selecting ? .selectionRejected : .selectorUnavailable
        case FlowCoreABIStatus.tooLarge, FlowCoreABIStatus.backpressure:
            .resourceExhausted
        case FlowCoreABIStatus.closed, FlowCoreABIStatus.cancelled:
            .engineClosed
        default:
            .internalFailure
        }
    }

    private static func routingModeError(_ status: Int32) -> FlowCoreEngineError {
        switch status {
        case FlowCoreABIStatus.closed, FlowCoreABIStatus.cancelled,
             FlowCoreABIStatus.invalidState:
            .engineClosed
        case FlowCoreABIStatus.invalidArgument:
            .invalidConfiguration
        default:
            .internalFailure
        }
    }

    private enum ShutdownAdmission: Equatable {
        case none
        case complete
    }
}

private enum ProxySelectionSnapshotCodec {
    private static let magic: [UInt8] = [0x41, 0x52, 0x53, 0x31]
    private static let noSelection = UInt32.max

    static func decode(_ data: Data) throws -> ProxySelectionSnapshot {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, Array(bytes[0..<4]) == magic else {
            throw FlowCoreEngineError.invalidSelectorSnapshot
        }
        let selectedIndex = readUInt32(bytes, at: 4)
        let memberCount = readUInt32(bytes, at: 8)
        guard
            let selectedIndex,
            let memberCount,
            memberCount <= 4_096
        else {
            throw FlowCoreEngineError.invalidSelectorSnapshot
        }
        var offset = 12
        var members: [String] = []
        members.reserveCapacity(Int(memberCount))
        for _ in 0..<memberCount {
            guard
                let length = readUInt32(bytes, at: offset),
                (1...1_024).contains(length)
            else {
                throw FlowCoreEngineError.invalidSelectorSnapshot
            }
            offset += 4
            let end = offset + Int(length)
            guard end <= bytes.count else {
                throw FlowCoreEngineError.invalidSelectorSnapshot
            }
            let valueBytes = bytes[offset..<end]
            guard
                !valueBytes.contains(0),
                let value = String(bytes: valueBytes, encoding: .utf8)
            else {
                throw FlowCoreEngineError.invalidSelectorSnapshot
            }
            members.append(value)
            offset = end
        }
        guard offset == bytes.count else {
            throw FlowCoreEngineError.invalidSelectorSnapshot
        }
        let selectedMember: String?
        if selectedIndex == noSelection {
            selectedMember = nil
        } else {
            guard Int(selectedIndex) < members.count else {
                throw FlowCoreEngineError.invalidSelectorSnapshot
            }
            selectedMember = members[Int(selectedIndex)]
        }
        return ProxySelectionSnapshot(
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

private enum ProxyLatencyResultCodec {
    private static let magic: [UInt8] = [0x41, 0x52, 0x4c, 0x31]

    static func decode(_ data: Data) throws -> ProxyLatencyState {
        let bytes = [UInt8](data)
        guard
            bytes.count >= 8,
            Array(bytes[0..<4]) == magic,
            let count = readUInt32(bytes, at: 4),
            count <= ProxySelectionProviderMessageCodec.maximumMemberCount
        else { throw FlowCoreEngineError.invalidLatencyResult }
        var offset = 8
        var results: [ProxyLatencyResult] = []
        results.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard
                let length = readUInt32(bytes, at: offset),
                (1...ProxySelectionProviderMessageCodec.maximumNameBytes)
                    .contains(Int(length))
            else { throw FlowCoreEngineError.invalidLatencyResult }
            offset += 4
            let (end, overflow) = offset.addingReportingOverflow(Int(length))
            guard !overflow, end + 4 <= bytes.count else {
                throw FlowCoreEngineError.invalidLatencyResult
            }
            let memberBytes = bytes[offset..<end]
            guard
                !memberBytes.contains(0),
                let member = String(bytes: memberBytes, encoding: .utf8),
                let delay = readUInt32(bytes, at: end)
            else { throw FlowCoreEngineError.invalidLatencyResult }
            results.append(
                ProxyLatencyResult(
                    member: member,
                    delayMilliseconds: delay == UInt32.max ? nil : delay
                )
            )
            offset = end + 4
        }
        guard offset == bytes.count else {
            throw FlowCoreEngineError.invalidLatencyResult
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

private final class FlowCoreTCPBridge: RustTCPFlowBridge, @unchecked Sendable {
    private let storage: FlowCoreFlowStorage

    init(storage: FlowCoreFlowStorage) {
        self.storage = storage
    }

    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        storage.activate(completion: completion)
    }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        storage.tcpRead(
            maximumBytes: maximumBytes,
            token: token,
            completion: completion
        )
    }

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        storage.tcpWrite(data, token: token, completion: completion)
    }

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        storage.tcpFinishWrite(token: token, completion: completion)
    }

    func cancel() {
        storage.cancel()
    }

    func destroy(completion: @escaping @Sendable () -> Void) {
        storage.destroy(completion: completion)
    }
}

private final class FlowCoreUDPBridge: RustUDPFlowBridge, @unchecked Sendable {
    private let storage: FlowCoreFlowStorage

    init(storage: FlowCoreFlowStorage) {
        self.storage = storage
    }

    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        storage.activate(completion: completion)
    }

    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {
        storage.udpRead(
            maximumDatagrams: maximumDatagrams,
            maximumBytes: maximumBytes,
            token: token,
            completion: completion
        )
    }

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {
        storage.udpWrite(datagrams, token: token, completion: completion)
    }

    func cancel() {
        storage.cancel()
    }

    func destroy(completion: @escaping @Sendable () -> Void) {
        storage.destroy(completion: completion)
    }
}

private final class FlowCoreFlowStorage: @unchecked Sendable {
    enum Kind {
        case tcp
        case udp
    }

    private enum Phase {
        case staged
        case active
        case cancelled
        case destroying
        case destroyed
    }

    let id = UUID()

    private let kind: Kind
    private let backend: any FlowCoreABIBackend
    private let queue: DispatchQueue
    private let gate = NSLock()
    private weak var owner: FlowCoreEngineStorage?
    private var acceptsCalls = true
    private var destroyRequested = false
    private var destroyFinished = false
    private var destroyCompletions: [@Sendable () -> Void] = []
    private var handle: FlowCoreABIHandle?
    private var phase: Phase = .staged
    private var nextABIToken: UInt64 = 0
    private var operations: [UInt64: FlowOperationToken] = [:]

    init(
        kind: Kind,
        backend: any FlowCoreABIBackend,
        handle: FlowCoreABIHandle,
        owner: FlowCoreEngineStorage
    ) {
        self.kind = kind
        self.backend = backend
        self.handle = handle
        self.owner = owner
        queue = DispatchQueue(
            label: "com.example.aetherroute.flow-core.flow.\(id.uuidString)",
            qos: .userInitiated
        )
    }

    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        enqueueCall(
            rejected: { completion(.failure(.closed)) }
        ) { [self] in
            guard phase == .staged, let handle else {
                completion(.failure(.closed))
                return
            }
            let status = backend.activate(handle)
            FlowCoreRuntimeLog.logger.debug(
                "stage=activateFlow transport=\(self.kindLabel, privacy: .public) status=\(status, privacy: .public)"
            )
            if status == FlowCoreABIStatus.success {
                phase = .active
                completion(.success(()))
            } else {
                if status == FlowCoreABIStatus.cancelled
                    || status == FlowCoreABIStatus.closed
                {
                    phase = .cancelled
                }
                completion(.failure(Self.flowError(for: status)))
            }
        }
    }

    func tcpWrite(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        enqueueCall(rejected: { completion(token, .failure(.closed)) }) {
            [self] in
            guard kind == .tcp else {
                completion(token, .failure(.invalidData("TCP/UDP flow mismatch")))
                return
            }
            guard !data.isEmpty else {
                completion(token, .failure(.invalidData("Empty TCP write")))
                return
            }
            FlowCoreRuntimeLog.logger.debug(
                "stage=tcpWrite submit bytes=\(data.count, privacy: .public)"
            )
            issueWriteOperation(token: token, completion: completion) {
                handle, abiToken, callback in
                backend.tcpWrite(
                    handle,
                    data: data,
                    token: abiToken,
                    completion: callback
                )
            }
        }
    }

    func tcpFinishWrite(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {
        enqueueCall(rejected: { completion(token, .failure(.closed)) }) {
            [self] in
            guard kind == .tcp else {
                completion(token, .failure(.invalidData("TCP/UDP flow mismatch")))
                return
            }
            FlowCoreRuntimeLog.logger.debug("stage=tcpFinishWrite submit")
            issueWriteOperation(token: token, completion: completion) {
                handle, abiToken, callback in
                backend.tcpFinishWrite(
                    handle,
                    token: abiToken,
                    completion: callback
                )
            }
        }
    }

    func tcpRead(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        enqueueCall(rejected: { completion(token, .failure(.closed)) }) {
            [self] in
            guard kind == .tcp else {
                completion(token, .failure(.invalidData("TCP/UDP flow mismatch")))
                return
            }
            guard
                (1...TCPFlowStateMachine.hardMaximumReadBytes)
                    .contains(maximumBytes)
            else {
                completion(token, .failure(.invalidData("Invalid TCP read limit")))
                return
            }
            guard phase == .active, let handle else {
                completion(token, .failure(.closed))
                return
            }
            FlowCoreRuntimeLog.logger.debug(
                "stage=tcpRead submit maximumBytes=\(maximumBytes, privacy: .public)"
            )
            let abiToken = beginOperation(token)
            let status = backend.tcpRead(
                handle,
                maximumBytes: maximumBytes,
                token: abiToken
            ) { [weak self] response in
                guard let self else { return }
                queue.async { [self] in
                    completeTCPRead(
                        abiToken: abiToken,
                        expected: token,
                        response: response,
                        completion: completion
                    )
                }
            }
            if status != FlowCoreABIStatus.success {
                if FlowCoreABIStatus.isExpectedTermination(status) {
                    FlowCoreRuntimeLog.logger.debug(
                        "stage=tcpRead terminated status=\(status, privacy: .public)"
                    )
                } else {
                    FlowCoreRuntimeLog.logger.error(
                        "stage=tcpRead submitFailed status=\(status, privacy: .public)"
                    )
                }
                operations.removeValue(forKey: abiToken)
                completion(token, .failure(Self.flowError(for: status)))
            }
        }
    }

    func udpWrite(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {
        enqueueCall(rejected: { completion(token, .failure(.closed)) }) {
            [self] in
            guard kind == .udp else {
                completion(token, .failure(.invalidData("TCP/UDP flow mismatch")))
                return
            }
            do {
                try UDPBatchValidator.validate(datagrams)
                FlowCoreRuntimeLog.logger.debug(
                    "stage=udpWrite submit datagrams=\(datagrams.count, privacy: .public) bytes=\(datagrams.reduce(0) { $0 + $1.payload.count }, privacy: .public)"
                )
            } catch {
                completion(token, .failure(.invalidData("Invalid UDP batch")))
                return
            }
            let encoded: [FlowCoreABIUDPDatagram]
            do {
                encoded = try datagrams.map {
                    FlowCoreABIUDPDatagram(
                        payload: $0.payload,
                        remoteEndpoint: try FlowEndpointCodec.encode(
                            $0.remoteEndpoint
                        )
                    )
                }
            } catch {
                completion(token, .failure(.invalidData("Invalid UDP endpoint")))
                return
            }
            issueWriteOperation(token: token, completion: completion) {
                handle, abiToken, callback in
                backend.udpWrite(
                    handle,
                    datagrams: encoded,
                    token: abiToken,
                    completion: callback
                )
            }
        }
    }

    func udpRead(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {
        enqueueCall(rejected: { completion(token, .failure(.closed)) }) {
            [self] in
            guard kind == .udp else {
                completion(token, .failure(.invalidData("TCP/UDP flow mismatch")))
                return
            }
            let policy = UDPBatchPolicy(
                maximumDatagrams: maximumDatagrams,
                maximumBatchBytes: maximumBytes
            )
            do {
                try policy.validated()
            } catch {
                completion(token, .failure(.invalidData("Invalid UDP read limits")))
                return
            }
            guard phase == .active, let handle else {
                completion(token, .failure(.closed))
                return
            }
            let abiToken = beginOperation(token)
            let status = backend.udpRead(
                handle,
                maximumDatagrams: maximumDatagrams,
                maximumBytes: maximumBytes,
                token: abiToken
            ) { [weak self] response in
                guard let self else { return }
                queue.async { [self] in
                    completeUDPRead(
                        abiToken: abiToken,
                        expected: token,
                        response: response,
                        policy: policy,
                        completion: completion
                    )
                }
            }
            if status != FlowCoreABIStatus.success {
                if FlowCoreABIStatus.isExpectedTermination(status) {
                    FlowCoreRuntimeLog.logger.debug(
                        "stage=udpRead terminated status=\(status, privacy: .public)"
                    )
                } else {
                    FlowCoreRuntimeLog.logger.error(
                        "stage=udpRead submitFailed status=\(status, privacy: .public)"
                    )
                }
                operations.removeValue(forKey: abiToken)
                completion(token, .failure(Self.flowError(for: status)))
            }
        }
    }

    func cancel() {
        gate.withLock {
            guard !destroyRequested else { return }
            queue.async { [self] in cancelSerialized() }
        }
    }

    func destroy(completion: @escaping @Sendable () -> Void) {
        let action = gate.withLock { () -> DestroyAdmission in
            if destroyFinished { return .complete }
            destroyCompletions.append(completion)
            guard !destroyRequested else { return .none }
            destroyRequested = true
            acceptsCalls = false
            queue.async { [self] in beginDestroy() }
            return .none
        }
        if action == .complete {
            queue.async(execute: completion)
        }
    }

    private func enqueueCall(
        rejected: @escaping @Sendable () -> Void,
        operation: @escaping @Sendable () -> Void
    ) {
        let accepted = gate.withLock { () -> Bool in
            guard acceptsCalls else { return false }
            // Enqueue while holding the gate. This establishes total ordering
            // between the last admitted call and the first destroy barrier.
            queue.async(execute: operation)
            return true
        }
        if !accepted {
            queue.async(execute: rejected)
        }
    }

    private func issueWriteOperation(
        token: FlowOperationToken,
        completion: @escaping @Sendable (
            FlowOperationToken,
            Result<Void, FlowIOError>
        ) -> Void,
        invoke: (
            FlowCoreABIHandle,
            UInt64,
            @escaping @Sendable (UInt64, Int32) -> Void
        ) -> Int32
    ) {
        guard phase == .active, let handle else {
            completion(token, .failure(.closed))
            return
        }
        let abiToken = beginOperation(token)
        let status = invoke(handle, abiToken) { [weak self] returned, status in
            guard let self else { return }
            queue.async { [self] in
                completeWrite(
                    abiToken: abiToken,
                    expected: token,
                    returned: returned,
                    status: status,
                    completion: completion
                )
            }
        }
        if status != FlowCoreABIStatus.success {
            if FlowCoreABIStatus.isExpectedTermination(status) {
                FlowCoreRuntimeLog.logger.debug(
                    "stage=flowWrite terminated transport=\(self.kindLabel, privacy: .public) status=\(status, privacy: .public)"
                )
            } else {
                FlowCoreRuntimeLog.logger.error(
                    "stage=flowWrite submitFailed transport=\(self.kindLabel, privacy: .public) status=\(status, privacy: .public)"
                )
            }
            operations.removeValue(forKey: abiToken)
            completion(token, .failure(Self.flowError(for: status)))
        }
    }

    private func beginOperation(_ token: FlowOperationToken) -> UInt64 {
        repeat { nextABIToken &+= 1 } while nextABIToken == 0
            || operations[nextABIToken] != nil
        operations[nextABIToken] = token
        return nextABIToken
    }

    private func completeWrite(
        abiToken: UInt64,
        expected: FlowOperationToken,
        returned: UInt64,
        status: Int32,
        completion: @escaping @Sendable (
            FlowOperationToken,
            Result<Void, FlowIOError>
        ) -> Void
    ) {
        guard let mapped = operations.removeValue(forKey: abiToken) else {
            return
        }
        guard mapped == expected, returned == abiToken else {
            FlowCoreRuntimeLog.logger.error(
                "stage=flowWrite callbackMalformed transport=\(self.kindLabel, privacy: .public)"
            )
            completion(expected, .failure(.invalidData("FFI token mismatch")))
            return
        }
        if status == FlowCoreABIStatus.success {
            FlowCoreRuntimeLog.logger.debug(
                "stage=flowWrite callbackSuccess transport=\(self.kindLabel, privacy: .public) operation=\(expected.kind.rawValue, privacy: .public)"
            )
            completion(mapped, .success(()))
        } else {
            if FlowCoreABIStatus.isExpectedTermination(status) {
                FlowCoreRuntimeLog.logger.debug(
                    "stage=flowWrite terminated transport=\(self.kindLabel, privacy: .public) operation=\(expected.kind.rawValue, privacy: .public) status=\(status, privacy: .public)"
                )
            } else {
                FlowCoreRuntimeLog.logger.error(
                    "stage=flowWrite callbackFailed transport=\(self.kindLabel, privacy: .public) operation=\(expected.kind.rawValue, privacy: .public) status=\(status, privacy: .public)"
                )
            }
            completion(mapped, .failure(Self.flowError(for: status)))
        }
    }

    private func completeTCPRead(
        abiToken: UInt64,
        expected: FlowOperationToken,
        response: FlowCoreABITCPReadResponse,
        completion: @escaping TCPReadCompletion
    ) {
        guard let mapped = operations.removeValue(forKey: abiToken) else {
            return
        }
        guard
            mapped == expected,
            response.token == abiToken,
            !response.malformed
        else {
            FlowCoreRuntimeLog.logger.error("stage=tcpRead callbackMalformed")
            completion(expected, .failure(.invalidData("Malformed TCP callback")))
            return
        }
        guard response.status == FlowCoreABIStatus.success else {
            if FlowCoreABIStatus.isExpectedTermination(response.status) {
                FlowCoreRuntimeLog.logger.debug(
                    "stage=tcpRead terminated status=\(response.status, privacy: .public)"
                )
            } else {
                FlowCoreRuntimeLog.logger.error(
                    "stage=tcpRead callbackFailed status=\(response.status, privacy: .public)"
                )
            }
            completion(mapped, .failure(Self.flowError(for: response.status)))
            return
        }
        if response.endOfStream {
            FlowCoreRuntimeLog.logger.debug("stage=tcpRead endOfStream")
            completion(mapped, .success(.endOfStream))
        } else if let data = response.data, !data.isEmpty {
            FlowCoreRuntimeLog.logger.debug(
                "stage=tcpRead success bytes=\(data.count, privacy: .public)"
            )
            completion(mapped, .success(.bytes(data)))
        } else {
            completion(mapped, .failure(.invalidData("Empty TCP callback")))
        }
    }

    private func completeUDPRead(
        abiToken: UInt64,
        expected: FlowOperationToken,
        response: FlowCoreABIUDPReadResponse,
        policy: UDPBatchPolicy,
        completion: @escaping UDPReadCompletion
    ) {
        guard let mapped = operations.removeValue(forKey: abiToken) else {
            return
        }
        guard
            mapped == expected,
            response.token == abiToken,
            !response.malformed
        else {
            FlowCoreRuntimeLog.logger.error("stage=udpRead callbackMalformed")
            completion(expected, .failure(.invalidData("Malformed UDP callback")))
            return
        }
        guard response.status == FlowCoreABIStatus.success else {
            if FlowCoreABIStatus.isExpectedTermination(response.status) {
                FlowCoreRuntimeLog.logger.debug(
                    "stage=udpRead terminated status=\(response.status, privacy: .public)"
                )
            } else {
                FlowCoreRuntimeLog.logger.error(
                    "stage=udpRead callbackFailed status=\(response.status, privacy: .public)"
                )
            }
            completion(mapped, .failure(Self.flowError(for: response.status)))
            return
        }
        if response.endOfStream {
            FlowCoreRuntimeLog.logger.debug("stage=udpRead endOfStream")
            completion(mapped, .success(.endOfStream))
            return
        }
        let datagrams: [UDPDatagram]
        do {
            datagrams = try response.datagrams.map {
                UDPDatagram(
                    payload: $0.payload,
                    remoteEndpoint: try FlowEndpointCodec.decode(
                        $0.remoteEndpoint
                    )
                )
            }
            try UDPBatchValidator.validate(datagrams, policy: policy)
            FlowCoreRuntimeLog.logger.debug(
                "stage=udpRead success datagrams=\(datagrams.count, privacy: .public) bytes=\(datagrams.reduce(0) { $0 + $1.payload.count }, privacy: .public)"
            )
        } catch {
            FlowCoreRuntimeLog.logger.error("stage=udpRead batchDecodeFailed")
            completion(mapped, .failure(.invalidData("Malformed UDP batch")))
            return
        }
        completion(mapped, .success(.datagrams(datagrams)))
    }

    private func cancelSerialized() {
        guard phase == .staged || phase == .active, let handle else { return }
        let status = backend.cancel(handle)
        FlowCoreRuntimeLog.logger.debug(
            "stage=cancelFlow transport=\(self.kindLabel, privacy: .public) status=\(status, privacy: .public)"
        )
        phase = .cancelled
    }

    private func beginDestroy() {
        guard phase != .destroyed, phase != .destroying, let handle else {
            finishDestroy()
            return
        }
        if phase != .cancelled {
            _ = backend.cancel(handle)
        }
        phase = .destroying
        let status = backend.destroy(handle)
        FlowCoreRuntimeLog.logger.debug(
            "stage=destroyFlow transport=\(self.kindLabel, privacy: .public) status=\(status, privacy: .public)"
        )
        guard status == FlowCoreABIStatus.success else {
            assertionFailure("FlowCore flow destroy barrier failed")
            return
        }
        self.handle = nil

        // Every native callback has returned before C destroy returns. Each
        // callback enqueues its copied Swift result onto this same queue. A
        // tail task therefore drains those results before exposing completion.
        queue.async { [self] in finishDestroy() }
    }

    private func finishDestroy() {
        phase = .destroyed
        assert(operations.isEmpty, "C destroy returned before callbacks drained")
        operations.removeAll(keepingCapacity: false)
        owner?.flowDidDestroy(id)
        let completions = gate.withLock { () -> [@Sendable () -> Void] in
            destroyFinished = true
            defer { destroyCompletions.removeAll(keepingCapacity: false) }
            return destroyCompletions
        }
        completions.forEach { $0() }
    }

    private static func flowError(for status: Int32) -> FlowIOError {
        switch status {
        case FlowCoreABIStatus.cancelled:
            .cancelled
        case FlowCoreABIStatus.closed:
            .closed
        case FlowCoreABIStatus.invalidArgument, FlowCoreABIStatus.tooLarge:
            .invalidData("Flow ABI rejected bounded data")
        case FlowCoreABIStatus.backpressure:
            .transport("Flow ABI backpressure")
        case FlowCoreABIStatus.invalidState:
            .transport("Flow ABI state mismatch")
        default:
            .transport("Flow ABI operation failed")
        }
    }

    private var kindLabel: String {
        switch kind {
        case .tcp: "tcp"
        case .udp: "udp"
        }
    }

    private enum DestroyAdmission: Equatable {
        case none
        case complete
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try operation()
    }
}

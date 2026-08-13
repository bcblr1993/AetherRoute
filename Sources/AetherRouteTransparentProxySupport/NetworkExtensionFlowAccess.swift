import AetherRouteKit
import Foundation
import Network
@preconcurrency import NetworkExtension
import OSLog

private enum NativeFlowRuntimeLog {
    static let log = DiagnosticLogCenter.current.log(
        category: "transparent-native-flow"
    )
}

/// Stable, privacy-preserving translation of NetworkExtension failures. Error
/// descriptions can contain endpoint or profile details, so only the numeric
/// framework code crosses into the data-plane state machine.
public enum NetworkExtensionFlowErrorMapper {
    public static func map(_ error: any Error) -> FlowIOError {
        let value = error as NSError
        guard
            value.domain == NEAppProxyErrorDomain,
            let code = NEAppProxyFlowError.Code(rawValue: value.code)
        else {
            return .transport("NetworkExtension operation failed")
        }

        switch code {
        case .aborted:
            return .cancelled
        case .notConnected, .peerReset, .hostUnreachable, .refused, .timedOut:
            return .closed
        default:
            return .transport("NetworkExtension error \(value.code)")
        }
    }

    public static var refused: any Error {
        NEAppProxyFlowError(.refused)
    }

    public static var aborted: any Error {
        NEAppProxyFlowError(.aborted)
    }
}

/// Every call that touches one `NEAppProxyFlow` is issued by the same serial
/// executor. This is the runtime basis for the `@unchecked Sendable` wrappers:
/// Swift callers may arrive concurrently, while the Apple object never does.
final class NetworkExtensionFlowExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    init(label: String = "com.example.aetherroute.flow") {
        queue = DispatchQueue(label: label)
    }

    func execute(_ operation: @escaping @Sendable () -> Void) {
        queue.async(execute: operation)
    }
}

/// Concrete Apple-side access for the bounded TCP adapter. It performs no
/// routing itself and never opens the flow; the provider keeps the required
/// create -> retain -> open -> activate ordering.
final class NetworkExtensionTCPFlowAccess:
    AppleTCPFlowAccess,
    @unchecked Sendable
{
    private let flow: NEAppProxyTCPFlow
    private let executor: NetworkExtensionFlowExecutor
    private let drainGate = NativeFlowDrainGate()

    init(
        flow: NEAppProxyTCPFlow,
        executor: NetworkExtensionFlowExecutor
    ) {
        self.flow = flow
        self.executor = executor
    }

    public func readData(
        completion: @escaping @Sendable (
            Result<Data?, FlowIOError>
        ) -> Void
    ) {
        executor.execute { [self] in
            guard drainGate.beginOperation() else {
                completion(.failure(.cancelled))
                return
            }
            let once = NativeOperationOnce()
            flow.readData { data, error in
                once.run { [self] in
                    if let error {
                        NativeFlowRuntimeLog.log.failure(
                            "stage=tcpNativeRead failed code=\((error as NSError).code)"
                        )
                        completion(
                            .failure(NetworkExtensionFlowErrorMapper.map(error))
                        )
                    } else {
                        NativeFlowRuntimeLog.log.verbose(
                            "stage=tcpNativeRead success bytes=\(data?.count ?? 0) eof=\((data == nil || data?.isEmpty == true))"
                        )
                        completion(.success(data))
                    }
                    completeOperation()
                }
            }
        }
    }

    public func writeData(
        _ data: Data,
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    ) {
        executor.execute { [self] in
            guard drainGate.beginOperation() else {
                completion(.failure(.cancelled))
                return
            }
            NativeFlowRuntimeLog.log.verbose(
                "stage=tcpNativeWrite submit bytes=\(data.count)"
            )
            let once = NativeOperationOnce()
            flow.write(data) { error in
                once.run { [self] in
                    if let error {
                        NativeFlowRuntimeLog.log.failure(
                            "stage=tcpNativeWrite failed code=\((error as NSError).code)"
                        )
                        completion(
                            .failure(NetworkExtensionFlowErrorMapper.map(error))
                        )
                    } else {
                        NativeFlowRuntimeLog.log.verbose(
                            "stage=tcpNativeWrite success bytes=\(data.count)"
                        )
                        completion(.success(()))
                    }
                    completeOperation()
                }
            }
        }
    }

    public func finishWriting() {
        executor.execute { [self] in
            guard drainGate.beginOperation() else { return }
            NativeFlowRuntimeLog.log.verbose("stage=tcpNativeFinishWrite")
            flow.closeWriteWithError(nil)
            completeOperation()
        }
    }

    public func cancel() {
        cancelAndDrain {}
    }

    public func cancelAndDrain(
        completion: @escaping @Sendable () -> Void
    ) {
        NativeFlowRuntimeLog.log.verbose("stage=tcpNativeDrain requested")
        let request = drainGate.requestCancel(completion: completion)
        request.completions.forEach { $0() }
        guard request.shouldIssueClose else { return }
        executor.execute { [self] in
            NativeFlowRuntimeLog.log.verbose("stage=tcpNativeDrain close begin")
            let error = NetworkExtensionFlowErrorMapper.aborted
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
            NativeFlowRuntimeLog.log.verbose("stage=tcpNativeDrain close success")
            drainGate.closeExecuted().forEach { $0() }
        }
    }

    private func completeOperation() {
        drainGate.operationReturned().forEach { $0() }
    }
}

/// Concrete Apple-side access for UDP using the macOS 15 typed Network
/// endpoint API. AetherRoute's native product baseline is macOS 15 so no
/// deprecated Objective-C endpoint representation enters the data plane.
final class NetworkExtensionUDPFlowAccess:
    AppleUDPFlowAccess,
    @unchecked Sendable
{
    private let flow: NEAppProxyUDPFlow
    private let executor: NetworkExtensionFlowExecutor
    private let readBatchGuard: NativeUDPReadBatchGuard
    private let drainGate = NativeFlowDrainGate()

    init(
        flow: NEAppProxyUDPFlow,
        executor: NetworkExtensionFlowExecutor,
        readBatchGuard: NativeUDPReadBatchGuard
    ) {
        self.flow = flow
        self.executor = executor
        self.readBatchGuard = readBatchGuard
    }

    public func readDatagrams(
        completion: @escaping @Sendable (
            Result<[UDPDatagram]?, FlowIOError>
        ) -> Void
    ) {
        executor.execute { [self] in
            guard drainGate.beginOperation() else {
                completion(.failure(.cancelled))
                return
            }
            let once = NativeOperationOnce()
            flow.readDatagrams { values, error in
                once.run { [self] in
                    Self.completeRead(
                        values,
                        error: error,
                        readBatchGuard: readBatchGuard,
                        completion: completion
                    )
                    completeOperation()
                }
            }
        }
    }

    public func writeDatagrams(
        _ datagrams: [UDPDatagram],
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    ) {
        let values: [(Data, Network.NWEndpoint)]
        do {
            values = try datagrams.map {
                ($0.payload, try NetworkFlowEndpointCodec.encode($0.remoteEndpoint))
            }
            NativeFlowRuntimeLog.log.verbose(
                "stage=udpNativeWrite submit datagrams=\(values.count) bytes=\(values.reduce(0) { $0 + $1.0.count })"
            )
        } catch {
            NativeFlowRuntimeLog.log.failure(
                "stage=udpNativeWrite endpointEncodeFailed"
            )
            completion(.failure(.invalidData("Invalid UDP endpoint from core")))
            return
        }

        executor.execute { [self] in
            guard drainGate.beginOperation() else {
                completion(.failure(.cancelled))
                return
            }
            let once = NativeOperationOnce()
            flow.writeDatagrams(values) { error in
                once.run { [self] in
                    Self.completeWrite(error, completion: completion)
                    completeOperation()
                }
            }
        }
    }

    public func cancel() {
        cancelAndDrain {}
    }

    public func cancelAndDrain(
        completion: @escaping @Sendable () -> Void
    ) {
        NativeFlowRuntimeLog.log.verbose("stage=udpNativeDrain requested")
        let request = drainGate.requestCancel(completion: completion)
        request.completions.forEach { $0() }
        guard request.shouldIssueClose else { return }
        executor.execute { [self] in
            NativeFlowRuntimeLog.log.verbose("stage=udpNativeDrain close begin")
            let error = NetworkExtensionFlowErrorMapper.aborted
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
            NativeFlowRuntimeLog.log.verbose("stage=udpNativeDrain close success")
            drainGate.closeExecuted().forEach { $0() }
        }
    }

    private static func completeRead(
        _ values: [(Data, Network.NWEndpoint)]?,
        error: (any Error)?,
        readBatchGuard: NativeUDPReadBatchGuard,
        completion: @escaping @Sendable (
            Result<[UDPDatagram]?, FlowIOError>
        ) -> Void
    ) {
        if let error {
            NativeFlowRuntimeLog.log.failure(
                "stage=udpNativeRead failed code=\((error as NSError).code)"
            )
            completion(.failure(NetworkExtensionFlowErrorMapper.map(error)))
            return
        }
        guard let values else {
            NativeFlowRuntimeLog.log.verbose("stage=udpNativeRead endOfStream")
            completion(.success(nil))
            return
        }
        // Check the native array before constructing UDPDatagram values or
        // decoding any endpoint. NetworkExtension has already allocated the
        // raw Data objects, but an oversized callback must not trigger a
        // second full-batch representation in the extension process.
        guard readBatchGuard.accepts(values, payloadByteCount: { $0.0.count }) else {
            NativeFlowRuntimeLog.log.failure(
                "stage=udpNativeRead stagingLimitExceeded datagrams=\(values.count)"
            )
            completion(
                .failure(.invalidData("Apple UDP staging limit exceeded"))
            )
            return
        }
        do {
            NativeFlowRuntimeLog.log.verbose(
                "stage=udpNativeRead success datagrams=\(values.count) bytes=\(values.reduce(0) { $0 + $1.0.count })"
            )
            completion(
                .success(
                    try values.map { payload, endpoint in
                        UDPDatagram(
                            payload: payload,
                            remoteEndpoint: try NetworkFlowEndpointCodec.decode(
                                endpoint,
                                transport: .udp
                            )
                        )
                    }
                )
            )
        } catch {
            NativeFlowRuntimeLog.log.failure(
                "stage=udpNativeRead endpointDecodeFailed"
            )
            completion(
                .failure(.invalidData("Invalid UDP endpoint from NetworkExtension"))
            )
        }
    }

    private static func completeWrite(
        _ error: (any Error)?,
        completion: @escaping @Sendable (
            Result<Void, FlowIOError>
        ) -> Void
    ) {
        if let error {
            NativeFlowRuntimeLog.log.failure(
                "stage=udpNativeWrite failed code=\((error as NSError).code)"
            )
            completion(.failure(NetworkExtensionFlowErrorMapper.map(error)))
        } else {
            NativeFlowRuntimeLog.log.verbose("stage=udpNativeWrite success")
            completion(.success(()))
        }
    }

    private func completeOperation() {
        drainGate.operationReturned().forEach { $0() }
    }
}

/// Pure, allocation-free validation for one raw NetworkExtension UDP read.
/// The error surface intentionally contains no endpoint, packet index, or
/// payload size so a rejected callback cannot disclose flow metadata.
struct NativeUDPReadBatchGuard: Sendable {
    let maximumDatagrams: Int
    let maximumBytes: Int

    init(
        maximumDatagrams: Int,
        maximumBytes: Int
    ) throws {
        guard
            (1...BoundedAppleUDPFlowAdapter.defaultMaximumStagingDatagrams)
                .contains(maximumDatagrams),
            (1...BoundedAppleUDPFlowAdapter.defaultMaximumStagingBytes)
                .contains(maximumBytes)
        else {
            throw FlowStateMachineConfigurationError.invalidMaximumBatchBytes(
                maximumBytes
            )
        }
        self.maximumDatagrams = maximumDatagrams
        self.maximumBytes = maximumBytes
    }

    /// The collection count is checked before its elements are inspected.
    /// `payloadByteCount` is evaluated at most once per accepted-count item.
    func accepts<Payloads: Collection>(
        _ payloads: Payloads,
        payloadByteCount: (Payloads.Element) -> Int
    ) -> Bool {
        guard payloads.count <= maximumDatagrams else { return false }

        var aggregateBytes = 0
        for payload in payloads {
            let bytes = payloadByteCount(payload)
            guard
                (0...UDPBatchPolicy.maximumPayloadBytes).contains(bytes),
                bytes <= maximumBytes - aggregateBytes
            else { return false }
            aggregateBytes += bytes
        }
        return true
    }
}

struct NativeDrainRequest {
    let shouldIssueClose: Bool
    let completions: [@Sendable () -> Void]
}

/// Counts callbacks accepted by one concrete Apple flow access. NetworkExtension
/// does not guarantee that an outstanding read callback is delivered after the
/// provider closes a flow during stop. Close execution is therefore the native
/// cancellation barrier: late callbacks retain their own access object, are
/// ignored by the bounded adapter, and cannot replay drain completion.
final class NativeFlowDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private var accepting = true
    private var closeHasExecuted = false
    private var pendingOperationCount = 0
    private var drainCompletions: [@Sendable () -> Void] = []

    func beginOperation() -> Bool {
        lock.withLock {
            guard accepting else { return false }
            pendingOperationCount += 1
            return true
        }
    }

    func requestCancel(
        completion: @escaping @Sendable () -> Void
    ) -> NativeDrainRequest {
        lock.withLock {
            if !accepting, closeHasExecuted, pendingOperationCount == 0 {
                return NativeDrainRequest(
                    shouldIssueClose: false,
                    completions: [completion]
                )
            }
            drainCompletions.append(completion)
            guard accepting else {
                return NativeDrainRequest(
                    shouldIssueClose: false,
                    completions: []
                )
            }
            accepting = false
            return NativeDrainRequest(
                shouldIssueClose: true,
                completions: []
            )
        }
    }

    func closeExecuted() -> [@Sendable () -> Void] {
        lock.withLock {
            closeHasExecuted = true
            pendingOperationCount = 0
            return takeCompletionsIfDrainedLocked()
        }
    }

    func operationReturned() -> [@Sendable () -> Void] {
        lock.withLock {
            guard pendingOperationCount > 0 else { return [] }
            pendingOperationCount -= 1
            return takeCompletionsIfDrainedLocked()
        }
    }

    private func takeCompletionsIfDrainedLocked() -> [@Sendable () -> Void] {
        guard
            !accepting,
            closeHasExecuted,
            pendingOperationCount == 0
        else { return [] }
        defer { drainCompletions.removeAll(keepingCapacity: false) }
        return drainCompletions
    }
}

private final class NativeOperationOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func run(_ operation: () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        if shouldRun { operation() }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

public enum NetworkExtensionFlowLifecycle {
    public static func open(
        _ flow: NEAppProxyFlow,
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        // Captured before the call so the completion closure stays Sendable
        // without retaining the non-Sendable flow.
        let transport = flow is NEAppProxyTCPFlow ? "tcp" : "udp"
        let remote = (flow as? NEAppProxyTCPFlow)
            .map { String(describing: $0.remoteFlowEndpoint) } ?? "n/a"
        let startedAt = DispatchTime.now().uptimeNanoseconds
        flow.open(withLocalFlowEndpoint: nil) { error in
            completeOpen(
                error,
                transport: transport,
                remote: remote,
                startedAt: startedAt,
                completion: completion
            )
        }
    }

    public static func tcpDestination(
        for flow: NEAppProxyTCPFlow
    ) throws -> FlowEndpoint {
        let decoded = try NetworkFlowEndpointCodec.decode(
            flow.remoteFlowEndpoint,
            transport: .tcp
        )
        guard let hostname = flow.remoteHostname, !hostname.isEmpty else {
            return decoded
        }
        return try FlowEndpoint(
            host: .name(hostname),
            port: decoded.port,
            transport: .tcp
        ).validated()
    }

    public static func udpLocalSource(
        for flow: NEAppProxyUDPFlow
    ) throws -> FlowEndpoint? {
        try udpLocalSource(from: flow.localFlowEndpoint)
    }

    /// NetworkExtension legitimately reports an unspecified local port for
    /// virtual DNS and some system-owned UDP flows. That value is not a usable
    /// socket identity, so it must enter the existing synthetic-source lease
    /// path rather than being rejected as a malformed remote endpoint.
    static func udpLocalSource(
        from rawEndpoint: Network.NWEndpoint?
    ) throws -> FlowEndpoint? {
        guard let rawEndpoint else { return nil }
        guard !NetworkFlowEndpointCodec.hasUnspecifiedPort(rawEndpoint) else {
            return nil
        }
        let endpoint = try NetworkFlowEndpointCodec.decode(
            rawEndpoint,
            transport: .udp
        )
        return try normalizeUDPLocalSource(endpoint)
    }

    /// Wildcard addresses do not identify an actual socket namespace. Treat
    /// them as missing so the provider must acquire one unique synthetic lease
    /// instead of colliding with the pool's 0.0.0.0 identity space.
    public static func normalizeUDPLocalSource(
        _ endpoint: FlowEndpoint?
    ) throws -> FlowEndpoint? {
        guard let endpoint else { return nil }
        return try normalizeLocalIPAddress(endpoint, transport: .udp)
    }

    private static func normalizeLocalIPAddress(
        _ endpoint: FlowEndpoint,
        transport: FlowTransport
    ) throws -> FlowEndpoint? {
        let validated = try endpoint.validated()
        guard validated.transport == transport else {
            throw NetworkFlowEndpointCodecError.invalidAddress
        }
        switch validated.host {
        case let .ipv4(bytes):
            return bytes.allSatisfy { $0 == 0 } ? nil : validated
        case let .ipv6(bytes, _):
            return bytes.allSatisfy { $0 == 0 } ? nil : validated
        case .name:
            throw NetworkFlowEndpointCodecError.invalidAddress
        }
    }

    private static func completeOpen(
        _ error: (any Error)?,
        transport: String,
        remote: String,
        startedAt: UInt64,
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        let elapsedMicroseconds =
            (DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000
        if let error {
            let nsError = error as NSError
            DiagnosticFlowOpenObserver.shared.record(
                transport: transport, succeeded: false
            )
            NativeFlowRuntimeLog.log.failure(
                """
                stage=nativeOpen failed transport=\(transport) \
                domain=\(nsError.domain) \
                code=\(nsError.code) \
                remote=\(remote) \
                elapsedUs=\(elapsedMicroseconds)
                """
            )
            completion(.failure(NetworkExtensionFlowErrorMapper.map(error)))
        } else {
            // Notice level so the success path survives in the default log
            // store. `info` is not persisted by default, which previously made
            // field captures look as if no flow had ever opened.
            DiagnosticFlowOpenObserver.shared.record(
                transport: transport, succeeded: true
            )
            NativeFlowRuntimeLog.log.verbose(
                """
                stage=nativeOpen success transport=\(transport) \
                remote=\(remote) \
                elapsedUs=\(elapsedMicroseconds)
                """
            )
            completion(.success(()))
        }
    }
}

/// Retains the Apple flow while a session is staged and exposes only the open
/// operation to the lifecycle coordinator.
final class NetworkExtensionFlowOpening:
    AppleProxyFlowOpening,
    @unchecked Sendable
{
    private let flow: NEAppProxyFlow
    private let executor: NetworkExtensionFlowExecutor

    init(
        flow: NEAppProxyFlow,
        executor: NetworkExtensionFlowExecutor
    ) {
        self.flow = flow
        self.executor = executor
    }

    public func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        executor.execute { [self] in
            NetworkExtensionFlowLifecycle.open(flow, completion: completion)
        }
    }
}

/// Production construction path for one Apple TCP flow. The opening and all
/// subsequent flow calls are structurally tied to the same serial executor.
public struct NetworkExtensionTCPFlowComponents: Sendable {
    /// The only public product is a sealed same-flow bundle. Exposing the raw
    /// opening and IO components separately would let another target combine
    /// values created for different native flows.
    public let ingress: TransparentTCPIngressComponents

    public init(
        flow: NEAppProxyTCPFlow,
        stagingBudget: FlowStagingMemoryBudget = .shared
    ) throws {
        let identity = TransparentProxyAppleFlowIdentity()
        let executor = NetworkExtensionFlowExecutor(
            label: "com.example.aetherroute.apple-tcp-flow"
        )
        let opening = NetworkExtensionFlowOpening(
            flow: flow,
            executor: executor
        )
        let boundedFlow = try BoundedAppleTCPFlowAdapter(
            access: NetworkExtensionTCPFlowAccess(
                flow: flow,
                executor: executor
            ),
            stagingBudget: stagingBudget
        )
        ingress = TransparentTCPIngressComponents(
            opening: opening,
            flow: boundedFlow,
            openingIdentity: identity,
            flowIdentity: identity
        )
    }
}

/// Production construction path for one Apple UDP flow. The opening and all
/// subsequent flow calls are structurally tied to the same serial executor.
public struct NetworkExtensionUDPFlowComponents: Sendable {
    public let ingress: TransparentUDPIngressComponents

    public init(
        flow: NEAppProxyUDPFlow,
        maximumStagingDatagrams: Int =
            BoundedAppleUDPFlowAdapter.defaultMaximumStagingDatagrams,
        maximumStagingBytes: Int =
            BoundedAppleUDPFlowAdapter.defaultMaximumStagingBytes,
        stagingBudget: FlowStagingMemoryBudget = .shared
    ) throws {
        let identity = TransparentProxyAppleFlowIdentity()
        let executor = NetworkExtensionFlowExecutor(
            label: "com.example.aetherroute.apple-udp-flow"
        )
        let readBatchGuard = try NativeUDPReadBatchGuard(
            maximumDatagrams: maximumStagingDatagrams,
            maximumBytes: maximumStagingBytes
        )
        let opening = NetworkExtensionFlowOpening(
            flow: flow,
            executor: executor
        )
        let boundedFlow = try BoundedAppleUDPFlowAdapter(
            access: NetworkExtensionUDPFlowAccess(
                flow: flow,
                executor: executor,
                readBatchGuard: readBatchGuard
            ),
            maximumStagingDatagrams: maximumStagingDatagrams,
            maximumStagingBytes: maximumStagingBytes,
            stagingBudget: stagingBudget
        )
        ingress = TransparentUDPIngressComponents(
            opening: opening,
            flow: boundedFlow,
            openingIdentity: identity,
            flowIdentity: identity
        )
    }
}

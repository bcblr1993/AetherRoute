import Foundation
import OSLog

public enum TCPReadResult: Sendable, Equatable {
    case bytes(Data)
    case endOfStream
}

public typealias TCPReadCompletion = @Sendable (
    FlowOperationToken,
    Result<TCPReadResult, FlowIOError>
) -> Void

public typealias TCPWriteCompletion = @Sendable (
    FlowOperationToken,
    Result<Void, FlowIOError>
) -> Void

/// The narrow surface that a future NEAppProxyTCPFlow adapter must implement.
/// Implementations initiate operations and return immediately; they must never
/// block the state-machine actor.
public protocol TransparentTCPFlowIO: Sendable {
    /// `maximumBytes` is the bridge's validation limit. NetworkExtension does
    /// not expose a native maximum on `readData`; an adapter may therefore
    /// receive a larger OS result, which this state machine rejects before it
    /// reaches Rust.
    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    )

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    )

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    )

    /// Must be idempotent. Cancellation may race with an OS completion.
    func cancel()

    /// Completion is a callback barrier for the native Apple flow: all close
    /// calls have run and every accepted raw read/write callback has returned.
    func cancelAndDrain(completion: @escaping @Sendable () -> Void)
}

public extension TransparentTCPFlowIO {
    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        cancel()
        completion()
    }
}

/// Rust-to-Swift byte source abstraction. No concrete FFI is linked in phase 1.
public protocol RustTCPSource: AnyObject, Sendable {
    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    )

    func cancel()
}

/// Swift-to-Rust byte sink abstraction. No concrete FFI is linked in phase 1.
public protocol RustTCPSink: AnyObject, Sendable {
    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    )

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    )

    func cancel()
}

public struct TCPFlowSnapshot: Sendable, Equatable {
    public let lifecycle: FlowLifecycle
    public let flowInputEnded: Bool
    public let bridgeInputEnded: Bool
    public let flowOutputFinished: Bool
    public let bridgeOutputFinished: Bool
    public let inFlight: Set<FlowOperationKind>
}

/// Full-duplex TCP pump with independent backpressure in both directions.
///
/// At most one read and one write are outstanding on the transparent flow.
/// A source is not read again until its corresponding sink write completes.
/// EOF half-closes only the opposite sink, allowing the reverse direction to
/// continue until its own EOF.
public actor TCPFlowStateMachine {
    public static let defaultMaximumReadBytes = 64 * 1_024
    public static let hardMaximumReadBytes = 1_024 * 1_024

    private let flow: any TransparentTCPFlowIO
    private let bridgeSource: any RustTCPSource
    private let bridgeSink: any RustTCPSink
    private let bridgeSourceAndSinkShareIdentity: Bool
    private let halfCloseIdleTimeout: Duration
    private let maximumReadBytes: Int
    private let onTermination: FlowTerminationHandler
    private let sessionID: UUID
    private let diagnosticLog: DiagnosticLog

    private var lifecycle: FlowLifecycle = .idle
    private var lastTransferAt = ContinuousClock.now
    private var startedAt = ProcessInfo.processInfo.systemUptime
    private var terminationTrigger = "cancel"
    private var firstEOF = "none"
    private var flowReadBytes: UInt64 = 0
    private var bridgeReadBytes: UInt64 = 0
    private var bridgeWrittenBytes: UInt64 = 0
    private var flowWrittenBytes: UInt64 = 0
    private var pendingBridgeWriteBytes = 0
    private var pendingFlowWriteBytes = 0
    private var sequence: UInt64 = 0
    private var flowReadToken: FlowOperationToken?
    private var flowWriteToken: FlowOperationToken?
    private var flowFinishToken: FlowOperationToken?
    private var bridgeReadToken: FlowOperationToken?
    private var bridgeWriteToken: FlowOperationToken?
    private var bridgeFinishToken: FlowOperationToken?
    private var flowInputEnded = false
    private var bridgeInputEnded = false
    private var flowOutputFinished = false
    private var bridgeOutputFinished = false
    private var didReportTermination = false
    private var halfCloseTimeoutTask: Task<Void, Never>?

    public init(
        flow: any TransparentTCPFlowIO,
        bridgeSource: any RustTCPSource,
        bridgeSink: any RustTCPSink,
        maximumReadBytes: Int = TCPFlowStateMachine.defaultMaximumReadBytes,
        halfCloseIdleTimeout: Duration = .seconds(15),
        sessionID: UUID = UUID(),
        diagnosticLog: DiagnosticLog? = nil,
        onTermination: @escaping FlowTerminationHandler = { _ in }
    ) throws {
        guard (1...Self.hardMaximumReadBytes).contains(maximumReadBytes) else {
            throw FlowStateMachineConfigurationError.invalidMaximumReadBytes(
                maximumReadBytes
            )
        }
        guard halfCloseIdleTimeout > .zero else {
            throw FlowStateMachineConfigurationError.invalidHalfCloseIdleTimeout
        }
        self.halfCloseIdleTimeout = halfCloseIdleTimeout
        self.sessionID = sessionID
        self.diagnosticLog = diagnosticLog ?? Self.pumpLog
        self.flow = flow
        self.bridgeSource = bridgeSource
        self.bridgeSink = bridgeSink
        self.bridgeSourceAndSinkShareIdentity =
            ObjectIdentifier(bridgeSource) == ObjectIdentifier(bridgeSink)
        self.maximumReadBytes = maximumReadBytes
        self.onTermination = onTermination
    }

    // Gated: the read callbacks fire per datagram, so an ungated record here
    // is the single largest logging cost in the product.
    private static let pumpLog = DiagnosticLogCenter.current.log(
        category: "tcp-pump"
    )

    public func start() throws {
        guard lifecycle == .idle else {
            throw FlowStateMachineStartError.alreadyStarted
        }
        lifecycle = .running
        startedAt = ProcessInfo.processInfo.systemUptime
        issueFlowRead()
        issueBridgeRead()
    }

    public func cancel() {
        guard lifecycle == .idle || lifecycle == .running else {
            return
        }
        halfCloseTimeoutTask?.cancel()
        halfCloseTimeoutTask = nil
        lifecycle = .cancelled
        invalidateOperations()
        cancelTransports()
        reportTermination()
    }

    public func snapshot() -> TCPFlowSnapshot {
        let tokens = [
            flowReadToken,
            flowWriteToken,
            flowFinishToken,
            bridgeReadToken,
            bridgeWriteToken,
            bridgeFinishToken,
        ]
        return TCPFlowSnapshot(
            lifecycle: lifecycle,
            flowInputEnded: flowInputEnded,
            bridgeInputEnded: bridgeInputEnded,
            flowOutputFinished: flowOutputFinished,
            bridgeOutputFinished: bridgeOutputFinished,
            inFlight: Set(tokens.compactMap(\.?.kind))
        )
    }

    private func nextToken(_ kind: FlowOperationKind) -> FlowOperationToken {
        sequence &+= 1
        return FlowOperationToken(
            sessionID: sessionID,
            sequence: sequence,
            kind: kind
        )
    }

    private func issueFlowRead() {
        guard lifecycle == .running, flowReadToken == nil, !flowInputEnded else {
            return
        }
        let token = nextToken(.flowRead)
        flowReadToken = token
        flow.read(maximumBytes: maximumReadBytes, token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeFlowRead(returnedToken, result: result)
            }
        }
    }

    private func issueBridgeRead() {
        guard
            lifecycle == .running,
            bridgeReadToken == nil,
            !bridgeInputEnded
        else {
            return
        }
        let token = nextToken(.bridgeRead)
        bridgeReadToken = token
        bridgeSource.read(maximumBytes: maximumReadBytes, token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeBridgeRead(returnedToken, result: result)
            }
        }
    }

    private func completeFlowRead(
        _ token: FlowOperationToken,
        result: Result<TCPReadResult, FlowIOError>
    ) {
        guard lifecycle == .running, flowReadToken == token else {
            return
        }
        flowReadToken = nil

        switch result {
        case let .failure(error):
            fail(error, stage: .flowRead)
        case .success(.endOfStream):
            Self.pumpLog.verbose("stage=flowRead outcome=endOfStream")
            if firstEOF == "none" { firstEOF = "flowRead" }
            flowInputEnded = true
            halfCloseTimeoutTask?.cancel()
            halfCloseTimeoutTask = nil
            issueBridgeFinish()
        case let .success(.bytes(data)):
            Self.pumpLog.verbose(
                "stage=flowRead outcome=bytes count=\(data.count)"
            )
            guard !data.isEmpty, data.count <= maximumReadBytes else {
                fail(.invalidData("TCP flow returned an invalid read size"), stage: .flowRead)
                return
            }
            lastTransferAt = .now
            flowReadBytes += UInt64(data.count)
            issueBridgeWrite(data)
        }
    }

    private func completeBridgeRead(
        _ token: FlowOperationToken,
        result: Result<TCPReadResult, FlowIOError>
    ) {
        guard lifecycle == .running, bridgeReadToken == token else {
            return
        }
        bridgeReadToken = nil

        switch result {
        case let .failure(error):
            fail(error, stage: .bridgeRead)
        case .success(.endOfStream):
            // An immediate end-of-stream here means the core closed the flow
            // without ever reaching the upstream node.
            Self.pumpLog.verbose("stage=bridgeRead outcome=endOfStream")
            if firstEOF == "none" { firstEOF = "bridgeRead" }
            bridgeInputEnded = true
            issueFlowFinish()
        case let .success(.bytes(data)):
            Self.pumpLog.verbose(
                "stage=bridgeRead outcome=bytes count=\(data.count)"
            )
            guard !data.isEmpty, data.count <= maximumReadBytes else {
                fail(.invalidData("TCP bridge returned an invalid read size"), stage: .bridgeRead)
                return
            }
            bridgeReadBytes += UInt64(data.count)
            issueFlowWrite(data)
        }
    }

    private func issueBridgeWrite(_ data: Data) {
        guard lifecycle == .running, bridgeWriteToken == nil else {
            fail(.invalidData("Overlapping TCP bridge write"), stage: .bridgeWrite)
            return
        }
        let token = nextToken(.bridgeWrite)
        bridgeWriteToken = token
        pendingBridgeWriteBytes = data.count
        bridgeSink.write(data, token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeBridgeWrite(returnedToken, result: result)
            }
        }
    }

    private func completeBridgeWrite(
        _ token: FlowOperationToken,
        result: Result<Void, FlowIOError>
    ) {
        guard lifecycle == .running, bridgeWriteToken == token else {
            return
        }
        bridgeWriteToken = nil
        switch result {
        case let .failure(error):
            fail(error, stage: .bridgeWrite)
        case .success:
            lastTransferAt = .now
            DiagnosticFlowOpenObserver.shared.record(.bytesUpstream(pendingBridgeWriteBytes))
            bridgeWrittenBytes += UInt64(pendingBridgeWriteBytes)
            pendingBridgeWriteBytes = 0
            issueFlowRead()
        }
    }

    private func issueFlowWrite(_ data: Data) {
        guard lifecycle == .running, flowWriteToken == nil else {
            fail(.invalidData("Overlapping TCP flow write"), stage: .flowWrite)
            return
        }
        let token = nextToken(.flowWrite)
        flowWriteToken = token
        pendingFlowWriteBytes = data.count
        flow.write(data, token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeFlowWrite(returnedToken, result: result)
            }
        }
    }

    private func completeFlowWrite(
        _ token: FlowOperationToken,
        result: Result<Void, FlowIOError>
    ) {
        guard lifecycle == .running, flowWriteToken == token else {
            return
        }
        flowWriteToken = nil
        switch result {
        case let .failure(error):
            fail(error, stage: .flowWrite)
        case .success:
            DiagnosticFlowOpenObserver.shared.record(.bytesClient(pendingFlowWriteBytes))
            flowWrittenBytes += UInt64(pendingFlowWriteBytes)
            pendingFlowWriteBytes = 0
            issueBridgeRead()
        }
    }

    private func issueBridgeFinish() {
        guard lifecycle == .running, bridgeFinishToken == nil else {
            return
        }
        let token = nextToken(.bridgeFinishWriting)
        bridgeFinishToken = token
        bridgeSink.finishWriting(token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeBridgeFinish(
                    returnedToken,
                    result: result
                )
            }
        }
    }

    private func completeBridgeFinish(
        _ token: FlowOperationToken,
        result: Result<Void, FlowIOError>
    ) {
        guard lifecycle == .running, bridgeFinishToken == token else {
            return
        }
        bridgeFinishToken = nil
        switch result {
        case let .failure(error):
            fail(error, stage: .bridgeFinishWriting)
        case .success:
            bridgeOutputFinished = true
            finishIfBothDirectionsEnded()
        }
    }

    private func issueFlowFinish() {
        guard lifecycle == .running, flowFinishToken == nil else {
            return
        }
        let token = nextToken(.flowFinishWriting)
        flowFinishToken = token
        flow.finishWriting(token: token) {
            [weak self] returnedToken, result in
            Task {
                await self?.completeFlowFinish(returnedToken, result: result)
            }
        }
    }

    private func completeFlowFinish(
        _ token: FlowOperationToken,
        result: Result<Void, FlowIOError>
    ) {
        guard lifecycle == .running, flowFinishToken == token else {
            return
        }
        flowFinishToken = nil
        switch result {
        case let .failure(error):
            fail(error, stage: .flowFinishWriting)
        case .success:
            flowOutputFinished = true
            finishIfBothDirectionsEnded()
        }
    }

    private func finishIfBothDirectionsEnded() {
        guard
            flowInputEnded,
            bridgeInputEnded,
            flowOutputFinished,
            bridgeOutputFinished
        else {
            if bridgeInputEnded, flowOutputFinished, !flowInputEnded, halfCloseTimeoutTask == nil {
                lastTransferAt = .now
                halfCloseTimeoutTask = Task { [weak self, timeout = halfCloseIdleTimeout] in
                    var delay = timeout
                    while !Task.isCancelled {
                        do {
                            try await Task.sleep(for: delay)
                        } catch {
                            return
                        }
                        guard let remaining = await self?.nextHalfCloseIdleDelay() else { return }
                        delay = remaining
                    }
                }
            }
            return
        }
        halfCloseTimeoutTask?.cancel()
        halfCloseTimeoutTask = nil
        terminationTrigger = "bothEOF"
        lifecycle = .finished
        invalidateOperations()
        reportTermination()
    }

    /// One watchdog per half-closed flow. Traffic updates a timestamp instead
    /// of allocating/cancelling a timer task for every forwarded chunk.
    private func nextHalfCloseIdleDelay() -> Duration? {
        guard lifecycle == .running, bridgeInputEnded, flowOutputFinished, !flowInputEnded else {
            return nil
        }
        // Rust owns the network-side idle policy. A pending bridge write can
        // still be draining a slow upstream; it is not an idle local client.
        guard bridgeWriteToken == nil else { return halfCloseIdleTimeout }
        let remaining = halfCloseIdleTimeout - lastTransferAt.duration(to: .now)
        if remaining > .zero { return remaining }
        terminationTrigger = "halfCloseTimeout"
        cancel()
        return nil
    }

    private func fail(_ error: FlowIOError, stage: FlowOperationKind) {
        guard lifecycle == .running else {
            return
        }
        halfCloseTimeoutTask?.cancel()
        halfCloseTimeoutTask = nil
        terminationTrigger = stage.rawValue
        lifecycle = .failed(error)
        invalidateOperations()
        cancelTransports()
        reportTermination()
    }

    private func invalidateOperations() {
        flowReadToken = nil
        flowWriteToken = nil
        flowFinishToken = nil
        bridgeReadToken = nil
        bridgeWriteToken = nil
        bridgeFinishToken = nil
    }

    private func cancelTransports() {
        flow.cancel()
        bridgeSource.cancel()
        if !bridgeSourceAndSinkShareIdentity {
            bridgeSink.cancel()
        }
    }

    private func reportTermination() {
        guard !didReportTermination else { return }
        didReportTermination = true
        if case .failed = lifecycle {
            DiagnosticFlowOpenObserver.shared.record(.sessionFailed)
        }
        // Exactly one boundary record, with fixed classifications only. Error
        // descriptions may contain credentials/endpoints and never enter it.
        let outcome: String
        let errorClass: String
        switch lifecycle {
        case let .failed(error):
            outcome = "failed"
            switch error {
            case .closed: errorClass = "closed"
            case .cancelled: errorClass = "cancelled"
            case .invalidData: errorClass = "invalidData"
            case .transport: errorClass = "transport"
            }
        case .finished: outcome = "finished"; errorClass = "none"
        case .cancelled: outcome = "cancelled"; errorClass = "none"
        case .idle, .running: return
        }
        let expiredHalfClose = terminationTrigger == "halfCloseTimeout"
        guard outcome == "failed" || expiredHalfClose || diagnosticLog.level.recordsPerFlow else {
            onTermination(lifecycle)
            return
        }
        let ageMilliseconds = Int(max(0, ProcessInfo.processInfo.systemUptime - startedAt) * 1_000)
        let summary = "stage=tcpTermination session=\(sessionID.uuidString) "
            + "trigger=\(terminationTrigger) outcome=\(outcome) error=\(errorClass) "
            + "ageMs=\(ageMilliseconds) firstEOF=\(firstEOF) "
            + "flowReadBytes=\(flowReadBytes) bridgeWrittenBytes=\(bridgeWrittenBytes) "
            + "bridgeReadBytes=\(bridgeReadBytes) flowWrittenBytes=\(flowWrittenBytes) "
            + "pendingBridgeWriteBytes=\(pendingBridgeWriteBytes) pendingFlowWriteBytes=\(pendingFlowWriteBytes)"
        if outcome == "failed" {
            diagnosticLog.failure(summary)
        } else if expiredHalfClose {
            // Expected idle reclamation is visible in standard diagnostics,
            // but is not a failed session or a user-requested cancellation.
            diagnosticLog.aggregate(summary)
        } else {
            diagnosticLog.verbose(summary)
        }
        onTermination(lifecycle)
    }
}

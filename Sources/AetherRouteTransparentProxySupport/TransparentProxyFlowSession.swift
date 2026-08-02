import AetherRouteKit
import Foundation

protocol AppleProxyFlowOpening: Sendable {
    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    )
}

public protocol RustStagedFlowLifecycle: Sendable {
    /// May perform dispatcher work. Implementations must invoke completion
    /// exactly once and serialize this call against `destroy`.
    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    )

    /// Idempotent and safe to race with an accepted asynchronous operation.
    func cancel()

    /// Callback barrier. Completion means no callback for this handle can run.
    func destroy(completion: @escaping @Sendable () -> Void)
}

public protocol RustTCPFlowBridge:
    RustStagedFlowLifecycle,
    RustTCPSource,
    RustTCPSink
{}

public protocol RustUDPFlowBridge:
    RustStagedFlowLifecycle,
    RustUDPSource,
    RustUDPSink
{}

enum TransparentProxyFlowSessionConfigurationError:
    Error,
    Sendable,
    Equatable
{
    case resourceLeaseKindMismatch
    case resourceLeaseUnavailable
    case sourceEndpointLeaseUnavailable
    case maximumTCPReadBytesExceedsAdmissionProfile
}

/// Owns one retained Apple TCP flow and one staged Rust handle. Startup order
/// is fixed to retain -> Apple open -> Rust activate -> bidirectional pump.
final class TransparentTCPProxySession:
    TransparentProxyIngressSession,
    @unchecked Sendable
{
    let sessionID: UUID

    private let opening: any AppleProxyFlowOpening
    private let flow: any TransparentTCPFlowIO
    private let rust: any RustTCPFlowBridge
    private let lifecycleQueue: DispatchQueue
    private var resourceLease: FlowResourceLease?
    private weak var registry: TransparentProxySessionRegistry?
    private let lock = NSLock()
    private var phase: Phase = .staged
    private var openCallbackPending = false
    private var destroyStarted = false
    private var destroyFinished = false
    private var appleDrainStarted = false
    private var appleDrainFinished = false
    private var machine: TCPFlowStateMachine?

    init(
        sessionID: UUID = UUID(),
        opening: any AppleProxyFlowOpening,
        flow: any TransparentTCPFlowIO,
        rust: any RustTCPFlowBridge,
        resourceLease: FlowResourceLease,
        registry: TransparentProxySessionRegistry,
        maximumReadBytes: Int = TCPFlowStateMachine.defaultMaximumReadBytes
    ) throws {
        guard resourceLease.kind == .tcp else {
            throw TransparentProxyFlowSessionConfigurationError
                .resourceLeaseKindMismatch
        }
        guard
            (1...TCPFlowStateMachine.defaultMaximumReadBytes)
                .contains(maximumReadBytes)
        else {
            throw TransparentProxyFlowSessionConfigurationError
                .maximumTCPReadBytesExceedsAdmissionProfile
        }
        guard resourceLease.claim(expectedKind: .tcp) else {
            throw TransparentProxyFlowSessionConfigurationError
                .resourceLeaseUnavailable
        }
        self.sessionID = sessionID
        self.opening = opening
        self.flow = flow
        self.rust = rust
        self.lifecycleQueue = DispatchQueue(
            label: "com.example.aetherroute.tcp-session.\(sessionID.uuidString)"
        )
        self.resourceLease = resourceLease
        self.registry = registry
        self.machine = nil
        do {
            self.machine = try TCPFlowStateMachine(
                flow: flow,
                bridgeSource: rust,
                bridgeSink: rust,
                maximumReadBytes: maximumReadBytes
            ) { [weak self] lifecycle in
                self?.scheduleMachineTermination(lifecycle)
            }
        } catch {
            self.resourceLease = nil
            resourceLease.release()
            throw error
        }
    }

    func start() {
        lifecycleQueue.async { [self] in
            startSerialized()
        }
    }

    private func startSerialized() {
        let shouldOpen = lock.withLock { () -> Bool in
            guard phase == .staged else { return false }
            phase = .opening
            openCallbackPending = true
            return true
        }
        guard shouldOpen else { return }
        issueOpen()
    }

    private func issueOpen() {
        // Strong ownership is deliberate. An insert-failed session is not in
        // the registry; the open callback must keep it alive until close/drain
        // can establish the remaining termination barrier.
        opening.open { [self] result in
            lifecycleQueue.async { [self] in
                openCompleted(result)
            }
        }
    }

    func cancel() {
        lifecycleQueue.async { [self] in
            cancelSerialized()
        }
    }

    private func cancelSerialized() {
        let action = lock.withLock { () -> CancelAction in
            switch phase {
            case .staged:
                phase = .terminating
                openCallbackPending = true
                return .openThenDestroy
            case .opening, .activating:
                phase = .terminating
                return .destroyDirectly
            case .running:
                return .cancelMachine
            case .terminating, .terminated:
                return .none
            }
        }

        switch action {
        case .none:
            break
        case .openThenDestroy:
            // An unopened claimed flow must still traverse Apple's open
            // lifecycle before close. issueOpen returns immediately; the
            // Apple drain is deferred until its callback arrives.
            issueOpen()
            terminateDirectly()
        case .cancelMachine:
            guard let machine else {
                terminateDirectly()
                return
            }
            Task { await machine.cancel() }
        case .destroyDirectly:
            terminateDirectly()
        }
    }

    private func openCompleted(_ result: Result<Void, FlowIOError>) {
        let action = lock.withLock { () -> OpenAction in
            guard openCallbackPending else { return .none }
            openCallbackPending = false
            switch phase {
            case .opening:
                switch result {
                case .success:
                    phase = .activating
                    return .activate
                case .failure:
                    phase = .terminating
                    return .destroy
                }
            case .terminating:
                guard !appleDrainStarted else {
                    return markTerminationIfReadyLocked()
                        ? .reportTermination
                        : .none
                }
                appleDrainStarted = true
                return .drainApple
            case .staged, .activating, .running, .terminated:
                return .none
            }
        }

        switch action {
        case .none:
            break
        case .activate:
            rust.activate { [weak self] result in
                guard let self else { return }
                lifecycleQueue.async { [weak self] in
                    self?.activationCompleted(result)
                }
            }
        case .destroy:
            terminateDirectly()
        case .drainApple:
            beginAppleDrain()
        case .reportTermination:
            reportTermination()
        }
    }

    private func activationCompleted(_ result: Result<Void, FlowIOError>) {
        let action = lock.withLock { () -> ActivationAction in
            guard phase == .activating else { return .none }
            switch result {
            case .success:
                phase = .running
                return .startMachine
            case .failure:
                phase = .terminating
                return .destroy
            }
        }

        switch action {
        case .none:
            break
        case .startMachine:
            guard let machine else {
                cancel()
                return
            }
            Task { [weak self] in
                do {
                    try await machine.start()
                } catch {
                    self?.cancel()
                }
            }
        case .destroy:
            terminateDirectly()
        }
    }

    private func scheduleMachineTermination(_ lifecycle: FlowLifecycle) {
        lifecycleQueue.async { [weak self] in
            self?.machineTerminated(lifecycle)
        }
    }

    private func machineTerminated(_: FlowLifecycle) {
        let shouldDestroy = lock.withLock { () -> Bool in
            guard phase == .running else { return false }
            phase = .terminating
            return true
        }
        guard shouldDestroy else { return }

        // Failed/cancelled state machines already cancelled both transports;
        // a clean finish needs no cancellation. Only the destroy barrier
        // remains at this ownership layer.
        beginDestroy()
    }

    private func terminateDirectly() {
        rust.cancel()
        beginDestroy()
    }

    private func beginDestroy() {
        let action = lock.withLock { () -> (Bool, Bool) in
            guard phase == .terminating, !destroyStarted else {
                return (false, false)
            }
            destroyStarted = true
            let shouldDrainApple =
                !openCallbackPending && !appleDrainStarted
            if shouldDrainApple { appleDrainStarted = true }
            return (true, shouldDrainApple)
        }
        guard action.0 else { return }

        if action.1 { beginAppleDrain() }

        // A strong capture deliberately keeps an unregistered startup failure
        // alive until the native callback barrier returns.
        rust.destroy { [self] in
            lifecycleQueue.async { [self] in
                destroyCompleted()
            }
        }
    }

    private func beginAppleDrain() {
        flow.cancelAndDrain { [self] in
            lifecycleQueue.async { [self] in
                appleDrainCompleted()
            }
        }
    }

    private func appleDrainCompleted() {
        let shouldReport = lock.withLock { () -> Bool in
            appleDrainFinished = true
            return markTerminationIfReadyLocked()
        }
        if shouldReport { reportTermination() }
    }

    private func destroyCompleted() {
        let shouldReport = lock.withLock { () -> Bool in
            destroyFinished = true
            return markTerminationIfReadyLocked()
        }
        if shouldReport { reportTermination() }
    }

    private func markTerminationIfReadyLocked() -> Bool {
        guard
            phase == .terminating,
            destroyFinished,
            appleDrainFinished,
            !openCallbackPending
        else { return false }
        phase = .terminated
        return true
    }

    private func reportTermination() {
        let lease = lock.withLock { () -> FlowResourceLease? in
            defer { resourceLease = nil }
            return resourceLease
        }
        lease?.release()
        registry?.didTerminate(sessionID: sessionID)
    }

    private enum Phase {
        case staged
        case opening
        case activating
        case running
        case terminating
        case terminated
    }

    private enum CancelAction {
        case none
        case openThenDestroy
        case cancelMachine
        case destroyDirectly
    }

    private enum OpenAction {
        case none
        case activate
        case destroy
        case drainApple
        case reportTermination
    }

    private enum ActivationAction {
        case none
        case startMachine
        case destroy
    }
}

/// UDP equivalent of `TransparentTCPProxySession`. A synthetic source lease,
/// when needed, stays reserved until the Rust destroy callback barrier returns.
final class TransparentUDPProxySession:
    TransparentProxyIngressSession,
    @unchecked Sendable
{
    let sessionID: UUID

    private let opening: any AppleProxyFlowOpening
    private let flow: any TransparentUDPFlowIO
    private let rust: any RustUDPFlowBridge
    private let lifecycleQueue: DispatchQueue
    private var resourceLease: FlowResourceLease?
    private weak var registry: TransparentProxySessionRegistry?
    private let lock = NSLock()
    private var phase: Phase = .staged
    private var openCallbackPending = false
    private var destroyStarted = false
    private var destroyFinished = false
    private var appleDrainStarted = false
    private var appleDrainFinished = false
    private var machine: UDPFlowStateMachine?
    private var sourceLease: SyntheticSourceEndpointLease?

    init(
        sessionID: UUID = UUID(),
        opening: any AppleProxyFlowOpening,
        flow: any TransparentUDPFlowIO,
        rust: any RustUDPFlowBridge,
        resourceLease: FlowResourceLease,
        registry: TransparentProxySessionRegistry,
        sourceLease: SyntheticSourceEndpointLease? = nil,
        policy: UDPBatchPolicy = .strict
    ) throws {
        guard resourceLease.kind == .udp else {
            throw TransparentProxyFlowSessionConfigurationError
                .resourceLeaseKindMismatch
        }
        let validatedPolicy = try policy.validated()
        guard resourceLease.claim(expectedKind: .udp) else {
            throw TransparentProxyFlowSessionConfigurationError
                .resourceLeaseUnavailable
        }
        if let sourceLease, !sourceLease.claim() {
            resourceLease.release()
            throw TransparentProxyFlowSessionConfigurationError
                .sourceEndpointLeaseUnavailable
        }
        self.sessionID = sessionID
        self.opening = opening
        self.flow = flow
        self.rust = rust
        self.lifecycleQueue = DispatchQueue(
            label: "com.example.aetherroute.udp-session.\(sessionID.uuidString)"
        )
        self.resourceLease = resourceLease
        self.registry = registry
        self.sourceLease = sourceLease
        self.machine = nil
        do {
            self.machine = try UDPFlowStateMachine(
                flow: flow,
                bridgeSource: rust,
                bridgeSink: rust,
                policy: validatedPolicy
            ) { [weak self] lifecycle in
                self?.scheduleMachineTermination(lifecycle)
            }
        } catch {
            self.sourceLease = nil
            self.resourceLease = nil
            sourceLease?.release()
            resourceLease.release()
            throw error
        }
    }

    func start() {
        lifecycleQueue.async { [self] in
            startSerialized()
        }
    }

    private func startSerialized() {
        let shouldOpen = lock.withLock { () -> Bool in
            guard phase == .staged else { return false }
            phase = .opening
            openCallbackPending = true
            return true
        }
        guard shouldOpen else { return }
        issueOpen()
    }

    private func issueOpen() {
        opening.open { [self] result in
            lifecycleQueue.async { [self] in
                openCompleted(result)
            }
        }
    }

    func cancel() {
        lifecycleQueue.async { [self] in
            cancelSerialized()
        }
    }

    private func cancelSerialized() {
        let action = lock.withLock { () -> CancelAction in
            switch phase {
            case .staged:
                phase = .terminating
                openCallbackPending = true
                return .openThenDestroy
            case .opening, .activating:
                phase = .terminating
                return .destroyDirectly
            case .running:
                return .cancelMachine
            case .terminating, .terminated:
                return .none
            }
        }
        switch action {
        case .none:
            break
        case .openThenDestroy:
            issueOpen()
            terminateDirectly()
        case .cancelMachine:
            guard let machine else {
                terminateDirectly()
                return
            }
            Task { await machine.cancel() }
        case .destroyDirectly:
            terminateDirectly()
        }
    }

    private func openCompleted(_ result: Result<Void, FlowIOError>) {
        let action = lock.withLock { () -> OpenAction in
            guard openCallbackPending else { return .none }
            openCallbackPending = false
            switch phase {
            case .opening:
                switch result {
                case .success:
                    phase = .activating
                    return .activate
                case .failure:
                    phase = .terminating
                    return .destroy
                }
            case .terminating:
                guard !appleDrainStarted else {
                    return markTerminationIfReadyLocked()
                        ? .reportTermination
                        : .none
                }
                appleDrainStarted = true
                return .drainApple
            case .staged, .activating, .running, .terminated:
                return .none
            }
        }
        switch action {
        case .none:
            break
        case .activate:
            rust.activate { [weak self] result in
                guard let self else { return }
                lifecycleQueue.async { [weak self] in
                    self?.activationCompleted(result)
                }
            }
        case .destroy:
            terminateDirectly()
        case .drainApple:
            beginAppleDrain()
        case .reportTermination:
            reportTermination()
        }
    }

    private func activationCompleted(_ result: Result<Void, FlowIOError>) {
        let action = lock.withLock { () -> ActivationAction in
            guard phase == .activating else { return .none }
            switch result {
            case .success:
                phase = .running
                return .startMachine
            case .failure:
                phase = .terminating
                return .destroy
            }
        }
        switch action {
        case .none:
            break
        case .startMachine:
            guard let machine else {
                cancel()
                return
            }
            Task { [weak self] in
                do {
                    try await machine.start()
                } catch {
                    self?.cancel()
                }
            }
        case .destroy:
            terminateDirectly()
        }
    }

    private func scheduleMachineTermination(_ lifecycle: FlowLifecycle) {
        lifecycleQueue.async { [weak self] in
            self?.machineTerminated(lifecycle)
        }
    }

    private func machineTerminated(_: FlowLifecycle) {
        let shouldDestroy = lock.withLock { () -> Bool in
            guard phase == .running else { return false }
            phase = .terminating
            return true
        }
        guard shouldDestroy else { return }
        beginDestroy()
    }

    private func terminateDirectly() {
        rust.cancel()
        beginDestroy()
    }

    private func beginDestroy() {
        let action = lock.withLock { () -> (Bool, Bool) in
            guard phase == .terminating, !destroyStarted else {
                return (false, false)
            }
            destroyStarted = true
            let shouldDrainApple =
                !openCallbackPending && !appleDrainStarted
            if shouldDrainApple { appleDrainStarted = true }
            return (true, shouldDrainApple)
        }
        guard action.0 else { return }
        if action.1 { beginAppleDrain() }
        rust.destroy { [self] in
            lifecycleQueue.async { [self] in
                destroyCompleted()
            }
        }
    }

    private func beginAppleDrain() {
        flow.cancelAndDrain { [self] in
            lifecycleQueue.async { [self] in
                appleDrainCompleted()
            }
        }
    }

    private func appleDrainCompleted() {
        let shouldReport = lock.withLock { () -> Bool in
            appleDrainFinished = true
            return markTerminationIfReadyLocked()
        }
        if shouldReport { reportTermination() }
    }

    private func destroyCompleted() {
        let shouldReport = lock.withLock { () -> Bool in
            destroyFinished = true
            return markTerminationIfReadyLocked()
        }
        if shouldReport { reportTermination() }
    }

    private func markTerminationIfReadyLocked() -> Bool {
        guard
            phase == .terminating,
            destroyFinished,
            appleDrainFinished,
            !openCallbackPending
        else { return false }
        phase = .terminated
        return true
    }

    private func reportTermination() {
        let resources = lock.withLock { () -> (
            SyntheticSourceEndpointLease?,
            FlowResourceLease?
        ) in
            defer { sourceLease = nil }
            defer { resourceLease = nil }
            return (sourceLease, resourceLease)
        }
        resources.0?.release()
        resources.1?.release()
        registry?.didTerminate(sessionID: sessionID)
    }

    private enum Phase {
        case staged
        case opening
        case activating
        case running
        case terminating
        case terminated
    }

    private enum CancelAction {
        case none
        case openThenDestroy
        case cancelMachine
        case destroyDirectly
    }

    private enum OpenAction {
        case none
        case activate
        case destroy
        case drainApple
        case reportTermination
    }

    private enum ActivationAction {
        case none
        case startMachine
        case destroy
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

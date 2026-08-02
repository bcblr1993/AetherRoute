import AetherRouteKit
import Foundation
@preconcurrency import NetworkExtension

/// Provider-owned lifetime barrier for raw flows that cannot be safely adapted
/// into sealed TCP/UDP ingress components. Every accepted claim is retained
/// until open -> close has completed. `stopAll` closes admission and does not
/// complete until all accepted native-flow callbacks have returned.
public final class NetworkExtensionFailClosedFlowRegistry:
    @unchecked Sendable
{
    public typealias StopCompletion = @Sendable () -> Void

    private let lock = NSLock()
    private var lifecycle: Lifecycle = .accepting
    private var claims: [UUID: FailClosedAppleFlowClaim] = [:]
    private var stopCompletions: [StopCompletion] = []

    public init() {}

    @discardableResult
    public func claimAndClose(_ flow: NEAppProxyFlow) -> Bool {
        claim(
            access: NetworkExtensionFailClosedFlowAccess(flow: flow)
        )
    }

    @discardableResult
    func claim(access: any FailClosedAppleFlowAccess) -> Bool {
        let id = UUID()
        let claim = FailClosedAppleFlowClaim(
            id: id,
            access: access
        ) { [weak self] finishedID in
            self?.didFinish(id: finishedID)
        }
        let inserted = lock.withLock { () -> Bool in
            guard lifecycle == .accepting else { return false }
            claims[id] = claim
            return true
        }
        guard inserted else { return false }
        // The registry retained the exact flow before open can callback.
        claim.start()
        return true
    }

    public func stopAll(completion: @escaping StopCompletion) {
        let completions = lock.withLock { () -> [StopCompletion] in
            switch lifecycle {
            case .stopped:
                return [completion]
            case .stopping:
                stopCompletions.append(completion)
                return []
            case .accepting:
                lifecycle = .stopping
                stopCompletions.append(completion)
                guard claims.isEmpty else { return [] }
                lifecycle = .stopped
                defer { stopCompletions.removeAll(keepingCapacity: false) }
                return stopCompletions
            }
        }
        completions.forEach { $0() }
    }

    /// A provider instance may be started again only after the previous stop
    /// barrier completed and no claim remains. This method is called before
    /// runtime preparation and performs no network operation.
    func resetForStart() -> Bool {
        lock.withLock {
            switch lifecycle {
            case .accepting:
                return claims.isEmpty
            case .stopping:
                return false
            case .stopped:
                guard claims.isEmpty else { return false }
                lifecycle = .accepting
                return true
            }
        }
    }

    var activeClaimCount: Int {
        lock.withLock { claims.count }
    }

    private func didFinish(id: UUID) {
        let action = lock.withLock { () -> FinishAction in
            guard let removed = claims.removeValue(forKey: id) else {
                return .none
            }
            guard lifecycle == .stopping, claims.isEmpty else {
                return .release(removed, completions: [])
            }
            lifecycle = .stopped
            defer { stopCompletions.removeAll(keepingCapacity: false) }
            return .release(removed, completions: stopCompletions)
        }

        switch action {
        case .none:
            break
        case let .release(claim, completions):
            withExtendedLifetime(claim) {}
            completions.forEach { $0() }
        }
    }

    private enum Lifecycle {
        case accepting
        case stopping
        case stopped
    }

    private enum FinishAction {
        case none
        case release(
            FailClosedAppleFlowClaim,
            completions: [StopCompletion]
        )
    }
}

/// Synchronous terminal fallback for a flow delivered after provider stop has
/// already sealed handler admission. NetworkExtension should not make such a
/// call; no asynchronous open is issued because the provider's callback
/// lifetime barrier has already closed.
public enum NetworkExtensionStoppedProviderFlow {
    @discardableResult
    public static func claimAndCloseSynchronously(_ flow: NEAppProxyFlow) -> Bool {
        let error = NetworkExtensionFlowErrorMapper.aborted
        flow.closeReadWithError(error)
        flow.closeWriteWithError(error)
        return true
    }
}

protocol FailClosedAppleFlowAccess: AnyObject, Sendable {
    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    )
    func close(completion: @escaping @Sendable () -> Void)
}

private final class NetworkExtensionFailClosedFlowAccess:
    FailClosedAppleFlowAccess,
    @unchecked Sendable
{
    private let flow: NEAppProxyFlow
    private let executor = NetworkExtensionFlowExecutor(
        label: "com.example.aetherroute.apple-fail-closed-flow"
    )

    init(flow: NEAppProxyFlow) {
        self.flow = flow
    }

    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        executor.execute { [flow] in
            NetworkExtensionFlowLifecycle.open(
                flow,
                completion: completion
            )
        }
    }

    func close(completion: @escaping @Sendable () -> Void) {
        executor.execute { [flow] in
            let error = NetworkExtensionFlowErrorMapper.refused
            flow.closeReadWithError(error)
            flow.closeWriteWithError(error)
            completion()
        }
    }
}

/// Internal seam keeps the open/close order testable without manufacturing an
/// NEAppProxyFlow or activating a provider. Production lifetime is owned by
/// NetworkExtensionFailClosedFlowRegistry, not by an untracked global object.
final class FailClosedAppleFlowClaim: @unchecked Sendable {
    typealias Finished = @Sendable (UUID) -> Void

    let id: UUID
    private let access: any FailClosedAppleFlowAccess
    private let finished: Finished
    private let lock = NSLock()
    private var phase: Phase = .staged

    init(
        id: UUID = UUID(),
        access: any FailClosedAppleFlowAccess,
        finished: @escaping Finished = { _ in }
    ) {
        self.id = id
        self.access = access
        self.finished = finished
    }

    @discardableResult
    func start() -> Bool {
        let shouldStart = lock.withLock { () -> Bool in
            guard phase == .staged else { return false }
            phase = .opening
            return true
        }
        guard shouldStart else { return false }
        access.open { [self] _ in
            openCompleted()
        }
        return true
    }

    private func openCompleted() {
        let shouldClose = lock.withLock { () -> Bool in
            guard phase == .opening else { return false }
            phase = .closing
            return true
        }
        guard shouldClose else { return }
        access.close { [self] in
            let shouldFinish = lock.withLock { () -> Bool in
                guard phase == .closing else { return false }
                phase = .closed
                return true
            }
            if shouldFinish { finished(id) }
        }
    }

    private enum Phase {
        case staged
        case opening
        case closing
        case closed
    }
}

private extension NSLock {
    func withLock<Value>(_ operation: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return operation()
    }
}

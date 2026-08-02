import AetherRouteKit
import Foundation

/// Privacy-safe startup stage telemetry. Underlying errors can contain profile
/// or endpoint data and therefore never leave the ingress boundary.
public enum TransparentProxyIngressFailurePoint: Sendable, Equatable {
    case identityRejection
    case componentBinding
    case resourceAdmission
    case sourceEndpointAdmission
    case rustStagedCreation
    case sessionCreation
    case registryInsertion
    case sessionStart
}

/// A provider-facing result with no bypass representation. Once a non-self
/// flow enters this coordinator it is claimed even if startup fails; callers
/// close the flow through rollback rather than returning false to the system.
public struct TransparentProxyIngressClaimResult: Sendable, Equatable {
    public let claimed: Bool
    public let sessionID: UUID?
    public let failurePoint: TransparentProxyIngressFailurePoint?

    fileprivate init(
        sessionID: UUID? = nil,
        failurePoint: TransparentProxyIngressFailurePoint? = nil
    ) {
        claimed = true
        self.sessionID = sessionID
        self.failurePoint = failurePoint
    }
}

/// Opaque within the support module. NetworkExtension factories mint one
/// identity for the opening and IO sides of exactly one native flow.
struct TransparentProxyAppleFlowIdentity: Sendable, Equatable {
    private let value = UUID()
}

/// Sealed, same-flow TCP components consumed by the ingress coordinator. The
/// raw opening and IO values are intentionally not public, preventing another
/// target from assembling a session out of components from different flows.
public struct TransparentTCPIngressComponents: Sendable {
    fileprivate let opening: any AppleProxyFlowOpening
    fileprivate let flow: any TransparentTCPFlowIO
    fileprivate let openingIdentity: TransparentProxyAppleFlowIdentity
    fileprivate let flowIdentity: TransparentProxyAppleFlowIdentity

    init(
        opening: any AppleProxyFlowOpening,
        flow: any TransparentTCPFlowIO,
        openingIdentity: TransparentProxyAppleFlowIdentity,
        flowIdentity: TransparentProxyAppleFlowIdentity
    ) {
        self.opening = opening
        self.flow = flow
        self.openingIdentity = openingIdentity
        self.flowIdentity = flowIdentity
    }

    fileprivate var hasMatchingFlowIdentity: Bool {
        openingIdentity == flowIdentity
    }
}

/// UDP equivalent of `TransparentTCPIngressComponents`.
public struct TransparentUDPIngressComponents: Sendable {
    fileprivate let opening: any AppleProxyFlowOpening
    fileprivate let flow: any TransparentUDPFlowIO
    fileprivate let openingIdentity: TransparentProxyAppleFlowIdentity
    fileprivate let flowIdentity: TransparentProxyAppleFlowIdentity

    init(
        opening: any AppleProxyFlowOpening,
        flow: any TransparentUDPFlowIO,
        openingIdentity: TransparentProxyAppleFlowIdentity,
        flowIdentity: TransparentProxyAppleFlowIdentity
    ) {
        self.opening = opening
        self.flow = flow
        self.openingIdentity = openingIdentity
        self.flowIdentity = flowIdentity
    }

    fileprivate var hasMatchingFlowIdentity: Bool {
        openingIdentity == flowIdentity
    }
}

/// Internal factory seam for deterministic lifecycle tests. A successful
/// builder transfers ownership of the Apple flow, Rust handle, and leases to
/// its returned session; a throwing builder transfers none of them.
protocol TransparentProxyIngressSession:
    TransparentProxySessionLifetime
{
    func start() throws
}

struct TransparentProxyIngressSessionFactory: Sendable {
    typealias TCPBuilder = @Sendable (
        UUID,
        TransparentTCPIngressComponents,
        any RustTCPFlowBridge,
        FlowResourceLease,
        TransparentProxySessionRegistry
    ) throws -> any TransparentProxyIngressSession

    typealias UDPBuilder = @Sendable (
        UUID,
        TransparentUDPIngressComponents,
        any RustUDPFlowBridge,
        FlowResourceLease,
        TransparentProxySessionRegistry,
        SyntheticSourceEndpointLease?,
        UDPBatchPolicy
    ) throws -> any TransparentProxyIngressSession

    let makeTCP: TCPBuilder
    let makeUDP: UDPBuilder

    static let live = TransparentProxyIngressSessionFactory(
        makeTCP: { sessionID, components, rust, lease, registry in
            try TransparentTCPProxySession(
                sessionID: sessionID,
                opening: components.opening,
                flow: components.flow,
                rust: rust,
                resourceLease: lease,
                registry: registry
            )
        },
        makeUDP: {
            sessionID,
            components,
            rust,
            lease,
            registry,
            sourceLease,
            policy in
            try TransparentUDPProxySession(
                sessionID: sessionID,
                opening: components.opening,
                flow: components.flow,
                rust: rust,
                resourceLease: lease,
                registry: registry,
                sourceLease: sourceLease,
                policy: policy
            )
        }
    )
}

/// Atomic provider ingress transaction for every non-verified-self flow.
///
/// Ordering is fixed: weighted lease (and UDP source lease) -> staged Rust
/// create -> session init/lease claim -> registry retention -> start. Every
/// failure still returns a claimed result. Before session ownership transfers,
/// rollback waits for the Apple open callback, Apple drain, and Rust destroy
/// barriers before releasing either lease. After transfer, session
/// cancellation provides the same three barriers.
public final class TransparentProxyIngressCoordinator: @unchecked Sendable {
    public typealias FailureObserver = @Sendable (
        TransparentProxyIngressFailurePoint
    ) -> Void
    /// A successful factory transfers one staged handle to the coordinator. A
    /// throwing factory must retain no live handle (or finish its own partial
    /// construction cleanup before throwing), because no handle crossed the
    /// ownership boundary for the coordinator to destroy.
    public typealias TCPRustFactory = @Sendable () throws -> any RustTCPFlowBridge
    public typealias UDPRustFactory = @Sendable (
        FlowEndpoint
    ) throws -> any RustUDPFlowBridge

    private let resourceBudget: FlowResourceBudget
    private let sourceEndpointPool: SyntheticSourceEndpointPool
    private let registry: TransparentProxySessionRegistry
    private let sessionFactory: TransparentProxyIngressSessionFactory
    private let failureObserver: FailureObserver

    public convenience init(
        resourceBudget: FlowResourceBudget,
        sourceEndpointPool: SyntheticSourceEndpointPool,
        registry: TransparentProxySessionRegistry,
        failureObserver: @escaping FailureObserver = { _ in }
    ) {
        self.init(
            resourceBudget: resourceBudget,
            sourceEndpointPool: sourceEndpointPool,
            registry: registry,
            sessionFactory: .live,
            failureObserver: failureObserver
        )
    }

    init(
        resourceBudget: FlowResourceBudget,
        sourceEndpointPool: SyntheticSourceEndpointPool,
        registry: TransparentProxySessionRegistry,
        sessionFactory: TransparentProxyIngressSessionFactory,
        failureObserver: @escaping FailureObserver = { _ in }
    ) {
        self.resourceBudget = resourceBudget
        self.sourceEndpointPool = sourceEndpointPool
        self.registry = registry
        self.sessionFactory = sessionFactory
        self.failureObserver = failureObserver
    }

    @discardableResult
    public func claimTCP(
        components: TransparentTCPIngressComponents,
        createRust: TCPRustFactory
    ) -> TransparentProxyIngressClaimResult {
        guard components.hasMatchingFlowIdentity else {
            return rollbackTCP(
                .componentBinding,
                components: components,
                rust: nil,
                resourceLease: nil
            )
        }

        let resourceLease: FlowResourceLease
        do {
            resourceLease = try resourceBudget.lease(for: .tcp)
        } catch {
            return rollbackTCP(
                .resourceAdmission,
                components: components,
                rust: nil,
                resourceLease: nil
            )
        }

        let rust: any RustTCPFlowBridge
        do {
            rust = try createRust()
        } catch {
            return rollbackTCP(
                .rustStagedCreation,
                components: components,
                rust: nil,
                resourceLease: resourceLease
            )
        }

        let sessionID = UUID()
        let session: any TransparentProxyIngressSession
        do {
            session = try sessionFactory.makeTCP(
                sessionID,
                components,
                rust,
                resourceLease,
                registry
            )
        } catch {
            return rollbackTCP(
                .sessionCreation,
                components: components,
                rust: rust,
                resourceLease: resourceLease
            )
        }

        do {
            try registry.insert(session)
        } catch {
            failureObserver(.registryInsertion)
            session.cancel()
            return TransparentProxyIngressClaimResult(
                failurePoint: .registryInsertion
            )
        }

        do {
            try session.start()
        } catch {
            failureObserver(.sessionStart)
            session.cancel()
            return TransparentProxyIngressClaimResult(
                failurePoint: .sessionStart
            )
        }
        return TransparentProxyIngressClaimResult(sessionID: sessionID)
    }

    /// Claims and actively rejects an unverified/malformed-identity TCP flow.
    /// A provider must reserve `false` exclusively for a positively verified
    /// self-egress bypass and use this path for every fail-closed decision.
    @discardableResult
    public func rejectTCP(
        components: TransparentTCPIngressComponents
    ) -> TransparentProxyIngressClaimResult {
        let failurePoint: TransparentProxyIngressFailurePoint =
            components.hasMatchingFlowIdentity
                ? .identityRejection
                : .componentBinding
        return rollbackTCP(
            failurePoint,
            components: components,
            rust: nil,
            resourceLease: nil
        )
    }

    @discardableResult
    public func claimUDP(
        components: TransparentUDPIngressComponents,
        localSource: FlowEndpoint?,
        policy: UDPBatchPolicy = .strict,
        createRust: UDPRustFactory
    ) -> TransparentProxyIngressClaimResult {
        guard components.hasMatchingFlowIdentity else {
            return rollbackUDP(
                .componentBinding,
                components: components,
                rust: nil,
                resourceLease: nil,
                sourceLease: nil
            )
        }

        let resourceLease: FlowResourceLease
        do {
            resourceLease = try resourceBudget.lease(for: .udp)
        } catch {
            return rollbackUDP(
                .resourceAdmission,
                components: components,
                rust: nil,
                resourceLease: nil,
                sourceLease: nil
            )
        }

        let source: FlowEndpoint
        let sourceLease: SyntheticSourceEndpointLease?
        do {
            if let localSource {
                let validated = try localSource.validated()
                guard validated.transport == .udp else {
                    throw IngressSourceError.invalidEndpoint
                }
                switch validated.host {
                case .ipv4, .ipv6:
                    break
                case .name:
                    throw IngressSourceError.invalidEndpoint
                }
                source = validated
                sourceLease = nil
            } else {
                let lease = try sourceEndpointPool.leaseUDP()
                source = lease.endpoint
                sourceLease = lease
            }
        } catch {
            return rollbackUDP(
                .sourceEndpointAdmission,
                components: components,
                rust: nil,
                resourceLease: resourceLease,
                sourceLease: nil
            )
        }

        let rust: any RustUDPFlowBridge
        do {
            rust = try createRust(source)
        } catch {
            return rollbackUDP(
                .rustStagedCreation,
                components: components,
                rust: nil,
                resourceLease: resourceLease,
                sourceLease: sourceLease
            )
        }

        let sessionID = UUID()
        let session: any TransparentProxyIngressSession
        do {
            session = try sessionFactory.makeUDP(
                sessionID,
                components,
                rust,
                resourceLease,
                registry,
                sourceLease,
                policy
            )
        } catch {
            return rollbackUDP(
                .sessionCreation,
                components: components,
                rust: rust,
                resourceLease: resourceLease,
                sourceLease: sourceLease
            )
        }

        do {
            try registry.insert(session)
        } catch {
            failureObserver(.registryInsertion)
            session.cancel()
            return TransparentProxyIngressClaimResult(
                failurePoint: .registryInsertion
            )
        }

        do {
            try session.start()
        } catch {
            failureObserver(.sessionStart)
            session.cancel()
            return TransparentProxyIngressClaimResult(
                failurePoint: .sessionStart
            )
        }
        return TransparentProxyIngressClaimResult(sessionID: sessionID)
    }

    /// UDP equivalent of `rejectTCP(components:)`.
    @discardableResult
    public func rejectUDP(
        components: TransparentUDPIngressComponents
    ) -> TransparentProxyIngressClaimResult {
        let failurePoint: TransparentProxyIngressFailurePoint =
            components.hasMatchingFlowIdentity
                ? .identityRejection
                : .componentBinding
        return rollbackUDP(
            failurePoint,
            components: components,
            rust: nil,
            resourceLease: nil,
            sourceLease: nil
        )
    }

    private func rollbackTCP(
        _ failurePoint: TransparentProxyIngressFailurePoint,
        components: TransparentTCPIngressComponents,
        rust: (any RustTCPFlowBridge)?,
        resourceLease: FlowResourceLease?
    ) -> TransparentProxyIngressClaimResult {
        failureObserver(failurePoint)
        let rustCleanup: TransparentProxyIngressRollback.CancelRustAndDestroy?
        if let rust {
            rustCleanup = { completion in
                rust.cancel()
                rust.destroy(completion: completion)
            }
        } else {
            rustCleanup = nil
        }
        let rollback = TransparentProxyIngressRollback(
            openApple: { completion in
                components.opening.open(completion: completion)
            },
            cancelAppleAndDrain: { completion in
                components.flow.cancelAndDrain(completion: completion)
            },
            cancelRustAndDestroy: rustCleanup,
            resourceLease: resourceLease,
            sourceLease: nil
        )
        rollback.start()
        return TransparentProxyIngressClaimResult(failurePoint: failurePoint)
    }

    private func rollbackUDP(
        _ failurePoint: TransparentProxyIngressFailurePoint,
        components: TransparentUDPIngressComponents,
        rust: (any RustUDPFlowBridge)?,
        resourceLease: FlowResourceLease?,
        sourceLease: SyntheticSourceEndpointLease?
    ) -> TransparentProxyIngressClaimResult {
        failureObserver(failurePoint)
        let rustCleanup: TransparentProxyIngressRollback.CancelRustAndDestroy?
        if let rust {
            rustCleanup = { completion in
                rust.cancel()
                rust.destroy(completion: completion)
            }
        } else {
            rustCleanup = nil
        }
        let rollback = TransparentProxyIngressRollback(
            openApple: { completion in
                components.opening.open(completion: completion)
            },
            cancelAppleAndDrain: { completion in
                components.flow.cancelAndDrain(completion: completion)
            },
            cancelRustAndDestroy: rustCleanup,
            resourceLease: resourceLease,
            sourceLease: sourceLease
        )
        rollback.start()
        return TransparentProxyIngressClaimResult(failurePoint: failurePoint)
    }

    private enum IngressSourceError: Error {
        case invalidEndpoint
    }
}

/// Retains rollback resources until all three asynchronous ownership
/// boundaries have acknowledged shutdown. Release methods are idempotent, but
/// this class deliberately invokes them only once after the joint barrier.
private final class TransparentProxyIngressRollback: @unchecked Sendable {
    typealias OpenApple = @Sendable (
        @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) -> Void
    typealias CancelAppleAndDrain = @Sendable (
        @escaping @Sendable () -> Void
    ) -> Void
    typealias CancelRustAndDestroy = @Sendable (
        @escaping @Sendable () -> Void
    ) -> Void

    private let openApple: OpenApple
    private let cancelAppleAndDrain: CancelAppleAndDrain
    private let cancelRustAndDestroy: CancelRustAndDestroy?
    private let lock = NSLock()
    private var resourceLease: FlowResourceLease?
    private var sourceLease: SyntheticSourceEndpointLease?
    private var openFinished = false
    private var appleDrainStarted = false
    private var appleFinished = false
    private var rustFinished = false
    private var released = false

    init(
        openApple: @escaping OpenApple,
        cancelAppleAndDrain: @escaping CancelAppleAndDrain,
        cancelRustAndDestroy: CancelRustAndDestroy?,
        resourceLease: FlowResourceLease?,
        sourceLease: SyntheticSourceEndpointLease?
    ) {
        self.openApple = openApple
        self.cancelAppleAndDrain = cancelAppleAndDrain
        self.cancelRustAndDestroy = cancelRustAndDestroy
        self.resourceLease = resourceLease
        self.sourceLease = sourceLease
    }

    func start() {
        // Issue open first. Even a failed open callback is an ordering barrier
        // before close; returning `true` without this sequence can leave an
        // unopened flow eligible for unintended system bypass behavior.
        openApple { [self] _ in
            openCompleted()
        }
        if let cancelRustAndDestroy {
            cancelRustAndDestroy { [self] in
                finishRust()
            }
        } else {
            finishRust()
        }
    }

    private func openCompleted() {
        let shouldDrain = lock.withLock { () -> Bool in
            guard !openFinished else { return false }
            openFinished = true
            guard !appleDrainStarted else { return false }
            appleDrainStarted = true
            return true
        }
        guard shouldDrain else { return }
        cancelAppleAndDrain { [self] in
            finishApple()
        }
    }

    private func finishApple() {
        let resources = lock.withLock { () -> ReleasedResources? in
            appleFinished = true
            return takeResourcesIfFinishedLocked()
        }
        resources?.release()
    }

    private func finishRust() {
        let resources = lock.withLock { () -> ReleasedResources? in
            rustFinished = true
            return takeResourcesIfFinishedLocked()
        }
        resources?.release()
    }

    private func takeResourcesIfFinishedLocked() -> ReleasedResources? {
        guard
            openFinished,
            appleFinished,
            rustFinished,
            !released
        else { return nil }
        released = true
        defer { resourceLease = nil }
        defer { sourceLease = nil }
        return ReleasedResources(
            resourceLease: resourceLease,
            sourceLease: sourceLease
        )
    }

    private struct ReleasedResources {
        let resourceLease: FlowResourceLease?
        let sourceLease: SyntheticSourceEndpointLease?

        func release() {
            sourceLease?.release()
            resourceLease?.release()
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

import AetherRouteKit
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxyIngressCoordinatorTests:
    XCTestCase,
    @unchecked Sendable
{
    func testCrossFlowComponentsAreClaimedClosedBeforeAdmission() throws {
        let flow = IngressTCPFlow()
        let components = TransparentTCPIngressComponents(
            opening: IngressFlowOpening(automaticallyOpens: true),
            flow: flow,
            openingIdentity: TransparentProxyAppleFlowIdentity(),
            flowIdentity: TransparentProxyAppleFlowIdentity()
        )
        let context = try makeContext(maximumBytes: 1)
        let rustCreationCount = LockedValue(0)

        let result = context.coordinator.claimTCP(
            components: components
        ) {
            rustCreationCount.mutate { $0 += 1 }
            return IngressRustTCPFlow()
        }

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .componentBinding)
        XCTAssertNil(result.sessionID)
        XCTAssertEqual(rustCreationCount.value, 0)
        XCTAssertEqual(flow.cancelCount, 1)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 0)
    }

    func testAdmissionFailureStillClaimsAndClosesFlow() throws {
        let flow = IngressTCPFlow()
        let context = try makeContext(maximumBytes: 1)

        let result = context.coordinator.claimTCP(
            components: tcpComponents(flow: flow)
        ) {
            XCTFail("Rust must not be created without an admission lease")
            return IngressRustTCPFlow()
        }

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .resourceAdmission)
        XCTAssertEqual(flow.cancelCount, 1)
        XCTAssertEqual(context.registry.snapshot().activeSessionCount, 0)
    }

    func testRustCreationFailureHoldsLeaseUntilAppleDrain() throws {
        let opening = IngressFlowOpening()
        let flow = IngressTCPFlow(automaticallyDrains: false)
        let context = try makeContext(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes
        )

        let result = context.coordinator.claimTCP(
            components: tcpComponents(opening: opening, flow: flow)
        ) {
            throw IngressTestError.injected
        }

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .rustStagedCreation)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        XCTAssertEqual(opening.openCount, 1)
        XCTAssertEqual(flow.cancelCount, 0)

        // A failed open callback is still the required ordering barrier before
        // claim-and-close; the admission lease remains held throughout.
        opening.complete(.failure(.closed))
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        XCTAssertEqual(flow.cancelCount, 1)

        flow.completeDrain()
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 0)
    }

    func testSessionCreationFailureWaitsForJointDestroyBarrier() throws {
        let flow = IngressTCPFlow(automaticallyDrains: false)
        let rust = IngressRustTCPFlow(automaticallyDestroys: false)
        let live = TransparentProxyIngressSessionFactory.live
        let factory = TransparentProxyIngressSessionFactory(
            makeTCP: { _, _, _, _, _ in
                throw IngressTestError.injected
            },
            makeUDP: live.makeUDP
        )
        let context = try makeContext(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes,
            sessionFactory: factory
        )

        let result = context.coordinator.claimTCP(
            components: tcpComponents(flow: flow),
            createRust: { rust }
        )

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .sessionCreation)
        XCTAssertEqual(flow.cancelCount, 1)
        XCTAssertEqual(rust.cancelCount, 1)
        XCTAssertEqual(rust.destroyCount, 1)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)

        flow.completeDrain()
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        rust.completeDestroy()
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 0)
    }

    func testRegistryInsertFailureCancelsOwnedSessionAndWaitsForBarriers() throws {
        let opening = IngressFlowOpening()
        let flow = IngressTCPFlow(automaticallyDrains: false)
        let rust = IngressRustTCPFlow(automaticallyDestroys: false)
        let registry = try TransparentProxySessionRegistry()
        registry.stopAll {}
        let weakSession = WeakIngressSessionBox()
        let live = TransparentProxyIngressSessionFactory.live
        let factory = TransparentProxyIngressSessionFactory(
            makeTCP: { sessionID, components, rust, lease, registry in
                let session = try live.makeTCP(
                    sessionID,
                    components,
                    rust,
                    lease,
                    registry
                )
                weakSession.value = session
                return session
            },
            makeUDP: live.makeUDP
        )
        let context = try makeContext(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes,
            registry: registry,
            sessionFactory: factory
        )

        let result = context.coordinator.claimTCP(
            components: tcpComponents(opening: opening, flow: flow),
            createRust: { rust }
        )

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .registryInsertion)
        waitUntil { rust.destroyCount == 1 }
        XCTAssertEqual(opening.openCount, 1)
        XCTAssertEqual(flow.cancelCount, 0)
        XCTAssertEqual(rust.cancelCount, 1)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        XCTAssertNotNil(weakSession.value)

        rust.completeDestroy()
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        XCTAssertNotNil(weakSession.value)
        opening.complete(.success(()))
        waitUntil { flow.cancelCount == 1 }
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        XCTAssertNotNil(weakSession.value)
        flow.completeDrain()
        waitUntil { context.budget.snapshot().activeLeaseCount == 0 }
        waitUntil { weakSession.value == nil }
        XCTAssertEqual(registry.snapshot().activeSessionCount, 0)
    }

    func testStartFailureAfterInsertClaimsAndCancelsRegisteredSession() throws {
        let opening = IngressFlowOpening()
        let flow = IngressTCPFlow(automaticallyDrains: false)
        let rust = IngressRustTCPFlow(automaticallyDestroys: false)
        let live = TransparentProxyIngressSessionFactory.live
        let registry = try TransparentProxySessionRegistry()
        let factory = TransparentProxyIngressSessionFactory(
            makeTCP: { sessionID, components, rust, lease, registry in
                let base = try live.makeTCP(
                    sessionID,
                    components,
                    rust,
                    lease,
                    registry
                )
                return StartFailingIngressSession(base: base)
            },
            makeUDP: live.makeUDP
        )
        let context = try makeContext(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes,
            registry: registry,
            sessionFactory: factory
        )

        let result = context.coordinator.claimTCP(
            components: tcpComponents(opening: opening, flow: flow),
            createRust: { rust }
        )

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .sessionStart)
        XCTAssertEqual(registry.snapshot().activeSessionCount, 1)
        waitUntil { rust.destroyCount == 1 }
        XCTAssertEqual(opening.openCount, 1)
        XCTAssertEqual(flow.cancelCount, 0)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)

        opening.complete(.success(()))
        waitUntil { flow.cancelCount == 1 }
        flow.completeDrain()
        rust.completeDestroy()
        waitUntil { registry.snapshot().activeSessionCount == 0 }
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 0)
    }

    func testSuccessfulTransactionUsesFixedOrdering() throws {
        let events = LockedValue<[String]>([])
        let admissionSeenByRust = LockedValue(false)
        let registryCountSeenByStart = LockedValue(-1)
        let opening = IngressFlowOpening(automaticallyOpens: true)
        let flow = IngressTCPFlow()
        let rust = IngressRustTCPFlow()
        let registry = try TransparentProxySessionRegistry()
        let budget = try FlowResourceBudget(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes
        )
        let live = TransparentProxyIngressSessionFactory.live
        let factory = TransparentProxyIngressSessionFactory(
            makeTCP: { sessionID, components, rust, lease, registry in
                events.mutate { $0.append("session") }
                let base = try live.makeTCP(
                    sessionID,
                    components,
                    rust,
                    lease,
                    registry
                )
                return StartObservingIngressSession(base: base) {
                    events.mutate { $0.append("start") }
                    registryCountSeenByStart.mutate {
                        $0 = registry.snapshot().activeSessionCount
                    }
                }
            },
            makeUDP: live.makeUDP
        )
        let coordinator = TransparentProxyIngressCoordinator(
            resourceBudget: budget,
            sourceEndpointPool: try SyntheticSourceEndpointPool(),
            registry: registry,
            sessionFactory: factory
        )

        let result = coordinator.claimTCP(
            components: tcpComponents(opening: opening, flow: flow)
        ) {
            events.mutate { $0.append("rust") }
            admissionSeenByRust.mutate {
                $0 = budget.snapshot().activeLeaseCount == 1
            }
            return rust
        }

        XCTAssertTrue(result.claimed)
        XCTAssertNil(result.failurePoint)
        XCTAssertNotNil(result.sessionID)
        XCTAssertEqual(events.value, ["rust", "session", "start"])
        XCTAssertTrue(admissionSeenByRust.value)
        XCTAssertEqual(registryCountSeenByStart.value, 1)
        waitUntil { opening.openCount == 1 && rust.activateCount == 1 }

        registry.stopAll {}
        waitUntil { registry.snapshot().activeSessionCount == 0 }
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 0)
    }

    func testUDPSourceAdmissionFailureClaimsAndClosesFlow() throws {
        let sourcePool = try SyntheticSourceEndpointPool(
            portRange: 63_500...63_500
        )
        let heldSource = try sourcePool.leaseUDP()
        let flow = IngressUDPFlow()
        let context = try makeContext(
            maximumBytes: TransparentFlowResourceKind.udp.reservationBytes,
            sourcePool: sourcePool
        )

        let result = context.coordinator.claimUDP(
            components: udpComponents(flow: flow),
            localSource: nil
        ) { _ in
            XCTFail("Rust must not be created without a source identity")
            return IngressRustUDPFlow()
        }

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .sourceEndpointAdmission)
        XCTAssertEqual(flow.cancelCount, 1)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 0)
        XCTAssertEqual(sourcePool.activeLeaseCount, 1)
        heldSource.release()
    }

    func testExplicitIdentityRejectionClaimsOpenThenClosesWithoutRust() throws {
        let opening = IngressFlowOpening()
        let flow = IngressTCPFlow(automaticallyDrains: false)
        let context = try makeContext(maximumBytes: 1)

        let result = context.coordinator.rejectTCP(
            components: tcpComponents(opening: opening, flow: flow)
        )

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .identityRejection)
        XCTAssertEqual(opening.openCount, 1)
        XCTAssertEqual(flow.cancelCount, 0)

        opening.complete(.success(()))
        XCTAssertEqual(flow.cancelCount, 1)
        flow.completeDrain()
    }

    func testUDPRollbackRetainsSyntheticAndResourceLeasesUntilAllBarriers()
        throws
    {
        let sourcePool = try SyntheticSourceEndpointPool(
            portRange: 63_600...63_600
        )
        let flow = IngressUDPFlow(automaticallyDrains: false)
        let rust = IngressRustUDPFlow(automaticallyDestroys: false)
        let live = TransparentProxyIngressSessionFactory.live
        let factory = TransparentProxyIngressSessionFactory(
            makeTCP: live.makeTCP,
            makeUDP: { _, _, _, _, _, _, _ in
                throw IngressTestError.injected
            }
        )
        let context = try makeContext(
            maximumBytes: TransparentFlowResourceKind.udp.reservationBytes,
            sourcePool: sourcePool,
            sessionFactory: factory
        )

        let result = context.coordinator.claimUDP(
            components: udpComponents(flow: flow),
            localSource: nil,
            createRust: { _ in rust }
        )

        XCTAssertTrue(result.claimed)
        XCTAssertEqual(result.failurePoint, .sessionCreation)
        XCTAssertEqual(sourcePool.activeLeaseCount, 1)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        XCTAssertEqual(rust.cancelCount, 1)
        XCTAssertEqual(rust.destroyCount, 1)

        rust.completeDestroy()
        XCTAssertEqual(sourcePool.activeLeaseCount, 1)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 1)
        flow.completeDrain()
        XCTAssertEqual(sourcePool.activeLeaseCount, 0)
        XCTAssertEqual(context.budget.snapshot().activeLeaseCount, 0)
    }

    private func makeContext(
        maximumBytes: Int,
        sourcePool: SyntheticSourceEndpointPool? = nil,
        registry: TransparentProxySessionRegistry? = nil,
        sessionFactory: TransparentProxyIngressSessionFactory = .live
    ) throws -> IngressTestContext {
        let budget = try FlowResourceBudget(maximumBytes: maximumBytes)
        let resolvedRegistry = try registry ?? TransparentProxySessionRegistry()
        let coordinator = TransparentProxyIngressCoordinator(
            resourceBudget: budget,
            sourceEndpointPool: try sourcePool ?? SyntheticSourceEndpointPool(),
            registry: resolvedRegistry,
            sessionFactory: sessionFactory
        )
        return IngressTestContext(
            coordinator: coordinator,
            budget: budget,
            registry: resolvedRegistry
        )
    }

    private func tcpComponents(
        opening: IngressFlowOpening = IngressFlowOpening(
            automaticallyOpens: true
        ),
        flow: IngressTCPFlow
    ) -> TransparentTCPIngressComponents {
        let identity = TransparentProxyAppleFlowIdentity()
        return TransparentTCPIngressComponents(
            opening: opening,
            flow: flow,
            openingIdentity: identity,
            flowIdentity: identity
        )
    }

    private func udpComponents(
        opening: IngressFlowOpening = IngressFlowOpening(
            automaticallyOpens: true
        ),
        flow: IngressUDPFlow
    ) -> TransparentUDPIngressComponents {
        let identity = TransparentProxyAppleFlowIdentity()
        return TransparentUDPIngressComponents(
            opening: opening,
            flow: flow,
            openingIdentity: identity,
            flowIdentity: identity
        )
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        _ predicate: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate(), Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.001))
        }
        XCTAssertTrue(predicate())
    }
}

private struct IngressTestContext {
    let coordinator: TransparentProxyIngressCoordinator
    let budget: FlowResourceBudget
    let registry: TransparentProxySessionRegistry
}

private enum IngressTestError: Error {
    case injected
}

private final class IngressFlowOpening:
    AppleProxyFlowOpening,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let automaticallyOpens: Bool
    private var opens = 0
    private var completions: [
        @Sendable (Result<Void, FlowIOError>) -> Void
    ] = []

    init(automaticallyOpens: Bool = false) {
        self.automaticallyOpens = automaticallyOpens
    }

    var openCount: Int { lock.withLock { opens } }

    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        let completeNow = lock.withLock { () -> Bool in
            opens += 1
            guard automaticallyOpens else {
                completions.append(completion)
                return false
            }
            return true
        }
        if completeNow { completion(.success(())) }
    }

    func complete(_ result: Result<Void, FlowIOError>) {
        let completion = lock.withLock { completions.removeFirst() }
        completion(result)
    }
}

private final class IngressTCPFlow:
    TransparentTCPFlowIO,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let automaticallyDrains: Bool
    private var cancellations = 0
    private var drainCompletions: [@Sendable () -> Void] = []
    private var drained = false

    init(automaticallyDrains: Bool = true) {
        self.automaticallyDrains = automaticallyDrains
    }

    var cancelCount: Int { lock.withLock { cancellations } }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {}

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {}

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {}

    func cancel() {
        lock.withLock {
            guard cancellations == 0 else { return }
            cancellations = 1
        }
    }

    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        cancel()
        let completeNow = lock.withLock { () -> Bool in
            if automaticallyDrains || drained { return true }
            drainCompletions.append(completion)
            return false
        }
        if completeNow { completion() }
    }

    func completeDrain() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            drained = true
            defer { drainCompletions.removeAll(keepingCapacity: false) }
            return drainCompletions
        }
        completions.forEach { $0() }
    }
}

private final class IngressUDPFlow:
    TransparentUDPFlowIO,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let automaticallyDrains: Bool
    private var cancellations = 0
    private var drainCompletions: [@Sendable () -> Void] = []
    private var drained = false

    init(automaticallyDrains: Bool = true) {
        self.automaticallyDrains = automaticallyDrains
    }

    var cancelCount: Int { lock.withLock { cancellations } }

    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {}

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {}

    func cancel() {
        lock.withLock {
            guard cancellations == 0 else { return }
            cancellations = 1
        }
    }

    func cancelAndDrain(completion: @escaping @Sendable () -> Void) {
        cancel()
        let completeNow = lock.withLock { () -> Bool in
            if automaticallyDrains || drained { return true }
            drainCompletions.append(completion)
            return false
        }
        if completeNow { completion() }
    }

    func completeDrain() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            drained = true
            defer { drainCompletions.removeAll(keepingCapacity: false) }
            return drainCompletions
        }
        completions.forEach { $0() }
    }
}

private final class IngressRustTCPFlow:
    RustTCPFlowBridge,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let automaticallyDestroys: Bool
    private var activations = 0
    private var cancellations = 0
    private var destructions = 0
    private var destroyCompletions: [@Sendable () -> Void] = []

    init(automaticallyDestroys: Bool = true) {
        self.automaticallyDestroys = automaticallyDestroys
    }

    var activateCount: Int { lock.withLock { activations } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var destroyCount: Int { lock.withLock { destructions } }

    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        lock.withLock { activations += 1 }
        completion(.success(()))
    }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {}

    func write(
        _ data: Data,
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {}

    func finishWriting(
        token: FlowOperationToken,
        completion: @escaping TCPWriteCompletion
    ) {}

    func cancel() {
        lock.withLock {
            guard cancellations == 0 else { return }
            cancellations = 1
        }
    }

    func destroy(completion: @escaping @Sendable () -> Void) {
        let completeNow = lock.withLock { () -> Bool in
            guard destructions == 0 else {
                destroyCompletions.append(completion)
                return false
            }
            destructions = 1
            if automaticallyDestroys { return true }
            destroyCompletions.append(completion)
            return false
        }
        if completeNow { completion() }
    }

    func completeDestroy() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            defer { destroyCompletions.removeAll(keepingCapacity: false) }
            return destroyCompletions
        }
        completions.forEach { $0() }
    }
}

private final class IngressRustUDPFlow:
    RustUDPFlowBridge,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let automaticallyDestroys: Bool
    private var cancellations = 0
    private var destructions = 0
    private var destroyCompletions: [@Sendable () -> Void] = []

    init(automaticallyDestroys: Bool = true) {
        self.automaticallyDestroys = automaticallyDestroys
    }

    var cancelCount: Int { lock.withLock { cancellations } }
    var destroyCount: Int { lock.withLock { destructions } }

    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        completion(.success(()))
    }

    func readDatagrams(
        maximumDatagrams: Int,
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping UDPReadCompletion
    ) {}

    func writeDatagrams(
        _ datagrams: [UDPDatagram],
        token: FlowOperationToken,
        completion: @escaping UDPWriteCompletion
    ) {}

    func cancel() {
        lock.withLock {
            guard cancellations == 0 else { return }
            cancellations = 1
        }
    }

    func destroy(completion: @escaping @Sendable () -> Void) {
        let completeNow = lock.withLock { () -> Bool in
            guard destructions == 0 else {
                destroyCompletions.append(completion)
                return false
            }
            destructions = 1
            if automaticallyDestroys { return true }
            destroyCompletions.append(completion)
            return false
        }
        if completeNow { completion() }
    }

    func completeDestroy() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            defer { destroyCompletions.removeAll(keepingCapacity: false) }
            return destroyCompletions
        }
        completions.forEach { $0() }
    }
}

private final class StartFailingIngressSession:
    TransparentProxyIngressSession,
    @unchecked Sendable
{
    private let base: any TransparentProxyIngressSession

    init(base: any TransparentProxyIngressSession) {
        self.base = base
    }

    var sessionID: UUID { base.sessionID }
    func start() throws { throw IngressTestError.injected }
    func cancel() { base.cancel() }
}

private final class StartObservingIngressSession:
    TransparentProxyIngressSession,
    @unchecked Sendable
{
    private let base: any TransparentProxyIngressSession
    private let onStart: @Sendable () -> Void

    init(
        base: any TransparentProxyIngressSession,
        onStart: @escaping @Sendable () -> Void
    ) {
        self.base = base
        self.onStart = onStart
    }

    var sessionID: UUID { base.sessionID }

    func start() throws {
        onStart()
        try base.start()
    }

    func cancel() { base.cancel() }
}

private final class WeakIngressSessionBox: @unchecked Sendable {
    weak var value: (any TransparentProxyIngressSession)?
}

private final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Value

    init(_ value: Value) {
        storage = value
    }

    var value: Value { lock.withLock { storage } }

    func mutate(_ operation: (inout Value) -> Void) {
        lock.withLock { operation(&storage) }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

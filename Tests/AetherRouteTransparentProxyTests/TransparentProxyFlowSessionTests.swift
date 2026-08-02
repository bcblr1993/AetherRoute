import AetherRouteKit
import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxyFlowSessionTests:
    XCTestCase,
    @unchecked Sendable
{
    func testTCPActivateWaitsForAppleOpen() throws {
        let registry = try TransparentProxySessionRegistry()
        let opening = StubFlowOpening()
        let flow = StubTCPFlow()
        let rust = StubRustTCPFlow()
        let session = try TransparentTCPProxySession(
            opening: opening,
            flow: flow,
            rust: rust,
            resourceLease: try resourceLease(for: .tcp),
            registry: registry
        )
        try registry.insert(session)

        session.start()
        waitUntil { opening.openCount == 1 }
        XCTAssertEqual(opening.openCount, 1)
        XCTAssertEqual(rust.activateCount, 0)

        opening.complete(.success(()))
        waitUntil { rust.activateCount == 1 }
        XCTAssertEqual(rust.activateCount, 1)
        XCTAssertEqual(flow.readCount, 0)

        rust.completeActivation(.success(()))
        waitUntil { flow.readCount == 1 && rust.readCount == 1 }
    }

    func testCancelDuringOpenWaitsForDestroyBarrierAndNeverActivates() throws {
        let registry = try TransparentProxySessionRegistry()
        let opening = StubFlowOpening()
        let flow = StubTCPFlow(automaticallyCompletesDrain: false)
        let rust = StubRustTCPFlow()
        let budget = try FlowResourceBudget(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes
        )
        let lease = try budget.lease(for: .tcp)
        let session = try TransparentTCPProxySession(
            opening: opening,
            flow: flow,
            rust: rust,
            resourceLease: lease,
            registry: registry
        )
        try registry.insert(session)
        session.start()
        waitUntil { opening.openCount == 1 }

        let stopped = LockedFlag()
        registry.stopAll { stopped.set() }
        waitUntil { rust.destroyCount == 1 }
        XCTAssertEqual(flow.cancelCount, 0)
        XCTAssertEqual(rust.cancelCount, 1)
        XCTAssertEqual(rust.destroyCount, 1)
        XCTAssertFalse(stopped.value)
        XCTAssertEqual(registry.snapshot().activeSessionCount, 1)

        rust.completeDestroy()
        XCTAssertFalse(stopped.value)
        XCTAssertEqual(registry.snapshot().activeSessionCount, 1)

        opening.complete(.success(()))
        waitUntil { flow.cancelCount == 1 }
        XCTAssertFalse(stopped.value)
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 1)
        flow.completeDrain()
        waitUntil { stopped.value }
        XCTAssertTrue(stopped.value)
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 0)
        XCTAssertEqual(registry.snapshot().activeSessionCount, 0)
        XCTAssertEqual(rust.activateCount, 0)
    }

    func testActivationFailureDestroysBeforeRegistryRelease() throws {
        let registry = try TransparentProxySessionRegistry()
        let opening = StubFlowOpening()
        let flow = StubTCPFlow()
        let rust = StubRustTCPFlow()
        let session = try TransparentTCPProxySession(
            opening: opening,
            flow: flow,
            rust: rust,
            resourceLease: try resourceLease(for: .tcp),
            registry: registry
        )
        try registry.insert(session)
        session.start()
        waitUntil { opening.openCount == 1 }
        opening.complete(.success(()))
        waitUntil { rust.activateCount == 1 }
        rust.completeActivation(.failure(.closed))

        waitUntil { rust.destroyCount == 1 }
        XCTAssertEqual(flow.cancelCount, 1)
        XCTAssertEqual(rust.destroyCount, 1)
        XCTAssertEqual(registry.snapshot().activeSessionCount, 1)
        rust.completeDestroy()
        waitUntil { registry.snapshot().activeSessionCount == 0 }
        XCTAssertEqual(registry.snapshot().activeSessionCount, 0)
    }

    func testUDPSourceLeaseLivesThroughDestroyBarrier() throws {
        let registry = try TransparentProxySessionRegistry()
        let pool = try SyntheticSourceEndpointPool(portRange: 62_000...62_000)
        let lease = try pool.leaseUDP()
        let opening = StubFlowOpening()
        let flow = StubUDPFlow()
        let rust = StubRustUDPFlow()
        let session = try TransparentUDPProxySession(
            opening: opening,
            flow: flow,
            rust: rust,
            resourceLease: try resourceLease(for: .udp),
            registry: registry,
            sourceLease: lease
        )
        try registry.insert(session)

        registry.stopAll {}
        waitUntil { rust.destroyCount == 1 }
        XCTAssertEqual(opening.openCount, 1)
        XCTAssertEqual(flow.cancelCount, 0)
        XCTAssertEqual(pool.activeLeaseCount, 1)
        XCTAssertEqual(rust.destroyCount, 1)
        rust.completeDestroy()
        XCTAssertEqual(pool.activeLeaseCount, 1)
        opening.complete(.success(()))
        waitUntil { pool.activeLeaseCount == 0 }
        XCTAssertEqual(pool.activeLeaseCount, 0)
    }

    func testRunningCancellationDoesNotCancelSharedTransportsTwice() throws {
        let registry = try TransparentProxySessionRegistry()
        let opening = StubFlowOpening()
        let flow = StubTCPFlow()
        let rust = StubRustTCPFlow()
        let session = try TransparentTCPProxySession(
            opening: opening,
            flow: flow,
            rust: rust,
            resourceLease: try resourceLease(for: .tcp),
            registry: registry
        )
        try registry.insert(session)
        session.start()
        waitUntil { opening.openCount == 1 }
        opening.complete(.success(()))
        waitUntil { rust.activateCount == 1 }
        rust.completeActivation(.success(()))
        waitUntil { flow.readCount == 1 && rust.readCount == 1 }

        let stopped = LockedFlag()
        registry.stopAll { stopped.set() }
        waitUntil { rust.destroyCount == 1 }

        XCTAssertEqual(flow.cancelCount, 1)
        XCTAssertEqual(rust.cancelCount, 1)
        rust.completeDestroy()
        waitUntil { stopped.value }
    }

    func testSessionRejectsResourceLeaseForWrongTransport() throws {
        let registry = try TransparentProxySessionRegistry()
        XCTAssertThrowsError(
            try TransparentTCPProxySession(
                opening: StubFlowOpening(),
                flow: StubTCPFlow(),
                rust: StubRustTCPFlow(),
                resourceLease: try resourceLease(for: .udp),
                registry: registry
            )
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxyFlowSessionConfigurationError,
                .resourceLeaseKindMismatch
            )
        }

        XCTAssertThrowsError(
            try TransparentTCPProxySession(
                opening: StubFlowOpening(),
                flow: StubTCPFlow(),
                rust: StubRustTCPFlow(),
                resourceLease: try resourceLease(for: .tcp),
                registry: registry,
                maximumReadBytes:
                    TCPFlowStateMachine.defaultMaximumReadBytes + 1
            )
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxyFlowSessionConfigurationError,
                .maximumTCPReadBytesExceedsAdmissionProfile
            )
        }
    }

    func testResourceAndSyntheticLeasesCannotBeClaimedByTwoSessions() throws {
        let registry = try TransparentProxySessionRegistry()
        let tcpBudget = try FlowResourceBudget(
            maximumBytes: TransparentFlowResourceKind.tcp.reservationBytes
        )
        let sharedTCPLease = try tcpBudget.lease(for: .tcp)
        let firstTCP = try TransparentTCPProxySession(
            opening: StubFlowOpening(),
            flow: StubTCPFlow(),
            rust: StubRustTCPFlow(),
            resourceLease: sharedTCPLease,
            registry: registry
        )
        XCTAssertNotNil(firstTCP)
        XCTAssertThrowsError(
            try TransparentTCPProxySession(
                opening: StubFlowOpening(),
                flow: StubTCPFlow(),
                rust: StubRustTCPFlow(),
                resourceLease: sharedTCPLease,
                registry: registry
            )
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxyFlowSessionConfigurationError,
                .resourceLeaseUnavailable
            )
        }
        XCTAssertEqual(tcpBudget.snapshot().activeLeaseCount, 1)

        let udpBudget = try FlowResourceBudget(
            maximumBytes:
                2 * TransparentFlowResourceKind.udp.reservationBytes
        )
        let pool = try SyntheticSourceEndpointPool(
            portRange: 63_000...63_000
        )
        let sharedSource = try pool.leaseUDP()
        let firstUDP = try TransparentUDPProxySession(
            opening: StubFlowOpening(),
            flow: StubUDPFlow(),
            rust: StubRustUDPFlow(),
            resourceLease: try udpBudget.lease(for: .udp),
            registry: registry,
            sourceLease: sharedSource
        )
        XCTAssertNotNil(firstUDP)
        XCTAssertThrowsError(
            try TransparentUDPProxySession(
                opening: StubFlowOpening(),
                flow: StubUDPFlow(),
                rust: StubRustUDPFlow(),
                resourceLease: try udpBudget.lease(for: .udp),
                registry: registry,
                sourceLease: sharedSource
            )
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxyFlowSessionConfigurationError,
                .sourceEndpointLeaseUnavailable
            )
        }
        XCTAssertEqual(pool.activeLeaseCount, 1)
        XCTAssertEqual(udpBudget.snapshot().activeLeaseCount, 1)
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

    private func resourceLease(
        for kind: TransparentFlowResourceKind
    ) throws -> FlowResourceLease {
        let budget = try FlowResourceBudget(
            maximumBytes: kind.reservationBytes
        )
        return try budget.lease(for: kind)
    }
}

private final class StubFlowOpening: AppleProxyFlowOpening, @unchecked Sendable {
    private let lock = NSLock()
    private var completions: [@Sendable (Result<Void, FlowIOError>) -> Void] = []
    private var opens = 0

    var openCount: Int { lock.withLock { opens } }

    func open(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        lock.withLock {
            opens += 1
            completions.append(completion)
        }
    }

    func complete(_ result: Result<Void, FlowIOError>) {
        let completion = lock.withLock { completions.removeFirst() }
        completion(result)
    }
}

private final class StubTCPFlow: TransparentTCPFlowIO, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var cancellations = 0
    private var drainCompletions: [@Sendable () -> Void] = []
    private let automaticallyCompletesDrain: Bool

    init(automaticallyCompletesDrain: Bool = true) {
        self.automaticallyCompletesDrain = automaticallyCompletesDrain
    }

    var readCount: Int { lock.withLock { reads } }
    var cancelCount: Int { lock.withLock { cancellations } }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        lock.withLock { reads += 1 }
    }

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
            guard !automaticallyCompletesDrain else { return true }
            drainCompletions.append(completion)
            return false
        }
        if completeNow { completion() }
    }

    func completeDrain() {
        let completions = lock.withLock { () -> [@Sendable () -> Void] in
            defer { drainCompletions.removeAll(keepingCapacity: false) }
            return drainCompletions
        }
        completions.forEach { $0() }
    }
}

private final class StubRustTCPFlow: RustTCPFlowBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var activationCompletions: [
        @Sendable (Result<Void, FlowIOError>) -> Void
    ] = []
    private var destroyCompletions: [@Sendable () -> Void] = []
    private var activations = 0
    private var reads = 0
    private var cancellations = 0
    private var destroys = 0

    var activateCount: Int { lock.withLock { activations } }
    var readCount: Int { lock.withLock { reads } }
    var cancelCount: Int { lock.withLock { cancellations } }
    var destroyCount: Int { lock.withLock { destroys } }

    func activate(
        completion: @escaping @Sendable (Result<Void, FlowIOError>) -> Void
    ) {
        lock.withLock {
            activations += 1
            activationCompletions.append(completion)
        }
    }

    func completeActivation(_ result: Result<Void, FlowIOError>) {
        let completion = lock.withLock { activationCompletions.removeFirst() }
        completion(result)
    }

    func read(
        maximumBytes: Int,
        token: FlowOperationToken,
        completion: @escaping TCPReadCompletion
    ) {
        lock.withLock { reads += 1 }
    }

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
        lock.withLock {
            destroys += 1
            destroyCompletions.append(completion)
        }
    }

    func completeDestroy() {
        let completion = lock.withLock { destroyCompletions.removeFirst() }
        completion()
    }
}

private final class StubUDPFlow: TransparentUDPFlowIO, @unchecked Sendable {
    private let lock = NSLock()
    private var cancellations = 0

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
        completion()
    }
}

private final class StubRustUDPFlow: RustUDPFlowBridge, @unchecked Sendable {
    private let lock = NSLock()
    private var destroyCompletions: [@Sendable () -> Void] = []
    private var destroys = 0

    var destroyCount: Int { lock.withLock { destroys } }

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

    func cancel() {}

    func destroy(completion: @escaping @Sendable () -> Void) {
        lock.withLock {
            destroys += 1
            destroyCompletions.append(completion)
        }
    }

    func completeDestroy() {
        let completion = lock.withLock { destroyCompletions.removeFirst() }
        completion()
    }
}

private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool { lock.withLock { storage } }
    func set() { lock.withLock { storage = true } }
}

private extension NSLock {
    func withLock<Value>(_ body: () -> Value) -> Value {
        lock()
        defer { unlock() }
        return body()
    }
}

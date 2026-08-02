import Foundation
import XCTest
@testable import AetherRouteTransparentProxySupport

final class TransparentProxySessionRegistryTests:
    XCTestCase,
    @unchecked Sendable
{
    func testCapacityAndDuplicateIdentifiersFailClosed() throws {
        let registry = try TransparentProxySessionRegistry(
            maximumSessionCount: 2
        )
        let first = StubProxySession()
        let duplicate = StubProxySession(sessionID: first.sessionID)
        let second = StubProxySession()
        let third = StubProxySession()

        try registry.insert(first)
        XCTAssertThrowsError(try registry.insert(duplicate)) { error in
            XCTAssertEqual(
                error as? TransparentProxySessionRegistryError,
                .duplicateSessionIdentifier
            )
        }
        try registry.insert(second)
        XCTAssertThrowsError(try registry.insert(third)) { error in
            XCTAssertEqual(
                error as? TransparentProxySessionRegistryError,
                .capacityExceeded
            )
        }
        XCTAssertEqual(registry.snapshot().activeSessionCount, 2)
    }

    func testStopCompletionWaitsForEveryDestroyAcknowledgement() throws {
        let registry = try TransparentProxySessionRegistry()
        let first = StubProxySession()
        let second = StubProxySession()
        try registry.insert(first)
        try registry.insert(second)

        let completed = LockedCounter()
        registry.stopAll { completed.increment() }
        registry.stopAll { completed.increment() }

        XCTAssertEqual(first.cancelCount, 1)
        XCTAssertEqual(second.cancelCount, 1)
        XCTAssertEqual(completed.value, 0)
        XCTAssertEqual(registry.snapshot().lifecycle, .stopping)

        registry.didTerminate(sessionID: first.sessionID)
        XCTAssertEqual(completed.value, 0)
        registry.didTerminate(sessionID: second.sessionID)
        XCTAssertEqual(completed.value, 2)
        XCTAssertEqual(registry.snapshot().lifecycle, .stopped)

        registry.didTerminate(sessionID: second.sessionID)
        registry.stopAll { completed.increment() }
        XCTAssertEqual(completed.value, 3)
    }

    func testRegistryRetainsClaimedFlowUntilTerminationBarrier() throws {
        let registry = try TransparentProxySessionRegistry()
        var session: StubProxySession? = StubProxySession()
        weak let weakSession = session
        let identifier = try XCTUnwrap(session?.sessionID)
        try registry.insert(try XCTUnwrap(session))

        session = nil
        XCTAssertNotNil(weakSession)
        registry.didTerminate(sessionID: identifier)
        XCTAssertNil(weakSession)
    }

    func testInsertAfterStopIsRejected() throws {
        let registry = try TransparentProxySessionRegistry()
        registry.stopAll {}
        XCTAssertThrowsError(try registry.insert(StubProxySession())) { error in
            XCTAssertEqual(
                error as? TransparentProxySessionRegistryError,
                .notAccepting
            )
        }
    }

    func testSessionDeinitMayReenterRegistryWithoutLockInversion() throws {
        let registry = try TransparentProxySessionRegistry()
        let deinitCount = LockedCounter()
        var session: ReentrantDeinitSession? = ReentrantDeinitSession {
            _ = registry.snapshot()
            deinitCount.increment()
        }
        weak let weakSession = session
        let identifier = try XCTUnwrap(session?.sessionID)
        try registry.insert(try XCTUnwrap(session))
        session = nil

        registry.didTerminate(sessionID: identifier)

        XCTAssertNil(weakSession)
        XCTAssertEqual(deinitCount.value, 1)
    }

    func testInvalidCapacityIsRejected() {
        XCTAssertThrowsError(
            try TransparentProxySessionRegistry(maximumSessionCount: 0)
        ) { error in
            XCTAssertEqual(
                error as? TransparentProxySessionRegistryError,
                .invalidCapacity
            )
        }
    }
}

private final class ReentrantDeinitSession:
    TransparentProxySessionLifetime,
    @unchecked Sendable
{
    let sessionID = UUID()
    private let onDeinit: @Sendable () -> Void

    init(onDeinit: @escaping @Sendable () -> Void) {
        self.onDeinit = onDeinit
    }

    func cancel() {}

    deinit {
        onDeinit()
    }
}

private final class StubProxySession:
    TransparentProxySessionLifetime,
    @unchecked Sendable
{
    let sessionID: UUID
    private let lock = NSLock()
    private var cancellations = 0

    init(sessionID: UUID = UUID()) {
        self.sessionID = sessionID
    }

    var cancelCount: Int {
        lock.withLock { cancellations }
    }

    func cancel() {
        lock.withLock {
            cancellations += 1
        }
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
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

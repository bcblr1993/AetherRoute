import XCTest
@testable import AetherRouteTransparentProxySupport

final class FlowResourceBudgetTests: XCTestCase, @unchecked Sendable {
    /// The default budget once admitted only 25 concurrent UDP flows, which a
    /// single QUIC page load exhausts, silently dropping user traffic while the
    /// session registry still advertised 4,096 sessions. Lock in a floor so the
    /// per-flow charges cannot drift back into starving ordinary browsing.
    func testDefaultBudgetAdmitsRealisticConcurrency() throws {
        let budget = try FlowResourceBudget()

        var udpLeases: [FlowResourceLease] = []
        for _ in 0..<512 {
            udpLeases.append(try budget.lease(for: .udp))
        }
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 512)

        udpLeases.removeAll()
        XCTAssertEqual(budget.snapshot().reservedBytes, 0)

        var tcpLeases: [FlowResourceLease] = []
        for _ in 0..<1_024 {
            tcpLeases.append(try budget.lease(for: .tcp))
        }
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 1_024)
    }

    /// The registry limit, not the byte backstop, must be what bounds ordinary
    /// traffic. A mixed working set well inside the registry cap has to fit.
    func testMixedWorkingSetFitsWithinDefaultBudget() throws {
        let budget = try FlowResourceBudget()
        var leases: [FlowResourceLease] = []

        for _ in 0..<400 {
            leases.append(try budget.lease(for: .tcp))
            leases.append(try budget.lease(for: .udp))
        }

        XCTAssertEqual(budget.snapshot().activeLeaseCount, 800)
        XCTAssertLessThanOrEqual(
            budget.snapshot().reservedBytes,
            FlowResourceBudget.defaultMaximumBytes
        )
    }

    func testWeightedAdmissionFailsClosedAndLeaseReleaseIsIdempotent() throws {
        let maximum = TransparentFlowResourceKind.udp.reservationBytes
        let budget = try FlowResourceBudget(maximumBytes: maximum)
        let lease = try budget.lease(for: .udp)

        XCTAssertEqual(
            budget.snapshot(),
            FlowResourceBudgetSnapshot(
                maximumBytes: maximum,
                reservedBytes: maximum,
                activeLeaseCount: 1
            )
        )
        XCTAssertThrowsError(try budget.lease(for: .tcp)) { error in
            XCTAssertEqual(error as? FlowResourceBudgetError, .exhausted)
        }

        lease.release()
        lease.release()
        XCTAssertEqual(budget.snapshot().reservedBytes, 0)
        XCTAssertEqual(budget.snapshot().activeLeaseCount, 0)
    }

    func testInvalidBudgetIsRejected() {
        XCTAssertThrowsError(try FlowResourceBudget(maximumBytes: 0)) { error in
            XCTAssertEqual(
                error as? FlowResourceBudgetError,
                .invalidMaximumBytes
            )
        }
    }
}

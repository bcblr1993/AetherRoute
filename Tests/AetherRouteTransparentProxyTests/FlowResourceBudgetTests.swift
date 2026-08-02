import XCTest
@testable import AetherRouteTransparentProxySupport

final class FlowResourceBudgetTests: XCTestCase, @unchecked Sendable {
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

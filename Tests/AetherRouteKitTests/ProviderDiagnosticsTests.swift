@testable import AetherRouteKit
import Dispatch
import XCTest

final class ProviderDiagnosticsTests: XCTestCase, @unchecked Sendable {
    func testAccumulatorCountsFixedCategoriesConcurrently() {
        let accumulator = ProviderDiagnosticAccumulator()
        DispatchQueue.concurrentPerform(iterations: 1_000) { index in
            accumulator.record(.flowAdmissionFailure)
            if index.isMultiple(of: 2) {
                accumulator.record(.networkSettingsFailure)
            }
        }
        accumulator.record(.invalidRequest)
        accumulator.record(.unavailable)
        accumulator.record(.rejected)
        accumulator.record(.responseTooLarge)
        accumulator.record(.internalFailure)

        XCTAssertEqual(
            accumulator.snapshot(),
            ProviderDiagnosticSnapshot(
                networkSettingsFailureCount: 500,
                invalidControlRequestCount: 1,
                unavailableControlRequestCount: 1,
                rejectedControlRequestCount: 1,
                oversizedControlResponseCount: 1,
                internalControlFailureCount: 1,
                flowAdmissionFailureCount: 1_000
            )
        )
    }

    func testSnapshotJSONContainsOnlyFixedNumericFields() throws {
        let snapshot = ProviderDiagnosticSnapshot(
            startupFailureCount: 1,
            internalControlFailureCount: 2
        )
        let data = try JSONEncoder().encode(snapshot)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(object.count, 8)
        XCTAssertTrue(object.values.allSatisfy { $0 is NSNumber })
    }
}

import AetherRouteKit
import XCTest

final class UpdateAvailabilityTests: XCTestCase {
    func testCheckThenFindUpdate() {
        let state = UpdateAvailability.unknown
            .applying(.checkStarted)
            .applying(.foundUpdate(version: "1.0.37"))
        XCTAssertEqual(state, .available(version: "1.0.37"))
        XCTAssertEqual(state.availableVersion, "1.0.37")
    }

    func testKnownUpdateStaysVisibleDuringRecheck() {
        let state = UpdateAvailability.available(version: "1.0.37").applying(.checkStarted)
        XCTAssertEqual(state, .available(version: "1.0.37"))
    }

    func testNoUpdateClearsBadge() {
        XCTAssertEqual(UpdateAvailability.available(version: "1.0.37").applying(.noUpdateFound), .upToDate)
        XCTAssertEqual(UpdateAvailability.checking.applying(.noUpdateFound), .upToDate)
    }

    func testSkippingOrInstallingClearsBadge() {
        XCTAssertEqual(UpdateAvailability.available(version: "1.0.37").applying(.updateDismissed), .upToDate)
    }

    func testFailedCheckDoesNotClaimUpToDate() {
        XCTAssertEqual(UpdateAvailability.checking.applying(.checkFailed), .unknown)
        XCTAssertEqual(UpdateAvailability.available(version: "1.0.37").applying(.checkFailed), .available(version: "1.0.37"))
        XCTAssertEqual(UpdateAvailability.upToDate.applying(.checkFailed), .upToDate)
    }
}

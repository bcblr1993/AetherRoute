import XCTest
@testable import AetherRouteKit

final class TailscalePresenceTests: XCTestCase {
    func testCGNATRangeIsExactly100_64Slash10() {
        func ip(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 { a << 24 | b << 16 | c << 8 | d }
        XCTAssertTrue(TailscalePresence.isCGNAT(ip(100, 64, 0, 1)))
        XCTAssertTrue(TailscalePresence.isCGNAT(ip(100, 127, 255, 254)))
        XCTAssertFalse(TailscalePresence.isCGNAT(ip(100, 63, 255, 255)))
        XCTAssertFalse(TailscalePresence.isCGNAT(ip(100, 128, 0, 0)))
        XCTAssertFalse(TailscalePresence.isCGNAT(ip(198, 18, 0, 1)))
    }

    func testReadingTheSystemNeverThrowsOrClaimsAnExitNodeWithoutTheOverlay() {
        let presence = TailscalePresence.current()
        if !presence.isRunning { XCTAssertFalse(presence.usesExitNode) }
    }
}

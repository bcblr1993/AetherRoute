import AetherRouteKit
import XCTest
@testable import AetherRouteTransparentProxySupport

final class SyntheticSourceEndpointPoolTests: XCTestCase, @unchecked Sendable {
    func testLeasesAreUniqueUntilReleasedAndWrapSafely() throws {
        let pool = try SyntheticSourceEndpointPool(portRange: 60_000...60_002)
        let first = try pool.leaseUDP()
        let second = try pool.leaseUDP()
        let third = try pool.leaseUDP()

        XCTAssertEqual(first.endpoint, udpEndpoint(port: 60_000))
        XCTAssertEqual(second.endpoint, udpEndpoint(port: 60_001))
        XCTAssertEqual(third.endpoint, udpEndpoint(port: 60_002))
        XCTAssertEqual(pool.activeLeaseCount, 3)
        XCTAssertThrowsError(try pool.leaseUDP()) { error in
            XCTAssertEqual(
                error as? SyntheticSourceEndpointPoolError,
                .exhausted
            )
        }

        second.release()
        second.release()
        let wrapped = try pool.leaseUDP()
        XCTAssertEqual(wrapped.endpoint, udpEndpoint(port: 60_001))
        XCTAssertEqual(pool.activeLeaseCount, 3)
    }

    func testLeaseDeinitReturnsPort() throws {
        let pool = try SyntheticSourceEndpointPool(portRange: 61_000...61_000)
        var lease: SyntheticSourceEndpointLease? = try pool.leaseUDP()
        XCTAssertNotNil(lease)
        XCTAssertEqual(pool.activeLeaseCount, 1)

        lease = nil
        XCTAssertEqual(pool.activeLeaseCount, 0)
        XCTAssertEqual(
            try pool.leaseUDP().endpoint,
            udpEndpoint(port: 61_000)
        )
    }

    func testZeroPortRangeIsRejected() {
        XCTAssertThrowsError(
            try SyntheticSourceEndpointPool(portRange: 0...10)
        ) { error in
            XCTAssertEqual(
                error as? SyntheticSourceEndpointPoolError,
                .invalidPortRange
            )
        }
    }

    private func udpEndpoint(port: UInt16) -> FlowEndpoint {
        FlowEndpoint(
            host: .ipv4([0, 0, 0, 0]),
            port: port,
            transport: .udp
        )
    }
}

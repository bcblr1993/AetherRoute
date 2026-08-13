import AetherRouteKit
import Darwin
import Foundation
import Network
import XCTest
@testable import AetherRouteTransparentProxySupport

final class NetworkFlowEndpointCodecTests: XCTestCase {
    func testDomainIsCanonicalizedWithoutResolvingIt() throws {
        let networkEndpoint = Network.NWEndpoint.hostPort(
            host: .name("WWW.Example.COM.", nil),
            port: 443
        )

        let flowEndpoint = try NetworkFlowEndpointCodec.decode(
            networkEndpoint,
            transport: .tcp
        )
        XCTAssertEqual(flowEndpoint.host, .name("www.example.com"))
        XCTAssertEqual(
            try NetworkFlowEndpointCodec.decode(
                NetworkFlowEndpointCodec.encode(flowEndpoint),
                transport: .tcp
            ),
            flowEndpoint
        )
    }

    func testIPv4RoundTripUsesSockaddrNetworkByteOrder() throws {
        let endpoint = FlowEndpoint(
            host: .ipv4([192, 0, 2, 9]),
            port: 0x1234,
            transport: .udp
        )

        XCTAssertEqual(
            try NetworkFlowEndpointCodec.decode(
                NetworkFlowEndpointCodec.encode(endpoint),
                transport: .udp
            ),
            endpoint
        )
    }

    func testIPv6ScopeIDSurvivesOpaqueEndpointRoundTrip() throws {
        let scopeID = if_nametoindex("lo0")
        XCTAssertNotEqual(scopeID, 0)
        let endpoint = FlowEndpoint(
            host: .ipv6(
                Array(repeating: 0, count: 15) + [1],
                scopeID: scopeID
            ),
            port: 53,
            transport: .udp
        )

        XCTAssertEqual(
            try NetworkFlowEndpointCodec.decode(
                NetworkFlowEndpointCodec.encode(endpoint),
                transport: .udp
            ),
            endpoint
        )
    }

    func testRejectsNonHostPortEndpointAndZeroPort() {
        XCTAssertThrowsError(
            try NetworkFlowEndpointCodec.decode(
                .unix(path: "/tmp/not-a-proxy-endpoint"),
                transport: .tcp
            )
        )
        XCTAssertThrowsError(
            try NetworkFlowEndpointCodec.decode(
                .hostPort(host: "example.com", port: .any),
                transport: .tcp
            )
        )
    }

    func testUnspecifiedUDPLocalPortUsesSyntheticSourceLease() throws {
        let unspecified = Network.NWEndpoint.hostPort(
            host: .ipv4(.init("100.64.0.5")!),
            port: .any
        )
        XCTAssertTrue(NetworkFlowEndpointCodec.hasUnspecifiedPort(unspecified))
        XCTAssertNil(
            try NetworkExtensionFlowLifecycle.udpLocalSource(
                from: unspecified
            )
        )

        let concrete = Network.NWEndpoint.hostPort(
            host: .ipv4(.init("192.168.50.24")!),
            port: 54_189
        )
        XCTAssertFalse(NetworkFlowEndpointCodec.hasUnspecifiedPort(concrete))
        XCTAssertEqual(
            try NetworkExtensionFlowLifecycle.udpLocalSource(from: concrete),
            FlowEndpoint(
                host: .ipv4([192, 168, 50, 24]),
                port: 54_189,
                transport: .udp
            )
        )
    }
}

import Foundation
import XCTest
@testable import AetherRouteKit

final class FlowEndpointCodecTests: XCTestCase {
    func testRoundTripsIPv4IPv6AndNamedEndpoints() throws {
        let endpoints = [
            FlowEndpoint(
                host: .ipv4([127, 0, 0, 1]),
                port: 443,
                transport: .tcp
            ),
            FlowEndpoint(
                host: .ipv6(
                    Array(repeating: 0, count: 15) + [1],
                    scopeID: 42
                ),
                port: 53,
                transport: .udp
            ),
            FlowEndpoint(
                host: .name("xn--fsq.example"),
                port: 8_443,
                transport: .tcp
            ),
        ]

        for endpoint in endpoints {
            XCTAssertEqual(
                try FlowEndpointCodec.decode(
                    FlowEndpointCodec.encode(endpoint)
                ),
                endpoint
            )
        }
    }

    func testEncodingIsVersionedAndUsesNetworkByteOrder() throws {
        let endpoint = FlowEndpoint(
            host: .ipv4([192, 0, 2, 1]),
            port: 0x1234,
            transport: .tcp
        )

        XCTAssertEqual(
            Array(try FlowEndpointCodec.encode(endpoint)),
            [
                1, 1, 1, 0x12, 0x34,
                0, 0, 0, 0,
                0, 4,
                192, 0, 2, 1,
            ]
        )
    }

    func testNamedEndpointsUseOneCanonicalRoutingForm() throws {
        let endpoint = FlowEndpoint(
            host: .name("ExAmPlE.COM."),
            port: 443,
            transport: .tcp
        )
        XCTAssertEqual(endpoint.host, .name("example.com"))

        let encoded = try FlowEndpointCodec.encode(endpoint)
        XCTAssertEqual(
            try FlowEndpointCodec.decode(encoded).host,
            .name("example.com")
        )

        let nonCanonicalPayload = Array("EXAMPLE.COM.".utf8)
        let nonCanonicalWire = Data([
            1, 1, 3, 0x01, 0xbb,
            0, 0, 0, 0,
            0, UInt8(nonCanonicalPayload.count),
        ] + nonCanonicalPayload)
        XCTAssertEqual(
            try FlowEndpointCodec.decode(nonCanonicalWire).host,
            .name("example.com")
        )

        XCTAssertThrowsError(
            try FlowEndpoint(
                host: .name("example.com.."),
                port: 443,
                transport: .tcp
            ).validated()
        )
    }

    func testRejectsZeroPortInvalidIPAndInvalidName() {
        XCTAssertThrowsError(
            try FlowEndpoint(
                host: .ipv4([127, 0, 0]),
                port: 443,
                transport: .tcp
            ).validated()
        )
        XCTAssertThrowsError(
            try FlowEndpoint(
                host: .ipv6([0, 1], scopeID: 3),
                port: 443,
                transport: .tcp
            ).validated()
        )
        XCTAssertThrowsError(
            try FlowEndpoint(
                host: .name(String(repeating: "a", count: 254)),
                port: 443,
                transport: .tcp
            ).validated()
        )
        for invalidName in [
            "white space.example",
            "-leading.example",
            "trailing-.example",
            "empty..label",
            "under_score.example",
            "例子.example",
            "\(String(repeating: "a", count: 64)).example",
        ] {
            XCTAssertThrowsError(
                try FlowEndpoint(
                    host: .name(invalidName),
                    port: 443,
                    transport: .tcp
                ).validated(),
                invalidName
            )
        }
        XCTAssertThrowsError(
            try FlowEndpoint(
                host: .name("example.com"),
                port: 0,
                transport: .tcp
            ).validated()
        )
    }

    func testIPv6ScopeUsesNetworkByteOrderAndNonIPv6ScopeIsRejected() throws {
        let scopedIPv6 = FlowEndpoint(
            host: .ipv6(
                Array(repeating: 0, count: 15) + [1],
                scopeID: 0x12345678
            ),
            port: 443,
            transport: .tcp
        )
        let encoded = try FlowEndpointCodec.encode(scopedIPv6)
        XCTAssertEqual(Array(encoded[5...8]), [0x12, 0x34, 0x56, 0x78])
        XCTAssertEqual(try FlowEndpointCodec.decode(encoded), scopedIPv6)

        var illegalIPv4Scope = try FlowEndpointCodec.encode(
            FlowEndpoint(
                host: .ipv4([127, 0, 0, 1]),
                port: 443,
                transport: .tcp
            )
        )
        illegalIPv4Scope[8] = 1
        XCTAssertThrowsError(
            try FlowEndpointCodec.decode(illegalIPv4Scope)
        ) { error in
            XCTAssertEqual(
                error as? FlowEndpointCodecError,
                .unexpectedScopeID(hostKind: 1, scopeID: 1)
            )
        }

        var illegalNameScope = try FlowEndpointCodec.encode(
            FlowEndpoint(
                host: .name("example.com"),
                port: 443,
                transport: .tcp
            )
        )
        illegalNameScope[7] = 1
        XCTAssertThrowsError(try FlowEndpointCodec.decode(illegalNameScope))
    }

    func testDecoderRejectsUnknownTagsTruncationAndTrailingBytes() throws {
        let valid = try FlowEndpointCodec.encode(
            FlowEndpoint(
                host: .name("example.com"),
                port: 443,
                transport: .tcp
            )
        )
        var unknownVersion = valid
        unknownVersion[0] = 99
        XCTAssertThrowsError(try FlowEndpointCodec.decode(unknownVersion))

        var unknownTransport = valid
        unknownTransport[1] = 99
        XCTAssertThrowsError(try FlowEndpointCodec.decode(unknownTransport))

        var unknownHost = valid
        unknownHost[2] = 99
        XCTAssertThrowsError(try FlowEndpointCodec.decode(unknownHost))

        XCTAssertThrowsError(try FlowEndpointCodec.decode(valid.dropLast()))

        var trailing = valid
        trailing.append(0)
        XCTAssertThrowsError(try FlowEndpointCodec.decode(trailing))
    }
}

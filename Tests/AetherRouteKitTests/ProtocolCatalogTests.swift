import XCTest
@testable import AetherRouteKit

final class ProtocolCatalogTests: XCTestCase {
    func testReleaseTargetHasUniqueProtocolIdentifiers() {
        let identifiers = ProtocolCatalog.releaseTarget.map(\.id)
        XCTAssertEqual(Set(identifiers).count, identifiers.count)
    }

    func testEverySupportedProtocolIsAReleaseGate() {
        let identifiers = Set(ProtocolCatalog.releaseTarget.map(\.id))
        let required = Set([
            "http", "socks5", "shadowsocks", "vmess", "vless", "trojan",
            "hysteria2", "tuic", "anytls", "wireguard", "ssh",
            "shadowquic"
        ])
        XCTAssertEqual(identifiers, required)
    }

    func testNoProtocolIsPrematurelyMarkedVerified() {
        XCTAssertFalse(ProtocolCatalog.releaseTarget.contains { $0.readiness == .verified })
    }

    func testHTTPConnectIsIntegratedButAwaitsInteroperabilityVerification() {
        let http = ProtocolCatalog.releaseTarget.first { $0.id == "http" }
        XCTAssertEqual(http?.readiness, .integration)
        XCTAssertEqual(http?.transports, ["CONNECT", "TLS", "Basic Auth"])
    }

    func testTUICV5IsIntegratedButAwaitsThirdPartyInteroperability() {
        let tuic = ProtocolCatalog.releaseTarget.first { $0.id == "tuic" }
        XCTAssertEqual(tuic?.displayName, "TUIC v5")
        XCTAssertEqual(tuic?.readiness, .integration)
        XCTAssertEqual(
            tuic?.transports,
            ["QUIC", "TCP", "UDP Datagram", "UDP Stream"]
        )
    }
}

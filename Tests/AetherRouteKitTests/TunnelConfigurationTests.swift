import XCTest
@testable import AetherRouteKit

final class TunnelConfigurationTests: XCTestCase {
    func testDefaultConfigurationIsValid() throws {
        let configuration = TunnelConfiguration()
        XCTAssertEqual(try configuration.validated(), configuration)
    }

    func testRejectsUnsafeMTU() {
        let configuration = TunnelConfiguration(mtu: 1_000)
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? TunnelConfigurationError, .invalidMTU(1_000))
        }
    }

    func testRejectsInvalidDNSAddress() {
        let configuration = TunnelConfiguration(dnsServers: ["not-an-address"])
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(error as? TunnelConfigurationError, .invalidDNSServers)
        }
    }

    func testAcceptsIPv6DNSAddress() throws {
        let configuration = TunnelConfiguration(dnsServers: ["2606:4700:4700::1111"])
        XCTAssertEqual(try configuration.validated(), configuration)
    }

    func testRejectsInvalidIPv6TunnelAddress() {
        let configuration = TunnelConfiguration(ipv6Address: "not-ipv6")
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(
                error as? TunnelConfigurationError,
                .invalidIPv6Address("not-ipv6")
            )
        }
    }

    func testRejectsInvalidIPv6PrefixLength() {
        let configuration = TunnelConfiguration(ipv6PrefixLength: 129)
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(
                error as? TunnelConfigurationError,
                .invalidIPv6PrefixLength(129)
            )
        }
    }

    func testRejectsInvalidLocalProxySettings() {
        let configuration = TunnelConfiguration(
            localProxy: LocalProxySettings(
                isEnabled: true,
                httpPort: 7_890,
                socksPort: 7_890
            )
        )
        XCTAssertThrowsError(try configuration.validated()) { error in
            XCTAssertEqual(
                error as? TunnelConfigurationError,
                .invalidLocalProxy
            )
        }
    }

    func testProviderConfigurationRoundTripsEveryRoutingMode() {
        let localProxy = LocalProxySettings(
            isEnabled: true,
            httpPort: 17_890,
            socksPort: 17_891
        )
        for mode in RoutingMode.allCases {
            let encoded = TunnelProviderConfigurationCodec.setting(
                routingMode: mode,
                localProxy: localProxy,
                in: ["futureKey": "preserved"]
            )

            XCTAssertEqual(
                try TunnelProviderConfigurationCodec.routingMode(from: encoded),
                mode
            )
            XCTAssertEqual(encoded["futureKey"] as? String, "preserved")
            XCTAssertEqual(
                try? TunnelProviderConfigurationCodec.localProxySettings(
                    from: encoded
                ),
                localProxy
            )
            XCTAssertTrue(
                TunnelProviderConfigurationCodec.isPrimaryConfiguration(encoded)
            )
        }
    }

    func testProviderConfigurationDefaultsMissingModeToRule() throws {
        XCTAssertEqual(
            try TunnelProviderConfigurationCodec.routingMode(from: nil),
            .rule
        )
        XCTAssertEqual(
            try TunnelProviderConfigurationCodec.localProxySettings(from: nil),
            LocalProxySettings()
        )
    }

    func testProviderConfigurationRejectsUnknownMode() {
        XCTAssertThrowsError(
            try TunnelProviderConfigurationCodec.routingMode(
                from: [
                    TunnelProviderConfigurationCodec.routingModeKey: "unknown"
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? TunnelProviderConfigurationError,
                .invalidRoutingMode
            )
        }
    }

    func testProviderConfigurationRejectsMalformedLocalProxy() {
        let malformed: [[String: Any]] = [
            [
                TunnelProviderConfigurationCodec.localProxyEnabledKey: true,
                TunnelProviderConfigurationCodec.localProxyHTTPPortKey: 7_890,
            ],
            [
                TunnelProviderConfigurationCodec.localProxyEnabledKey: "true",
                TunnelProviderConfigurationCodec.localProxyHTTPPortKey: 7_890,
                TunnelProviderConfigurationCodec.localProxySOCKSPortKey: 7_891,
            ],
            [
                TunnelProviderConfigurationCodec.localProxyEnabledKey: true,
                TunnelProviderConfigurationCodec.localProxyHTTPPortKey: 7_890,
                TunnelProviderConfigurationCodec.localProxySOCKSPortKey: 7_890,
            ],
            [
                TunnelProviderConfigurationCodec.localProxyEnabledKey: true,
                TunnelProviderConfigurationCodec.localProxyHTTPPortKey: true,
                TunnelProviderConfigurationCodec.localProxySOCKSPortKey: 7_891,
            ],
        ]
        for configuration in malformed {
            XCTAssertThrowsError(
                try TunnelProviderConfigurationCodec.localProxySettings(
                    from: configuration
                )
            ) { error in
                XCTAssertEqual(
                    error as? TunnelProviderConfigurationError,
                    .invalidLocalProxy
                )
            }
        }
    }

    func testProviderConfigurationRejectsFutureSchema() {
        XCTAssertThrowsError(
            try TunnelProviderConfigurationCodec.localProxySettings(
                from: [
                    TunnelProviderConfigurationCodec.schemaVersionKey: 99
                ]
            )
        ) { error in
            XCTAssertEqual(
                error as? TunnelProviderConfigurationError,
                .unsupportedSchema
            )
        }
    }

    func testPacketFlowABIValuesAreStable() {
        XCTAssertEqual(RoutingMode.rule.packetFlowABIValue, 0)
        XCTAssertEqual(RoutingMode.global.packetFlowABIValue, 1)
        XCTAssertEqual(RoutingMode.direct.packetFlowABIValue, 2)
    }

    func testDisabledOrLegacyProviderConfigurationMustBePersisted() {
        let current = TunnelProviderConfigurationCodec.setting(
            routingMode: .global,
            localProxy: LocalProxySettings(
                isEnabled: true,
                httpPort: 17_890,
                socksPort: 17_891
            )
        )
        XCTAssertFalse(
            TunnelProviderConfigurationCodec.requiresPersistence(
                routingMode: .global,
                localProxy: LocalProxySettings(
                    isEnabled: true,
                    httpPort: 17_890,
                    socksPort: 17_891
                ),
                configuration: current,
                isEnabled: true
            )
        )
        XCTAssertTrue(
            TunnelProviderConfigurationCodec.requiresPersistence(
                routingMode: .global,
                localProxy: LocalProxySettings(
                    isEnabled: true,
                    httpPort: 17_890,
                    socksPort: 17_891
                ),
                configuration: current,
                isEnabled: false
            )
        )
        XCTAssertTrue(
            TunnelProviderConfigurationCodec.requiresPersistence(
                routingMode: .global,
                configuration: [
                    TunnelProviderConfigurationCodec.routingModeKey: "global"
                ],
                isEnabled: true
            )
        )
    }

    func testRoutingModePreferencePersistsWithoutConnecting() throws {
        let suite = "TunnelConfigurationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RoutingModePreferenceStore(defaults: defaults)

        XCTAssertEqual(
            store.load(),
            .rule
        )
        store.save(.global)
        XCTAssertEqual(store.load(), .global)
    }
}

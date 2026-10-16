import XCTest
@testable import AetherRouteKit

final class LocalProxySettingsTests: XCTestCase {
    func testDefaultsAreDisabledAndValid() throws {
        let settings = LocalProxySettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertEqual(settings.httpPort, 7_890)
        XCTAssertEqual(settings.socksPort, 7_891)
        XCTAssertFalse(settings.allowLAN)
        XCTAssertEqual(try settings.validated(), settings)
        XCTAssertThrowsError(try settings.shellEnvironmentCommand()) { error in
            XCTAssertEqual(error as? LocalProxySettingsError, .disabled)
        }
    }

    func testShellEnvironmentUsesOnlyFixedLoopbackAndValidatedPorts() throws {
        let command = try LocalProxySettings(
            isEnabled: true,
            httpPort: 18_090,
            socksPort: 18_091
        ).shellEnvironmentCommand()

        XCTAssertTrue(command.contains("HTTP_PROXY=http://127.0.0.1:18090"))
        XCTAssertTrue(command.contains("ALL_PROXY=socks5h://127.0.0.1:18091"))
        XCTAssertTrue(command.contains("NO_PROXY=localhost,127.0.0.1,::1"))
        XCTAssertFalse(command.contains("0.0.0.0"))
        XCTAssertFalse(command.contains("localhost:"))
        XCTAssertFalse(command.contains("\n"))
    }

    func testLANConfigurationGuideAndEnvironment() throws {
        let settings = LocalProxySettings(
            isEnabled: true,
            httpPort: 7_890,
            socksPort: 7_891,
            allowLAN: true
        )
        let guide = settings.lanConfigurationGuide(lanIP: "192.168.1.108")
        XCTAssertTrue(guide.contains("192.168.1.108"))
        XCTAssertTrue(guide.contains("7890"))
        XCTAssertTrue(guide.contains("7891"))

        let lanCmd = try settings.lanShellEnvironmentCommand(lanIP: "192.168.1.108")
        XCTAssertTrue(lanCmd.contains("HTTP_PROXY=http://192.168.1.108:7890"))
        XCTAssertTrue(lanCmd.contains("ALL_PROXY=socks5h://192.168.1.108:7891"))
        XCTAssertTrue(lanCmd.contains("NO_PROXY=localhost,127.0.0.1,::1,192.168.1.108"))

        // When allowLAN is false, lanShellEnvironmentCommand must throw disabled
        let disabledLAN = LocalProxySettings(isEnabled: true, allowLAN: false)
        XCTAssertThrowsError(try disabledLAN.lanShellEnvironmentCommand(lanIP: "192.168.1.108")) { error in
            XCTAssertEqual(error as? LocalProxySettingsError, .disabled)
        }

        // When allowLAN is true but isEnabled is false, it must still succeed
        let independentLAN = LocalProxySettings(isEnabled: false, allowLAN: true)
        let independentCmd = try independentLAN.lanShellEnvironmentCommand(lanIP: "192.168.1.108")
        XCTAssertTrue(independentCmd.contains("HTTP_PROXY=http://192.168.1.108:7890"))
    }

    func testRejectsPrivilegedOutOfRangeAndDuplicatePorts() {
        XCTAssertThrowsError(
            try LocalProxySettings(httpPort: 80).validated()
        ) { error in
            XCTAssertEqual(
                error as? LocalProxySettingsError,
                .invalidHTTPPort(80)
            )
        }
        XCTAssertThrowsError(
            try LocalProxySettings(socksPort: 65_536).validated()
        ) { error in
            XCTAssertEqual(
                error as? LocalProxySettingsError,
                .invalidSOCKSPort(65_536)
            )
        }
        XCTAssertThrowsError(
            try LocalProxySettings(httpPort: 8_888, socksPort: 8_888)
                .validated()
        ) { error in
            XCTAssertEqual(
                error as? LocalProxySettingsError,
                .duplicatePorts(8_888)
            )
        }
    }

    func testStoreRoundTripsAndInvalidDataFailsClosed() throws {
        let suite = "LocalProxySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalProxySettingsStore(defaults: defaults)
        let expected = LocalProxySettings(
            isEnabled: true,
            httpPort: 28_090,
            socksPort: 28_091
        )

        try store.save(expected)
        XCTAssertEqual(store.load(), expected)

        defaults.set(Data("not-json".utf8), forKey: LocalProxySettingsStore.storageKey)
        XCTAssertEqual(store.load(), LocalProxySettings())

        let future = LocalProxySettings(version: 2, isEnabled: true)
        defaults.set(
            try JSONEncoder().encode(future),
            forKey: LocalProxySettingsStore.storageKey
        )
        XCTAssertEqual(store.load(), LocalProxySettings())
    }

    func testStoreRejectsInvalidSettingsWithoutReplacingExistingValue() throws {
        let suite = "LocalProxySettingsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = LocalProxySettingsStore(defaults: defaults)
        let existing = LocalProxySettings(
            isEnabled: true,
            httpPort: 38_090,
            socksPort: 38_091
        )
        try store.save(existing)

        XCTAssertThrowsError(
            try store.save(
                LocalProxySettings(
                    isEnabled: true,
                    httpPort: 38_090,
                    socksPort: 38_090
                )
            )
        )
        XCTAssertEqual(store.load(), existing)
    }

    func testLegacyPayloadWithoutAllowLANDecodesSafely() throws {
        // v1 payload generated by older versions without allowLAN key
        let json = """
        {"version":1,"isEnabled":true,"httpPort":17890,"socksPort":17891}
        """
        let decoded = try JSONDecoder().decode(LocalProxySettings.self, from: Data(json.utf8))
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.httpPort, 17890)
        XCTAssertEqual(decoded.socksPort, 17891)
        XCTAssertFalse(decoded.allowLAN)
    }
}

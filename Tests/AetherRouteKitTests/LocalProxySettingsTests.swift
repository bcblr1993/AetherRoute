import XCTest
@testable import AetherRouteKit

final class LocalProxySettingsTests: XCTestCase {
    func testDefaultsAreDisabledAndValid() throws {
        let settings = LocalProxySettings()
        XCTAssertFalse(settings.isEnabled)
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
}

import XCTest
@testable import AetherRouteKit

final class ProfileImportValidatorTests: XCTestCase {
    func testAcceptsDataOnlyProfile() throws {
        let profile = """
        proxies:
          - name: example
            type: socks5
            server: 127.0.0.1
            port: 1080
        """
        XCTAssertNoThrow(try ProfileImportValidator.validate(data: Data(profile.utf8)))
    }

    func testRejectsExecutableScriptKey() {
        let profile = """
        proxies: []
        script:
          code: runSomething()
        """
        XCTAssertThrowsError(try ProfileImportValidator.validate(data: Data(profile.utf8))) { error in
            XCTAssertEqual(error as? ProfileImportError, .forbiddenExecutableKey("script"))
        }
    }

    func testRejectsIndentedAndInlineExecutableKeys() {
        let profiles = [
            "proxies: []\nrules:\n  command: whoami\n",
            "proxies: [{name: unsafe, type: ss, plugin: executable}]\n",
            "proxies: []\nsettings: { external-ui-url: https://example.com/ui.zip }\n",
            "proxies: []\n'scripts': {}\n",
        ]

        for profile in profiles {
            XCTAssertThrowsError(
                try ProfileImportValidator.validate(data: Data(profile.utf8)),
                "Expected executable key to be rejected in: \(profile)"
            )
        }
    }

    func testCommentsURLsAndRuleScalarsAreNotTreatedAsKeys() {
        let profile = """
        # command: ignored
        proxy-providers:
          safe:
            type: http
            url: https://example.com/command:value
        rules:
          - DOMAIN-SUFFIX,command:example.com,DIRECT
        """
        XCTAssertNoThrow(try ProfileImportValidator.validate(data: Data(profile.utf8)))
    }

    func testDoesNotAcceptProxyWordsInsideCommentsOrValues() {
        let profile = """
        # proxies: []
        note: "proxy-providers: is not a mapping key"
        rules: []
        """
        XCTAssertThrowsError(try ProfileImportValidator.validate(data: Data(profile.utf8))) { error in
            XCTAssertEqual(error as? ProfileImportError, .missingProxyDefinition)
        }
    }

    func testRejectsOversizedProfile() {
        let data = Data(repeating: 0x61, count: ProfileImportValidator.maximumProfileBytes + 1)
        XCTAssertThrowsError(try ProfileImportValidator.validate(data: data))
    }

    func testLargeValidationHonorsCancellationDuringLineScan() {
        let profile = Data(
            (["proxies:"] + (0..<5_000).map {
                "  - {name: node-\($0), type: socks5, server: 127.0.0.1, port: 1080}"
            }).joined(separator: "\n").utf8
        )
        var checks = 0

        XCTAssertThrowsError(
            try ProfileImportValidator.validate(
                data: profile,
                cancellationCheck: {
                    checks += 1
                    if checks == 4 { throw CancellationError() }
                }
            )
        ) { error in
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(checks, 4)
    }

    func testAcceptsSafeBuiltinPluginsAndPluginOpts() {
        let validProfiles = [
            """
            proxies:
              - name: ss-obfs
                type: ss
                server: 127.0.0.1
                port: 8388
                cipher: aes-128-gcm
                password: secret
                plugin: obfs
                plugin-opts:
                  mode: http
                  host: bing.com
            """,
            """
            proxies:
              - { name: ss-inline, type: ss, server: 1.1.1.1, port: 8388, cipher: aes-128-gcm, password: pwd, plugin: obfs, plugin-opts: { mode: http, host: bing.com } }
            """,
            """
            proxies:
              - name: ss-v2ray
                type: ss
                server: 127.0.0.1
                port: 8388
                cipher: aes-128-gcm
                password: secret
                plugin: "v2ray-plugin"
                plugin-opts:
                  mode: websocket
                  host: example.com
            """,
            """
            proxies:
              - name: ss-shadowtls
                type: ss
                server: 127.0.0.1
                port: 8388
                cipher: aes-128-gcm
                password: secret
                plugin: 'shadow-tls'
                plugin-opts:
                  host: example.com
                  password: tls-password
                  version: 3
            """
        ]

        for profile in validProfiles {
            XCTAssertNoThrow(
                try ProfileImportValidator.validate(data: Data(profile.utf8)),
                "Safe built-in plugin should be accepted: \(profile)"
            )
        }
    }

    func testRejectsMaliciousOrExternalPlugins() {
        let maliciousProfiles = [
            "proxies: [{name: evil, type: ss, plugin: /bin/sh}]",
            "proxies: [{name: evil, type: ss, plugin: 'curl http://evil.com'}]",
            "proxies: [{name: evil, type: ss, plugin: custom-binary}]",
            """
            proxies:
              - name: evil-block
                type: ss
                plugin: "../../../usr/bin/python"
            """
        ]

        for profile in maliciousProfiles {
            XCTAssertThrowsError(
                try ProfileImportValidator.validate(data: Data(profile.utf8)),
                "Malicious or arbitrary executable plugin must be rejected: \(profile)"
            ) { error in
                XCTAssertEqual(error as? ProfileImportError, .forbiddenExecutableKey("plugin"))
            }
        }
    }
}

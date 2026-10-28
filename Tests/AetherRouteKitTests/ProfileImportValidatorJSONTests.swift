import Foundation
import XCTest
@testable import AetherRouteKit

/// JSON is valid YAML, and some subscription tools serve Clash profiles as
/// JSON. A value then ends with a comma: `"plugin": "shadow-tls",`.
final class ProfileImportValidatorJSONTests: XCTestCase {
    private func profile(plugin: String, extra: String = "") -> Data {
        Data("""
        {
          "proxies": [
            {
              "name": "a",
              "type": "ss",
              "plugin": \(plugin),\(extra)
              "plugin-opts": {"host": "x", "password": "y", "version": 3}
            }
          ]
        }
        """.utf8)
    }

    func testAcceptsABuiltinPluginFollowedByAComma() throws {
        // Rejected as an executable plugin before, which refused the profile.
        try ProfileImportValidator.validate(data: profile(plugin: #""shadow-tls""#))
        try ProfileImportValidator.validate(data: profile(plugin: #""obfs""#))
    }

    func testStillRejectsAnUnknownPluginOrCommandInJSON() {
        for plugin in [#""/bin/sh""#, #""evil-plugin""#, #""shadow-tls; rm""#] {
            XCTAssertThrowsError(try ProfileImportValidator.validate(data: profile(plugin: plugin))) { error in
                XCTAssertEqual(error as? ProfileImportError, .forbiddenExecutableKey("plugin"), plugin)
            }
        }
        XCTAssertThrowsError(
            try ProfileImportValidator.validate(
                data: profile(plugin: #""shadow-tls""#, extra: "\n      \"command\": \"sh\",")
            )
        ) { error in
            XCTAssertEqual(error as? ProfileImportError, .forbiddenExecutableKey("command"))
        }
    }
}

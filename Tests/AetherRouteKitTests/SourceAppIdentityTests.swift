@testable import AetherRouteKit
import Foundation
import XCTest

final class SourceAppIdentityTests: XCTestCase {
    private let chromeHelper = "/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/130.0/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper"

    func testFlowSourceAppEncodesASA1() throws {
        let app = try XCTUnwrap(FlowSourceApp(
            signingIdentifier: "com.example",
            executablePath: "/x"
        ))
        XCTAssertEqual(
            app.encoded,
            Data("ASA1".utf8) + Data([0, 11]) + Data("com.example".utf8)
                + Data([0, 2]) + Data("/x".utf8)
        )
    }

    func testFlowSourceAppDropsFieldsTheEngineWouldReject() {
        let long = String(repeating: "a", count: FlowSourceApp.maximumFieldBytes + 1)
        let app = FlowSourceApp(signingIdentifier: long, executablePath: "/bin/ok")
        XCTAssertNil(app?.signingIdentifier)
        XCTAssertEqual(app?.executablePath, "/bin/ok")
        XCTAssertNil(FlowSourceApp(signingIdentifier: "bad\nid", executablePath: ""))
        XCTAssertNil(FlowSourceApp(signingIdentifier: "", executablePath: nil))
        // Exactly the limit is still accepted, as the engine accepts it.
        let limit = String(repeating: "b", count: FlowSourceApp.maximumFieldBytes)
        XCTAssertEqual(
            FlowSourceApp(signingIdentifier: limit, executablePath: nil)?.signingIdentifier,
            limit
        )
    }

    func testHelpersFoldIntoTheOutermostApp() throws {
        let helper = try XCTUnwrap(SourceAppIdentity(
            signingIdentifier: "com.google.Chrome.helper",
            executablePath: chromeHelper
        ))
        let main = try XCTUnwrap(SourceAppIdentity(
            signingIdentifier: "com.google.Chrome",
            executablePath: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        ))
        XCTAssertEqual(helper.kind, .application)
        XCTAssertEqual(helper.bundlePath, "/Applications/Google Chrome.app")
        XCTAssertEqual(helper.groupingKey, main.groupingKey)
    }

    func testIdentifierOnlyDropsHelperSuffixes() {
        XCTAssertEqual(
            SourceAppIdentity.applicationIdentifier(for: "com.google.Chrome.helper.renderer"),
            "com.google.Chrome"
        )
        XCTAssertEqual(
            SourceAppIdentity.applicationIdentifier(for: "com.microsoft.VSCode.helper"),
            "com.microsoft.VSCode"
        )
        // Not a helper, and "ChromeX" is a different app.
        XCTAssertEqual(
            SourceAppIdentity.applicationIdentifier(for: "com.google.ChromeX"),
            "com.google.ChromeX"
        )
        let identity = SourceAppIdentity(
            signingIdentifier: "com.google.Chrome.helper",
            executablePath: ""
        )
        XCTAssertEqual(identity?.bundleIdentifier, "com.google.Chrome")
        XCTAssertEqual(identity?.kind, .application)
    }

    func testSystemProcessesAndToolsAreNamedForWhatTheyAre() {
        XCTAssertEqual(
            SourceAppIdentity(
                signingIdentifier: "com.apple.WebKit.Networking",
                executablePath: "/System/Library/Frameworks/WebKit.framework/Versions/A/XPCServices/com.apple.WebKit.Networking.xpc/Contents/MacOS/com.apple.WebKit.Networking"
            )?.kind,
            .system(.webKitNetworking)
        )
        XCTAssertEqual(
            SourceAppIdentity(signingIdentifier: "", executablePath: "/usr/libexec/nsurlsessiond")?.kind,
            .system(.backgroundTransfers)
        )
        let curl = SourceAppIdentity(signingIdentifier: "com.apple.curl", executablePath: "/usr/bin/curl")
        XCTAssertEqual(curl?.kind, .executable)
        XCTAssertEqual(curl?.fallbackName, "curl")
        XCTAssertEqual(curl?.groupingKey, "path:/usr/bin/curl")
    }

    func testNothingReportedIsUnknown() {
        XCTAssertNil(SourceAppIdentity(signingIdentifier: "", executablePath: ""))
        XCTAssertNil(SourceAppIdentity(signingIdentifier: "", executablePath: "relative"))
    }
}

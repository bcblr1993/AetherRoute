import XCTest
@testable import AetherRouteKit

final class AppLogTests: XCTestCase {
    func testSubsystemConsistency() {
        XCTAssertEqual(AppLog.subsystem, "com.aetherroute.desktop")
    }

    func testCategoryHierarchyConventions() {
        let appCategories = [
            AppLog.Category.appRuntime,
            AppLog.Category.appLifecycle,
            AppLog.Category.appActivation,
        ]
        for category in appCategories {
            XCTAssertTrue(category.hasPrefix("app."), "Expected app prefix for \(category)")
        }

        let tunnelCategories = [
            AppLog.Category.tunnelRuntime,
            AppLog.Category.tunnelCore,
        ]
        for category in tunnelCategories {
            XCTAssertTrue(category.hasPrefix("tunnel."), "Expected tunnel prefix for \(category)")
        }

        let proxyCategories = [
            AppLog.Category.proxyRuntime,
            AppLog.Category.proxyBudget,
            AppLog.Category.proxyInput,
        ]
        for category in proxyCategories {
            XCTAssertTrue(category.hasPrefix("proxy."), "Expected proxy prefix for \(category)")
        }

        let engineCategories = [
            AppLog.Category.flowEngine,
        ]
        for category in engineCategories {
            XCTAssertTrue(category.hasPrefix("engine."), "Expected engine prefix for \(category)")
        }

        let kitCategories = [
            AppLog.Category.profileKeys,
            AppLog.Category.activeProfile,
            AppLog.Category.diagnostics,
        ]
        for category in kitCategories {
            XCTAssertTrue(category.hasPrefix("kit."), "Expected kit prefix for \(category)")
        }
    }

    func testLoggerCreationDoesNotCrash() {
        let logger = AppLog.logger(category: AppLog.Category.appRuntime)
        logger.debug("Testing testLoggerCreationDoesNotCrash debug message")
    }

    func testURLSanitizationRedactsSensitiveQueryParams() {
        let rawURLString = "https://subscribe.example.com/api/v1/client/subscribe?token=SECRET_TOKEN_12345&flag=clash&secret=MY_KEY"
        guard let url = URL(string: rawURLString) else {
            XCTFail("Failed to construct URL")
            return
        }

        let sanitized = url.sanitizedForLogging
        XCTAssertFalse(sanitized.contains("SECRET_TOKEN_12345"))
        XCTAssertFalse(sanitized.contains("MY_KEY"))
        XCTAssertTrue(sanitized.contains("token=***"))
        XCTAssertTrue(sanitized.contains("secret=***"))
        XCTAssertTrue(sanitized.contains("flag=clash"))
    }

    func testURLSanitizationStripsUserInfoAndFragment() {
        let rawURLString = "https://admin:supersecret@subscribe.example.com:8443/download?apiKey=xyz987#section2"
        let sanitized = rawURLString.sanitizedURLForLogging

        XCTAssertFalse(sanitized.contains("admin"))
        XCTAssertFalse(sanitized.contains("supersecret"))
        XCTAssertFalse(sanitized.contains("xyz987"))
        XCTAssertFalse(sanitized.contains("#section2"))
        XCTAssertTrue(sanitized.contains("apiKey=***"))
    }

    func testURLSanitizationPreservesSafeURL() {
        let rawURLString = "https://example.com/path/to/resource?version=1&format=json"
        let sanitized = rawURLString.sanitizedURLForLogging

        XCTAssertEqual(sanitized, "https://example.com/path/to/resource?version=1&format=json")
    }

    func testURLSanitizationHandlesMalformedInputGracefully() {
        let notAURL = ":::not-a-valid-url:::"
        XCTAssertEqual(notAURL.sanitizedURLForLogging, notAURL)
    }
}

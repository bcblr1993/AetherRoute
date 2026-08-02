import XCTest
@testable import AetherRouteKit

final class ProfileOperationIssueTests: XCTestCase {
    func testMapsEverySubscriptionFailureWithoutCarryingItsURL() {
        let values: [(ProfileSubscriptionError, ProfileOperationIssue)] = [
            (.invalidURL, .invalidSubscriptionURL),
            (.invalidAutoUpdateInterval, .invalidAutoUpdateInterval),
            (.invalidResponse, .invalidSubscriptionResponse),
            (.insecureRedirect, .unsafeRedirect),
            (.tooManyRedirects, .tooManyRedirects),
            (.responseTooLarge(12), .subscriptionResponseTooLarge(12)),
            (.httpStatus(403), .subscriptionHTTPStatus(403)),
            (
                .notModifiedWithoutActiveProfile,
                .notModifiedWithoutActiveProfile
            ),
        ]

        for (error, expected) in values {
            XCTAssertEqual(ProfileOperationIssue(error), expected)
        }
    }

    func testMapsImportAndPayloadFailuresExactly() {
        XCTAssertEqual(ProfileOperationIssue(ProfileImportError.empty), .emptyProfile)
        XCTAssertEqual(
            ProfileOperationIssue(ProfileImportError.tooLarge(99)),
            .profileTooLarge(99)
        )
        XCTAssertEqual(
            ProfileOperationIssue(ProfileImportError.notUTF8),
            .profileNotUTF8
        )
        XCTAssertEqual(
            ProfileOperationIssue(ProfileImportError.forbiddenExecutableKey("exec")),
            .forbiddenExecutableKey("exec")
        )
        XCTAssertEqual(
            ProfileOperationIssue(ProfileImportError.missingProxyDefinition),
            .missingProxyDefinition
        )
        XCTAssertEqual(
            ProfileOperationIssue(SubscriptionPayloadError.unsupportedFormat),
            .unsupportedSubscriptionFormat
        )
        XCTAssertEqual(
            ProfileOperationIssue(SubscriptionPayloadError.invalidBase64),
            .invalidSubscriptionBase64
        )
        XCTAssertEqual(
            ProfileOperationIssue(SubscriptionPayloadError.tooManyNodes(64)),
            .tooManySubscriptionNodes(64)
        )
        XCTAssertEqual(
            ProfileOperationIssue(SubscriptionPayloadError.invalidShareLink(3)),
            .invalidSubscriptionNode(3)
        )
        XCTAssertEqual(
            ProfileOperationIssue(
                SubscriptionPayloadError.unsupportedShareScheme("unknown")
            ),
            .unsupportedShareScheme("unknown")
        )
    }

    func testRejectsForeignErrorsInsteadOfPresentingTheirDescriptions() {
        XCTAssertNil(ProfileOperationIssue(CocoaError(.fileReadUnknown)))
    }
}

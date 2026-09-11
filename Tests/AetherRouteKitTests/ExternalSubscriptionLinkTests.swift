import Foundation
import XCTest
@testable import AetherRouteKit

final class ExternalSubscriptionLinkTests: XCTestCase {
    func testParsesCanonicalHTTPSSubscriptionLink() throws {
        let incoming = try XCTUnwrap(
            URL(
                string: "aetherroute://subscribe?url=https%3A%2F%2Fprofiles.example%2Fconfig.yaml%3Ftoken%3Dprivate"
            )
        )

        let request = try ExternalSubscriptionLinkParser.parse(incoming)

        XCTAssertEqual(request.providerHost, "profiles.example")
        XCTAssertEqual(
            request.subscriptionURL.absoluteString,
            "https://profiles.example/config.yaml?token=private"
        )
    }

    func testParsesClashAndCustomNameLinks() throws {
        let clashURL = try XCTUnwrap(
            URL(string: "clash://install-config?url=https%3A%2F%2Fprofiles.example%2Fconfig.yaml&name=My%20Airport")
        )
        let request1 = try ExternalSubscriptionLinkParser.parse(clashURL)
        XCTAssertEqual(request1.providerHost, "profiles.example")
        XCTAssertEqual(request1.subscriptionURL.absoluteString, "https://profiles.example/config.yaml")
        XCTAssertEqual(request1.suggestedName, "My Airport")

        let clashSub = try XCTUnwrap(
            URL(string: "clash://install-sub?url=https%3A%2F%2Fprofiles.example%2Fconfig.yaml")
        )
        let request2 = try ExternalSubscriptionLinkParser.parse(clashSub)
        XCTAssertEqual(request2.providerHost, "profiles.example")
        XCTAssertNil(request2.suggestedName)

        let aetherWithName = try XCTUnwrap(
            URL(string: "aetherroute://subscribe?url=https%3A%2F%2Fprofiles.example%2Fconfig.yaml&name=FastRoute")
        )
        let request3 = try ExternalSubscriptionLinkParser.parse(aetherWithName)
        XCTAssertEqual(request3.providerHost, "profiles.example")
        XCTAssertEqual(request3.suggestedName, "FastRoute")
    }

    func testAcceptsOnlyOneExactURLParameter() throws {
        for value in [
            "aetherroute://subscribe",
            "aetherroute://subscribe?url=",
            "aetherroute://subscribe?url=https%3A%2F%2Fexample.com%2Fa&url=https%3A%2F%2Fexample.com%2Fb",
        ] {
            XCTAssertThrowsError(
                try ExternalSubscriptionLinkParser.parse(
                    try XCTUnwrap(URL(string: value))
                )
            ) { error in
                XCTAssertEqual(
                    error as? ExternalSubscriptionLinkError,
                    .invalidParameters,
                    value
                )
            }
        }
    }

    func testRejectsUnknownActionsPathsCredentialsAndFragments() throws {
        for value in [
            "aetherroute://import?url=https%3A%2F%2Fexample.com%2Fa",
            "aetherroute://subscribe/activate?url=https%3A%2F%2Fexample.com%2Fa",
            "aetherroute://user:pass@subscribe?url=https%3A%2F%2Fexample.com%2Fa",
            "aetherroute://subscribe?url=https%3A%2F%2Fexample.com%2Fa#fragment",
        ] {
            XCTAssertThrowsError(
                try ExternalSubscriptionLinkParser.parse(
                    try XCTUnwrap(URL(string: value))
                )
            ) { error in
                XCTAssertEqual(
                    error as? ExternalSubscriptionLinkError,
                    .invalidAction,
                    value
                )
            }
        }
    }

    func testRejectsNonHTTPSCredentialAndFragmentSubscriptionURLs() throws {
        for target in [
            "http://example.com/profile.yaml",
            "https://user:secret@example.com/profile.yaml",
            "https://example.com/profile.yaml#token",
        ] {
            var components = URLComponents()
            components.scheme = "aetherroute"
            components.host = "subscribe"
            components.queryItems = [URLQueryItem(name: "url", value: target)]

            XCTAssertThrowsError(
                try ExternalSubscriptionLinkParser.parse(
                    try XCTUnwrap(components.url)
                )
            ) { error in
                XCTAssertEqual(
                    error as? ExternalSubscriptionLinkError,
                    .invalidSubscriptionURL,
                    target
                )
            }
        }
    }

    func testRejectsForeignScheme() throws {
        let incoming = try XCTUnwrap(
            URL(string: "unknownscheme://subscribe?url=https%3A%2F%2Fexample.com%2Fa")
        )
        XCTAssertThrowsError(
            try ExternalSubscriptionLinkParser.parse(incoming)
        ) { error in
            XCTAssertEqual(
                error as? ExternalSubscriptionLinkError,
                .invalidScheme
            )
        }
    }

    func testEnforcesEncodedLinkAndDecodedTargetBounds() throws {
        let oversizedTarget = "https://example.com/" + String(
            repeating: "a",
            count: ExternalSubscriptionLinkParser.maximumSubscriptionURLBytes
        )
        var components = URLComponents()
        components.scheme = "aetherroute"
        components.host = "subscribe"
        components.queryItems = [
            URLQueryItem(name: "url", value: oversizedTarget),
        ]
        XCTAssertThrowsError(
            try ExternalSubscriptionLinkParser.parse(
                try XCTUnwrap(components.url)
            )
        ) { error in
            XCTAssertEqual(
                error as? ExternalSubscriptionLinkError,
                .invalidSubscriptionURL
            )
        }

        let oversizedIncoming = try XCTUnwrap(
            URL(
                string: "aetherroute://subscribe?url=" + String(
                    repeating: "a",
                    count: ExternalSubscriptionLinkParser.maximumIncomingLinkBytes
                )
            )
        )
        XCTAssertThrowsError(
            try ExternalSubscriptionLinkParser.parse(oversizedIncoming)
        ) { error in
            XCTAssertEqual(
                error as? ExternalSubscriptionLinkError,
                .linkTooLong
            )
        }
    }
}

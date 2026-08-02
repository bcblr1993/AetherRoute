import Foundation
import XCTest
@testable import AetherRouteKit

final class ProfileSubscriptionTests: XCTestCase {
    func testRejectsInsecureCredentialAndFragmentURLs() throws {
        for value in [
            "http://example.com/profile.yaml",
            "https://user:secret@example.com/profile.yaml",
            "https://example.com/profile.yaml#token",
            "https:///profile.yaml",
        ] {
            XCTAssertThrowsError(
                try ProfileSubscription(url: try XCTUnwrap(URL(string: value)))
            ) { error in
                XCTAssertEqual(
                    error as? ProfileSubscriptionError,
                    .invalidURL,
                    value
                )
            }
        }
    }

    func testUpdatedResponseUsesConditionalHeadersAndValidators() async throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml?token=private"))
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        let subscription = try ProfileSubscription(
            url: url,
            etag: "\"old\"",
            lastModified: "Mon, 01 Jan 2024 00:00:00 GMT"
        )
        let profileData = Self.validProfileData()
        let client = ProfileSubscriptionClient(
            transport: { request in
                XCTAssertEqual(request.url, url)
                XCTAssertEqual(request.headers["If-None-Match"], "\"old\"")
                XCTAssertEqual(
                    request.headers["If-Modified-Since"],
                    "Mon, 01 Jan 2024 00:00:00 GMT"
                )
                XCTAssertNotNil(request.headers["Accept"])
                XCTAssertTrue(
                    try XCTUnwrap(request.headers["Accept"]).contains("*/*")
                )
                XCTAssertEqual(
                    request.headers["User-Agent"],
                    ProfileSubscriptionClient.userAgent
                )
                XCTAssertTrue(
                    try XCTUnwrap(request.headers["User-Agent"])
                        .localizedCaseInsensitiveContains("clash")
                )
                XCTAssertEqual(request.headers["Cache-Control"], "no-cache")
                return ProfileSubscriptionHTTPResponse(
                    data: profileData,
                    statusCode: 200,
                    finalURL: url,
                    headers: [
                        "ETag": "\"new\"",
                        "Last-Modified": "Tue, 02 Jan 2024 00:00:00 GMT",
                    ]
                )
            },
            now: { checkedAt }
        )

        guard case let .updated(data, metadata, report) = try await client.fetch(subscription) else {
            return XCTFail("Expected an updated profile")
        }
        XCTAssertEqual(data, profileData)
        XCTAssertEqual(metadata.url, url)
        XCTAssertEqual(metadata.etag, "\"new\"")
        XCTAssertEqual(metadata.lastCheckedAt, checkedAt)
        XCTAssertEqual(metadata.lastUpdatedAt, checkedAt)
        XCTAssertEqual(
            report,
            SubscriptionPayloadReport(
                usableNodeCount: nil,
                skippedNodeCount: 0
            )
        )
    }

    func testNotModifiedPreservesLastUpdatedDate() async throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml"))
        let previousUpdate = Date(timeIntervalSince1970: 1_000)
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        let subscription = try ProfileSubscription(
            url: url,
            etag: "\"same\"",
            lastUpdatedAt: previousUpdate
        )
        let client = ProfileSubscriptionClient(
            transport: { _ in
                ProfileSubscriptionHTTPResponse(
                    data: Data(),
                    statusCode: 304,
                    finalURL: url,
                    headers: ["ETag": "\"same\""]
                )
            },
            now: { checkedAt }
        )

        guard case let .notModified(metadata) = try await client.fetch(subscription) else {
            return XCTFail("Expected an unchanged profile")
        }
        XCTAssertEqual(metadata.lastCheckedAt, checkedAt)
        XCTAssertEqual(metadata.lastUpdatedAt, previousUpdate)
    }

    func testRejectsOversizedAndInvalidDownloadedProfiles() async throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml"))
        let subscription = try ProfileSubscription(url: url)
        let oversized = ProfileSubscriptionClient { _ in
            ProfileSubscriptionHTTPResponse(
                data: Self.validProfileData(),
                statusCode: 200,
                finalURL: url,
                headers: [
                    "Content-Length": String(
                        ProfileImportValidator.maximumProfileBytes + 1
                    ),
                ]
            )
        }
        do {
            _ = try await oversized.fetch(subscription)
            XCTFail("Expected an oversized response failure")
        } catch {
            XCTAssertEqual(
                error as? ProfileSubscriptionError,
                .responseTooLarge(ProfileImportValidator.maximumProfileBytes + 1)
            )
        }

        let invalid = ProfileSubscriptionClient { _ in
            ProfileSubscriptionHTTPResponse(
                data: Data("rules:\n  - MATCH,DIRECT\n".utf8),
                statusCode: 200,
                finalURL: url
            )
        }
        do {
            _ = try await invalid.fetch(subscription)
            XCTFail("Expected profile validation to fail")
        } catch {
            XCTAssertEqual(error as? ProfileImportError, .missingProxyDefinition)
        }
    }

    func testRejectsHTTPSDowngradeInFinalResponse() async throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml"))
        let insecure = try XCTUnwrap(URL(string: "http://profiles.example/config.yaml"))
        let subscription = try ProfileSubscription(url: url)
        let client = ProfileSubscriptionClient { _ in
            ProfileSubscriptionHTTPResponse(
                data: Self.validProfileData(),
                statusCode: 200,
                finalURL: insecure
            )
        }

        do {
            _ = try await client.fetch(subscription)
            XCTFail("Expected HTTPS downgrade rejection")
        } catch {
            XCTAssertEqual(error as? ProfileSubscriptionError, .invalidURL)
        }
    }

    func testRedirectDelegateRejectsUnsafeTargetBeforeFollowingIt() throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://profiles.example/config.yaml")
        )
        let unsafeURL = try XCTUnwrap(
            URL(string: "https://user:secret@redirect.example/profile.yaml")
        )
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: ["Location": unsafeURL.absoluteString]
            )
        )
        let delegate = HTTPSOnlyRedirectDelegate()
        var acceptedRequest: URLRequest?

        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: URLRequest(url: unsafeURL)
        ) { acceptedRequest = $0 }

        XCTAssertNil(acceptedRequest)
        XCTAssertEqual(delegate.redirectError, .insecureRedirect)
    }

    func testRedirectDelegateBoundsHopsAndCopiesOnlySafeHeaders() throws {
        let originalURL = try XCTUnwrap(
            URL(string: "https://profiles.example/config.yaml")
        )
        var originalRequest = URLRequest(url: originalURL)
        originalRequest.setValue(
            ProfileSubscriptionClient.userAgent,
            forHTTPHeaderField: "User-Agent"
        )
        originalRequest.setValue("application/yaml", forHTTPHeaderField: "Accept")
        originalRequest.setValue("private", forHTTPHeaderField: "Authorization")
        originalRequest.setValue("session=private", forHTTPHeaderField: "Cookie")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.dataTask(with: originalRequest)
        let response = try XCTUnwrap(
            HTTPURLResponse(
                url: originalURL,
                statusCode: 302,
                httpVersion: "HTTP/1.1",
                headerFields: nil
            )
        )
        let delegate = HTTPSOnlyRedirectDelegate()

        for hop in 1...6 {
            let target = try XCTUnwrap(
                URL(string: "https://redirect.example/profile-\(hop).yaml")
            )
            var acceptedRequest: URLRequest?
            delegate.urlSession(
                session,
                task: task,
                willPerformHTTPRedirection: response,
                newRequest: URLRequest(url: target)
            ) { acceptedRequest = $0 }

            if hop <= 5 {
                XCTAssertEqual(acceptedRequest?.url, target)
                XCTAssertEqual(
                    acceptedRequest?.value(forHTTPHeaderField: "User-Agent"),
                    ProfileSubscriptionClient.userAgent
                )
                XCTAssertEqual(
                    acceptedRequest?.value(forHTTPHeaderField: "Accept"),
                    "application/yaml"
                )
                XCTAssertNil(
                    acceptedRequest?.value(forHTTPHeaderField: "Authorization")
                )
                XCTAssertNil(acceptedRequest?.value(forHTTPHeaderField: "Cookie"))
            } else {
                XCTAssertNil(acceptedRequest)
                XCTAssertEqual(delegate.redirectError, .tooManyRedirects)
            }
        }
    }

    func testAutomaticUpdateDueWindowAndDisabledState() throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml"))
        let checked = Date(timeIntervalSince1970: 10_000)
        let enabled = try ProfileSubscription(
            url: url,
            lastCheckedAt: checked,
            autoUpdateInterval: 3_600
        )
        XCTAssertFalse(enabled.isDue(at: checked.addingTimeInterval(3_599)))
        XCTAssertTrue(enabled.isDue(at: checked.addingTimeInterval(3_600)))

        let disabled = try ProfileSubscription(
            url: url,
            lastCheckedAt: checked,
            autoUpdateInterval: nil
        )
        XCTAssertFalse(disabled.isDue(at: checked.addingTimeInterval(99_999)))
    }

    func testActiveProfileDecodesLegacyPayloadWithoutSubscription() throws {
        let payload = """
        {
          "formatVersion": 1,
          "name": "Legacy",
          "yaml": "proxies:\\n  - {name: Direct, type: direct}\\n",
          "importedAt": 0
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let profile = try decoder.decode(ActiveProfile.self, from: Data(payload.utf8))
        XCTAssertNil(profile.subscription)
    }

    private static func validProfileData() -> Data {
        Data(
            """
            proxies:
              - {name: Edge, type: vmess, server: 127.0.0.1, port: 443}
            rules:
              - MATCH,Edge
            """.utf8
        )
    }
}

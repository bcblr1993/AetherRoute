import Foundation
import XCTest
@testable import AetherRouteKit

final class SubscriptionUsageTests: XCTestCase {
    private let reportedAt = Date(timeIntervalSince1970: 1_800_000_000)
    private let gib: UInt64 = 1_073_741_824

    func testParsesTheStandardHeader() throws {
        let usage = try XCTUnwrap(SubscriptionUsage.parse(
            header: "upload=1073741824; download=2147483648; total=10737418240; expire=1830000000",
            reportedAt: reportedAt
        ))
        XCTAssertEqual(usage.uploadBytes, gib)
        XCTAssertEqual(usage.downloadBytes, 2 * gib)
        XCTAssertEqual(usage.totalBytes, 10 * gib)
        XCTAssertEqual(usage.expiresAt, Date(timeIntervalSince1970: 1_830_000_000))
        XCTAssertEqual(usage.usedBytes, 3 * gib)
        XCTAssertEqual(usage.remainingBytes, 7 * gib)
        XCTAssertEqual(try XCTUnwrap(usage.usedFraction), 0.3, accuracy: 0.0001)
        XCTAssertEqual(usage.reportedAt, reportedAt)
    }

    func testParsingIsLenientPerField() throws {
        let usage = try XCTUnwrap(SubscriptionUsage.parse(
            header: " Upload = 10 ,DOWNLOAD=abc; total=-5;expire=0; total2=9; =3; download",
            reportedAt: reportedAt
        ))
        XCTAssertEqual(usage.uploadBytes, 10)
        XCTAssertNil(usage.downloadBytes, "not a number")
        XCTAssertNil(usage.totalBytes, "negative")
        XCTAssertNil(usage.expiresAt, "expire=0 means no expiry")

        let float = try XCTUnwrap(SubscriptionUsage.parse(
            header: "upload=0; download=1.073741824E9; total=1.5",
            reportedAt: reportedAt
        ))
        XCTAssertEqual(float.downloadBytes, gib)
        XCTAssertNil(float.totalBytes, "fractional byte counts are rejected")

        let huge = try XCTUnwrap(SubscriptionUsage.parse(
            header: "upload=18446744073709551615; download=18446744073709551615; total=1",
            reportedAt: reportedAt
        ))
        XCTAssertEqual(huge.usedBytes, .max, "sum saturates instead of overflowing")
        XCTAssertEqual(huge.remainingBytes, 0)

        for missing in [nil, "", "nothing here", "expire=0", String(repeating: "a", count: 2_000)] {
            XCTAssertNil(SubscriptionUsage.parse(header: missing, reportedAt: reportedAt), String(describing: missing))
        }
        XCTAssertNil(
            SubscriptionUsage.parse(header: "expire=99999999999999", reportedAt: reportedAt)?.expiresAt,
            "beyond year 9999"
        )
    }

    func testAlertsPickTheMostUrgentState() {
        let now = reportedAt
        func usage(used: UInt64?, total: UInt64?, expiresIn: TimeInterval?) -> SubscriptionUsage {
            SubscriptionUsage(
                uploadBytes: 0,
                downloadBytes: used,
                totalBytes: total,
                expiresAt: expiresIn.map { now.addingTimeInterval($0) },
                reportedAt: now
            )
        }
        let day: TimeInterval = 86_400
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(nil, now: now), .none)
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 1, total: 100, expiresIn: 30 * day), now: now), .none)
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 90, total: 100, expiresIn: nil), now: now), .none,
                       "exactly 10% left is not yet low")
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 91, total: 100, expiresIn: nil), now: now),
                       .low(remainingBytes: 9))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expiring = usage(used: 1, total: 100, expiresIn: 3 * day)
        if case .expiring = SubscriptionUsageAlert.evaluate(expiring, now: now) {} else {
            XCTFail("three days out is expiring")
        }
        // Calendar days, not rounded-up hours: a minute-aligned clock must
        // not turn 12 days into 13.
        XCTAssertEqual(usage(used: 1, total: 100, expiresIn: 12 * day).daysUntilExpiry(
            now: now.addingTimeInterval(-30), calendar: utc), 12)
        XCTAssertEqual(usage(used: 1, total: 100, expiresIn: 60).daysUntilExpiry(now: now, calendar: utc), 0)
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 1, total: 100, expiresIn: 60), now: now),
                       .expiring(daysLeft: usage(used: 1, total: 100, expiresIn: 60).daysUntilExpiry(now: now) ?? -1))
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 1, total: 100, expiresIn: 3 * day + 60), now: now), .none)
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 100, total: 100, expiresIn: 30 * day), now: now), .exhausted)
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 100, total: 100, expiresIn: 0), now: now), .expired,
                       "an ended subscription outranks used-up traffic")
        XCTAssertEqual(SubscriptionUsageAlert.evaluate(usage(used: 5, total: nil, expiresIn: nil), now: now), .none,
                       "no total means no traffic alert")
        XCTAssertTrue(SubscriptionUsageAlert.expired.isSevere)
        XCTAssertFalse(SubscriptionUsageAlert.expiring(daysLeft: 1).isSevere)
    }

    func testProviderHints() {
        XCTAssertEqual(SubscriptionResponseHints.updateInterval(header: "12"), 12 * 3_600)
        XCTAssertEqual(SubscriptionResponseHints.updateInterval(header: " 24 "), 24 * 3_600)
        for invalid in [nil, "0", "0.5", "169", "-1", "soon", "nan"] {
            XCTAssertNil(SubscriptionResponseHints.updateInterval(header: invalid), String(describing: invalid))
        }

        XCTAssertEqual(
            SubscriptionResponseHints.profileName(contentDisposition: "attachment; filename=\"My Airport.yaml\""),
            "My Airport"
        )
        XCTAssertEqual(
            SubscriptionResponseHints.profileName(
                contentDisposition: "attachment; filename=fallback.yaml; filename*=UTF-8''%E6%9C%BA%E5%9C%BA.yaml"
            ),
            "机场",
            "the RFC 5987 form wins"
        )
        XCTAssertEqual(
            SubscriptionResponseHints.profileName(contentDisposition: "attachment; filename=\"../etc/pass\\wd\""),
            "..etcpasswd",
            "no path separators survive"
        )
        for invalid in [nil, "attachment", "attachment; filename=\"\"", "attachment; filename=\".yaml\""] {
            let name = SubscriptionResponseHints.profileName(contentDisposition: invalid)
            XCTAssertTrue(name == nil || name == ".yaml", String(describing: invalid))
        }
    }

    func testSubscriptionsSavedBeforeUsageStillDecode() throws {
        let legacy = Data("""
        {"url":"https://profiles.example/config.yaml","autoUpdateInterval":21600}
        """.utf8)
        let subscription = try JSONDecoder().decode(ProfileSubscription.self, from: legacy)
        XCTAssertNil(subscription.usage)
        XCTAssertNil(subscription.providerUpdateInterval)
        XCTAssertNil(subscription.isAutoUpdateIntervalCustomized)
        XCTAssertEqual(subscription.effectiveAutoUpdateInterval, 21_600)
    }

    func testProviderIntervalAppliesUntilTheUserChoosesOne() throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml"))
        let following = try ProfileSubscription(url: url, providerUpdateInterval: 12 * 3_600)
        XCTAssertEqual(following.effectiveAutoUpdateInterval, 12 * 3_600)

        let chosen = try following.withAutoUpdate(interval: 24 * 3_600)
        XCTAssertEqual(chosen.effectiveAutoUpdateInterval, 24 * 3_600)
        XCTAssertEqual(chosen.isAutoUpdateIntervalCustomized, true)

        let manual = try following.withAutoUpdate(interval: nil)
        XCTAssertNil(manual.effectiveAutoUpdateInterval, "turning updates off always wins")
        XCTAssertFalse(manual.isDue(at: .distantFuture))

        let back = try manual.withAutoUpdate(interval: nil, followProvider: true)
        XCTAssertEqual(back.effectiveAutoUpdateInterval, 12 * 3_600)
        XCTAssertEqual(back.isAutoUpdateIntervalCustomized, false)
        XCTAssertEqual(back.providerUpdateInterval, 12 * 3_600)
    }

    func testFetchRecordsProviderHeadersAndKeepsThemWhenAbsent() async throws {
        let url = try XCTUnwrap(URL(string: "https://profiles.example/config.yaml"))
        let checkedAt = Date(timeIntervalSince1970: 2_000)
        var headers = [
            "Subscription-Userinfo": "upload=1; download=2; total=100; expire=1830000000",
            "Profile-Update-Interval": "12",
            "Content-Disposition": "attachment; filename=\"Edge.yaml\"",
        ]
        let profile = Data("proxies:\n  - {name: Edge, type: vmess, server: 127.0.0.1, port: 443}\nrules:\n  - MATCH,Edge\n".utf8)
        let first = ProfileSubscriptionClient(
            transport: { [headers] _ in
                ProfileSubscriptionHTTPResponse(data: profile, statusCode: 200, finalURL: url, headers: headers)
            },
            now: { checkedAt }
        )
        guard case let .updated(_, metadata, _) = try await first.fetch(try ProfileSubscription(url: url)) else {
            return XCTFail("Expected an updated profile")
        }
        XCTAssertEqual(metadata.usage?.usedBytes, 3)
        XCTAssertEqual(metadata.usage?.totalBytes, 100)
        XCTAssertEqual(metadata.usage?.reportedAt, checkedAt)
        XCTAssertEqual(metadata.providerUpdateInterval, 12 * 3_600)
        XCTAssertEqual(metadata.providerProfileName, "Edge")

        headers = [:]
        let later = Date(timeIntervalSince1970: 3_000)
        let second = ProfileSubscriptionClient(
            transport: { _ in
                ProfileSubscriptionHTTPResponse(data: Data(), statusCode: 304, finalURL: url, headers: [:])
            },
            now: { later }
        )
        guard case let .notModified(kept) = try await second.fetch(metadata) else {
            return XCTFail("Expected an unchanged profile")
        }
        XCTAssertEqual(kept.usage, metadata.usage, "a response without the header keeps the last report")
        XCTAssertEqual(kept.providerUpdateInterval, 12 * 3_600)
        XCTAssertEqual(kept.providerProfileName, "Edge")
        XCTAssertEqual(kept.lastCheckedAt, later)
    }
}

import Foundation
import XCTest
@testable import AetherRouteKit

final class BypassPolicyTests: XCTestCase {
    func testCanonicalizesDomainSuffixesWithoutBroadeningInvalidWildcards() throws {
        XCTAssertEqual(try BypassRule.parse("  *.Example.COM. ").value, "example.com")
        XCTAssertEqual(try BypassRule.parse("printer").value, "printer")
        for value in ["", ".example.com", "foo.*.example", "-bad.example", "bad_.example", "127.0.0.1"] {
            XCTAssertThrowsError(try BypassRule.parse(value)) { error in
                XCTAssertEqual(error as? BypassPolicyError, .invalidDomain, value)
            }
        }
    }

    func testCanonicalizesIPv4NetworksAndRejectsDefaultRoute() throws {
        let rule = try BypassRule.parse("192.0.2.226/24")
        XCTAssertEqual(rule.kind, .ipv4CIDR)
        XCTAssertEqual(rule.value, "192.0.2.0/24")
        for value in ["0.0.0.0/0", "10.0.0.1/33", "10.0.0.1/-1", "10.0.0.1"] {
            XCTAssertThrowsError(try BypassRule.parse(value))
        }
    }

    func testCanonicalizesIPv6NetworksAndRejectsZoneAndDefaultRoute() throws {
        let rule = try BypassRule.parse("2001:db8::1234/64")
        XCTAssertEqual(rule.kind, .ipv6CIDR)
        XCTAssertEqual(rule.value, "2001:db8::/64")
        for value in ["::/0", "fe80::1%en0/64", "2001:db8::1/129"] {
            XCTAssertThrowsError(try BypassRule.parse(value)) { error in
                XCTAssertEqual(error as? BypassPolicyError, .invalidCIDR, value)
            }
        }
    }

    func testPolicyRejectsDuplicateCanonicalRules() throws {
        let first = try BypassRule.parse("*.example.com")
        let duplicate = try BypassRule.parse("EXAMPLE.COM.")
        XCTAssertThrowsError(
            try BypassPolicy(rules: [first, duplicate]).validated()
        ) { error in
            XCTAssertEqual(error as? BypassPolicyError, .duplicateRule)
        }
    }

    func testPolicySeparatesProviderRuleKindsAndRemovesByIdentity() throws {
        let domain = try BypassRule.parse("example.com")
        let ipv4 = try BypassRule.parse("10.20.30.40/16")
        let ipv6 = try BypassRule.parse("2001:db8::9/48")
        let policy = try BypassPolicy(rules: [domain, ipv4, ipv6]).validated()
        XCTAssertEqual(policy.domains, ["example.com"])
        XCTAssertEqual(policy.ipv4CIDRs, ["10.20.0.0/16"])
        XCTAssertEqual(policy.ipv6CIDRs, ["2001:db8::/48"])
        XCTAssertEqual(policy.removing(id: ipv4.id).rules, [domain, ipv6])
    }

    func testEncryptedStoreRoundTripsAndHidesRules() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keys = InMemoryProfileKeyStore(
            keys: [
                EncryptedProfileCodec.defaultKeyID:
                    Data(repeating: 0x4A, count: 32),
            ]
        )
        let store = BypassPolicyStore(directoryURL: directory, keyStore: keys)
        let policy = try BypassPolicy(
            rules: [
                BypassRule.parse("private.example"),
                BypassRule.parse("10.50.0.9/16"),
            ]
        ).validated()

        try store.save(policy)
        XCTAssertEqual(try store.load(), policy)

        let encrypted = try Data(
            contentsOf: directory.appendingPathComponent("bypass-policy.v1.json")
        )
        let text = String(decoding: encrypted, as: UTF8.self)
        XCTAssertFalse(text.contains("private.example"))
        XCTAssertFalse(text.contains("10.50.0.0"))
    }

    func testEncryptedStoreRejectsTamperingAndWrongKey() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keyID = EncryptedProfileCodec.defaultKeyID
        let keys = InMemoryProfileKeyStore(
            keys: [keyID: Data(repeating: 0x11, count: 32)]
        )
        let store = BypassPolicyStore(directoryURL: directory, keyStore: keys)
        try store.save(
            BypassPolicy(rules: [try BypassRule.parse("example.com")])
        )

        let wrongStore = BypassPolicyStore(
            directoryURL: directory,
            keyStore: InMemoryProfileKeyStore(
                keys: [keyID: Data(repeating: 0x22, count: 32)]
            )
        )
        XCTAssertThrowsError(try wrongStore.load()) { error in
            XCTAssertEqual(error as? BypassPolicyError, .authenticationFailed)
        }

        let url = directory.appendingPathComponent("bypass-policy.v1.json")
        var data = try Data(contentsOf: url)
        data[data.index(before: data.endIndex)] ^= 0x01
        try data.write(to: url, options: [.atomic])
        XCTAssertThrowsError(try store.load())
    }

    func testNetworkSettingsPlanProducesExactRouteMasks() throws {
        let policy = try BypassPolicy(
            rules: [
                BypassRule.parse("example.com"),
                BypassRule.parse("10.20.30.40/20"),
                BypassRule.parse("100.64.0.0/10"),
                BypassRule.parse("2001:db8:1::f/48"),
            ]
        ).validated()

        let plan = try BypassNetworkSettingsPlan(policy: policy)

        XCTAssertEqual(plan.domainSuffixes, ["example.com"])
        XCTAssertEqual(
            plan.ipv4Routes,
            [
                .init(
                    destinationAddress: "10.20.16.0",
                    subnetMask: "255.255.240.0",
                    prefixLength: 20
                ),
                .init(
                    destinationAddress: "100.64.0.0",
                    subnetMask: "255.192.0.0",
                    prefixLength: 10
                ),
            ]
        )
        XCTAssertEqual(
            plan.ipv6Routes,
            [
                .init(
                    destinationAddress: "2001:db8:1::",
                    prefixLength: 48
                ),
            ]
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "BypassPolicyTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

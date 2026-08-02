import Foundation
import XCTest
@testable import AetherRouteKit

final class DNSRuntimePolicyTests: XCTestCase {
    func testDefaultsToFullyInheritedPolicy() {
        XCTAssertTrue(DNSRuntimePolicy().isInherited)
        XCTAssertEqual(DNSRuntimeResolutionMode.allCases.count, 4)
        XCTAssertEqual(DNSRuntimeBoolean.allCases.count, 3)
    }

    func testStoreBindsPolicyToExactProfileWithoutPersistingYAML() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DNSRuntimePolicyStore(directoryURL: directory)
        let profile = "dns:\n  enable: true\n  nameserver: [1.1.1.1]\n"
        let policy = DNSRuntimePolicy(
            resolutionMode: .fakeIP,
            ipv6: .disabled,
            respectsRules: .enabled
        )

        try store.save(policy, forProfileYAML: profile)

        XCTAssertEqual(try store.load(forProfileYAML: profile), policy)
        XCTAssertEqual(
            try store.load(forProfileYAML: profile + "# refreshed\n"),
            .inherited
        )
        let data = try Data(
            contentsOf: directory.appendingPathComponent(
                "dns-runtime-policy.v1.json"
            )
        )
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("nameserver"))
        XCTAssertFalse(text.contains("1.1.1.1"))
    }

    func testStoreRejectsMalformedAndOversizedPayloads() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("dns-runtime-policy.v1.json")
        let store = DNSRuntimePolicyStore(directoryURL: directory)

        try Data("{}".utf8).write(to: url)
        XCTAssertThrowsError(try store.load(forProfileYAML: "profile")) {
            XCTAssertEqual($0 as? DNSRuntimePolicyError, .decodingFailed)
        }

        try Data(
            repeating: 0x41,
            count: DNSRuntimePolicyStore.maximumFileBytes + 1
        ).write(to: url)
        XCTAssertThrowsError(try store.load(forProfileYAML: "profile")) {
            XCTAssertEqual(
                $0 as? DNSRuntimePolicyError,
                .fileTooLarge(DNSRuntimePolicyStore.maximumFileBytes + 1)
            )
        }
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "DNSRuntimePolicyTests-\(UUID().uuidString)",
            isDirectory: true
        )
    }
}

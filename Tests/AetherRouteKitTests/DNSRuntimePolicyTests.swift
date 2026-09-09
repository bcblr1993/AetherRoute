import Foundation
import XCTest
@testable import AetherRouteKit

final class DNSRuntimePolicyTests: XCTestCase {
    func testDefaultsToFullyInheritedPolicy() {
        XCTAssertTrue(DNSRuntimePolicy().isInherited)
        XCTAssertEqual(DNSRuntimeResolutionMode.allCases.count, 4)
        XCTAssertEqual(DNSRuntimeBoolean.allCases.count, 3)
    }

    func testPacketTunnelCompatibilityDefaultUsesFakeIPForNormalDNS() {
        XCTAssertEqual(
            DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                for: DNSConfigurationSummary(
                    isPresent: true,
                    isEnabled: true,
                    allowsIPv6: true,
                    mode: .fakeIP
                )
            ),
            DNSRuntimePolicy(ipv6: .disabled)
        )
        XCTAssertEqual(
            DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                for: DNSConfigurationSummary(
                    isPresent: true,
                    isEnabled: true,
                    allowsIPv6: false,
                    mode: .fakeIP
                )
            ),
            .inherited
        )
        XCTAssertEqual(
            DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                for: DNSConfigurationSummary(
                    isPresent: true,
                    isEnabled: true,
                    allowsIPv6: true,
                    mode: .normal
                )
            ),
            DNSRuntimePolicy(
                resolutionMode: .fakeIP,
                ipv6: .disabled
            )
        )
        XCTAssertEqual(
            DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                for: DNSConfigurationSummary(
                    isPresent: true,
                    isEnabled: true,
                    allowsIPv6: false,
                    mode: .normal
                )
            ),
            DNSRuntimePolicy(
                resolutionMode: .fakeIP,
                ipv6: .disabled
            )
        )
        XCTAssertEqual(
            DNSRuntimePolicy.packetTunnelCompatibilityDefault(
                for: DNSConfigurationSummary(
                    isPresent: true,
                    isEnabled: false,
                    allowsIPv6: true,
                    mode: .normal
                )
            ),
            DNSRuntimePolicy(
                resolutionMode: .fakeIP,
                ipv6: .disabled
            )
        )
    }

    func testMissingAndDisabledDNSUseCompatiblePacketTunnelDefaults() {
        for yaml in [
            "proxies: []\nrules:\n  - MATCH,DIRECT\n",
            "dns:\n  enable: false\n  ipv6: true\n  enhanced-mode: fake-ip\n",
        ] {
            let summary = ProfileConfigurationInspector.inspect(yaml: yaml)
            let dns = summary.dns
            XCTAssertFalse(dns.isEnabled)
            let policy = DNSRuntimePolicy.packetTunnelCompatibilityDefault(for: dns)
            XCTAssertEqual(policy.resolutionMode, .fakeIP)
            XCTAssertEqual(policy.ipv6, .disabled)
            XCTAssertEqual(policy.effectivePacketTunnelResolutionMode(for: dns), .fakeIP)
            XCTAssertFalse(policy.effectivePacketTunnelAllowsIPv6(
                for: dns, profileAllowsIPv6: summary.allowsIPv6
            ))
        }
    }

    func testExplicitInheritedPolicyShowsTheCoreDefaultForDisabledDNS() {
        let summary = ProfileConfigurationInspector.inspect(yaml: """
            dns:
              enable: false
              enhanced-mode: fake-ip
              ipv6: true
            """)
        let dns = summary.dns
        XCTAssertEqual(dns.mode, .fakeIP)
        XCTAssertEqual(
            DNSRuntimePolicy.inherited.effectivePacketTunnelResolutionMode(for: dns),
            .normal
        )
        XCTAssertFalse(
            DNSRuntimePolicy.inherited.effectivePacketTunnelAllowsIPv6(
                for: dns, profileAllowsIPv6: summary.allowsIPv6
            )
        )
        XCTAssertTrue(
            DNSRuntimePolicy.inherited.effectivePacketTunnelAllowsIPv6(
                for: dns, profileAllowsIPv6: true
            )
        )
        XCTAssertEqual(
            DNSRuntimePolicy.inherited.effectivePacketTunnelResolutionMode(
                for: DNSConfigurationSummary()
            ),
            .normal
        )
    }

    func testEnabledProfileDNSAndExplicitRuntimeChoicesRemainAccurate() {
        let dns = DNSConfigurationSummary(
            isPresent: true, isEnabled: true, allowsIPv6: true, mode: .redirHost
        )
        XCTAssertEqual(
            DNSRuntimePolicy.inherited.effectivePacketTunnelResolutionMode(for: dns),
            .redirHost
        )
        XCTAssertTrue(DNSRuntimePolicy.inherited.effectivePacketTunnelAllowsIPv6(
            for: dns, profileAllowsIPv6: true
        ))
        let explicit = DNSRuntimePolicy(resolutionMode: .normal, ipv6: .disabled)
        XCTAssertEqual(explicit.effectivePacketTunnelResolutionMode(for: dns), .normal)
        XCTAssertFalse(explicit.effectivePacketTunnelAllowsIPv6(
            for: dns, profileAllowsIPv6: true
        ))
        XCTAssertTrue(DNSRuntimePolicy(ipv6: .enabled).effectivePacketTunnelAllowsIPv6(
            for: dns, profileAllowsIPv6: false
        ))
    }

    func testStorePreservesExplicitChoicesForProfileWithoutDNS() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DNSRuntimePolicyStore(directoryURL: directory)
        let profile = "proxies: []\nrules:\n  - MATCH,DIRECT\n"
        XCTAssertNil(try store.loadIfPresent(forProfileYAML: profile))
        for choice in [
            DNSRuntimePolicy.inherited,
            DNSRuntimePolicy(resolutionMode: .normal, ipv6: .enabled),
        ] {
            try store.save(choice, forProfileYAML: profile)
            XCTAssertEqual(try store.loadIfPresent(forProfileYAML: profile), choice)
        }
    }

    func testLoadIfPresentDistinguishesMissingFromExplicitInheritedChoice()
        throws
    {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DNSRuntimePolicyStore(directoryURL: directory)
        let profile = "dns:\n  enable: true\n  ipv6: true\n  enhanced-mode: fake-ip\n"

        XCTAssertNil(try store.loadIfPresent(forProfileYAML: profile))
        XCTAssertEqual(try store.load(forProfileYAML: profile), .inherited)

        try store.save(.inherited, forProfileYAML: profile)
        XCTAssertEqual(
            try store.loadIfPresent(forProfileYAML: profile),
            .inherited
        )
        XCTAssertNil(
            try store.loadIfPresent(forProfileYAML: profile + "# refreshed\n")
        )
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

import Foundation
import XCTest
@testable import AetherRouteKit

final class CertificateTrustOptionTests: XCTestCase {
    private let pin = Array(repeating: "AB", count: 32).joined(separator: ":")
    private let normalizedPin = String(repeating: "ab", count: 32)

    func testNodesSavedBeforeCertificatePinningStillDecode() throws {
        let node = AetherNode(
            name: "Old",
            protocolID: .trojan,
            server: "edge.example",
            port: 443,
            password: "secret",
            tls: AetherNodeTLS(serverName: "edge.example")
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(node)) as? [String: Any]
        )
        var tls = try XCTUnwrap(object["tls"] as? [String: Any])
        tls.removeValue(forKey: "certificateFingerprint")
        object["tls"] = tls
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(AetherNode.self, from: legacy)
        XCTAssertEqual(decoded.tls.certificateFingerprint, "")
        XCTAssertEqual(decoded, node)
    }

    func testPinnedNodeCompilesANormalizedFingerprint() throws {
        let node = AetherNode(
            name: "Pinned",
            protocolID: .trojan,
            server: "edge.example",
            port: 443,
            password: "secret",
            tls: AetherNodeTLS(serverName: "edge.example", certificateFingerprint: pin)
        )
        let yaml = try AetherNodeProfileCompiler.compile(node: node)
        XCTAssertTrue(yaml.contains("fingerprint: '\(normalizedPin)'"), yaml)
        XCTAssertTrue(yaml.contains("skip-cert-verify: false"))
    }

    func testFingerprintValidationFollowsWhereAPinApplies() throws {
        func node(
            _ protocolID: AetherNodeProtocol,
            tls: AetherNodeTLS
        ) -> AetherNode {
            AetherNode(
                name: "Node",
                protocolID: protocolID,
                server: "edge.example",
                port: 443,
                password: "secret",
                uuid: "11111111-2222-3333-4444-555555555555",
                cipher: "aes-128-gcm",
                tls: tls
            )
        }
        XCTAssertNoThrow(
            try node(.vmess, tls: AetherNodeTLS(enabled: true, certificateFingerprint: pin))
                .validated()
        )
        XCTAssertNoThrow(
            try node(.hysteria2, tls: AetherNodeTLS(certificateFingerprint: normalizedPin))
                .validated()
        )
        let invalid = AetherNodeValidationError.invalidField("Certificate fingerprint")
        for rejected in [
            node(.trojan, tls: AetherNodeTLS(certificateFingerprint: "abc")),
            // Without TLS there is no certificate to pin.
            node(.http, tls: AetherNodeTLS(enabled: false, certificateFingerprint: pin)),
            node(.shadowsocks, tls: AetherNodeTLS(certificateFingerprint: pin)),
            // REALITY borrows another site's certificate.
            node(.vless, tls: AetherNodeTLS(
                enabled: true,
                serverName: "edge.example",
                realityPublicKey: "ignored",
                certificateFingerprint: pin
            )),
        ] {
            XCTAssertThrowsError(try rejected.validateCertificateFingerprint()) {
                XCTAssertEqual($0 as? AetherNodeValidationError, invalid)
            }
        }
    }

    func testHysteria2ShareLinkKeepsItsPinnedCertificate() throws {
        let link = "hysteria2://secret@127.0.0.1:8443?sni=edge.example&pinSHA256=\(pin)#HY2"
        let output = try SubscriptionPayloadNormalizer.normalize(Data(link.utf8))
        let yaml = try XCTUnwrap(String(data: output, encoding: .utf8))
        XCTAssertTrue(yaml.contains("fingerprint: '\(normalizedPin)'"), yaml)
    }

    func testReadableCAFilesAreInlinedAndUnreadableOnesReported() throws {
        let certificate = """
        -----BEGIN CERTIFICATE-----
        MIIBszCCAVmgAwIBAgIUTEST
        -----END CERTIFICATE-----
        """
        let directory = URL(fileURLWithPath: "/profiles", isDirectory: true)
        let files = [
            "/profiles/certs/ca.pem": certificate,
            "/etc/ca.pem": certificate,
            "/profiles/notes.txt": "not a certificate",
        ]
        let profile = """
        proxies:
          - name: relative
            type: hysteria2
            ca: certs/ca.pem
          - name: absolute
            type: tuic
            ca: "/etc/ca.pem"
          - name: missing
            type: hysteria2
            ca: /nowhere/ca.pem # comment
          - name: not-pem
            type: tuic
            ca: notes.txt
          - name: inline
            type: hysteria2
            ca-str: |
              -----BEGIN CERTIFICATE-----
          - {name: flow, type: hysteria2, ca: flow.pem}
        """

        let outcome = ProfileCertificateAuthorityInliner.inline(
            Data(profile.utf8),
            relativeTo: directory,
            readFile: { url in
                guard let text = files[url.path] else {
                    throw CocoaError(.fileReadNoPermission)
                }
                return Data(text.utf8)
            }
        )
        let yaml = try XCTUnwrap(String(data: outcome.data, encoding: .utf8))

        XCTAssertEqual(outcome.unreadablePaths, ["/nowhere/ca.pem", "notes.txt"])
        XCTAssertFalse(yaml.contains("ca: certs/ca.pem"))
        XCTAssertFalse(yaml.contains("ca: \"/etc/ca.pem\""))
        // Two inlined files plus the profile's own ca-str block.
        XCTAssertEqual(yaml.components(separatedBy: "    ca-str: |\n      -----BEGIN CERTIFICATE-----").count - 1, 3)
        XCTAssertTrue(yaml.contains("      MIIBszCCAVmgAwIBAgIUTEST"))
        // Unreadable paths, inline PEM and flow mappings stay as written.
        XCTAssertTrue(yaml.contains("    ca: /nowhere/ca.pem # comment"))
        XCTAssertTrue(yaml.contains("    ca: notes.txt"))
        XCTAssertTrue(yaml.contains("{name: flow, type: hysteria2, ca: flow.pem}"))
    }

    func testProfilesWithoutCAAreReturnedUnchanged() {
        let data = Data("proxies:\n  - {name: Edge, type: direct}\n".utf8)
        let outcome = ProfileCertificateAuthorityInliner.inline(data, relativeTo: nil)
        XCTAssertEqual(outcome.data, data)
        XCTAssertTrue(outcome.unreadablePaths.isEmpty)
    }
}

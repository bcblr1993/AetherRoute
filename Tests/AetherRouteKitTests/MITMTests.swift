import Foundation
import Security
import XCTest
@testable import AetherRouteKit

final class MITMTests: XCTestCase {
    private final class InMemoryCAStore: @unchecked Sendable {
        var data: Data?
    }

    func testCADefaultGenerationPersistsECDSAP256RootAndExportsValidPEMAndDER() throws {
        let box = InMemoryCAStore()
        let authority = MITMCertificateAuthority(
            read: { box.data },
            write: { box.data = $0 },
            delete: { box.data = nil }
        )

        XCTAssertFalse(authority.hasCertificate())
        let generated = try authority.loadOrCreateCA()
        XCTAssertTrue(authority.hasCertificate())
        XCTAssertTrue(generated.certificatePEM.contains("-----BEGIN CERTIFICATE-----"))
        XCTAssertTrue(generated.certificatePEM.contains("-----END CERTIFICATE-----"))
        XCTAssertTrue(generated.privateKeyPKCS8PEM.contains("-----BEGIN PRIVATE KEY-----"))
        XCTAssertTrue(generated.privateKeyPKCS8PEM.contains("-----END PRIVATE KEY-----"))
        XCTAssertFalse(generated.sha256Fingerprint.isEmpty)

        // Verify Security.framework parses the generated X.509 v3 certificate cleanly.
        let secCert = SecCertificateCreateWithData(nil, generated.certificateDER as CFData)
        XCTAssertNotNil(secCert)

        // Reload returns identical keypair & certificate without rotating.
        let reloaded = try authority.loadOrCreateCA()
        XCTAssertEqual(reloaded, generated)

        // Regenerate replaces CA with a brand-new keypair & certificate.
        let rotated = try authority.regenerateCA()
        XCTAssertNotEqual(rotated.sha256Fingerprint, generated.sha256Fingerprint)
        XCTAssertNotEqual(rotated.certificateDER, generated.certificateDER)

        try authority.deleteCA()
        XCTAssertFalse(authority.hasCertificate())
    }

    func testMITMConfigurationDefaultsValidationAndSerialization() throws {
        let cfg = MITMConfiguration()
        XCTAssertFalse(cfg.isEnabled)
        XCTAssertTrue(cfg.hostPatterns.isEmpty)
        XCTAssertTrue(cfg.bypassHosts.contains("*.apple.com"))
        XCTAssertTrue(cfg.urlRewrites.isEmpty)
        XCTAssertTrue(cfg.headerBodyRewrites.isEmpty)
        XCTAssertTrue(cfg.scripts.isEmpty)

        XCTAssertThrowsError(
            try MITMConfiguration(
                isEnabled: true,
                hostPatterns: ["valid.example.com"],
                urlRewrites: [
                    MITMURLRewriteRule(
                        pattern: "[unclosed-regex",
                        replacement: "https://example.com",
                        mode: .redirect302,
                        isEnabled: true
                    )
                ]
            ).validated()
        ) { error in
            XCTAssertEqual(error as? MITMConfigurationError, .invalidRegex("[unclosed-regex"))
        }

        let valid = try MITMConfiguration(
            isEnabled: true,
            hostPatterns: ["*.example.com", "api.test.local"],
            urlRewrites: [
                MITMURLRewriteRule(
                    pattern: "^https://old\\.example\\.com/(.*)$",
                    replacement: "https://new.example.com/$1",
                    mode: .redirect302,
                    isEnabled: true
                )
            ],
            headerBodyRewrites: [
                MITMHeaderBodyRewriteRule(
                    scope: .requestHeader,
                    urlPattern: "^https://api\\.test\\.local/.*",
                    headerName: "User-Agent",
                    pattern: "^.*$",
                    replacement: "AetherRoute/3.2",
                    isEnabled: true
                )
            ],
            scripts: [
                MITMJSScriptRule(
                    name: "Inject Header",
                    hook: .httpRequest,
                    urlPattern: "^https://api\\.test\\.local/.*",
                    scriptBody: "$request.headers['X-Test'] = '1'; $done({ headers: $request.headers });",
                    timeoutMs: 500,
                    isEnabled: true
                )
            ]
        ).validated()

        let encoded = try JSONEncoder().encode(valid)
        let decoded = try JSONDecoder().decode(MITMConfiguration.self, from: encoded)
        XCTAssertEqual(decoded, valid)
    }

    func testHTTPCaptureFormatsShellSafeCurlCommand() {
        let capture = MITMHTTPCaptureEntry(
            id: 7,
            timestampUnixMs: 1_795_400_000_000,
            method: "POST",
            url: "https://api.example.com/v1/items?a=1&b='quoted'",
            host: "api.example.com",
            statusCode: 200,
            durationMs: 28,
            requestHeaders: [
                "Content-Type": "application/json",
                "X-Custom": "hello'world",
            ],
            responseHeaders: ["Content-Type": "application/json"],
            requestBodyPreview: "{\"k\":\"v's\"}",
            responseBodyPreview: "{\"ok\":true}",
            appliedRules: ["header-rewrite"]
        )

        let curl = capture.cURLCommand()
        XCTAssertTrue(curl.hasPrefix("curl -X POST "))
        XCTAssertTrue(curl.contains("'https://api.example.com/v1/items?a=1&b='\"'\"'quoted'\"'\"''"))
        XCTAssertTrue(curl.contains("-H 'Content-Type: application/json'"))
        XCTAssertTrue(curl.contains("-H 'X-Custom: hello'\"'\"'world'"))
        XCTAssertTrue(curl.contains("--data-raw '{\"k\":\"v'\"'\"'s\"}'"))
    }

    func testKeychainBaseQueryUsesDataProtectionKeychainAndLocalOnly() {
        let query = MITMCertificateAuthority.keychainBaseQuery(
            service: MITMCertificateAuthority.defaultService,
            account: MITMCertificateAuthority.defaultAccount
        )
        XCTAssertEqual(query[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(query[kSecAttrService as String] as? String, MITMCertificateAuthority.defaultService)
        XCTAssertEqual(query[kSecAttrAccount as String] as? String, MITMCertificateAuthority.defaultAccount)
        XCTAssertEqual(query[kSecUseDataProtectionKeychain as String] as? Bool, true)
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false)
    }
}

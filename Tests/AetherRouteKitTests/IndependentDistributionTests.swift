import CryptoKit
import Foundation
import XCTest
@testable import AetherRouteKit

final class IndependentDistributionTests: XCTestCase {
    @TaskLocal private static var updateCommitCallerMarker = false

    private let productID = "com.example.aetherroute"
    private let licenseURL = URL(string: "https://license.example/v1/license")!
    private let updateURL = URL(string: "https://updates.example/stable.json")!
    private let deviceID = "11111111-2222-3333-4444-555555555555"

    func testConnectionAccessFailsClosedOutsideDevelopmentAndActiveReceipt() {
        XCTAssertTrue(
            DistributionConnectionAccess.unrestrictedDevelopment
                .permitsNewConnection
        )
        XCTAssertTrue(
            DistributionConnectionAccess.authorized.permitsNewConnection
        )
        XCTAssertFalse(
            DistributionConnectionAccess.activationRequired
                .permitsNewConnection
        )
        XCTAssertFalse(
            DistributionConnectionAccess.restricted(.expired)
                .permitsNewConnection
        )
        XCTAssertFalse(
            DistributionConnectionAccess.restricted(.revoked)
                .permitsNewConnection
        )
        XCTAssertFalse(
            DistributionConnectionAccess.restricted(.deviceLimit)
                .permitsNewConnection
        )
        XCTAssertFalse(
            DistributionConnectionAccess.restricted(.active)
                .permitsNewConnection
        )
        XCTAssertFalse(
            DistributionConnectionAccess.verificationUnavailable
                .permitsNewConnection
        )
    }

    func testExpiredActiveReceiptCannotAuthorizeConnection() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try configuration(privateKey)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entitlement = LicenseEntitlement(
            productID: productID,
            licenseID: "license-expired",
            deviceID: deviceID,
            state: .active,
            issuedAt: now.addingTimeInterval(-7_200),
            expiresAt: now.addingTimeInterval(-3_600)
        )
        let receipt = try signedEnvelope(
            encoded(entitlement),
            privateKey: privateKey
        )
        let client = try IndependentDistributionClient(
            configuration: configuration,
            transport: { _ in
                XCTFail("Receipt verification must not perform network I/O")
                throw IndependentDistributionError.invalidHTTPResponse
            },
            now: { now }
        )

        XCTAssertThrowsError(
            try client.verifiedEntitlement(
                from: receipt,
                deviceID: deviceID
            )
        ) { error in
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .expiredEntitlement
            )
        }
    }

    func testConfigurationRejectsUnsafeEndpointsAndInvalidKey() throws {
        let key = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
        XCTAssertThrowsError(
            try IndependentDistributionConfiguration(
                productID: productID,
                licenseServiceURL: URL(string: "http://license.example/v1")!,
                updateManifestURL: updateURL,
                signingPublicKeyBase64: key.base64EncodedString()
            )
        ) { error in
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .invalidServiceURL
            )
        }
        XCTAssertThrowsError(
            try IndependentDistributionConfiguration(
                productID: productID,
                licenseServiceURL: licenseURL,
                updateManifestURL: updateURL,
                signingPublicKeyBase64: Data(repeating: 1, count: 31)
                    .base64EncodedString()
            )
        ) { error in
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .invalidPublicKey
            )
        }
    }

    func testSignedEnvelopeRejectsTampering() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let payload = Data("{\"value\":1}".utf8)
        var envelope = try signedEnvelope(payload, privateKey: privateKey)
        envelope[envelope.startIndex] ^= 1
        let verifier = try DistributionSignatureVerifier(
            publicKey: privateKey.publicKey.rawRepresentation
        )
        XCTAssertThrowsError(try verifier.verifiedPayload(from: envelope))
    }

    func testUpdateCheckAcceptsOnlySignedMatchingArm64Manifest() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try configuration(privateKey)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let manifest = SoftwareUpdateManifest(
            productID: productID,
            version: "1.2.0",
            build: 120,
            publishedAt: now,
            minimumSystemVersion: "15.0",
            downloadURL: URL(string: "https://updates.example/AetherRoute-1.2.0.dmg")!,
            sha256: String(repeating: "a", count: 64),
            releaseNotesURL: URL(string: "https://updates.example/1.2.0")!
        )
        let responseData = try signedEnvelope(
            encoded(manifest),
            privateKey: privateKey
        )
        let expectedUpdateURL = updateURL
        let client = try IndependentDistributionClient(
            configuration: configuration,
            transport: { request in
                XCTAssertEqual(request.method, .get)
                XCTAssertEqual(request.url, expectedUpdateURL)
                return DistributionHTTPResponse(
                    data: responseData,
                    statusCode: 200,
                    finalURL: expectedUpdateURL
                )
            },
            now: { now }
        )

        guard case let .available(value) = try await client.checkForUpdates(
            currentBuild: 100
        ) else {
            return XCTFail("Expected an available update")
        }
        XCTAssertEqual(value, manifest)
        guard case .current = try await client.checkForUpdates(currentBuild: 120)
        else {
            return XCTFail("Expected the current build")
        }
    }

    func testLicenseActivationVerifiesProductDeviceAndSignedReceipt() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try configuration(privateKey)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entitlement = LicenseEntitlement(
            productID: productID,
            licenseID: "license-001",
            deviceID: deviceID,
            state: .active,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(30 * 24 * 60 * 60)
        )
        let receipt = try signedEnvelope(
            encoded(entitlement),
            privateKey: privateKey
        )
        let expectedLicenseURL = licenseURL
        let expectedDeviceID = deviceID
        let client = try IndependentDistributionClient(
            configuration: configuration,
            transport: { request in
                XCTAssertEqual(request.method, .post)
                XCTAssertEqual(request.url, expectedLicenseURL)
                let body = try XCTUnwrap(request.body)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(with: body) as? [String: Any]
                )
                XCTAssertEqual(object["action"] as? String, "activate")
                XCTAssertEqual(object["licenseKey"] as? String, "AAAA-BBBB-CCCC")
                XCTAssertTrue(object["signedReceipt"] is NSNull)
                XCTAssertEqual(
                    Set(object.keys),
                    Set([
                        "schemaVersion", "action", "productID", "deviceID",
                        "appVersion", "appBuild", "licenseKey", "signedReceipt",
                    ])
                )
                XCTAssertEqual(object["deviceID"] as? String, expectedDeviceID)
                return DistributionHTTPResponse(
                    data: receipt,
                    statusCode: 200,
                    finalURL: expectedLicenseURL
                )
            },
            now: { now }
        )

        let result = try await client.activateLicense(
            key: "AAAA-BBBB-CCCC",
            deviceID: deviceID,
            appVersion: "1.0",
            appBuild: "1"
        )
        XCTAssertEqual(result.entitlement, entitlement)
        XCTAssertEqual(result.signedReceipt, receipt)
        XCTAssertThrowsError(
            try client.verifiedEntitlement(
                from: receipt,
                deviceID: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
            )
        ) { error in
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .invalidEntitlement
            )
        }
    }

    func testRefreshAndDeactivateEncodeExplicitNullLicenseKey() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try configuration(privateKey)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let entitlement = LicenseEntitlement(
            productID: productID,
            licenseID: "license-wire-contract",
            deviceID: deviceID,
            state: .active,
            issuedAt: now
        )
        let receipt = try signedEnvelope(
            encoded(entitlement),
            privateKey: privateKey
        )
        let expectedReceipt = receipt.base64EncodedString()
        let expectedLicenseURL = licenseURL
        let client = try IndependentDistributionClient(
            configuration: configuration,
            transport: { request in
                XCTAssertEqual(request.url, expectedLicenseURL)
                let object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: try XCTUnwrap(request.body)
                    ) as? [String: Any]
                )
                XCTAssertTrue(object["licenseKey"] is NSNull)
                XCTAssertEqual(object["signedReceipt"] as? String, expectedReceipt)
                switch object["action"] as? String {
                case "refresh":
                    return DistributionHTTPResponse(
                        data: receipt,
                        statusCode: 200,
                        finalURL: expectedLicenseURL
                    )
                case "deactivate":
                    return DistributionHTTPResponse(
                        data: Data(),
                        statusCode: 204,
                        finalURL: expectedLicenseURL
                    )
                default:
                    throw IndependentDistributionError.invalidPayload
                }
            },
            now: { now }
        )

        _ = try await client.refreshLicense(
            signedReceipt: receipt,
            deviceID: deviceID,
            appVersion: "1.0",
            appBuild: "1"
        )
        try await client.deactivateLicense(
            signedReceipt: receipt,
            deviceID: deviceID,
            appVersion: "1.0",
            appBuild: "1"
        )
    }

    func testRedirectAndOversizedResponsesFailClosed() async throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let configuration = try configuration(privateKey)
        let expectedUpdateURL = updateURL
        let redirected = try IndependentDistributionClient(
            configuration: configuration,
            transport: { _ in
                DistributionHTTPResponse(
                    data: Data(),
                    statusCode: 302,
                    finalURL: URL(string: "https://other.example/manifest")!
                )
            }
        )
        do {
            _ = try await redirected.checkForUpdates(currentBuild: 1)
            XCTFail("Expected redirect rejection")
        } catch {
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .redirectRejected
            )
        }

        let oversized = try IndependentDistributionClient(
            configuration: configuration,
            transport: { _ in
                DistributionHTTPResponse(
                    data: Data(
                        repeating: 1,
                        count: IndependentDistributionConfiguration
                            .maximumResponseBytes + 1
                    ),
                    statusCode: 200,
                    finalURL: expectedUpdateURL
                )
            }
        )
        do {
            _ = try await oversized.checkForUpdates(currentBuild: 1)
            XCTFail("Expected response bound rejection")
        } catch {
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .responseTooLarge(
                    IndependentDistributionConfiguration.maximumResponseBytes + 1
                )
            )
        }
    }

    func testInMemoryCredentialStoreNeverPersistsActivationKey() throws {
        let store = InMemoryDistributionCredentialStore()
        let first = try store.loadOrCreateDeviceID()
        let second = try store.loadOrCreateDeviceID()
        XCTAssertEqual(first, second)
        XCTAssertNotNil(UUID(uuidString: first))
        XCTAssertNil(try store.loadReceipt())
        let receipt = Data("signed-receipt-only".utf8)
        try store.saveReceipt(receipt)
        XCTAssertEqual(try store.loadReceipt(), receipt)
        try store.deleteReceipt()
        XCTAssertNil(try store.loadReceipt())
    }

    func testVerifiedUpdateDownloadCommitsOnlyMatchingDMG() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("transport.dmg")
        let destination = directory.appendingPathComponent("AetherRoute.dmg")
        let bytes = Data("not-a-real-dmg-but-integrity-bound".utf8)
        try bytes.write(to: source, options: .atomic)
        try Data("older-build".utf8).write(to: destination, options: .atomic)
        let expectedDownloadURL = URL(
            string: "https://updates.example/AetherRoute-1.2.0.dmg"
        )!
        let manifest = SoftwareUpdateManifest(
            productID: productID,
            version: "1.2.0",
            build: 120,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000),
            minimumSystemVersion: "15.0",
            downloadURL: expectedDownloadURL,
            sha256: sha256(bytes)
        )
        let downloader = VerifiedSoftwareUpdateDownloader { url in
            XCTAssertEqual(url, expectedDownloadURL)
            return SoftwareUpdateDownloadResponse(
                temporaryFileURL: source,
                statusCode: 200,
                finalURL: expectedDownloadURL
            )
        }

        let artifact = try await downloader.download(
            manifest: manifest,
            to: destination
        )
        XCTAssertEqual(artifact.fileURL, destination)
        XCTAssertEqual(artifact.byteCount, Int64(bytes.count))
        XCTAssertEqual(artifact.sha256, sha256(bytes))
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testVerifiedUpdateCommitUsesDetachedTaskContext() async throws {
        let downloadURL = URL(
            string: "https://updates.example/AetherRoute-1.2.0.dmg"
        )!
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("transport.dmg")
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("AetherRoute.dmg")
        let manifest = SoftwareUpdateManifest(
            productID: productID,
            version: "1.2.0",
            build: 120,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000),
            minimumSystemVersion: "15.0",
            downloadURL: downloadURL,
            sha256: String(repeating: "a", count: 64)
        )
        let downloader = VerifiedSoftwareUpdateDownloader(
            transport: { _ in
                SoftwareUpdateDownloadResponse(
                    temporaryFileURL: temporaryURL,
                    statusCode: 200,
                    finalURL: downloadURL
                )
            },
            artifactCommitter: { _, manifest, destination in
                VerifiedSoftwareUpdateArtifact(
                    fileURL: destination,
                    byteCount: Self.updateCommitCallerMarker ? 1 : 2,
                    sha256: manifest.sha256
                )
            }
        )

        let artifact = try await Self.$updateCommitCallerMarker.withValue(true) {
            try await downloader.download(
                manifest: manifest,
                to: destination
            )
        }

        XCTAssertEqual(
            artifact.byteCount,
            2,
            "DMG verification and atomic commit inherited the caller task."
        )
    }

    func testVerifiedUpdateDownloadRejectsRedirectAndHashMismatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let source = directory.appendingPathComponent("transport.dmg")
        let destination = directory.appendingPathComponent("AetherRoute.dmg")
        try Data("tampered".utf8).write(to: source, options: .atomic)
        let downloadURL = URL(
            string: "https://updates.example/AetherRoute-1.2.0.dmg"
        )!
        let manifest = SoftwareUpdateManifest(
            productID: productID,
            version: "1.2.0",
            build: 120,
            publishedAt: Date(timeIntervalSince1970: 2_000_000_000),
            minimumSystemVersion: "15.0",
            downloadURL: downloadURL,
            sha256: String(repeating: "0", count: 64)
        )

        let redirected = VerifiedSoftwareUpdateDownloader { _ in
            SoftwareUpdateDownloadResponse(
                temporaryFileURL: source,
                statusCode: 200,
                finalURL: URL(string: "https://other.example/update.dmg")!
            )
        }
        do {
            _ = try await redirected.download(
                manifest: manifest,
                to: destination
            )
            XCTFail("Expected redirect rejection")
        } catch {
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .redirectRejected
            )
        }

        let mismatched = VerifiedSoftwareUpdateDownloader { _ in
            SoftwareUpdateDownloadResponse(
                temporaryFileURL: source,
                statusCode: 200,
                finalURL: downloadURL
            )
        }
        do {
            _ = try await mismatched.download(
                manifest: manifest,
                to: destination
            )
            XCTFail("Expected SHA-256 rejection")
        } catch {
            XCTAssertEqual(
                error as? IndependentDistributionError,
                .updateArtifactHashMismatch
            )
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    private func configuration(
        _ privateKey: Curve25519.Signing.PrivateKey
    ) throws -> IndependentDistributionConfiguration {
        try IndependentDistributionConfiguration(
            productID: productID,
            licenseServiceURL: licenseURL,
            updateManifestURL: updateURL,
            signingPublicKeyBase64: privateKey.publicKey.rawRepresentation
                .base64EncodedString()
        )
    }

    private func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }

    private func signedEnvelope(
        _ payload: Data,
        privateKey: Curve25519.Signing.PrivateKey
    ) throws -> Data {
        let envelope = SignedDistributionEnvelope(
            payload: payload.base64EncodedString(),
            signature: try privateKey.signature(for: payload)
                .base64EncodedString()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

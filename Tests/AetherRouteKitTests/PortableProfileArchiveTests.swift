import Foundation
import XCTest
@testable import AetherRouteKit

final class PortableProfileArchiveTests: XCTestCase {
    private let password = "correct horse battery staple"

    func testRoundTripPreservesCatalogAndExportDate() throws {
        let codec = testCodec()
        let catalog = makeCatalog()
        let exportedAt = Date(timeIntervalSince1970: 1_800_100_000)

        let archive = try codec.seal(
            catalog: catalog,
            password: password,
            exportedAt: exportedAt
        )
        let payload = try codec.open(archive, password: password)

        XCTAssertEqual(payload.catalog, catalog)
        XCTAssertEqual(payload.exportedAt, exportedAt)
        XCTAssertEqual(
            payload.formatVersion,
            PortableProfileArchivePayload.currentFormatVersion
        )
    }

    func testCiphertextDoesNotExposeProfilesOrPassword() throws {
        let codec = testCodec()
        let archive = try codec.seal(
            catalog: makeCatalog(),
            password: password
        )
        let text = try XCTUnwrap(String(data: archive, encoding: .utf8))

        XCTAssertFalse(text.contains("Portable Office"))
        XCTAssertFalse(text.contains("portable.example"))
        XCTAssertFalse(text.contains("PORTABLE-SECRET"))
        XCTAssertFalse(text.contains(password))
        XCTAssertTrue(text.contains("PBKDF2-HMAC-SHA256"))
        XCTAssertTrue(text.contains("AES-256-GCM"))
    }

    func testWrongPasswordAndTamperingAreRejectedUniformly() throws {
        let codec = testCodec()
        let archive = try codec.seal(
            catalog: makeCatalog(),
            password: password
        )

        XCTAssertThrowsError(
            try codec.open(
                archive,
                password: "incorrect archive password"
            )
        ) { error in
            XCTAssertEqual(
                error as? PortableProfileArchiveError,
                .authenticationFailed
            )
        }

        let tampered = try mutateArchive(archive, field: "sealedBox") {
            var data = $0
            data[data.startIndex] ^= 0x01
            return data
        }
        XCTAssertThrowsError(
            try codec.open(tampered, password: password)
        ) { error in
            XCTAssertEqual(
                error as? PortableProfileArchiveError,
                .authenticationFailed
            )
        }
    }

    func testHeaderIsAuthenticated() throws {
        let codec = testCodec()
        let archive = try codec.seal(
            catalog: makeCatalog(),
            password: password
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: archive) as? [String: Any]
        )
        object["iterations"] = 100_001
        let tampered = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(
            try codec.open(tampered, password: password)
        ) { error in
            XCTAssertEqual(
                error as? PortableProfileArchiveError,
                .authenticationFailed
            )
        }
    }

    func testRequiresLongPasswordAndRejectsOversizedInputEarly() throws {
        let codec = testCodec()
        XCTAssertThrowsError(
            try codec.seal(catalog: makeCatalog(), password: "too short")
        ) { error in
            XCTAssertEqual(
                error as? PortableProfileArchiveError,
                .weakPassword(
                    PortableProfileArchiveCodec.minimumPasswordCharacters
                )
            )
        }

        let oversized = Data(
            count: PortableProfileArchiveCodec.maximumArchiveBytes + 1
        )
        XCTAssertThrowsError(
            try codec.open(oversized, password: password)
        ) { error in
            XCTAssertEqual(
                error as? PortableProfileArchiveError,
                .archiveTooLarge(oversized.count)
            )
        }
    }

    func testCanonicalEquivalentPasswordsOpenTheSameArchive() throws {
        let codec = testCodec()
        let decomposed = "portable-pass-e\u{301}-2026"
        let composed = "portable-pass-é-2026"
        let archive = try codec.seal(
            catalog: makeCatalog(),
            password: decomposed
        )

        XCTAssertEqual(
            try codec.open(archive, password: composed).catalog,
            makeCatalog()
        )
    }

    private func testCodec() -> PortableProfileArchiveCodec {
        PortableProfileArchiveCodec(
            iterationCount: 100_000,
            randomBytes: { count in Data(repeating: 0x5A, count: count) }
        )
    }

    private func makeCatalog() -> ProfileCatalog {
        let managed = ManagedProfile(
            id: UUID(uuidString: "7B234946-8A3D-4AC6-8C6A-79C5C4F17641")!,
            profile: ActiveProfile(
                name: "Portable Office",
                yaml: """
                proxies:
                  - name: private
                    type: trojan
                    server: portable.example
                    port: 443
                    password: PORTABLE-SECRET
                """,
                importedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
        return ProfileCatalog(
            activeProfileID: managed.id,
            profiles: [managed]
        )
    }

    private func mutateArchive(
        _ archive: Data,
        field: String,
        mutation: (Data) -> Data
    ) throws -> Data {
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: archive) as? [String: Any]
        )
        let encoded = try XCTUnwrap(object[field] as? String)
        let value = try XCTUnwrap(Data(base64Encoded: encoded))
        object[field] = mutation(value).base64EncodedString()
        return try JSONSerialization.data(withJSONObject: object)
    }
}

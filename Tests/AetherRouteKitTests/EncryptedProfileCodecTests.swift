import Foundation
import XCTest
@testable import AetherRouteKit

final class EncryptedProfileCodecTests: XCTestCase {
    func testAADPurposeMismatchFailsAuthentication() throws {
        let key = Data(repeating: 0x31, count: 32)
        let writer = EncryptedProfileCodec()
        let reader = EncryptedProfileCodec(purpose: "AetherRoute.OtherPurpose")
        let encrypted = try writer.seal(profile, keyData: key)

        XCTAssertThrowsError(try reader.open(encrypted, keyData: key)) { error in
            XCTAssertEqual(
                error as? EncryptedProfileCodecError,
                .authenticationFailed
            )
        }
    }

    func testAADKeyIDMismatchFailsAuthentication() throws {
        let key = Data(repeating: 0x52, count: 32)
        let writer = EncryptedProfileCodec()
        let encrypted = try writer.seal(profile, keyData: key)
        var envelope = try JSONDecoder().decode(
            EncryptedProfileEnvelope.self,
            from: encrypted
        )
        envelope = EncryptedProfileEnvelope(
            formatVersion: envelope.formatVersion,
            algorithm: envelope.algorithm,
            keyID: "profile-master-key.v2",
            sealedBox: envelope.sealedBox
        )
        let relabeled = try JSONEncoder().encode(envelope)
        let reader = EncryptedProfileCodec(keyID: "profile-master-key.v2")

        XCTAssertThrowsError(try reader.open(relabeled, keyData: key)) { error in
            XCTAssertEqual(
                error as? EncryptedProfileCodecError,
                .authenticationFailed
            )
        }
    }

    func testEnvelopeRejectsUnsupportedVersionBeforeDecryption() throws {
        let key = Data(repeating: 0x73, count: 32)
        let codec = EncryptedProfileCodec()
        let encrypted = try codec.seal(profile, keyData: key)
        let original = try JSONDecoder().decode(
            EncryptedProfileEnvelope.self,
            from: encrypted
        )
        let unsupported = EncryptedProfileEnvelope(
            formatVersion: 99,
            algorithm: original.algorithm,
            keyID: original.keyID,
            sealedBox: original.sealedBox
        )

        XCTAssertThrowsError(
            try codec.open(JSONEncoder().encode(unsupported), keyData: key)
        ) { error in
            XCTAssertEqual(
                error as? EncryptedProfileCodecError,
                .unsupportedFormat(99)
            )
        }
    }

    private var profile: ActiveProfile {
        ActiveProfile(
            name: "AAD",
            yaml: "proxies:\n  - { name: direct, type: direct }\n"
        )
    }
}

import CryptoKit
import Foundation

struct EncryptedProfileEnvelope: Codable, Equatable, Sendable {
    let formatVersion: Int
    let algorithm: String
    let keyID: String
    var sealedBox: Data
}

struct EncryptedProfileCodec: Sendable {
    static let currentFormatVersion = 2
    static let algorithm = "AES-256-GCM"
    static let defaultKeyID = "profile-master-key.v1"
    static let defaultPurpose = "AetherRoute.ActiveProfile"

    let keyID: String
    private let purpose: String

    init(
        purpose: String = Self.defaultPurpose,
        keyID: String = Self.defaultKeyID
    ) {
        self.purpose = purpose
        self.keyID = keyID
    }

    func seal(_ profile: ActiveProfile, keyData: Data) throws -> Data {
        let key = try symmetricKey(from: keyData)
        let plaintext: Data
        do {
            plaintext = try Self.profileEncoder.encode(profile)
        } catch {
            throw EncryptedProfileCodecError.profileEncodingFailed
        }

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.seal(
                plaintext,
                using: key,
                authenticating: authenticatedData(keyID: keyID)
            )
        } catch {
            throw EncryptedProfileCodecError.encryptionFailed
        }
        guard let combined = sealedBox.combined else {
            throw EncryptedProfileCodecError.encryptionFailed
        }

        let envelope = EncryptedProfileEnvelope(
            formatVersion: Self.currentFormatVersion,
            algorithm: Self.algorithm,
            keyID: keyID,
            sealedBox: combined
        )
        do {
            return try Self.envelopeEncoder.encode(envelope)
        } catch {
            throw EncryptedProfileCodecError.envelopeEncodingFailed
        }
    }

    func open(_ envelopeData: Data, keyData: Data) throws -> ActiveProfile {
        let envelope = try decodeEnvelope(envelopeData)
        let key = try symmetricKey(from: keyData)

        let sealedBox: AES.GCM.SealedBox
        do {
            sealedBox = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        } catch {
            throw EncryptedProfileCodecError.authenticationFailed
        }

        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData(keyID: envelope.keyID)
            )
        } catch {
            throw EncryptedProfileCodecError.authenticationFailed
        }

        do {
            return try Self.profileDecoder.decode(ActiveProfile.self, from: plaintext)
        } catch {
            throw EncryptedProfileCodecError.profileDecodingFailed
        }
    }

    func decodeEnvelope(_ data: Data) throws -> EncryptedProfileEnvelope {
        let envelope: EncryptedProfileEnvelope
        do {
            envelope = try Self.envelopeDecoder.decode(
                EncryptedProfileEnvelope.self,
                from: data
            )
        } catch {
            throw EncryptedProfileCodecError.malformedEnvelope
        }

        guard envelope.formatVersion == Self.currentFormatVersion else {
            throw EncryptedProfileCodecError.unsupportedFormat(
                envelope.formatVersion
            )
        }
        guard envelope.algorithm == Self.algorithm else {
            throw EncryptedProfileCodecError.unsupportedAlgorithm(
                envelope.algorithm
            )
        }
        guard envelope.keyID == keyID else {
            throw EncryptedProfileCodecError.unsupportedKeyID(envelope.keyID)
        }
        return envelope
    }

    private func symmetricKey(from data: Data) throws -> SymmetricKey {
        guard data.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw EncryptedProfileCodecError.invalidKeyLength(data.count)
        }
        return SymmetricKey(data: data)
    }

    private func authenticatedData(keyID: String) -> Data {
        Data(
            "\(purpose)|\(Self.currentFormatVersion)|\(keyID)".utf8
        )
    }

    private static var profileEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var profileDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var envelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var envelopeDecoder: JSONDecoder {
        JSONDecoder()
    }
}

enum EncryptedProfileCodecError: LocalizedError, Equatable {
    case authenticationFailed
    case encryptionFailed
    case envelopeEncodingFailed
    case invalidKeyLength(Int)
    case malformedEnvelope
    case profileDecodingFailed
    case profileEncodingFailed
    case unsupportedAlgorithm(String)
    case unsupportedFormat(Int)
    case unsupportedKeyID(String)

    var errorDescription: String? {
        switch self {
        case .authenticationFailed:
            "The encrypted profile could not be authenticated."
        case .encryptionFailed:
            "The profile could not be encrypted."
        case .envelopeEncodingFailed:
            "The encrypted profile envelope could not be encoded."
        case let .invalidKeyLength(length):
            "The profile encryption key has an invalid length (\(length) bytes)."
        case .malformedEnvelope:
            "The encrypted profile envelope is malformed."
        case .profileDecodingFailed:
            "The decrypted profile could not be decoded."
        case .profileEncodingFailed:
            "The profile could not be encoded for encryption."
        case let .unsupportedAlgorithm(algorithm):
            "The encrypted profile algorithm '\(algorithm)' is not supported."
        case let .unsupportedFormat(version):
            "The encrypted profile format version \(version) is not supported."
        case let .unsupportedKeyID(keyID):
            "The encrypted profile key identifier '\(keyID)' is not supported."
        }
    }
}

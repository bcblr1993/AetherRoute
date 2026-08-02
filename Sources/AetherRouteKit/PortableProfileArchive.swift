import CommonCrypto
import CryptoKit
import Foundation
import Security

public struct PortableProfileArchivePayload: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public let formatVersion: Int
    public let exportedAt: Date
    public let catalog: ProfileCatalog

    public init(exportedAt: Date = .now, catalog: ProfileCatalog) {
        self.formatVersion = Self.currentFormatVersion
        self.exportedAt = exportedAt
        self.catalog = catalog
    }
}

/// Creates a password-protected archive that is intentionally independent of
/// the device-only Keychain key used for at-rest profile storage. The archive
/// can therefore move between Macs without weakening local storage.
public struct PortableProfileArchiveCodec: Sendable {
    public static let filenameExtension = "aetherroute"
    public static let minimumPasswordCharacters = 12
    public static let productionIterationCount = 600_000
    public static let maximumArchiveBytes = 72 * 1_024 * 1_024

    private static let formatVersion = 1
    private static let kdf = "PBKDF2-HMAC-SHA256"
    private static let cipher = "AES-256-GCM"
    private static let minimumAcceptedIterations = 100_000
    private static let maximumAcceptedIterations = 2_000_000
    private static let saltBytes = 16
    private static let keyBytes = 32
    private static let purpose = "AetherRoute.PortableProfileArchive"

    private let iterationCount: Int
    private let randomBytes: @Sendable (Int) throws -> Data

    public init() {
        iterationCount = Self.productionIterationCount
        randomBytes = Self.secureRandomBytes
    }

    init(
        iterationCount: Int,
        randomBytes: @escaping @Sendable (Int) throws -> Data =
            Self.secureRandomBytes
    ) {
        self.iterationCount = iterationCount
        self.randomBytes = randomBytes
    }

    public func seal(
        catalog: ProfileCatalog,
        password: String,
        exportedAt: Date = .now
    ) throws -> Data {
        try catalog.validateForStorage()
        guard !catalog.profiles.isEmpty else {
            throw PortableProfileArchiveError.emptyCatalog
        }
        guard Self.minimumAcceptedIterations...Self.maximumAcceptedIterations
            ~= iterationCount else {
            throw PortableProfileArchiveError.invalidIterationCount(
                iterationCount
            )
        }

        var passwordBytes = try normalizedPasswordBytes(password)
        defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
        let salt = try randomBytes(Self.saltBytes)
        guard salt.count == Self.saltBytes else {
            throw PortableProfileArchiveError.randomGenerationFailed
        }
        var derivedKey = try deriveKey(
            passwordBytes: passwordBytes,
            salt: salt,
            iterations: iterationCount
        )
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        let payload = PortableProfileArchivePayload(
            exportedAt: exportedAt,
            catalog: catalog
        )
        let plaintext: Data
        do {
            plaintext = try Self.payloadEncoder.encode(payload)
        } catch {
            throw PortableProfileArchiveError.payloadEncodingFailed
        }

        let header = PortableProfileArchiveEnvelope(
            formatVersion: Self.formatVersion,
            kdf: Self.kdf,
            cipher: Self.cipher,
            iterations: iterationCount,
            salt: salt,
            sealedBox: Data()
        )
        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.seal(
                plaintext,
                using: SymmetricKey(data: derivedKey),
                authenticating: authenticatedData(for: header)
            )
        } catch {
            throw PortableProfileArchiveError.encryptionFailed
        }
        guard let combined = box.combined else {
            throw PortableProfileArchiveError.encryptionFailed
        }
        let envelope = PortableProfileArchiveEnvelope(
            formatVersion: header.formatVersion,
            kdf: header.kdf,
            cipher: header.cipher,
            iterations: header.iterations,
            salt: header.salt,
            sealedBox: combined
        )
        let encoded: Data
        do {
            encoded = try Self.envelopeEncoder.encode(envelope)
        } catch {
            throw PortableProfileArchiveError.envelopeEncodingFailed
        }
        guard encoded.count <= Self.maximumArchiveBytes else {
            throw PortableProfileArchiveError.archiveTooLarge(encoded.count)
        }
        return encoded
    }

    public func open(
        _ data: Data,
        password: String
    ) throws -> PortableProfileArchivePayload {
        guard !data.isEmpty, data.count <= Self.maximumArchiveBytes else {
            throw PortableProfileArchiveError.archiveTooLarge(data.count)
        }
        let envelope = try decodeEnvelope(data)
        var passwordBytes = try normalizedPasswordBytes(password)
        defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
        var derivedKey = try deriveKey(
            passwordBytes: passwordBytes,
            salt: envelope.salt,
            iterations: envelope.iterations
        )
        defer { derivedKey.resetBytes(in: 0..<derivedKey.count) }

        let box: AES.GCM.SealedBox
        do {
            box = try AES.GCM.SealedBox(combined: envelope.sealedBox)
        } catch {
            throw PortableProfileArchiveError.authenticationFailed
        }
        let plaintext: Data
        do {
            plaintext = try AES.GCM.open(
                box,
                using: SymmetricKey(data: derivedKey),
                authenticating: authenticatedData(for: envelope)
            )
        } catch {
            throw PortableProfileArchiveError.authenticationFailed
        }

        let payload: PortableProfileArchivePayload
        do {
            payload = try Self.payloadDecoder.decode(
                PortableProfileArchivePayload.self,
                from: plaintext
            )
        } catch {
            throw PortableProfileArchiveError.payloadDecodingFailed
        }
        guard payload.formatVersion ==
                PortableProfileArchivePayload.currentFormatVersion else {
            throw PortableProfileArchiveError.unsupportedPayloadFormat(
                payload.formatVersion
            )
        }
        do {
            try payload.catalog.validateForStorage()
        } catch {
            throw PortableProfileArchiveError.invalidCatalog
        }
        guard !payload.catalog.profiles.isEmpty else {
            throw PortableProfileArchiveError.emptyCatalog
        }
        return payload
    }

    private func decodeEnvelope(
        _ data: Data
    ) throws -> PortableProfileArchiveEnvelope {
        let envelope: PortableProfileArchiveEnvelope
        do {
            envelope = try JSONDecoder().decode(
                PortableProfileArchiveEnvelope.self,
                from: data
            )
        } catch {
            throw PortableProfileArchiveError.malformedEnvelope
        }
        guard envelope.formatVersion == Self.formatVersion else {
            throw PortableProfileArchiveError.unsupportedEnvelopeFormat(
                envelope.formatVersion
            )
        }
        guard envelope.kdf == Self.kdf else {
            throw PortableProfileArchiveError.unsupportedKDF(envelope.kdf)
        }
        guard envelope.cipher == Self.cipher else {
            throw PortableProfileArchiveError.unsupportedCipher(
                envelope.cipher
            )
        }
        guard Self.minimumAcceptedIterations...Self.maximumAcceptedIterations
            ~= envelope.iterations else {
            throw PortableProfileArchiveError.invalidIterationCount(
                envelope.iterations
            )
        }
        guard (16...32).contains(envelope.salt.count),
              envelope.sealedBox.count >= 28 else {
            throw PortableProfileArchiveError.malformedEnvelope
        }
        return envelope
    }

    private func normalizedPasswordBytes(_ password: String) throws -> Data {
        let normalized = password.precomposedStringWithCanonicalMapping
        guard normalized.count >= Self.minimumPasswordCharacters else {
            throw PortableProfileArchiveError.weakPassword(
                Self.minimumPasswordCharacters
            )
        }
        let bytes = Data(normalized.utf8)
        guard bytes.count <= 1_024 else {
            throw PortableProfileArchiveError.passwordTooLong
        }
        return bytes
    }

    private func deriveKey(
        passwordBytes: Data,
        salt: Data,
        iterations: Int
    ) throws -> Data {
        var key = Data(count: Self.keyBytes)
        let keyLength = key.count
        let status = passwordBytes.withUnsafeBytes { passwordBuffer in
            salt.withUnsafeBytes { saltBuffer in
                key.withUnsafeMutableBytes { keyBuffer in
                    CCKeyDerivationPBKDF(
                        UInt32(kCCPBKDF2),
                        passwordBuffer.baseAddress?
                            .assumingMemoryBound(to: Int8.self),
                        passwordBytes.count,
                        saltBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                        salt.count,
                        UInt32(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        keyBuffer.baseAddress?
                            .assumingMemoryBound(to: UInt8.self),
                        keyLength
                    )
                }
            }
        }
        guard status == kCCSuccess else {
            key.resetBytes(in: 0..<key.count)
            throw PortableProfileArchiveError.keyDerivationFailed(status)
        }
        return key
    }

    private func authenticatedData(
        for envelope: PortableProfileArchiveEnvelope
    ) -> Data {
        Data(
            [
                Self.purpose,
                String(envelope.formatVersion),
                envelope.kdf,
                envelope.cipher,
                String(envelope.iterations),
                envelope.salt.base64EncodedString(),
            ].joined(separator: "|").utf8
        )
    }

    private static func secureRandomBytes(count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(
                kSecRandomDefault,
                count,
                buffer.baseAddress!
            )
        }
        guard status == errSecSuccess else {
            throw PortableProfileArchiveError.randomGenerationFailed
        }
        return data
    }

    private static var payloadEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static var payloadDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static var envelopeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

public enum PortableProfileArchiveError: LocalizedError, Equatable {
    case archiveTooLarge(Int)
    case authenticationFailed
    case emptyCatalog
    case encryptionFailed
    case envelopeEncodingFailed
    case invalidCatalog
    case invalidIterationCount(Int)
    case keyDerivationFailed(Int32)
    case malformedEnvelope
    case passwordTooLong
    case payloadDecodingFailed
    case payloadEncodingFailed
    case randomGenerationFailed
    case unsupportedCipher(String)
    case unsupportedEnvelopeFormat(Int)
    case unsupportedKDF(String)
    case unsupportedPayloadFormat(Int)
    case weakPassword(Int)

    public var errorDescription: String? {
        switch self {
        case let .archiveTooLarge(bytes):
            String.localizedStringWithFormat(
                String(localized: "The portable profile archive is too large (%lld bytes)."),
                Int64(bytes)
            )
        case .authenticationFailed:
            String(localized: "The password is incorrect or the portable archive was modified.")
        case .emptyCatalog:
            String(localized: "Add at least one profile before creating a portable archive.")
        case .encryptionFailed:
            String(localized: "The portable profile archive could not be encrypted.")
        case .envelopeEncodingFailed:
            String(localized: "The portable profile archive could not be encoded.")
        case .invalidCatalog:
            String(localized: "The portable archive contains an invalid profile library.")
        case let .invalidIterationCount(iterations):
            String.localizedStringWithFormat(
                String(localized: "The portable archive uses an unsafe or unsupported key-derivation count (%lld)."),
                Int64(iterations)
            )
        case let .keyDerivationFailed(status):
            String.localizedStringWithFormat(
                String(localized: "The portable archive key could not be derived (%lld)."),
                Int64(status)
            )
        case .malformedEnvelope:
            String(localized: "The selected file is not a valid AetherRoute portable archive.")
        case .passwordTooLong:
            String(localized: "The archive password is too long.")
        case .payloadDecodingFailed:
            String(localized: "The portable archive contents could not be decoded.")
        case .payloadEncodingFailed:
            String(localized: "The profile library could not be prepared for export.")
        case .randomGenerationFailed:
            String(localized: "Secure random data could not be generated.")
        case let .unsupportedCipher(cipher):
            String.localizedStringWithFormat(
                String(localized: "The portable archive cipher %@ is not supported."),
                cipher
            )
        case let .unsupportedEnvelopeFormat(version):
            String.localizedStringWithFormat(
                String(localized: "The portable archive format version %lld is not supported."),
                Int64(version)
            )
        case let .unsupportedKDF(kdf):
            String.localizedStringWithFormat(
                String(localized: "The portable archive key-derivation method %@ is not supported."),
                kdf
            )
        case let .unsupportedPayloadFormat(version):
            String.localizedStringWithFormat(
                String(localized: "The portable profile payload version %lld is not supported."),
                Int64(version)
            )
        case let .weakPassword(minimum):
            String.localizedStringWithFormat(
                String(localized: "Use a password with at least %lld characters."),
                Int64(minimum)
            )
        }
    }
}

private struct PortableProfileArchiveEnvelope: Codable, Sendable {
    let formatVersion: Int
    let kdf: String
    let cipher: String
    let iterations: Int
    let salt: Data
    let sealedBox: Data
}

import CryptoKit
import Foundation
import Security

public struct MITMRootCertificateBundle: Codable, Equatable, Sendable {
    public let certificateDER: Data
    public let privateKeyPKCS8DER: Data

    public init(certificateDER: Data, privateKeyPKCS8DER: Data) {
        self.certificateDER = certificateDER
        self.privateKeyPKCS8DER = privateKeyPKCS8DER
    }

    public var certificatePEM: String {
        Self.wrapPEM(label: "CERTIFICATE", der: certificateDER)
    }

    public var privateKeyPKCS8PEM: String {
        Self.wrapPEM(label: "PRIVATE KEY", der: privateKeyPKCS8DER)
    }

    public var sha256Fingerprint: String {
        let digest = SHA256.hash(data: certificateDER)
        return digest.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    private static func wrapPEM(label: String, der: Data) -> String {
        let base64 = der.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return "-----BEGIN \(label)-----\n\(base64)\n-----END \(label)-----\n"
    }
}

public enum MITMCertificateAuthorityError: LocalizedError, Equatable, Sendable {
    case keyGenerationFailed(String)
    case signingFailed(String)
    case invalidKeyMaterial
    case keychainFailure(OSStatus)
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case let .keyGenerationFailed(detail):
            return "Failed to generate MITM root CA keypair: \(detail)"
        case let .signingFailed(detail):
            return "Failed to sign MITM root CA certificate: \(detail)"
        case .invalidKeyMaterial:
            return "Stored MITM root CA key material is corrupted."
        case let .keychainFailure(status):
            return "Keychain error managing MITM root CA (OSStatus \(status))."
        case .exportFailed:
            return "Failed to export MITM root CA certificate."
        }
    }
}

public final class MITMCertificateAuthority: @unchecked Sendable {
    public static let defaultService = "com.aetherroute.desktop.mitm"
    public static let defaultAccount = "root-ca.v1"

    private let read: () throws -> Data?
    private let write: (Data) throws -> Void
    private let delete: () throws -> Void
    private let lock = NSLock()

    public init(
        service: String = MITMCertificateAuthority.defaultService,
        account: String = MITMCertificateAuthority.defaultAccount,
        read: (() throws -> Data?)? = nil,
        write: ((Data) throws -> Void)? = nil,
        delete: (() throws -> Void)? = nil
    ) {
        self.read = read ?? { try Self.defaultKeychainRead(service: service, account: account) }
        self.write = write ?? { try Self.defaultKeychainWrite(service: service, account: account, data: $0) }
        self.delete = delete ?? { try Self.defaultKeychainDelete(service: service, account: account) }
    }

    public func hasCertificate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = try? read(),
              let decoded = try? JSONDecoder().decode(MITMRootCertificateBundle.self, from: raw),
              !decoded.certificateDER.isEmpty,
              !decoded.privateKeyPKCS8DER.isEmpty else {
            return false
        }
        return true
    }

    public func loadIfPresent() throws -> MITMRootCertificateBundle? {
        lock.lock()
        defer { lock.unlock() }
        guard let raw = try read() else { return nil }
        guard let decoded = try? JSONDecoder().decode(MITMRootCertificateBundle.self, from: raw),
              !decoded.certificateDER.isEmpty,
              !decoded.privateKeyPKCS8DER.isEmpty else {
            throw MITMCertificateAuthorityError.invalidKeyMaterial
        }
        return decoded
    }

    public func loadOrCreateCA() throws -> MITMRootCertificateBundle {
        lock.lock()
        defer { lock.unlock() }
        if let raw = try read(),
           let decoded = try? JSONDecoder().decode(MITMRootCertificateBundle.self, from: raw),
           !decoded.certificateDER.isEmpty,
           !decoded.privateKeyPKCS8DER.isEmpty {
            return decoded
        }
        let generated = try Self.generateECDSAP256RootCA()
        let encoded = try JSONEncoder().encode(generated)
        try write(encoded)
        return generated
    }

    public func regenerateCA() throws -> MITMRootCertificateBundle {
        lock.lock()
        defer { lock.unlock() }
        let generated = try Self.generateECDSAP256RootCA()
        let encoded = try JSONEncoder().encode(generated)
        try write(encoded)
        return generated
    }

    public func deleteCA() throws {
        lock.lock()
        defer { lock.unlock() }
        try delete()
    }

    // MARK: - ECDSA P-256 Self-Signed X.509 v3 Root CA Generator

    public static func generateECDSAP256RootCA(
        commonName: String = "AetherRoute MITM Root CA",
        organizationName: String = "AetherRoute",
        now: Date = .now
    ) throws -> MITMRootCertificateBundle {
        let keyAttributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let privateKey = SecKeyCreateRandomKey(keyAttributes as CFDictionary, &error),
              let publicKey = SecKeyCopyPublicKey(privateKey) else {
            let desc = error?.takeRetainedValue().localizedDescription ?? "SecKeyCreateRandomKey failed"
            throw MITMCertificateAuthorityError.keyGenerationFailed(desc)
        }

        var privError: Unmanaged<CFError>?
        var pubError: Unmanaged<CFError>?
        guard let rawPrivate = SecKeyCopyExternalRepresentation(privateKey, &privError) as Data?,
              let rawPublic = SecKeyCopyExternalRepresentation(publicKey, &pubError) as Data?,
              rawPublic.count == 65,
              rawPrivate.count == 97 else {
            let desc = privError?.takeRetainedValue().localizedDescription
                ?? pubError?.takeRetainedValue().localizedDescription
                ?? "Unexpected ECDSA P-256 key representation length"
            throw MITMCertificateAuthorityError.keyGenerationFailed(desc)
        }

        // Security.framework X9.63 EC private key layout: 0x04 || X(32) || Y(32) || d(32)
        let scalarD = Data(rawPrivate.suffix(32))
        let pkcs8DER = encodePKCS8P256PrivateKey(scalarD: scalarD, publicX963: rawPublic)
        let tbsDER = try encodeRootTBSCertificate(
            commonName: commonName,
            organizationName: organizationName,
            publicX963: rawPublic,
            notBefore: now.addingTimeInterval(-3_600),
            notAfter: now.addingTimeInterval(10 * 365 * 86_400)
        )

        var signError: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            privateKey,
            .ecdsaSignatureMessageX962SHA256,
            tbsDER as CFData,
            &signError
        ) as Data? else {
            let desc = signError?.takeRetainedValue().localizedDescription ?? "SecKeyCreateSignature failed"
            throw MITMCertificateAuthorityError.signingFailed(desc)
        }

        let algID = derSequence(derOID(oidECDSAWithSHA256))
        let signatureBitString = derBitString(unusedBits: 0, signature)
        let certDER = derSequence(tbsDER + algID + signatureBitString)

        return MITMRootCertificateBundle(
            certificateDER: certDER,
            privateKeyPKCS8DER: pkcs8DER
        )
    }

    // MARK: - Keychain Persistence (Host App Only)

    static func keychainBaseQuery(service: String, account: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup = try? AppConstants.keychainAccessGroup() {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }

    private static func defaultKeychainRead(service: String, account: String) throws -> Data? {
        var query = keychainBaseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw MITMCertificateAuthorityError.keychainFailure(status)
        }
    }

    private static func defaultKeychainWrite(service: String, account: String, data: Data) throws {
        let baseQuery = keychainBaseQuery(service: service, account: account)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attrs = baseQuery
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attrs[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            attrs[kSecValueData as String] = data
            let addStatus = SecItemAdd(attrs as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw MITMCertificateAuthorityError.keychainFailure(addStatus)
            }
        default:
            throw MITMCertificateAuthorityError.keychainFailure(updateStatus)
        }
    }

    private static func defaultKeychainDelete(service: String, account: String) throws {
        let query = keychainBaseQuery(service: service, account: account)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw MITMCertificateAuthorityError.keychainFailure(status)
        }
    }

    // MARK: - Minimal ASN.1 DER X.509 & PKCS#8 Encoder

    private static let oidECPublicKey: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]
    private static let oidPrime256v1: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07]
    private static let oidECDSAWithSHA256: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02]
    private static let oidCommonName: [UInt8] = [0x55, 0x04, 0x03]
    private static let oidOrganization: [UInt8] = [0x55, 0x04, 0x0A]
    private static let oidSubjectKeyID: [UInt8] = [0x55, 0x1D, 0x0E]
    private static let oidKeyUsage: [UInt8] = [0x55, 0x1D, 0x0F]
    private static let oidBasicConstraints: [UInt8] = [0x55, 0x1D, 0x13]

    private static func encodePKCS8P256PrivateKey(scalarD: Data, publicX963: Data) -> Data {
        let ecPriv = derSequence(
            derInteger(Data([0x01]))
                + derOctetString(scalarD)
                + derTLV(tag: 0xA0, derOID(oidPrime256v1))
                + derTLV(tag: 0xA1, derBitString(unusedBits: 0, publicX963))
        )
        let algID = derSequence(derOID(oidECPublicKey) + derOID(oidPrime256v1))
        return derSequence(derInteger(Data([0x00])) + algID + derOctetString(ecPriv))
    }

    private static func encodeRootTBSCertificate(
        commonName: String,
        organizationName: String,
        publicX963: Data,
        notBefore: Date,
        notAfter: Date
    ) throws -> Data {
        var serialBytes = [UInt8](repeating: 0, count: 16)
        guard SecRandomCopyBytes(kSecRandomDefault, serialBytes.count, &serialBytes) == errSecSuccess else {
            throw MITMCertificateAuthorityError.keyGenerationFailed("SecRandomCopyBytes serial failed")
        }
        serialBytes[0] = (serialBytes[0] & 0x7F) | 0x01 // ensure non-zero positive integer

        let version = derTLV(tag: 0xA0, derInteger(Data([0x02]))) // X.509 v3
        let serial = derInteger(Data(serialBytes))
        let sigAlg = derSequence(derOID(oidECDSAWithSHA256))

        let orgRDN = derTLV(
            tag: 0x31,
            derSequence(derOID(oidOrganization) + derUTF8String(organizationName))
        )
        let cnRDN = derTLV(
            tag: 0x31,
            derSequence(derOID(oidCommonName) + derUTF8String(commonName))
        )
        let name = derSequence(orgRDN + cnRDN)

        let validity = derSequence(derTime(notBefore) + derTime(notAfter))
        let spki = derSequence(
            derSequence(derOID(oidECPublicKey) + derOID(oidPrime256v1))
                + derBitString(unusedBits: 0, publicX963)
        )

        let basicConstraints = derSequence(
            derOID(oidBasicConstraints)
                + derTLV(tag: 0x01, Data([0xFF])) // critical TRUE
                + derOctetString(derSequence(derTLV(tag: 0x01, Data([0xFF]))))
        )
        let keyUsage = derSequence(
            derOID(oidKeyUsage)
                + derTLV(tag: 0x01, Data([0xFF])) // critical TRUE
                + derOctetString(derBitString(unusedBits: 1, Data([0x06]))) // keyCertSign | cRLSign
        )
        let keyIDDigest = Data(SHA256.hash(data: publicX963).prefix(20))
        let subjectKeyID = derSequence(
            derOID(oidSubjectKeyID)
                + derOctetString(derOctetString(keyIDDigest))
        )
        let extensions = derTLV(tag: 0xA3, derSequence(basicConstraints + keyUsage + subjectKeyID))

        return derSequence(version + serial + sigAlg + name + validity + name + spki + extensions)
    }

    private static func derTime(_ date: Date) -> Data {
        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        if year < 2050 {
            formatter.dateFormat = "yyMMddHHmmss'Z'"
            return derTLV(tag: 0x17, Data(formatter.string(from: date).utf8))
        } else {
            formatter.dateFormat = "yyyyMMddHHmmss'Z'"
            return derTLV(tag: 0x18, Data(formatter.string(from: date).utf8))
        }
    }

    private static func derSequence(_ content: Data) -> Data { derTLV(tag: 0x30, content) }
    private static func derOID(_ bytes: [UInt8]) -> Data { derTLV(tag: 0x06, Data(bytes)) }
    private static func derOctetString(_ content: Data) -> Data { derTLV(tag: 0x04, content) }
    private static func derUTF8String(_ text: String) -> Data { derTLV(tag: 0x0C, Data(text.utf8)) }

    private static func derBitString(unusedBits: UInt8, _ payload: Data) -> Data {
        var content = Data([unusedBits])
        content.append(payload)
        return derTLV(tag: 0x03, content)
    }

    private static func derInteger(_ raw: Data) -> Data {
        var bytes = [UInt8](raw)
        while bytes.count > 1 && bytes[0] == 0x00 && (bytes[1] & 0x80) == 0 {
            bytes.removeFirst()
        }
        if bytes.isEmpty || (bytes[0] & 0x80) != 0 {
            bytes.insert(0x00, at: 0)
        }
        return derTLV(tag: 0x02, Data(bytes))
    }

    private static func derTLV(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        let len = content.count
        if len < 128 {
            out.append(UInt8(len))
        } else if len <= 0xFF {
            out.append(0x81)
            out.append(UInt8(len))
        } else {
            out.append(0x82)
            out.append(UInt8((len >> 8) & 0xFF))
            out.append(UInt8(len & 0xFF))
        }
        out.append(content)
        return out
    }
}

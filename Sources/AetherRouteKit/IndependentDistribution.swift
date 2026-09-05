import CryptoKit
@preconcurrency import Foundation
import Security

public enum IndependentDistributionMode: String, Equatable, Sendable {
    case free
    case licensed
    case development
}

/// Free access is an explicit property of the signed product. An incomplete
/// licensed build must never silently become an unlocked application.
public struct IndependentDistributionPolicy: Equatable, Sendable {
    public let mode: IndependentDistributionMode
    public let configuration: IndependentDistributionConfiguration?

    public init(
        mode rawMode: String?,
        releaseChannel: String,
        productID: String?,
        licenseServiceURL: String?,
        updateManifestURL: String?,
        signingPublicKeyBase64: String?
    ) throws {
        let hasServices = licenseServiceURL != nil
            || updateManifestURL != nil || signingPublicKeyBase64 != nil
        switch rawMode {
        case "free":
            guard !hasServices else {
                throw IndependentDistributionError.invalidServiceURL
            }
            mode = .free
            configuration = nil
        case nil where ["development", "beta"].contains(releaseChannel) && !hasServices:
            // Compatibility for older isolated development/QA fixtures only.
            mode = .development
            configuration = nil
        case "licensed", nil:
            guard let productID,
                  let licenseServiceURL,
                  let licenseURL = URL(string: licenseServiceURL),
                  let updateManifestURL,
                  let updateURL = URL(string: updateManifestURL),
                  let signingPublicKeyBase64 else {
                throw IndependentDistributionError.invalidServiceURL
            }
            mode = .licensed
            configuration = try IndependentDistributionConfiguration(
                productID: productID,
                licenseServiceURL: licenseURL,
                updateManifestURL: updateURL,
                signingPublicKeyBase64: signingPublicKeyBase64
            )
        default:
            throw IndependentDistributionError.invalidServiceURL
        }
    }
}

public struct IndependentDistributionConfiguration: Equatable, Sendable {
    public static let maximumResponseBytes = 64 * 1_024
    public static let maximumSignedPayloadBytes = 32 * 1_024

    public let productID: String
    public let licenseServiceURL: URL
    public let updateManifestURL: URL
    public let signingPublicKey: Data

    public init(
        productID: String,
        licenseServiceURL: URL,
        updateManifestURL: URL,
        signingPublicKeyBase64: String
    ) throws {
        let productID = productID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...128).contains(productID.utf8.count),
              productID.unicodeScalars.allSatisfy({
                  $0.isASCII && !$0.properties.isWhitespace
              }) else {
            throw IndependentDistributionError.invalidProductID
        }
        try Self.validateHTTPSURL(licenseServiceURL)
        try Self.validateHTTPSURL(updateManifestURL)
        guard let publicKey = Data(base64Encoded: signingPublicKeyBase64),
              publicKey.count == 32 else {
            throw IndependentDistributionError.invalidPublicKey
        }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)

        self.productID = productID
        self.licenseServiceURL = licenseServiceURL
        self.updateManifestURL = updateManifestURL
        self.signingPublicKey = publicKey
    }

    public static func validateHTTPSURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              !host.isEmpty,
              url.user == nil,
              url.password == nil,
              url.fragment == nil else {
            throw IndependentDistributionError.invalidServiceURL
        }
    }
}

public struct SignedDistributionEnvelope: Codable, Equatable, Sendable {
    public let payload: String
    public let signature: String

    public init(payload: String, signature: String) {
        self.payload = payload
        self.signature = signature
    }
}

public struct DistributionSignatureVerifier: Sendable {
    private let publicKey: Data

    public init(publicKey: Data) throws {
        guard publicKey.count == 32 else {
            throw IndependentDistributionError.invalidPublicKey
        }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        self.publicKey = publicKey
    }

    public func verifiedPayload(from envelopeData: Data) throws -> Data {
        guard envelopeData.count <= IndependentDistributionConfiguration.maximumResponseBytes
        else {
            throw IndependentDistributionError.responseTooLarge(envelopeData.count)
        }
        let envelope: SignedDistributionEnvelope
        do {
            envelope = try JSONDecoder().decode(
                SignedDistributionEnvelope.self,
                from: envelopeData
            )
        } catch {
            throw IndependentDistributionError.invalidEnvelope
        }
        guard let payload = Data(base64Encoded: envelope.payload),
              let signature = Data(base64Encoded: envelope.signature),
              !payload.isEmpty,
              payload.count <= IndependentDistributionConfiguration.maximumSignedPayloadBytes,
              signature.count == 64 else {
            throw IndependentDistributionError.invalidEnvelope
        }
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
        guard key.isValidSignature(signature, for: payload) else {
            throw IndependentDistributionError.invalidSignature
        }
        return payload
    }

    public func decode<T: Decodable>(
        _ type: T.Type,
        from envelopeData: Data
    ) throws -> T {
        let payload = try verifiedPayload(from: envelopeData)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(type, from: payload)
        } catch {
            throw IndependentDistributionError.invalidPayload
        }
    }
}

public enum LicenseEntitlementState: String, Codable, Equatable, Sendable {
    case active
    case expired
    case revoked
    case deviceLimit
}

/// The host's connection gate is deliberately separate from transient service
/// errors. A previously verified, unexpired receipt remains usable while the
/// owner's service is temporarily unreachable; a signed restriction or an
/// unverifiable local receipt still fails closed for new connections.
public enum DistributionConnectionAccess: Equatable, Sendable {
    case free
    case unrestrictedDevelopment
    case activationRequired
    case authorized
    case restricted(LicenseEntitlementState)
    case verificationUnavailable

    public var permitsNewConnection: Bool {
        switch self {
        case .free, .unrestrictedDevelopment, .authorized:
            true
        case .activationRequired, .restricted, .verificationUnavailable:
            false
        }
    }
}

public struct LicenseEntitlement: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let productID: String
    public let licenseID: String
    public let deviceID: String
    public let state: LicenseEntitlementState
    public let issuedAt: Date
    public let expiresAt: Date?

    public init(
        schemaVersion: Int = 1,
        productID: String,
        licenseID: String,
        deviceID: String,
        state: LicenseEntitlementState,
        issuedAt: Date,
        expiresAt: Date? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.productID = productID
        self.licenseID = licenseID
        self.deviceID = deviceID
        self.state = state
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
    }

    public func validated(
        for configuration: IndependentDistributionConfiguration,
        deviceID expectedDeviceID: String,
        now: Date
    ) throws -> Self {
        guard schemaVersion == 1,
              productID == configuration.productID,
              deviceID == expectedDeviceID,
              (1...128).contains(licenseID.utf8.count),
              issuedAt <= now.addingTimeInterval(5 * 60) else {
            throw IndependentDistributionError.invalidEntitlement
        }
        if let expiresAt, expiresAt < issuedAt {
            throw IndependentDistributionError.invalidEntitlement
        }
        if state == .active, let expiresAt, expiresAt <= now {
            throw IndependentDistributionError.expiredEntitlement
        }
        return self
    }
}

public struct SoftwareUpdateManifest: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let productID: String
    public let version: String
    public let build: Int
    public let publishedAt: Date
    public let minimumSystemVersion: String
    public let architecture: String
    public let downloadURL: URL
    public let sha256: String
    public let releaseNotesURL: URL?

    public init(
        schemaVersion: Int = 1,
        productID: String,
        version: String,
        build: Int,
        publishedAt: Date,
        minimumSystemVersion: String,
        architecture: String = "arm64",
        downloadURL: URL,
        sha256: String,
        releaseNotesURL: URL? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.productID = productID
        self.version = version
        self.build = build
        self.publishedAt = publishedAt
        self.minimumSystemVersion = minimumSystemVersion
        self.architecture = architecture
        self.downloadURL = downloadURL
        self.sha256 = sha256
        self.releaseNotesURL = releaseNotesURL
    }

    public func validated(
        for configuration: IndependentDistributionConfiguration,
        now: Date
    ) throws -> Self {
        guard schemaVersion == 1,
              productID == configuration.productID,
              build > 0,
              Self.isNumericVersion(version),
              Self.isNumericVersion(minimumSystemVersion),
              architecture == "arm64",
              publishedAt <= now.addingTimeInterval(5 * 60),
              sha256.range(
                  of: "^[0-9a-f]{64}$",
                  options: .regularExpression
              ) != nil else {
            throw IndependentDistributionError.invalidUpdateManifest
        }
        try IndependentDistributionConfiguration.validateHTTPSURL(downloadURL)
        if let releaseNotesURL {
            try IndependentDistributionConfiguration.validateHTTPSURL(
                releaseNotesURL
            )
        }
        return self
    }

    private static func isNumericVersion(_ value: String) -> Bool {
        value.range(
            of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$",
            options: .regularExpression
        ) != nil
    }
}

public enum SoftwareUpdateCheck: Equatable, Sendable {
    case current(checkedAt: Date)
    case available(SoftwareUpdateManifest)
}

public enum DistributionHTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
}

public struct DistributionHTTPRequest: Sendable {
    public let method: DistributionHTTPMethod
    public let url: URL
    public let headers: [String: String]
    public let body: Data?

    public init(
        method: DistributionHTTPMethod,
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

public struct DistributionHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let finalURL: URL

    public init(data: Data, statusCode: Int, finalURL: URL) {
        self.data = data
        self.statusCode = statusCode
        self.finalURL = finalURL
    }
}

public struct LicenseActivationResult: Sendable {
    public let entitlement: LicenseEntitlement
    public let signedReceipt: Data

    public init(entitlement: LicenseEntitlement, signedReceipt: Data) {
        self.entitlement = entitlement
        self.signedReceipt = signedReceipt
    }
}

public struct IndependentDistributionClient: Sendable {
    public typealias Transport = @Sendable (
        DistributionHTTPRequest
    ) async throws -> DistributionHTTPResponse

    private struct LicenseRequest: Encodable {
        let schemaVersion = 1
        let action: String
        let productID: String
        let deviceID: String
        let appVersion: String
        let appBuild: String
        let licenseKey: String?
        let signedReceipt: String?

        private enum CodingKeys: String, CodingKey {
            case schemaVersion
            case action
            case productID
            case deviceID
            case appVersion
            case appBuild
            case licenseKey
            case signedReceipt
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(schemaVersion, forKey: .schemaVersion)
            try container.encode(action, forKey: .action)
            try container.encode(productID, forKey: .productID)
            try container.encode(deviceID, forKey: .deviceID)
            try container.encode(appVersion, forKey: .appVersion)
            try container.encode(appBuild, forKey: .appBuild)
            if let licenseKey {
                try container.encode(licenseKey, forKey: .licenseKey)
            } else {
                try container.encodeNil(forKey: .licenseKey)
            }
            if let signedReceipt {
                try container.encode(signedReceipt, forKey: .signedReceipt)
            } else {
                try container.encodeNil(forKey: .signedReceipt)
            }
        }
    }

    private let configuration: IndependentDistributionConfiguration
    private let transport: Transport
    private let now: @Sendable () -> Date
    private let verifier: DistributionSignatureVerifier

    public init(
        configuration: IndependentDistributionConfiguration,
        transport: @escaping Transport,
        now: @escaping @Sendable () -> Date = { .now }
    ) throws {
        self.configuration = configuration
        self.transport = transport
        self.now = now
        verifier = try DistributionSignatureVerifier(
            publicKey: configuration.signingPublicKey
        )
    }

    public static func live(
        configuration: IndependentDistributionConfiguration
    ) throws -> Self {
        try Self(configuration: configuration) { request in
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.urlCache = nil
            sessionConfiguration.requestCachePolicy = .reloadIgnoringLocalCacheData
            sessionConfiguration.httpCookieAcceptPolicy = .never
            sessionConfiguration.httpShouldSetCookies = false
            sessionConfiguration.timeoutIntervalForRequest = 20
            sessionConfiguration.timeoutIntervalForResource = 30
            sessionConfiguration.waitsForConnectivity = false
            let delegate = DistributionNoRedirectDelegate()
            let session = URLSession(
                configuration: sessionConfiguration,
                delegate: delegate,
                delegateQueue: nil
            )
            defer { session.finishTasksAndInvalidate() }

            var urlRequest = URLRequest(url: request.url)
            urlRequest.httpMethod = request.method.rawValue
            urlRequest.httpBody = request.body
            urlRequest.timeoutInterval = 20
            for (name, value) in request.headers {
                urlRequest.setValue(value, forHTTPHeaderField: name)
            }
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let response = response as? HTTPURLResponse,
                  let finalURL = response.url else {
                throw IndependentDistributionError.invalidHTTPResponse
            }
            var data = Data()
            data.reserveCapacity(
                IndependentDistributionConfiguration.maximumResponseBytes
            )
            for try await byte in bytes {
                guard data.count
                    < IndependentDistributionConfiguration.maximumResponseBytes
                else {
                    throw IndependentDistributionError.responseTooLarge(
                        data.count + 1
                    )
                }
                data.append(byte)
            }
            return DistributionHTTPResponse(
                data: data,
                statusCode: response.statusCode,
                finalURL: finalURL
            )
        }
    }

    public func activateLicense(
        key: String,
        deviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> LicenseActivationResult {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (8...256).contains(key.utf8.count),
              !key.contains(where: { $0.isNewline || $0.isWhitespace }) else {
            throw IndependentDistributionError.invalidLicenseKey
        }
        return try await requestEntitlement(
            action: "activate",
            deviceID: deviceID,
            appVersion: appVersion,
            appBuild: appBuild,
            licenseKey: key,
            signedReceipt: nil
        )
    }

    public func refreshLicense(
        signedReceipt: Data,
        deviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws -> LicenseActivationResult {
        _ = try verifiedEntitlement(
            from: signedReceipt,
            deviceID: deviceID
        )
        return try await requestEntitlement(
            action: "refresh",
            deviceID: deviceID,
            appVersion: appVersion,
            appBuild: appBuild,
            licenseKey: nil,
            signedReceipt: signedReceipt.base64EncodedString()
        )
    }

    public func deactivateLicense(
        signedReceipt: Data,
        deviceID: String,
        appVersion: String,
        appBuild: String
    ) async throws {
        _ = try verifiedEntitlement(
            from: signedReceipt,
            deviceID: deviceID
        )
        let body = try encodedLicenseRequest(
            action: "deactivate",
            deviceID: deviceID,
            appVersion: appVersion,
            appBuild: appBuild,
            licenseKey: nil,
            signedReceipt: signedReceipt.base64EncodedString()
        )
        let response = try await sendLicenseRequest(body: body)
        guard response.statusCode == 204, response.data.isEmpty else {
            throw IndependentDistributionError.httpStatus(response.statusCode)
        }
    }

    public func verifiedEntitlement(
        from signedReceipt: Data,
        deviceID: String
    ) throws -> LicenseEntitlement {
        try verifier.decode(LicenseEntitlement.self, from: signedReceipt)
            .validated(
                for: configuration,
                deviceID: deviceID,
                now: now()
            )
    }

    public func checkForUpdates(
        currentBuild: Int
    ) async throws -> SoftwareUpdateCheck {
        guard currentBuild > 0 else {
            throw IndependentDistributionError.invalidCurrentBuild
        }
        let response = try await transport(
            DistributionHTTPRequest(
                method: .get,
                url: configuration.updateManifestURL,
                headers: [
                    "Accept": "application/json",
                    "User-Agent": "AetherRoute/1 UpdateChecker",
                ]
            )
        )
        try validate(response, expectedURL: configuration.updateManifestURL)
        guard response.statusCode == 200 else {
            throw IndependentDistributionError.httpStatus(response.statusCode)
        }
        let manifest = try verifier.decode(
            SoftwareUpdateManifest.self,
            from: response.data
        ).validated(for: configuration, now: now())
        return manifest.build > currentBuild
            ? .available(manifest)
            : .current(checkedAt: now())
    }

    private func requestEntitlement(
        action: String,
        deviceID: String,
        appVersion: String,
        appBuild: String,
        licenseKey: String?,
        signedReceipt: String?
    ) async throws -> LicenseActivationResult {
        let body = try encodedLicenseRequest(
            action: action,
            deviceID: deviceID,
            appVersion: appVersion,
            appBuild: appBuild,
            licenseKey: licenseKey,
            signedReceipt: signedReceipt
        )
        let response = try await sendLicenseRequest(body: body)
        guard response.statusCode == 200 else {
            throw IndependentDistributionError.httpStatus(response.statusCode)
        }
        let entitlement = try verifiedEntitlement(
            from: response.data,
            deviceID: deviceID
        )
        return LicenseActivationResult(
            entitlement: entitlement,
            signedReceipt: response.data
        )
    }

    private func encodedLicenseRequest(
        action: String,
        deviceID: String,
        appVersion: String,
        appBuild: String,
        licenseKey: String?,
        signedReceipt: String?
    ) throws -> Data {
        guard UUID(uuidString: deviceID) != nil,
              !appVersion.isEmpty,
              !appBuild.isEmpty else {
            throw IndependentDistributionError.invalidClientIdentity
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(
            LicenseRequest(
                action: action,
                productID: configuration.productID,
                deviceID: deviceID,
                appVersion: appVersion,
                appBuild: appBuild,
                licenseKey: licenseKey,
                signedReceipt: signedReceipt
            )
        )
    }

    private func sendLicenseRequest(
        body: Data
    ) async throws -> DistributionHTTPResponse {
        let response = try await transport(
            DistributionHTTPRequest(
                method: .post,
                url: configuration.licenseServiceURL,
                headers: [
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "User-Agent": "AetherRoute/1 LicenseClient",
                ],
                body: body
            )
        )
        try validate(response, expectedURL: configuration.licenseServiceURL)
        return response
    }

    private func validate(
        _ response: DistributionHTTPResponse,
        expectedURL: URL
    ) throws {
        guard response.finalURL == expectedURL else {
            throw IndependentDistributionError.redirectRejected
        }
        guard response.data.count <= IndependentDistributionConfiguration.maximumResponseBytes
        else {
            throw IndependentDistributionError.responseTooLarge(
                response.data.count
            )
        }
    }
}

public protocol DistributionCredentialStoring: Sendable {
    func loadOrCreateDeviceID() throws -> String
    func loadReceipt() throws -> Data?
    func saveReceipt(_ data: Data) throws
    func deleteReceipt() throws
}

public final class InMemoryDistributionCredentialStore:
    DistributionCredentialStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var deviceID: String?
    private var receipt: Data?

    public init(deviceID: String? = nil, receipt: Data? = nil) {
        self.deviceID = deviceID
        self.receipt = receipt
    }

    public func loadOrCreateDeviceID() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        if let deviceID { return deviceID }
        let created = UUID().uuidString.lowercased()
        deviceID = created
        return created
    }

    public func loadReceipt() throws -> Data? {
        lock.lock()
        defer { lock.unlock() }
        return receipt
    }

    public func saveReceipt(_ data: Data) throws {
        guard data.count <= IndependentDistributionConfiguration.maximumResponseBytes else {
            throw IndependentDistributionError.responseTooLarge(data.count)
        }
        lock.lock()
        receipt = data
        lock.unlock()
    }

    public func deleteReceipt() throws {
        lock.lock()
        receipt = nil
        lock.unlock()
    }
}

public struct DataProtectionDistributionCredentialStore:
    DistributionCredentialStoring,
    @unchecked Sendable
{
    public static let defaultService = "com.aetherroute.independent-distribution"

    private let accessGroupResolver: @Sendable () throws -> String
    private let service: String

    public init(
        accessGroup: String? = nil,
        service: String = Self.defaultService
    ) {
        if let accessGroup {
            accessGroupResolver = {
                try AppConstants.validateKeychainAccessGroup(accessGroup)
            }
        } else {
            accessGroupResolver = {
                try AppConstants.keychainAccessGroup()
            }
        }
        self.service = service
    }

    public func loadOrCreateDeviceID() throws -> String {
        if let data = try load(account: "device-id"),
           let value = String(data: data, encoding: .utf8),
           UUID(uuidString: value) != nil {
            return value
        }
        let value = UUID().uuidString.lowercased()
        try save(Data(value.utf8), account: "device-id")
        return value
    }

    public func loadReceipt() throws -> Data? {
        try load(account: "license-receipt")
    }

    public func saveReceipt(_ data: Data) throws {
        guard data.count <= IndependentDistributionConfiguration.maximumResponseBytes else {
            throw IndependentDistributionError.responseTooLarge(data.count)
        }
        try save(data, account: "license-receipt")
    }

    public func deleteReceipt() throws {
        let query = try baseQuery(account: "license-receipt")
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw IndependentDistributionError.keychain(status)
        }
    }

    private func load(account: String) throws -> Data? {
        var query = try baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data else {
                throw IndependentDistributionError.keychain(errSecDecode)
            }
            return data
        case errSecItemNotFound:
            return nil
        default:
            throw IndependentDistributionError.keychain(status)
        }
    }

    private func save(_ data: Data, account: String) throws {
        var query = try baseQuery(account: account)
        let update = [kSecValueData as String: data]
        switch SecItemUpdate(query as CFDictionary, update as CFDictionary) {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            query[kSecAttrAccessible as String] =
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            query[kSecValueData as String] = data
            let status = SecItemAdd(query as CFDictionary, nil)
            guard status == errSecSuccess else {
                throw IndependentDistributionError.keychain(status)
            }
        case let status:
            throw IndependentDistributionError.keychain(status)
        }
    }

    private func baseQuery(account: String) throws -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessGroup as String: try accessGroupResolver(),
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public enum IndependentDistributionError: LocalizedError, Equatable, Sendable {
    case invalidProductID
    case invalidServiceURL
    case invalidPublicKey
    case invalidEnvelope
    case invalidSignature
    case invalidPayload
    case invalidEntitlement
    case expiredEntitlement
    case invalidUpdateManifest
    case invalidUpdateArtifact
    case invalidUpdateDestination
    case updateArtifactTooLarge(Int64)
    case updateArtifactHashMismatch
    case invalidLicenseKey
    case invalidClientIdentity
    case invalidCurrentBuild
    case invalidHTTPResponse
    case redirectRejected
    case responseTooLarge(Int)
    case httpStatus(Int)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidProductID: "The distribution product identifier is invalid."
        case .invalidServiceURL: "License and update services must use credential-free HTTPS URLs."
        case .invalidPublicKey: "The distribution signing public key is invalid."
        case .invalidEnvelope: "The service returned an invalid signed envelope."
        case .invalidSignature: "The service response signature could not be verified."
        case .invalidPayload: "The signed service payload is invalid."
        case .invalidEntitlement: "The license does not match this product or Mac."
        case .expiredEntitlement: "The license has expired."
        case .invalidUpdateManifest: "The signed update manifest is invalid."
        case .invalidUpdateArtifact: "The downloaded update is not a valid file."
        case .invalidUpdateDestination: "Choose a valid DMG destination."
        case let .updateArtifactTooLarge(bytes): "The downloaded update is too large (\(bytes) bytes)."
        case .updateArtifactHashMismatch: "The downloaded update failed its integrity check."
        case .invalidLicenseKey: "Enter a valid license key without spaces."
        case .invalidClientIdentity: "The local licensing identity is invalid."
        case .invalidCurrentBuild: "The current build number is invalid."
        case .invalidHTTPResponse: "The distribution service returned an invalid response."
        case .redirectRejected: "The distribution service attempted an unexpected redirect."
        case let .responseTooLarge(bytes): "The distribution response is too large (\(bytes) bytes)."
        case let .httpStatus(status): "The distribution service returned HTTP \(status)."
        case let .keychain(status): "License data could not be accessed in Keychain (Security status \(status))."
        }
    }
}

private final class DistributionNoRedirectDelegate:
    NSObject,
    URLSessionTaskDelegate,
    @unchecked Sendable
{
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

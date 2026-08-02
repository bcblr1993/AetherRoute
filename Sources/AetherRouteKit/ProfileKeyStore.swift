import Foundation
import Security

public protocol ProfileKeyStoring: Sendable {
    func loadKey(keyID: String) throws -> Data
    func loadOrCreateKey(keyID: String) throws -> Data
}

public enum ProfileKeyStoreError: LocalizedError, Equatable {
    case keyNotFound
    case invalidKeyLength(Int)
    case randomGenerationFailed(OSStatus)
    case securityError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keyNotFound:
            "The profile encryption key is unavailable. Reimport the profile instead of overwriting the encrypted data."
        case let .invalidKeyLength(length):
            "The profile encryption key has an invalid length (\(length) bytes)."
        case let .randomGenerationFailed(status):
            "A profile encryption key could not be generated (Security status \(status))."
        case let .securityError(status):
            "The profile encryption key could not be accessed (Security status \(status))."
        }
    }
}

public struct DataProtectionProfileKeyStore: ProfileKeyStoring, @unchecked Sendable {
    public static let defaultService = "com.aetherroute.profile-encryption"
    public static let keySizeBytes = 32

    private let accessGroupResolver: @Sendable () throws -> String
    private let service: String
    private let operations: ProfileKeyStoreOperations

    public init(
        accessGroup: String? = nil,
        service: String = Self.defaultService
    ) {
        if let accessGroup {
            self.init(
                accessGroupResolver: {
                    try AppConstants.validateKeychainAccessGroup(accessGroup)
                },
                service: service,
                operations: .system
            )
        } else {
            self.init(
                accessGroupResolver: {
                    try AppConstants.keychainAccessGroup()
                },
                service: service,
                operations: .system
            )
        }
    }

    init(
        accessGroup: String,
        service: String,
        operations: ProfileKeyStoreOperations
    ) {
        self.init(
            accessGroupResolver: {
                try AppConstants.validateKeychainAccessGroup(accessGroup)
            },
            service: service,
            operations: operations
        )
    }

    init(
        accessGroupResolver: @escaping @Sendable () throws -> String,
        service: String,
        operations: ProfileKeyStoreOperations
    ) {
        self.accessGroupResolver = accessGroupResolver
        self.service = service
        self.operations = operations
    }

    public func loadKey(keyID: String) throws -> Data {
        var query = try baseQuery(keyID: keyID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        let (status, result) = operations.copyMatching(query)
        switch status {
        case errSecSuccess:
            guard let result else {
                throw ProfileKeyStoreError.securityError(errSecDecode)
            }
            try Self.validateKey(result)
            return result
        case errSecItemNotFound:
            throw ProfileKeyStoreError.keyNotFound
        default:
            throw ProfileKeyStoreError.securityError(status)
        }
    }

    public func loadOrCreateKey(keyID: String) throws -> Data {
        do {
            return try loadKey(keyID: keyID)
        } catch ProfileKeyStoreError.keyNotFound {
            // Continue with a single add attempt. Another process may win the
            // race between this lookup and SecItemAdd; that case is handled by
            // re-reading the winning item below.
        }

        let candidate = try operations.randomData(Self.keySizeBytes)
        try Self.validateKey(candidate)

        var attributes = try baseQuery(keyID: keyID)
        attributes[kSecAttrAccessible as String] =
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        attributes[kSecValueData as String] = candidate

        switch operations.add(attributes) {
        case errSecSuccess:
            return candidate
        case errSecDuplicateItem:
            return try loadKey(keyID: keyID)
        case let status:
            throw ProfileKeyStoreError.securityError(status)
        }
    }

    private func baseQuery(keyID: String) throws -> [String: Any] {
        let accessGroup = try accessGroupResolver()
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: keyID,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func validateKey(_ data: Data) throws {
        guard data.count == keySizeBytes else {
            throw ProfileKeyStoreError.invalidKeyLength(data.count)
        }
    }
}

/// A lock-protected key store intended for deterministic tests and isolated
/// previews. Production code uses ``DataProtectionProfileKeyStore`` by default.
public final class InMemoryProfileKeyStore: ProfileKeyStoring, @unchecked Sendable {
    public typealias KeyGenerator = @Sendable () throws -> Data

    private let lock = NSLock()
    private var keys: [String: Data]
    private let keyGenerator: KeyGenerator

    public init(keys: [String: Data] = [:]) {
        self.keys = keys
        self.keyGenerator = {
            try ProfileKeyStoreOperations.system.randomData(
                DataProtectionProfileKeyStore.keySizeBytes
            )
        }
    }

    public init(
        keys: [String: Data],
        keyGenerator: @escaping KeyGenerator
    ) {
        self.keys = keys
        self.keyGenerator = keyGenerator
    }

    public func loadKey(keyID: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let key = keys[keyID] else {
            throw ProfileKeyStoreError.keyNotFound
        }
        guard key.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw ProfileKeyStoreError.invalidKeyLength(key.count)
        }
        return key
    }

    public func loadOrCreateKey(keyID: String) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let key = keys[keyID] {
            guard key.count == DataProtectionProfileKeyStore.keySizeBytes else {
                throw ProfileKeyStoreError.invalidKeyLength(key.count)
            }
            return key
        }

        let key = try keyGenerator()
        guard key.count == DataProtectionProfileKeyStore.keySizeBytes else {
            throw ProfileKeyStoreError.invalidKeyLength(key.count)
        }
        keys[keyID] = key
        return key
    }
}

struct ProfileKeyStoreOperations: @unchecked Sendable {
    let copyMatching: ([String: Any]) -> (OSStatus, Data?)
    let add: ([String: Any]) -> OSStatus
    let randomData: (Int) throws -> Data

    static let system = Self(
        copyMatching: { query in
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        },
        add: { attributes in
            SecItemAdd(attributes as CFDictionary, nil)
        },
        randomData: { count in
            var data = Data(count: count)
            let status = data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else {
                    return errSecAllocate
                }
                return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
            }
            guard status == errSecSuccess else {
                throw ProfileKeyStoreError.randomGenerationFailed(status)
            }
            return data
        }
    )
}

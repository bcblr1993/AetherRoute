import Foundation
import Security

public enum ControlledListenerKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case http
    case socks
    case mixed

    public var abiKind: UInt32 {
        switch self {
        case .http: return 1
        case .socks: return 2
        case .mixed: return 3
        }
    }

    public var displayName: String {
        switch self {
        case .http: return "HTTP"
        case .socks: return "SOCKS5"
        case .mixed: return "Mixed (HTTP + SOCKS5)"
        }
    }
}

public struct ControlledListenerSpec: Identifiable, Codable, Equatable, Hashable, Sendable {
    public var id: UUID
    public var kind: ControlledListenerKind
    public var name: String
    public var port: Int

    public init(
        id: UUID = UUID(),
        kind: ControlledListenerKind,
        name: String,
        port: Int
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.port = port
    }
}

public enum ExternalControllerSettingsError: LocalizedError, Equatable, Sendable {
    case unsupportedVersion
    case invalidPort(Int)
    case invalidListenerPort(Int)
    case portConflict(Int)
    case invalidListenerName
    case tooManyControlledListeners

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion:
            return "External Controller configuration version is unsupported."
        case let .invalidPort(port):
            return "External Controller port \(port) must be between 1024 and 65535."
        case let .invalidListenerPort(port):
            return "Controlled listener port \(port) must be between 1024 and 65535."
        case let .portConflict(port):
            return "Port \(port) conflicts with another configured listener or local proxy."
        case .invalidListenerName:
            return "Controlled listener name must be non-empty UTF-8 up to 64 bytes without control characters."
        case .tooManyControlledListeners:
            return "At most \(ExternalControllerSettings.maximumControlledListeners) controlled listeners are allowed."
        }
    }
}

public struct ExternalControllerSettings: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let permittedPorts = 1_024...65_535
    public static let defaultPort = 9_090
    public static let maximumControlledListeners = 16

    public var version: Int
    public var isEnabled: Bool
    public var port: Int
    public var controlledListenersEnabled: Bool
    public var controlledListeners: [ControlledListenerSpec]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        port: Int = Self.defaultPort,
        controlledListenersEnabled: Bool = false,
        controlledListeners: [ControlledListenerSpec] = []
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.port = port
        self.controlledListenersEnabled = controlledListenersEnabled
        self.controlledListeners = controlledListeners
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case isEnabled
        case port
        case controlledListenersEnabled
        case controlledListeners
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.version = try container.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        self.isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        self.port = try container.decodeIfPresent(Int.self, forKey: .port) ?? Self.defaultPort
        self.controlledListenersEnabled = try container.decodeIfPresent(Bool.self, forKey: .controlledListenersEnabled) ?? false
        self.controlledListeners = try container.decodeIfPresent([ControlledListenerSpec].self, forKey: .controlledListeners) ?? []
    }

    public func validated(localProxy: LocalProxySettings = LocalProxySettings()) throws -> Self {
        guard version == Self.currentVersion else {
            throw ExternalControllerSettingsError.unsupportedVersion
        }
        guard Self.permittedPorts.contains(port) else {
            throw ExternalControllerSettingsError.invalidPort(port)
        }
        if port == localProxy.httpPort || port == localProxy.socksPort {
            throw ExternalControllerSettingsError.portConflict(port)
        }
        guard controlledListeners.count <= Self.maximumControlledListeners else {
            throw ExternalControllerSettingsError.tooManyControlledListeners
        }

        var usedPorts: Set<Int> = [port, localProxy.httpPort, localProxy.socksPort]
        var normalizedListeners: [ControlledListenerSpec] = []
        normalizedListeners.reserveCapacity(controlledListeners.count)

        for listener in controlledListeners {
            guard Self.permittedPorts.contains(listener.port) else {
                throw ExternalControllerSettingsError.invalidListenerPort(listener.port)
            }
            guard !usedPorts.contains(listener.port) else {
                throw ExternalControllerSettingsError.portConflict(listener.port)
            }
            let trimmedName = listener.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedName.isEmpty,
                  trimmedName.utf8.count <= 64,
                  trimmedName.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F }) else {
                throw ExternalControllerSettingsError.invalidListenerName
            }
            usedPorts.insert(listener.port)
            normalizedListeners.append(
                ControlledListenerSpec(
                    id: listener.id,
                    kind: listener.kind,
                    name: trimmedName,
                    port: listener.port
                )
            )
        }

        return ExternalControllerSettings(
            version: version,
            isEnabled: isEnabled,
            port: port,
            controlledListenersEnabled: controlledListenersEnabled,
            controlledListeners: normalizedListeners
        )
    }
}

public final class ExternalControllerPreferencesStore: @unchecked Sendable {
    public static let defaultKey = "AetherRoute.ExternalControllerSettings"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = ExternalControllerPreferencesStore.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load(localProxy: LocalProxySettings = LocalProxySettings()) -> ExternalControllerSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(ExternalControllerSettings.self, from: data),
              let validated = try? decoded.validated(localProxy: localProxy) else {
            return ExternalControllerSettings()
        }
        return validated
    }

    public func save(
        _ settings: ExternalControllerSettings,
        localProxy: LocalProxySettings = LocalProxySettings()
    ) throws {
        let validated = try settings.validated(localProxy: localProxy)
        let data = try JSONEncoder().encode(validated)
        defaults.set(data, forKey: key)
    }
}

public enum ExternalControllerSecretStoreError: LocalizedError, Equatable, Sendable {
    case keychainFailure(OSStatus)
    case randomGenerationFailed(OSStatus)
    case invalidStoredSecret

    public var errorDescription: String? {
        switch self {
        case let .keychainFailure(status):
            return "Failed to access External Controller secret in Keychain (OSStatus \(status))."
        case let .randomGenerationFailed(status):
            return "Failed to generate cryptographically random secret (OSStatus \(status))."
        case .invalidStoredSecret:
            return "Stored External Controller secret was malformed."
        }
    }
}

public final class ExternalControllerSecretStore: @unchecked Sendable {
    public static let defaultService = "com.aetherroute.desktop.external-controller"
    public static let defaultAccount = "controller-secret.v1"
    public static let secretLength = 32
    private static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")

    private let service: String
    private let account: String
    private let read: ([String: Any]) throws -> Data?
    private let write: ([String: Any], Data) throws -> Void
    private let delete: ([String: Any]) throws -> Void
    private let lock = NSLock()

    public init(
        service: String = ExternalControllerSecretStore.defaultService,
        account: String = ExternalControllerSecretStore.defaultAccount,
        read: (([String: Any]) throws -> Data?)? = nil,
        write: (([String: Any], Data) throws -> Void)? = nil,
        delete: (([String: Any]) throws -> Void)? = nil
    ) {
        self.service = service
        self.account = account
        self.read = read ?? Self.defaultRead
        self.write = write ?? Self.defaultWrite
        self.delete = delete ?? Self.defaultDelete
    }

    public func loadOrCreateSecret() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let query = baseQuery()
        if let existing = try read(query),
           let decoded = String(data: existing, encoding: .utf8),
           Self.isValidSecret(decoded) {
            return decoded
        }

        let generated = try Self.generateSecret()
        guard let data = generated.data(using: .utf8) else {
            throw ExternalControllerSecretStoreError.invalidStoredSecret
        }
        try write(query, data)
        return generated
    }

    public func regenerateSecret() throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let generated = try Self.generateSecret()
        guard let data = generated.data(using: .utf8) else {
            throw ExternalControllerSecretStoreError.invalidStoredSecret
        }
        try write(baseQuery(), data)
        return generated
    }

    public func clearSecret() throws {
        lock.lock()
        defer { lock.unlock() }
        try delete(baseQuery())
    }

    public static func isValidSecret(_ value: String) -> Bool {
        value.count == secretLength && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    public static func generateSecret() throws -> String {
        var result = ""
        result.reserveCapacity(secretLength)
        let alphabetCount = alphabet.count // 62
        let upperBound = UInt8(256 - (256 % alphabetCount)) // 248 -> unbiased uniform sampling

        while result.count < secretLength {
            var byte: UInt8 = 0
            let status = SecRandomCopyBytes(kSecRandomDefault, 1, &byte)
            guard status == errSecSuccess else {
                throw ExternalControllerSecretStoreError.randomGenerationFailed(status)
            }
            if byte < upperBound {
                result.append(alphabet[Int(byte) % alphabetCount])
            }
        }
        return result
    }

    private func baseQuery() -> [String: Any] {
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

    private static func defaultRead(_ baseQuery: [String: Any]) throws -> Data? {
        var query = baseQuery
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
            throw ExternalControllerSecretStoreError.keychainFailure(status)
        }
    }

    private static func defaultWrite(_ baseQuery: [String: Any], data: Data) throws {
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecAttrSynchronizable as String] = kCFBooleanFalse as Any
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw ExternalControllerSecretStoreError.keychainFailure(addStatus)
            }
        default:
            throw ExternalControllerSecretStoreError.keychainFailure(updateStatus)
        }
    }

    private static func defaultDelete(_ baseQuery: [String: Any]) throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ExternalControllerSecretStoreError.keychainFailure(status)
        }
    }
}

public enum ExternalControllerURLBuilder {
    public static func apiBaseURL(port: Int) -> URL? {
        guard ExternalControllerSettings.permittedPorts.contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    public static func metacubexdURL(port: Int, secret: String) -> URL? {
        dashboardURL(base: "https://metacubexd.pages.dev/#/setup", port: port, secret: secret)
    }

    public static func zashboardURL(port: Int, secret: String) -> URL? {
        dashboardURL(base: "https://board.zash.run.place/#/setup", port: port, secret: secret)
    }

    private static func dashboardURL(base: String, port: Int, secret: String) -> URL? {
        guard ExternalControllerSettings.permittedPorts.contains(port) else { return nil }
        let encodedSecret = secret.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? secret
        return URL(string: "\(base)?hostname=127.0.0.1&port=\(port)&secret=\(encodedSecret)")
    }
}

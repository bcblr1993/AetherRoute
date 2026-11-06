import Darwin
import Foundation

public enum GlobalShortcutAction: String, CaseIterable, Codable, Sendable {
    case toggleConnection
    case routingRule
    case routingGlobal
    case routingDirect
}

public enum GlobalShortcutKey: String, CaseIterable, Codable, Sendable {
    case controlOptionC
    case controlOptionP
    case controlOptionSpace
    case controlOptionR
    case controlOptionG
    case controlOptionD
    case controlOption1
    case controlOption2
    case controlOption3
    case controlShiftC
    case controlShiftP
    case controlShiftSpace

    public var displayTitle: String {
        switch self {
        case .controlOptionC: "⌃⌥C"
        case .controlOptionP: "⌃⌥P"
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionR: "⌃⌥R"
        case .controlOptionG: "⌃⌥G"
        case .controlOptionD: "⌃⌥D"
        case .controlOption1: "⌃⌥1"
        case .controlOption2: "⌃⌥2"
        case .controlOption3: "⌃⌥3"
        case .controlShiftC: "⌃⇧C"
        case .controlShiftP: "⌃⇧P"
        case .controlShiftSpace: "⌃⇧Space"
        }
    }
}

public struct GlobalShortcutPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var isEnabled: Bool
    public var toggleConnection: GlobalShortcutKey
    public var routingRule: GlobalShortcutKey
    public var routingGlobal: GlobalShortcutKey
    public var routingDirect: GlobalShortcutKey

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        toggleConnection: GlobalShortcutKey = .controlOptionC,
        routingRule: GlobalShortcutKey = .controlOption1,
        routingGlobal: GlobalShortcutKey = .controlOption2,
        routingDirect: GlobalShortcutKey = .controlOption3
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.toggleConnection = toggleConnection
        self.routingRule = routingRule
        self.routingGlobal = routingGlobal
        self.routingDirect = routingDirect
    }

    public subscript(action: GlobalShortcutAction) -> GlobalShortcutKey {
        get {
            switch action {
            case .toggleConnection: toggleConnection
            case .routingRule: routingRule
            case .routingGlobal: routingGlobal
            case .routingDirect: routingDirect
            }
        }
        set {
            switch action {
            case .toggleConnection: toggleConnection = newValue
            case .routingRule: routingRule = newValue
            case .routingGlobal: routingGlobal = newValue
            case .routingDirect: routingDirect = newValue
            }
        }
    }

    public var hasUniqueAssignments: Bool {
        Set(GlobalShortcutAction.allCases.map { self[$0] }).count
            == GlobalShortcutAction.allCases.count
    }

    /// Assigns a key without ever leaving two global actions in conflict.
    /// If the key is already in use, the two assignments are swapped.
    public mutating func assign(
        _ key: GlobalShortcutKey,
        to action: GlobalShortcutAction
    ) {
        let previous = self[action]
        guard previous != key else { return }
        if let conflictingAction = GlobalShortcutAction.allCases.first(
            where: { $0 != action && self[$0] == key }
        ) {
            self[conflictingAction] = previous
        }
        self[action] = key
    }

    public func validated() throws -> Self {
        guard version == Self.currentVersion else {
            throw AppAutomationPreferencesError.unsupportedVersion
        }
        guard hasUniqueAssignments else {
            throw AppAutomationPreferencesError.duplicateShortcut
        }
        return self
    }
}

public enum AppAutomationPreferencesError: Error, Equatable, Sendable {
    case unsupportedVersion
    case duplicateShortcut
    case invalidNetworkRule
    case tooManyNetworkRules
}

public enum NetworkTriggerKind: String, CaseIterable, Codable, Equatable, Sendable {
    case wifiSSID
    case gatewayAddress
    case ethernet
}

public enum NetworkAutomationAction: Codable, Equatable, Hashable, Sendable {
    case setRoutingMode(RoutingMode)
    case connect
    case disconnect
}

public struct NetworkAutomationRule: Codable, Equatable, Sendable, Identifiable {
    public static let maximumValueLength = 128

    public var id: UUID
    public var isEnabled: Bool
    public var triggerKind: NetworkTriggerKind
    public var matchValue: String
    public var action: NetworkAutomationAction

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        triggerKind: NetworkTriggerKind,
        matchValue: String = "",
        action: NetworkAutomationAction
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.triggerKind = triggerKind
        self.matchValue = matchValue
        self.action = action
    }

    public func validated() throws -> NetworkAutomationRule {
        var copy = self
        let trimmed = matchValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= Self.maximumValueLength,
              !trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
        else {
            throw AppAutomationPreferencesError.invalidNetworkRule
        }
        switch triggerKind {
        case .wifiSSID:
            guard !trimmed.isEmpty else {
                throw AppAutomationPreferencesError.invalidNetworkRule
            }
            copy.matchValue = trimmed
        case .gatewayAddress:
            guard Self.isValidIPAddress(trimmed) else {
                throw AppAutomationPreferencesError.invalidNetworkRule
            }
            copy.matchValue = trimmed
        case .ethernet:
            copy.matchValue = ""
        }
        return copy
    }

    public func matches(_ environment: NetworkEnvironmentSnapshot) -> Bool {
        guard isEnabled else { return false }
        switch triggerKind {
        case .wifiSSID:
            guard let ssid = environment.wifiSSID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !ssid.isEmpty else { return false }
            return ssid.caseInsensitiveCompare(matchValue.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        case .gatewayAddress:
            guard let gw = environment.gatewayAddress?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !gw.isEmpty else { return false }
            return gw.caseInsensitiveCompare(matchValue.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame
        case .ethernet:
            return environment.isEthernet
        }
    }

    static func isValidIPAddress(_ value: String) -> Bool {
        guard !value.isEmpty else { return false }
        var ipv4 = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
            return true
        }
        var ipv6 = in6_addr()
        if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 {
            return true
        }
        return false
    }
}

public struct NetworkAutomationPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public static let maximumRuleCount = 32

    public var version: Int
    public var isEnabled: Bool
    public var rules: [NetworkAutomationRule]

    public init(
        version: Int = Self.currentVersion,
        isEnabled: Bool = false,
        rules: [NetworkAutomationRule] = []
    ) {
        self.version = version
        self.isEnabled = isEnabled
        self.rules = rules
    }

    public func validated() throws -> NetworkAutomationPreferences {
        guard version == Self.currentVersion else {
            throw AppAutomationPreferencesError.unsupportedVersion
        }
        guard rules.count <= Self.maximumRuleCount else {
            throw AppAutomationPreferencesError.tooManyNetworkRules
        }
        var copy = self
        copy.rules = try rules.map { try $0.validated() }
        return copy
    }

    public func matchedAction(for environment: NetworkEnvironmentSnapshot) -> NetworkAutomationAction? {
        guard isEnabled else { return nil }
        return rules.first(where: { $0.matches(environment) })?.action
    }
}

public struct NetworkAutomationPreferenceStore {
    public static let storageKey = "AetherRoute.NetworkAutomationPreferences"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.storageKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> NetworkAutomationPreferences {
        guard let data = defaults.data(forKey: key),
              let decoded = try? PropertyListDecoder().decode(
                  NetworkAutomationPreferences.self,
                  from: data
              ),
              let validated = try? decoded.validated() else {
            return NetworkAutomationPreferences()
        }
        return validated
    }

    public func save(_ preferences: NetworkAutomationPreferences) throws {
        let preferences = try preferences.validated()
        defaults.set(
            try PropertyListEncoder().encode(preferences),
            forKey: key
        )
    }
}

public struct AppAutomationPreferenceStore {
    public static let storageKey = "AetherRoute.GlobalShortcutPreferences"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.storageKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> GlobalShortcutPreferences {
        guard let data = defaults.data(forKey: key),
              let decoded = try? PropertyListDecoder().decode(
                  GlobalShortcutPreferences.self,
                  from: data
              ),
              let validated = try? decoded.validated() else {
            return GlobalShortcutPreferences()
        }
        return validated
    }

    public func save(_ preferences: GlobalShortcutPreferences) throws {
        let preferences = try preferences.validated()
        defaults.set(
            try PropertyListEncoder().encode(preferences),
            forKey: key
        )
    }
}

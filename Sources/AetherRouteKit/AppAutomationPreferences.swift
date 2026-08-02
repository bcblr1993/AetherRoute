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

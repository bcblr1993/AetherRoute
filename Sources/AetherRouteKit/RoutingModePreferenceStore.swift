import Foundation

public struct RoutingModePreferenceStore {
    public static let defaultKey = "defaultRoutingMode"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> RoutingMode {
        guard let rawValue = defaults.string(forKey: key),
              let mode = RoutingMode(rawValue: rawValue) else {
            return .rule
        }
        return mode
    }

    public func save(_ mode: RoutingMode) {
        defaults.set(mode.rawValue, forKey: key)
    }
}

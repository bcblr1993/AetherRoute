import Foundation

/// A persistent store recording the user's intended proxy connection state
/// across application launches and terminations.
public struct ConnectionIntentStore: @unchecked Sendable {
    public static let defaultKey = "AetherRoute.LastConnectionIntent"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    /// Whether the user intended the connection to be active before the last quit or reboot.
    public var wasConnected: Bool {
        defaults.bool(forKey: key)
    }

    /// Updates the persisted user intent.
    public func save(intendedConnected: Bool) {
        defaults.set(intendedConnected, forKey: key)
    }
}

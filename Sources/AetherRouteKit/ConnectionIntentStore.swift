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

    /// Shutdown can stop the provider before the final AppKit callback. Keep
    /// the standing intent, and never overwrite the first termination snapshot.
    public func saveForApplicationTermination(
        managerIsActive: Bool,
        userIntendsToConnect: Bool,
        alreadyTerminating: Bool
    ) {
        guard !alreadyTerminating else { return }
        // An explicit disconnect is persisted before the provider finishes
        // stopping. Its still-active status must not undo that decision.
        let intent = defaults.object(forKey: key) == nil
            ? managerIsActive || userIntendsToConnect
            : wasConnected
        save(intendedConnected: intent)
    }
}

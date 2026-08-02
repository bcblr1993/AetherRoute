import Foundation

/// A versioned, app-local record that the current network privacy disclosure
/// has been accepted. The value is intentionally stored in the host app's
/// sandboxed preferences: it is not a secret and must not depend on App Group
/// provisioning before the app has a production signing identity.
public struct PrivacyConsentStore {
    public static let currentDisclosureVersion = 2
    public static let defaultKey = "privacyDisclosureAcceptedVersion"

    private let defaults: UserDefaults
    private let key: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = Self.defaultKey
    ) {
        self.defaults = defaults
        self.key = key
    }

    public var acceptedDisclosureVersion: Int? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.integer(forKey: key)
    }

    public var hasAcceptedCurrentDisclosure: Bool {
        acceptedDisclosureVersion == Self.currentDisclosureVersion
    }

    public func acceptCurrentDisclosure() {
        defaults.set(Self.currentDisclosureVersion, forKey: key)
    }

    public func requireCurrentConsent() throws {
        guard hasAcceptedCurrentDisclosure else {
            throw PrivacyConsentError.required
        }
    }
}

public enum PrivacyConsentError: LocalizedError, Equatable {
    case required

    public var errorDescription: String? {
        "Review and accept the network privacy disclosure before continuing."
    }
}

import Foundation

public enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    public var id: Self { self }

    public var localeIdentifier: String? {
        switch self {
        case .system: nil
        case .simplifiedChinese: "zh-Hans"
        case .english: "en"
        }
    }
}

public struct AppLanguagePreferenceStore {
    public static let storageKey = "AetherRouteAppLanguage"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> AppLanguagePreference {
        guard let rawValue = defaults.string(forKey: Self.storageKey),
              let preference = AppLanguagePreference(rawValue: rawValue) else {
            return .system
        }
        return preference
    }

    public func save(_ preference: AppLanguagePreference) {
        defaults.set(preference.rawValue, forKey: Self.storageKey)
    }
}

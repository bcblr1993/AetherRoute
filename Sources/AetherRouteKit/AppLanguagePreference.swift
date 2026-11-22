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

public enum AppLocalizationLocaleBridge {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var provider: @Sendable () -> Locale = {
        .autoupdatingCurrent
    }

    public static var currentLocale: Locale {
        lock.withLock { provider() }
    }

    public static func register(_ provider: @escaping @Sendable () -> Locale) {
        lock.withLock {
            self.provider = provider
        }
    }
}

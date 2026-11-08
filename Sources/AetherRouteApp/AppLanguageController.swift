import AetherRouteKit
import Combine
import Foundation

enum AppLocalization {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var localeIdentifier: String?
    nonisolated(unsafe) private static var localizationBundle: Bundle = .main
    nonisolated(unsafe) private static var cachedLocale: Locale = .autoupdatingCurrent
    nonisolated(unsafe) private static var cachedRegionNames: [String: String] = [:]
    nonisolated(unsafe) private static var cachedDurationFormatterWithSeconds: DateComponentsFormatter?
    nonisolated(unsafe) private static var cachedDurationFormatterMinutesOnly: DateComponentsFormatter?

    static func configure(_ preference: AppLanguagePreference) {
        let bundle = resolvedBundle(for: preference)
        let locale = preference.localeIdentifier.map { Locale(identifier: $0) }
            ?? .autoupdatingCurrent
        lock.withLock {
            localeIdentifier = preference.localeIdentifier
            localizationBundle = bundle
            cachedLocale = locale
            cachedRegionNames.removeAll(keepingCapacity: true)
            cachedDurationFormatterWithSeconds = nil
            cachedDurationFormatterMinutesOnly = nil
        }
    }

    static func string(_ value: String.LocalizationValue) -> String {
        let (locale, bundle) = lock.withLock {
            (cachedLocale, localizationBundle)
        }
        return String(localized: value, bundle: bundle, locale: locale)
    }

    static func string(_ value: String) -> String {
        string(String.LocalizationValue(value))
    }

    /// Formats a counted string with the catalog's plural rules applied
    /// ("1 rule", "3 rules"). `String(localized:)` returns a plain string,
    /// which loses the plural variations, so counted copy goes through the
    /// bundle's format string instead.
    static func format(_ key: String, _ arguments: any CVarArg...) -> String {
        let (locale, bundle) = lock.withLock {
            (cachedLocale, localizationBundle)
        }
        let format = bundle.localizedString(forKey: key, value: nil, table: nil)
        return String(format: format, locale: locale, arguments: arguments)
    }

    static func date(
        _ value: Date,
        date dateStyle: Date.FormatStyle.DateStyle,
        time timeStyle: Date.FormatStyle.TimeStyle
    ) -> String {
        let locale = lock.withLock { cachedLocale }
        return value.formatted(
            Date.FormatStyle(date: dateStyle, time: timeStyle)
                .locale(locale)
        )
    }

    /// A region's name in the app's language ("香港", "Hong Kong"). Node
    /// names use UK for the United Kingdom.
    static func regionName(_ code: String) -> String {
        let iso = code.uppercased() == "UK" ? "GB" : code.uppercased()
        if let cached = lock.withLock({ cachedRegionNames[iso] }) {
            return cached
        }
        let locale = lock.withLock { cachedLocale }
        let resolved = locale.localizedString(forRegionCode: iso) ?? code
        lock.withLock {
            cachedRegionNames[iso] = resolved
        }
        return resolved
    }

    /// The one elapsed-time format in the app: the two largest units,
    /// abbreviated ("2小时11分钟", "2h 11m"), in the app's chosen language.
    /// Live timers pass `includesSeconds` so a short session still moves
    /// ("49分钟2秒", "49m 2s"); summaries round to whole minutes.
    static func duration(_ interval: TimeInterval, includesSeconds: Bool = false) -> String {
        let value = (includesSeconds ? max(0, interval) : max(60, interval)).rounded(.down)
        return lock.withLock {
            let formatter: DateComponentsFormatter
            if includesSeconds, let existing = cachedDurationFormatterWithSeconds {
                formatter = existing
            } else if !includesSeconds, let existing = cachedDurationFormatterMinutesOnly {
                formatter = existing
            } else {
                var calendar = Calendar.current
                calendar.locale = cachedLocale
                let created = DateComponentsFormatter()
                created.calendar = calendar
                created.unitsStyle = .abbreviated
                created.allowedUnits = includesSeconds
                    ? [.day, .hour, .minute, .second]
                    : [.day, .hour, .minute]
                created.maximumUnitCount = 2
                created.zeroFormattingBehavior = .dropAll
                if includesSeconds {
                    cachedDurationFormatterWithSeconds = created
                } else {
                    cachedDurationFormatterMinutesOnly = created
                }
                formatter = created
            }
            return formatter.string(from: value) ?? ""
        }
    }

    private static func resolvedBundle(
        for preference: AppLanguagePreference
    ) -> Bundle {
        let localization: String?
        switch preference {
        case .simplifiedChinese:
            localization = "zh-Hans"
        case .english:
            localization = "en"
        case .system:
            localization = Bundle.main.preferredLocalizations.first(where: {
                $0.hasPrefix("zh") || $0.hasPrefix("en")
            }) ?? "en"
        }
        guard let localization,
              let path = Bundle.main.path(
                forResource: localization,
                ofType: "lproj"
              ),
              let bundle = Bundle(path: path) else {
            return .main
        }
        return bundle
    }
}

@MainActor
final class AppLanguageController: ObservableObject {
    @Published private(set) var preference: AppLanguagePreference

    private let store: AppLanguagePreferenceStore
    private let persistsSelection: Bool

    init(store: AppLanguagePreferenceStore = .init()) {
        self.store = store
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        let reviewLanguage = ProcessInfo.processInfo.environment[
            "AETHERROUTE_UI_REVIEW_LANGUAGE"
        ].flatMap(AppLanguagePreference.init(rawValue:))
        self.persistsSelection = reviewLanguage == nil
        let preference = reviewLanguage ?? store.load()
#else
        self.persistsSelection = true
        let preference = store.load()
#endif
        self.preference = preference
        AppLocalization.configure(preference)
    }

    var locale: Locale {
        preference.localeIdentifier.map { Locale(identifier: $0) }
            ?? .autoupdatingCurrent
    }

    func select(_ preference: AppLanguagePreference) {
        guard self.preference != preference else { return }
        AppLocalization.configure(preference)
        if persistsSelection {
            store.save(preference)
        }
        self.preference = preference
    }
}

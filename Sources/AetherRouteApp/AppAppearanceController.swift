import AppKit
import Combine
import Foundation

enum AppAppearancePreference: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: nil
        case .light: .aqua
        case .dark: .darkAqua
        }
    }
}

@MainActor
final class AppAppearanceController: ObservableObject {
    private static let storageKey = "AetherRouteAppearance"
    @Published private(set) var preference: AppAppearancePreference
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preference = defaults.string(forKey: Self.storageKey)
            .flatMap(AppAppearancePreference.init(rawValue:)) ?? .system
        apply()
    }

    func select(_ preference: AppAppearancePreference) {
        guard self.preference != preference else { return }
        self.preference = preference
        defaults.set(preference.rawValue, forKey: Self.storageKey)
        apply()
    }

    private func apply() {
        // App-wide appearance also covers Settings, sheets, title bars and
        // the menu-bar popover. nil restores live system appearance changes.
        NSApplication.shared.appearance = preference.appearanceName
            .flatMap(NSAppearance.init(named:))
    }
}

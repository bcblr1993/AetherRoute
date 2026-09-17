import AppKit
import Combine
import Foundation

@MainActor
final class AppDockVisibilityController: ObservableObject {
    static let shared = AppDockVisibilityController()
    static let storageKey = "AetherRouteHideDockIcon"

    @Published private(set) var isDockIconHidden: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isDockIconHidden = defaults.bool(forKey: Self.storageKey)
        apply()
    }

    func setDockIconHidden(_ hidden: Bool) {
        guard isDockIconHidden != hidden else { return }
        isDockIconHidden = hidden
        defaults.set(hidden, forKey: Self.storageKey)
        apply()
    }

    func apply() {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] != nil {
            NSApplication.shared.setActivationPolicy(.regular)
            return
        }
#endif
        let targetPolicy: NSApplication.ActivationPolicy = isDockIconHidden ? .accessory : .regular
        if NSApplication.shared.activationPolicy() != targetPolicy {
            NSApplication.shared.setActivationPolicy(targetPolicy)
        }
        if !isDockIconHidden {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}

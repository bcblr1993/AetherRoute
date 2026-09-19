import AppKit
import AetherRouteKit
import Combine
import Foundation
import OSLog

@MainActor
final class AppDockVisibilityController: ObservableObject {
    static let shared = AppDockVisibilityController()
    static let storageKey = "AetherRouteHideDockIcon"
    private static let logger = AppLog.logger(category: AppLog.Category.appLifecycle)

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

    func apply(force: Bool = false) {
#if DEBUG || AETHERROUTE_UI_RESPONSIVENESS
        if ProcessInfo.processInfo.environment["AETHERROUTE_UI_REVIEW"] != nil {
            NSApplication.shared.setActivationPolicy(.regular)
            return
        }
#endif
        let targetPolicy: NSApplication.ActivationPolicy = isDockIconHidden ? .accessory : .regular
        let currentPolicy = NSApplication.shared.activationPolicy()
        if force || currentPolicy != targetPolicy {
            let changed = NSApplication.shared.setActivationPolicy(targetPolicy)
            Self.logger.info(
                "stage=dockVisibility apply isDockIconHidden=\(self.isDockIconHidden, privacy: .public) targetPolicy=\(targetPolicy.rawValue, privacy: .public) previousPolicy=\(currentPolicy.rawValue, privacy: .public) result=\(changed, privacy: .public) force=\(force, privacy: .public)"
            )
        }
        if !isDockIconHidden {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }
}


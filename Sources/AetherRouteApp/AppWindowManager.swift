import AetherRouteKit
import AppKit
import Combine
import Darwin
import OSLog
import SwiftUI

@MainActor
final class AppWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = AppWindowManager()
    private static let logger = AppLog.logger(category: AppLog.Category.appLifecycle)
    static let settingsNavigationNotification = Notification.Name("com.aetherroute.desktop.navigate-to-settings")

    private(set) weak var mainWindow: NSWindow?
    private weak var forwardedDelegate: (any NSWindowDelegate)?
    @Published private(set) var pendingSettingsTab: String?
    var isTerminating = false
    var openWindowAction: (() -> Void)?

    override private init() {
        super.init()
    }

    func requestSettingsTab(_ tabIdentifier: String) {
        pendingSettingsTab = tabIdentifier
        NotificationCenter.default.post(name: Self.settingsNavigationNotification, object: tabIdentifier)
    }

    @discardableResult
    func consumePendingSettingsTab() -> String? {
        defer { pendingSettingsTab = nil }
        return pendingSettingsTab
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        if let existing = window.delegate, existing !== self {
            forwardedDelegate = existing
        }
        window.delegate = self
        Self.logger.info(
            "MainWindow registered with AppWindowManager: windowNumber=\(window.windowNumber)"
        )
    }

    static func isMainWindowCandidate(_ window: NSWindow) -> Bool {
        guard !(window is NSPanel), window.canBecomeMain else { return false }
        let identifier = window.identifier?.rawValue ?? ""
        if identifier == "main" || identifier.hasPrefix("main-") {
            return true
        }
        if identifier.localizedCaseInsensitiveContains("settings")
            || identifier.localizedCaseInsensitiveContains("sparkle")
            || identifier.localizedCaseInsensitiveContains("update") {
            return false
        }
        let className = NSStringFromClass(type(of: window))
        if className.localizedCaseInsensitiveContains("Settings")
            || className.hasPrefix("SPU")
            || className.hasPrefix("SU") {
            return false
        }
        if let controller = window.windowController {
            let controllerClass = NSStringFromClass(type(of: controller))
            if controllerClass.hasPrefix("SPU")
                || controllerClass.hasPrefix("SU")
                || controllerClass.localizedCaseInsensitiveContains("Settings") {
                return false
            }
        }
        return true
    }

    func showMainWindow() {
        Self.logger.info(
            "showMainWindow requested. mainWindow exists=\(self.mainWindow != nil)"
        )
        AppDockVisibilityController.shared.apply()
        if let window = mainWindow {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        // Fallback: search for a candidate main window (excluding Settings/Sparkle).
        if let window = NSApplication.shared.windows.first(where: Self.isMainWindowCandidate) {
            registerMainWindow(window)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        if let openWindowAction {
            openWindowAction()
            NSApplication.shared.activate(ignoringOtherApps: true)
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - NSWindowDelegate

    private struct ForwardingBox: @unchecked Sendable {
        let target: AnyObject?
    }

    nonisolated override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) {
            return true
        }
        guard Thread.isMainThread else { return false }
        return MainActor.assumeIsolated {
            forwardedDelegate?.responds(to: aSelector) ?? false
        }
    }

    nonisolated override func forwardingTarget(for aSelector: Selector!) -> Any? {
        guard Thread.isMainThread else { return nil }
        let boxed: ForwardingBox = MainActor.assumeIsolated {
            if let forwardedDelegate, forwardedDelegate.responds(to: aSelector) {
                return ForwardingBox(target: forwardedDelegate)
            }
            return ForwardingBox(target: nil)
        }
        return boxed.target
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isTerminating {
            return forwardedDelegate?.windowShouldClose?(sender) ?? true
        }
        sender.orderOut(nil)
        trimMemoryFootprint()
        return false
    }

    func windowDidMiniaturize(_ notification: Notification) {
        forwardedDelegate?.windowDidMiniaturize?(notification)
        trimMemoryFootprint()
    }

    private func trimMemoryFootprint() {
        #if canImport(Darwin)
        malloc_zone_pressure_relief(malloc_default_zone(), 0)
        #endif
    }
}

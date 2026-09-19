import AetherRouteKit
import AppKit
import OSLog
import SwiftUI

@MainActor
final class AppWindowManager: NSObject, NSWindowDelegate {
    static let shared = AppWindowManager()
    private static let logger = AppLog.logger(category: AppLog.Category.appLifecycle)

    private(set) weak var mainWindow: NSWindow?
    var isTerminating = false
    var openWindowAction: (() -> Void)?

    override private init() {
        super.init()
    }

    func registerMainWindow(_ window: NSWindow) {
        guard mainWindow !== window else { return }
        mainWindow = window
        window.isReleasedWhenClosed = false
        window.delegate = self
        Self.logger.info(
            "MainWindow registered with AppWindowManager: windowNumber=\(window.windowNumber)"
        )
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

        // Fallback: search for a candidate window in NSApplication.shared.windows
        if let window = NSApplication.shared.windows.first(where: {
            !($0 is NSPanel) && $0.canBecomeMain
        }) {
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isTerminating {
            return true
        }
        sender.orderOut(nil)
        return false
    }
}

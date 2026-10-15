import AppKit
import Foundation
import SwiftUI

enum AppLocalization {
    static func string(_ value: String) -> String { value }
}

@main struct MenuBarIconTests {
    @MainActor
    static func main() {
        print("Running menu bar icon tests...")

        // 1. Verify all 41 icon options and their SF Symbols in AppKit
        let allCases = AppMenuBarIconOption.allCases
        precondition(allCases.count == 41, "Expected exactly 41 menu bar icon options, got \(allCases.count)")

        for option in allCases {
            let unconnected = option.unconnectedSymbol
            let connected = option.connectedSymbol
            precondition(!unconnected.isEmpty, "\(option.rawValue) unconnectedSymbol must not be empty")
            precondition(!connected.isEmpty, "\(option.rawValue) connectedSymbol must not be empty")

            let config = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
            guard let unImg = NSImage(systemSymbolName: unconnected, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                fatalError("Missing system symbol for unconnected: \(unconnected) (option: \(option.rawValue))")
            }
            precondition(unImg.size.width > 0 && unImg.size.height > 0)

            guard let connImg = NSImage(systemSymbolName: connected, accessibilityDescription: nil)?
                .withSymbolConfiguration(config) else {
                fatalError("Missing system symbol for connected: \(connected) (option: \(option.rawValue))")
            }
            precondition(connImg.size.width > 0 && connImg.size.height > 0)

            precondition(option.symbol(isConnected: false) == unconnected)
            precondition(option.symbol(isConnected: true) == connected)
            precondition(!option.localizedTitle.isEmpty, "\(option.rawValue) localized title must not be empty")
        }

        // 2. Verify MenuBarBadgedIcon generation with all symbols
        for option in allCases {
            let symbol = option.connectedSymbol
            let badgedImage = MenuBarBadgedIcon.image(symbol: symbol)
            precondition(badgedImage.size.width > 0 && badgedImage.size.height > 0, "Badged image generation failed for \(symbol)")
        }

        // 3. Verify AppMenuBarIconController persistence and fallback isolation
        let suiteName = "com.aetherroute.test.menubaricon.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        // Test default value
        let controller = AppMenuBarIconController(defaults: testDefaults)
        precondition(controller.currentIcon == .paperplane, "Default icon must be .paperplane")
        precondition(controller.currentSymbol(isConnected: false) == "paperplane")
        precondition(controller.currentSymbol(isConnected: true) == "paperplane.fill")

        // Test switching to flame
        controller.select(.flame)
        precondition(controller.currentIcon == .flame)
        precondition(testDefaults.string(forKey: AppMenuBarIconController.storageKey) == "flame")
        precondition(controller.currentSymbol(isConnected: false) == "flame")
        precondition(controller.currentSymbol(isConnected: true) == "flame.fill")

        // Test switching to cpu
        controller.select(.cpu)
        precondition(controller.currentIcon == .cpu)
        precondition(testDefaults.string(forKey: AppMenuBarIconController.storageKey) == "cpu")
        precondition(controller.currentSymbol(isConnected: false) == "cpu")
        precondition(controller.currentSymbol(isConnected: true) == "cpu.fill")

        // Test fallback on corrupt / unknown key
        testDefaults.set("unknown_corrupted_symbol_key", forKey: AppMenuBarIconController.storageKey)
        let restoredController = AppMenuBarIconController(defaults: testDefaults)
        precondition(restoredController.currentIcon == .paperplane, "Corrupt key must safely fall back to .paperplane")

        print("Menu bar icon tests passed: 41 paired SF Symbols verified, badge rendering passed, persistence and safe fallback verified.")
    }
}

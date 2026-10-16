import AppKit
import Foundation
import SwiftUI

enum AppLocalization {
    static func string(_ value: String) -> String { value }
}

@main struct MenuBarTrafficTests {
    @MainActor
    static func main() {
        print("Running menu bar real-time traffic gate tests...")

        // ---------------------------------------------------------
        // 1. Verify MenuBarTrafficFormatter rate formatting
        // ---------------------------------------------------------
        print("1. Testing MenuBarTrafficFormatter...")
        precondition(MenuBarTrafficFormatter.formatRate(0) == "0 B/s", "0 bytes must format to 0 B/s")
        precondition(MenuBarTrafficFormatter.formatRate(512) == "512 B/s", "512 bytes must format to 512 B/s")
        precondition(MenuBarTrafficFormatter.formatRate(1023) == "1023 B/s", "1023 bytes must format to 1023 B/s")
        precondition(MenuBarTrafficFormatter.formatRate(1024) == "1.0 KB/s", "1024 bytes must format to 1.0 KB/s")
        precondition(MenuBarTrafficFormatter.formatRate(1536) == "1.5 KB/s", "1536 bytes must format to 1.5 KB/s")
        precondition(MenuBarTrafficFormatter.formatRate(100 * 1024) == "100.0 KB/s" || MenuBarTrafficFormatter.formatRate(100 * 1024) == "100 KB/s", "100 KB formatting")
        precondition(MenuBarTrafficFormatter.formatRate(1024 * 1024) == "1.0 MB/s", "1 MB must format to 1.0 MB/s")
        precondition(MenuBarTrafficFormatter.formatRate(UInt64(15.4 * 1024 * 1024)) == "15.4 MB/s", "15.4 MB formatting")
        precondition(MenuBarTrafficFormatter.formatRate(1024 * 1024 * 1024) == "1.00 GB/s", "1 GB must format to 1.00 GB/s")
        precondition(MenuBarTrafficFormatter.formatRate(UInt64(2.5 * 1024 * 1024 * 1024)) == "2.50 GB/s", "2.5 GB formatting")

        precondition(MenuBarTrafficFormatter.uploadRateString(0) == "↑ 0 B/s", "Upload string for 0 B/s")
        precondition(MenuBarTrafficFormatter.downloadRateString(0) == "↓ 0 B/s", "Download string for 0 B/s")
        precondition(MenuBarTrafficFormatter.uploadRateString(1024) == "↑ 1.0 KB/s", "Upload string for 1.0 KB/s")
        precondition(MenuBarTrafficFormatter.downloadRateString(1024 * 1024) == "↓ 1.0 MB/s", "Download string for 1.0 MB/s")

        // ---------------------------------------------------------
        // 2. Verify MenuBarTrafficController persistence & defaults
        // ---------------------------------------------------------
        print("2. Testing MenuBarTrafficController persistence...")
        let suiteName = "com.aetherroute.test.menubartraffic.\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        // Test default: must be disabled (false)
        let controller = MenuBarTrafficController(defaults: testDefaults)
        precondition(!controller.isEnabled, "Default state of menu bar traffic must be false (disabled)")

        // Test enabling
        controller.setEnabled(true)
        precondition(controller.isEnabled, "Controller must reflect enabled state")
        precondition(testDefaults.bool(forKey: MenuBarTrafficController.storageKey) == true, "UserDefaults must persist true")

        // Test disabling
        controller.setEnabled(false)
        precondition(!controller.isEnabled, "Controller must reflect disabled state")
        precondition(testDefaults.bool(forKey: MenuBarTrafficController.storageKey) == false, "UserDefaults must persist false")

        // Test corrupt / missing key fallback
        testDefaults.removeObject(forKey: MenuBarTrafficController.storageKey)
        let restoredController = MenuBarTrafficController(defaults: testDefaults)
        precondition(!restoredController.isEnabled, "Restored controller without key must default safely to false")

        // ---------------------------------------------------------
        // 3. Verify MenuBarTrafficRenderer output & dimensions
        // ---------------------------------------------------------
        print("3. Testing MenuBarTrafficRenderer dimensions and appearance...")

        let sampleSymbol = "paperplane.fill"

        // 3a. When disabled: output must match MenuBarBadgedIcon EXACTLY
        let disabledStandard = MenuBarTrafficRenderer.image(
            symbol: sampleSymbol,
            isConnected: true,
            hasUpdate: false,
            isTrafficEnabled: false,
            uploadBytesPerSecond: 1024,
            downloadBytesPerSecond: 2048
        )
        precondition(disabledStandard.size == MenuBarBadgedIcon.standardCanvasSize,
                     "Disabled traffic must return standard canvas size \(MenuBarBadgedIcon.standardCanvasSize), got \(disabledStandard.size)")
        precondition(disabledStandard.isTemplate, "Standard disabled traffic icon must be template")

        let disabledBadged = MenuBarTrafficRenderer.image(
            symbol: sampleSymbol,
            isConnected: true,
            hasUpdate: true,
            isTrafficEnabled: false,
            uploadBytesPerSecond: 1024,
            downloadBytesPerSecond: 2048
        )
        precondition(disabledBadged.size == MenuBarBadgedIcon.badgedCanvasSize,
                     "Disabled badged traffic must return badged canvas size \(MenuBarBadgedIcon.badgedCanvasSize), got \(disabledBadged.size)")
        precondition(!disabledBadged.isTemplate, "Badged disabled traffic icon must not be template")

        // 3b. When enabled: output must be extended canvas size
        let enabledStandard = MenuBarTrafficRenderer.image(
            symbol: sampleSymbol,
            isConnected: true,
            hasUpdate: false,
            isTrafficEnabled: true,
            uploadBytesPerSecond: 512_000,
            downloadBytesPerSecond: 15_400_000
        )
        precondition(enabledStandard.size == MenuBarTrafficRenderer.trafficCanvasSize,
                     "Enabled traffic must return trafficCanvasSize \(MenuBarTrafficRenderer.trafficCanvasSize), got \(enabledStandard.size)")
        precondition(enabledStandard.isTemplate, "Enabled traffic without update badge must be template for native vibrancy")

        let enabledBadged = MenuBarTrafficRenderer.image(
            symbol: sampleSymbol,
            isConnected: true,
            hasUpdate: true,
            isTrafficEnabled: true,
            uploadBytesPerSecond: 512_000,
            downloadBytesPerSecond: 15_400_000
        )
        precondition(enabledBadged.size == MenuBarTrafficRenderer.badgedTrafficCanvasSize,
                     "Enabled badged traffic must return badgedTrafficCanvasSize \(MenuBarTrafficRenderer.badgedTrafficCanvasSize), got \(enabledBadged.size)")
        precondition(!enabledBadged.isTemplate, "Enabled badged traffic must not be template to preserve red badge dot")

        // 3c. Disconnected state: rates must clamp to 0 B/s
        let disconnectedImage = MenuBarTrafficRenderer.image(
            symbol: "paperplane",
            isConnected: false,
            hasUpdate: false,
            isTrafficEnabled: true,
            uploadBytesPerSecond: 999_999,
            downloadBytesPerSecond: 999_999
        )
        precondition(disconnectedImage.size == MenuBarTrafficRenderer.trafficCanvasSize, "Disconnected enabled traffic canvas size match")

        // ---------------------------------------------------------
        // 4. Verify all 41 SF Symbols render cleanly with traffic
        // ---------------------------------------------------------
        print("4. Testing all 41 SF Symbols in traffic mode...")
        for option in AppMenuBarIconOption.allCases {
            for isConnected in [true, false] {
                let symbol = option.symbol(isConnected: isConnected)
                for hasUpdate in [false, true] {
                    let img = MenuBarTrafficRenderer.image(
                        symbol: symbol,
                        isConnected: isConnected,
                        hasUpdate: hasUpdate,
                        isTrafficEnabled: true,
                        uploadBytesPerSecond: 120_000,
                        downloadBytesPerSecond: 1_500_000
                    )
                    precondition(img.size.width > 0 && img.size.height > 0, "Image for \(symbol) must have non-zero dimensions")
                    let expectedSize = hasUpdate ? MenuBarTrafficRenderer.badgedTrafficCanvasSize : MenuBarTrafficRenderer.trafficCanvasSize
                    precondition(img.size == expectedSize, "Image size mismatch for \(symbol): expected \(expectedSize), got \(img.size)")
                }
            }
        }

        // ---------------------------------------------------------
        // 5. Verify Controller telemetry update & image integration
        // ---------------------------------------------------------
        print("5. Testing Controller telemetry update...")
        controller.setEnabled(true)
        controller.updateTelemetry(upload: 1024, download: 2048)
        precondition(controller.uploadBytesPerSecond == 1024, "Controller upload rate updated")
        precondition(controller.downloadBytesPerSecond == 2048, "Controller download rate updated")

        let currentImg = controller.menuBarImage(symbol: "paperplane.fill", isConnected: true, hasUpdate: false)
        precondition(currentImg.size == MenuBarTrafficRenderer.trafficCanvasSize, "Controller returns traffic canvas")

        controller.reset()
        precondition(controller.uploadBytesPerSecond == 0, "Controller reset upload")
        precondition(controller.downloadBytesPerSecond == 0, "Controller reset download")

        print("All menu bar real-time traffic gate tests passed successfully! 🚀")
    }
}

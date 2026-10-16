import AppKit
import Combine
import Foundation
import SwiftUI

/// Compact and fixed-alignment speed formatter optimized for macOS menu bar typography.
public enum MenuBarTrafficFormatter {
    public static func formatRate(_ bytes: UInt64) -> String {
        if bytes < 1024 {
            return "\(bytes) B/s"
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return String(format: "%.1f KB/s", kb)
        } else if bytes < 1024 * 1024 * 1024 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return String(format: "%.1f MB/s", mb)
        } else {
            let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
            return String(format: "%.2f GB/s", gb)
        }
    }

    public static func uploadRateString(_ bytes: UInt64) -> String {
        "↑ " + formatRate(bytes)
    }

    public static func downloadRateString(_ bytes: UInt64) -> String {
        "↓ " + formatRate(bytes)
    }
}

/// Dynamic AppKit NSImage renderer combining SF Symbols with pixel-aligned 2-line real-time traffic.
public enum MenuBarTrafficRenderer {
    public static let standardIconSize = MenuBarBadgedIcon.standardCanvasSize
    public static let badgedIconSize = MenuBarBadgedIcon.badgedCanvasSize
    public static let trafficCanvasSize = NSSize(width: 74, height: 18)
    public static let badgedTrafficCanvasSize = NSSize(width: 78, height: 18)

    public static func image(
        symbol: String,
        isConnected: Bool,
        hasUpdate: Bool = false,
        isTrafficEnabled: Bool,
        uploadBytesPerSecond: UInt64,
        downloadBytesPerSecond: UInt64
    ) -> NSImage {
        guard isTrafficEnabled else {
            return MenuBarBadgedIcon.image(symbol: symbol, hasUpdate: hasUpdate)
        }

        let canvas = hasUpdate ? badgedTrafficCanvasSize : trafficCanvasSize
        let iconAreaWidth: CGFloat = hasUpdate ? 21.0 : 18.0

        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)

        let image = NSImage(size: canvas, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .high

            // 1. Draw Icon
            if let glyph {
                let maxGlyphWidth: CGFloat = hasUpdate ? 15.0 : 16.0
                let maxGlyphHeight: CGFloat = 14.0

                let widthRatio = maxGlyphWidth / glyph.size.width
                let heightRatio = maxGlyphHeight / glyph.size.height
                let scale = min(widthRatio, heightRatio, 1.0)

                let drawWidth = round(glyph.size.width * scale)
                let drawHeight = round(glyph.size.height * scale)

                let drawX = round((iconAreaWidth - drawWidth) / 2.0)
                let drawY = round((canvas.height - drawHeight) / 2.0)
                let drawRect = NSRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

                if hasUpdate {
                    glyph.draw(in: drawRect)
                    NSColor.labelColor.set()
                    drawRect.fill(using: .sourceAtop)

                    // Accent color update badge
                    let dotSize: CGFloat = 5.0
                    let dotX = iconAreaWidth - dotSize - 0.5
                    let dotY = canvas.height - dotSize - 1.0
                    let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)

                    context.compositingOperation = .clear
                    NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.0, dy: -1.0)).fill()

                    context.compositingOperation = .sourceOver
                    NSColor.controlAccentColor.set()
                    NSBezierPath(ovalIn: dotRect).fill()
                } else {
                    glyph.draw(in: drawRect)
                }
            }

            // 2. Draw 2-line Monospaced Traffic Rates
            let uploadText = isConnected ? MenuBarTrafficFormatter.uploadRateString(uploadBytesPerSecond) : "↑ 0 B/s"
            let downloadText = isConnected ? MenuBarTrafficFormatter.downloadRateString(downloadBytesPerSecond) : "↓ 0 B/s"

            let font = NSFont.monospacedSystemFont(ofSize: 8.0, weight: .semibold)
            let textColor = hasUpdate ? NSColor.labelColor : NSColor.black

            let paragraphStyle = NSMutableParagraphStyle()
            paragraphStyle.alignment = .left
            paragraphStyle.lineBreakMode = .byClipping

            let attributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: paragraphStyle
            ]

            let textStartX = iconAreaWidth + 3.0
            let textWidth = canvas.width - textStartX - 1.0

            // Top Line: Upload (y: 9.0 to 17.5 in flipped: false)
            let uploadRect = NSRect(x: textStartX, y: 9.0, width: textWidth, height: 8.5)
            uploadText.draw(in: uploadRect, withAttributes: attributes)

            // Bottom Line: Download (y: 0.5 to 9.0 in flipped: false)
            let downloadRect = NSRect(x: textStartX, y: 0.5, width: textWidth, height: 8.5)
            downloadText.draw(in: downloadRect, withAttributes: attributes)

            return true
        }

        image.isTemplate = !hasUpdate
        return image
    }
}

/// Manages user settings and state for real-time network traffic in the macOS menu bar.
@MainActor
public final class MenuBarTrafficController: ObservableObject {
    public static let shared = MenuBarTrafficController()
    public static let storageKey = "AetherRouteMenuBarTrafficEnabled"

    @Published public private(set) var isEnabled: Bool
    @Published public private(set) var uploadBytesPerSecond: UInt64 = 0
    @Published public private(set) var downloadBytesPerSecond: UInt64 = 0

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isEnabled = defaults.bool(forKey: Self.storageKey)
    }

    public func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        defaults.set(enabled, forKey: Self.storageKey)
        if !enabled {
            reset()
        }
    }

    public func updateTelemetry(upload: UInt64, download: UInt64) {
        guard isEnabled else { return }
        if uploadBytesPerSecond != upload || downloadBytesPerSecond != download {
            uploadBytesPerSecond = upload
            downloadBytesPerSecond = download
        }
    }

    public func reset() {
        if uploadBytesPerSecond != 0 || downloadBytesPerSecond != 0 {
            uploadBytesPerSecond = 0
            downloadBytesPerSecond = 0
        }
    }

    public func menuBarImage(symbol: String, isConnected: Bool, hasUpdate: Bool = false) -> NSImage {
        MenuBarTrafficRenderer.image(
            symbol: symbol,
            isConnected: isConnected,
            hasUpdate: hasUpdate,
            isTrafficEnabled: isEnabled,
            uploadBytesPerSecond: uploadBytesPerSecond,
            downloadBytesPerSecond: downloadBytesPerSecond
        )
    }
}

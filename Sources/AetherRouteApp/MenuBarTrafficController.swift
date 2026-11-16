import AppKit
import Combine
import Foundation
import SwiftUI

/// Compact and fixed-alignment speed formatter optimized for macOS menu bar typography.
public enum MenuBarTrafficFormatter {
    public static func rateComponents(_ bytes: UInt64) -> (value: String, unit: String) {
        if bytes < 1024 {
            return ("\(bytes)", "B/s")
        } else if bytes < 1024 * 1024 {
            let kb = Double(bytes) / 1024.0
            return (String(format: "%.1f", kb), "KB/s")
        } else if bytes < 1024 * 1024 * 1024 {
            let mb = Double(bytes) / (1024.0 * 1024.0)
            return (String(format: "%.1f", mb), "MB/s")
        } else {
            let gb = Double(bytes) / (1024.0 * 1024.0 * 1024.0)
            return (String(format: "%.2f", gb), "GB/s")
        }
    }

    public static func formatRate(_ bytes: UInt64) -> String {
        let (val, unit) = rateComponents(bytes)
        return "\(val) \(unit)"
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
    public static let trafficCanvasSize = NSSize(width: 82, height: 18)
    public static let badgedTrafficCanvasSize = NSSize(width: 86, height: 18)

    private struct CacheKey: Hashable {
        let symbol: String
        let isConnected: Bool
        let hasUpdate: Bool
        let uploadValue: String
        let uploadUnit: String
        let downloadValue: String
        let downloadUnit: String
    }

    /// Tiny LRU cache (capped at 4 entries) so repeated `MenuBarStatusItemView`
    /// evaluations return the exact `NSImage` without growing memory during
    /// continuous rate changes (`Tests/MenuBarTraffic/transforms.swift`).
    private final class BoundedImageCache: @unchecked Sendable {
        private let lock = NSLock()
        private let capacity = 4
        private var entries: [CacheKey: NSImage] = [:]
        private var order: [CacheKey] = []

        func get(_ key: CacheKey) -> NSImage? {
            lock.lock()
            defer { lock.unlock() }
            guard let image = entries[key] else { return nil }
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
                order.append(key)
            }
            return image
        }

        func set(_ image: NSImage, for key: CacheKey) {
            lock.lock()
            defer { lock.unlock() }
            entries[key] = image
            if let index = order.firstIndex(of: key) {
                order.remove(at: index)
            }
            order.append(key)
            while order.count > capacity {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
        }
    }

    private final class LazyAppearanceVariantCache: @unchecked Sendable {
        private let lock = NSLock()
        private let sourceImage: NSImage
        private let canvas: NSSize
        private var reps: [NSAppearance.Name: NSBitmapImageRep] = [:]

        init(sourceImage: NSImage, canvas: NSSize) {
            self.sourceImage = sourceImage
            self.canvas = canvas
        }

        func bitmapRep(for appearanceName: NSAppearance.Name) -> NSBitmapImageRep? {
            lock.lock()
            if let existing = reps[appearanceName] {
                lock.unlock()
                return existing
            }
            lock.unlock()

            var built: NSBitmapImageRep?
            NSAppearance(named: appearanceName)?.performAsCurrentDrawingAppearance {
                built = MenuBarTrafficRenderer.rasterizeBitmapRep(sourceImage, canvas: canvas)
            }
            guard let built else { return nil }

            lock.lock()
            if let existing = reps[appearanceName] {
                lock.unlock()
                return existing
            }
            reps[appearanceName] = built
            lock.unlock()
            return built
        }
    }

    private static let cache = BoundedImageCache()

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

        let uploadComponents: (value: String, unit: String) = isConnected
            ? MenuBarTrafficFormatter.rateComponents(uploadBytesPerSecond)
            : (value: "0", unit: "B/s")
        let downloadComponents: (value: String, unit: String) = isConnected
            ? MenuBarTrafficFormatter.rateComponents(downloadBytesPerSecond)
            : (value: "0", unit: "B/s")

        let key = CacheKey(
            symbol: symbol,
            isConnected: isConnected,
            hasUpdate: hasUpdate,
            uploadValue: uploadComponents.value,
            uploadUnit: uploadComponents.unit,
            downloadValue: downloadComponents.value,
            downloadUnit: downloadComponents.unit
        )
        if let cached = cache.get(key) {
            return cached
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

            // 2. Draw 2-line Monospaced Traffic Rates with Column-Aligned Typography
            // Resolve the dynamic color to a concrete sRGB value in the current
            // drawing appearance; CoreText intermittently dropped unresolved
            // dynamic colors from the attribute dictionary (nil value abort).
            let textColor = (hasUpdate ? NSColor.labelColor : NSColor.black)
                .usingColorSpace(.sRGB) ?? NSColor.black
            let font = trafficFont
            let valueAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: valueParagraphStyle
            ]
            let unitAttrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor,
                .paragraphStyle: unitParagraphStyle
            ]

            let textStartX = iconAreaWidth + 2.0
            let arrowWidth: CGFloat = 6.0
            let valueWidth: CGFloat = 28.0
            let valueUnitGap: CGFloat = 2.5
            let unitWidth: CGFloat = 22.0

            let arrowX = textStartX
            let valueX = arrowX + arrowWidth
            let unitX = valueX + valueWidth + valueUnitGap

            let lineHeight: CGFloat = 8.5

            // Top Line: Upload (y: 9.0 to 17.5 in flipped: false)
            drawArrow(up: true, in: NSRect(x: arrowX, y: 9.0, width: arrowWidth, height: lineHeight), color: textColor)
            uploadComponents.value.draw(in: NSRect(x: valueX, y: 9.0, width: valueWidth, height: lineHeight), withAttributes: valueAttrs)
            uploadComponents.unit.draw(in: NSRect(x: unitX, y: 9.0, width: unitWidth, height: lineHeight), withAttributes: unitAttrs)

            // Bottom Line: Download (y: 0.5 to 9.0 in flipped: false)
            drawArrow(up: false, in: NSRect(x: arrowX, y: 0.5, width: arrowWidth, height: lineHeight), color: textColor)
            downloadComponents.value.draw(in: NSRect(x: valueX, y: 0.5, width: valueWidth, height: lineHeight), withAttributes: valueAttrs)
            downloadComponents.unit.draw(in: NSRect(x: unitX, y: 0.5, width: unitWidth, height: lineHeight), withAttributes: unitAttrs)

            return true
        }

        // Finish text drawing in fixed Retina contexts (`rasterize`). Colored
        // labels must still follow the native status item's drawing appearance,
        // which can differ from the appearance in which SwiftUI created the image.
        guard hasUpdate else {
            guard let rendered = rasterize(image, canvas: canvas) else {
                return MenuBarBadgedIcon.image(symbol: symbol, hasUpdate: false)
            }
            rendered.isTemplate = true
            cache.set(rendered, for: key)
            return rendered
        }
        let names: [NSAppearance.Name] = [
            .aqua, .darkAqua, .vibrantLight, .vibrantDark,
            .accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua,
            .accessibilityHighContrastVibrantLight, .accessibilityHighContrastVibrantDark
        ]
        let variantCache = LazyAppearanceVariantCache(sourceImage: image, canvas: canvas)
        let currentName = NSAppearance.currentDrawing().bestMatch(from: names) ?? .aqua
        guard variantCache.bitmapRep(for: currentName) != nil else {
            return MenuBarBadgedIcon.image(symbol: symbol, hasUpdate: true)
        }
        let rendered = NSImage(size: canvas, flipped: false) { _ in
            let name = NSAppearance.currentDrawing().bestMatch(from: names) ?? .aqua
            guard let rep = variantCache.bitmapRep(for: name) else { return false }
            return rep.draw(in: NSRect(origin: .zero, size: canvas))
        }
        rendered.isTemplate = false
        cache.set(rendered, for: key)
        return rendered
    }

    // Immutable shared typography: built once instead of per frame.
    nonisolated(unsafe) private static let trafficFont =
        NSFont.monospacedSystemFont(ofSize: 8.0, weight: .semibold)
    nonisolated(unsafe) private static let valueParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        style.lineBreakMode = .byClipping
        return style.copy() as! NSParagraphStyle
    }()
    nonisolated(unsafe) private static let unitParagraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.alignment = .left
        style.lineBreakMode = .byClipping
        return style.copy() as! NSParagraphStyle
    }()

    /// Crisp vector arrow; avoids font fallback for the arrow glyphs.
    private static func drawArrow(up: Bool, in rect: NSRect, color: NSColor) {
        let midX = rect.midX
        let top = rect.minY + 1.5
        let bottom = rect.maxY - 1.5
        let head: CGFloat = 2.0
        let path = NSBezierPath()
        path.lineWidth = 1.0
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: NSPoint(x: midX, y: top))
        path.line(to: NSPoint(x: midX, y: bottom))
        let tip = up ? bottom : top
        let dir: CGFloat = up ? -1 : 1
        path.move(to: NSPoint(x: midX - head, y: tip + dir * head))
        path.line(to: NSPoint(x: midX, y: tip))
        path.line(to: NSPoint(x: midX + head, y: tip + dir * head))
        color.setStroke()
        path.stroke()
    }

    private static func rasterizeBitmapRep(_ image: NSImage, canvas: NSSize) -> NSBitmapImageRep? {
        guard let pixels = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
            isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0
        ) else {
            return nil
        }
        pixels.size = canvas
        guard let context = NSGraphicsContext(bitmapImageRep: pixels) else {
            return nil
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // NSGraphicsContext derives its 2x transform from pixels.size.
        context.cgContext.clear(CGRect(origin: .zero, size: canvas))
        image.draw(in: NSRect(origin: .zero, size: canvas), from: .zero,
                   operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return pixels
    }

    private static func rasterize(_ image: NSImage, canvas: NSSize) -> NSImage? {
        guard let pixels = rasterizeBitmapRep(image, canvas: canvas) else {
            return nil
        }
        let rendered = NSImage(size: canvas)
        rendered.addRepresentation(pixels)
        return rendered
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
    public var onEnabledChanged: ((Bool) -> Void)?

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
        onEnabledChanged?(enabled)
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

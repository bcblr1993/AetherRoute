import AppKit
import Combine
import Foundation
import SwiftUI

/// Pre-validated SF Symbols available for menu bar customization.
/// Every case provides paired symbols: an outline glyph for disconnected
/// and a solid fill glyph for connected.
enum AppMenuBarIconOption: String, CaseIterable, Identifiable {
    // Default
    case paperplane
    // Nature & Celestial
    case bolt
    case star
    case heart
    case flame
    case sparkles
    case leaf
    case drop
    case snowflake
    case sun
    case moon
    case cloud
    case mountain
    // Geometry & Patterns
    case circle
    case square
    case triangle
    case diamond
    case hexagon
    case seal
    case halfMoon
    case honeycomb
    case infinity
    // Geek & Hardware
    case command
    case cpu
    case memorychip
    case gauge
    case fanblades
    case gearshape
    case terminal
    case waveform
    case magicWand
    case key
    case crown
    // Lifestyle & Mascot
    case gamecontroller
    case headphones
    case musicNote
    case pawprint
    case cat
    case hare
    case tortoise
    case ellipsis

    var id: String { rawValue }

    var unconnectedSymbol: String {
        switch self {
        case .paperplane: "paperplane"
        case .bolt: "bolt"
        case .star: "star"
        case .heart: "heart"
        case .flame: "flame"
        case .sparkles: "sparkles"
        case .leaf: "leaf"
        case .drop: "drop"
        case .snowflake: "snowflake"
        case .sun: "sun.max"
        case .moon: "moon"
        case .cloud: "cloud"
        case .mountain: "mountain.2"
        case .circle: "circle"
        case .square: "square"
        case .triangle: "triangle"
        case .diamond: "diamond"
        case .hexagon: "hexagon"
        case .seal: "seal"
        case .halfMoon: "circle.lefthalf.filled"
        case .honeycomb: "circle.hexagongrid"
        case .infinity: "infinity"
        case .command: "command"
        case .cpu: "cpu"
        case .memorychip: "memorychip"
        case .gauge: "gauge.with.needle"
        case .fanblades: "fanblades"
        case .gearshape: "gearshape"
        case .terminal: "terminal"
        case .waveform: "waveform"
        case .magicWand: "wand.and.stars"
        case .key: "key"
        case .crown: "crown"
        case .gamecontroller: "gamecontroller"
        case .headphones: "headphones"
        case .musicNote: "music.note"
        case .pawprint: "pawprint"
        case .cat: "cat"
        case .hare: "hare"
        case .tortoise: "tortoise"
        case .ellipsis: "ellipsis.circle"
        }
    }

    var connectedSymbol: String {
        switch self {
        case .paperplane: "paperplane.fill"
        case .bolt: "bolt.fill"
        case .star: "star.fill"
        case .heart: "heart.fill"
        case .flame: "flame.fill"
        case .sparkles: "sparkles"
        case .leaf: "leaf.fill"
        case .drop: "drop.fill"
        case .snowflake: "snowflake"
        case .sun: "sun.max.fill"
        case .moon: "moon.fill"
        case .cloud: "cloud.fill"
        case .mountain: "mountain.2.fill"
        case .circle: "circle.fill"
        case .square: "square.fill"
        case .triangle: "triangle.fill"
        case .diamond: "diamond.fill"
        case .hexagon: "hexagon.fill"
        case .seal: "seal.fill"
        case .halfMoon: "circle.lefthalf.filled"
        case .honeycomb: "circle.hexagongrid.fill"
        case .infinity: "infinity"
        case .command: "command"
        case .cpu: "cpu.fill"
        case .memorychip: "memorychip.fill"
        case .gauge: "gauge.with.needle.fill"
        case .fanblades: "fanblades.fill"
        case .gearshape: "gearshape.fill"
        case .terminal: "terminal.fill"
        case .waveform: "waveform"
        case .magicWand: "wand.and.stars.inverse"
        case .key: "key.fill"
        case .crown: "crown.fill"
        case .gamecontroller: "gamecontroller.fill"
        case .headphones: "headphones"
        case .musicNote: "music.note"
        case .pawprint: "pawprint.fill"
        case .cat: "cat.fill"
        case .hare: "hare.fill"
        case .tortoise: "tortoise.fill"
        case .ellipsis: "ellipsis.circle.fill"
        }
    }

    var localizedTitle: String {
        switch self {
        case .paperplane: AppLocalization.string("Paperplane (Default)")
        case .bolt: AppLocalization.string("Lightning")
        case .star: AppLocalization.string("Star")
        case .heart: AppLocalization.string("Heart")
        case .flame: AppLocalization.string("Flame")
        case .sparkles: AppLocalization.string("Sparkles")
        case .leaf: AppLocalization.string("Leaf")
        case .drop: AppLocalization.string("Drop")
        case .snowflake: AppLocalization.string("Snowflake")
        case .sun: AppLocalization.string("Sun")
        case .moon: AppLocalization.string("Moon")
        case .cloud: AppLocalization.string("Cloud")
        case .mountain: AppLocalization.string("Mountain")
        case .circle: AppLocalization.string("Circle")
        case .square: AppLocalization.string("Square")
        case .triangle: AppLocalization.string("Triangle")
        case .diamond: AppLocalization.string("Diamond")
        case .hexagon: AppLocalization.string("Hexagon")
        case .seal: AppLocalization.string("Seal")
        case .halfMoon: AppLocalization.string("Half Moon")
        case .honeycomb: AppLocalization.string("Honeycomb")
        case .infinity: AppLocalization.string("Infinity")
        case .command: AppLocalization.string("Command")
        case .cpu: AppLocalization.string("CPU")
        case .memorychip: AppLocalization.string("Memory")
        case .gauge: AppLocalization.string("Gauge")
        case .fanblades: AppLocalization.string("Fan")
        case .gearshape: AppLocalization.string("Gear")
        case .terminal: AppLocalization.string("Terminal")
        case .waveform: AppLocalization.string("Waveform")
        case .magicWand: AppLocalization.string("Magic Wand")
        case .key: AppLocalization.string("Key")
        case .crown: AppLocalization.string("Crown")
        case .gamecontroller: AppLocalization.string("Gamepad")
        case .headphones: AppLocalization.string("Headphones")
        case .musicNote: AppLocalization.string("Music")
        case .pawprint: AppLocalization.string("Paw")
        case .cat: AppLocalization.string("Cat")
        case .hare: AppLocalization.string("Rabbit")
        case .tortoise: AppLocalization.string("Turtle")
        case .ellipsis: AppLocalization.string("Ellipsis")
        }
    }

    func symbol(isConnected: Bool) -> String {
        isConnected ? connectedSymbol : unconnectedSymbol
    }
}

@MainActor
final class AppMenuBarIconController: ObservableObject {
    static let shared = AppMenuBarIconController()
    static let storageKey = "AetherRouteMenuBarIcon"

    @Published private(set) var currentIcon: AppMenuBarIconOption
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let raw = defaults.string(forKey: Self.storageKey),
           let option = AppMenuBarIconOption(rawValue: raw) {
            self.currentIcon = option
        } else {
            self.currentIcon = .paperplane
        }
    }

    func select(_ icon: AppMenuBarIconOption) {
        guard currentIcon != icon else { return }
        currentIcon = icon
        defaults.set(icon.rawValue, forKey: Self.storageKey)
    }

    func currentSymbol(isConnected: Bool) -> String {
        currentIcon.symbol(isConnected: isConnected)
    }

    func menuBarImage(isConnected: Bool, hasUpdate: Bool = false) -> NSImage {
        let symbol = currentSymbol(isConnected: isConnected)
        return MenuBarBadgedIcon.image(symbol: symbol, hasUpdate: hasUpdate)
    }
}

/// Generates standardized, uniform-sized, pixel-aligned crisp menu bar status item images.
enum MenuBarBadgedIcon {
    /// Standard canvas size for menu bar icon (width: 18, height: 18) ensuring identical footprint.
    static let standardCanvasSize = NSSize(width: 18, height: 18)
    /// Canvas with notification badge dot (width: 22, height: 18).
    static let badgedCanvasSize = NSSize(width: 22, height: 18)

    static func image(symbol: String, hasUpdate: Bool = true) -> NSImage {
        let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
        guard let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        else {
            return NSImage(size: hasUpdate ? badgedCanvasSize : standardCanvasSize)
        }

        let canvas = hasUpdate ? badgedCanvasSize : standardCanvasSize
        let maxGlyphWidth: CGFloat = hasUpdate ? 16.0 : 17.0
        let maxGlyphHeight: CGFloat = 15.0

        let widthRatio = maxGlyphWidth / glyph.size.width
        let heightRatio = maxGlyphHeight / glyph.size.height
        let scale = min(widthRatio, heightRatio, 1.0)

        let drawWidth = round(glyph.size.width * scale)
        let drawHeight = round(glyph.size.height * scale)

        let iconAreaWidth: CGFloat = hasUpdate ? 17.0 : canvas.width
        let drawX = round((iconAreaWidth - drawWidth) / 2.0)
        let drawY = round((canvas.height - drawHeight) / 2.0)
        let drawRect = NSRect(x: drawX, y: drawY, width: drawWidth, height: drawHeight)

        let image = NSImage(size: canvas, flipped: false) { _ in
            guard let context = NSGraphicsContext.current else { return false }
            context.imageInterpolation = .high

            if hasUpdate {
                // With update dot: draw glyph with labelColor so it adapts to menu bar vibrancy
                glyph.draw(in: drawRect)
                NSColor.labelColor.set()
                drawRect.fill(using: .sourceAtop)

                // Accent color update dot with thin transparent gap around it
                let dotSize: CGFloat = 5.0
                let dotX = canvas.width - dotSize - 0.5
                let dotY = canvas.height - dotSize - 1.0
                let dotRect = NSRect(x: dotX, y: dotY, width: dotSize, height: dotSize)

                context.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.0, dy: -1.0)).fill()

                context.compositingOperation = .sourceOver
                NSColor.controlAccentColor.set()
                NSBezierPath(ovalIn: dotRect).fill()
            } else {
                // Pure template: drawn directly, AppKit applies system vector template caching & vibrancy
                glyph.draw(in: drawRect)
            }
            return true
        }

        image.isTemplate = !hasUpdate
        return image
    }
}


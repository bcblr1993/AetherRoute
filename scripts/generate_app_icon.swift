#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let sizes = [16, 32, 64, 128, 256, 512, 1024]
private let outputDirectory: URL = {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--output-directory" {
        return URL(fileURLWithPath: arguments[2], isDirectory: true)
    }
    precondition(arguments.count == 1)
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset")
}()

// MARK: - Design grid
//
// The handoff draws on a 96-unit grid, and that grid maps onto the 512 px
// graphic safe area centred on the 1024 px canvas.

private let canvasSide: CGFloat = 1024
private let tileInset: CGFloat = 100
private let tileSide: CGFloat = 824
private let safeAreaSide: CGFloat = 512
private let gridSide: CGFloat = 96
private let safeAreaOrigin = (canvasSide - safeAreaSide) / 2
private let unit = safeAreaSide / gridSide

/// Converts a point on the 96-unit design grid to canvas coordinates.
private func grid(_ x: CGFloat, _ y: CGFloat, side: CGFloat) -> CGPoint {
    let scale = side / canvasSide
    return CGPoint(
        x: (safeAreaOrigin + x * unit) * scale,
        y: (safeAreaOrigin + y * unit) * scale
    )
}

private func gridLength(_ value: CGFloat, side: CGFloat) -> CGFloat {
    value * unit * side / canvasSide
}

// MARK: - Geometry

/// The three renditions are drawn separately rather than scaled down from one
/// another: below 64 px the half-opacity right arc turns to mud, and below
/// 32 px the arcs go with it. Only the route survives at 16 px.
private struct Rendition {
    let stroke: CGFloat
    let arcs: Bool
    let rightArc: Bool
    /// Vertical chord endpoints and radius of the left arc, in grid units.
    let arcTop: CGFloat
    let arcRadius: CGFloat
    let routeStart: CGFloat
    let routeEnd: CGFloat
    let arrowTip: CGFloat
    let arrowBack: CGFloat
    let arrowRise: CGFloat

    static let full = Rendition(
        stroke: 13, arcs: true, rightArc: true,
        arcTop: 14, arcRadius: 38,
        routeStart: 18, routeEnd: 58,
        arrowTip: 66, arrowBack: 50, arrowRise: 15
    )
    static let compact = Rendition(
        stroke: 15, arcs: true, rightArc: false,
        arcTop: 16, arcRadius: 36,
        routeStart: 20, routeEnd: 58,
        arrowTip: 65, arrowBack: 50, arrowRise: 14
    )
    static let minimal = Rendition(
        stroke: 19, arcs: false, rightArc: false,
        arcTop: 0, arcRadius: 0,
        routeStart: 20, routeEnd: 56,
        arrowTip: 67, arrowBack: 50, arrowRise: 16
    )

    static func forPixelSize(_ size: Int) -> Rendition {
        if size <= 16 { return .minimal }
        if size <= 32 { return .compact }
        return .full
    }
}

/// Approximates a circular arc with cubic Béziers. Working from explicit
/// angles keeps the result independent of the drawing API's winding
/// convention, which is easy to get backwards under a flipped CTM.
private func appendArc(
    to path: CGMutablePath,
    center: CGPoint,
    radius: CGFloat,
    from start: CGFloat,
    to end: CGFloat
) {
    let total = end - start
    let segments = max(1, Int(ceil(abs(total) / (.pi / 2))))
    let step = total / CGFloat(segments)
    let k = 4.0 / 3.0 * tan(step / 4)

    var angle = start
    var current = CGPoint(
        x: center.x + radius * cos(angle),
        y: center.y + radius * sin(angle)
    )
    path.move(to: current)
    for _ in 0..<segments {
        let next = angle + step
        let target = CGPoint(
            x: center.x + radius * cos(next),
            y: center.y + radius * sin(next)
        )
        let control1 = CGPoint(
            x: current.x - k * radius * sin(angle),
            y: current.y + k * radius * cos(angle)
        )
        let control2 = CGPoint(
            x: target.x + k * radius * sin(next),
            y: target.y - k * radius * cos(next)
        )
        path.addCurve(to: target, control1: control1, control2: control2)
        angle = next
        current = target
    }
}

/// The arc is specified by a vertical chord plus a radius, bulging away from
/// the centre line. Solving for the centre keeps the two arcs exactly
/// symmetrical about x = 48.
private func arcPath(_ rendition: Rendition, left: Bool, side: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let chordX: CGFloat = left ? 32 : 64
    let top = rendition.arcTop
    let bottom = gridSide - top
    let halfChord = (bottom - top) / 2
    let offset = sqrt(rendition.arcRadius * rendition.arcRadius - halfChord * halfChord)
    let centerX = left ? chordX + offset : chordX - offset
    let center = grid(centerX, gridSide / 2, side: side)
    let radius = gridLength(rendition.arcRadius, side: side)

    // Angles measured in the flipped drawing space, where y grows downward.
    // The half-sweep is taken from the bulge direction out to the chord, which
    // selects the minor arc the handoff asks for (large-arc-flag 0).
    let sweep = atan2(halfChord, offset)
    let through: CGFloat = left ? .pi : 0
    appendArc(to: path, center: center, radius: radius, from: through - sweep, to: through + sweep)
    return path
}

private func routePath(_ rendition: Rendition, side: CGFloat) -> CGPath {
    let path = CGMutablePath()
    let axis = gridSide / 2
    path.move(to: grid(rendition.routeStart, axis, side: side))
    path.addLine(to: grid(rendition.routeEnd, axis, side: side))
    path.move(to: grid(rendition.arrowBack, axis - rendition.arrowRise, side: side))
    path.addLine(to: grid(rendition.arrowTip, axis, side: side))
    path.addLine(to: grid(rendition.arrowBack, axis + rendition.arrowRise, side: side))
    return path
}

// MARK: - Rendering

private func superellipse(in rect: CGRect, exponent: CGFloat = 5) -> CGPath {
    let path = CGMutablePath()
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let a = rect.width / 2
    let b = rect.height / 2
    for step in 0...256 {
        let angle = CGFloat(step) / 256 * .pi * 2
        let cosine = cos(angle)
        let sine = sin(angle)
        let x = a * (cosine < 0 ? -1 : 1) * pow(abs(cosine), 2 / exponent)
        let y = b * (sine < 0 ? -1 : 1) * pow(abs(sine), 2 / exponent)
        let value = CGPoint(x: center.x + x, y: center.y + y)
        step == 0 ? path.move(to: value) : path.addLine(to: value)
    }
    path.closeSubpath()
    return path
}

private func drawGradient(_ context: CGContext, side: CGFloat) {
    let colors = [
        CGColor(red: 0x4C / 255, green: 0xA8 / 255, blue: 0xFF / 255, alpha: 1),
        CGColor(red: 0x0A / 255, green: 0x6E / 255, blue: 0xFA / 255, alpha: 1),
        CGColor(red: 0x09 / 255, green: 0x42 / 255, blue: 0xA8 / 255, alpha: 1),
    ]
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
        colors: colors as CFArray,
        locations: [0, 0.55, 1]
    )!
    // 160 degrees, measured in the design coordinate system.
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 0.86 * side, y: 0.08 * side),
        end: CGPoint(x: 0.14 * side, y: 0.92 * side),
        options: []
    )
}

private func render(size: Int) throws -> Data {
    let side = CGFloat(size)
    let scale = side / canvasSide
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw NSError(domain: "AetherRouteIcon", code: 1) }

    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    let tile = CGRect(
        x: tileInset * scale,
        y: tileInset * scale,
        width: tileSide * scale,
        height: tileSide * scale
    )
    context.saveGState()
    context.addPath(superellipse(in: tile))
    context.clip()
    drawGradient(context, side: side)
    context.restoreGState()

    let rendition = Rendition.forPixelSize(size)
    context.setLineWidth(gridLength(rendition.stroke, side: side))
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))

    if rendition.arcs {
        context.addPath(arcPath(rendition, left: true, side: side))
        context.strokePath()
    }
    if rendition.rightArc {
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.45))
        context.addPath(arcPath(rendition, left: false, side: side))
        context.strokePath()
        context.restoreGState()
    }
    context.addPath(routePath(rendition, side: side))
    context.strokePath()

    guard let image = context.makeImage() else {
        throw NSError(domain: "AetherRouteIcon", code: 2)
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AetherRouteIcon", code: 3)
    }
    return data
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for size in sizes {
    let output = outputDirectory.appendingPathComponent("AppIcon-\(size).png")
    try render(size: size).write(to: output, options: .atomic)
    print("Generated \(output.path)")
}

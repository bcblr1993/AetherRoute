#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let side: CGFloat = 1024
private let outputDirectory: URL = {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--output-directory" {
        return URL(fileURLWithPath: arguments[2], isDirectory: true)
    }
    precondition(arguments.count == 1)
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/AetherRouteApp/AppIcon.icon/Assets")
}()

// The 96-unit design grid maps onto the 664 px graphic safe area, not the whole
// canvas. That is what puts the specified 13-unit stroke at 90 px, and it keeps
// these layers in register with the flattened Assets.xcassets renditions.
private let safeAreaSide: CGFloat = 664
private let gridSide: CGFloat = 96
private let safeAreaOrigin = (side - safeAreaSide) / 2
private let unit = safeAreaSide / gridSide
private let strokeUnits: CGFloat = 13
private let arcTop: CGFloat = 14
private let arcRadius: CGFloat = 38

private enum Layer: String, CaseIterable { case portal = "Portal.png"; case route = "Route.png" }

private func grid(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
    CGPoint(x: safeAreaOrigin + x * unit, y: safeAreaOrigin + y * unit)
}

/// Approximates a circular arc with cubic Béziers so the result does not depend
/// on the drawing API's winding convention under a flipped CTM.
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

private func arc(left: Bool) -> CGPath {
    let path = CGMutablePath()
    let chordX: CGFloat = left ? 32 : 64
    let halfChord = (gridSide - 2 * arcTop) / 2
    let offset = sqrt(arcRadius * arcRadius - halfChord * halfChord)
    let center = grid(left ? chordX + offset : chordX - offset, gridSide / 2)
    // Half-sweep taken from the bulge direction out to the chord, which selects
    // the minor arc the handoff specifies.
    let sweep = atan2(halfChord, offset)
    let through: CGFloat = left ? .pi : 0
    appendArc(
        to: path,
        center: center,
        radius: arcRadius * unit,
        from: through - sweep,
        to: through + sweep
    )
    return path
}

private func route() -> CGPath {
    let path = CGMutablePath()
    let axis = gridSide / 2
    path.move(to: grid(18, axis))
    path.addLine(to: grid(58, axis))
    path.move(to: grid(50, axis - 15))
    path.addLine(to: grid(66, axis))
    path.addLine(to: grid(50, axis + 15))
    return path
}

private func render(_ layer: Layer) throws -> Data {
    let context = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setAllowsAntialiasing(true); context.setShouldAntialias(true)
    context.translateBy(x: 0, y: side); context.scaleBy(x: 1, y: -1)
    context.setLineWidth(strokeUnits * unit); context.setLineCap(.round); context.setLineJoin(.round)
    switch layer {
    case .portal:
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.addPath(arc(left: true)); context.strokePath()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.45)); context.addPath(arc(left: false)); context.strokePath()
    case .route:
        context.setStrokeColor(CGColor(gray: 1, alpha: 1)); context.addPath(route()); context.strokePath()
    }
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for layer in Layer.allCases {
    let output = outputDirectory.appendingPathComponent(layer.rawValue)
    try render(layer).write(to: output, options: .atomic)
    print("Generated \(output.path)")
}

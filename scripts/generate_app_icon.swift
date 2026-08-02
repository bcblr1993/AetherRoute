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
    precondition(
        arguments.count == 1,
        "Usage: generate_app_icon.swift [--output-directory PATH]"
    )
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset")
}()

private func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> CGPoint {
    CGPoint(x: x * size, y: y * size)
}

private func gatePath(size: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: point(0.675, 0.195, size: size))
    path.addCurve(
        to: point(0.255, 0.255, size: size),
        control1: point(0.555, 0.125, size: size),
        control2: point(0.370, 0.145, size: size)
    )
    path.addCurve(
        to: point(0.255, 0.755, size: size),
        control1: point(0.105, 0.395, size: size),
        control2: point(0.105, 0.625, size: size)
    )
    path.addCurve(
        to: point(0.755, 0.735, size: size),
        control1: point(0.395, 0.885, size: size),
        control2: point(0.620, 0.875, size: size)
    )
    path.addCurve(
        to: point(0.825, 0.590, size: size),
        control1: point(0.805, 0.685, size: size),
        control2: point(0.830, 0.635, size: size)
    )
    return path
}

private func risingRoutePath(size: CGFloat) -> CGPath {
    let path = CGMutablePath()
    path.move(to: point(0.265, 0.700, size: size))
    path.addCurve(
        to: point(0.505, 0.625, size: size),
        control1: point(0.360, 0.745, size: size),
        control2: point(0.445, 0.695, size: size)
    )
    path.addCurve(
        to: point(0.705, 0.340, size: size),
        control1: point(0.585, 0.535, size: size),
        control2: point(0.620, 0.455, size: size)
    )
    path.addCurve(
        to: point(0.840, 0.300, size: size),
        control1: point(0.755, 0.310, size: size),
        control2: point(0.805, 0.300, size: size)
    )
    return path
}

private func drawLinearGradient(
    _ context: CGContext,
    colors: [CGColor],
    start: CGPoint,
    end: CGPoint
) {
    let locations = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
    guard let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
        colors: colors as CFArray,
        locations: locations
    ) else { return }
    context.drawLinearGradient(
        gradient,
        start: start,
        end: end,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

private func render(size: Int) throws -> Data {
    let side = CGFloat(size)
    guard let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AetherRouteIcon", code: 1)
    }

    context.interpolationQuality = .high
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // Bitmap contexts use a lower-left origin. The SwiftUI glyph uses the
    // AppKit convention, so normalize to a top-left origin before drawing.
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)

    drawLinearGradient(
        context,
        colors: [
            CGColor(red: 0.17, green: 0.76, blue: 0.98, alpha: 1),
            CGColor(red: 0.04, green: 0.39, blue: 0.94, alpha: 1),
            CGColor(red: 0.21, green: 0.13, blue: 0.61, alpha: 1),
        ],
        start: point(0.08, 0.06, size: side),
        end: point(0.94, 0.94, size: side)
    )

    let glow = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.displayP3),
        colors: [
            CGColor(red: 0.92, green: 1.00, blue: 1.00, alpha: 0.38),
            CGColor(red: 0.18, green: 0.74, blue: 1.00, alpha: 0.0),
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        glow,
        startCenter: point(0.26, 0.20, size: side),
        startRadius: 0,
        endCenter: point(0.26, 0.20, size: side),
        endRadius: side * 0.72,
        options: [.drawsAfterEndLocation]
    )

    // A quiet lens behind the mark gives large renditions depth without
    // introducing detail that collapses at menu-bar size.
    if size >= 64 {
        let lensRect = CGRect(
            x: side * 0.175,
            y: side * 0.175,
            width: side * 0.650,
            height: side * 0.650
        )
        context.saveGState()
        context.setFillColor(CGColor(red: 0.90, green: 0.98, blue: 1.00, alpha: 0.055))
        context.fillEllipse(in: lensRect)
        context.setStrokeColor(CGColor(red: 0.94, green: 1.00, blue: 1.00, alpha: 0.13))
        context.setLineWidth(side * 0.006)
        context.strokeEllipse(in: lensRect.insetBy(dx: side * 0.003, dy: side * 0.003))
        context.restoreGState()
    }

    let gate = gatePath(size: side)
    let route = risingRoutePath(size: side)
    let gateWidth = side * (size <= 32 ? 0.096 : 0.074)
    let routeWidth = side * (size <= 32 ? 0.076 : 0.054)

    context.saveGState()
    context.addPath(gate)
    context.setLineWidth(gateWidth * 1.55)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.setShadow(
        offset: CGSize(width: 0, height: side * 0.018),
        blur: side * 0.052,
        color: CGColor(red: 0.72, green: 0.96, blue: 1.00, alpha: 0.34)
    )
    context.setStrokeColor(CGColor(red: 0.72, green: 0.96, blue: 1.00, alpha: 0.22))
    context.strokePath()
    context.restoreGState()

    context.saveGState()
    context.addPath(gate)
    context.setLineWidth(gateWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    drawLinearGradient(
        context,
        colors: [
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
            CGColor(red: 0.94, green: 0.99, blue: 1.00, alpha: 1),
            CGColor(red: 0.30, green: 0.86, blue: 1.00, alpha: 0.84),
        ],
        start: point(0.20, 0.18, size: side),
        end: point(0.82, 0.82, size: side)
    )
    context.restoreGState()

    if size >= 64 {
        context.saveGState()
        context.addPath(gate)
        context.setLineWidth(max(1, gateWidth * 0.16))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setStrokeColor(CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 0.52))
        context.translateBy(x: -side * 0.006, y: -side * 0.007)
        context.strokePath()
        context.restoreGState()
    }

    context.saveGState()
    context.addPath(route)
    context.setLineWidth(routeWidth)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.replacePathWithStrokedPath()
    context.clip()
    drawLinearGradient(
        context,
        colors: [
            CGColor(red: 0.72, green: 0.94, blue: 1.00, alpha: 0.82),
            CGColor(red: 0.18, green: 0.89, blue: 1.00, alpha: 1),
            CGColor(red: 1.00, green: 1.00, blue: 1.00, alpha: 1),
        ],
        start: point(0.28, 0.74, size: side),
        end: point(0.70, 0.32, size: side)
    )
    context.restoreGState()

    let dotCenter = point(0.840, 0.300, size: side)
    let dotRadius = side * (size <= 32 ? 0.050 : 0.039)
    context.saveGState()
    context.setShadow(
        offset: .zero,
        blur: side * 0.036,
        color: CGColor(red: 0.70, green: 0.96, blue: 1.00, alpha: 0.68)
    )
    context.setFillColor(CGColor(red: 0.94, green: 1.00, blue: 1.00, alpha: 1))
    context.fillEllipse(
        in: CGRect(
            x: dotCenter.x - dotRadius,
            y: dotCenter.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        )
    )
    context.restoreGState()

    guard let cgImage = context.makeImage() else {
        throw NSError(domain: "AetherRouteIcon", code: 2)
    }
    let bitmap = NSBitmapImageRep(cgImage: cgImage)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AetherRouteIcon", code: 3)
    }
    return data
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for size in sizes {
    let output = outputDirectory.appendingPathComponent("AppIcon-\(size).png")
    try render(size: size).write(to: output, options: .atomic)
    print("Generated \(output.path)")
}

#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

private let canvasSize = 1024
private let outputDirectory: URL = {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--output-directory" {
        return URL(fileURLWithPath: arguments[2], isDirectory: true)
    }
    precondition(
        arguments.count == 1,
        "Usage: generate_icon_composer_assets.swift [--output-directory PATH]"
    )
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/AetherRouteApp/AppIcon.icon/Assets")
}()

private enum Layer: String, CaseIterable {
    case portal = "Portal.png"
    case route = "Route.png"
}

private func point(_ x: CGFloat, _ y: CGFloat, size: CGFloat) -> CGPoint {
    CGPoint(x: x * size, y: y * size)
}

private func portalPath(size: CGFloat) -> CGPath {
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

private func routePath(size: CGFloat) -> CGPath {
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

private func render(_ layer: Layer) throws -> Data {
    let side = CGFloat(canvasSize)
    guard let context = CGContext(
        data: nil,
        width: canvasSize,
        height: canvasSize,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw NSError(domain: "AetherRouteIconComposer", code: 1)
    }

    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    context.setLineCap(.round)
    context.setLineJoin(.round)

    switch layer {
    case .portal:
        context.addPath(portalPath(size: side))
        context.setStrokeColor(
            CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        context.setLineWidth(76)
        context.strokePath()
    case .route:
        context.addPath(routePath(size: side))
        context.setStrokeColor(
            CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        context.setLineWidth(56)
        context.strokePath()

        let center = point(0.840, 0.300, size: side)
        context.setFillColor(
            CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        )
        context.fillEllipse(
            in: CGRect(
                x: center.x - 39,
                y: center.y - 39,
                width: 78,
                height: 78
            )
        )
    }

    guard let image = context.makeImage() else {
        throw NSError(domain: "AetherRouteIconComposer", code: 2)
    }
    let bitmap = NSBitmapImageRep(cgImage: image)
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "AetherRouteIconComposer", code: 3)
    }
    return data
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

for layer in Layer.allCases {
    let output = outputDirectory.appendingPathComponent(layer.rawValue)
    try render(layer).write(to: output, options: .atomic)
    print("Generated \(output.path)")
}

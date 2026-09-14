#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

// Icon Composer layer masks for the dot-matrix "A".
//
// Both files are white-on-transparent; icon.json supplies the real tint, which
// is why the ink/grey split lives there rather than here. Route carries the
// apex and crossbar, Portal the legs.
//
// The geometry below must stay in step with scripts/generate_icon_source.swift,
// which draws the same mark into the flattened master and the in-app emblem.
// verify_app_icon.sh re-runs this script and compares pixels, so a drift here
// fails the build rather than shipping two different marks.

private let side: CGFloat = 1024
private let dotRadius: CGFloat = 68
private let columns: [CGFloat] = [312, 512, 712]
private let rows: [CGFloat] = [312, 512, 712]

private enum Layer: String, CaseIterable {
    case portal = "Portal.png"
    case route = "Route.png"

    /// Centres in a top-down frame; `render` flips the context to match.
    var dots: [CGPoint] {
        switch self {
        case .route:
            [
                CGPoint(x: columns[1], y: rows[0]),
                CGPoint(x: columns[0], y: rows[1]),
                CGPoint(x: columns[1], y: rows[1]),
                CGPoint(x: columns[2], y: rows[1]),
            ]
        case .portal:
            [
                CGPoint(x: columns[0], y: rows[2]),
                CGPoint(x: columns[2], y: rows[2]),
            ]
        }
    }
}

private let outputDirectory: URL = {
    let arguments = CommandLine.arguments
    if arguments.count == 3, arguments[1] == "--output-directory" {
        return URL(fileURLWithPath: arguments[2], isDirectory: true)
    }
    precondition(arguments.count == 1)
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("Sources/AetherRouteApp/AppIcon.icon/Assets")
}()

private func render(_ layer: Layer) throws -> Data {
    let context = CGContext(
        data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.clear(CGRect(x: 0, y: 0, width: side, height: side))
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    context.translateBy(x: 0, y: side)
    context.scaleBy(x: 1, y: -1)
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    for dot in layer.dots {
        context.addEllipse(in: CGRect(
            x: dot.x - dotRadius,
            y: dot.y - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
    }
    context.fillPath()
    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
for layer in Layer.allCases {
    let output = outputDirectory.appendingPathComponent(layer.rawValue)
    try render(layer).write(to: output, options: .atomic)
    print("Generated \(output.path)")
}

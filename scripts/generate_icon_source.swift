#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

// Package the user-selected Silver Flight artwork without redrawing it.
// The checked-in original is the single source for Dock and in-app branding.
let root: URL = {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if FileManager.default.fileExists(atPath: current.appendingPathComponent("Design/AppIcon/SilverFlight.png").path) {
        return current
    }
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let candidate = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Design/AppIcon/SilverFlight.png").path) {
        return candidate
    }
    return current
}()
let args = CommandLine.arguments
precondition(args.count == 1 || (args.count == 3 && args[1] == "--output-directory"))
let output = args.count == 3 ? URL(fileURLWithPath: args[2]) : root
func render(_ filename: String) throws -> Data {
    let source = root.appendingPathComponent("Design/AppIcon/\(filename)")
    guard let image = NSImage(contentsOf: source),
          let bitmap = image.representations.first as? NSBitmapImageRep,
          let cgImage = bitmap.cgImage else { fatalError("Cannot load \(filename)") }
    let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
    return NSBitmapImageRep(cgImage: context.makeImage()!)
        .representation(using: .png, properties: [:])!
}
let light = try render("SilverFlight.png")
let dark = try render("SilverFlightDark.png")
for (path, data) in [
    ("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png", light),
    ("Sources/AetherRouteApp/Assets.xcassets/AetherSapphireEmblem.imageset/AetherSapphireEmblem.png", light),
    ("Sources/AetherRouteApp/Assets.xcassets/AetherSapphireEmblem.imageset/AetherSapphireEmblem-Dark.png", dark)
] {
    let url = output.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    print("Generated \(url.path)")
}

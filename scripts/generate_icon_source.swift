#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

// Package the user-selected Silver Flight artwork without redrawing it.
// The checked-in original is the single source for Dock and in-app branding.
let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let args = CommandLine.arguments
precondition(args.count == 1 || (args.count == 3 && args[1] == "--output-directory"))
let output = args.count == 3 ? URL(fileURLWithPath: args[2]) : root
let source = root.appendingPathComponent("Design/AppIcon/SilverFlight.png")
guard let image = NSImage(contentsOf: source),
      let bitmap = image.representations.first as? NSBitmapImageRep,
      let cgImage = bitmap.cgImage else { fatalError("Cannot load SilverFlight.png") }
let context = CGContext(data: nil, width: 1024, height: 1024, bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
context.interpolationQuality = .high
context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1024, height: 1024))
let rendered = NSBitmapImageRep(cgImage: context.makeImage()!)
let data = rendered.representation(using: .png, properties: [:])!
for path in [
    "Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png",
    "Sources/AetherRouteApp/Assets.xcassets/AetherSapphireEmblem.imageset/AetherSapphireEmblem.png"
] {
    let url = output.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
    print("Generated \(url.path)")
}

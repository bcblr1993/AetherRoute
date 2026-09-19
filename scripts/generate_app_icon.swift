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

private let repoRoot: URL = {
    let current = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    if FileManager.default.fileExists(atPath: current.appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").path) {
        return current
    }
    let scriptURL = URL(fileURLWithPath: CommandLine.arguments[0])
    let candidate = scriptURL.deletingLastPathComponent().deletingLastPathComponent()
    if FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png").path) {
        return candidate
    }
    return current
}()

let masterURL = repoRoot.appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")

guard let masterImage = NSImage(contentsOf: masterURL),
      let rep = masterImage.representations.first as? NSBitmapImageRep,
      let masterCG = rep.cgImage else {
    fatalError("Cannot load master AppIcon-1024.png")
}

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for size in sizes {
    if size == 1024 {
        let output = outputDirectory.appendingPathComponent("AppIcon-1024.png")
        if output.path != masterURL.path {
            let data = rep.representation(using: .png, properties: [:])!
            try data.write(to: output)
        }
        continue
    }
    guard let resizeCtx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Cannot create context for \(size)") }
    resizeCtx.interpolationQuality = .high
    resizeCtx.draw(masterCG, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let resizedCG = resizeCtx.makeImage() else { fatalError() }
    let resizedRep = NSBitmapImageRep(cgImage: resizedCG)
    guard let png = resizedRep.representation(using: .png, properties: [:]) else { fatalError() }
    let output = outputDirectory.appendingPathComponent("AppIcon-\(size).png")
    try png.write(to: output)
}

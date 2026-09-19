#!/usr/bin/env swift

import Foundation

// Keep the optional Icon Composer document on the same approved artwork.
let root: URL = {
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
let args = CommandLine.arguments
precondition(args.count == 1 || (args.count == 3 && args[1] == "--output-directory"))
let output = args.count == 3 ? URL(fileURLWithPath: args[2])
    : root.appendingPathComponent("Sources/AetherRouteApp/AppIcon.icon/Assets")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let source = root.appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png")
try Data(contentsOf: source).write(to: output.appendingPathComponent("SilverFlight.png"), options: .atomic)

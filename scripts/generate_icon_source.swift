#!/usr/bin/env swift

// Draws the AetherRoute mark: a dot-matrix "A" on a white squircle.
//
// Two outputs, both 1024x1024 in Display P3:
//   AppIcon-1024.png            the flattened master the renditions derive from
//   AetherSapphireEmblem.png    the same mark for in-app chrome
//
// The Icon Composer layer masks come from generate_icon_composer_assets.swift.
// The dot geometry is duplicated there and the two must stay in step;
// verify_app_icon.sh re-renders the masks and compares pixels, so a drift
// fails the build instead of shipping two different marks.

import AppKit
import CoreGraphics
import Foundation

let canvas = 1024.0
// Matches the previous artwork's optical size so the Dock silhouette is unchanged.
let plateInset = 89.0
let plateSize = canvas - plateInset * 2
// Apple's continuous-corner ratio for app icons.
let cornerRadius = plateSize * 0.2237

// A three-by-three matrix, the same density as the reference mark — the
// restraint is the point, so the letter has to fit in six dots rather than
// spelling itself out:
//
//        .  ●  .      apex
//        ●  ●  ●      crossbar
//        ●  .  ●      legs
//
// Ink carries apex and crossbar, grey carries the legs. That mirrors how the
// reference splits a solid centre against lighter outer dots, and it keeps the
// silhouette readable when the icon is 16pt.
let dotRadius = 68.0
private let columns = [312.0, 512.0, 712.0]
private let rows = [312.0, 512.0, 712.0]

// Apex and crossbar.
let darkDots: [(Double, Double)] = [
    (columns[1], rows[0]),
    (columns[0], rows[1]), (columns[1], rows[1]), (columns[2], rows[1]),
]
// Legs.
let greyDots: [(Double, Double)] = [
    (columns[0], rows[2]), (columns[2], rows[2]),
]

let plateColor = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
let darkColor = CGColor(srgbRed: 0.110, green: 0.110, blue: 0.118, alpha: 1)
// Lighter outer dots, matching the reference mark's two-tone depth.
let greyColor = CGColor(srgbRed: 0.604, green: 0.604, blue: 0.627, alpha: 1)

let outputRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let appIconSet = outputRoot
    .appendingPathComponent("Sources/AetherRouteApp/Assets.xcassets/AppIcon.appiconset")

func makeContext() -> CGContext {
    let space = CGColorSpace(name: CGColorSpace.displayP3)!
    guard let context = CGContext(
        data: nil,
        width: Int(canvas),
        height: Int(canvas),
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("cannot create bitmap context") }
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)
    return context
}

/// Core Graphics puts the origin at the bottom left; the dot table above reads
/// top-down, which is how the artwork was laid out.
func flip(_ y: Double) -> Double { canvas - y }

func addDots(_ dots: [(Double, Double)], to context: CGContext) {
    for (x, y) in dots {
        context.addEllipse(in: CGRect(
            x: x - dotRadius,
            y: flip(y) - dotRadius,
            width: dotRadius * 2,
            height: dotRadius * 2
        ))
    }
}

func write(_ context: CGContext, to url: URL) {
    guard let image = context.makeImage() else { fatalError("cannot render \(url.lastPathComponent)") }
    let rep = NSBitmapImageRep(cgImage: image)
    rep.size = NSSize(width: canvas, height: canvas)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("cannot encode \(url.lastPathComponent)")
    }
    try! data.write(to: url)
    print("wrote \(url.lastPathComponent)")
}

// 1. Flattened master: white plate plus both dot groups.
let master = makeContext()
let plate = CGPath(
    roundedRect: CGRect(x: plateInset, y: plateInset, width: plateSize, height: plateSize),
    cornerWidth: cornerRadius,
    cornerHeight: cornerRadius,
    transform: nil
)
master.addPath(plate)
master.setFillColor(plateColor)
master.fillPath()
master.setFillColor(darkColor)
addDots(darkDots, to: master)
master.fillPath()
master.setFillColor(greyColor)
addDots(greyDots, to: master)
master.fillPath()
write(master, to: appIconSet.appendingPathComponent("AppIcon-1024.png"))

// 2. In-app emblem. Same mark, but edge to edge: the Dock needs the app icon
// to sit inside a margin, whereas SwiftUI sizes this one through its own
// container and a second inset would just shrink the glyph twice.
let emblem = makeContext()
let emblemPlate = CGPath(
    roundedRect: CGRect(x: 0, y: 0, width: canvas, height: canvas),
    cornerWidth: canvas * 0.2237,
    cornerHeight: canvas * 0.2237,
    transform: nil
)
emblem.addPath(emblemPlate)
emblem.setFillColor(plateColor)
emblem.fillPath()

let emblemScale = canvas / plateSize
func scaled(_ dots: [(Double, Double)]) -> [(Double, Double)] {
    dots.map { (512 + ($0.0 - 512) * emblemScale, 512 + ($0.1 - 512) * emblemScale) }
}
let emblemRadius = dotRadius * emblemScale
func addEmblemDots(_ dots: [(Double, Double)], to context: CGContext) {
    for (x, y) in scaled(dots) {
        context.addEllipse(in: CGRect(
            x: x - emblemRadius,
            y: flip(y) - emblemRadius,
            width: emblemRadius * 2,
            height: emblemRadius * 2
        ))
    }
}
emblem.setFillColor(darkColor)
addEmblemDots(darkDots, to: emblem)
emblem.fillPath()
emblem.setFillColor(greyColor)
addEmblemDots(greyDots, to: emblem)
emblem.fillPath()
write(emblem, to: outputRoot.appendingPathComponent(
    "Sources/AetherRouteApp/Assets.xcassets/AetherSapphireEmblem.imageset/AetherSapphireEmblem.png"
))

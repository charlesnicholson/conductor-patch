#!/usr/bin/env swift
//
// Builds the app icon: Conductor's own icon with a wrench badged onto the lower-right
// corner. Run by build.sh; writes a .iconset directory that iconutil turns into .icns.
//
//   swift tools/make-icon.swift <input.icns> <output.iconset>
//
// Conductor's icon is a near-black rounded square lit by warm off-white shapes, so the
// badge inverts that -- a warm off-white disc holding a dark wrench -- which stays legible
// both against the icon and against a white Finder row.

import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write(
        Data("usage: make-icon.swift <input.icns> <output.iconset>\n".utf8))
    exit(2)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let iconsetURL = URL(fileURLWithPath: arguments[2])

guard let base = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("cannot read \(sourceURL.path)\n".utf8))
    exit(1)
}
guard let wrenchTemplate = NSImage(systemSymbolName: "wrench.fill", accessibilityDescription: nil)
else {
    FileHandle.standardError.write(Data("SF Symbol wrench.fill unavailable\n".utf8))
    exit(1)
}

let ink = NSColor(srgbRed: 0.13, green: 0.10, blue: 0.09, alpha: 1)
let discColor = NSColor(srgbRed: 0.97, green: 0.95, blue: 0.93, alpha: 1)

/// A wrench of the given colour and point size.
///
/// Colouring via paletteColors rather than the fill-then-destinationIn trick: SF Symbols
/// carry a nearly-transparent alignment rectangle, and masking a solid fill through it
/// leaves a faint one-pixel box around the glyph.
func wrench(_ template: NSImage, _ color: NSColor, pointSize: CGFloat) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
    return template.withSymbolConfiguration(configuration) ?? template
}

func render(size: Int) -> Data? {
    let side = CGFloat(size)
    guard
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: side, height: side)

    guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let canvas = NSRect(x: 0, y: 0, width: side, height: side)
    base.draw(in: canvas, from: .zero, operation: .sourceOver, fraction: 1)

    // Lower-right, overlapping the rounded square's corner. Conductor's artwork sits
    // inside the usual macOS icon padding, so the disc straddles the edge rather than
    // floating in the margin.
    let radius = side * 0.195
    let center = NSPoint(x: side * 0.755, y: side * 0.245)
    let disc = NSRect(
        x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
    shadow.shadowBlurRadius = side * 0.025
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.008)
    shadow.set()

    let path = NSBezierPath(ovalIn: disc)
    discColor.setFill()
    path.fill()

    // The ring is what keeps the disc from dissolving into a white Finder background.
    NSShadow().set()
    ink.setStroke()
    path.lineWidth = max(1, side * 0.008)
    path.stroke()

    // Fit the glyph to a box inside the disc, preserving its aspect: wrench.fill is not
    // square, and forcing it into a square rect both distorts it and shifts it off centre.
    let glyph = wrench(wrenchTemplate, ink, pointSize: radius * 1.3)
    let natural = glyph.size
    let box = radius * 1.20
    let scale = min(box / natural.width, box / natural.height)
    let drawn = NSSize(width: natural.width * scale, height: natural.height * scale)
    glyph.draw(
        in: NSRect(
            x: center.x - drawn.width / 2, y: center.y - drawn.height / 2,
            width: drawn.width, height: drawn.height),
        from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try? FileManager.default.removeItem(at: iconsetURL)
try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

// The ten representations iconutil expects for a complete .icns.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    guard let png = render(size: variant.pixels) else {
        FileHandle.standardError.write(Data("failed to render \(variant.name)\n".utf8))
        exit(1)
    }
    try png.write(to: iconsetURL.appendingPathComponent(variant.name))
}

print("wrote \(variants.count) representations to \(iconsetURL.path)")

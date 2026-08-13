#!/usr/bin/env swift

// Draws Markpad's app icon and writes the asset catalog images.
//
// The icon is generated rather than stored as binary art so it can be tweaked in code and
// regenerated at every size from one definition.
//
// Usage: swift scripts/generate-icon.swift

import AppKit
import Foundation

let outputDirectory = URL(fileURLWithPath: "Markpad/Resources/Assets.xcassets/AppIcon.appiconset")
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

/// macOS icons sit inside a rounded square with a margin around it.
func drawIcon(size: CGFloat, in context: CGContext) {
    let scale = size / 1024
    context.saveGState()
    context.scaleBy(x: scale, y: scale)

    let inset: CGFloat = 100
    let rect = CGRect(x: inset, y: inset, width: 1024 - inset * 2, height: 1024 - inset * 2)
    let shape = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

    // Soft vertical gradient, a shade of ink rather than a saturated colour.
    context.saveGState()
    shape.addClip()
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.28, green: 0.42, blue: 0.72, alpha: 1),
        NSColor(srgbRed: 0.16, green: 0.24, blue: 0.48, alpha: 1)
    ])
    gradient?.draw(in: rect, angle: -90)
    context.restoreGState()

    // The markdown mark: an "M" with a descending arrow, drawn as strokes so it stays
    // crisp when the icon is rendered small.
    let strokeWidth: CGFloat = 74
    let ink = NSColor.white

    let m = NSBezierPath()
    m.move(to: CGPoint(x: 300, y: 390))
    m.line(to: CGPoint(x: 300, y: 640))
    m.line(to: CGPoint(x: 415, y: 505))
    m.line(to: CGPoint(x: 530, y: 640))
    m.line(to: CGPoint(x: 530, y: 390))
    m.lineWidth = strokeWidth
    m.lineCapStyle = .round
    m.lineJoinStyle = .round
    ink.setStroke()
    m.stroke()

    let arrow = NSBezierPath()
    arrow.move(to: CGPoint(x: 700, y: 640))
    arrow.line(to: CGPoint(x: 700, y: 400))
    arrow.lineWidth = strokeWidth
    arrow.lineCapStyle = .round
    arrow.stroke()

    let head = NSBezierPath()
    head.move(to: CGPoint(x: 610, y: 500))
    head.line(to: CGPoint(x: 700, y: 396))
    head.line(to: CGPoint(x: 790, y: 500))
    head.lineWidth = strokeWidth
    head.lineCapStyle = .round
    head.lineJoinStyle = .round
    head.stroke()

    context.restoreGState()
}

func writePNG(size: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "icon", code: 1) }

    NSGraphicsContext.saveGraphicsState()
    let graphicsContext = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphicsContext
    drawIcon(size: CGFloat(size), in: graphicsContext.cgContext)
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 2)
    }
    try data.write(to: url)
}

struct Entry {
    let size: Int
    let scale: Int
    var pixels: Int { size * scale }
    var filename: String { "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png" }
}

let entries = [
    Entry(size: 16, scale: 1), Entry(size: 16, scale: 2),
    Entry(size: 32, scale: 1), Entry(size: 32, scale: 2),
    Entry(size: 128, scale: 1), Entry(size: 128, scale: 2),
    Entry(size: 256, scale: 1), Entry(size: 256, scale: 2),
    Entry(size: 512, scale: 1), Entry(size: 512, scale: 2)
]

for entry in entries {
    try writePNG(size: entry.pixels, to: outputDirectory.appendingPathComponent(entry.filename))
}

let images = entries.map { entry in
    """
        {
          "filename" : "\(entry.filename)",
          "idiom" : "mac",
          "scale" : "\(entry.scale)x",
          "size" : "\(entry.size)x\(entry.size)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}

"""
try contents.write(
    to: outputDirectory.appendingPathComponent("Contents.json"),
    atomically: true,
    encoding: .utf8
)

print("Wrote \(entries.count) icon images to \(outputDirectory.path)")

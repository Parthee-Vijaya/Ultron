#!/usr/bin/env swift
// Generates the Ultron arc-reactor app icon into the AppIcon.appiconset folder.
// Run via: `swift scripts/generate-icon.swift` from the repo root.

import AppKit
import CoreGraphics

// MARK: - Config

let outputDir = "Ultron/Resources/Assets.xcassets/AppIcon.appiconset"
let slots: [(pixel: Int, filename: String)] = [
    (16,   "icon_16.png"),
    (32,   "icon_16@2x.png"),
    (32,   "icon_32.png"),
    (64,   "icon_32@2x.png"),
    (128,  "icon_128.png"),
    (256,  "icon_128@2x.png"),
    (256,  "icon_256.png"),
    (512,  "icon_256@2x.png"),
    (512,  "icon_512.png"),
    (1024, "icon_512@2x.png"),
]

// Colour palette — matches UltronTheme.swift
let bgDeep       = NSColor(srgbRed: 0.027, green: 0.055, blue: 0.086, alpha: 1)
let bgElevated   = NSColor(srgbRed: 0.055, green: 0.102, blue: 0.157, alpha: 1)
let neonCyan     = NSColor(srgbRed: 0.255, green: 0.941, blue: 0.984, alpha: 1)
let brightCyan   = NSColor(srgbRed: 0.494, green: 0.976, blue: 1.000, alpha: 1)

// MARK: - Drawing

func renderIcon(size: Int) -> NSImage? {
    let dim = CGFloat(size)
    let canvasRect = NSRect(x: 0, y: 0, width: dim, height: dim)
    let image = NSImage(size: canvasRect.size)

    image.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return nil
    }

    // Rounded square base — macOS icon guidelines want ~22% corner radius but
    // Apple's template overlays the final squircle, so we draw a full rounded
    // rect and rely on the system to apply its own mask only at ≥256 px.
    let cornerRadius = dim * 0.22
    let basePath = NSBezierPath(roundedRect: canvasRect, xRadius: cornerRadius, yRadius: cornerRadius)

    ctx.saveGState()
    basePath.addClip()

    // Background gradient
    let gradient = NSGradient(colors: [bgDeep, bgElevated])!
    gradient.draw(in: canvasRect, angle: 315)

    // Subtle cyan bloom in upper-left
    let bloomCenter = NSPoint(x: dim * 0.3, y: dim * 0.7)
    let bloom = NSGradient(colorsAndLocations:
        (neonCyan.withAlphaComponent(0.25), 0.0),
        (neonCyan.withAlphaComponent(0.0), 1.0)
    )!
    bloom.draw(fromCenter: bloomCenter, radius: 0,
               toCenter: bloomCenter, radius: dim * 0.6,
               options: [])

    ctx.restoreGState()

    // Arc-reactor rings ---
    let center = NSPoint(x: dim / 2, y: dim / 2)
    let ringStrokes: [(radiusFrac: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (0.42, max(1.5, dim * 0.018), 0.85),
        (0.33, max(1.2, dim * 0.014), 0.65),
        (0.24, max(1.0, dim * 0.012), 0.5),
    ]
    for ring in ringStrokes {
        let r = dim * ring.radiusFrac
        let rect = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = ring.width
        neonCyan.withAlphaComponent(ring.alpha).setStroke()
        path.stroke()
    }

    // Dashed outer ring — a little retro-HUD flourish
    let dashedR = dim * 0.48
    let dashedRect = NSRect(x: center.x - dashedR, y: center.y - dashedR,
                            width: dashedR * 2, height: dashedR * 2)
    let dashedPath = NSBezierPath(ovalIn: dashedRect)
    dashedPath.lineWidth = max(0.8, dim * 0.006)
    let dashPattern: [CGFloat] = [dim * 0.025, dim * 0.02]
    dashedPath.setLineDash(dashPattern, count: dashPattern.count, phase: 0)
    neonCyan.withAlphaComponent(0.35).setStroke()
    dashedPath.stroke()

    // Bright core with glow
    let coreRadius = dim * 0.12
    let coreRect = NSRect(x: center.x - coreRadius, y: center.y - coreRadius,
                          width: coreRadius * 2, height: coreRadius * 2)
    // Halo (large, faint)
    let haloRadius = dim * 0.2
    let haloRect = NSRect(x: center.x - haloRadius, y: center.y - haloRadius,
                          width: haloRadius * 2, height: haloRadius * 2)
    let halo = NSGradient(colorsAndLocations:
        (brightCyan.withAlphaComponent(0.55), 0.0),
        (brightCyan.withAlphaComponent(0.0), 1.0)
    )!
    halo.draw(in: NSBezierPath(ovalIn: haloRect), relativeCenterPosition: .zero)
    // Core (solid bright)
    let core = NSGradient(colorsAndLocations:
        (NSColor.white.withAlphaComponent(0.98), 0.0),
        (brightCyan, 0.5),
        (neonCyan, 1.0)
    )!
    core.draw(in: NSBezierPath(ovalIn: coreRect), relativeCenterPosition: .zero)

    image.unlockFocus()
    return image
}

// MARK: - Write PNGs

func savePNG(_ image: NSImage, to path: String) throws {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encoding failed for \(path)"])
    }
    try png.write(to: URL(fileURLWithPath: path))
}

// MARK: - Update Contents.json

let contentsJSON = """
{
  "images" : [
    { "idiom" : "mac", "scale" : "1x", "size" : "16x16",   "filename" : "icon_16.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "16x16",   "filename" : "icon_16@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "32x32",   "filename" : "icon_32.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "32x32",   "filename" : "icon_32@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "128x128", "filename" : "icon_128.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "128x128", "filename" : "icon_128@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "256x256", "filename" : "icon_256.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "256x256", "filename" : "icon_256@2x.png" },
    { "idiom" : "mac", "scale" : "1x", "size" : "512x512", "filename" : "icon_512.png" },
    { "idiom" : "mac", "scale" : "2x", "size" : "512x512", "filename" : "icon_512@2x.png" }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""

// MARK: - Main

let fm = FileManager.default
if !fm.fileExists(atPath: outputDir) {
    FileHandle.standardError.write("Error: output dir not found: \(outputDir)\n".data(using: .utf8)!)
    exit(1)
}

for slot in slots {
    guard let image = renderIcon(size: slot.pixel) else {
        FileHandle.standardError.write("Failed to render \(slot.pixel)px\n".data(using: .utf8)!)
        exit(1)
    }
    let path = "\(outputDir)/\(slot.filename)"
    do {
        try savePNG(image, to: path)
        print("✓ wrote \(slot.filename) (\(slot.pixel)×\(slot.pixel))")
    } catch {
        FileHandle.standardError.write("Failed to write \(path): \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}

try! contentsJSON.write(toFile: "\(outputDir)/Contents.json", atomically: true, encoding: .utf8)
print("✓ updated Contents.json")

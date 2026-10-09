#!/usr/bin/env swift
// Render the app icon and write it as an .icns file.
//
// The icon is drawn in code (no source artwork to keep in sync): a dark
// rounded tile holding three usage bars, echoing the dropdown's rows.
// Re-run after changing the drawing; the resulting .icns is committed so
// builds (and CI) don't need to regenerate it.
//
// Usage: swift scripts/make-icon.swift [output.icns]   (default: Resources/AppIcon.icns)
import AppKit

let output = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/AppIcon.icns"

/// Draw the icon into the current graphics context on a 1024×1024 grid.
func drawIcon() {
    // Apple's icon grid: an 824pt tile centered on the 1024pt canvas.
    let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 28
    shadow.set()
    NSColor.black.setFill()
    tilePath.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(starting: NSColor(srgbRed: 0.17, green: 0.18, blue: 0.23, alpha: 1),
               ending: NSColor(srgbRed: 0.07, green: 0.07, blue: 0.10, alpha: 1))?
        .draw(in: tilePath, angle: -90)

    // Three bars, top to bottom: (fill fraction, color).
    let bars: [(CGFloat, NSColor)] = [
        (0.38, NSColor(srgbRed: 0.30, green: 0.85, blue: 0.55, alpha: 1)),
        (0.64, NSColor(srgbRed: 1.00, green: 0.74, blue: 0.25, alpha: 1)),
        (0.88, NSColor(srgbRed: 1.00, green: 0.38, blue: 0.36, alpha: 1)),
    ]
    let barHeight: CGFloat = 96
    let gap: CGFloat = 76
    let inset: CGFloat = 150
    let trackWidth = tile.width - inset * 2
    let stackHeight = CGFloat(bars.count) * barHeight + CGFloat(bars.count - 1) * gap
    var y = tile.midY + stackHeight / 2 - barHeight

    for (fraction, color) in bars {
        let track = NSRect(x: tile.minX + inset, y: y, width: trackWidth, height: barHeight)
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: track, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        var fill = track
        fill.size.width = trackWidth * fraction
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        y -= barHeight + gap
    }
}

/// Render the icon at an exact pixel size and return PNG data.
func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try fm.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: iconset) }

// The sizes iconutil expects: each point size at @1x and @2x.
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let outputURL = URL(fileURLWithPath: output)
try fm.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", outputURL.path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("✗ iconutil failed\n".utf8))
    exit(1)
}
print("✓ Wrote \(output)")

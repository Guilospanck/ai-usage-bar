// Draws the 1280x640 GitHub social preview image: icon on the left, title and two tagline lines on the right.
// Usage: swift scripts/make-social.swift <icon.png> <out.png> <title> <line1> <line2> <bgTop> <bgBottom> <ink>
// Colors are hex such as f3f5f2.
// Example: swift scripts/make-social.swift assets/icon.png assets/social.png "AI Usage Bar" "Claude, OpenAI and Antigravity" "usage in your macOS menu bar." f1f2f5 dfe2ea 14161c
import AppKit

let a = CommandLine.arguments
let w = 1280, h = 640
func hex(_ s: String) -> NSColor {
    let v = Int(s, radix: 16)!
    return NSColor(red: CGFloat(v >> 16 & 255) / 255, green: CGFloat(v >> 8 & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
}
let icon = NSImage(contentsOfFile: a[1])!
let ink = hex(a[8])
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

NSGradient(starting: hex(a[6]), ending: hex(a[7]))!.draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

let size: CGFloat = 360
icon.draw(in: NSRect(x: 100, y: (CGFloat(h) - size) / 2, width: size, height: size))

// Text column: x 520...1230. Shrinks the font until the string fits.
let left: CGFloat = 520, maxW: CGFloat = 710
func draw(_ s: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, y: CGFloat) {
    var sz = size
    func attrs() -> [NSAttributedString.Key: Any] { [.font: NSFont.systemFont(ofSize: sz, weight: weight), .foregroundColor: color] }
    while NSAttributedString(string: s, attributes: attrs()).size().width > maxW { sz -= 2 }
    NSAttributedString(string: s, attributes: attrs()).draw(at: NSPoint(x: left, y: y))
}
draw(a[3], size: 96, weight: .bold, color: ink, y: 330)
draw(a[4], size: 36, weight: .regular, color: ink.withAlphaComponent(0.75), y: 262)
draw(a[5], size: 36, weight: .regular, color: ink.withAlphaComponent(0.75), y: 210)

NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[2]))

// Draws the OS+ app icon. Usage: swift scripts/make-icon.swift <out.png>  (1024×1024)
// scripts/make-icon.sh turns it into Resources/AppIcon.icns.
import AppKit

let side: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// macOS icon grid: an 824pt rounded square centred on a 1024 canvas, with a soft drop shadow.
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.black.setFill()
shape.fill()
NSGraphicsContext.restoreGraphicsState()

// Deep graphite-to-indigo gradient with a faint top highlight.
NSGraphicsContext.saveGraphicsState()
shape.addClip()
NSGradient(colors: [NSColor(red: 0.20, green: 0.22, blue: 0.42, alpha: 1),
                    NSColor(red: 0.07, green: 0.08, blue: 0.16, alpha: 1)])!.draw(in: tile, angle: -90)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.10), NSColor.white.withAlphaComponent(0)])!
    .draw(in: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), angle: -90)
NSGraphicsContext.restoreGraphicsState()

// "OS" in white, "+" in warm orange.
func rounded(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .heavy)
    return base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: size) } ?? base
}
let text = NSMutableAttributedString(string: "OS", attributes: [.font: rounded(330), .foregroundColor: NSColor.white,
                                                                 .kern: -8])
text.append(NSAttributedString(string: "+", attributes: [
    .font: rounded(330), .foregroundColor: NSColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 1)]))
let size = text.size()
text.draw(at: NSPoint(x: tile.midX - size.width / 2, y: tile.midY - size.height / 2 + 6))

// Thin inner border so it holds up on dark backgrounds.
NSColor.white.withAlphaComponent(0.08).setStroke()
let border = NSBezierPath(roundedRect: tile.insetBy(dx: 2, dy: 2), xRadius: 183, yRadius: 183)
border.lineWidth = 4
border.stroke()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))

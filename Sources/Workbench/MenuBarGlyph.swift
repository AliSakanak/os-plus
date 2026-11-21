import AppKit

/// The "OS+" menu-bar icon, drawn as text so it stays crisp at any scale.
/// It's a template image, so macOS tints it for light/dark menu bars and wallpapers automatically.
enum MenuBarGlyph {
    static let text = "OS+"

    /// - Parameter alert: adds a small dot at the top right when something needs attention.
    static func image(alert: Bool) -> NSImage {
        var font = NSFont.systemFont(ofSize: 12.5, weight: .heavy)
        if let rounded = font.fontDescriptor.withDesign(.rounded) {
            font = NSFont(descriptor: rounded, size: 12.5) ?? font
        }
        let label = NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: NSColor.black,  // template images only use the alpha channel
            .kern: -0.3,
        ])
        let textSize = label.size()
        let dot: CGFloat = 4.5
        let size = NSSize(width: ceil(textSize.width) + (alert ? dot + 1 : 0) + 1, height: 16)

        let image = NSImage(size: size, flipped: false) { rect in
            label.draw(at: NSPoint(x: 0.5, y: floor((rect.height - textSize.height) / 2) + 0.5))
            if alert {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.width - dot, y: rect.height - dot - 1, width: dot, height: dot)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = alert ? "OS+ — something needs attention" : "OS+"
        return image
    }
}

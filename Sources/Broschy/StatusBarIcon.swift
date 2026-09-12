import AppKit

enum StatusBarIcon {
    /// A vector template keeps the notch mark sharp at menu-bar scale and lets
    /// macOS choose its color for light, dark, and highlighted appearances.
    static func makeImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()

            let screen = NSBezierPath(
                roundedRect: NSRect(x: 1.75, y: 3.25, width: 14.5, height: 11.5),
                xRadius: 2.6, yRadius: 2.6
            )
            screen.lineWidth = 1.5
            screen.stroke()

            let notch = NSBezierPath(
                roundedRect: NSRect(x: 6, y: 11.75, width: 6, height: 3.5),
                xRadius: 1, yRadius: 1
            )
            notch.fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Broschy"
        return image
    }
}

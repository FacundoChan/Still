import AppKit

/// A small outline of a crop shape, so a ratio reads as portrait, landscape or square at a glance.
/// Drawn rather than taken from SF Symbols, which has shapes for only some of the presets.
enum AspectGlyph {
    /// - Parameters:
    ///   - ratio: Width ÷ height.
    ///   - dashed: For Freeform, whose shape isn't fixed.
    static func image(ratio: Double, dashed: Bool = false) -> NSImage {
        let box = NSSize(width: 16, height: 16)
        let longEdge: CGFloat = 13
        // Extreme custom ratios still leave a visible shape.
        let ratio = min(max(ratio, 0.25), 4)
        let size = ratio >= 1
            ? NSSize(width: longEdge, height: longEdge / ratio)
            : NSSize(width: longEdge * ratio, height: longEdge)
        let image = NSImage(size: box, flipped: false) { bounds in
            let lineWidth: CGFloat = 1.25
            let rect = NSRect(
                x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2,
                width: size.width, height: size.height
            ).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            // Slightly rounded, like SF Symbols' rectangles; larger radii turn wide shapes into pills.
            let radius = min(1.5, min(rect.width, rect.height) * 0.2)
            let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
            path.lineWidth = lineWidth
            if dashed { path.setLineDash([2, 1.5], count: 2, phase: 0) }
            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        // A template, so menus tint it for highlighting and dark mode.
        image.isTemplate = true
        return image
    }

    /// For VoiceOver and tooltips.
    static func orientation(ratio: Double) -> String {
        if abs(ratio - 1) < 0.01 { return "Square" }
        return ratio > 1 ? "Landscape" : "Portrait"
    }
}

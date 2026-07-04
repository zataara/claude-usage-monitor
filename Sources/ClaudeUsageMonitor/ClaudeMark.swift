import AppKit

/// The Claude sunburst mark, loaded from the bundled SVG as a template image so it
/// tints to the menu-bar color (light/dark) and can be recolored in the popover.
/// Nil when running the raw binary (no app bundle) — callers fall back gracefully.
enum ClaudeMark {
    /// Menu-bar mark, tight-cropped to the glyph (the source SVG has ~15% transparent
    /// padding) and sized to fill the bar height like the Claude app's own mark.
    /// NSStatusItem renders the NSImage at its own size — a SwiftUI .frame is ignored.
    static let menuBar: NSImage? = tightTemplate(18)

    /// Base template image (natural size) for the popover, where SwiftUI .frame works.
    static let image: NSImage? = load()

    private static func load() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "claude-mark", withExtension: "svg"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }

    /// Renders the mark, finds its opaque bounding box, crops the padding, and returns a
    /// `pt`-sized square template image whose glyph fills the frame.
    private static func tightTemplate(_ pt: CGFloat) -> NSImage? {
        guard let base = load() else { return nil }
        let n = 256
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: n, pixelsHigh: n,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        base.draw(in: NSRect(x: 0, y: 0, width: n, height: n))
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = rep.cgImage else { return base }
        var minX = n, minY = n, maxX = -1, maxY = -1
        for y in 0..<n {
            for x in 0..<n where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
            }
        }
        guard maxX >= minX, maxY >= minY else { base.size = NSSize(width: pt, height: pt); return base }

        let w = maxX - minX + 1, h = maxY - minY + 1
        let side = max(w, h)
        guard let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: w, height: h)) else { return base }

        // Center the cropped glyph in a square, then scale to pt.
        let square = NSImage(size: NSSize(width: side, height: side))
        square.lockFocus()
        NSImage(cgImage: cropped, size: NSSize(width: w, height: h))
            .draw(in: NSRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h))
        square.unlockFocus()
        square.size = NSSize(width: pt, height: pt)
        square.isTemplate = true
        return square
    }
}

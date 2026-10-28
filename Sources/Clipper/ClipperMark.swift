import AppKit

/// Clipper's mark, "Shelf Clip": a paperclip lying on its side whose longest run keeps going and becomes the shelf.
/// Shared by the menu bar glyph and the app icon so the two always match.
enum ClipperMark {
    /// The wire's centre line in y-down units: four runs `s` apart from `y1`, concentric left turns centred at `xc`,
    /// the right turn centred at `xr`, and the bottom run carried on to `tail`. `map` converts to AppKit points.
    /// Returned in two parts so the app icon can set the inner loop back: the inner loop (inner leg, inner turn,
    /// middle run) and the outer loop (right turn, top run, outer turn, long run).
    static func wireParts(s: Double, y1: Double, xc: Double, xr: Double, tail: Double,
                          map: (Double, Double) -> NSPoint) -> (inner: NSBezierPath, outer: NSBezierPath) {
        let (y2, y3, y4) = (y1 + s, y1 + 2 * s, y1 + 3 * s)
        func arc(_ p: NSBezierPath, cx: Double, cy: Double, r: Double, from a0: Double, to a1: Double) {
            let steps = 48
            for i in 1...steps {
                let a = (a0 + (a1 - a0) * Double(i) / Double(steps)) * .pi / 180
                p.line(to: map(cx + r * cos(a), cy + r * sin(a)))
            }
        }
        let inner = NSBezierPath(), outer = NSBezierPath()
        inner.move(to: map(xr - s, y2))                                      // free end of the inner leg
        inner.line(to: map(xc, y2))
        arc(inner, cx: xc, cy: y2 + s / 2, r: s / 2, from: 270, to: 90)      // inner turn, round the left
        inner.line(to: map(xr, y3))
        outer.move(to: map(xr, y3))
        arc(outer, cx: xr, cy: y2, r: s, from: 90, to: -90)                  // right turn
        outer.line(to: map(xc, y1))
        arc(outer, cx: xc, cy: y2 + s / 2, r: 1.5 * s, from: 270, to: 90)    // outer turn, round the left
        outer.line(to: map(tail, y4))                                        // the long run: the shelf
        for p in [inner, outer] { p.lineCapStyle = .round; p.lineJoinStyle = .round }
        return (inner, outer)
    }

    /// The whole wire as one path.
    static func wire(s: Double, y1: Double, xc: Double, xr: Double, tail: Double, map: (Double, Double) -> NSPoint) -> NSBezierPath {
        let (inner, outer) = wireParts(s: s, y1: y1, xc: xc, xr: xr, tail: tail, map: map)
        inner.append(outer)
        return inner
    }

    /// The menu bar glyph: a template image (black + alpha) that macOS tints for light, dark and selected states.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let p = wire(s: 2.6, y1: 5.4, xc: 5.5, xr: 11.7, tail: 17.3) { x, y in
                NSPoint(x: r.minX + x / 18 * r.width, y: r.maxY - y / 18 * r.height)
            }
            p.lineWidth = 1.4 / 18 * r.width
            NSColor.black.setStroke(); p.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Clipper"
        return img
    }

    /// The app icon at `pixels` square, on the macOS icon grid (824-pixel body in 1024). Three layers, no baked effects:
    /// a blue ground with a translucent shelf, the inner loop at half opacity (set back), and the outer loop whose long
    /// run is the shelf's top edge and runs off the right edge.
    /// Resources/IconLayers holds the same layers as full-bleed SVGs for Icon Composer.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels) / 1024
        // Canvas pixels, y down, to AppKit.
        func px(_ x: Double, _ y: Double) -> NSPoint { NSPoint(x: x * s, y: (1024 - y) * s) }
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s).addClip()
        NSGradient(starting: NSColor(srgbRed: 0x3F / 255, green: 0x7C / 255, blue: 0xFF / 255, alpha: 1),
                   ending: NSColor(srgbRed: 0x1C / 255, green: 0x47 / 255, blue: 0xCC / 255, alpha: 1))?
            .draw(in: NSRect(x: 0, y: 0, width: 1024 * s, height: 1024 * s), angle: -90)
        // Canvas px: run spacing, wire width, left-turn centre, right-turn centre, top run. At 16 and 32 px the clip
        // is larger with a thicker wire so its four runs stay apart; at 16 px each run is one pixel row.
        let (sp, w, xc, xr, y1): (Double, Double, Double, Double, Double) =
            pixels <= 16 ? (128, 64, 350, 760, 288) : pixels <= 32 ? (112, 64, 370, 730, 302) : (96, 54, 360, 690, 326)
        let shelfTop = y1 + 3 * sp
        NSColor(white: 1, alpha: 0.16).setFill()
        NSRect(x: 0, y: 0, width: 1024 * s, height: (1024 - shelfTop) * s).fill()
        let (inner, outer) = wireParts(s: sp, y1: y1, xc: xc, xr: xr, tail: 1100, map: px)
        inner.lineWidth = w * s; outer.lineWidth = w * s
        NSColor(white: 1, alpha: pixels <= 32 ? 0.7 : 0.5).setStroke(); inner.stroke()
        NSColor.white.setStroke(); outer.stroke()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// --make-icon <dir>: writes an .iconset (16…1024 px) for iconutil.
    static func writeIconset(to dir: URL) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for pt in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let name = scale == 1 ? "icon_\(pt)x\(pt).png" : "icon_\(pt)x\(pt)@2x.png"
                try appIcon(pixels: pt * scale).representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent(name))
            }
        }
    }
}

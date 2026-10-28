import AppKit

/// Clipper's mark, "Loop C": one wire bent into a C with an inner return. Drawn on a 20-unit grid (y down) and
/// shared by the menu bar glyph and the app icon so the two always match.
enum ClipperMark {
    /// The wire's centre line, fitted to `rect` in AppKit's y-up coordinates.
    static func path(in rect: NSRect) -> NSBezierPath {
        func pt(_ x: Double, _ y: Double) -> NSPoint {
            NSPoint(x: rect.minX + x / 20 * rect.width, y: rect.maxY - y / 20 * rect.height)
        }
        func arc(_ p: NSBezierPath, cx: Double, cy: Double, r: Double, from a0: Double, to a1: Double) {
            let steps = 48
            for i in 1...steps {
                let a = (a0 + (a1 - a0) * Double(i) / Double(steps)) * .pi / 180
                p.line(to: pt(cx + r * cos(a), cy + r * sin(a)))
            }
        }
        let p = NSBezierPath()
        // Outer C: radius 6.5 around the left, from top-right (15.4, 6) to bottom-right (15.4, 14).
        let outerStart = atan2(-4.0, 5.123) * 180 / .pi
        p.move(to: pt(15.4, 6))
        arc(p, cx: 10.277, cy: 10, r: 6.5, from: outerStart, to: -360 - outerStart)
        // The hook back inside.
        p.curve(to: pt(13, 12.3), controlPoint1: pt(16.47, 12.87), controlPoint2: pt(15.667, 12.3))
        // Inner C: radius 3.5, from bottom-right (13, 12.3) round the left to top-right (13, 7.7).
        let innerStart = atan2(2.3, 2.638) * 180 / .pi
        arc(p, cx: 10.362, cy: 10, r: 3.5, from: innerStart, to: 360 - innerStart)
        p.line(to: pt(15, 7.7))
        p.lineCapStyle = .round; p.lineJoinStyle = .round
        return p
    }

    /// The menu bar glyph: a template image (black + alpha) that macOS tints for light, dark and selected states.
    static func menuBarImage() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in
            let p = path(in: r)
            p.lineWidth = 1.7 / 20 * r.width
            NSColor.black.setStroke(); p.stroke()
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Clipper"
        return img
    }

    /// The app icon at `pixels` square: the macOS icon grid (824-pixel body in 1024) with a pale blue ground and the
    /// blue wire. One layer pair (ground, wire), so it can move to Icon Composer unchanged.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let s = CGFloat(pixels) / 1024
        let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let squircle = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.28); shadow.shadowOffset = NSSize(width: 0, height: -10 * s); shadow.shadowBlurRadius = 20 * s
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor(srgbRed: 0.84, green: 0.88, blue: 0.98, alpha: 1).setFill(); squircle.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(starting: NSColor(srgbRed: 0.97, green: 0.98, blue: 1, alpha: 1), ending: NSColor(srgbRed: 0.84, green: 0.88, blue: 0.98, alpha: 1))?
            .draw(in: squircle, angle: -90)
        let wire = path(in: body)
        wire.lineWidth = 0.09 * body.width
        NSColor(srgbRed: 0x2B / 255, green: 0x62 / 255, blue: 0xEB / 255, alpha: 1).setStroke(); wire.stroke()
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

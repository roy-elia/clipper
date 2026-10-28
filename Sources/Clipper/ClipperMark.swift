import AppKit

/// Clipper's marks. The menu bar glyph is "Shelf Clip", a paperclip lying on its side whose longest run keeps going and
/// becomes the shelf. The app icon is "Fan", three upright clips fanned out.
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

    /// An upright clip's centre line in y-down canvas units: legs `s` apart centred on `cx`, top turns centred at `yt`,
    /// bottom turn at `yb`.
    static func uprightClip(cx: Double, yt: Double, yb: Double, s: Double, innerEnd: Double, outerEnd: Double) -> CGPath {
        let (x1, x2, x3, x4) = (cx - 1.5 * s, cx - 0.5 * s, cx + 0.5 * s, cx + 1.5 * s)
        let p = CGMutablePath()
        p.move(to: CGPoint(x: x2, y: innerEnd))
        p.addLine(to: CGPoint(x: x2, y: yt))
        p.addArc(center: CGPoint(x: cx, y: yt), radius: s / 2, startAngle: .pi, endAngle: 0, clockwise: false)    // inner turn
        p.addLine(to: CGPoint(x: x3, y: yb))
        p.addArc(center: CGPoint(x: x2, y: yb), radius: s, startAngle: 0, endAngle: .pi, clockwise: false)       // bottom turn
        p.addLine(to: CGPoint(x: x1, y: yt))
        p.addArc(center: CGPoint(x: cx, y: yt), radius: 1.5 * s, startAngle: .pi, endAngle: 0, clockwise: false) // outer turn
        p.addLine(to: CGPoint(x: x4, y: outerEnd))
        return p
    }

    static func srgb(_ hex: UInt32, _ a: Double = 1) -> CGColor {
        CGColor(srgbRed: Double(hex >> 16 & 255) / 255, green: Double(hex >> 8 & 255) / 255, blue: Double(hex & 255) / 255, alpha: a)
    }

    /// The app icon at `pixels` square, on the macOS icon grid (824-pixel body in 1024): "Fan", three clips fanned out
    /// in the brand blues on a white ground, one per copy in the history. Each clip is a solid object (its outline filled
    /// with a vertical gradient, a bright rim and a soft shadow) because the flat .icns gets no Liquid Glass of its own.
    /// At 32 and 16 px it drops to two shorter clips, the front one upright with its legs on whole pixels.
    /// Resources/IconLayers holds the same layers as full-bleed SVGs for Icon Composer.
    static func appIcon(pixels: Int) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let gc = NSGraphicsContext(bitmapImageRep: rep)!, ctx = gc.cgContext
        let k = Double(pixels) / 1024
        ctx.translateBy(x: 0, y: Double(pixels)); ctx.scaleBy(x: k, y: -k)   // y down on the 1024 grid
        func gradient(_ a: CGColor, _ b: CGColor, from y0: Double, to y1: Double) {
            let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [a, b] as CFArray, locations: [0, 1])!
            ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: y0), end: CGPoint(x: 512, y: y1),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        ctx.addPath(CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824), cornerWidth: 185, cornerHeight: 185, transform: nil))
        ctx.clip()
        gradient(srgb(0xFFFFFF), srgb(0xE9EEF8), from: 100, to: 924)

        let small = pixels <= 32
        // Rotation, spacing, wire width, leg length (top turn to bottom turn), centre x, how far below the clip it pivots.
        let (angles, sp, w, len, cx, drop): ([Double], Double, Double, Double, Double, Double) =
            pixels <= 16 ? ([-0.38, 0], 128, 64, 280, 544, 40)
            : small ? ([-0.34, 0], 96, 64, 250, 528, 40)
            : ([-0.34, 0, 0.34], 72, 50, 259, 512, 80)
        let blues: [(UInt32, UInt32)] = [(0x9DBBFF, 0x7EA4FF), (0x4F86FF, 0x2F6BFF), (0x2457E6, 0x1C3FB8)]
        let colors = small ? [blues[0], blues[2]] : blues
        let bottom = 512 + (2.5 * sp + len) / 2 - 12   // the clip's lowest point, so the fan sits just above centre
        let yt = bottom - sp - len, yb = yt + len
        for (angle, (top, base)) in zip(angles, colors) {
            ctx.saveGState()
            ctx.translateBy(x: cx, y: bottom + drop); ctx.rotate(by: angle); ctx.translateBy(x: -cx, y: -(bottom + drop))
            let shape = uprightClip(cx: cx, yt: yt, yb: yb, s: sp, innerEnd: yb - 0.55 * sp, outerEnd: yb - 1.1 * sp)
                .copy(strokingWithWidth: w, lineCap: .round, lineJoin: .round, miterLimit: 10)
            ctx.saveGState()   // shadow offsets aren't scaled by the CTM, and y is up in device space
            ctx.setShadow(offset: CGSize(width: 0, height: -14 * k), blur: 28 * k, color: srgb(0x0A1A4A, small ? 0.1 : 0.22))
            ctx.addPath(shape); ctx.setFillColor(srgb(base)); ctx.fillPath()
            ctx.restoreGState()
            ctx.addPath(shape); ctx.clip()
            gradient(srgb(top), srgb(base), from: 200, to: 760)
            ctx.addPath(shape); ctx.setStrokeColor(CGColor(gray: 1, alpha: 0.35)); ctx.setLineWidth(5); ctx.strokePath()   // rim
            ctx.restoreGState()
        }
        gc.flushGraphics()
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

import SwiftUI
import AppKit

/// The house palette: one brand colour with light and dark values per role (same family as Iris).
/// Colour lives only here. Accent means three things: the current selection, the primary action, success.
/// Colours on glass are fixed values (not .secondary) so they keep 4.5:1 over any desktop.
enum Palette {
    /// Light and dark values, plus optional Increase Contrast values.
    private static func dynamic(light: UInt32, dark: UInt32, icLight: UInt32? = nil, icDark: UInt32? = nil) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let v: UInt32
            switch ap.bestMatch(from: [.darkAqua, .aqua, .accessibilityHighContrastDarkAqua, .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua?: v = icDark ?? dark
            case .accessibilityHighContrastAqua?: v = icLight ?? light
            case .darkAqua?: v = dark
            default: v = light
            }
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    /// Selection ring, focus and accent glyphs on cards: a clear blue, `#2B62EB` light / `#5C94FF` dark.
    static let accent = dynamic(light: 0x2B62EB, dark: 0x5C94FF, icLight: 0x1F4FD6, icDark: 0x8DB4FF)
    /// Filled controls (selection count, Picks on). The deep blue in both modes, because white on `#5C94FF` fails.
    static let accentFill = dynamic(light: 0x2B62EB, dark: 0x2B62EB, icLight: 0x1F4FD6, icDark: 0x1F4FD6)
    /// Label and glyph on `accentFill`.
    static let onAccent = Color.white
    /// Selected tab or chip: the strongest neutral, near-black in light and near-white in dark.
    static let ink = dynamic(light: 0x1D1D1F, dark: 0xF2F2F5)
    /// Label on `ink`.
    static let inkOn = dynamic(light: 0xFFFFFF, dark: 0x1D1D1F)
    /// Brand colour for text and glyphs on opaque surfaces (never on raw glass).
    static let brandInk = dynamic(light: 0x2457E6, dark: 0x8AB0FF, icLight: 0x1A45C2, icDark: 0xA9C4FF)

    /// Text and glyphs on shelf glass.
    static let glassLabel = dynamic(light: 0x1D1D1F, dark: 0xF2F2F5)
    /// Quieter text on glass (“248 clips”, empty-state body), in place of .secondary and .tertiary.
    static let glassLabel2 = dynamic(light: 0x3C3C40, dark: 0xE3E3E8, icLight: 0x2C2C30, icDark: 0xEBEBF0)

    /// Gap between a card and its selection ring, so the ring never sits on raw glass.
    static let keyline = dynamic(light: 0xFFFFFF, dark: 0x000000)
    /// Selection ring while the shelf isn't key.
    static let ringInactive = dynamic(light: 0x7C7C82, dark: 0x8E8E93, icLight: 0x5E5E63, icDark: 0xAEAEB2)
    /// Card lift: stronger in dark so dark cards keep an edge on dark glass.
    static let cardShadow = Color(nsColor: NSColor(name: nil) { ap in
        NSColor.black.withAlphaComponent(ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? 0.40 : 0.18)
    })

    /// Card header fill: the colour, darkened in 4% steps (at most 24%) until white or near-black text reaches 4.5:1.
    static func headerFill(_ c: Color) -> Color {
        guard let ns = NSColor(c).usingColorSpace(.sRGB) else { return c }
        let r = ns.redComponent, g = ns.greenComponent, b = ns.blueComponent
        var k: CGFloat = 0
        while k < 0.24, Contrast.bestLabelRatio(red: r * (1 - k), green: g * (1 - k), blue: b * (1 - k)) < 4.5 { k += 0.04 }
        return Color(.sRGB, red: r * (1 - k), green: g * (1 - k), blue: b * (1 - k))
    }
}

/// WCAG relative luminance and contrast, shared by the header fill and its label choice.
enum Contrast {
    static func luminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> Double {
        func lin(_ v: CGFloat) -> Double { let d = Double(v); return d <= 0.03928 ? d / 12.92 : pow((d + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(red) + 0.7152 * lin(green) + 0.0722 * lin(blue)
    }
    /// The better of white and the card's near-black ink (`#121212`) on this colour.
    static func bestLabelRatio(red: CGFloat, green: CGFloat, blue: CGFloat) -> Double {
        let L = luminance(red: red, green: green, blue: blue)
        return max(1.05 / (L + 0.05), (L + 0.05) / 0.0575)
    }
}

extension View {
    /// Tab or chip: quiet fill when idle, inverted neutral when selected. A fill (not tint), so it keeps its colour in
    /// non-activating panels where macOS draws glass tints without colour.
    func capsuleChip(selected: Bool, hPad: CGFloat = 14) -> some View {
        self.foregroundStyle(selected ? Palette.inkOn : Color.primary)
            .padding(.horizontal, hPad).padding(.vertical, 7)
            .background(selected ? AnyShapeStyle(Palette.ink) : AnyShapeStyle(.quaternary), in: Capsule())
    }

    func clipperStyle() -> some View { self.tint(Palette.accent) }
}

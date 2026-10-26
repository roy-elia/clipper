import SwiftUI
import AppKit

/// The house palette: one brand colour with light and dark values per role (same family as Iris).
/// Colour lives only here. Accent means three things: the current selection, the primary action, success.
enum Palette {
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { ap in
            let v = ap.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
        })
    }

    /// Selection and primary action: a clear blue, `#2F6BFF` light / `#5C94FF` dark.
    static let accent = dynamic(light: 0x2F6BFF, dark: 0x5C94FF)
    /// Selected tab or chip: the strongest neutral, near-black in light and near-white in dark.
    static let ink = dynamic(light: 0x1D1D1F, dark: 0xF2F2F5)
    /// Label on `ink`.
    static let inkOn = dynamic(light: 0xFFFFFF, dark: 0x1D1D1F)
    /// Brand colour for text and glyphs on plain surfaces (same blue, tuned for contrast).
    static let brandInk = dynamic(light: 0x2457E6, dark: 0x8AB0FF)
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

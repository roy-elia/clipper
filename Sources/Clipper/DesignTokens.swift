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

    /// Brand `#7559E3`; system controls pick it up through `.tint`.
    static let brand = dynamic(light: 0x7559E3, dark: 0x8F77F0)
    /// Fill for the selected tab, chip and card: lilac `#A78BFA` light / `#B9A6FA` dark.
    static let lilac = dynamic(light: 0xA78BFA, dark: 0xB9A6FA)
    /// Label on lilac: `#22184A` (about 5.8:1 on light lilac, 7.3:1 on dark lilac).
    static let lilacInk = Color(nsColor: NSColor(srgbRed: 0x22 / 255, green: 0x18 / 255, blue: 0x4A / 255, alpha: 1))
    /// Lilac text on plain surfaces: `#6347D8` light / `#C9BCFF` dark.
    static let brandInk = dynamic(light: 0x6347D8, dark: 0xC9BCFF)
}

extension View {
    /// Tab or chip: neutral fill, lilac fill with dark ink when selected. A fill (not tint), so it keeps its colour in
    /// non-activating panels where macOS draws glass tints without colour.
    func capsuleChip(selected: Bool, hPad: CGFloat = 12) -> some View {
        self.foregroundStyle(selected ? Palette.lilacInk : Color.primary)
            .padding(.horizontal, hPad).padding(.vertical, 5)
            .background(selected ? AnyShapeStyle(Palette.lilac) : AnyShapeStyle(.quaternary), in: Capsule())
    }

    func clipperStyle() -> some View { self.tint(Palette.brand) }
}

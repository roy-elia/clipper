import AppKit
import SwiftUI
import QuickLookThumbnailing
import UniformTypeIdentifiers
import DropCore

extension UTType {
    /// A card dragged inside the shelf (its clip id), so it can be dropped on a pinboard tab.
    static let clipperClip = UTType(exportedAs: "com.royelia.clipper.clip-id")
}

/// Quick Look thumbnails for file cards, cached by path.
@MainActor
enum FileThumb {
    private static var cache: [String: NSImage] = [:]
    static func image(for item: ClipItem) async -> NSImage? {
        guard let s = item.fileURLs?.first, let url = URL(string: s), url.isFileURL else { return nil }
        if let c = cache[url.path] { return c }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 220, height: 160), scale: 2, representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) else { return nil }
        cache[url.path] = rep.nsImage
        return rep.nsImage
    }
}

/// Formatted text clips drawn with their bold, italic, underline and colour, at the card's text size.
enum RichText {
    static func attributed(_ item: ClipItem) -> AttributedString? {
        guard !item.isSecret, item.kind == .text, let rtf = item.extras?["public.rtf"] ?? item.extras?["NeXT Rich Text Format v1.0 pasteboard type"],
              let ns = NSMutableAttributedString(rtf: rtf, documentAttributes: nil), ns.length > 0 else { return nil }
        let whole = NSRange(location: 0, length: min(ns.length, 1200))
        let clipped = NSMutableAttributedString(attributedString: ns.attributedSubstring(from: whole))
        let all = NSRange(location: 0, length: clipped.length)
        clipped.enumerateAttribute(.font, in: all) { v, r, _ in
            let f = (v as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            let traits = f.fontDescriptor.symbolicTraits
            var d = NSFont.systemFont(ofSize: 14).fontDescriptor.withSymbolicTraits(traits.intersection([.bold, .italic]))
            if traits.contains(.monoSpace) { d = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular).fontDescriptor }
            clipped.addAttribute(.font, value: NSFont(descriptor: d, size: 14) ?? NSFont.systemFont(ofSize: 14), range: r)
        }
        // Dark text from light documents would vanish in dark mode; keep only clearly coloured runs.
        clipped.enumerateAttribute(.foregroundColor, in: all) { v, r, _ in
            guard let c = (v as? NSColor)?.usingColorSpace(.sRGB) else { return }
            let sat = max(c.redComponent, c.greenComponent, c.blueComponent) - min(c.redComponent, c.greenComponent, c.blueComponent)
            if sat < 0.25 { clipped.removeAttribute(.foregroundColor, range: r) }
        }
        clipped.removeAttribute(.backgroundColor, range: all)
        return try? AttributedString(clipped, including: \.appKit)
    }
}

/// The iCloud sync button in the shelf: spins while syncing; its tooltip says when the last sync finished.
struct SyncButton: View {
    let syncing: Bool
    let last: Date?
    let action: () -> Void
    @State private var spin = false
    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(syncing && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .linear(duration: 1).repeatForever(autoreverses: false) : .default, value: spin)
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onChange(of: syncing) { spin = syncing }
        .help(SyncButton.status(syncing: syncing, last: last))
        .accessibilityLabel(SyncButton.status(syncing: syncing, last: last))
        .accessibilityIdentifier("shelf.sync")
    }
    static func status(syncing: Bool, last: Date?) -> String {
        if syncing { return "Syncing…" }
        guard let last else { return "Not synced yet" }
        return "Synced " + Relative.string(from: last)
    }
}

extension LinkPreview {
    /// A link's preview image shrunk to card size (600 px wide JPEG).
    static func thumbnailJPEG(_ img: NSImage) -> Data? {
        guard let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let scale = min(1, 600 / CGFloat(cg.width))
        let w = Int(CGFloat(cg.width) * scale), h = Int(CGFloat(cg.height) * scale)
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: 0.75])
    }
}

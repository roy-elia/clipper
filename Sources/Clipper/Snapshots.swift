import AppKit
import SwiftUI
import DropCore

@MainActor
func fixtureModel() -> ShelfModel {
    let store = HistoryStore()
    let rules = CaptureRules()
    func add(_ s: String, app: String = "com.apple.Safari") {
        store.add(rules.makeItem(from: .init(types: [], string: s, sourceBundleID: app))!)
    }
    add("The quick brown fox jumps over the lazy dog and keeps running across the field")
    add("https://developer.apple.com/documentation/swiftui")
    add("#3478F6")
    add("func hello() { print(\"hi\") }", app: "com.apple.dt.Xcode")
    let img = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { r in
        NSGradient(colors: [.systemBlue, .systemPink])!.draw(in: r, angle: 30); return true
    }
    if let tiff = img.tiffRepresentation {
        store.add(ClipItem(kind: .image, title: "image", data: tiff, sourceBundleID: "com.apple.Preview", checksum: "img1"))
    }
    store.add(CaptureRules().makeItem(from: .init(types: ["public.file-url"], sourceBundleID: "com.apple.finder", fileURLs: ["file:///Users/me/Report%20Q3.pdf", "file:///Users/me/notes.txt"]))!)
    let rich = NSMutableAttributedString(string: "Formatted paragraph with bold text", attributes: [.font: NSFont.systemFont(ofSize: 12)])
    rich.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 12), range: NSRange(location: 25, length: 4))
    rich.addAttribute(.foregroundColor, value: NSColor.systemOrange, range: NSRange(location: 0, length: 9))
    let rtf = rich.rtf(from: NSRange(location: 0, length: rich.length)) ?? Data()
    store.add(CaptureRules().makeItem(from: .init(types: ["public.rtf"], string: rich.string, sourceBundleID: "com.apple.TextEdit", extras: ["public.rtf": rtf]))!)
    store.add(CaptureRules().makeItem(from: .init(types: [], string: "ghp_16C7e42F292c6912E7710c838347Ae178B4a", sourceBundleID: "com.apple.Terminal"))!)
    let first = store.all.last!
    store.createPinboard("Work"); store.createPinboard("Ideas")
    store.setPinboard("Work", for: first.id)
    let m = ShelfModel(store: store)
    m.stack.push(store.all[0]); m.stack.push(store.all[1])
    return m
}

/// Renders one SwiftUI view into a key window at 2x so materials draw as they do on screen.
@MainActor
func render<V: View>(_ view: V, appearance: NSAppearance.Name, large: Bool, to url: URL) -> CGSize {
    let root = view.environment(\.dynamicTypeSize, large ? .xxxLarge : .large)
    let host = NSHostingView(rootView: root)
    let size = host.fittingSize
    let win = KeyableWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
    win.appearance = NSAppearance(named: appearance)
    win.contentView = host
    win.backgroundColor = appearance == .darkAqua ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.93, alpha: 1)
    win.setFrameOrigin(NSPoint(x: -20000, y: 0))
    win.orderFront(nil); win.makeKey()
    for _ in 0..<4 {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
    }
    // Capture from the window server so vibrancy and materials draw as on screen, then flatten onto the backdrop.
    if let cg = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(win.windowNumber), [.boundsIgnoreFraming, .bestResolution]),
       let ctx = CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
        let full = CGRect(x: 0, y: 0, width: cg.width, height: cg.height)
        ctx.setFillColor((win.backgroundColor.usingColorSpace(.sRGB) ?? .gray).cgColor)
        ctx.fill(full); ctx.draw(cg, in: full)
        if let flat = ctx.makeImage() {
            let rep = NSBitmapImageRep(cgImage: flat); rep.size = size
            if let png = rep.representation(using: .png, properties: [:]) { try? png.write(to: url) }
        }
    }
    win.orderOut(nil)
    return size
}

final class KeyableWindow: NSWindow { override var canBecomeKey: Bool { true } }

@MainActor
func runSnapshots(into dir: String) -> Int32 {
    NSApplication.shared.setActivationPolicy(.accessory)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let m = fixtureModel()
    let item = m.store.all.first { $0.isSecret } ?? m.store.all[0]
    let looks: [(String, NSAppearance.Name, Bool)] = [("light", .aqua, false), ("dark", .darkAqua, false), ("dark-large", .darkAqua, true)]
    var count = 0
    for (name, ap, large) in looks {
        func out(_ screen: String) -> URL { URL(fileURLWithPath: dir).appendingPathComponent("\(screen)-\(name).png") }
        m.picks = false; m.board = nil; m.refresh()
        let a = render(ShelfView(model: m).frame(width: 1400), appearance: ap, large: large, to: out("Shelf")); count += 1
        m.picks = true; m.targetApp = "com.apple.Terminal"; m.refresh()
        _ = render(ShelfView(model: m).frame(width: 1400), appearance: ap, large: large, to: out("Shelf-Picks")); count += 1
        m.picks = false; m.board = "Work"; m.refresh()
        _ = render(ShelfView(model: m).frame(width: 1400), appearance: ap, large: large, to: out("Shelf-Work")); count += 1
        m.board = "Ideas"; m.refresh()
        _ = render(ShelfView(model: m).frame(width: 1400), appearance: ap, large: large, to: out("Shelf-Empty")); count += 1
        _ = render(PreviewView(item: item), appearance: ap, large: large, to: out("Preview")); count += 1
        if let t = m.store.all.first(where: { $0.kind == ClipKind.text && !$0.isSecret && !$0.isRich }) { _ = render(PreviewView(item: t, startEditing: true), appearance: ap, large: large, to: out("Preview-Edit")); count += 1 }
        _ = render(StackView(model: m, onPasteNext: {}), appearance: ap, large: large, to: out("Stack")); count += 1
        _ = render(SettingsView(model: m, accessibilityTrusted: false, mcpToken: "x"), appearance: ap, large: large, to: out("Settings")); count += 1
        _ = render(NewClipView(boards: m.boards, onSave: { _, _ in }, onCancel: {}), appearance: ap, large: large, to: out("NewClip")); count += 1
        _ = render(OnboardingView(hotkey: .default, onGrant: {}, onFinish: {}), appearance: ap, large: large, to: out("Onboarding")); count += 1
        _ = render(WhatsNewView(version: "0.2.0", onClose: {}), appearance: ap, large: large, to: out("WhatsNew")); count += 1
        _ = render(AboutView(version: "0.2.0", build: "abc123"), appearance: ap, large: large, to: out("About")); count += 1
        print("rendered \(name) shelf \(Int(a.width))x\(Int(a.height)) pt")
    }
    print("SNAPSHOTS \(count) -> \(dir)")
    return 0
}

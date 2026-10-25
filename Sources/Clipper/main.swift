import AppKit
import SwiftUI
import DropCore

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let store = HistoryStore(url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Clipper/history.json"))
    lazy var monitor = PasteboardMonitor(store: store)
    lazy var model = ShelfModel(store: store)
    var panel: NSPanel?
    var statusItem: NSStatusItem?
    let hotkeys = HotkeyCenter()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clipper")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Clipper", action: #selector(toggle), keyEquivalent: "").target = self
        let pause = menu.addItem(withTitle: "Pause Capture", action: #selector(togglePause(_:)), keyEquivalent: "")
        pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        monitor.onChange = { [weak self] in self?.model.refresh() }
        model.onPick = { [weak self] item in self?.pick(item) }
        hotkeys.onFire = { [weak self] in self?.toggle() }
        if !hotkeys.register(.default) { NSLog("Clipper: could not register \(Hotkey.default.display)") }
        menu.addItem(withTitle: "Paste Needs Accessibility…", action: #selector(grant), keyEquivalent: "").target = self
        monitor.start()
    }

    @objc func grant() {
        if !PasteInjector.requestAccess() { PasteInjector.openAccessibilitySettings() }
    }

    /// Hide the shelf, put the clip on the pasteboard, then ⌘V into whatever app is still frontmost.
    func pick(_ item: ClipItem) {
        monitor.write(item)
        panel?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            if !PasteInjector.pasteNow() { PasteInjector.requestAccess() }
        }
    }

    @objc func togglePause(_ s: NSMenuItem) {
        monitor.paused.toggle(); s.title = monitor.paused ? "Resume Capture" : "Pause Capture"
    }

    @objc func toggle() {
        if panel == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 190),
                            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled], backing: .buffered, defer: false)
            p.titleVisibility = .hidden; p.titlebarAppearsTransparent = true; p.isFloatingPanel = true
            p.isMovableByWindowBackground = true; p.backgroundColor = .clear
            let host = NSHostingView(rootView: ShelfView(model: model))
            p.contentView = host
            panel = p
        }
        if let s = NSScreen.main, let p = panel {
            p.setFrameOrigin(NSPoint(x: s.frame.midX - 380, y: s.frame.minY + 60))
        }
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        model.refresh(); panel?.makeKeyAndOrderFront(nil)
    }
}

/// Non-activating so the app you are pasting into stays frontmost, yet still able to take typing for search.
final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

/// --selftest: exercises capture on a private pasteboard without touching the user's clipboard.
@MainActor func selftest() -> Int32 {
    var fails = 0
    func check(_ name: String, _ ok: Bool) { print(ok ? "PASS" : "FAIL", name); if !ok { fails += 1 } }
    let pb = NSPasteboard(name: NSPasteboard.Name("clipper.selftest.\(UUID())"))
    let store = HistoryStore(capacity: 50)
    let mon = PasteboardMonitor(pasteboard: pb, store: store)
    pb.clearContents(); pb.setString("hello selftest", forType: .string)
    check("captures text", mon.poll()?.text == "hello selftest")
    check("no change, no capture", mon.poll() == nil)
    pb.clearContents(); pb.setString("hello selftest", forType: .string)
    _ = mon.poll(); check("duplicate collapses", store.all.count == 1)
    pb.clearContents(); pb.setString("secret", forType: .string)
    pb.setData(Data(), forType: NSPasteboard.PasteboardType(CaptureRules.concealed))
    check("concealed skipped", mon.poll() == nil && store.all.count == 1)
    pb.clearContents(); pb.setString("https://example.com", forType: .string)
    check("link kind", mon.poll()?.kind == .link)
    mon.paused = true; pb.clearContents(); pb.setString("while paused", forType: .string)
    check("paused skipped", mon.poll() == nil)
    mon.paused = false
    if let first = store.all.last { mon.write(first); check("write not recaptured", mon.poll() == nil) }
    let hc = HotkeyCenter()
    check("hotkey registers", hc.register(Hotkey(keyCode: 9, modifiers: Hotkey.cmd | Hotkey.option | Hotkey.control)))
    check("bad hotkey rejected", !hc.register(Hotkey(keyCode: 9, modifiers: Hotkey.shift)))
    hc.unregister()
    print("INFO accessibility trusted:", PasteInjector.trusted)
    check("paste is a no-op without permission", PasteInjector.trusted || !PasteInjector.pasteNow())
    print(fails == 0 ? "SELFTEST OK" : "SELFTEST FAILED \(fails)")
    return fails == 0 ? 0 : 1
}

if CommandLine.arguments.contains("--selftest") {
    exit(MainActor.assumeIsolated { selftest() })
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

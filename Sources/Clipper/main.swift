import AppKit
import SwiftUI
import DropCore

@MainActor
final class App: NSObject, NSApplicationDelegate {
    static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clipper")
    static let settingsURL = support.appendingPathComponent("settings.json")
    let store = HistoryStore(url: App.support.appendingPathComponent("history.json"))
    lazy var monitor = PasteboardMonitor(store: store)
    lazy var model = ShelfModel(store: store, settings: AppSettings.load(App.settingsURL))
    var panel: NSPanel?
    var previewPanel: NSPanel?
    var stackWindow: NSWindow?
    var settingsWindow: NSWindow?
    var mcp: MCPServer?
    static let tokenURL = App.support.appendingPathComponent("mcp-token")
    lazy var mcpToken = MCPServer.loadToken(at: App.tokenURL)
    var statusItem: NSStatusItem?
    let hotkeys = HotkeyCenter()

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clipper")
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Clipper", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Paste Stack…", action: #selector(showStack), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        let pause = menu.addItem(withTitle: "Pause Capture", action: #selector(togglePause(_:)), keyEquivalent: "")
        pause.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem?.menu = menu
        monitor.onChange = { [weak self] in self?.model.refresh() }
        model.onPick = { [weak self] item in self?.pick(item) }
        model.onPreview = { [weak self] item in self?.preview(item) }
        model.onSettingsChanged = { [weak self] in
            guard let self else { return }
            model.settings.save(App.settingsURL)
            applyMCP()
        }
        applyMCP()
        store.capacity = model.settings.historyCapacity
        hotkeys.onFire = { [weak self] in self?.toggle() }
        if !hotkeys.register(model.settings.hotkey) { NSLog("Clipper: could not register \(model.settings.hotkey.display)") }
        menu.addItem(withTitle: "Paste Needs Accessibility…", action: #selector(grant), keyEquivalent: "").target = self
        monitor.start()
        PasteInjector.diag("launch: pid \(ProcessInfo.processInfo.processIdentifier) trusted=\(PasteInjector.trusted) postEventAccess=\(CGPreflightPostEventAccess())")
    }

    func window(_ title: String, _ view: some View, id: String) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(id); w.center(); return w
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window("Clipper Settings", SettingsView(model: model, accessibilityTrusted: PasteInjector.trusted, mcpToken: mcpToken, onGrant: { [weak self] in self?.grant() }), id: "settings")
        }
        NSApp.activate(); settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showStack() {
        if stackWindow == nil {
            stackWindow = window("Paste Stack", StackView(model: model, onPasteNext: { [weak self] in self?.pasteNext() }), id: "stack")
            stackWindow?.level = .floating
        }
        stackWindow?.makeKeyAndOrderFront(nil)
    }

    /// Pops the oldest stacked clip and pastes it; the stack window never takes focus from the target app.
    func pasteNext() {
        guard let item = model.stack.pop() else { return }
        pick(item)
    }

    func preview(_ item: ClipItem) {
        if previewPanel == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                               styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.title = "Preview"; previewPanel = p
        }
        previewPanel?.contentView = NSHostingView(rootView: PreviewView(item: item))
        previewPanel?.center(); previewPanel?.makeKeyAndOrderFront(nil)
    }

    @objc func grant() {
        if !PasteInjector.requestAccess() { PasteInjector.openAccessibilitySettings() }
    }

    /// Hide the shelf, put the clip on the pasteboard, then ⌘V into whatever app is still frontmost.
    func pick(_ item: ClipItem) {
        PasteInjector.diag("pick: \(item.kind.rawValue) \"\(item.title.prefix(20))\" previousApp=\((panel as? ShelfPanel)?.previousApp?.bundleIdentifier ?? "nil")")
        monitor.write(item)
        panel?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            let ok = PasteInjector.pasteNow()
            NSLog("Clipper paste: trusted=%d posted=%d frontmost=%@", PasteInjector.trusted ? 1 : 0, ok ? 1 : 0, front)
            if !ok { PasteInjector.requestAccess() }
        }
    }

    /// Starts, restarts or stops the MCP server to match settings.
    func applyMCP() {
        let s = model.settings
        if let m = mcp, !s.mcpEnabled || m.port != s.mcpPort { m.stop(); mcp = nil }
        guard s.mcpEnabled, mcp == nil else { return }
        let server = MCPServer(store: store, token: mcpToken, port: s.mcpPort)
        server.onState = { NSLog("Clipper MCP \($0)") }
        do { try server.start(); mcp = server } catch { NSLog("Clipper MCP failed to start: \(error)") }
    }

    @objc func togglePause(_ s: NSMenuItem) {
        monitor.paused.toggle(); s.title = monitor.paused ? "Resume Capture" : "Pause Capture"
    }

    @objc func toggle() {
        if panel == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 252),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.hasShadow = false; p.becomesKeyOnlyIfNeeded = true
            p.isMovableByWindowBackground = true; p.backgroundColor = .clear; p.isOpaque = false
            let host = NSHostingView(rootView: ShelfView(model: model))
            p.contentView = host
            panel = p
        }
        if let s = NSScreen.main, let p = panel {
            p.setFrameOrigin(NSPoint(x: s.visibleFrame.midX - 380, y: s.visibleFrame.minY + 24))
        }
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        if let shelf = panel as? ShelfPanel {
            let front = NSWorkspace.shared.frontmostApplication
            shelf.previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
        }
        // Don't take key status from the app being pasted into; the panel becomes key only if a text field is clicked.
        model.refresh(); panel?.orderFrontRegardless()
    }
}

/// Non-activating so the app you are pasting into stays frontmost, yet still able to take typing for search.
final class ShelfPanel: NSPanel {
    /// The app that was frontmost when the panel opened. Making this panel key takes key status from that app's
    /// window, so closing the panel must hand it back or the next keystroke (including our ⌘V) goes nowhere.
    var previousApp: NSRunningApplication?
    override var canBecomeKey: Bool { true }
    override func orderOut(_ sender: Any?) {
        super.orderOut(sender)
        previousApp?.activate()
        previousApp = nil
    }
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
    let m = ShelfModel(store: store)
    m.addBoard("Work"); check("board created and selected", m.boards == ["Work"] && m.board == "Work")
    if let it = store.all.first { m.pin(it, to: "Work"); check("pin shows on board", m.items.count == 1)
        m.stack.push(it); m.delete(it); check("delete clears stack", m.stack.isEmpty) }
    m.renameBoard("Work", "Office"); check("rename", m.board == "Office" && m.boards == ["Office"])
    m.deleteBoard("Office"); check("delete board returns to history", m.board == nil && m.boards.isEmpty)
    m.updateSettings { $0.setCapacity(10) }
    check("capacity clamped and applied", store.capacity == 50)
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
/// --serve-mcp <port> <tokenfile>: headless server over an in-memory store, for end-to-end tests.
if let i = CommandLine.arguments.firstIndex(of: "--serve-mcp"), i + 2 < CommandLine.arguments.count,
   let port = UInt16(CommandLine.arguments[i + 1]) {
    let server = MCPServer(store: HistoryStore(), token: MCPServer.loadToken(at: URL(fileURLWithPath: CommandLine.arguments[i + 2])), port: port)
    server.onState = { print("MCP \($0)"); fflush(stdout) }
    do { try server.start() } catch { print("MCP failed: \(error)"); exit(1) }
    RunLoop.main.run()
}
if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
    exit(MainActor.assumeIsolated { runSnapshots(into: CommandLine.arguments[i + 1]) })
}
let delegate = MainActor.assumeIsolated { App() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()

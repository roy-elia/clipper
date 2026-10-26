import AppKit
import AVFoundation
import SwiftUI
import DropCore

@MainActor
final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// CLIPPER_SUPPORT_DIR points a test run at a scratch folder so it never touches the real history.
    static let support = ProcessInfo.processInfo.environment["CLIPPER_SUPPORT_DIR"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clipper")
    static let settingsURL = support.appendingPathComponent("settings.json")
    let store = HistoryStore(url: App.support.appendingPathComponent("history.json"))
    lazy var monitor = PasteboardMonitor(store: store)
    static let logURL = support.appendingPathComponent("paste-log.json")
    lazy var model = ShelfModel(store: store, settings: AppSettings.load(App.settingsURL))
    var panel: NSPanel?
    var previewPanel: NSPanel?
    var stackWindow: NSWindow?
    var settingsWindow: NSWindow?
    var mcp: MCPServer?
    static let tokenURL = App.support.appendingPathComponent("mcp-token")
    lazy var mcpToken = MCPServer.loadToken(at: App.tokenURL)
    var statusItem: NSStatusItem?
    var statusMenu: NSMenu?
    var clickAwayMonitor: Any?
    var wheelMonitor: Any?
    let hotkeys = HotkeyCenter()
    let stackHotkeys = HotkeyCenter(id: 2)
    let sounds = SoundFeedback()
    let osd = OSD()
    var collecting = false
    var collectItem: NSMenuItem?
    var pauseItem: NSMenuItem?
    var statusLine: NSMenuItem?
    var grantItem: NSMenuItem?
    var onboardingWindow: NSWindow?
    var whatsNewWindow: NSWindow?
    var aboutWindow: NSWindow?
    static let syncStateURL = support.appendingPathComponent("sync-state.json")
    var syncState = SyncState()
    var syncing = false
    var confirming = false
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }

    func applicationDidFinishLaunching(_ n: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "paperclip", accessibilityDescription: "Clipper")
        let menu = NSMenu()
        statusLine = menu.addItem(withTitle: "Capturing", action: nil, keyEquivalent: ""); statusLine?.isEnabled = false
        menu.addItem(.separator())
        menu.addItem(withTitle: "Show Clipper", action: #selector(toggle), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Clip…", action: #selector(showNewClip), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Paste Stack…", action: #selector(showStack), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Clear History…", action: #selector(confirmClear), keyEquivalent: "").target = self
        collectItem = menu.addItem(withTitle: "Collect Copies to Stack", action: #selector(toggleCollect(_:)), keyEquivalent: "")
        collectItem?.target = self
        let pause = menu.addItem(withTitle: "Pause Capture", action: #selector(togglePause(_:)), keyEquivalent: "")
        pause.target = self; pauseItem = pause
        grantItem = menu.addItem(withTitle: "Allow Pasting (Accessibility)…", action: #selector(grant), keyEquivalent: "")
        grantItem?.target = self
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Getting Started…", action: #selector(showGettingStarted), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About Clipper", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu = menu
        statusItem?.button?.target = self
        statusItem?.button?.action = #selector(statusClicked)
        statusItem?.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        monitor.onChange = { [weak self] in self?.model.refresh() }
        model.onPick = { [weak self] item, plain in self?.pick(item, plain: plain) }
        model.onClose = { [weak self] in self?.panel?.orderOut(nil) }
        model.onPreview = { [weak self] item in self?.preview(item) }
        model.onClear = { [weak self] in self?.confirmClear() }
        model.onDrop = { [weak self] providers in self?.ingest(providers) ?? false }
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.panel?.isVisible == true { PasteInjector.diag("resign buttons=\(NSEvent.pressedMouseButtons)") }; if self?.panel?.isVisible == true, self?.confirming == false, NSEvent.pressedMouseButtons == 0 { self?.panel?.orderOut(nil) } }
        }
        installWheelScrolling()
        model.onSettingsChanged = { [weak self] in
            guard let self else { return }
            model.settings.save(App.settingsURL)
            applyMCP()
            if hotkeys.registered != model.settings.hotkey, !hotkeys.register(model.settings.hotkey) {
                NSLog("Clipper: could not register \(model.settings.hotkey.display)")
            }
            monitor.secretPolicy = model.settings.secretPolicy
            monitor.rules = CaptureRules(ignoredBundleIDs: Set(model.settings.ignoredBundleIDs))
            sounds.enabled = model.settings.playSounds
            if stackHotkeys.registered != model.settings.stackHotkey { stackHotkeys.register(model.settings.stackHotkey) }
            applyPrivacy()
            applySpotlight()
            if model.settings.iCloudSync { syncNow() }
        }
        applyMCP()
        store.capacity = model.settings.historyCapacity
        model.log = PasteLog.load(App.logURL)
        monitor.secretPolicy = model.settings.secretPolicy
        hotkeys.onFire = { [weak self] in self?.toggle() }
        if !hotkeys.register(model.settings.hotkey) { NSLog("Clipper: could not register \(model.settings.hotkey.display)") }
        monitor.onChange = { [weak self] in
            guard let self else { return }
            askModelAboutLatest()
            if let latest = store.all.first {
                sounds.play(.copy)
                if latest.isSecret { osd.show("Secret copied. Hidden.", symbol: "lock.fill", hideFromSharing: model.settings.hideFromSharing) }
                else if collecting { model.stack.push(latest); osd.show("Added to stack (\(model.stack.items.count))", symbol: "square.stack.3d.up", hideFromSharing: model.settings.hideFromSharing) }
            }
            if model.settings.iCloudSync { syncNow() }
            model.refresh()
            if model.settings.spotlightEnabled { applySpotlight() }
        }
        Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.purgeSecrets() }
        }
        installPanelShortcuts()
        monitor.rules = CaptureRules(ignoredBundleIDs: Set(model.settings.ignoredBundleIDs))
        sounds.enabled = model.settings.playSounds
        stackHotkeys.onFire = { [weak self] in self?.pasteNext() }
        stackHotkeys.register(model.settings.stackHotkey)
        model.onShare = { [weak self] item in self?.share(item) }
        syncState = (try? Data(contentsOf: App.syncStateURL)).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.syncNow() } }
        DispatchQueue.main.async { [weak self] in self?.showFirstRunWindows() }
        monitor.start()
        applySpotlight()
        PasteInjector.diag("launch: pid \(ProcessInfo.processInfo.processIdentifier) trusted=\(PasteInjector.trusted) postEventAccess=\(CGPreflightPostEventAccess())")
    }

    func window(_ title: String, _ view: some View, id: String) -> NSWindow {
        let w = NSWindow(contentViewController: NSHostingController(rootView: view))
        w.title = title; w.styleMask = [.titled, .closable]; w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(id); w.center(); return w
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window("Clipper Settings", SettingsView(model: model, accessibilityTrusted: PasteInjector.trusted, mcpToken: mcpToken, modelNote: SmartClassifier.isAvailable ? " On-device model: available." : " On-device model: not available on this Mac, rules only.", onGrant: { [weak self] in self?.grant() }), id: "settings")
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
        guard let item = model.stack.pop() else { osd.show("Stack is empty", symbol: "square.stack.3d.up", hideFromSharing: model.settings.hideFromSharing); return }
        osd.show("Pasting \(item.isSecret ? "a secret" : String(item.title.prefix(24)))  ·  \(model.stack.items.count) left", symbol: "square.stack.3d.up", hideFromSharing: model.settings.hideFromSharing)
        pick(item, plain: false)
    }

    func preview(_ item: ClipItem) {
        if previewPanel == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                               styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.title = "Preview"; previewPanel = p
        }
        previewPanel?.contentView = NSHostingView(rootView: PreviewView(item: item, onSave: { [weak self] text in
            guard let self else { return }
            if let updated = store.updateText(item.id, to: text) { model.refresh(); preview(updated) }
        }))
        applyPrivacy()
        previewPanel?.center(); previewPanel?.makeKeyAndOrderFront(nil)
    }

    /// ⌘1–9 paste, ⌘Y preview, ⌘⌫ delete. A local monitor is used because a non-activating panel never gets
    /// the key-equivalent pass that normal windows do.
    func installPanelShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel, panel.isVisible, e.window === panel else { return e }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // ⇧Return pastes as plain text; the text field would otherwise turn it into a line break.
            if mods == .shift, e.keyCode == 36 || e.keyCode == 76 { model.pickSelected(plain: true); return nil }
            guard mods == .command else { return e }
            if e.keyCode == 51 { model.deleteSelected(); return nil }
            if let c = e.charactersIgnoringModifiers {
                if let n = Int(c), (1...9).contains(n) { model.pick(number: n); return nil }
                if c == "y", let i = model.selected { model.onPreview?(i); return nil }
            }
            return e
        }
    }

    /// Unclear short tokens go to the on-device model; a "secret" verdict hides the clip like a rule match would.
    func askModelAboutLatest() {
        guard model.settings.smartModel, let item = store.all.first, !item.isSecret, let text = item.text,
              SecretDetector.isAmbiguous(text) else { return }
        Task { @MainActor in
            if await SmartClassifier.looksSecret(text) == true {
                store.markSecret(item.id, byModel: true); PasteInjector.diag("model: marked a clip as secret"); model.refresh()
            }
        }
    }

    func purgeSecrets() {
        guard model.settings.secretPolicy == .expire else { return }
        if store.purgeSecrets(olderThan: TimeInterval(model.settings.secretMinutes * 60)) > 0 { model.refresh() }
    }

    /// Keeps Clipper's windows out of screen sharing, recordings and screenshots taken by other apps.
    func applyPrivacy() {
        let type: NSWindow.SharingType = model.settings.hideFromSharing ? .none : .readOnly
        for w in [panel, previewPanel, stackWindow, settingsWindow, newClipWindow] { w?.sharingType = type }
    }

    @objc func toggleCollect(_ s: NSMenuItem) {
        collecting.toggle(); s.state = collecting ? .on : .off
        osd.show(collecting ? "Collecting copies into the stack" : "Stopped collecting", symbol: "square.stack.3d.up", hideFromSharing: model.settings.hideFromSharing)
    }

    func share(_ item: ClipItem) {
        var things: [Any] = []
        if let urls = item.fileURLs, !urls.isEmpty { things = urls.compactMap { URL(string: $0) } }
        else if let d = item.data, let img = NSImage(data: d) { things = [img] }
        else if let t = item.text { things = [t] }
        guard !things.isEmpty, !item.isSecret, let view = panel?.contentView else { return }
        NSSharingServicePicker(items: things).show(relativeTo: NSRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    func syncNow() {
        guard model.settings.iCloudSync, CloudKitTransport.available, !syncing else { return }
        syncing = true
        let transport = CloudKitTransport(); let store = store; var state = syncState
        Task.detached {
            do { let r = try await SyncCoordinator.sync(store, state: &state, transport: transport); PasteInjector.diag("sync: pushed \(r.pushed) pulled \(r.pulled)") }
            catch { PasteInjector.diag("sync failed: \(error.localizedDescription)") }
            let done = state
            await MainActor.run {
                self.syncState = done; self.syncing = false
                if let d = try? JSONEncoder().encode(done) { try? d.write(to: App.syncStateURL, options: .atomic) }
                self.model.refresh()
            }
        }
    }

    func showFirstRunWindows() {
        if !model.settings.onboarded {
            presentOnboarding()
        } else if model.settings.lastSeenVersion != App.version {
            whatsNewWindow = window("What's New", WhatsNewView(version: App.version, onClose: { [weak self] in
                self?.whatsNewWindow?.close(); self?.whatsNewWindow = nil
            }), id: "whatsnew")
            model.updateSettings { $0.lastSeenVersion = App.version }
            NSApp.activate(); whatsNewWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func presentOnboarding() {
        do {
            onboardingWindow = window("Welcome", OnboardingView(hotkey: model.settings.hotkey, onGrant: { [weak self] in self?.grant() }, onFinish: { [weak self] in
                guard let self else { return }
                model.updateSettings { $0.onboarded = true; $0.lastSeenVersion = App.version }
                onboardingWindow?.close(); onboardingWindow = nil
            }), id: "onboarding")
            NSApp.activate(); onboardingWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// The permission item only shows while pasting is not allowed yet.
    func menuNeedsUpdate(_ menu: NSMenu) { grantItem?.isHidden = PasteInjector.trusted }

    @objc func showGettingStarted() {
        presentOnboarding()
    }

    @objc func showAbout() {
        if aboutWindow == nil { aboutWindow = window("About Clipper", AboutView(version: App.version, build: App.build), id: "about") }
        NSApp.activate(); aboutWindow?.makeKeyAndOrderFront(nil)
    }

    var newClipWindow: NSWindow?
    let spotlight = SpotlightIndexer()

    @objc func showNewClip() {
        let view = NewClipView(boards: store.pinboards(), onSave: { [weak self] text, board in
            guard let self, var item = CaptureRules().makeItem(from: .init(types: [], string: text, sourceBundleID: Bundle.main.bundleIdentifier)) else { return }
            item.pinboard = board
            store.add(item); model.refresh(); newClipWindow?.close(); newClipWindow = nil
        }, onCancel: { [weak self] in self?.newClipWindow?.close(); self?.newClipWindow = nil })
        newClipWindow = window("New Clip", view, id: "newclip")
        NSApp.activate(); newClipWindow?.makeKeyAndOrderFront(nil)
    }

    func applySpotlight() {
        if model.settings.spotlightEnabled { spotlight.sync(store.all) } else { spotlight.removeAll() }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for u in urls { handle(URLAction.parse(u)) }
    }

    func handle(_ a: URLAction?) {
        switch a {
        case .show?: if panel?.isVisible != true { toggle() }
        case .stack?: showStack()
        case .new?: showNewClip()
        case .settings?: showSettings()
        case .collect?: if let m = collectItem { toggleCollect(m) }
        case .pause?: togglePause(pauseItem ?? NSMenuItem())
        case .about?: showAbout()
        case .clear?: confirmClear()
        case .search(let q)?: if panel?.isVisible != true { toggle() }; model.query = q; model.refresh()
        case nil: break
        }
    }

    @objc func grant() {
        if !PasteInjector.requestAccess() { PasteInjector.openAccessibilitySettings() }
    }

    /// Hide the shelf, put the clip on the pasteboard, then ⌘V into whatever app is still frontmost.
    func pick(_ item: ClipItem, plain: Bool = false) {
        PasteInjector.diag("pick: \(item.kind.rawValue) \"\(item.title.prefix(20))\" previousApp=\((panel as? ShelfPanel)?.previousApp?.bundleIdentifier ?? "nil")")
        if let target = (panel as? ShelfPanel)?.previousApp?.bundleIdentifier ?? NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           target != Bundle.main.bundleIdentifier {
            model.log.record(.init(itemID: item.id, kind: item.kind, targetApp: target)); model.log.save(App.logURL)
        }
        monitor.write(item, plain: plain)
        sounds.play(.paste)
        panel?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            let ok = PasteInjector.pasteNow()
            PasteInjector.diag("pasted plain=\(plain) ok=\(ok) frontmost=\(front)")
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
        statusLine?.title = monitor.paused ? "Paused" : "Capturing"
        osd.show(monitor.paused ? "Capture paused" : "Capture resumed", symbol: monitor.paused ? "pause.circle" : "play.circle", hideFromSharing: model.settings.hideFromSharing)
    }

    @objc func statusClicked() {
        guard let e = NSApp.currentEvent else { toggle(); return }
        if e.type == .rightMouseUp || e.modifierFlags.contains(.control), let m = statusMenu, let b = statusItem?.button {
            panel?.orderOut(nil)
            m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
        } else { toggle() }
    }

    /// Always asks first: deleting history cannot be undone.
    @objc func confirmClear() {
        let total = store.all.count, pinned = store.all.filter { $0.pinboard != nil }.count
        guard total > 0 else { osd.show("Nothing to clear", symbol: "tray", hideFromSharing: model.settings.hideFromSharing); return }
        confirming = true; defer { confirming = false }
        NSApp.activate()
        let a = NSAlert()
        a.messageText = "Clear all saved clips?"
        a.informativeText = "This deletes \(total) saved \(total == 1 ? "clip" : "clips") from Clipper and its synced copies. It cannot be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete All")
        if pinned > 0 { a.addButton(withTitle: "Keep Pinned (\(pinned))") }
        a.addButton(withTitle: "Cancel")
        let r = a.runModal()
        let keep: Bool
        switch (r, pinned > 0) {
        case (.alertFirstButtonReturn, _): keep = false
        case (.alertSecondButtonReturn, true): keep = true
        default: return
        }
        let n = store.clear(keepPinned: keep)
        model.refresh()
        osd.show("Cleared \(n) \(n == 1 ? "clip" : "clips")", symbol: "trash", hideFromSharing: model.settings.hideFromSharing)
    }

    /// Drops onto the shelf save the dropped images, files and text as clips.
    func ingest(_ providers: [NSItemProvider]) -> Bool {
        PasteInjector.diag("drop: \(providers.count) item(s)")
        let rules = monitor.rules
        let me = Bundle.main.bundleIdentifier
        var accepted = false
        for p in providers {
            if p.hasItemConformingToTypeIdentifier("public.file-url") {
                accepted = true
                p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in
                        let snap = PasteboardSnapshot(types: ["public.file-url"], string: nil, data: nil, sourceBundleID: me, fileURLs: [url.absoluteString])
                        if let item = rules.makeItem(from: snap) { _ = self.store.add(item); self.model.refresh() }
                    }
                }
            } else if p.canLoadObject(ofClass: NSImage.self) {
                accepted = true
                p.loadObject(ofClass: NSImage.self) { obj, _ in
                    guard let img = obj as? NSImage, let tiff = img.tiffRepresentation,
                          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
                    Task { @MainActor in
                        let snap = PasteboardSnapshot(types: ["public.png"], string: nil, data: png, sourceBundleID: me)
                        if let item = rules.makeItem(from: snap) { _ = self.store.add(item); self.model.refresh() }
                    }
                }
            } else if p.canLoadObject(ofClass: NSString.self) {
                accepted = true
                _ = p.loadObject(ofClass: NSString.self) { obj, _ in
                    guard let str = obj as? String else { return }
                    Task { @MainActor in
                        let snap = PasteboardSnapshot(types: ["public.utf8-plain-text"], string: str, data: nil, sourceBundleID: me)
                        if let item = rules.makeItem(from: snap) { _ = self.store.add(item); self.model.refresh() }
                    }
                }
            }
        }
        return accepted
    }

    /// A mouse wheel only scrolls vertically; turn it sideways so it moves along the row of clips.
    func installWheelScrolling() {
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
            guard let self, let panel, panel.isVisible, e.window === panel,
                  !e.hasPreciseScrollingDeltas, abs(e.scrollingDeltaY) > abs(e.scrollingDeltaX),
                  let cg = e.cgEvent?.copy() else { return e }
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventPointDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: cg.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1))
            cg.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
            return NSEvent(cgEvent: cg) ?? e
        }
    }

    @objc func toggle() {
        if panel == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 326),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.hasShadow = false
            p.backgroundColor = .clear; p.isOpaque = false
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let host = NSHostingView(rootView: ShelfView(model: model))
            p.contentView = host
            panel = p
            applyPrivacy()
        }
        if panel?.isVisible == true { panel?.orderOut(nil); return }
        if let shelf = panel as? ShelfPanel {
            let front = NSWorkspace.shared.frontmostApplication
            shelf.previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? nil : front
            model.targetApp = shelf.previousApp?.bundleIdentifier
        }
        model.picks = model.settings.opensOnPicks && !PickRanker(log: model.log).rank(store.all, for: model.targetApp, limit: 1).isEmpty
        model.board = nil; model.selection = 0; model.query = ""
        model.refresh(); model.focusTick += 1
        // The shelf rises from the bottom edge of the screen the pointer is on, full width with a small margin.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let v = screen?.visibleFrame, let p = panel {
            let inset: CGFloat = 12, h: CGFloat = 326
            let end = NSRect(x: v.minX + inset, y: v.minY + inset, width: v.width - inset * 2, height: h)
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            p.setFrame(reduce ? end : end.offsetBy(dx: 0, dy: -(h + inset)), display: false)
            p.alphaValue = reduce ? 0 : 1
            NSApp.activate(); p.makeKeyAndOrderFront(nil)
            NSAnimationContext.runAnimationGroup { c in
                c.duration = reduce ? 0.15 : 0.32
                c.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                p.animator().setFrame(end, display: true)
                p.animator().alphaValue = 1
            }
        }
        startClickAway()
    }

    func stopClickAway() {
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m); clickAwayMonitor = nil }
    }

    /// A press outside the shelf dismisses it on release, unless that press was a drag that ended over the shelf
    /// (dragging a file in from Finder must not close the shelf it is being dropped on).
    func startClickAway() {
        if let m = clickAwayMonitor { NSEvent.removeMonitor(m) }
        var downOutside = false, dragged = false
        clickAwayMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseDragged, .leftMouseUp]) { [weak self] e in
            MainActor.assumeIsolated {
                guard let self, let p = self.panel, p.isVisible, !self.confirming else { return }
                let inside = p.frame.contains(NSEvent.mouseLocation)
                if e.type != .leftMouseDragged { PasteInjector.diag("away: \(e.type.rawValue) inside=\(inside)") }
                switch e.type {
                case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                    downOutside = !inside; dragged = false
                    if downOutside, e.type != .leftMouseDown { p.orderOut(nil) }
                case .leftMouseDragged: dragged = true
                case .leftMouseUp:
                    if downOutside, !(dragged && inside) { p.orderOut(nil) }
                    downOutside = false; dragged = false
                default: break
                }
            }
        }
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
        (NSApp.delegate as? App)?.stopClickAway()
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
    // rich text keeps formatting on a normal write and drops it for plain
    pb.clearContents(); pb.setString("styled", forType: .string); pb.setData(Data("{\\rtf1 styled}".utf8), forType: .rtf)
    let rich = mon.poll(); check("rich text captured with rtf", rich?.isRich == true)
    if let r = rich {
        mon.write(r); check("normal write restores rtf", pb.data(forType: .rtf) != nil)
        mon.write(r, plain: true); check("plain write drops rtf", pb.data(forType: .rtf) == nil && pb.string(forType: .string) == "styled")
    }
    // files round-trip as real file URLs
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-selftest.txt"); try? "x".write(to: tmp, atomically: true, encoding: .utf8)
    pb.clearContents(); pb.writeObjects([tmp as NSURL])
    let f = mon.poll(); check("file captured as file clip", f?.kind == .file && f?.fileNames == ["clipper-selftest.txt"])
    if let f { mon.write(f); check("file write restores a file URL", (pb.readObjects(forClasses: [NSURL.self], options: nil) as? [URL])?.first?.lastPathComponent == "clipper-selftest.txt") }
    try? FileManager.default.removeItem(at: tmp)
    let m = ShelfModel(store: store)
    m.addBoard("Work"); check("board created and selected", m.boards == ["Work"] && m.board == "Work")
    if let it = store.all.first { m.pin(it, to: "Work"); check("pin shows on board", m.items.count == 1)
        m.stack.push(it); m.delete(it); check("delete clears stack", m.stack.isEmpty) }
    m.renameBoard("Work", "Office"); check("rename", m.board == "Office" && m.boards == ["Office"])
    m.deleteBoard("Office"); check("delete board returns to history", m.board == nil && m.boards.isEmpty)
    m.board = nil; m.refresh(); m.selection = 0
    m.move(1); check("selection moves", m.selection == (m.items.count > 1 ? 1 : 0)); m.move(-5); check("selection clamps", m.selection == 0)
    var picked: (String, Bool)?
    m.onPick = { picked = ($0.title, $1) }
    m.pickSelected(plain: true); check("return pastes selection, shift means plain", picked?.1 == true)
    m.pick(number: 1); check("quick-number picks first", picked?.1 == false)
    m.app = "no.such.app"; m.refresh(); check("app filter narrows", m.items.isEmpty); m.app = nil; m.refresh()
    m.updateSettings { $0.setCapacity(10) }
    check("capacity clamped and applied", store.capacity == 50)
    // secrets
    pb.clearContents(); pb.setString("ghp_16C7e42F292c6912E7710c838347Ae178B4a", forType: .string)
    check("token captured and flagged secret", mon.poll()?.isSecret == true)
    mon.secretPolicy = .skip; pb.clearContents(); pb.setString("ghp_16C7e42F292c6912E7710c838347Ae178B4b", forType: .string)
    check("skip policy never saves a secret", mon.poll() == nil); mon.secretPolicy = .expire
    print("INFO on-device model:", SmartClassifier.availability)
    if SmartClassifier.isAvailable {
        for sample in ["Tr0ub4dor&3", "correct-horse-battery-staple-9", "quarterly", "Release-2026.4"] {
            let sem = DispatchSemaphore(value: 0); var verdict: Bool?
            Task { @MainActor in verdict = await SmartClassifier.looksSecret(sample); sem.signal() }
            while sem.wait(timeout: .now()) == .timedOut { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
            print("INFO model verdict for \(sample):", verdict.map { $0 ? "secret" : "ordinary" } ?? "no answer")
        }
    }
    // sounds: the synthesized WAV is valid and plays when enabled
    let wav = SoundFeedback.wav(freqs: [660, 880])
    check("sound is a well-formed WAV", wav.prefix(4) == Data("RIFF".utf8) && wav.count > 44 && (try? AVAudioPlayer(data: wav)) != nil)
    let snd = SoundFeedback(); check("sounds silent when disabled", !snd.play(.copy)); snd.enabled = true
    check("sounds play when enabled", snd.play(.paste))
    // OSD and screen-share privacy
    let osd = OSD(); osd.show("Selftest", symbol: "checkmark"); check("OSD shows", osd.isShowing && osd.lastText == "Selftest")
    let probe = NSPanel(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
    probe.sharingType = .none; check("window can be hidden from sharing", probe.sharingType == .none)
    let h1 = HotkeyCenter(id: 1), h2 = HotkeyCenter(id: 2)
    check("two hotkeys register side by side", h1.register(Hotkey(keyCode: 9, modifiers: Hotkey.cmd | Hotkey.option | Hotkey.control)) && h2.register(Hotkey(keyCode: 8, modifiers: Hotkey.cmd | Hotkey.option | Hotkey.control)))
    h1.unregister(); h2.unregister()
    print("INFO iCloud container entitlement present:", CloudKitTransport.available)
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

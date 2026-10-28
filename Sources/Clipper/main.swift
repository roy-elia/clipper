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
    static let clientsURL = App.support.appendingPathComponent("mcp-clients.json")
    let mcpClients = MCPClients(url: App.clientsURL)
    lazy var clientsModel = ClientsModel(mcpClients)
    var editorWindow: NSWindow?
    var importWindow: NSWindow?
    var lastShelfApp: String?
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
    var lastOtherApp: NSRunningApplication?
    var pause = CapturePause()
    var shortcutsWindow: NSWindow?
    var activity: NSUserActivity?
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
        let timed = NSMenu()
        for (i, d) in CapturePause.durations.enumerated() {
            let it = timed.addItem(withTitle: "For \(d.0)", action: #selector(pauseFor(_:)), keyEquivalent: ""); it.target = self; it.tag = i
        }
        menu.addItem(withTitle: "Pause For", action: nil, keyEquivalent: "").submenu = timed
        grantItem = menu.addItem(withTitle: "Allow Pasting (Accessibility)…", action: #selector(grant), keyEquivalent: "")
        grantItem?.target = self
        menu.delegate = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Getting Started…", action: #selector(showGettingStarted), keyEquivalent: "").target = self
        menu.addItem(withTitle: "About Clipper", action: #selector(showAbout), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusMenu = menu
        statusItem?.isVisible = model.settings.showMenuBarIcon
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
            statusItem?.isVisible = model.settings.showMenuBarIcon
            monitor.secretPolicy = model.settings.secretPolicy
            monitor.rules = makeRules()
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
            if PasteInjector.verbose, let l = store.all.first { PasteInjector.diag("capture: \(l.kind.rawValue) from \(l.sourceBundleID ?? "?") \(l.isSecret ? "secret" : "\(l.title.count) chars")") }
            fetchLinkTitleForLatest()
            advertiseHandoff()
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
            MainActor.assumeIsolated { self?.purgeSecrets(); self?.purgeExpired(); if let s = self, s.pause.active, !s.pause.isPaused() { s.resume() } }
        }
        installPanelShortcuts()
        monitor.rules = makeRules()
        sounds.enabled = model.settings.playSounds
        stackHotkeys.onFire = { [weak self] in self?.pasteNext() }
        stackHotkeys.register(model.settings.stackHotkey)
        model.onShare = { [weak self] item in self?.share(item) }
        model.onCopy = { [weak self] item in self?.copyOnly(item) }
        model.onEdit = { [weak self] item in self?.openEditor(item) }
        model.onWritingTools = { [weak self] item in
            guard let self else { return }
            openEditor(item)
            // Apple's Writing Tools work on the focused editor (macOS 15.2+).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { NSApp.sendAction(Selector(("showWritingTools:")), to: nil, from: nil) }
        }
        model.onPickMany = { [weak self] items, plain in self?.pickMany(items, plain: plain) }
        model.onDeleted = { [weak self] n in
            guard let self else { return }
            osd.show(n == 1 ? "Deleted. ⌘Z to undo" : "Deleted \(n) clips. ⌘Z to undo", symbol: "trash", hideFromSharing: model.settings.hideFromSharing)
        }
        model.onSyncNow = { [weak self] in self?.syncNow() }
        model.onOpen = { [weak self] item, app in self?.openTarget(item, with: app) }
        model.onReveal = { [weak self] item in
            guard let u = ShelfView.target(of: item) else { return }
            self?.panel?.orderOut(nil); NSWorkspace.shared.activateFileViewerSelecting([u])
        }
        model.onCopyPlain = { [weak self] item in self?.copyOnly(item, plain: true) }
        model.onEditBoard = { [weak self] name in self?.editBoard(name) }
        model.confirmPin = { [weak self] n, board in self?.confirm("Pin \(n) clips to \(board)?", button: "Pin") ?? true }
        migrateMCPToken()
        model.onRename = { [weak self] item in self?.renameClip(item) }
        model.onRenameBoard = { [weak self] name in self?.renameBoard(name) }
        model.onCommand = { [weak self] c in self?.run(c) }
        installModifierWatch()
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let pid = app?.processIdentifier
            MainActor.assumeIsolated {
                guard let pid, pid != ProcessInfo.processInfo.processIdentifier else { return }
                self?.lastOtherApp = NSRunningApplication(processIdentifier: pid)
            }
        }
        lastOtherApp = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : $0 }
        syncState = (try? Data(contentsOf: App.syncStateURL)).flatMap { try? JSONDecoder().decode(SyncState.self, from: $0) } ?? SyncState()
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.syncNow() } }
        DispatchQueue.main.async { [weak self] in self?.offerMoveToApplications(); self?.showFirstRunWindows() }
        monitor.start()
        applySpotlight()
        PasteInjector.diag("launch: pid \(ProcessInfo.processInfo.processIdentifier) trusted=\(PasteInjector.trusted) postEventAccess=\(CGPreflightPostEventAccess())")
    }

    /// takesKeyboard is false for the Paste Stack, which must leave the keyboard with the app being pasted into.
    func window(_ title: String, _ view: some View, id: String, takesKeyboard: Bool = true) -> NSWindow {
        let w: NSWindow = takesKeyboard
            ? KeyWindow(contentRect: .zero, styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            : NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentViewController = NSHostingController(rootView: view)
        w.title = title; w.isReleasedWhenClosed = false
        w.setFrameAutosaveName(id); w.center(); return w
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            settingsWindow = window("Clipper Settings", SettingsView(model: model, accessibilityTrusted: PasteInjector.trusted, clients: clientsModel, modelNote: SmartClassifier.isAvailable ? " On-device model: available." : " On-device model: not available on this Mac, rules only.", onGrant: { [weak self] in self?.grant() }), id: "settings")
            // The sidebar runs to the top of the window, under the traffic lights.
            settingsWindow?.styleMask.insert(.fullSizeContentView)
            settingsWindow?.titlebarAppearsTransparent = true
            settingsWindow?.toolbarStyle = .unified
        }
        bringClipperForward(); settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func showStack() {
        if stackWindow == nil {
            stackWindow = window("Paste Stack", StackView(model: model, onPasteNext: { [weak self] in self?.pasteNext() }), id: "stack", takesKeyboard: false)
            stackWindow?.level = .floating
        }
        stackWindow?.makeKeyAndOrderFront(nil)
    }

    /// Pops the oldest stacked clip and pastes it; the stack window never takes focus from the target app.
    func pasteNext() {
        // An empty stack opens the Paste Stack window so it can be filled; otherwise paste the next item.
        guard let item = model.stack.pop() else { showStack(); return }
        osd.show("Pasting \(item.isSecret ? "a secret" : String(item.title.prefix(24)))  ·  \(model.stack.items.count) left", symbol: "square.stack.3d.up", hideFromSharing: model.settings.hideFromSharing)
        pick(item, plain: false)
    }

    func preview(_ item: ClipItem, edit: Bool = false) {
        if previewPanel == nil {
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 320),
                               styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.title = "Preview"; previewPanel = p
        }
        previewPanel?.contentView = NSHostingView(rootView: PreviewView(item: item, onSave: { [weak self] text in
            guard let self else { return }
            if let updated = store.updateText(item.id, to: text) { model.refresh(); preview(updated) }
        }, startEditing: edit))
        applyPrivacy()
        previewPanel?.center(); previewPanel?.makeKeyAndOrderFront(nil)
    }

    /// ⌘1–9 paste, ⌘Y preview, ⌘⌫ delete. A local monitor is used because a non-activating panel never gets
    /// the key-equivalent pass that normal windows do.
    var quickFlag: NSEvent.ModifierFlags {
        switch model.settings.quickModifier { case .command: .command; case .option: .option; case .control: .control }
    }

    func makeRules() -> CaptureRules {
        var r = CaptureRules(ignoredBundleIDs: Set(model.settings.ignoredBundleIDs))
        r.ignoreConfidential = model.settings.ignoreConfidential; r.ignoreTransient = model.settings.ignoreTransient
        return r
    }

    /// Holding the quick-paste modifier shows the 1…9 badges; key status decides the selection ring's colour.
    func installModifierWatch() {
        NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] e in
            guard let self else { return e }
            let held = e.modifierFlags.intersection([.command, .option, .control, .shift]) == quickFlag
            if model.modifierHeld != held { model.modifierHeld = held }
            return e
        }
        for (n, key) in [(NSWindow.didBecomeKeyNotification, true), (NSWindow.didResignKeyNotification, false)] {
            NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] note in
                let win = ObjectIdentifier(note.object as AnyObject)
                MainActor.assumeIsolated {
                    guard let self, let p = self.panel, ObjectIdentifier(p) == win else { return }
                    self.model.isKey = key; if !key { self.model.modifierHeld = false }
                }
            }
        }
    }

    func confirm(_ title: String, info: String = "", button: String) -> Bool {
        confirming = true; defer { confirming = false }
        bringClipperForward()
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        return runAlert(a) == .alertFirstButtonReturn
    }

    /// 1 for the first button, 2 for the second.
    func ask3(_ title: String, info: String, first: String, second: String) -> Int {
        confirming = true; defer { confirming = false }
        bringClipperForward()
        let a = NSAlert(); a.messageText = title; a.informativeText = info
        a.addButton(withTitle: first); a.addButton(withTitle: second)
        return runAlert(a) == .alertFirstButtonReturn ? 1 : 2
    }

    func openTarget(_ item: ClipItem, with app: URL?) {
        guard let u = ShelfView.target(of: item) else { return }
        panel?.orderOut(nil); store.markUsed(item.id)
        if let app { NSWorkspace.shared.open([u], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) }
        else { NSWorkspace.shared.open(u) }
    }

    /// Edit Pinboard: name and colour in one dialog.
    func editBoard(_ name: String) {
        confirming = true; defer { confirming = false }
        bringClipperForward()
        let a = NSAlert(); a.messageText = "Edit Pinboard"
        let box = NSStackView(frame: NSRect(x: 0, y: 0, width: 260, height: 56)); box.orientation = .vertical; box.alignment = .leading
        let field = NSTextField(string: name); field.frame.size.width = 260
        let pop = NSPopUpButton()
        let names = ["Red", "Orange", "Yellow", "Green", "Teal", "Blue", "Purple", "Pink"]
        for (i, hex) in HistoryStore.boardPalette.enumerated() {
            pop.addItem(withTitle: names[i])
            let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { r in (NSColor(Color(hex: hex) ?? .gray)).setFill(); NSBezierPath(ovalIn: r).fill(); return true }
            pop.lastItem?.image = dot
        }
        pop.selectItem(at: HistoryStore.boardPalette.firstIndex(of: store.boardColor(name)) ?? 0)
        box.addArrangedSubview(field); box.addArrangedSubview(pop)
        field.widthAnchor.constraint(equalToConstant: 260).isActive = true
        a.accessoryView = box; a.addButton(withTitle: "Save"); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = field
        guard runAlert(a) == .alertFirstButtonReturn else { return }
        store.setBoardColor(name, HistoryStore.boardPalette[pop.indexOfSelectedItem])
        let new = field.stringValue.trimmingCharacters(in: .whitespaces)
        if !new.isEmpty, new != name { model.renameBoard(name, new) } else { model.refresh() }
    }

    /// Closing the shelf normally hands focus back to the app the user came from. When the shelf closes to open one
    /// of Clipper's own windows, that hand-back would win and the window would open behind it, with typing going
    /// to the other app, so skip it.
    func hideShelfForOwnWindow() {
        (panel as? ShelfPanel)?.previousApp = nil; panel?.orderOut(nil)
    }

    func openEditor(_ item: ClipItem) {
        hideShelfForOwnWindow()
        guard !item.isSecret, item.fileURLs == nil else { preview(item); return }
        let close: () -> Void = { [weak self] in self?.editorWindow?.close(); self?.editorWindow = nil }
        let view = ClipEditorView(item: item, autosave: model.settings.editorAutosave,
                                  onAutosaveChanged: { [weak self] v in self?.model.updateSettings { $0.editorAutosave = v }; if let w = self?.editorWindow, let i = self?.store.item(item.id) { _ = w; self?.openEditor(i) } },
                                  onSave: { [weak self] e in self?.store.replaceContent(item.id, text: e.text, data: e.data, extras: e.extras); self?.model.refresh() },
                                  onClose: close)
        if editorWindow == nil {
            let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false; editorWindow = w
        }
        editorWindow?.title = view.title
        editorWindow?.contentView = NSHostingView(rootView: view)
        applyPrivacy()
        editorWindow?.center(); bringClipperForward(); editorWindow?.makeKeyAndOrderFront(nil)
    }

    /// Run from Downloads or a disk image, offer once to move into ~/Applications (no admin password needed).
    func offerMoveToApplications() {
        let path = Bundle.main.bundlePath
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path
        guard path.hasSuffix(".app"), !path.hasPrefix("/Applications/"), !path.hasPrefix(home + "/"), !model.settings.askedMoveToApplications else { return }
        model.updateSettings { $0.askedMoveToApplications = true }
        guard confirm("Move Clipper to your Applications folder?", info: "Clipper is running from \((path as NSString).deletingLastPathComponent). Moving it keeps your Downloads folder uncluttered and lets it open at login.", button: "Move to Applications") else { return }
        let dest = URL(fileURLWithPath: home).appendingPathComponent("Clipper.app")
        do {
            try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.trashItem(at: dest, resultingItemURL: nil) }
            try FileManager.default.moveItem(atPath: path, toPath: dest.path)
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/open"); p.arguments = ["-n", dest.path]
            try p.run(); NSApp.terminate(nil)
        } catch {
            let a = NSAlert(); a.messageText = "Could not move to Applications folder"; a.informativeText = error.localizedDescription; _ = runAlert(a)
        }
    }

    /// Import from iPhone: Continuity Camera (Take Photo, Scan Documents) into a new clip.
    func showImport() {
        if importWindow == nil {
            let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 200), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            w.title = "Import from iPhone"; w.isReleasedWhenClosed = false
            let v = ContinuityImportView(frame: w.contentRect(forFrameRect: w.frame))
            v.onImage = { [weak self] data in
                guard let self else { return }
                let snap = PasteboardSnapshot(types: ["public.png"], data: data, sourceBundleID: Bundle.main.bundleIdentifier)
                if let item = monitor.rules.makeItem(from: snap) { store.add(item); model.refresh() }
                importWindow?.close()
                osd.show("Added from iPhone", symbol: "iphone", hideFromSharing: model.settings.hideFromSharing)
            }
            w.contentView = v; importWindow = w
        }
        importWindow?.center(); bringClipperForward(); importWindow?.makeKeyAndOrderFront(nil)
        importWindow?.makeFirstResponder(importWindow?.contentView)
    }

    /// Several cards at once: their text, one per line, pasted (or copied) as one clip.
    func pickMany(_ items: [ClipItem], plain: Bool) {
        let text = ClipItem.joinedText(items)
        guard !text.isEmpty else { if let f = items.first { pick(f, plain: plain) }; return }
        let combined = ClipItem(kind: .text, title: String(text.prefix(120)), text: text, checksum: CaptureRules.checksum(string: text, data: nil))
        model.marked = []
        pick(combined, plain: true)
    }

    /// Copy without pasting: the clip goes on the clipboard and the shelf closes.
    func copyOnly(_ item: ClipItem, plain: Bool = false) {
        store.markUsed(item.id)
        monitor.write(item, plain: plain || model.settings.alwaysPlain)
        panel?.orderOut(nil)
        osd.show(item.isSecret ? "Secret copied" : "Copied", symbol: "doc.on.clipboard", hideFromSharing: model.settings.hideFromSharing)
    }

    func ask(_ title: String, value: String, button: String) -> String? {
        confirming = true; defer { confirming = false }
        bringClipperForward()
        let a = NSAlert(); a.messageText = title
        let f = NSTextField(string: value); f.frame = NSRect(x: 0, y: 0, width: 260, height: 24); f.placeholderString = "Name"
        a.accessoryView = f; a.addButton(withTitle: button); a.addButton(withTitle: "Cancel")
        a.window.initialFirstResponder = f
        return runAlert(a) == .alertFirstButtonReturn ? f.stringValue : nil
    }

    func renameClip(_ item: ClipItem) {
        guard let name = ask("Rename Clip", value: item.customTitle ?? "", button: "Rename") else { return }
        store.rename(item.id, to: name); model.refresh()
    }

    func renameBoard(_ old: String) {
        guard let name = ask("Rename Pinboard", value: old, button: "Rename") else { return }
        model.renameBoard(old, name)
    }

    func run(_ c: ShelfCommand) {
        switch c {
        case .about: hideShelfForOwnWindow(); showAbout()
        case .newClip: hideShelfForOwnWindow(); showNewClip()
        case .settings: hideShelfForOwnWindow(); showSettings()
        case .gettingStarted: hideShelfForOwnWindow(); showGettingStarted()
        case .shortcuts: hideShelfForOwnWindow(); showShortcuts()
        case .pause(let d): setPause(d)
        case .resume: resume()
        case .clear: confirmClear()
        case .quit: NSApp.terminate(nil)
        case .importFromDevice: hideShelfForOwnWindow(); showImport()
        case .startDiagnostics:
            PasteInjector.verbose = true; model.diagnosing = true
            PasteInjector.diag("diagnostics started: version \(App.version) build \(App.build), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
            osd.show("Diagnostics started", symbol: "stethoscope", hideFromSharing: model.settings.hideFromSharing)
        case .stopDiagnostics:
            PasteInjector.verbose = false; model.diagnosing = false
            let log = (try? String(contentsOf: PasteInjector.logURL, encoding: .utf8)) ?? ""
            copyWithoutSaving(String(log.suffix(200_000)))
            osd.show("Logs copied. Paste them into your report.", symbol: "doc.on.clipboard", hideFromSharing: model.settings.hideFromSharing)
        }
    }

    /// Pauses capture until resumed or for a fixed time; a timer resumes it when the time is up.
    func setPause(_ duration: TimeInterval?) {
        pause = CapturePause(active: true, until: duration.map { Date().addingTimeInterval($0) })
        applyPause()
        let f = DateFormatter(); f.timeStyle = .short
        osd.show(pause.until.map { "Capture paused until \(f.string(from: $0))" } ?? "Capture paused", symbol: "pause.circle", hideFromSharing: model.settings.hideFromSharing)
    }

    func resume() {
        pause = CapturePause(); applyPause()
        osd.show("Capture resumed", symbol: "play.circle", hideFromSharing: model.settings.hideFromSharing)
    }

    func applyPause() {
        monitor.paused = pause.isPaused()
        let f = DateFormatter(); f.timeStyle = .short
        model.pausedUntil = monitor.paused ? (pause.until.map { "until \(f.string(from: $0))" } ?? "paused") : nil
        pauseItem?.title = monitor.paused ? "Resume Capture" : "Pause Capture"
        statusLine?.title = monitor.paused ? "Paused" + (pause.until.map { " until \(f.string(from: $0))" } ?? "") : "Capturing"
    }

    func showShortcuts() {
        if shortcutsWindow == nil {
            let w = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 420), styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: false)
            w.title = "Keyboard Shortcuts"; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: ShortcutsView(settings: model.settings))
            shortcutsWindow = w
        }
        shortcutsWindow?.contentView = NSHostingView(rootView: ShortcutsView(settings: model.settings))
        shortcutsWindow?.center(); bringClipperForward(); shortcutsWindow?.makeKeyAndOrderFront(nil)
    }

    func installPanelShortcuts() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard let self, let panel, panel.isVisible, e.window === panel else { return e }
            // While a new pinboard is being named, Return and Esc belong to that field. SwiftUI can hand the
            // field's Return to the search field's submit action, which would paste the selected clip.
            if model.namingBoard {
                if e.keyCode == 36 || e.keyCode == 76 { model.finishNamingBoard?(true); return nil }
                if e.keyCode == 53 { model.finishNamingBoard?(false); return nil }
                return e
            }
            let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
            // ⇧Return pastes as plain text; the text field would otherwise turn it into a line break.
            if mods == .shift, e.keyCode == 36 || e.keyCode == 76 { model.pickTargets(plain: true); return nil }
            if mods.isEmpty, e.keyCode == 36 || e.keyCode == 76 { model.pickTargets(plain: false); return nil }
            if mods.isEmpty, e.keyCode == 53, !model.marked.isEmpty { model.marked = []; return nil }
            // Space previews the selected clip while the search field is empty.
            if mods.isEmpty, e.keyCode == 49, model.query.isEmpty, let i = model.selected { model.onPreview?(i); return nil }
            if mods == quickFlag, let c = e.charactersIgnoringModifiers, let n = Int(c), (1...9).contains(n) { model.pick(number: n); return nil }
            // ⌫ deletes the selected clip while the search field is empty; ⌘Z puts it back.
            if mods.isEmpty, e.keyCode == 51 || e.keyCode == 117, model.query.isEmpty, let i = model.selected {
                _ = i; model.deleteTargets(); return nil
            }
            if mods == .command, e.charactersIgnoringModifiers == "z", model.query.isEmpty, model.lastDeleted != nil {
                model.undoDelete(); osd.show("Restored", symbol: "arrow.uturn.backward", hideFromSharing: model.settings.hideFromSharing); return nil
            }
            if mods == .command, e.keyCode == 123 { model.cycleBoard(-1); return nil }
            if mods == .command, e.keyCode == 124 { model.cycleBoard(1); return nil }
            guard mods == .command else { return e }
            if e.keyCode == 51 { model.deleteTargets(); return nil }
            if let c = e.charactersIgnoringModifiers {
                if c == "c", model.query.isEmpty || panel.firstResponder as? NSTextView == nil, let i = model.selected { copyOnly(i); return nil }
                if c == "e", let i = model.selected { openEditor(i); return nil }
                if c == "f" { model.focusTick += 1; model.searchTick += 1; return nil }
                if c == "g", let i = model.selected, let b = i.pinboard { model.picks = false; model.board = b; model.refresh(); return nil }
                if c == "a", model.query.isEmpty { model.marked = model.items.map(\.id); return nil }
                if c == "r", let i = model.selected { renameClip(i); return nil }
                if c == "y", let i = model.selected { model.onPreview?(i); return nil }
                if c == "]" { model.cycleBoard(1); return nil }
                if c == "[" { model.cycleBoard(-1); return nil }
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

    /// Applies the "keep history" setting: unpinned clips older than the chosen span are deleted.
    func purgeExpired() {
        guard let age = model.settings.retention.seconds else { return }
        if store.purge(olderThan: age) > 0 { model.refresh() }
    }

    /// Opt-in: reads the page title of a newly copied public link so its card can show it.
    func fetchLinkTitleForLatest() {
        guard model.settings.linkPreviews, let item = store.all.first, item.kind == .link, !item.isSecret,
              item.extras?["linkTitle"] == nil, let text = item.text, let url = LinkPreview.fetchable(text) else { return }
        let cfg = URLSessionConfiguration.ephemeral; cfg.timeoutIntervalForRequest = 6; cfg.httpCookieStorage = nil
        var req = URLRequest(url: url); req.setValue("text/html", forHTTPHeaderField: "Accept")
        let id = item.id
        URLSession(configuration: cfg).dataTask(with: req) { data, resp, _ in
            guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                  let html = String(data: data.prefix(200_000), encoding: .utf8) ?? String(data: data.prefix(200_000), encoding: .isoLatin1),
                  let title = LinkPreview.title(fromHTML: html) else { return }
            let image = LinkPreview.imageURL(fromHTML: html, base: url).flatMap { LinkPreview.fetchable($0.absoluteString) }
            Task { @MainActor in self.store.setLinkTitle(id, title); self.model.refresh() }
            guard let image else { return }
            URLSession(configuration: cfg).dataTask(with: image) { d, r, _ in
                guard let d, d.count < 5_000_000, (r as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: d),
                      let small = LinkPreview.thumbnailJPEG(img) else { return }
                Task { @MainActor in self.store.setLinkImage(id, small); self.model.refresh() }
            }.resume()
        }.resume()
    }

    /// Handoff: the newest non-secret text clip is offered to other devices signed in to the same iCloud account.
    func advertiseHandoff() {
        guard let item = store.all.first(where: { !$0.isSecret }), let text = item.text, item.kind == .text || item.kind == .link else { return }
        let a = NSUserActivity(activityType: "com.royelia.clipper.activity")
        a.title = "Latest clip"; a.isEligibleForHandoff = true
        a.userInfo = ["text": String(text.prefix(2000))]
        a.becomeCurrent(); activity?.invalidate(); activity = a
    }

    func application(_ application: NSApplication, continue userActivity: NSUserActivity, restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void) -> Bool {
        guard userActivity.activityType == "com.royelia.clipper.activity", let text = userActivity.userInfo?["text"] as? String else { return false }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
        osd.show("Clip received from another device", symbol: "arrow.down.circle", hideFromSharing: model.settings.hideFromSharing)
        return true
    }

    /// Opening Clipper again (Spotlight, Finder) shows the shelf, which is the way in when the menu bar icon is hidden.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if panel?.isVisible != true { toggle() }
        return true
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
        syncing = true; model.syncing = true
        let transport = CloudKitTransport(); let store = store; var state = syncState
        Task.detached {
            do { let r = try await SyncCoordinator.sync(store, state: &state, transport: transport); PasteInjector.diag("sync: pushed \(r.pushed) pulled \(r.pulled)") }
            catch { PasteInjector.diag("sync failed: \(error.localizedDescription)") }
            let done = state
            await MainActor.run {
                self.syncState = done; self.syncing = false; self.model.syncing = false; self.model.lastSynced = Date()
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
            bringClipperForward(); whatsNewWindow?.makeKeyAndOrderFront(nil)
        }
    }

    func presentOnboarding() {
        do {
            onboardingWindow = window("Welcome", OnboardingView(hotkey: model.settings.hotkey, onGrant: { [weak self] in self?.grant() }, onFinish: { [weak self] in
                guard let self else { return }
                model.updateSettings { $0.onboarded = true; $0.lastSeenVersion = App.version }
                onboardingWindow?.close(); onboardingWindow = nil
            }), id: "onboarding")
            bringClipperForward(); onboardingWindow?.makeKeyAndOrderFront(nil)
        }
    }

    /// The permission item only shows while pasting is not allowed yet.
    func menuNeedsUpdate(_ menu: NSMenu) { grantItem?.isHidden = PasteInjector.trusted }

    @objc func showGettingStarted() {
        presentOnboarding()
    }

    @objc func showAbout() {
        if aboutWindow == nil { aboutWindow = window("About Clipper", AboutView(version: App.version, build: App.build), id: "about") }
        bringClipperForward(); aboutWindow?.makeKeyAndOrderFront(nil)
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
        bringClipperForward(); newClipWindow?.makeKeyAndOrderFront(nil)
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
        if model.settings.pasteTarget == .clipboard { copyOnly(item, plain: plain); return }
        // The first paste without Accessibility access asks once: allow it, or switch to copy-only.
        if !PasteInjector.trusted && !model.settings.askedDirectPaste {
            model.updateSettings { $0.askedDirectPaste = true }
            let app = (panel as? ShelfPanel)?.previousApp?.localizedName ?? "the front app"
            let choice = ask3("Do you want to paste directly to \(app)?", info: "Clipper needs Accessibility access to paste for you. Without it, picked clips go to the clipboard and you paste with ⌘V.",
                              first: "Allow Access", second: "Not Now, Copy to Clipboard")
            if choice == 1 { grant() } else { model.updateSettings { $0.pasteTarget = .clipboard }; copyOnly(item, plain: plain); return }
        }
        store.markUsed(item.id)
        monitor.write(item, plain: plain || model.settings.alwaysPlain)
        sounds.play(.paste)
        panel?.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            let ok = PasteInjector.pasteNow()
            PasteInjector.diag("pasted plain=\(plain) ok=\(ok) frontmost=\(front)")
            if !ok { PasteInjector.requestAccess() }
        }
    }

    /// The single token from earlier versions becomes the first connected tool, so existing setups keep working.
    /// The file is removed afterwards, so disconnecting that tool really revokes it instead of it coming back on
    /// the next launch.
    func migrateMCPToken() {
        guard let old = try? String(contentsOf: App.tokenURL, encoding: .utf8) else { return }
        if mcpClients.all.isEmpty, old.count == 64 { mcpClients.add("Existing connection", token: old); clientsModel.reload() }
        try? FileManager.default.removeItem(at: App.tokenURL)
    }

    /// Starts, restarts or stops the MCP server to match settings.
    func applyMCP() {
        let s = model.settings
        if let m = mcp, !s.mcpEnabled || m.port != s.mcpPort { m.stop(); mcp = nil }
        guard s.mcpEnabled, mcp == nil else { return }
        let clients = mcpClients
        let server = MCPServer(store: store, tokens: { clients.tokens }, onUse: { t in clients.touch(token: t); Task { @MainActor in self.clientsModel.reload() } }, port: s.mcpPort)
        server.onState = { NSLog("Clipper MCP \($0)") }
        do { try server.start(); mcp = server } catch { NSLog("Clipper MCP failed to start: \(error)") }
    }

    @objc func pauseFor(_ s: NSMenuItem) { setPause(CapturePause.durations[s.tag].1) }

    @objc func togglePause(_ s: NSMenuItem) {
        if monitor.paused { resume() } else { setPause(nil) }
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
        bringClipperForward()
        let a = NSAlert()
        a.messageText = "Clear all saved clips?"
        a.informativeText = "This deletes \(total) saved \(total == 1 ? "clip" : "clips") from Clipper and its synced copies. It cannot be undone."
        a.alertStyle = .warning
        a.addButton(withTitle: "Delete All")
        if pinned > 0 { a.addButton(withTitle: "Keep Pinned (\(pinned))") }
        a.addButton(withTitle: "Cancel")
        let r = runAlert(a)
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
            let p = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: ShelfView.height),
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
            // Opened from the menu bar or a link, Clipper is already in front: use the app that was before it.
            shelf.previousApp = front?.bundleIdentifier == Bundle.main.bundleIdentifier ? lastOtherApp : front
            model.targetApp = shelf.previousApp?.bundleIdentifier
        }
        let appChanged = model.targetApp != lastShelfApp
        lastShelfApp = model.targetApp
        model.picks = model.settings.opensOnPicks && (model.settings.suggestTrigger == .always || appChanged)
            && !PickRanker(log: model.log).rank(store.all, for: model.targetApp, limit: 1).isEmpty
        model.board = nil; model.selection = 0; model.query = ""
        model.refresh(); model.focusTick += 1
        // The shelf rises from the bottom edge of the screen the pointer is on, full width with a small margin.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        if let v = screen?.visibleFrame, let p = panel {
            let inset: CGFloat = 8, h: CGFloat = ShelfView.height
            let end = NSRect(x: v.minX + inset, y: v.minY + inset, width: v.width - inset * 2, height: h)
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            p.setFrame(reduce ? end : end.offsetBy(dx: 0, dy: -(h + inset)), display: false)
            p.alphaValue = reduce ? 0 : 1
            bringClipperForward(); p.makeKeyAndOrderFront(nil)
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
/// A window that takes the keyboard without making Clipper the active app. Clipper is a menu bar app and its
/// shelf never takes focus, so macOS refuses to activate it from a click there; an ordinary window would open
/// behind the app the user came from and their typing would go to that app.
final class KeyWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        hidesOnDeactivate = false; becomesKeyOnlyIfNeeded = false
    }
}

/// Clipper has no menu bar of its own to show, but the Edit and Format items still give text fields and the
/// editor their standard shortcuts (⌘X ⌘C ⌘V ⌘A ⌘Z ⌘B ⌘I ⌘U).
@MainActor func installEditMenu() {
    let main = NSMenu()
    let edit = NSMenu(title: "Edit")
    func add(_ m: NSMenu, _ t: String, _ sel: String, _ key: String, _ mods: NSEvent.ModifierFlags = .command) {
        let i = NSMenuItem(title: t, action: Selector(sel), keyEquivalent: key); i.keyEquivalentModifierMask = mods; m.addItem(i)
    }
    add(edit, "Undo", "undo:", "z"); add(edit, "Redo", "redo:", "z", [.command, .shift]); edit.addItem(.separator())
    add(edit, "Cut", "cut:", "x"); add(edit, "Copy", "copy:", "c"); add(edit, "Paste", "paste:", "v")
    add(edit, "Paste and Match Style", "pasteAsPlainText:", "v", [.command, .option, .shift]); add(edit, "Select All", "selectAll:", "a")
    let format = NSMenu(title: "Format")
    add(format, "Bold", "addFontTrait:", "b"); format.items.last?.tag = Int(NSFontTraitMask.boldFontMask.rawValue)
    add(format, "Italic", "addFontTrait:", "i"); format.items.last?.tag = Int(NSFontTraitMask.italicFontMask.rawValue)
    add(format, "Underline", "underline:", "u")
    for m in [NSMenu(title: "Clipper"), edit, format] { let i = NSMenuItem(); i.submenu = m; main.addItem(i) }
    NSApp.mainMenu = main
}

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
    let fixedToken = MCPServer.loadToken(at: URL(fileURLWithPath: CommandLine.arguments[i + 2]))
    let server = MCPServer(store: HistoryStore(), tokens: { [fixedToken] }, port: port)
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
installEditMenu()
app.run()

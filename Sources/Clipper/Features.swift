import AppKit
import SwiftUI
@preconcurrency import CoreSpotlight
import ServiceManagement
import DropCore

/// Launch at login through the system's login-item API (works for a signed app in ~/Applications).
enum LoginItem {
    static var enabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
        catch { PasteInjector.diag("login item \(on ? "register" : "unregister") failed: \(error.localizedDescription)") }
    }
}

/// Optional Spotlight index of clip text, so clips can be found from system search. Off unless enabled in Settings.
@MainActor
final class SpotlightIndexer {
    static let domain = "com.royelia.clipper.clips"
    func sync(_ items: [ClipItem]) {
        let idx = CSSearchableIndex.default()
        let searchable = items.prefix(500).compactMap { i -> CSSearchableItem? in
            guard i.kind != .image, let t = i.text else { return nil }
            let a = CSSearchableItemAttributeSet(contentType: .text)
            a.title = i.title; a.textContent = String(t.prefix(2000)); a.contentCreationDate = i.createdAt
            return CSSearchableItem(uniqueIdentifier: i.id.uuidString, domainIdentifier: Self.domain, attributeSet: a)
        }
        idx.deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in idx.indexSearchableItems(searchable) { _ in } }
    }
    func removeAll() { CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [Self.domain]) { _ in } }
}

struct NewClipView: View {
    @State private var text = ""
    @State private var board = ""
    let boards: [String]
    var onSave: (String, String?) -> Void
    var onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New Clip").font(.headline)
            TextEditor(text: $text).font(.body.monospaced()).scrollContentBackground(.hidden).padding(6).frame(minHeight: 140)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).accessibilityIdentifier("newclip.text")
            Picker("Pinboard", selection: $board) {
                Text("None").tag("")
                ForEach(boards, id: \.self) { Text($0).tag($0) }
            }.accessibilityIdentifier("newclip.board")
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Save") { onSave(text, board.isEmpty ? nil : board) }
                    .keyboardShortcut(.defaultAction).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("newclip.save")
            }
        }.padding(16).frame(width: 420, height: 280)
    }
}

/// Click, press a shortcut, done. Esc cancels. Needs ⌘, ⌃ or ⌥ so ordinary typing is never swallowed.
struct HotkeyRecorder: View {
    let current: Hotkey
    var onChange: (Hotkey) -> Void
    @State private var recording = false
    @State private var monitor: Any?
    @State private var rejected = false

    var body: some View {
        Button(recording ? "Press shortcut…" : current.display) { recording ? stop() : start() }
            .font(.body.monospaced()).accessibilityIdentifier("settings.hotkey")
            .overlay(alignment: .trailing) { if rejected { Text("Needs ⌘, ⌃ or ⌥").font(.caption).foregroundStyle(.red).offset(x: 120) } }
            .onDisappear(perform: stop)
    }

    func start() {
        recording = true; rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53 { stop(); return nil }   // Esc
            let hk = Hotkey(keyCode: UInt32(e.keyCode), modifiers: Self.carbon(e.modifierFlags))
            if hk.isValid { onChange(hk); stop() } else { rejected = true }
            return nil
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; recording = false
    }

    static func carbon(_ f: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if f.contains(.command) { m |= Hotkey.cmd }
        if f.contains(.shift) { m |= Hotkey.shift }
        if f.contains(.option) { m |= Hotkey.option }
        if f.contains(.control) { m |= Hotkey.control }
        return m
    }
}

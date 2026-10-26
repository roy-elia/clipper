import Testing
import Foundation
@testable import DropCore

@Suite struct PasteParityTests {
    func item(_ t: String) -> ClipItem { ClipItem(kind: .text, title: t, text: t, checksum: CaptureRules.checksum(string: t, data: nil)) }

    @Test func renameSetsAndClearsCustomTitle() {
        let s = HistoryStore(); let a = s.add(item("abc"))
        s.rename(a.id, to: "  Address  ")
        #expect(s.item(a.id)?.customTitle == "Address")
        s.rename(a.id, to: "")
        #expect(s.item(a.id)?.customTitle == nil)
    }

    @Test func pinboardColoursFollowRenameAndDelete() {
        let s = HistoryStore()
        #expect(s.createPinboard("A")); #expect(s.createPinboard("B"))
        #expect(s.boardColor("A") == HistoryStore.boardPalette[0])
        #expect(s.boardColor("B") == HistoryStore.boardPalette[1])
        s.setBoardColor("A", "#34C759")
        #expect(s.renamePinboard("A", to: "C"))
        #expect(s.boardColor("C") == "#34C759")
        s.deletePinboard("C")
        #expect(s.boardColor("C") == HistoryStore.boardPalette[0])
    }

    @Test func coloursAndTitlesSurviveReload() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-parity-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let s = HistoryStore(url: url); let a = s.add(item("x")); _ = s.createPinboard("Work"); s.setBoardColor("Work", "#AF52DE"); s.rename(a.id, to: "Named")
        let r = HistoryStore(url: url)
        #expect(r.boardColor("Work") == "#AF52DE" && r.item(a.id)?.customTitle == "Named")
    }

    @Test func confidentialAndTransientToggles() {
        var r = CaptureRules()
        let secret = PasteboardSnapshot(types: [CaptureRules.concealed, "public.utf8-plain-text"], string: "pw")
        let temp = PasteboardSnapshot(types: [CaptureRules.transient, "public.utf8-plain-text"], string: "tmp")
        #expect(!r.shouldCapture(secret) && !r.shouldCapture(temp))
        r.ignoreConfidential = false; r.ignoreTransient = false
        #expect(r.shouldCapture(secret) && r.shouldCapture(temp))
    }

    @Test func timedPause() {
        let now = Date()
        #expect(CapturePause(active: true, until: now.addingTimeInterval(900)).isPaused(at: now))
        #expect(!CapturePause(active: true, until: now.addingTimeInterval(-1)).isPaused(at: now))
        #expect(CapturePause(active: true).isPaused(at: now))
        #expect(!CapturePause().isPaused(at: now))
        #expect(CapturePause.durations.map(\.1) == [900, 1800, 3600, 10_800, 28_800])
    }

    @Test func settingsDefaultsMatchAndReset() throws {
        var s = AppSettings()
        #expect(s.pasteTarget == .activeApp && s.quickModifier == .command && s.ignoreConfidential && s.ignoreTransient)
        #expect(s.stackHotkey == Hotkey(keyCode: 8, modifiers: Hotkey.cmd | Hotkey.shift))
        s.stackHotkey = Hotkey(keyCode: 9, modifiers: Hotkey.cmd | Hotkey.control); s.quickModifier = .option
        s.resetShortcuts()
        #expect(s.stackHotkey == AppSettings().stackHotkey && s.quickModifier == .command)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"playSounds":true}"#.utf8))
        #expect(old.pasteTarget == .activeApp && old.playSounds)
    }
}

import Testing
import Foundation
@testable import DropCore

@Suite struct ShortcutTests {
    func clip(_ kind: ClipKind, _ c: String, pin: String? = nil) -> ClipItem {
        ClipItem(kind: kind, title: c, text: kind == .text ? c : nil, data: kind == .image ? Data([1]) : nil, checksum: c, pinboard: pin)
    }

    @Test func newestAndPreviousFollowCopyOrder() {
        let s = HistoryStore(url: nil)
        #expect(s.newest == nil && s.previous == nil)
        _ = s.add(clip(.text, "first")); #expect(s.newest?.checksum == "first" && s.previous == nil)
        _ = s.add(clip(.text, "second"))
        #expect(s.newest?.checksum == "second" && s.previous?.checksum == "first")
    }

    @Test func deleteImagesKeepsPinnedAndOtherKinds() {
        let s = HistoryStore(url: nil)
        _ = s.add(clip(.image, "a")); _ = s.add(clip(.image, "b", pin: "Work")); _ = s.add(clip(.text, "c"))
        #expect(s.deleteImages().map(\.checksum) == ["a"])
        #expect(Set(s.all.map(\.checksum)) == ["b", "c"])
    }

    @Test func typeFilterDigitsFollowTheFilterOrder() {
        #expect((1...5).map { ClipKind.forFilterDigit($0) } == [.text, .link, .image, .file, .color])
        #expect(ClipKind.forFilterDigit(0) == nil && ClipKind.forFilterDigit(6) == nil)
    }

    @Test func newGlobalShortcutsAreDistinctAndMigrate() throws {
        let d = AppSettings()
        let all = [d.hotkey, d.stackHotkey, d.screenshotsHotkey, d.deleteLastHotkey, d.pauseHotkey, d.plainPasteHotkey, d.previousClipHotkey]
        #expect(Set(all).count == all.count)
        #expect([d.deleteLastHotkey, d.pauseHotkey, d.plainPasteHotkey, d.previousClipHotkey].map(\.display) == ["⌃⌥⌘Z", "⌃⌥⌘P", "⌃⌥⌘V", "⌃⌥⌘B"])
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.pauseHotkey == d.pauseHotkey && old.previousClipHotkey == d.previousClipHotkey)
        var s = d; s.pauseHotkey = Hotkey(keyCode: 1, modifiers: Hotkey.cmd | Hotkey.option); s.resetShortcuts()
        #expect(s.pauseHotkey == d.pauseHotkey)
    }
}

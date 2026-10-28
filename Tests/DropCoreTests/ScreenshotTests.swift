import Testing
import Foundation
@testable import DropCore

@Suite struct ScreenshotTests {
    func img(_ app: String?, _ c: String) -> ClipItem { ClipItem(kind: .image, title: "image", data: Data([1]), sourceBundleID: app, checksum: c) }
    func file(_ path: String, _ c: String) -> ClipItem { ClipItem(kind: .file, title: "file", sourceBundleID: "com.apple.finder", checksum: c, fileURLs: [path]) }

    @Test func recognisesScreenshotsFromToolsAndFileNames() {
        #expect(img("com.apple.screencaptureui", "a").isScreenshot)
        #expect(img("cc.ffitch.shottr", "b").isScreenshot)
        #expect(img("pl.maketheweb.cleanshotx", "c").isScreenshot)
        #expect(img("com.TechSmith.Snagit2024", "d").isScreenshot)
        #expect(file("file:///Users/r/Desktop/Screenshot%202026-10-28%20at%2015.01.02.png", "e").isScreenshot)
        #expect(file("/Users/r/Desktop/CleanShot 2026-10-28 at 15.01.02@2x.png", "f").isScreenshot)
    }

    @Test func leavesOtherImagesAndFilesAlone() {
        #expect(!img("com.google.Chrome", "a").isScreenshot)
        #expect(!img(nil, "b").isScreenshot)
        #expect(!file("/Users/r/Desktop/Screenshot notes.txt", "c").isScreenshot)
        #expect(!file("/Users/r/Pictures/holiday.png", "d").isScreenshot)
        #expect(!ClipItem(kind: .text, title: "t", text: "Screenshot 1.png", sourceBundleID: "cc.ffitch.shottr", checksum: "e").isScreenshot)
    }

    @Test func deleteScreenshotsKeepsPinnedAndOtherClips() {
        let s = HistoryStore(url: nil)
        _ = s.add(img("cc.ffitch.shottr", "1"))
        var pinned = img("com.apple.screencaptureui", "2"); pinned.pinboard = "Work"; _ = s.add(pinned)
        _ = s.add(img("com.google.Chrome", "3"))
        _ = s.add(ClipItem(kind: .text, title: "t", text: "hi", checksum: "4"))
        let removed = s.deleteScreenshots()
        #expect(removed.map(\.checksum) == ["1"])
        #expect(Set(s.all.map(\.checksum)) == ["2", "3", "4"])
        for r in removed { s.restore(r) }
        #expect(s.all.count == 4)
    }

    @Test func clearScreenshotsShortcutDefaultsAndMigrates() throws {
        let d = AppSettings()
        #expect(d.screenshotsHotkey.display == "⌃⌥⌘⌫")
        #expect(d.screenshotsHotkey != d.hotkey && d.screenshotsHotkey != d.stackHotkey)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        #expect(old.screenshotsHotkey == d.screenshotsHotkey)
        var s = d; s.screenshotsHotkey = Hotkey(keyCode: 1, modifiers: Hotkey.cmd | Hotkey.option); s.resetShortcuts()
        #expect(s.screenshotsHotkey == d.screenshotsHotkey)
    }
}

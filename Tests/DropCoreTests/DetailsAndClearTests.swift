import Testing
import Foundation
import AppKit
@testable import DropCore

@Suite struct DetailsAndClearTests {
    let rules = CaptureRules()
    func text(_ s: String) -> ClipItem { rules.makeItem(from: .init(types: [], string: s))! }

    @Test func textDetails() {
        #expect(text("hello world").detail == "11 characters")
        #expect(text("x").detail == "1 character")
        let multi = text("one two\nthree")
        #expect(multi.wordCount == 3 && multi.lineCount == 2)
        #expect(multi.moreDetails == ["13 characters", "3 words", "2 lines"])
    }

    @Test func linkColorAndSecretDetails() {
        #expect(text("https://developer.apple.com/documentation").detail == "developer.apple.com")
        #expect(text("#3478f6").detail == "#3478F6")
        #expect(text("ghp_16C7e42F292c6912E7710c838347Ae178B4a").detail == "Hidden")
    }

    @Test func imageDetailsUsePixelSize() throws {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 120, pixelsHigh: 80, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        let png = try #require(rep.representation(using: .png, properties: [:]))
        let item = ClipItem(kind: .image, title: "image", data: png, checksum: "i")
        #expect(item.detail == "120 × 80")
        #expect(ClipItem(kind: .image, title: "i", data: Data(count: 2048), checksum: "j").detail.contains("KB"))
    }

    @Test func fileDetailsCountFilesAndSize() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-detail-\(UUID()).txt")
        try Data(count: 4096).write(to: url); defer { try? FileManager.default.removeItem(at: url) }
        let one = try #require(rules.makeItem(from: .init(types: ["public.file-url"], fileURLs: [url.absoluteString])))
        #expect(one.detail.hasPrefix("1 file"))
        let two = try #require(rules.makeItem(from: .init(types: ["public.file-url"], fileURLs: ["file:///nope/a", "file:///nope/b"])))
        #expect(two.detail == "2 files")
    }

    @Test func clearRemovesEverythingOrKeepsPinned() {
        let st = HistoryStore()
        let a = st.add(text("a")); st.add(text("b")); st.add(text("c"))
        st.setPinboard("Keep", for: a.id)
        #expect(st.clear(keepPinned: true) == 2)
        #expect(st.all.map(\.title) == ["a"])
        #expect(st.clear(keepPinned: false) == 1 && st.all.isEmpty)
        #expect(st.clear(keepPinned: false) == 0)
    }

    @Test func clearedClipsSyncAsDeletions() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(), b = HistoryStore()
        var sa = SyncState(), sb = SyncState()
        a.add(text("one")); a.add(text("two"))
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        #expect(b.all.count == 2)
        a.clear(keepPinned: false)
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        #expect(b.all.isEmpty)
    }
}

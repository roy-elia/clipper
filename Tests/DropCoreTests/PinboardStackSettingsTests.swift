import Testing
import Foundation
@testable import DropCore

@Suite struct PinboardStackSettingsTests {
    func item(_ s: String) -> ClipItem { CaptureRules().makeItem(from: .init(types: [], string: s))! }

    @Test func pinboardLifecycle() {
        let st = HistoryStore()
        #expect(st.createPinboard("Work"))
        #expect(!st.createPinboard("Work"))
        #expect(!st.createPinboard("  "))
        let a = st.add(item("a")); st.setPinboard("Work", for: a.id)
        #expect(st.renamePinboard("Work", to: "Office"))
        #expect(st.pinboards() == ["Office"])
        #expect(st.search(pinboard: "Office").count == 1)
        #expect(!st.renamePinboard("Nope", to: "X"))
        st.deletePinboard("Office")
        #expect(st.pinboards().isEmpty)
        #expect(st.all.count == 1 && st.all[0].pinboard == nil)
    }

    @Test func emptyBoardsPersist() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let st = HistoryStore(url: url); st.createPinboard("Ideas")
        #expect(HistoryStore(url: url).pinboards() == ["Ideas"])
    }

    @Test func stackIsFirstInFirstOut() {
        var s = PasteStack()
        let a = item("a"), b = item("b"), c = item("c")
        s.push(a); s.push(b); s.push(c)
        s.move(from: 2, to: 0)
        #expect(s.pop()?.title == "c")
        s.remove(b.id)
        #expect(s.pop()?.title == "a")
        #expect(s.pop() == nil && s.isEmpty)
    }

    @Test func settingsClampAndRoundTrip() {
        var s = AppSettings(); s.setCapacity(5); #expect(s.historyCapacity == 50)
        s.setCapacity(99_999); #expect(s.historyCapacity == 10_000)
        s.playSounds = true
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-set-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        s.save(url)
        #expect(AppSettings.load(url) == s)
        #expect(AppSettings.load(URL(fileURLWithPath: "/nonexistent/x.json")) == AppSettings())
    }

    @Test func oldSettingsFileStillLoads() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-old-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"historyCapacity": 300, "playSounds": true}"#.utf8).write(to: url)
        let s = AppSettings.load(url)
        #expect(s.historyCapacity == 300 && s.playSounds && !s.mcpEnabled && s.mcpPort == 47821)
    }
}

import Testing
import Foundation
@testable import DropCore

@Suite struct ParityTests {
    func item(_ t: String, age: TimeInterval = 0) -> ClipItem {
        ClipItem(kind: .text, title: t, text: t, checksum: CaptureRules.checksum(string: t, data: nil), createdAt: Date().addingTimeInterval(-age))
    }

    @Test func purgeKeepsPinnedAndRecent() {
        let s = HistoryStore()
        s.add(item("old", age: 40 * 86_400)); let pinned = s.add(item("oldpinned", age: 40 * 86_400)); s.add(item("new"))
        s.createPinboard("Work"); s.setPinboard("Work", for: pinned.id)
        #expect(s.purge(olderThan: Retention.month.seconds!) == 1)
        #expect(Set(s.all.map(\.title)) == ["oldpinned", "new"])
        #expect(Retention.forever.seconds == nil)
    }

    @Test func duplicateIsIndependent() {
        let s = HistoryStore(); let a = s.add(item("hello"))
        let d = s.duplicate(a.id)
        #expect(d != nil && d!.id != a.id)
        #expect(s.all.count == 2 && s.all[0].text == "hello" && s.all[1].text == "hello")
        s.add(item("hello"))
        #expect(s.all.count == 2)
    }

    @Test func settingsMigrateWithNewKeys() throws {
        let old = #"{"historyCapacity":200}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: old)
        #expect(s.historyCapacity == 200 && s.alwaysPlain == false && s.showMenuBarIcon && s.retention == .forever && s.linkPreviews == false)
    }

    @Test func linkTitleParsing() {
        #expect(LinkPreview.title(fromHTML: "<html><head><title> Hi &amp; bye </title></head>") == "Hi & bye")
        #expect(LinkPreview.title(fromHTML: #"<meta property="og:title" content="OG Title"><title>Other</title>"#) == "OG Title")
        #expect(LinkPreview.title(fromHTML: "<p>none</p>") == nil)
    }

    @Test func onlyPublicLinksAreFetched() {
        #expect(LinkPreview.fetchable("https://example.com/a") != nil)
        for bad in ["http://localhost:3000", "http://127.0.0.1/x", "http://192.168.1.2", "http://172.20.0.1", "file:///etc/passwd", "javascript:alert(1)", "not a url", "http://printer.local"] {
            #expect(LinkPreview.fetchable(bad) == nil, "\(bad)")
        }
    }

    @Test func linkTitleStored() {
        let s = HistoryStore(); let a = s.add(item("https://example.com"))
        s.setLinkTitle(a.id, "Example")
        #expect(s.item(a.id)?.extras?["linkTitle"].flatMap { String(data: $0, encoding: .utf8) } == "Example")
    }
}

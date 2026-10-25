import Testing
import Foundation
@testable import DropCore

@Suite struct HistoryStoreTests {
    func item(_ s: String) -> ClipItem {
        CaptureRules().makeItem(from: .init(types: [], string: s))!
    }

    @Test func testDuplicateMovesToTopAndKeepsID() {
        let st = HistoryStore()
        let a = st.add(item("a")); _ = st.add(item("b"))
        let again = st.add(item("a"))
        #expect(st.all.map(\.title) == ["a", "b"])
        #expect(again.id == a.id)
    }

    @Test func testCapacityTrimsOldestButKeepsPinned() {
        let st = HistoryStore(capacity: 2)
        let first = st.add(item("1")); st.setPinboard("Keep", for: first.id)
        for s in ["2", "3", "4"] { st.add(item(s)) }
        #expect(Set(st.all.map(\.title)) == ["1", "4", "3"])
    }

    @Test func testSearchFilters() {
        let st = HistoryStore()
        st.add(item("Hello World")); st.add(item("https://a.com")); st.add(item("zzz"))
        #expect(st.search("hello").count == 1)
        #expect(st.search(kind: .link).count == 1)
        #expect(st.search("nope").count == 0)
    }

    @Test func testPersistenceRoundTrip() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let st = HistoryStore(url: url); st.add(item("keep me"))
        #expect(HistoryStore(url: url).all.map(\.title) == ["keep me"])
    }
}

import Testing
import Foundation
@testable import DropCore

@Suite struct CaptureRulesTests {
    let rules = CaptureRules()

    @Test func testCanary() { #expect(1 + 1 == 2) }

    @Test func testConcealedAndIgnoredAppsAreSkipped() {
        #expect(!(rules.shouldCapture(.init(types: [CaptureRules.concealed], string: "hunter2"))))
        #expect(!(rules.shouldCapture(.init(types: [CaptureRules.transient], string: "x"))))
        #expect(!(rules.shouldCapture(.init(types: [], string: "x", sourceBundleID: "com.apple.Passwords"))))
        #expect(rules.shouldCapture(.init(types: ["public.utf8-plain-text"], string: "hello")))
    }

    @Test func testOversizedAndEmptyAreSkipped() {
        let big = Data(count: 21_000_000)
        #expect(!(rules.shouldCapture(.init(types: ["public.png"], data: big))))
        #expect(!(rules.shouldCapture(.init(types: [], string: ""))))
    }

    @Test func testKinds() {
        #expect(rules.kind(of: .init(types: [], string: "https://example.com/a?b=1")) == .link)
        #expect(rules.kind(of: .init(types: [], string: "see https://example.com")) == .text)
        #expect(rules.kind(of: .init(types: [], string: "#1a2B3c")) == .color)
        #expect(rules.kind(of: .init(types: ["public.png"], data: Data([1]))) == .image)
        #expect(rules.kind(of: .init(types: ["public.file-url"], string: "file:///a")) == .file)
    }

    @Test func testChecksumStableAndTitleIsFirstLine() throws {
        let a = try #require(rules.makeItem(from: .init(types: [], string: "line one\nline two")))
        let b = try #require(rules.makeItem(from: .init(types: [], string: "line one\nline two")))
        #expect(a.checksum == b.checksum)
        #expect(a.title == "line one")
    }
}

@Suite struct RichAndFileCaptureTests {
    let rules = CaptureRules()

    @Test func richTextKeepsFormattingButDedupesByPlainText() throws {
        let a = try #require(rules.makeItem(from: .init(types: ["public.rtf"], string: "Hello", extras: ["public.rtf": Data([1, 2])])))
        let b = try #require(rules.makeItem(from: .init(types: [], string: "Hello")))
        #expect(a.isRich && !b.isRich)
        #expect(a.checksum == b.checksum)
        #expect(a.plainText == "Hello")
    }

    @Test func oversizedExtrasAreDropped() throws {
        let a = try #require(rules.makeItem(from: .init(types: [], string: "x", extras: ["public.html": Data(count: 3_000_000)])))
        #expect(!a.isRich)
    }

    @Test func fileClipsKeepURLsAndShowNames() throws {
        let item = try #require(rules.makeItem(from: .init(types: ["public.file-url"], fileURLs: ["file:///tmp/a.pdf", "file:///tmp/b%20c.txt"])))
        #expect(item.kind == .file)
        #expect(item.title == "a.pdf, b c.txt")
        #expect(item.text == "/tmp/a.pdf\n/tmp/b c.txt")
        #expect(item.fileNames == ["a.pdf", "b c.txt"])
    }

    @Test func oldHistoryWithoutNewFieldsStillLoads() throws {
        let json = #"[{"id":"7E1D3B2E-0000-4000-8000-000000000001","kind":"text","title":"t","text":"t","checksum":"c","createdAt":"2026-10-25T00:00:00Z"}]"#
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-old-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(json.utf8).write(to: url)
        #expect(HistoryStore(url: url).all.count == 1)
    }

    @Test func appsAreRankedByUse() {
        let st = HistoryStore()
        for (i, app) in ["a", "b", "b", "c", "b", "a"].enumerated() {
            st.add(rules.makeItem(from: .init(types: [], string: "item\(i)", sourceBundleID: app))!)
        }
        #expect(st.apps() == ["b", "a", "c"])
    }
}


@Suite struct CustomIgnoreTests {
    @Test func userAddedAppsAreIgnoredAndRemovedOnesAreNot() {
        let rules = CaptureRules(ignoredBundleIDs: ["com.example.bank"])
        #expect(!rules.shouldCapture(.init(types: [], string: "balance", sourceBundleID: "com.example.bank")))
        #expect(rules.shouldCapture(.init(types: [], string: "balance", sourceBundleID: "com.apple.Passwords")))   // list replaced, not merged
    }
}

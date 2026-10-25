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

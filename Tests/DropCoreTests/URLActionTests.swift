import Testing
import Foundation
@testable import DropCore

@Suite struct URLActionTests {
    func parse(_ s: String) -> URLAction? { URL(string: s).flatMap(URLAction.parse) }
    @Test func knownActions() {
        #expect(parse("clipper://show") == .show)
        #expect(parse("clipper://stack") == .stack)
        #expect(parse("clipper://new") == .new)
        #expect(parse("clipper://settings") == .settings)
        #expect(parse("clipper://collect") == .collect && parse("clipper://pause") == .pause && parse("clipper://about") == .about)
    }
    @Test func searchCarriesQuery() {
        #expect(parse("clipper://search?q=hello%20world") == .search("hello world"))
        #expect(parse("clipper://search") == .search(""))
    }
    @Test func unknownIsIgnored() {
        #expect(parse("clipper://nope") == nil)
        #expect(parse("https://example.com") == nil)
    }
}

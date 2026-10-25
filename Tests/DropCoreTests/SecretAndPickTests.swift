import Testing
import Foundation
@testable import DropCore

@Suite struct SecretDetectorTests {
    @Test func flagsKnownCredentialShapes() {
        #expect(SecretDetector.classify("-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----") == .privateKey)
        #expect(SecretDetector.classify("AKIAIOSFODNN7EXAMPLE") == .cloudKey)
        #expect(SecretDetector.classify("ghp_16C7e42F292c6912E7710c838347Ae178B4a") == .apiToken)
        #expect(SecretDetector.classify("sk-proj-abcdefghijklmnopqrstuvwxyz0123456789") == .apiToken)
        #expect(SecretDetector.classify("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dBjftJeZ4CVPmB92K27uhbUJU1p1r") == .jwt)
        #expect(SecretDetector.classify("password = hunter2hunter2") == .credentialAssignment)
        #expect(SecretDetector.classify("export API_KEY=abc123def456") == .credentialAssignment)
        #expect(SecretDetector.classify("4111 1111 1111 1111") == .creditCard)
    }

    @Test func leavesOrdinaryTextAlone() {
        #expect(SecretDetector.classify("Meeting at 3pm in the conference room") == nil)
        #expect(SecretDetector.classify("https://developer.apple.com/documentation/swiftui") == nil)
        #expect(SecretDetector.classify("4111 1111 1111 1112") == nil)        // fails Luhn
        #expect(SecretDetector.classify("The password policy requires 12 characters") == nil)
        #expect(SecretDetector.classify("/Users/me/Documents/some-long-file-name-here.txt") == nil)
        #expect(SecretDetector.classify("") == nil)
    }

    @Test func highEntropyTokenIsFlaggedButShortIdentifiersAreAmbiguousNotSecret() {
        #expect(SecretDetector.classify("xK9#mP2$vL8@nQ4!wR7&tY3*uI6^") == .highEntropy)
        #expect(SecretDetector.classify("Tr0ub4dor&3") == nil)
        #expect(SecretDetector.isAmbiguous("Tr0ub4dor&3"))
        #expect(!SecretDetector.isAmbiguous("hello world"))
        #expect(!SecretDetector.isAmbiguous("plainword"))
    }

    @Test func captureMarksSecretsOnTextAndLinksOnly() throws {
        let rules = CaptureRules()
        let secret = try #require(rules.makeItem(from: .init(types: [], string: "ghp_16C7e42F292c6912E7710c838347Ae178B4a")))
        #expect(secret.isSecret)
        let plain = try #require(rules.makeItem(from: .init(types: [], string: "buy milk")))
        #expect(!plain.isSecret && plain.sensitive == nil)
        let link = try #require(rules.makeItem(from: .init(types: [], string: "https://x.test/cb?token=abcdef123456")))
        #expect(link.kind == .link)
    }
}

@Suite struct PickRankerTests {
    func item(_ s: String, app: String? = nil, ageMin: Double = 0, now: Date) -> ClipItem {
        var i = CaptureRules().makeItem(from: .init(types: [], string: s, sourceBundleID: app), now: now.addingTimeInterval(-ageMin * 60))!
        i.id = UUID(); return i
    }

    @Test func secretsAreNeverSuggested() {
        let now = Date()
        var s = item("ghp_16C7e42F292c6912E7710c838347Ae178B4a", now: now); s.sensitive = true
        let ok = item("hello", now: now)
        #expect(PickRanker(log: PasteLog(), now: now).rank([s, ok], for: nil) == [ok])
    }

    @Test func recencyOrdersWhenThereIsNoHistory() {
        let now = Date()
        let old = item("old", ageMin: 600, now: now), new = item("new", ageMin: 1, now: now)
        #expect(PickRanker(log: PasteLog(), now: now).rank([old, new], for: "com.x").map(\.title) == ["new", "old"])
    }

    @Test func clipsPastedIntoThisAppBeforeRiseAbove() {
        let now = Date()
        let used = item("used here", ageMin: 120, now: now), fresh = item("fresh", ageMin: 10, now: now)
        var log = PasteLog(); log.record(.init(itemID: used.id, kind: .text, targetApp: "com.terminal", date: now))
        let r = PickRanker(log: log, now: now)
        #expect(r.rank([fresh, used], for: "com.terminal").first?.title == "used here")
        #expect(r.rank([fresh, used], for: "com.other").first?.title == "fresh")
    }

    @Test func whatYouJustCopiedLeads() {
        let now = Date()
        let used = item("used here", ageMin: 60, now: now), justCopied = item("just copied", ageMin: 0.2, now: now)
        var log = PasteLog(); log.record(.init(itemID: used.id, kind: .text, targetApp: "com.terminal", date: now))
        #expect(PickRanker(log: log, now: now).rank([used, justCopied], for: "com.terminal").first?.title == "just copied")
    }

    @Test func kindAffinityAndSourceAppBoost() {
        let now = Date()
        let link = item("https://a.com", ageMin: 5, now: now), text = item("note", ageMin: 5, now: now)
        var log = PasteLog()
        for _ in 0..<5 { log.record(.init(itemID: UUID(), kind: .link, targetApp: "com.browser", date: now)) }
        #expect(PickRanker(log: log, now: now).rank([text, link], for: "com.browser").first?.kind == .link)
        let fromApp = item("same app", app: "com.notes", ageMin: 5, now: now), other = item("other", app: "com.x", ageMin: 5, now: now)
        #expect(PickRanker(log: PasteLog(), now: now).rank([other, fromApp], for: "com.notes").first?.title == "same app")
    }

    @Test func pasteLogIsCappedAndRoundTrips() throws {
        var log = PasteLog()
        for _ in 0..<(PasteLog.cap + 20) { log.record(.init(itemID: UUID(), kind: .text, targetApp: "a")) }
        #expect(log.events.count == PasteLog.cap)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-log-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        log.save(url)
        // ISO-8601 drops sub-second precision, so compare what matters: the events and their order.
        #expect(PasteLog.load(url).events.map(\.itemID) == log.events.map(\.itemID))
    }
}

@Suite struct SecretHandlingTests {
    let token = "ghp_16C7e42F292c6912E7710c838347Ae178B4a"

    @Test func purgeRemovesOldUnpinnedSecretsOnly() {
        let st = HistoryStore(); let rules = CaptureRules(); let now = Date()
        let old = st.add(rules.makeItem(from: .init(types: [], string: token), now: now.addingTimeInterval(-600))!)
        let pinned = st.add(rules.makeItem(from: .init(types: [], string: token + "pinned"), now: now.addingTimeInterval(-600))!)
        st.setPinboard("Keep", for: pinned.id)
        st.add(rules.makeItem(from: .init(types: [], string: token + "new"), now: now)!)
        st.add(rules.makeItem(from: .init(types: [], string: "ordinary old note"), now: now.addingTimeInterval(-600))!)
        #expect(st.purgeSecrets(olderThan: 300, now: now) == 1)
        #expect(st.item(old.id) == nil && st.item(pinned.id) != nil && st.all.count == 3)
    }

    @Test func markSecretFlipsFlag() {
        let st = HistoryStore(); let i = st.add(CaptureRules().makeItem(from: .init(types: [], string: "Tr0ub4dor&3"))!)
        #expect(!i.isSecret)
        st.markSecret(i.id); #expect(st.item(i.id)?.isSecret == true)
        st.markSecret(i.id, false); #expect(st.item(i.id)?.isSecret == false)
    }

    @Test func mcpNeverRevealsSecrets() throws {
        let st = HistoryStore(); let h = MCPHandler(store: st)
        let i = st.add(CaptureRules().makeItem(from: .init(types: [], string: token))!)
        func call(_ name: String, _ args: [String: Any]) throws -> String {
            let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": ["name": name, "arguments": args]])
            return String(decoding: h.handle(body)!, as: UTF8.self)
        }
        let read = try call("read_item", ["id": i.id.uuidString])
        #expect(!read.contains(token) && read.contains("secret withheld"))
        let found = try call("search", ["query": "ghp_"])
        #expect(!found.contains(token) && found.contains("\\\"count\\\":0"))
    }

    @Test func oldSettingsGetSecretDefaults() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-s-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"playSounds": true}"#.utf8).write(to: url)
        let s = AppSettings.load(url)
        #expect(s.secretPolicy == .expire && s.secretMinutes == 5 && s.opensOnPicks && s.smartModel)
    }
}

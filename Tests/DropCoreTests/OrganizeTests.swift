import Testing
import Foundation
@testable import DropCore

@Suite struct OrganizeTests {
    @Test func dateRanges() {
        let cal = Calendar(identifier: .gregorian)
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 12))!
        let yesterday = now.addingTimeInterval(-86_400), tenDays = now.addingTimeInterval(-10 * 86_400)
        #expect(DateRange.today.contains(now, now: now, calendar: cal) && !DateRange.today.contains(yesterday, now: now, calendar: cal))
        #expect(DateRange.yesterday.contains(yesterday, now: now, calendar: cal))
        #expect(DateRange.week.contains(yesterday, now: now) && !DateRange.week.contains(tenDays, now: now))
        #expect(DateRange.month.contains(tenDays, now: now))
    }

    @Test func lastUsedAndUntitled() {
        let s = HistoryStore(); let a = s.add(ClipItem(kind: .text, title: "a", text: "a", checksum: "a"))
        #expect(s.item(a.id)?.lastUsed == nil)
        s.markUsed(a.id, at: Date(timeIntervalSince1970: 5))
        #expect(s.item(a.id)?.lastUsed == Date(timeIntervalSince1970: 5))
        #expect(s.freeBoardName() == "Untitled")
        _ = s.createPinboard("Untitled")
        #expect(s.freeBoardName() == "Untitled 2")
    }

    @Test func clientsAddTouchRemoveAndPersist() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-clients-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let c = MCPClients(url: url)
        let a = c.add("Claude Code"); let b = c.add("  ")
        #expect(a.token.count == 64 && a.token != b.token && b.name == "AI Tool")
        #expect(c.touch(token: a.token) == "Claude Code" && c.touch(token: "nope") == nil)
        c.remove(b.id)
        let r = MCPClients(url: url)
        #expect(r.all.map(\.name) == ["Claude Code"] && r.all[0].lastUsed != nil)
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(perms == 0o600)
    }

    @Test func gateAcceptsAnyClientTokenAndNamesIt() {
        func req(_ tok: String) -> HTTPRequest {
            HTTPRequest(method: "POST", path: "/mcp", headers: ["host": "127.0.0.1:47821", "authorization": "Bearer \(tok)"], body: Data())
        }
        let (ok, m) = HTTPGate.authorize(req("t2"), tokens: ["t1", "t2"], port: 47821)
        #expect(ok == .ok && m == "t2")
        let (bad, none) = HTTPGate.authorize(req("x"), tokens: ["t1"], port: 47821)
        #expect(bad == .status(401, "Invalid token") && none == nil)
        let (empty, _) = HTTPGate.authorize(req("x"), tokens: [], port: 47821)
        #expect(empty != .ok)
    }

    @Test func configHasBridgeUrlAndToken() {
        let j = MCPClients.config(name: "Claude Code", bridgePath: "/A/clipper-mcp-stdio", token: "abc", port: 47821)
        #expect(j.contains("\"clipper-claude-code\"") && j.contains("http://127.0.0.1:47821/mcp") && j.contains("\"MCP_TOKEN\": \"abc\""))
    }
}

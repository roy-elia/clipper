import Testing
import Foundation
@testable import DropCore

@Suite struct HTTPGateTests {
    func req(_ s: String) -> Data { Data(s.utf8) }
    let good = "POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:47821\r\nAuthorization: Bearer secret\r\nContent-Length: 2\r\n\r\n{}"

    @Test func parsesCompleteRequest() {
        guard case .request(let r) = HTTPGate.parse(req(good)) else { Issue.record("not parsed"); return }
        #expect(r.method == "POST" && r.path == "/mcp" && r.body == Data("{}".utf8))
        #expect(r.headers["authorization"] == "Bearer secret")
    }

    @Test func waitsForMoreBytes() {
        #expect(HTTPGate.parse(req("POST /mcp HTTP/1.1\r\nHost: x")) == .incomplete)
        #expect(HTTPGate.parse(req(String(good.dropLast()))) == .incomplete)
    }

    @Test func rejectsMalformedAndOversized() {
        #expect(HTTPGate.parse(req("garbage\r\n\r\n")) == .bad(status: 400))
        #expect(HTTPGate.parse(req("POST /mcp HTTP/1.1\r\nContent-Length: 99999999\r\n\r\n")) == .bad(status: 413))
        #expect(HTTPGate.parse(req("POST /mcp HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n")) == .bad(status: 501))
    }

    func authorize(_ s: String) -> HTTPGate.Verdict {
        guard case .request(let r) = HTTPGate.parse(req(s)) else { return .status(0, "unparsed") }
        return HTTPGate.authorize(r, token: "secret", port: 47821)
    }

    @Test func authRules() {
        #expect(authorize(good) == .ok)
        #expect(authorize(good.replacingOccurrences(of: "Bearer secret", with: "Bearer wrong")) == .status(401, "Invalid token"))
        #expect(authorize(good.replacingOccurrences(of: "Authorization: Bearer secret\r\n", with: "")) == .status(401, "Missing bearer token"))
        #expect(authorize(good.replacingOccurrences(of: "127.0.0.1:47821", with: "evil.example:47821")) == .status(403, "Forbidden host"))
        #expect(authorize(good.replacingOccurrences(of: "Content-Length", with: "Origin: https://evil.example\r\nContent-Length")) == .status(403, "Forbidden origin"))
        #expect(authorize(good.replacingOccurrences(of: "POST", with: "GET")) == .status(405, "Use POST"))
        #expect(authorize(good.replacingOccurrences(of: "/mcp", with: "/other")) == .status(404, "Not found"))
    }

    @Test func tokenIsRandomAndCompareIsExact() {
        #expect(HTTPGate.makeToken().count == 64 && HTTPGate.makeToken() != HTTPGate.makeToken())
        #expect(HTTPGate.constantTimeEqual("abc", "abc") && !HTTPGate.constantTimeEqual("abc", "abd") && !HTTPGate.constantTimeEqual("abc", "ab"))
    }
}

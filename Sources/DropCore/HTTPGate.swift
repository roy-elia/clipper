import Foundation
import Security

public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    public var headers: [String: String]   // lower-cased names
    public var body: Data
}

public enum HTTPParse: Sendable, Equatable {
    case incomplete
    case request(HTTPRequest)
    case bad(status: Int)
}

public enum HTTPGate {
    public static let maxBody = 1_000_000

    /// Parses one request from a receive buffer; `incomplete` means read more bytes.
    public static func parse(_ buf: Data) -> HTTPParse {
        guard let split = buf.range(of: Data("\r\n\r\n".utf8)) else { return buf.count > 16_384 ? .bad(status: 431) : .incomplete }
        let head = String(decoding: buf[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let parts = head[0].split(separator: " ")
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else { return .bad(status: 400) }
        var headers: [String: String] = [:]
        for l in head.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { return .bad(status: 400) }
            headers[l[..<c].lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        if headers["transfer-encoding"] != nil { return .bad(status: 501) }
        let len = headers["content-length"].flatMap { Int($0) } ?? 0
        if len < 0 { return .bad(status: 400) }
        if len > maxBody { return .bad(status: 413) }
        let bodyStart = split.upperBound
        guard buf.count - bodyStart >= len else { return .incomplete }
        return .request(HTTPRequest(method: String(parts[0]), path: String(parts[1]), headers: headers,
                                    body: buf.subdata(in: bodyStart..<(bodyStart + len))))
    }

    public enum Verdict: Sendable, Equatable { case ok, status(Int, String) }

    /// Auth and DNS-rebinding checks, in the order they should fail.
    public static func authorize(_ r: HTTPRequest, token: String, port: UInt16) -> Verdict {
        let allowedHosts: Set<String> = ["127.0.0.1:\(port)", "localhost:\(port)", "[::1]:\(port)"]
        guard let host = r.headers["host"], allowedHosts.contains(host.lowercased()) else { return .status(403, "Forbidden host") }
        if let origin = r.headers["origin"], !isLoopbackOrigin(origin) { return .status(403, "Forbidden origin") }
        guard let auth = r.headers["authorization"], auth.hasPrefix("Bearer ") else { return .status(401, "Missing bearer token") }
        guard constantTimeEqual(String(auth.dropFirst(7)), token) else { return .status(401, "Invalid token") }
        guard r.path == "/mcp" else { return .status(404, "Not found") }
        guard r.method == "POST" else { return .status(405, "Use POST") }
        return .ok
    }

    static func isLoopbackOrigin(_ o: String) -> Bool {
        guard let u = URL(string: o), let h = u.host else { return false }
        return ["127.0.0.1", "localhost", "::1"].contains(h)
    }

    public static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) { diff |= Int(i < x.count ? x[i] : 0) ^ Int(i < y.count ? y[i] : 0) }
        return diff == 0
    }

    public static func response(status: Int, reason: String, body: Data = Data(), json: Bool = false) -> Data {
        var h = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        if json { h += "Content-Type: application/json\r\n" }
        if status == 401 { h += "WWW-Authenticate: Bearer\r\n" }
        if status == 405 { h += "Allow: POST\r\n" }
        return Data(h.utf8) + Data("\r\n".utf8) + body
    }

    public static func makeToken() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }
}

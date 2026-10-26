import Foundation

/// Reads a page title out of HTML: Open Graph first, then the <title> element.
public enum LinkPreview {
    public static func title(fromHTML html: String) -> String? {
        let head = String(html.prefix(200_000))
        if let t = capture(#"<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#, in: head)
            ?? capture(#"<meta[^>]+content=["']([^"']+)["'][^>]+property=["']og:title["']"#, in: head)
            ?? capture(#"<title[^>]*>([^<]+)</title>"#, in: head) {
            let clean = decode(t).trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            return clean.isEmpty ? nil : String(clean.prefix(160))
        }
        return nil
    }

    /// Only plain http(s) links to public hosts are fetched, never loopback or private addresses.
    public static func fetchable(_ text: String) -> URL? {
        guard let u = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)), ["http", "https"].contains(u.scheme?.lowercased()),
              let host = u.host?.lowercased(), !host.isEmpty, host != "localhost", !host.hasSuffix(".local"), !host.hasSuffix(".internal") else { return nil }
        if host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") || host.hasPrefix("169.254.") || host == "::1" || host.hasPrefix("[") { return nil }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }), (16...31).contains(second) { return nil }
        return u
    }

    static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func decode(_ s: String) -> String {
        s.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
         .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

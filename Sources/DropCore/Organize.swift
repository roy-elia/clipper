import Foundation

/// The Date section of the filter popover.
public enum DateRange: String, CaseIterable, Sendable {
    case today, yesterday, week, month
    public var label: String {
        switch self { case .today: "Today"; case .yesterday: "Yesterday"; case .week: "Last 7 Days"; case .month: "Last 30 Days" }
    }
    public func contains(_ d: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        switch self {
        case .today: return calendar.isDate(d, inSameDayAs: now)
        case .yesterday: return calendar.date(byAdding: .day, value: -1, to: now).map { calendar.isDate(d, inSameDayAs: $0) } ?? false
        case .week: return d <= now && now.timeIntervalSince(d) < 7 * 86_400
        case .month: return d <= now && now.timeIntervalSince(d) < 30 * 86_400
        }
    }
}

/// One AI tool allowed to use Clipper's MCP server, with its own token so it can be disconnected alone.
public struct MCPClient: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var token: String
    public var created: Date
    public var lastUsed: Date?
}

/// The AI tools list behind Settings ▸ AI tools. Stored owner-only next to the history.
public final class MCPClients: @unchecked Sendable {
    let lock = NSLock()
    private(set) var list: [MCPClient] = []
    private let url: URL?

    public init(url: URL? = nil) {
        self.url = url
        if let url, let d = try? Data(contentsOf: url), let l = try? JSONDecoder.iso.decode([MCPClient].self, from: d) { list = l }
    }

    public var all: [MCPClient] { lock.withLock { list } }
    public var tokens: Set<String> { lock.withLock { Set(list.map(\.token)) } }

    /// Adds a tool with a fresh random token; an existing single token can be brought in as `token`.
    @discardableResult
    public func add(_ name: String, token: String? = nil, now: Date = Date()) -> MCPClient {
        let n = name.trimmingCharacters(in: .whitespaces)
        let c = MCPClient(id: UUID(), name: n.isEmpty ? "AI Tool" : n, token: token ?? Self.newToken(), created: now, lastUsed: nil)
        lock.withLock { list.append(c); persist() }
        return c
    }

    public func remove(_ id: UUID) { lock.withLock { list.removeAll { $0.id == id }; persist() } }

    /// Records a successful request; returns the tool's name.
    @discardableResult
    public func touch(token: String, at date: Date = Date()) -> String? {
        lock.withLock {
            guard let i = list.firstIndex(where: { HTTPGate.constantTimeEqual($0.token, token) }) else { return nil }
            // Write at most once a minute so a busy tool does not hammer the disk.
            if list[i].lastUsed.map({ date.timeIntervalSince($0) > 60 }) ?? true { list[i].lastUsed = date; persist() }
            return list[i].name
        }
    }

    public static func newToken() -> String {
        var b = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// The JSON an MCP client config needs: the stdio bridge inside the app, with this tool's token.
    public static func config(name: String, bridgePath: String, token: String, port: UInt16) -> String {
        let key = name.lowercased().replacingOccurrences(of: " ", with: "-")
        return """
        {
          "mcpServers": {
            "clipper-\(key)": {
              "command": "\(bridgePath)",
              "env": { "MCP_URL": "http://127.0.0.1:\(port)/mcp", "MCP_TOKEN": "\(token)" }
            }
          }
        }
        """
    }

    func persist() {
        guard let url, let d = try? JSONEncoder.iso.encode(list) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

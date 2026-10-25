import Foundation

/// Transport-independent MCP server logic: JSON-RPC 2.0 over a HistoryStore.
/// Methods: initialize, ping, tools/list, tools/call; notifications get no reply.
public final class MCPHandler: @unchecked Sendable {
    public static let protocolVersion = "2025-06-18"
    let store: HistoryStore
    public init(store: HistoryStore) { self.store = store }

    typealias JSON = [String: Any]

    /// Returns the JSON response body, or nil when the message is a notification.
    public func handle(_ body: Data) -> Data? {
        guard let obj = try? JSONSerialization.jsonObject(with: body) else { return encode(error(nil, -32700, "Parse error")) }
        if let batch = obj as? [JSON] {
            let replies = batch.compactMap { respond(to: $0) }
            return replies.isEmpty ? nil : try? JSONSerialization.data(withJSONObject: replies)
        }
        guard let msg = obj as? JSON else { return encode(error(nil, -32600, "Invalid request")) }
        return respond(to: msg).flatMap(encode)
    }

    func respond(to msg: JSON) -> JSON? {
        let id = msg["id"]
        guard let method = msg["method"] as? String else { return id == nil ? nil : error(id, -32600, "Invalid request") }
        if id == nil { return nil } // notification
        switch method {
        case "initialize":
            return result(id, ["protocolVersion": Self.protocolVersion,
                               "capabilities": ["tools": ["listChanged": false]],
                               "serverInfo": ["name": "clipper", "version": "0.1.0"]])
        case "ping": return result(id, [:])
        case "tools/list": return result(id, ["tools": Self.tools])
        case "tools/call":
            let params = msg["params"] as? JSON ?? [:]
            guard let name = params["name"] as? String else { return error(id, -32602, "Missing tool name") }
            guard Self.tools.contains(where: { $0["name"] as? String == name }) else { return error(id, -32602, "Unknown tool: \(name)") }
            return result(id, call(name, params["arguments"] as? JSON ?? [:]))
        default: return error(id, -32601, "Method not found: \(method)")
        }
    }

    // MARK: tools

    static func tool(_ name: String, _ desc: String, _ props: JSON = [:], required: [String] = []) -> JSON {
        ["name": name, "description": desc, "inputSchema": ["type": "object", "properties": props, "required": required]]
    }
    nonisolated(unsafe) static let str: JSON = ["type": "string"]

    nonisolated(unsafe) public static let tools: [[String: Any]] = [
        tool("search", "Search clipboard history by text, with optional kind, pinboard and limit filters.",
             ["query": str, "kind": ["type": "string", "enum": ClipKind.allCases.map(\.rawValue)], "pinboard": str, "limit": ["type": "integer"]]),
        tool("read_item", "Read one clip in full by id.", ["id": str], required: ["id"]),
        tool("create_item", "Add a new text clip, optionally on a pinboard.", ["text": str, "pinboard": str], required: ["text"]),
        tool("update_item", "Replace the text of a text clip.", ["id": str, "text": str], required: ["id", "text"]),
        tool("delete_item", "Delete a clip from history.", ["id": str], required: ["id"]),
        tool("list_pinboards", "List pinboards with their clip counts."),
        tool("create_pinboard", "Create an empty pinboard.", ["name": str], required: ["name"]),
        tool("rename_pinboard", "Rename a pinboard.", ["name": str, "new_name": str], required: ["name", "new_name"]),
        tool("delete_pinboard", "Delete a pinboard; its clips stay in history, unpinned.", ["name": str], required: ["name"]),
        tool("add_item_to_pinboard", "Pin a clip to a pinboard (created if missing).", ["id": str, "pinboard": str], required: ["id", "pinboard"]),
        tool("remove_item_from_pinboard", "Unpin a clip from its pinboard.", ["id": str], required: ["id"]),
    ]

    func call(_ name: String, _ a: JSON) -> JSON {
        func text(_ s: String, error: Bool = false) -> JSON {
            ["content": [["type": "text", "text": s]], "isError": error]
        }
        func fail(_ s: String) -> JSON { text(s, error: true) }
        func id() -> UUID? { (a["id"] as? String).flatMap(UUID.init(uuidString:)) }
        func summary(_ i: ClipItem) -> JSON {
            var d: JSON = ["id": i.id.uuidString, "kind": i.kind.rawValue, "title": i.isSecret ? "[secret withheld]" : i.title,
                           "created_at": ISO8601DateFormatter().string(from: i.createdAt)]
            if let p = i.pinboard { d["pinboard"] = p }
            if let b = i.sourceBundleID { d["source_app"] = b }
            return d
        }
        func json(_ o: Any) -> JSON {
            let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys])) ?? Data()
            return text(String(decoding: d, as: UTF8.self))
        }

        switch name {
        case "search":
            let kind = (a["kind"] as? String).flatMap(ClipKind.init(rawValue:))
            if a["kind"] != nil && kind == nil { return fail("Unknown kind") }
            let limit = min(max((a["limit"] as? Int) ?? 20, 1), 100)
            // Secrets never leave the app through MCP, not even as search hits.
            let hits = store.search(a["query"] as? String ?? "", kind: kind, pinboard: a["pinboard"] as? String).filter { !$0.isSecret }
            return json(["count": hits.count, "items": hits.prefix(limit).map(summary)])
        case "read_item":
            guard let i = id().flatMap(store.item) else { return fail("No clip with that id") }
            var d = summary(i); if i.isSecret { d["text"] = "[secret withheld]" } else if let t = i.text { d["text"] = t } else { d["text"] = NSNull() }; d["has_binary_data"] = i.data != nil
            return json(d)
        case "create_item":
            guard let t = a["text"] as? String, !t.isEmpty else { return fail("text is required") }
            guard var item = CaptureRules().makeItem(from: .init(types: [], string: t, sourceBundleID: "mcp")) else { return fail("Rejected") }
            if let b = a["pinboard"] as? String, !b.isEmpty { item.pinboard = b }
            return json(summary(store.add(item)))
        case "update_item":
            guard let i = id(), let t = a["text"] as? String else { return fail("id and text are required") }
            guard let u = store.updateText(i, to: t) else { return fail("No editable text clip with that id") }
            return json(summary(u))
        case "delete_item":
            guard let i = id(), store.item(i) != nil else { return fail("No clip with that id") }
            store.delete(i); return text("Deleted")
        case "list_pinboards":
            return json(["pinboards": store.pinboards().map { ["name": $0, "count": store.search(pinboard: $0).count] as JSON }])
        case "create_pinboard":
            guard let n = a["name"] as? String else { return fail("name is required") }
            return store.createPinboard(n) ? text("Created") : fail("Name is empty or already exists")
        case "rename_pinboard":
            guard let o = a["name"] as? String, let n = a["new_name"] as? String else { return fail("name and new_name are required") }
            return store.renamePinboard(o, to: n) ? text("Renamed") : fail("Unknown pinboard, or the new name is empty or taken")
        case "delete_pinboard":
            guard let n = a["name"] as? String, store.pinboards().contains(n) else { return fail("Unknown pinboard") }
            store.deletePinboard(n); return text("Deleted")
        case "add_item_to_pinboard":
            guard let i = id(), store.item(i) != nil, let b = (a["pinboard"] as? String)?.trimmingCharacters(in: .whitespaces), !b.isEmpty
            else { return fail("A valid id and pinboard are required") }
            store.setPinboard(b, for: i); return text("Pinned")
        case "remove_item_from_pinboard":
            guard let i = id(), store.item(i) != nil else { return fail("No clip with that id") }
            store.setPinboard(nil, for: i); return text("Unpinned")
        default: return fail("Unknown tool")
        }
    }

    // MARK: JSON-RPC plumbing

    func result(_ id: Any?, _ r: JSON) -> JSON { ["jsonrpc": "2.0", "id": id ?? NSNull(), "result": r] }
    func error(_ id: Any?, _ code: Int, _ message: String) -> JSON {
        ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]]
    }
    func encode(_ o: JSON) -> Data? { try? JSONSerialization.data(withJSONObject: o) }
}

import Testing
import Foundation
@testable import DropCore

@Suite struct MCPHandlerTests {
    func rpc(_ h: MCPHandler, _ method: String, _ params: [String: Any]? = nil, id: Any? = 1) -> [String: Any]? {
        var m: [String: Any] = ["jsonrpc": "2.0", "method": method]
        if let id { m["id"] = id }
        if let params { m["params"] = params }
        let data = try! JSONSerialization.data(withJSONObject: m)
        return h.handle(data).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
    func callTool(_ h: MCPHandler, _ name: String, _ args: [String: Any] = [:]) -> (text: String, isError: Bool) {
        let r = rpc(h, "tools/call", ["name": name, "arguments": args])!["result"] as! [String: Any]
        let t = ((r["content"] as! [[String: Any]])[0]["text"] as! String)
        return (t, r["isError"] as? Bool ?? false)
    }
    func idOf(_ text: String) -> String { (try! JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any])["id"] as! String }

    @Test func initializeAndToolList() {
        let h = MCPHandler(store: HistoryStore())
        let r = rpc(h, "initialize")!["result"] as! [String: Any]
        #expect(r["protocolVersion"] as? String == MCPHandler.protocolVersion)
        let tools = (rpc(h, "tools/list")!["result"] as! [String: Any])["tools"] as! [[String: Any]]
        #expect(tools.count == 11)
        #expect(Set(tools.compactMap { $0["name"] as? String }).count == 11)
    }

    @Test func notificationsGetNoReply() {
        #expect(rpc(MCPHandler(store: HistoryStore()), "notifications/initialized", id: nil) == nil)
    }

    @Test func errorsAreJSONRPC() {
        let h = MCPHandler(store: HistoryStore())
        #expect((rpc(h, "nope")!["error"] as! [String: Any])["code"] as? Int == -32601)
        #expect((rpc(h, "tools/call", ["name": "zzz"])!["error"] as! [String: Any])["code"] as? Int == -32602)
        let bad = h.handle(Data("{not json".utf8))!
        #expect(((try! JSONSerialization.jsonObject(with: bad) as! [String: Any])["error"] as! [String: Any])["code"] as? Int == -32700)
    }

    @Test func createReadUpdateSearchDelete() {
        let h = MCPHandler(store: HistoryStore())
        let created = callTool(h, "create_item", ["text": "remember the milk"])
        #expect(!created.isError)
        let id = idOf(created.text)
        #expect(callTool(h, "read_item", ["id": id]).text.contains("remember the milk"))
        #expect(callTool(h, "update_item", ["id": id, "text": "buy oat milk"]).isError == false)
        #expect(callTool(h, "search", ["query": "oat"]).text.contains("\"count\":1"))
        #expect(callTool(h, "search", ["query": "milk", "kind": "image"]).text.contains("\"count\":0"))
        #expect(callTool(h, "search", ["kind": "bogus"]).isError)
        #expect(!callTool(h, "delete_item", ["id": id]).isError)
        #expect(callTool(h, "read_item", ["id": id]).isError)
        #expect(callTool(h, "read_item", ["id": "not-a-uuid"]).isError)
    }

    @Test func pinboardTools() {
        let h = MCPHandler(store: HistoryStore())
        let id = idOf(callTool(h, "create_item", ["text": "x"]).text)
        #expect(!callTool(h, "create_pinboard", ["name": "Work"]).isError)
        #expect(callTool(h, "create_pinboard", ["name": "Work"]).isError)
        #expect(!callTool(h, "add_item_to_pinboard", ["id": id, "pinboard": "Work"]).isError)
        #expect(callTool(h, "list_pinboards").text.contains("\"count\":1"))
        #expect(!callTool(h, "rename_pinboard", ["name": "Work", "new_name": "Office"]).isError)
        #expect(callTool(h, "search", ["pinboard": "Office"]).text.contains("\"count\":1"))
        #expect(!callTool(h, "remove_item_from_pinboard", ["id": id]).isError)
        #expect(!callTool(h, "delete_pinboard", ["name": "Office"]).isError)
        #expect(callTool(h, "delete_pinboard", ["name": "Office"]).isError)
    }
}

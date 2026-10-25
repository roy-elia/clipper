import Foundation

// Bridges stdio MCP clients to Clipper's local HTTP endpoint.
// Env: MCP_URL (e.g. http://127.0.0.1:47821/mcp), MCP_TOKEN (shown in Clipper settings).
func fail(_ m: String) -> Never { FileHandle.standardError.write(Data("clipper-mcp-stdio: \(m)\n".utf8)); exit(1) }

let env = ProcessInfo.processInfo.environment
guard let urlString = env["MCP_URL"], !urlString.isEmpty else { fail("MCP_URL environment variable is required") }
guard let token = env["MCP_TOKEN"], !token.isEmpty else { fail("MCP_TOKEN environment variable is required") }
guard let url = URL(string: urlString), ["http", "https"].contains(url.scheme ?? "") else { fail("MCP_URL must be an http or https URL") }

let out = FileHandle.standardOutput
func write(_ d: Data) { out.write(d + Data("\n".utf8)) }

func rpcError(_ id: Any?, _ message: String) -> Data {
    (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": -32000, "message": message]])) ?? Data()
}

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    if trimmed.isEmpty { continue }
    let body = Data(trimmed.utf8)
    let id = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["id"]
    var req = URLRequest(url: url, timeoutInterval: 30)
    req.httpMethod = "POST"; req.httpBody = body
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, resp, err in
        defer { sem.signal() }
        if let err { if id != nil { write(rpcError(id, "Clipper is not reachable: \(err.localizedDescription)")) }; return }
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200: if let data, !data.isEmpty { write(data) }
        case 202: break
        case 401: if id != nil { write(rpcError(id, "Clipper rejected the token (check MCP_TOKEN)")) }
        default: if id != nil { write(rpcError(id, "Clipper returned HTTP \(status)")) }
        }
    }.resume()
    sem.wait()
}

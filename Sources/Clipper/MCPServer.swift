import Foundation
import Network
import DropCore

/// Loopback-only HTTP server for MCP clients. One request per connection, bearer-token protected.
final class MCPServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "clipper.mcp")
    private var listener: NWListener?
    private let handler: MCPHandler
    /// Tokens currently allowed (one per connected AI tool), read on every request so a disconnect is immediate.
    private let tokens: @Sendable () -> Set<String>
    private let onUse: @Sendable (String) -> Void
    let port: UInt16
    var onState: (@Sendable (String) -> Void)?

    init(store: HistoryStore, tokens: @escaping @Sendable () -> Set<String>, onUse: @escaping @Sendable (String) -> Void = { _ in }, port: UInt16) {
        handler = MCPHandler(store: store); self.tokens = tokens; self.onUse = onUse; self.port = port
    }

    static func loadToken(at url: URL) -> String {
        if let t = try? String(contentsOf: url, encoding: .utf8), t.count == 64 { return t }
        let t = HTTPGate.makeToken()
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? t.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return t
    }

    func start() throws {
        let params = NWParameters.tcp
        params.requiredInterfaceType = .loopback
        guard let p = NWEndpoint.Port(rawValue: port) else { throw CocoaError(.fileReadInvalidFileName) }
        let l = try NWListener(using: params, on: p)
        l.stateUpdateHandler = { [weak self] st in
            switch st {
            case .ready: self?.onState?("listening on 127.0.0.1:\(self?.port ?? 0)")
            case .failed(let e): self?.onState?("failed: \(e)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
        listener = l
    }

    func stop() { listener?.cancel(); listener = nil }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        // Idle or slow clients must not hold the connection open.
        queue.asyncAfter(deadline: .now() + 10) { c.cancel() }
        read(c, Data())
    }

    private func read(_ c: NWConnection, _ buf: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buf
            if let data { buf.append(data) }
            switch HTTPGate.parse(buf) {
            case .incomplete:
                if done || err != nil { c.cancel() } else { self.read(c, buf) }
            case .bad(let s):
                self.send(c, HTTPGate.response(status: s, reason: "Bad Request"))
            case .request(let r):
                let (verdict, matched) = HTTPGate.authorize(r, tokens: self.tokens(), port: self.port)
                switch verdict {
                case .status(let s, let msg): self.send(c, HTTPGate.response(status: s, reason: msg))
                case .ok:
                    if let m = matched { self.onUse(m) }
                    if let out = self.handler.handle(r.body) {
                        self.send(c, HTTPGate.response(status: 200, reason: "OK", body: out, json: true))
                    } else {
                        self.send(c, HTTPGate.response(status: 202, reason: "Accepted"))
                    }
                }
            }
        }
    }

    private func send(_ c: NWConnection, _ d: Data) {
        c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
    }
}

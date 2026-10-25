import Foundation

/// File-backed history. Newest first. A repeated checksum moves the existing item to the top.
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipItem] = []
    private let url: URL?
    public var capacity: Int

    public init(url: URL? = nil, capacity: Int = 1000) {
        self.url = url; self.capacity = capacity
        if let url, let d = try? Data(contentsOf: url), let decoded = try? JSONDecoder.iso.decode([ClipItem].self, from: d) {
            items = decoded
        }
    }

    public var all: [ClipItem] { lock.withLock { items } }

    @discardableResult
    public func add(_ item: ClipItem) -> ClipItem {
        lock.withLock {
            var item = item
            if let i = items.firstIndex(where: { $0.checksum == item.checksum }) {
                let old = items.remove(at: i)
                item.id = old.id; item.pinboard = old.pinboard
            }
            items.insert(item, at: 0)
            trim()
            persist()
            return item
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock { items.removeAll { $0.id == id }; persist() }
    }

    public func setPinboard(_ name: String?, for id: UUID) {
        lock.withLock {
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinboard = name; persist() }
        }
    }

    public func pinboards() -> [String] {
        Array(Set(all.compactMap(\.pinboard))).sorted()
    }

    public func search(_ query: String = "", kind: ClipKind? = nil, pinboard: String? = nil, app: String? = nil) -> [ClipItem] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return all.filter { i in
            (kind == nil || i.kind == kind) && (pinboard == nil || i.pinboard == pinboard)
                && (app == nil || i.sourceBundleID == app)
                && (q.isEmpty || i.title.lowercased().contains(q) || (i.text?.lowercased().contains(q) ?? false))
        }
    }

    /// Pinned items are never trimmed.
    private func trim() {
        var unpinned = 0
        items = items.filter { i in
            if i.pinboard != nil { return true }
            unpinned += 1
            return unpinned <= capacity
        }
    }

    private func persist() {
        guard let url, let d = try? JSONEncoder.iso.encode(items) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
    }
}

extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

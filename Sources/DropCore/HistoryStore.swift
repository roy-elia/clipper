import Foundation

/// File-backed history. Newest first. A repeated checksum moves the existing item to the top.
public final class HistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [ClipItem] = []
    private var boards: [String] = []
    private let url: URL?
    public var capacity: Int

    public init(url: URL? = nil, capacity: Int = 1000) {
        self.url = url; self.capacity = capacity
        if let url, let d = try? Data(contentsOf: url) {
            if let env = try? JSONDecoder.iso.decode(Envelope.self, from: d) { items = env.items; boards = env.boards }
            else if let legacy = try? JSONDecoder.iso.decode([ClipItem].self, from: d) { items = legacy }
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

    public func item(_ id: UUID) -> ClipItem? { lock.withLock { items.first { $0.id == id } } }

    /// Edits the text of a text-like clip, recomputing its checksum and title. Returns nil for unknown or image clips.
    @discardableResult
    public func updateText(_ id: UUID, to text: String) -> ClipItem? {
        lock.withLock {
            guard let i = items.firstIndex(where: { $0.id == id }), items[i].data == nil else { return nil }
            items[i].text = text
            items[i].title = text.split(whereSeparator: \.isNewline).first.map { String($0.prefix(120)) } ?? "text"
            items[i].checksum = CaptureRules.checksum(string: text, data: nil)
            persist(); return items[i]
        }
    }

    public func setPinboard(_ name: String?, for id: UUID) {
        lock.withLock {
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinboard = name; persist() }
        }
    }

    /// Empty boards persist: the list is explicit, plus any board an item still refers to.
    /// Source apps seen in history, most used first, for the filter chips.
    public func apps() -> [String] {
        let counts = Dictionary(grouping: all.compactMap(\.sourceBundleID), by: { $0 }).mapValues(\.count)
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.map(\.key)
    }

    public func pinboards() -> [String] {
        lock.withLock { boards + Set(items.compactMap(\.pinboard)).subtracting(boards).sorted() }
    }

    @discardableResult
    public func createPinboard(_ name: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        return lock.withLock {
            guard !n.isEmpty, !boards.contains(n), !items.contains(where: { $0.pinboard == n }) else { return false }
            boards.append(n); persist(); return true
        }
    }

    @discardableResult
    public func renamePinboard(_ old: String, to new: String) -> Bool {
        let n = new.trimmingCharacters(in: .whitespaces)
        return lock.withLock {
            let existing = Set(boards).union(items.compactMap(\.pinboard))
            guard !n.isEmpty, existing.contains(old), !existing.contains(n) else { return false }
            boards = boards.map { $0 == old ? n : $0 }
            for i in items.indices where items[i].pinboard == old { items[i].pinboard = n }
            persist(); return true
        }
    }

    /// Deleting a board unpins its clips (they stay in history) rather than deleting them.
    public func deletePinboard(_ name: String) {
        lock.withLock {
            boards.removeAll { $0 == name }
            for i in items.indices where items[i].pinboard == name { items[i].pinboard = nil }
            persist()
        }
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
        guard let url, let d = try? JSONEncoder.iso.encode(Envelope(items: items, boards: boards)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        // Clipboard history can hold secrets: owner-only file and folder.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
    }
}

struct Envelope: Codable { var items: [ClipItem]; var boards: [String] }

extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }

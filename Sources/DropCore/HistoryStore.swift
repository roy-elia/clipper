import Foundation

/// File-backed history. Newest first. A repeated checksum moves the existing item to the top.
public final class HistoryStore: @unchecked Sendable {
    let lock = NSLock()
    var items: [ClipItem] = []
    var boards: [String] = []
    var tombstones: [UUID: Date] = [:]
    var boardColors: [String: String] = [:]
    private let url: URL?
    public var capacity: Int

    public init(url: URL? = nil, capacity: Int = 1000) {
        self.url = url; self.capacity = capacity
        if let url, let d = try? Data(contentsOf: url) {
            if let env = try? JSONDecoder.iso.decode(Envelope.self, from: d) { items = env.items; boards = env.boards; tombstones = env.tombstones ?? [:]; boardColors = env.boardColors ?? [:] }
            else if let legacy = try? JSONDecoder.iso.decode([ClipItem].self, from: d) { items = legacy }
        }
    }

    public var all: [ClipItem] { lock.withLock { items } }

    @discardableResult
    public func add(_ item: ClipItem) -> ClipItem {
        lock.withLock {
            var item = item
            item.modifiedAt = Date()
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
        lock.withLock { if items.contains(where: { $0.id == id }) { tombstones[id] = Date() }; items.removeAll { $0.id == id }; persist() }
    }

    /// Deletes unpinned clips older than `age` seconds, recording tombstones. Returns how many were removed.
    @discardableResult
    public func purge(olderThan age: TimeInterval, now: Date = Date()) -> Int {
        lock.withLock {
            let doomed = items.filter { $0.pinboard == nil && now.timeIntervalSince($0.createdAt) >= age }
            guard !doomed.isEmpty else { return 0 }
            for i in doomed { tombstones[i.id] = now }
            let ids = Set(doomed.map(\.id))
            items.removeAll { ids.contains($0.id) }
            persist(); return doomed.count
        }
    }

    /// Puts a second, independent copy of a clip at the top. Its checksum is made unique so it is not collapsed back.
    @discardableResult
    public func duplicate(_ id: UUID) -> ClipItem? {
        lock.withLock {
            guard var c = items.first(where: { $0.id == id }) else { return nil }
            c.id = UUID(); c.pinboard = nil; c.createdAt = Date(); c.modifiedAt = Date()
            c.checksum += "#copy-" + c.id.uuidString
            items.insert(c, at: 0); trim(); persist(); return c
        }
    }

    /// Stores a fetched preview image for a link clip (small JPEG/PNG data only).
    public func setLinkImage(_ id: UUID, _ data: Data) {
        guard data.count <= 1_500_000 else { return }
        lock.withLock {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            var e = items[i].extras ?? [:]; e["linkImage"] = data; items[i].extras = e
            items[i].modifiedAt = Date(); persist()
        }
    }

    /// Stores a fetched page title for a link clip.
    public func setLinkTitle(_ id: UUID, _ title: String) {
        lock.withLock {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            var e = items[i].extras ?? [:]; e["linkTitle"] = Data(title.utf8); items[i].extras = e
            items[i].modifiedAt = Date(); persist()
        }
    }

    /// Gives a clip its own name; an empty name clears it.
    public func rename(_ id: UUID, to title: String?) {
        let t = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.withLock {
            guard let i = items.firstIndex(where: { $0.id == id }) else { return }
            items[i].customTitle = (t?.isEmpty ?? true) ? nil : String(t!.prefix(80))
            items[i].modifiedAt = Date(); persist()
        }
    }

    /// Pinboard colours, as hex. New pinboards take the next colour from a fixed set.
    public static let boardPalette = ["#FF5F57", "#FFB340", "#FFD84D", "#34C759", "#30B0C7", "#3D7BFF", "#AF52DE", "#FF6FAF"]
    public func boardColor(_ name: String) -> String { lock.withLock { boardColors[name] ?? Self.boardPalette[0] } }
    public func setBoardColor(_ name: String, _ hex: String) { lock.withLock { boardColors[name] = hex; persist() } }

    /// Puts back a clip removed by delete (undo): back in date order, and no longer recorded as deleted.
    public func restore(_ item: ClipItem) {
        lock.withLock {
            guard !items.contains(where: { $0.id == item.id }) else { return }
            tombstones[item.id] = nil
            var c = item; c.modifiedAt = Date()
            let at = items.firstIndex { $0.createdAt < c.createdAt } ?? items.count
            items.insert(c, at: at); trim(); persist()
        }
    }

    public func markUsed(_ id: UUID, at date: Date = Date()) {
        lock.withLock { if let i = items.firstIndex(where: { $0.id == id }) { items[i].lastUsed = date; persist() } }
    }

    /// "Untitled", "Untitled 2", … — the first name no pinboard uses yet.
    public func freeBoardName(_ base: String = "Untitled") -> String {
        let used = Set(pinboards())
        if !used.contains(base) { return base }
        var n = 2; while used.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
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
            items[i].modifiedAt = Date()
            persist(); return items[i]
        }
    }

    /// Deletes saved clips. Returns how many were removed. Deletions are recorded so they sync as deletions.
    @discardableResult
    public func clear(keepPinned: Bool) -> Int {
        lock.withLock {
            let doomed = items.filter { !(keepPinned && $0.pinboard != nil) }
            let now = Date()
            for i in doomed { tombstones[i.id] = now }
            let ids = Set(doomed.map(\.id))
            items.removeAll { ids.contains($0.id) }
            persist()
            return doomed.count
        }
    }

    public func markSecret(_ id: UUID, _ on: Bool = true, byModel: Bool = false) {
        lock.withLock { if let i = items.firstIndex(where: { $0.id == id }) { items[i].sensitive = on ? true : nil; items[i].modelFlagged = on && byModel ? true : nil; items[i].modifiedAt = Date(); persist() } }
    }

    /// Deletes secret clips older than `ttl` seconds unless they are pinned. Returns how many were removed.
    @discardableResult
    public func purgeSecrets(olderThan ttl: TimeInterval, now: Date = Date()) -> Int {
        lock.withLock {
            let before = items.count
            items.removeAll { $0.isSecret && $0.modelFlagged != true && $0.pinboard == nil && now.timeIntervalSince($0.createdAt) >= ttl }
            if items.count != before { persist() }
            return before - items.count
        }
    }

    public func setPinboard(_ name: String?, for id: UUID) {
        lock.withLock {
            if let i = items.firstIndex(where: { $0.id == id }) { items[i].pinboard = name; items[i].modifiedAt = Date(); persist() }
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
            if boardColors[n] == nil { boardColors[n] = Self.boardPalette[boards.count % Self.boardPalette.count] }
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
            if let c = boardColors.removeValue(forKey: old) { boardColors[n] = c }
            for i in items.indices where items[i].pinboard == old { items[i].pinboard = n }
            persist(); return true
        }
    }

    /// Deleting a board unpins its clips (they stay in history) rather than deleting them.
    public func deletePinboard(_ name: String) {
        lock.withLock {
            boards.removeAll { $0 == name }
            boardColors[name] = nil
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
    func trim() {
        var unpinned = 0
        items = items.filter { i in
            if i.pinboard != nil { return true }
            unpinned += 1
            return unpinned <= capacity
        }
    }

    func persist() {
        guard let url, let d = try? JSONEncoder.iso.encode(Envelope(items: items, boards: boards, tombstones: tombstones, boardColors: boardColors)) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: url, options: .atomic)
        // Clipboard history can hold secrets: owner-only file and folder.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
    }
}

struct Envelope: Codable { var items: [ClipItem]; var boards: [String]; var tombstones: [UUID: Date]?; var boardColors: [String: String]? }

extension JSONEncoder { static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e } }
extension JSONDecoder { static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d } }


// MARK: sync support
public extension HistoryStore {
    /// Everything that changed after `date` (all of it when nil), including deletions.
    func changes(since date: Date?) -> [SyncRecord] {
        lock.withLock {
            let live = items.filter { date == nil || $0.changedAt > date! }.map { SyncRecord(id: $0.id, item: $0, changedAt: $0.changedAt) }
            let gone = tombstones.filter { date == nil || $0.value > date! }.map { SyncRecord(id: $0.key, item: nil, changedAt: $0.value) }
            return live + gone
        }
    }

    var latestChange: Date? {
        lock.withLock { ([items.map(\.changedAt).max(), tombstones.values.max()].compactMap { $0 }).max() }
    }

    /// Merges records from another device: the newer change wins; a newer deletion beats an older edit.
    /// Returns how many local clips were added, changed or removed.
    @discardableResult
    func apply(_ records: [SyncRecord]) -> Int {
        lock.withLock {
            var n = 0
            for r in records {
                let localIdx = items.firstIndex { $0.id == r.id }
                let localTime = localIdx.map { items[$0].changedAt } ?? tombstones[r.id]
                if let lt = localTime, lt >= r.changedAt { continue }
                if let remote = r.item {
                    if let i = localIdx { items[i] = remote } else {
                        // Same content already here under another id: keep one copy.
                        if let dup = items.firstIndex(where: { $0.checksum == remote.checksum }) { items.remove(at: dup) }
                        items.append(remote)
                    }
                    tombstones[r.id] = nil
                } else {
                    if let i = localIdx { items.remove(at: i) }
                    tombstones[r.id] = r.changedAt
                }
                n += 1
            }
            items.sort { $0.createdAt > $1.createdAt }
            trim(); if n > 0 { persist() }
            return n
        }
    }
}

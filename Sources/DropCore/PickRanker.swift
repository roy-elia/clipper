import Foundation

/// One remembered paste: which clip went into which app.
public struct PasteEvent: Codable, Sendable, Equatable {
    public var itemID: UUID
    public var kind: ClipKind
    public var targetApp: String
    public var date: Date
    public init(itemID: UUID, kind: ClipKind, targetApp: String, date: Date = Date()) {
        self.itemID = itemID; self.kind = kind; self.targetApp = targetApp; self.date = date
    }
}

public struct PasteLog: Codable, Sendable, Equatable {
    public private(set) var events: [PasteEvent] = []
    public static let cap = 500
    public init() {}
    public mutating func record(_ e: PasteEvent) {
        events.append(e)
        if events.count > Self.cap { events.removeFirst(events.count - Self.cap) }
    }
    public static func load(_ url: URL) -> PasteLog {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.iso.decode(PasteLog.self, from: $0) } ?? PasteLog()
    }
    public func save(_ url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.iso.encode(self).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Suggests which clips to offer for the app being pasted into. Signals, strongest first:
/// the clip was pasted into this app before, it came from this app, its kind is what this app usually receives,
/// and it is recent. Secrets are never suggested.
public struct PickRanker: Sendable {
    public var log: PasteLog
    public var now: Date
    public init(log: PasteLog, now: Date = Date()) { self.log = log; self.now = now }

    public func score(_ item: ClipItem, for app: String?) -> Double {
        if item.isSecret { return -1 }
        var s = 0.0
        let age = max(0, now.timeIntervalSince(item.createdAt))
        s += 3.0 * exp(-age / 1800)            // half an hour of recency carries most of the weight
        s += 0.5 * exp(-age / 86_400)
        // Most pastes are of what was just copied, so a clip from the last two minutes always leads.
        if age < 120 { s += 6 }
        guard let app else { return s }
        let here = log.events.filter { $0.targetApp == app }
        if here.contains(where: { $0.itemID == item.id }) { s += 4.0 }
        if item.sourceBundleID == app { s += 1.0 }
        if !here.isEmpty {
            let share = Double(here.filter { $0.kind == item.kind }.count) / Double(here.count)
            s += 2.0 * share
        }
        return s
    }

    public func rank(_ items: [ClipItem], for app: String?, limit: Int = 8) -> [ClipItem] {
        items.map { ($0, score($0, for: app)) }
            .filter { $0.1 >= 0 }
            .sorted { $0.1 > $1.1 }
            .prefix(limit).map(\.0)
    }
}

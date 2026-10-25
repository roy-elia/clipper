import Foundation

/// One clip as it travels between devices: either its current content or a deletion marker.
public struct SyncRecord: Codable, Sendable, Equatable {
    public var id: UUID
    public var item: ClipItem?       // nil = deleted
    public var changedAt: Date
    public init(id: UUID, item: ClipItem?, changedAt: Date) { self.id = id; self.item = item; self.changedAt = changedAt }
}

/// The wire to a server. CloudKit implements this on a signed build with an iCloud container; tests use `MemoryCloud`.
public protocol SyncTransport: Sendable {
    func push(_ records: [SyncRecord]) async throws
    /// Returns everything newer than `token` plus the token to pass next time.
    func pull(since token: String?) async throws -> (records: [SyncRecord], token: String)
}

public struct SyncState: Codable, Sendable, Equatable {
    public var token: String?
    public var lastPush: Date?
    public init() {}
}

/// Last-writer-wins sync of a HistoryStore. Secrets and oversized clips never leave the device.
public enum SyncCoordinator {
    public static let maxClipBytes = 5_000_000

    public static func syncable(_ i: ClipItem) -> Bool {
        !i.isSecret && (i.data?.count ?? 0) + (i.extras?.values.reduce(0) { $0 + $1.count } ?? 0) <= maxClipBytes
    }

    @discardableResult
    public static func sync(_ store: HistoryStore, state: inout SyncState, transport: SyncTransport) async throws -> (pushed: Int, pulled: Int) {
        let outgoing = store.changes(since: state.lastPush).filter { $0.item.map(syncable) ?? true }
        if !outgoing.isEmpty { try await transport.push(outgoing) }
        let (incoming, token) = try await transport.pull(since: state.token)
        let applied = store.apply(incoming)
        state.token = token
        state.lastPush = store.latestChange
        return (outgoing.count, applied)
    }
}

/// An in-memory server for tests: keeps the newest record per id and hands out an increasing token.
public actor MemoryCloud: SyncTransport {
    private var records: [UUID: (rec: SyncRecord, seq: Int)] = [:]
    private var seq = 0
    public init() {}
    public func push(_ recs: [SyncRecord]) async throws {
        for r in recs {
            if let existing = records[r.id], existing.rec.changedAt > r.changedAt { continue }
            seq += 1; records[r.id] = (r, seq)
        }
    }
    public func pull(since token: String?) async throws -> (records: [SyncRecord], token: String) {
        let after = token.flatMap(Int.init) ?? 0
        return (records.values.filter { $0.seq > after }.sorted { $0.seq < $1.seq }.map(\.rec), String(seq))
    }
    public var count: Int { records.count }
}

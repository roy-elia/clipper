import Foundation
import CloudKit
import Security
import DropCore

/// CloudKit-backed SyncTransport. It only works in a build signed with an iCloud container entitlement from an
/// Apple developer team, so `available` checks the running binary's entitlements before anything touches CloudKit
/// (CKContainer traps when the entitlement is missing).
final class CloudKitTransport: SyncTransport, @unchecked Sendable {
    static let containerID = "iCloud.com.royelia.clipper"

    static var available: Bool {
        guard let task = SecTaskCreateFromSelf(nil),
              let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String]
        else { return false }
        return v.contains(containerID)
    }

    private let db: CKDatabase
    init() { db = CKContainer(identifier: Self.containerID).privateCloudDatabase }

    func push(_ records: [SyncRecord]) async throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        var save: [CKRecord] = []
        for r in records {
            let rec = CKRecord(recordType: "Clip", recordID: CKRecord.ID(recordName: r.id.uuidString))
            rec["changedAt"] = r.changedAt as CKRecordValue
            rec["deleted"] = (r.item == nil ? 1 : 0) as CKRecordValue
            if let item = r.item { rec["payload"] = try enc.encode(item) as CKRecordValue }
            save.append(rec)
        }
        for chunk in stride(from: 0, to: save.count, by: 200).map({ Array(save[$0..<min($0 + 200, save.count)]) }) {
            _ = try await db.modifyRecords(saving: chunk, deleting: [], savePolicy: .allKeys)
        }
    }

    func pull(since token: String?) async throws -> (records: [SyncRecord], token: String) {
        let iso = ISO8601DateFormatter()
        let since = token.flatMap(iso.date(from:)) ?? Date(timeIntervalSince1970: 0)
        let q = CKQuery(recordType: "Clip", predicate: NSPredicate(format: "changedAt > %@", since as NSDate))
        q.sortDescriptors = [NSSortDescriptor(key: "changedAt", ascending: true)]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        var out: [SyncRecord] = []; var newest = since
        var cursor: CKQueryOperation.Cursor?
        repeat {
            let page = cursor == nil ? try await db.records(matching: q, resultsLimit: 200) : try await db.records(continuingMatchFrom: cursor!, resultsLimit: 200)
            for (_, result) in page.matchResults {
                guard let rec = try? result.get(), let at = rec["changedAt"] as? Date, let id = UUID(uuidString: rec.recordID.recordName) else { continue }
                newest = max(newest, at)
                if (rec["deleted"] as? Int) == 1 { out.append(SyncRecord(id: id, item: nil, changedAt: at)) }
                else if let data = rec["payload"] as? Data, let item = try? dec.decode(ClipItem.self, from: data) {
                    out.append(SyncRecord(id: id, item: item, changedAt: at))
                }
            }
            cursor = page.queryCursor
        } while cursor != nil
        return (out, iso.string(from: newest))
    }
}

import Testing
import Foundation
@testable import DropCore

@Suite struct SyncTests {
    func clip(_ s: String) -> ClipItem { CaptureRules().makeItem(from: .init(types: [], string: s))! }

    @Test func twoDevicesConverge() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(), b = HistoryStore()
        var sa = SyncState(), sb = SyncState()
        a.add(clip("from A")); b.add(clip("from B"))
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        #expect(Set(a.all.map(\.title)) == ["from A", "from B"])
        #expect(Set(b.all.map(\.title)) == ["from A", "from B"])
    }

    @Test func deletionPropagatesAndStaysDeleted() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(), b = HistoryStore()
        var sa = SyncState(), sb = SyncState()
        let item = a.add(clip("temp"))
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        #expect(b.all.count == 1)
        a.delete(item.id)
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        #expect(b.all.isEmpty)
        try await SyncCoordinator.sync(b, state: &sb, transport: cloud); try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        #expect(a.all.isEmpty && b.all.isEmpty)   // no resurrection
    }

    @Test func newerEditWins() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(), b = HistoryStore()
        var sa = SyncState(), sb = SyncState()
        let item = a.add(clip("v1"))
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        try await Task.sleep(nanoseconds: 20_000_000)
        a.updateText(item.id, to: "v2 from A")
        try await Task.sleep(nanoseconds: 20_000_000)
        b.updateText(item.id, to: "v3 from B (newest)")
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        #expect(a.item(item.id)?.text == "v3 from B (newest)" && b.item(item.id)?.text == "v3 from B (newest)")
    }

    @Test func pinboardsSyncWithTheClip() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(), b = HistoryStore()
        var sa = SyncState(), sb = SyncState()
        let item = a.add(clip("pinned"))
        a.setPinboard("Work", for: item.id)
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        #expect(b.item(item.id)?.pinboard == "Work" && b.pinboards() == ["Work"])
    }

    @Test func secretsAndHugeClipsStayOnDevice() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(), b = HistoryStore()
        var sa = SyncState(), sb = SyncState()
        a.add(clip("ghp_16C7e42F292c6912E7710c838347Ae178B4a"))
        a.add(ClipItem(kind: .image, title: "big", data: Data(count: 6_000_000), checksum: "big"))
        a.add(clip("fine"))
        try await SyncCoordinator.sync(a, state: &sa, transport: cloud); try await SyncCoordinator.sync(b, state: &sb, transport: cloud)
        #expect(b.all.map(\.title) == ["fine"])
        #expect(await cloud.count == 1)
    }

    @Test func secondSyncSendsNothingNew() async throws {
        let cloud = MemoryCloud(); let a = HistoryStore(); var sa = SyncState()
        a.add(clip("x"))
        let first = try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        let second = try await SyncCoordinator.sync(a, state: &sa, transport: cloud)
        #expect(first.pushed == 1 && second.pushed == 0)
    }

    @Test func tombstonesSurviveRestart() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clipper-tomb-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let a = HistoryStore(url: url); let i = a.add(clip("gone")); a.delete(i.id)
        #expect(HistoryStore(url: url).changes(since: nil).contains { $0.id == i.id && $0.item == nil })
    }
}

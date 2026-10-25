import AppKit
import DropCore

/// Polls the pasteboard (0.25 s) and feeds new snapshots through CaptureRules into the store.
@MainActor
final class PasteboardMonitor {
    let pasteboard: NSPasteboard
    let rules: CaptureRules
    let store: HistoryStore
    var paused = false
    var onChange: (() -> Void)?
    private var lastCount: Int
    private var timer: Timer?

    init(pasteboard: NSPasteboard = .general, rules: CaptureRules = CaptureRules(), store: HistoryStore) {
        self.pasteboard = pasteboard; self.rules = rules; self.store = store
        lastCount = pasteboard.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { _ = self?.poll() }
        }
        timer?.tolerance = 0.025
    }

    func stop() { timer?.invalidate(); timer = nil }

    @discardableResult
    func poll() -> ClipItem? {
        guard pasteboard.changeCount != lastCount else { return nil }
        lastCount = pasteboard.changeCount
        guard !paused else { return nil }
        let types = Set((pasteboard.types ?? []).map(\.rawValue))
        let image = types.contains("public.png") ? pasteboard.data(forType: .png) : pasteboard.data(forType: .tiff)
        let snap = PasteboardSnapshot(types: types, string: pasteboard.string(forType: .string), data: image,
                                      sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        guard let item = rules.makeItem(from: snap) else { return nil }
        let stored = store.add(item)
        onChange?()
        return stored
    }

    /// Writing our own item back must not be re-captured as a new copy.
    func write(_ item: ClipItem) {
        pasteboard.clearContents()
        if let t = item.text { pasteboard.setString(t, forType: .string) }
        else if let d = item.data { pasteboard.setData(d, forType: .tiff) }
        lastCount = pasteboard.changeCount
    }
}

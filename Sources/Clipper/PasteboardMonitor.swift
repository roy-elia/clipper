import AppKit
import DropCore

/// Polls the pasteboard (0.25 s) and feeds new snapshots through CaptureRules into the store.
@MainActor
final class PasteboardMonitor {
    let pasteboard: NSPasteboard
    var rules: CaptureRules
    let store: HistoryStore
    var paused = false
    var onChange: (() -> Void)?
    private var lastCount: Int
    private var timer: Timer?

    static let richTypes: [NSPasteboard.PasteboardType] = [.rtf, .html]

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
        var extras: [String: Data] = [:]
        for t in Self.richTypes { if let d = pasteboard.data(forType: t) { extras[t.rawValue] = d } }
        let files = (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []).map(\.absoluteString)
        let snap = PasteboardSnapshot(types: types, string: files.isEmpty ? pasteboard.string(forType: .string) : nil, data: files.isEmpty ? image : nil,
                                      sourceBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
                                      extras: extras, fileURLs: files)
        guard let item = rules.makeItem(from: snap) else { return nil }
        let stored = store.add(item)
        onChange?()
        return stored
    }

    /// Puts an item back on the pasteboard. `plain` drops formatting and turns files into their paths.
    /// Our own write must not be re-captured as a new copy.
    func write(_ item: ClipItem, plain: Bool = false) {
        pasteboard.clearContents()
        if !plain, let urls = item.fileURLs, !urls.isEmpty {
            pasteboard.writeObjects(urls.compactMap { URL(string: $0) as NSURL? })
        } else {
            if let t = item.text { pasteboard.setString(t, forType: .string) }
            else if let d = item.data { pasteboard.setData(d, forType: .tiff) }
            if !plain { for (k, v) in item.extras ?? [:] { pasteboard.setData(v, forType: NSPasteboard.PasteboardType(k)) } }
        }
        lastCount = pasteboard.changeCount
    }
}

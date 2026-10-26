import AppKit
import DropCore

/// AppleScript / Shortcuts ("Run AppleScript") commands from Resources/Clipper.sdef.
/// Secret clips are never returned.
@MainActor private func clipperApp() -> App? { NSApp.delegate as? App }

@objc(ClipperLatestClipCommand) final class ClipperLatestClipCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        MainActor.assumeIsolated { clipperApp()?.store.all.first { !$0.isSecret }?.plainText ?? "" }
    }
}

@objc(ClipperClipAtIndexCommand) final class ClipperClipAtIndexCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        let n = (directParameter as? Int) ?? 0
        return MainActor.assumeIsolated { () -> String in
            guard let all = clipperApp()?.store.all, all.indices.contains(n - 1), !all[n - 1].isSecret else { return "" }
            return all[n - 1].plainText ?? all[n - 1].title
        }
    }
}

@objc(ClipperClipCountCommand) final class ClipperClipCountCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? { let n: Int = MainActor.assumeIsolated { clipperApp()?.store.all.count ?? 0 }; return n }
}

@objc(ClipperAddClipCommand) final class ClipperAddClipCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let text = directParameter as? String, !text.isEmpty else { return false }
        let board = (evaluatedArguments?["pinboardName"] as? String)?.trimmingCharacters(in: .whitespaces)
        return MainActor.assumeIsolated { () -> Bool in
            guard let a = clipperApp() else { return false }
            let snap = PasteboardSnapshot(types: ["public.utf8-plain-text"], string: text, sourceBundleID: Bundle.main.bundleIdentifier)
            guard let item = a.monitor.rules.makeItem(from: snap) else { return false }
            let saved = a.store.add(item)
            if let b = board, !b.isEmpty { _ = a.store.createPinboard(b); a.store.setPinboard(b, for: saved.id) }
            a.model.refresh()
            return true
        }
    }
}

@objc(ClipperCreatePinboardCommand) final class ClipperCreatePinboardCommand: NSScriptCommand {
    override func performDefaultImplementation() -> Any? {
        guard let name = directParameter as? String else { return false }
        return MainActor.assumeIsolated { () -> Bool in
            guard let a = clipperApp() else { return false }
            let ok = a.store.createPinboard(name); a.model.refresh(); return ok
        }
    }
}

import AppKit
import ApplicationServices

/// Pastes into the frontmost app by posting ⌘V. That needs the Accessibility permission.
enum PasteInjector {
    /// Plain-file diagnostics: unified-log redaction hides NSLog arguments for signed apps.
    static func diag(_ line: String) {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Clipper/clipper.log")
        let stamped = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(stamped.utf8)); try? h.close() }
        else { try? stamped.write(to: url, atomically: true, encoding: .utf8) }
    }

    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once and returns the current state.
    @discardableResult
    static func requestAccess() -> Bool {
        let opts = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    static func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Returns false (and posts nothing) when not trusted, so the caller can fall back to copy-only.
    /// Sends the whole chord (⌘ down, V down, V up, ⌘ up) the way a keyboard would, and holds back the user's real
    /// modifier state for a moment so a still-held ⇧ or ⌥ from the shortcut cannot change the paste into something else.
    @discardableResult
    static func pasteNow(plain: Bool = false) -> Bool {
        diag("paste: AXIsProcessTrusted=\(trusted) postEventAccess=\(CGPreflightPostEventAccess()) frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none")")
        guard trusted else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                        state: .eventSuppressionStateSuppressionInterval)
        src?.localEventsSuppressionInterval = 0.0
        let flags: CGEventFlags = plain ? [.maskCommand, .maskAlternate, .maskShift] : .maskCommand
        let steps: [(CGKeyCode, Bool, CGEventFlags)] = [(55, true, .maskCommand), (9, true, flags), (9, false, flags), (55, false, [])]
        for (key, down, fl) in steps {
            let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down)
            e?.flags = fl
            e?.post(tap: .cgAnnotatedSessionEventTap)
            usleep(8_000)
        }
        diag("paste: chord posted")
        return true
    }
}

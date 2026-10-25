import AppKit
import ApplicationServices

/// Pastes into the frontmost app by posting ⌘V. That needs the Accessibility permission.
enum PasteInjector {
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
    @discardableResult
    static func pasteNow(plain: Bool = false) -> Bool {
        guard trusted else { return false }
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        let flags: CGEventFlags = plain ? [.maskCommand, .maskAlternate, .maskShift] : .maskCommand
        down?.flags = flags; up?.flags = flags
        down?.post(tap: .cghidEventTap); up?.post(tap: .cghidEventTap)
        return true
    }
}

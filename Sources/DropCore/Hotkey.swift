import Foundation

/// A global shortcut as Carbon key code + modifier mask. Default is ⌘⇧V.
public struct Hotkey: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public static let cmd: UInt32 = 1 << 8, shift: UInt32 = 1 << 9, option: UInt32 = 1 << 11, control: UInt32 = 1 << 12
    public static let `default` = Hotkey(keyCode: 9, modifiers: cmd | shift)

    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }

    /// A shortcut must include ⌘, ⌃ or ⌥, otherwise it would swallow ordinary typing.
    public var isValid: Bool { modifiers & (Hotkey.cmd | Hotkey.control | Hotkey.option) != 0 }

    public var display: String {
        var s = ""
        if modifiers & Hotkey.control != 0 { s += "⌃" }
        if modifiers & Hotkey.option != 0 { s += "⌥" }
        if modifiers & Hotkey.shift != 0 { s += "⇧" }
        if modifiers & Hotkey.cmd != 0 { s += "⌘" }
        return s + (Hotkey.names[keyCode] ?? "key\(keyCode)")
    }

    static let names: [UInt32: String] = [0: "A", 1: "S", 2: "D", 3: "F", 5: "G", 6: "Z", 7: "X", 8: "C", 9: "V",
                                          11: "B", 12: "Q", 13: "W", 14: "E", 15: "R", 17: "T", 49: "Space", 51: "⌫"]
}

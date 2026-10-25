import Testing
@testable import DropCore

@Suite struct HotkeyTests {
    @Test func defaultIsCmdShiftV() { #expect(Hotkey.default.display == "⇧⌘V") }
    @Test func needsRealModifier() {
        #expect(Hotkey.default.isValid)
        #expect(!Hotkey(keyCode: 9, modifiers: Hotkey.shift).isValid)
        #expect(!Hotkey(keyCode: 9, modifiers: 0).isValid)
    }
}

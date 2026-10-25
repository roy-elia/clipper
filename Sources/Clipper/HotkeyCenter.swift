import Carbon.HIToolbox
import DropCore

/// Registers one global hotkey with Carbon; needs no Accessibility permission.
@MainActor
final class HotkeyCenter {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onFire: (() -> Void)?
    private(set) var registered: Hotkey?

    @discardableResult
    func register(_ hk: Hotkey) -> Bool {
        unregister()
        guard hk.isValid else { return false }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, _, ud in
                let me = Unmanaged<HotkeyCenter>.fromOpaque(ud!).takeUnretainedValue()
                DispatchQueue.main.async { MainActor.assumeIsolated { me.onFire?() } }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x434C4950), id: 1) // 'CLIP'
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { registered = hk }
        return status == noErr
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil; registered = nil
    }
}

import Carbon.HIToolbox
import DropCore

/// Registers one global hotkey with Carbon; needs no Accessibility permission.
@MainActor
final class HotkeyCenter {
    private var ref: EventHotKeyRef?
    private var handler: EventHandlerRef?
    var onFire: (() -> Void)?
    let id: UInt32
    init(id: UInt32 = 1) { self.id = id }
    private(set) var registered: Hotkey?

    @discardableResult
    func register(_ hk: Hotkey) -> Bool {
        unregister()
        guard hk.isValid else { return false }
        if handler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, ud in
                let me = Unmanaged<HotkeyCenter>.fromOpaque(ud!).takeUnretainedValue()
                // Several centers share the app event target; only react to our own hotkey id.
                var hk = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                guard hk.id == me.id else { return OSStatus(eventNotHandledErr) }
                DispatchQueue.main.async { MainActor.assumeIsolated { me.onFire?() } }
                return noErr
            }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
        }
        let id = EventHotKeyID(signature: OSType(0x434C4950), id: id) // 'CLIP'
        let status = RegisterEventHotKey(hk.keyCode, hk.modifiers, id, GetApplicationEventTarget(), 0, &ref)
        if status == noErr { registered = hk }
        return status == noErr
    }

    func unregister() {
        if let r = ref { UnregisterEventHotKey(r) }
        ref = nil; registered = nil
    }
}

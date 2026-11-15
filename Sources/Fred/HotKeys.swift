import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`.
///
/// This is still the only global-hotkey API that needs no privacy permission. The
/// handler runs on the main thread (application event target), synchronously, as early
/// as the OS can deliver it.
@MainActor
enum HotKeys {
    private static var handlers: [() -> Void] = []
    private static var installed = false

    /// Registers `keyCode` + Carbon `modifiers` (cmdKey, optionKey, shiftKey, controlKey).
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, _ handler: @escaping () -> Void) -> Bool {
        installIfNeeded()
        let id = UInt32(handlers.count)
        handlers.append(handler)
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4652_4544) /* 'FRED' */, id: id)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID,
                                         GetApplicationEventTarget(), 0, &ref)
        return status == noErr
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            MainActor.assumeIsolated {
                let i = Int(hk.id)
                if i < HotKeys.handlers.count { HotKeys.handlers[i]() }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

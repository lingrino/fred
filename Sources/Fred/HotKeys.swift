import Carbon.HIToolbox

/// Global hotkeys via Carbon `RegisterEventHotKey`.
///
/// This is still the only global-hotkey API that needs no privacy permission. The
/// handler runs on the main thread (application event target), synchronously, as early
/// as the OS can deliver it.
@MainActor
enum HotKeys {
    private static var handlers: [(Double) -> Void] = []
    private static var installed = false

    /// Registration state per hotkey, for `fredctl stats`.
    private(set) static var status: [String] = []

    /// Registers `keyCode` + Carbon `modifiers` (cmdKey, optionKey, shiftKey, controlKey).
    /// The handler receives the event's timestamp (for hotkey→shown latency).
    ///
    /// A combination is exclusive: if another app holds it (e.g. Spotlight or another launcher on
    /// ⌘Space), registration fails. Fred then keeps retrying every 2 s, so quitting the
    /// other app (or switching its hotkey off) hands the key to Fred without a restart.
    @discardableResult
    static func register(keyCode: Int, modifiers: Int, _ handler: @escaping (_ eventTime: Double) -> Void) -> Bool {
        installIfNeeded()
        let id = UInt32(handlers.count)
        handlers.append(handler)
        status.append("pending")
        return attempt(id: id, keyCode: keyCode, modifiers: modifiers)
    }

    private static func attempt(id: UInt32, keyCode: Int, modifiers: Int) -> Bool {
        var ref: EventHotKeyRef?
        let hkID = EventHotKeyID(signature: OSType(0x4652_4544) /* 'FRED' */, id: id)
        let st = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hkID, GetApplicationEventTarget(), 0, &ref)
        if st == noErr {
            status[Int(id)] = "registered"
            Log.info("hotkey \(id) registered")
            return true
        }
        if status[Int(id)] != "taken by another app, retrying" {
            Log.error("hotkey \(id) unavailable (\(st)); another app holds it — retrying")
        }
        status[Int(id)] = "taken by another app, retrying"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated { _ = attempt(id: id, keyCode: keyCode, modifiers: modifiers) }
        }
        return false
    }

    private static func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let t = GetEventTime(event)   // seconds since boot, same clock as systemUptime
            MainActor.assumeIsolated {
                let i = Int(hk.id)
                if i < HotKeys.handlers.count { HotKeys.handlers[i](t) }
            }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

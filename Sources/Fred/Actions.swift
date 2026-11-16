import AppKit
import Carbon
import FredCore

/// Side effects: opening things, system commands, copying, pasting.
@MainActor
enum Actions {
    static func openApp(path: String) {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: path), configuration: cfg) { _, err in
            if let err { Log.error("open app \(path): \(err)") }
        }
    }

    static func open(url: String) {
        guard let u = URL(string: url) else { return }
        NSWorkspace.shared.open(u)
    }

    static func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ s: String) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
    }

    // MARK: System commands

    /// Set FRED_DRY_RUN=1 (or `fredctl dryrun on`) to log instead of executing
    /// destructive commands — used when testing.
    static var dryRun = ProcessInfo.processInfo.environment["FRED_DRY_RUN"] == "1"

    static func run(_ c: Command) {
        if dryRun && c != .quitFred && c != .restartFred && c != .forceQuit && c != .fredSettings {
            Log.info("dry run: \(c.rawValue)")
            return
        }
        switch c {
        case .sleep: sendToLoginWindow(kAESleep)
        case .restart: sendToLoginWindow(kAERestart)          // 'rest': no confirmation dialog
        case .shutDown: sendToLoginWindow(kAEShutDown)        // 'shut': no confirmation dialog
        case .lock: lockScreen()
        case .emptyTrash: emptyTrash()
        case .quitFred: NSApp.terminate(nil)
        case .restartFred: relaunch()
        case .forceQuit, .fredSettings: break   // handled by the launcher
        }
    }

    /// QA1134: Apple events to loginwindow (the "system process"). Sent off-main: if the
    /// Automation consent prompt is pending, AESend blocks until it is answered.
    static func sendToLoginWindow(_ id: AEEventID) {
        DispatchQueue.global(qos: .userInitiated).async { sendToLoginWindowNow(id) }
    }

    nonisolated static func sendToLoginWindowNow(_ id: AEEventID) {
        var psn = ProcessSerialNumber(highLongOfPSN: 0, lowLongOfPSN: UInt32(kSystemProcess))
        let target = NSAppleEventDescriptor(descriptorType: typeProcessSerialNumber, bytes: &psn,
                                            length: MemoryLayout<ProcessSerialNumber>.size)
        let ev = NSAppleEventDescriptor.appleEvent(withEventClass: kCoreEventClass, eventID: id,
                                                   targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                                   transactionID: AETransactionID(kAnyTransactionID))
        do { try ev.sendEvent(options: [.noReply], timeout: 10) } catch { Log.error("loginwindow event: \(error)") }
    }

    /// SACLockScreenImmediate from the private login.framework — what the menu bar's
    /// "Lock Screen" uses. No permission needed.
    static func lockScreen() {
        typealias Fn = @convention(c) () -> Int32
        guard let h = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY),
              let sym = dlsym(h, "SACLockScreenImmediate") else { Log.error("lock: symbol missing"); return }
        _ = unsafeBitCast(sym, to: Fn.self)()
    }

    /// Asks Finder (Automation permission). Checks emptiness first: emptying an empty
    /// Trash can hang on recent macOS. Off main (a pending consent prompt blocks the
    /// send), on one serial queue: NSAppleScript isn't thread-safe.
    static func emptyTrash() {
        scriptQueue.async {
            let src = """
            tell application "Finder"
                if (count of items in trash) > 0 then empty trash
            end tell
            """
            var err: NSDictionary?
            NSAppleScript(source: src)?.executeAndReturnError(&err)
            if let err { Log.error("empty trash: \(err)") }
        }
    }

    /// Starts the bundle again once this process is gone: `open` while it still runs
    /// would only re-activate it. (The single-instance lock is close-on-exec, so the
    /// helper doesn't inherit it.)
    private static let scriptQueue = DispatchQueue(label: "fred.applescript", qos: .userInitiated)

    static func relaunch() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.05; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundlePath]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: Paste

    /// Posts ⌘V to whatever app has keyboard focus. Needs "Device Control and Data
    /// Access" (Accessibility / PostEvent). Flags are set explicitly so held modifiers
    /// (e.g. ⇧ from the ⌘⇧C hotkey) don't leak into the paste.
    static func postPaste() {
        guard CGPreflightPostEventAccess() else { missingPostEvent("paste"); return }
        let src = CGEventSource(stateID: .combinedSessionState)
        src?.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents, .permitSystemDefinedEvents],
                                                         state: .eventSuppressionStateSuppressionInterval)
        let v = CGKeyCode(keyCodeForV())
        let down = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// Types `text` into whatever has keyboard focus, without touching the clipboard:
    /// keyboard events carrying a Unicode string (≤ 20 UTF-16 units each — the limit of
    /// CGEventKeyboardSetUnicodeString), split on character boundaries. Needs the same
    /// PostEvent permission as ⌘V.
    static func typeText(_ text: String) {
        guard CGPreflightPostEventAccess() else { missingPostEvent("type"); return }
        let src = CGEventSource(stateID: .combinedSessionState)
        var chunk: [UniChar] = []
        func flush() {
            guard !chunk.isEmpty else { return }
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down) else { continue }
                e.flags = []
                chunk.withUnsafeBufferPointer { e.keyboardSetUnicodeString(stringLength: $0.count, unicodeString: $0.baseAddress) }
                e.post(tap: .cgSessionEventTap)
            }
            chunk.removeAll(keepingCapacity: true)
        }
        for ch in text {
            let u = Array(String(ch).utf16)
            if chunk.count + u.count > 20 { flush() }
            chunk += u
        }
        flush()
    }

    /// Without the grant nothing reaches the app: say so (the value is still on the
    /// clipboard for ⌘V by hand; Fred Settings shows which grant is missing).
    private static func missingPostEvent(_ what: String) {
        Log.error("\(what): no PostEvent permission (Accessibility)")
        NSSound.beep()
    }

    /// Key code that produces "v" in the current layout (Dvorak etc.), default ANSI V.
    static func keyCodeForV() -> Int {
        guard let src = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return kVK_ANSI_V }
        let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> Int in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return kVK_ANSI_V }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var len = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let st = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, 4, &len, &chars)
                if st == noErr && len == 1 && chars[0] == UniChar(UInt8(ascii: "v")) { return code }
            }
            return kVK_ANSI_V
        }
    }
}

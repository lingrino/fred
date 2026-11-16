import AppKit

/// Fred's NSApplication. Its only job: hand plain key-downs aimed at a Fred panel
/// straight to the query field's fast path. Normal NSApplication/NSWindow dispatch
/// costs ~100 µs per keystroke before the field sees the key. ⌘-combos and anything
/// the fast path declines take the normal route.
final class FredApplication: NSApplication {
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown {
            KeyTiming.received = nowNanos()
            KeyTiming.eventTime = e.timestamp
            if !e.modifierFlags.contains(.command), let p = keyWindow as? FloatingPanel,
               let f = p.firstResponder as? QueryField, f.handleFast(e) {
                return
            }
        }
        super.sendEvent(e)
    }
}

/// Timestamps of the key event being handled (instrumentation; see Launcher stats).
@MainActor enum KeyTiming {
    static var received: UInt64 = 0
    static var eventTime: Double = 0
}

/// One Fred per user: a second process (a dev binary run directly, a second copy of the
/// app) would append to the same logs and fight over the hotkeys. The lock is held for the
/// life of the process; a restart overlapping the old process's exit waits for it.
enum SingleInstance {
    static func acquire() -> Bool {
        let fd = open(Engine.dataDir.appendingPathComponent("fred.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return true }   // can't lock: run anyway rather than not at all
        for _ in 0..<60 {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return true }
            usleep(50_000)
        }
        close(fd)
        return false
    }
}

// Entry point. No NIB, no storyboard, no NSApplicationMain: the fewer moving parts
// between exec and a ready hotkey, the faster cold start is.
signal(SIGPIPE, SIG_IGN)   // a vanished socket peer is an error return, never a crash
guard SingleInstance.acquire() else {
    Log.error("another Fred is already running; exiting")
    exit(0)
}
let app = FredApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// `--regular` (debug only): show a Dock icon so UI automation tools can see Fred.
app.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
app.run()

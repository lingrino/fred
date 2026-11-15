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

// Entry point. No NIB, no storyboard, no NSApplicationMain: the fewer moving parts
// between exec and a ready hotkey, the faster cold start is.
let app = FredApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// `--regular` (debug only): show a Dock icon so UI automation tools can see Fred.
app.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
app.run()

import AppKit

// Entry point. No NIB, no storyboard, no NSApplicationMain: the fewer moving parts
// between exec and a ready hotkey, the faster cold start is.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
// `--regular` (debug only): show a Dock icon so UI automation tools can see Fred.
app.setActivationPolicy(CommandLine.arguments.contains("--regular") ? .regular : .accessory)
app.run()

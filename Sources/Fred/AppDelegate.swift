import AppKit
import Carbon.HIToolbox

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: SpikePanel!

    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = SpikePanel()
        let ok = HotKeys.register(keyCode: kVK_Space, modifiers: optionKey) { [unowned self] in
            self.panel.toggle()
        }
        NSLog("fred: hotkey registered=\(ok)")
    }
}

/// Temporary spike: proves non-activating key panel + glass + hotkey on this macOS.
@MainActor
final class SpikePanel: NSPanel, NSWindowDelegate {
    let field = NSTextField()

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 680, height: 64),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        delegate = self

        let glass = NSGlassEffectView(frame: NSRect(x: 0, y: 0, width: 680, height: 64))
        glass.cornerRadius = 24
        let content = NSView(frame: glass.bounds)
        field.frame = NSRect(x: 20, y: 14, width: 640, height: 36)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 26, weight: .light)
        field.placeholderString = "Fred"
        content.addSubview(field)
        glass.contentView = content
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    func toggle() {
        if isVisible { orderOut(nil); return }
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.maxY - f.height * 0.22 - frame.height))
        }
        makeKeyAndOrderFront(nil)
        makeFirstResponder(field)
    }

    func windowDidResignKey(_ notification: Notification) { orderOut(nil) }

    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

import AppKit

/// Shared look for Fred's floating panels (launcher and clipboard).
///
/// A borderless, non-activating NSPanel: it becomes key (gets the keyboard) without
/// activating Fred, so the app you were in stays frontmost — which is exactly what
/// paste-into-front-app needs, and avoids an app activation on every show.
/// Built once at launch and kept alive; showing is just `orderFront`.
@MainActor
class FloatingPanel: NSPanel {
    /// UI lives here, above the backdrop (not inside it), so backdrop changes never touch it.
    let content = FlippedView()
    var onResignKey: (() -> Void)?
    /// Sees ⌘-key equivalents first (⌘1…⌘9, ⌘↩, ⌘O…). Return true if handled.
    var keyHandler: ((NSEvent) -> Bool)?

    /// The window never changes size (resizing a window costs 1.3–2.6 ms: new backing
    /// store, window-server round trip): it is `maxHeight` tall and transparent, and only
    /// the backdrop's visible height changes.
    let maxHeight: CGFloat
    private let root = FlippedView()
    private var backdropView: NSView!
    /// Glass: the rounded mask that decides how much of the full-height glass shows.
    private var glassMask: CALayer?

    /// Backdrop, decided by an on-screen A/B on 2026-11-15 (`fredctl hotkeybench`, p50 of
    /// 30 real ⌘Space shows each): Liquid Glass — one full-height NSGlassEffectView that
    /// is never resized (resizing re-renders it, ~1 ms), clipped by a mask layer whose
    /// height moves instead. Show 5.3–6.4 ms vs 3.4–3.6 ms with vibrancy over five runs
    /// (the glass re-renders on the key-state change: commit ~3 vs 0.7 ms); keystrokes
    /// cost the same (~2 ms incl. OS delivery). Both are under one 120 Hz frame.
    /// The user prefers glass at that price. Fallback, no rebuild needed:
    /// `defaults write dev.fred.Fred debugBackdrop vibrancy` (NSVisualEffectView, state
    /// pinned active so focus changes don't re-render it, resized directly).
    static let vibrancy = UserDefaults.standard.string(forKey: "debugBackdrop") == "vibrancy"
    static var backdrop: String { vibrancy ? "vibrancy" : "glass" }

    init(width: CGFloat, heights: [CGFloat]) {
        maxHeight = heights.max() ?? 64
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: maxHeight),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .statusBar
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        animationBehavior = .none
        isReleasedWhenClosed = false
        isMovable = false

        root.frame = NSRect(x: 0, y: 0, width: width, height: maxHeight)
        root.wantsLayer = true
        if Self.vibrancy {
            let v = NSVisualEffectView(frame: root.bounds)
            v.material = .popover
            v.blendingMode = .behindWindow
            v.state = .active
            v.wantsLayer = true
            v.layer?.cornerRadius = Theme.cornerRadius
            v.layer?.masksToBounds = true
            backdropView = v
        } else {
            let container = FlippedView(frame: root.bounds)
            container.wantsLayer = true
            let ge = NSGlassEffectView(frame: container.bounds)
            ge.style = .regular
            ge.cornerRadius = Theme.cornerRadius
            container.addSubview(ge)
            let m = CALayer.still()
            m.backgroundColor = NSColor.black.cgColor
            m.cornerRadius = Theme.cornerRadius
            container.layer!.mask = m
            glassMask = m
            backdropView = container
        }
        root.addSubview(backdropView)
        content.frame = root.bounds
        content.wantsLayer = true
        root.addSubview(content)
        contentView = root
        setHeight(heights.min() ?? 64)
    }

    /// Never key while parked: an invisible key window would swallow the user's typing.
    override var canBecomeKey: Bool { shown }

    /// Plain key-downs go straight to the query field's fast path, skipping NSWindow's
    /// dispatch (key-equivalent scans, input-context setup): ~100 µs per keystroke.
    /// ⌘-combos still take the normal route so performKeyEquivalent sees them first.
    override func sendEvent(_ e: NSEvent) {
        if e.type == .keyDown, !e.modifierFlags.contains(.command),
           let f = firstResponder as? QueryField, f.handleFast(e) { return }
        super.sendEvent(e)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let h = keyHandler, h(event) { return true }
        if Self.editingKeyEquivalent(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Fred has no Edit menu, which is what normally maps ⌘A/⌘C/⌘X/⌘V/⌘Z to the focused
    /// text field. Route them to the first responder (the field editor) ourselves.
    static func editingKeyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let ch = e.charactersIgnoringModifiers?.lowercased() else { return false }
        let sel: Selector? = switch (ch, mods.contains(.shift)) {
        case ("a", false): #selector(NSText.selectAll(_:))
        case ("c", false): #selector(NSText.copy(_:))
        case ("x", false): #selector(NSText.cut(_:))
        case ("v", false): #selector(NSText.paste(_:))
        case ("z", false): Selector(("undo:"))
        case ("z", true): Selector(("redo:"))
        default: nil
        }
        guard let sel else { return false }
        return NSApp.sendAction(sel, to: nil, from: nil)
    }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    // MARK: Showing without re-rendering the glass
    //
    // Ordering a window out discards its rendered state; on the next order-in, the
    // NSGlassEffectView rebuilds — measured ~10 ms on the show path. So the panel is
    // only ordered out for an instant on hide (that is what hands keyboard focus back to
    // the previous app), then ordered straight back in invisible and click-through.
    // Showing is then just: alpha 1, accept mouse, become key.

    private(set) var shown = false

    /// Visible + key. The panel is normally already ordered in (parked).
    func present() {
        shown = true
        alphaValue = 1
        ignoresMouseEvents = false
        if !isVisible { orderFrontRegardless() }
        makeKey()
    }

    /// Invisible, not key, still ordered in so its layers (and the glass) stay rendered.
    func park() {
        shown = false
        if isKeyWindow || isVisible { orderOut(nil) }   // gives key focus back
        alphaValue = 0
        ignoresMouseEvents = true
        orderFrontRegardless()
    }

    /// Places the panel horizontally centered, its top edge at a fixed fraction of the
    /// screen under the mouse; the glass starts at the top and grows downward.
    func position(height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        let top = f.maxY - f.height * Theme.topFraction
        setFrameOrigin(NSPoint(x: (f.midX - frame.width / 2).rounded(), y: (top - maxHeight).rounded()))
        setHeight(height)
    }

    /// Visible height of the backdrop (the panel's apparent height).
    var glassHeight: CGFloat { glassMask?.frame.height ?? backdropView.frame.height }

    func setHeight(_ h: CGFloat) {
        let h = min(h, maxHeight)
        if let m = glassMask {
            guard abs(m.frame.height - h) > 0.5 else { return }
            m.frame = CGRect(x: 0, y: 0, width: frame.width, height: h)
        } else {
            guard abs(backdropView.frame.height - h) > 0.5 else { return }
            backdropView.frame = NSRect(x: 0, y: 0, width: frame.width, height: h)
        }
        invalidateShadow()
    }

    /// Pays the backdrop's first-render cost at launch (call while ordered in, invisible).
    func warmBackdrop() {
        displayIfNeeded()
        CATransaction.flush()
    }
}

/// Top-left origin view: all of Fred's layout code thinks top-down.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// `--regular` dev mode: Fred has a Dock icon and activates when a panel shows, so UI
/// automation (which only types into the frontmost app) can drive it. Never in normal use.
enum DevMode {
    static let regular = CommandLine.arguments.contains("--regular")
}

enum Theme {
    static let width: CGFloat = 680
    static let cornerRadius: CGFloat = 24
    static let topFraction: CGFloat = 0.22
    static let fieldHeight: CGFloat = 60
    nonisolated(unsafe) static let fieldFont = NSFont.systemFont(ofSize: 25, weight: .regular)
    static let rowHeight: CGFloat = 48
    static let iconSize: CGFloat = 32
    nonisolated(unsafe) static let rowFont = NSFont.systemFont(ofSize: 17, weight: .regular)
    nonisolated(unsafe) static let detailFont = NSFont.systemFont(ofSize: 13)
    static let rowInset: CGFloat = 8          // horizontal inset of the selection pill
    static let listPadding: CGFloat = 6       // above/below the rows
    static let maxRows = 5
}

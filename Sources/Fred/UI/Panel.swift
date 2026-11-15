import AppKit

/// Shared look for Fred's floating panels (launcher and clipboard).
///
/// A borderless, non-activating NSPanel: it becomes key (gets the keyboard) without
/// activating Fred, so the app you were in stays frontmost — which is exactly what
/// paste-into-front-app needs, and avoids an app activation on every show.
/// Built once at launch and kept alive; showing is just `orderFront`.
@MainActor
class FloatingPanel: NSPanel {
    /// UI lives here, above the glass (not inside it) so swapping glass views never
    /// touches it.
    let content = FlippedView()
    var onResignKey: (() -> Void)?
    /// Sees ⌘-key equivalents first (⌘1…⌘9, ⌘↩, ⌘O…). Return true if handled.
    var keyHandler: ((NSEvent) -> Bool)?

    /// The window never changes size: it is `maxHeight` tall and transparent.
    /// Height changes swap between pre-built glass views, one per possible height.
    ///
    /// Measured: resizing a window costs 1.3–2.6 ms (new backing store, window-server
    /// round trip); resizing an NSGlassEffectView costs ~1.1 ms of CPU in
    /// displayIfNeeded (it re-renders its shape). Toggling `isHidden` on an already-built
    /// glass view costs neither.
    let maxHeight: CGFloat
    private let root = FlippedView()
    private var glasses: [(height: CGFloat, view: NSView)] = []
    private var singleResizable = false
    private var current: NSView?
    /// Backdrop A/B (`defaults write dev.fred.Fred debugBackdrop <name>`): "vibrancy"
    /// (default: NSVisualEffectView, state pinned active), "glass" (NSGlassEffectView per
    /// height), "oneglass", "plain".
    ///
    /// Why not Liquid Glass by default: measured on this Mac, NSGlassEffectView re-renders
    /// on every key-state change (~10 ms in displayIfNeeded each time the panel shows) and
    /// ~1 ms per resize. Vibrancy: hotkey→committed 2.2 ms vs 13 ms with glass.
    static let backdrop = UserDefaults.standard.string(forKey: "debugBackdrop") ?? "vibrancy"

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
        // Glass re-renders when resized, so it gets one pre-built view per height.
        // Vibrancy resizes cheaply: one view, resized.
        singleResizable = Self.backdrop == "vibrancy" || Self.backdrop == "plain"
        let hs = Self.backdrop == "oneglass" || singleResizable ? [heights.max() ?? 64] : Array(Set(heights)).sorted()
        for h in hs {
            let frame = NSRect(x: 0, y: 0, width: width, height: h)
            let g: NSView
            if Self.backdrop == "plain" {
                g = NSView(frame: frame)
                g.wantsLayer = true
                g.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                g.layer?.cornerRadius = Theme.cornerRadius
            } else if Self.backdrop == "vibrancy" {
                let v = NSVisualEffectView(frame: frame)
                v.material = .popover
                v.blendingMode = .behindWindow
                v.state = .active          // same look key or not: no re-render on focus change
                v.wantsLayer = true
                v.layer?.cornerRadius = Theme.cornerRadius
                v.layer?.masksToBounds = true
                g = v
            } else {
                let ge = NSGlassEffectView(frame: frame)
                ge.style = .regular
                ge.cornerRadius = Theme.cornerRadius
                g = ge
            }
            g.isHidden = true
            root.addSubview(g)
            glasses.append((h, g))
        }
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
    // NSGlassEffectViews rebuild — measured ~10 ms on the show path. So the panel is
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

    var glassHeight: CGFloat { current?.frame.height ?? 0 }

    /// Shows the glass whose height is the smallest one ≥ `h`.
    func setHeight(_ h: CGFloat) {
        if singleResizable, let g = glasses.first?.view {
            if current !== g { g.isHidden = false; current = g }
            guard abs(g.frame.height - h) > 0.5 else { return }
            g.frame = NSRect(x: 0, y: 0, width: frame.width, height: min(h, maxHeight))
            invalidateShadow()
            return
        }
        guard let g = (glasses.first { $0.height >= h - 0.5 } ?? glasses.last)?.view, g !== current else { return }
        g.isHidden = false
        current?.isHidden = true
        current = g
        invalidateShadow()
    }

    /// Pays each glass view's first-render cost once (call while ordered in, invisible).
    func warmGlasses() {
        for (_, g) in glasses {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            current?.isHidden = true; g.isHidden = false; current = g
            CATransaction.commit()
            displayIfNeeded()
            CATransaction.flush()
        }
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

import AppKit

/// Shared look for Fred's floating panels (launcher and clipboard).
///
/// A borderless, non-activating NSPanel: it becomes key (gets the keyboard) without
/// activating Fred, so the app you were in stays frontmost — which is exactly what
/// paste-into-front-app needs, and avoids an app activation on every show.
/// Built once at launch and kept alive; showing is just `orderFront`.
@MainActor
class FloatingPanel: NSPanel {
    let glass = NSGlassEffectView()
    let content = FlippedView()
    var onResignKey: (() -> Void)?
    /// Sees ⌘-key equivalents first (⌘1…⌘9, ⌘↩, ⌘O…). Return true if handled.
    var keyHandler: ((NSEvent) -> Bool)?

    init(width: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: width, height: 64),
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

        glass.style = .regular
        glass.cornerRadius = Theme.cornerRadius
        glass.frame = NSRect(x: 0, y: 0, width: width, height: 64)
        glass.autoresizingMask = [.width, .height]
        content.frame = glass.bounds
        content.autoresizingMask = [.width, .height]
        glass.contentView = content
        contentView = glass
    }

    override var canBecomeKey: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let h = keyHandler, h(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Places the panel horizontally centered, its top edge at a fixed fraction of the
    /// screen under the mouse — the top stays put while height changes with results.
    func position(height: CGFloat) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        let top = f.maxY - f.height * Theme.topFraction
        setFrame(NSRect(x: (f.midX - frame.width / 2).rounded(), y: (top - height).rounded(),
                        width: frame.width, height: height), display: false)
    }

    /// Changes height keeping the top edge fixed.
    func setHeight(_ h: CGFloat) {
        guard abs(frame.height - h) > 0.5 else { return }
        var f = frame
        f.origin.y += f.height - h
        f.size.height = h
        setFrame(f, display: true)
    }
}

/// Top-left origin view: all of Fred's layout code thinks top-down.
class FlippedView: NSView {
    override var isFlipped: Bool { true }
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

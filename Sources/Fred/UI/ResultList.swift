import AppKit
import QuartzCore

/// The result rows: a fixed pool of rows created once, re-filled per keystroke.
///
/// Rows are plain layer trees (`RowLayer`), not views, and only change the layers whose
/// content or selection state changed — typically 1–5 rows per keystroke. Icons are
/// sub-images of the shared icon atlas, titles masks into the title atlas. No Auto
/// Layout, no table view, no implicit animations.
@MainActor
final class ResultList: FlippedView {
    struct Row: Equatable {
        var title: String
        var detail: String? = nil      // right-aligned secondary text (e.g. contact field label)
        var icon: Icon
        /// Catalog item whose pre-rendered title (TitleAtlas) can be used instead of
        /// rasterizing `title` now.
        var titleItem: Int? = nil
    }

    enum Icon: Equatable {
        case atlas(Int32)
        case image(CGImage)
        case none
        static func == (a: Icon, b: Icon) -> Bool {
            switch (a, b) {
            case (.atlas(let x), .atlas(let y)): x == y
            case (.image(let x), .image(let y)): x === y
            case (.none, .none): true
            default: false
            }
        }
    }

    let capacity: Int
    let rowHeight: CGFloat
    private var rowViews: [RowLayer] = []
    private(set) var rows: [Row] = []
    private(set) var selected = 0
    var atlas: IconAtlas? { didSet { for r in rowViews { r.atlas = atlas } } }
    var titles: TitleAtlas? { didSet { for r in rowViews { r.titles = titles } } }
    var onClick: ((Int) -> Void)?
    /// Called after the mouse moved onto a different row and selected it.
    var onHover: ((Int) -> Void)?
    private var lastMouse: NSPoint?

    init(capacity: Int, rowHeight: CGFloat = Theme.rowHeight, width: CGFloat) {
        self.capacity = capacity
        self.rowHeight = rowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(capacity) * rowHeight))
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        for i in 0..<capacity {
            let v = RowLayer(frame: CGRect(x: 0, y: CGFloat(i) * rowHeight, width: width, height: rowHeight), host: self)
            v.root.isHidden = true
            layer!.addSublayer(v.root)
            rowViews.append(v)
        }
    }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        for r in rowViews { r.appearanceChanged() }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        for r in rowViews { r.appearanceChanged() }
    }

    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { CGFloat(rows.count) * rowHeight }

    func set(_ new: [Row], selected sel: Int) {
        rows = new
        selected = new.isEmpty ? 0 : max(0, min(sel, new.count - 1))
        for i in 0..<capacity {
            let v = rowViews[i]
            if i < new.count {
                v.update(new[i], selected: i == selected)
                if v.root.isHidden { v.root.isHidden = false }
            } else if !v.root.isHidden {
                v.root.isHidden = true
            }
        }
    }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let new = max(0, min(i, rows.count - 1))
        guard new != selected else { return }
        rowViews[selected].setSelected(false)
        rowViews[new].setSelected(true)
        selected = new
    }

    // MARK: Hover selects
    //
    // Only real pointer movement selects a row: rows changing under a still pointer
    // (typing) don't move the selection, and sub-2-pt jitter is ignored.

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty {
            addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                           owner: self, userInfo: nil))
        }
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let last = lastMouse, abs(p.x - last.x) < 2, abs(p.y - last.y) < 2 { return }
        lastMouse = p
        guard let i = row(at: p), i != selected else { return }
        select(i)
        onHover?(i)
    }

    override func mouseDown(with event: NSEvent) {
        if let i = row(at: convert(event.locationInWindow, from: nil)) {
            select(i)
            onClick?(i)
        }
    }

    // Rows don't take clicks themselves; the list handles them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Row index at a point in this view's coordinates (for mouse clicks).
    func row(at p: NSPoint) -> Int? {
        let i = Int(p.y / rowHeight)
        return i >= 0 && i < rows.count ? i : nil
    }
}

/// One result row as a layer tree (no NSView: toggling/updating rows never enters
/// AppKit's view machinery): selection pill (GPU), icon (atlas sub-image, GPU), title
/// (pre-rendered mask from TitleAtlas, or a small CGImage rendered on the spot) and
/// optional right-aligned detail text.
@MainActor
final class RowLayer {
    let root = CALayer.still()
    private unowned let host: NSView
    private var row: ResultList.Row?
    private var isSelected = false
    private let pill = CALayer.still()
    private let iconLayer = CALayer.still()
    private let titleLayer = CALayer.still()
    private let detailLayer = CALayer.still()
    private let titleMask = CALayer.still()
    var atlas: IconAtlas? { didSet { applyIcon() } }
    var titles: TitleAtlas? { didSet { renderText() } }

    init(frame: CGRect, host: NSView) {
        self.host = host
        root.frame = frame
        pill.cornerRadius = 12
        pill.isHidden = true
        pill.frame = CGRect(x: Theme.rowInset, y: 0, width: frame.width - 2 * Theme.rowInset, height: frame.height)
        iconLayer.frame = CGRect(x: Theme.rowInset + 10, y: ((frame.height - Theme.iconSize) / 2).rounded(),
                                 width: Theme.iconSize, height: Theme.iconSize)
        iconLayer.contentsGravity = .resizeAspect
        iconLayer.minificationFilter = .trilinear
        titleMask.contentsGravity = .resize
        for l in [pill, iconLayer, titleLayer, detailLayer] { root.addSublayer(l) }
    }

    private var bounds: CGRect { root.bounds }
    private var effectiveAppearance: NSAppearance { host.effectiveAppearance }

    func appearanceChanged() {
        applyPillColor()
        renderText()
    }

    func update(_ r: ResultList.Row, selected: Bool) {
        guard r != row || selected != isSelected else { return }
        let iconChanged = r.icon != row?.icon
        let textChanged = r.title != row?.title || r.detail != row?.detail || r.titleItem != row?.titleItem
            || selected != isSelected
        row = r
        isSelected = selected
        pill.isHidden = !selected
        if selected { applyPillColor() }
        if iconChanged { applyIcon() }
        if textChanged { renderText() }
    }

    func setSelected(_ s: Bool) {
        guard s != isSelected else { return }
        isSelected = s
        pill.isHidden = !s
        if s { applyPillColor() }
        renderText()
    }

    private func applyPillColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            pill.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor
        }
    }

    private func applyIcon() {
        switch row?.icon {
        case .atlas(let slot)?: iconLayer.contents = atlas?.image(slot)
        case .image(let img)?: iconLayer.contents = img
        default: iconLayer.contents = nil
        }
    }

    private func renderText() {
        guard let row, let scale = host.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor else { return }
        let ap = effectiveAppearance
        let textX = Theme.rowInset + 10 + Theme.iconSize + 12
        var maxTitle = bounds.width - textX - Theme.rowInset - 14
        if let d = row.detail {
            let dc: NSColor = isSelected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
            let r = TextImage.render(d, font: Theme.detailFont, color: dc, scale: scale, appearance: ap)
            detailLayer.contents = r.image
            detailLayer.contentsScale = scale
            detailLayer.frame = CGRect(x: bounds.width - Theme.rowInset - 14 - r.size.width,
                                       y: ((bounds.height - r.size.height) / 2).rounded(), width: r.size.width, height: r.size.height)
            maxTitle -= r.size.width + 16
        } else {
            detailLayer.contents = nil
        }
        let tc: NSColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        // Pre-rendered mask (color is just the layer's background) whenever it fits: titles
        // in the atlas are cut at the full row width, so next to a detail ("True Tone" ·
        // Displays) only one that is short enough can be used.
        if let item = row.titleItem, let t = titles, t.has(item), t.scale == scale, t.size(item).width <= maxTitle + 0.5 {
            let size = t.size(item)
            ap.performAsCurrentDrawingAppearance { titleLayer.backgroundColor = tc.cgColor }
            titleLayer.contents = nil
            titleLayer.frame = CGRect(x: textX, y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
            if titleMask.contents as! CGImage? !== t.image { titleMask.contents = t.image }
            titleMask.contentsRect = t.contentsRect(item)
            titleMask.frame = CGRect(origin: .zero, size: size)
            if titleLayer.mask !== titleMask { titleLayer.mask = titleMask }
            return
        }
        titleLayer.mask = nil
        titleLayer.backgroundColor = nil
        let r = TextImage.render(row.title, font: Theme.rowFont, color: tc, maxWidth: maxTitle, scale: scale, appearance: ap)
        titleLayer.contents = r.image
        titleLayer.contentsScale = scale
        titleLayer.frame = CGRect(x: textX, y: ((bounds.height - r.size.height) / 2).rounded(), width: r.size.width, height: r.size.height)
    }
}

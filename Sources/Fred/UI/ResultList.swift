import AppKit
import QuartzCore

/// The result rows: a fixed pool of row views created once, re-filled per keystroke.
///
/// Each row draws itself (selection pill, icon, Core Text title) in `draw(_:)` and only
/// redraws when its content or selection state changes — typically 1–5 small rows per
/// keystroke. Icons are zero-copy sub-images of the shared atlas. No Auto Layout, no
/// table view, no implicit animations.
@MainActor
final class ResultList: FlippedView {
    struct Row: Equatable {
        var title: String
        var detail: String? = nil      // right-aligned secondary text (e.g. contact field label)
        var icon: Icon
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
    private var rowViews: [RowView] = []
    private(set) var rows: [Row] = []
    private(set) var selected = 0
    var atlas: IconAtlas? { didSet { for r in rowViews { r.atlas = atlas } } }
    var onClick: ((Int) -> Void)?

    init(capacity: Int, rowHeight: CGFloat = Theme.rowHeight, width: CGFloat) {
        self.capacity = capacity
        self.rowHeight = rowHeight
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: CGFloat(capacity) * rowHeight))
        wantsLayer = true
        for i in 0..<capacity {
            let v = RowView(frame: NSRect(x: 0, y: CGFloat(i) * rowHeight, width: width, height: rowHeight))
            v.isHidden = true
            addSubview(v)
            rowViews.append(v)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var height: CGFloat { CGFloat(rows.count) * rowHeight }

    func set(_ new: [Row], selected sel: Int) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rows = new
        selected = new.isEmpty ? 0 : max(0, min(sel, new.count - 1))
        for i in 0..<capacity {
            let v = rowViews[i]
            if i < new.count {
                v.update(new[i], selected: i == selected)
                if v.isHidden { v.isHidden = false }
            } else if !v.isHidden {
                v.isHidden = true
            }
        }
        CATransaction.commit()
    }

    func select(_ i: Int) {
        guard !rows.isEmpty else { return }
        let new = max(0, min(i, rows.count - 1))
        guard new != selected else { return }
        rowViews[selected].setSelected(false)
        rowViews[new].setSelected(true)
        selected = new
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

/// One result row, fully self-drawn.
@MainActor
final class RowView: FlippedView {
    private var row: ResultList.Row?
    private var isSelected = false
    private var titleLine: CTLine?
    private var detailLine: CTLine?
    private var icon: CGImage?
    var atlas: IconAtlas? { didSet { resolveIcon(); needsDisplay = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { false }

    func update(_ r: ResultList.Row, selected: Bool) {
        guard r != row || selected != isSelected else { return }
        let iconChanged = r.icon != row?.icon
        row = r
        isSelected = selected
        rebuildLines()
        if iconChanged { resolveIcon() }
        needsDisplay = true
    }

    func setSelected(_ s: Bool) {
        guard s != isSelected else { return }
        isSelected = s
        rebuildLines()
        needsDisplay = true
    }

    private func resolveIcon() {
        switch row?.icon {
        case .atlas(let slot)?: icon = atlas?.image(slot)
        case .image(let img)?: icon = img
        default: icon = nil
        }
    }

    private var textColor: NSColor { isSelected ? .alternateSelectedControlTextColor : .labelColor }

    private func rebuildLines() {
        guard let row else { titleLine = nil; detailLine = nil; return }
        titleLine = CTLineCreateWithAttributedString(NSAttributedString(string: row.title, attributes: [
            .font: Theme.rowFont, .foregroundColor: textColor,
        ]))
        if let d = row.detail {
            let dc: NSColor = isSelected ? .alternateSelectedControlTextColor.withAlphaComponent(0.8) : .secondaryLabelColor
            detailLine = CTLineCreateWithAttributedString(NSAttributedString(string: d, attributes: [
                .font: Theme.detailFont, .foregroundColor: dc,
            ]))
        } else {
            detailLine = nil
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        if isSelected {
            let pill = NSRect(x: Theme.rowInset, y: 0, width: bounds.width - 2 * Theme.rowInset, height: bounds.height)
            NSColor.controlAccentColor.withAlphaComponent(0.9).setFill()
            NSBezierPath(roundedRect: pill, xRadius: 12, yRadius: 12).fill()
        }
        let iconX = Theme.rowInset + 10
        if let icon {
            let r = CGRect(x: iconX, y: (bounds.height - Theme.iconSize) / 2, width: Theme.iconSize, height: Theme.iconSize)
            ctx.saveGState()
            ctx.interpolationQuality = .high
            // Flipped view: draw the image upright.
            ctx.translateBy(x: 0, y: r.maxY + r.minY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.draw(icon, in: r)
            ctx.restoreGState()
        }
        let textX = iconX + Theme.iconSize + 12
        var maxTitle = bounds.width - textX - Theme.rowInset - 14
        if let d = detailLine {
            let w = CTLineGetTypographicBounds(d, nil, nil, nil)
            maxTitle -= w + 16
            drawLine(d, ctx: ctx, x: bounds.width - Theme.rowInset - 14 - w, font: Theme.detailFont)
        }
        if var t = titleLine {
            if CTLineGetTypographicBounds(t, nil, nil, nil) > maxTitle {
                let ell = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: [
                    .font: Theme.rowFont, .foregroundColor: textColor]))
                if let tr = CTLineCreateTruncatedLine(t, maxTitle, .end, ell) { t = tr }
            }
            drawLine(t, ctx: ctx, x: textX, font: Theme.rowFont)
        }
    }

    private func drawLine(_ line: CTLine, ctx: CGContext, x: CGFloat, font: NSFont) {
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        let baseline = ((bounds.height - (font.ascender - font.descender)) / 2 - font.descender).rounded()
        ctx.textPosition = CGPoint(x: x, y: baseline)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }
}

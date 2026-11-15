import AppKit
import QuartzCore

@MainActor
protocol QueryFieldDelegate: AnyObject {
    func queryFieldDidChange(_ field: QueryField)
    /// Navigation/activation keys. Return true if handled.
    func queryField(_ field: QueryField, command: QueryField.Command) -> Bool
}

/// A single-line text input built for latency.
///
/// Why not NSTextField: measured on this Mac, AppKit's field editor path (key event →
/// input context → TextKit → controlTextDidChange) costs ~3.7 ms per keystroke, more than
/// everything else in Fred combined. Here, printable keys and editing keys are handled
/// directly in `keyDown` (no input-context round trip), and the text is one Core Text
/// line drawn into this view's layer. The caret is a separate layer whose blink is a
/// Core Animation animation (no timers, no redraws).
///
/// Anything the fast path doesn't recognize (dead keys like ⌥e, input methods, the emoji
/// picker, dictation) goes through the system input context via `NSTextInputClient`, so
/// composed input still works — just without the shortcut.
///
/// Text is kept as UTF-16 (NSMutableString) because NSTextInputClient speaks NSRange.
@MainActor
final class QueryField: NSView, @preconcurrency NSTextInputClient {
    enum Command { case up, down, pageUp, pageDown, enter, commandEnter, escape, tab }

    weak var delegate: QueryFieldDelegate?
    var font: NSFont = Theme.fieldFont { didSet { relayout() } }
    var placeholder = "" { didSet { if placeholder != oldValue { renderPlaceholder() } } }

    private let storage = NSMutableString()
    private var selection = NSRange(location: 0, length: 0)
    private var marked = NSRange(location: NSNotFound, length: 0)
    private var line: CTLine?
    private var scrollX: CGFloat = 0
    private let caret = CALayer.still()
    private let textLayer = CALayer.still()
    private let selectionLayer = CALayer.still()
    private let placeholderLayer = CALayer.still()
    private var undoStack: [(String, NSRange)] = []
    private var redoStack: [(String, NSRange)] = []

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        layer!.actions = CALayer.still().actions
        for l in [selectionLayer, placeholderLayer, textLayer, caret] { layer!.addSublayer(l) }
        setAccessibilityRole(.textField)
        setAccessibilityElement(true)
        relayout()
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override func accessibilityValue() -> Any? { storage as String }
    override func becomeFirstResponder() -> Bool { caret.isHidden = false; restartBlink(); return true }
    override func resignFirstResponder() -> Bool { caret.isHidden = true; return true }

    // MARK: Public text API

    var text: String {
        get { storage as String }
        set {
            storage.setString(newValue)
            selection = NSRange(location: storage.length, length: 0)
            marked = NSRange(location: NSNotFound, length: 0)
            undoStack.removeAll(); redoStack.removeAll()
            relayout()
        }
    }

    func selectAll() { selection = NSRange(location: 0, length: storage.length); relayout() }

    // MARK: Keyboard

    /// Instrumentation (fredctl stats): when keyDown was entered / text render cost.
    static var keyDownAt: UInt64 = 0
    static let renderCost = LatencyLog("  stage: field text render")
    static let relayoutCost = LatencyLog("  stage: field relayout total")
    static let blinkCost = LatencyLog("  stage: field caret blink restart")
    static let replaceCost = LatencyLog("  stage: field replace (pre-relayout)")

    /// Entry point from FloatingPanel.sendEvent. Returns false to let AppKit continue.
    func handleFast(_ event: NSEvent) -> Bool {
        Self.keyDownAt = nowNanos()
        return fastPath(event)
    }

    override func keyDown(with event: NSEvent) {
        Self.keyDownAt = nowNanos()
        if fastPath(event) { return }
        // Composed input (dead keys, IME, emoji): the system input context calls back
        // into insertText/setMarkedText/doCommand.
        if inputContext?.handleEvent(event) != true { interpretKeyEvents([event]) }
    }

    /// Handles everything a launcher query needs without leaving this method.
    private func fastPath(_ e: NSEvent) -> Bool {
        if hasMarkedText() { return false }
        let mods = e.modifierFlags.intersection([.command, .option, .control, .shift])
        let shift = mods.contains(.shift)
        switch Int(e.keyCode) {
        case 51:  // delete
            if mods.contains(.command) { deleteTo(0) }
            else if mods.contains(.option) { deleteTo(wordStart(before: selection.location)) }
            else { deleteBackward() }
            return true
        case 117: // forward delete
            if selection.length > 0 { replace(selection, with: "") }
            else if selection.location < storage.length {
                replace(storage.rangeOfComposedCharacterSequence(at: selection.location), with: "")
            }
            return true
        case 123: // ←
            if mods.contains(.command) { move(to: 0, extend: shift) }
            else if mods.contains(.option) { move(to: wordStart(before: caretIndex(left: true, shift)), extend: shift) }
            else { move(to: step(left: true, shift), extend: shift) }
            return true
        case 124: // →
            if mods.contains(.command) { move(to: storage.length, extend: shift) }
            else if mods.contains(.option) { move(to: wordEnd(after: caretIndex(left: false, shift)), extend: shift) }
            else { move(to: step(left: false, shift), extend: shift) }
            return true
        case 115: move(to: 0, extend: shift); return true                 // home
        case 119: move(to: storage.length, extend: shift); return true    // end
        case 126: return command(.up)
        case 125: return command(.down)
        case 116: return command(.pageUp)
        case 121: return command(.pageDown)
        case 36, 76: return command(mods.contains(.command) ? .commandEnter : .enter)
        case 53: return command(.escape)
        case 48: return command(.tab)
        default: break
        }
        if mods == .control, let c = e.charactersIgnoringModifiers {
            switch c {
            case "n": return command(.down)
            case "p": return command(.up)
            case "a": move(to: 0, extend: false); return true
            case "e": move(to: storage.length, extend: false); return true
            case "h": deleteBackward(); return true
            case "w": deleteTo(wordStart(before: selection.location)); return true
            case "u": deleteTo(0); return true
            case "k": replace(NSRange(location: selection.location, length: storage.length - selection.location), with: ""); return true
            default: return false
            }
        }
        // Printable ASCII typed with at most Shift: insert directly.
        guard mods.isSubset(of: [.shift]), let chars = e.characters, chars.utf16.count == 1,
              let u = chars.utf16.first, u >= 0x20 && u < 0x7F else { return false }
        replace(selection, with: chars)
        return true
    }

    private func command(_ c: Command) -> Bool { delegate?.queryField(self, command: c) ?? false }

    // MARK: Editing primitives

    private func replace(_ r: NSRange, with s: String, recordUndo: Bool = true) {
        let t0 = nowNanos()
        defer { _ = t0 }
        if recordUndo {
            undoStack.append((storage as String, selection))
            if undoStack.count > 200 { undoStack.removeFirst() }
            redoStack.removeAll()
        }
        storage.replaceCharacters(in: r, with: s)
        selection = NSRange(location: r.location + (s as NSString).length, length: 0)
        Self.replaceCost.add(nowNanos() - t0)
        changed()
    }

    private func deleteBackward() {
        if selection.length > 0 { replace(selection, with: ""); return }
        guard selection.location > 0 else { return }
        replace(storage.rangeOfComposedCharacterSequence(at: selection.location - 1), with: "")
    }

    private func deleteTo(_ i: Int) {
        if selection.length > 0 { replace(selection, with: ""); return }
        let lo = min(i, selection.location), hi = max(i, selection.location)
        if hi > lo { replace(NSRange(location: lo, length: hi - lo), with: "") }
    }

    /// Anchor for shift-extended selections: the end that isn't moving.
    private var anchor = 0

    private func caretIndex(left: Bool, _ extend: Bool) -> Int {
        if extend { return selection.location == anchor ? NSMaxRange(selection) : selection.location }
        return left ? selection.location : NSMaxRange(selection)
    }

    private func step(left: Bool, _ extend: Bool) -> Int {
        if !extend && selection.length > 0 { return left ? selection.location : NSMaxRange(selection) }
        let i = caretIndex(left: left, extend)
        if left { return i > 0 ? storage.rangeOfComposedCharacterSequence(at: i - 1).location : 0 }
        return i < storage.length ? NSMaxRange(storage.rangeOfComposedCharacterSequence(at: i)) : storage.length
    }

    private func move(to i: Int, extend: Bool) {
        let i = max(0, min(i, storage.length))
        if extend {
            if selection.length == 0 { anchor = selection.location }
            selection = NSRange(location: min(anchor, i), length: abs(i - anchor))
        } else {
            selection = NSRange(location: i, length: 0)
            anchor = i
        }
        relayout()
    }

    private func isSpace(_ i: Int) -> Bool {
        let c = storage.character(at: i)
        return c == 0x20 || c == 0x09 || c == UInt16(UInt8(ascii: "-")) || c == UInt16(UInt8(ascii: "."))
            || c == UInt16(UInt8(ascii: "/")) || c == UInt16(UInt8(ascii: "_"))
    }

    private func wordStart(before i: Int) -> Int {
        var j = i
        while j > 0 && isSpace(j - 1) { j -= 1 }
        while j > 0 && !isSpace(j - 1) { j -= 1 }
        return j
    }

    private func wordEnd(after i: Int) -> Int {
        var j = i
        let n = storage.length
        while j < n && isSpace(j) { j += 1 }
        while j < n && !isSpace(j) { j += 1 }
        return j
    }

    private func changed() {
        relayout()
        delegate?.queryFieldDidChange(self)
    }

    // MARK: Edit menu actions (routed by FloatingPanel's ⌘-key handling)

    @objc override func selectAll(_ sender: Any?) { selectAll() }

    @objc func copy(_ sender: Any?) {
        guard selection.length > 0 else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(storage.substring(with: selection), forType: .string)
    }

    @objc func cut(_ sender: Any?) {
        guard selection.length > 0 else { return }
        copy(sender)
        replace(selection, with: "")
    }

    @objc func paste(_ sender: Any?) {
        guard var s = NSPasteboard.general.string(forType: .string) else { return }
        s = s.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        replace(hasMarkedText() ? marked : selection, with: s)
    }

    @objc func undo(_ sender: Any?) {
        guard let (t, sel) = undoStack.popLast() else { return }
        redoStack.append((storage as String, selection))
        storage.setString(t); selection = sel
        changed()
    }

    @objc func redo(_ sender: Any?) {
        guard let (t, sel) = redoStack.popLast() else { return }
        undoStack.append((storage as String, selection))
        storage.setString(t); selection = sel
        changed()
    }

    // MARK: NSTextInputClient (composed input path)

    func insertText(_ string: Any, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let r = replacementRange.location != NSNotFound ? replacementRange : (hasMarkedText() ? marked : selection)
        marked = NSRange(location: NSNotFound, length: 0)
        replace(r, with: s.replacingOccurrences(of: "\n", with: " "))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let s = (string as? NSAttributedString)?.string ?? (string as? String) ?? ""
        let r = replacementRange.location != NSNotFound ? replacementRange : (hasMarkedText() ? marked : selection)
        storage.replaceCharacters(in: r, with: s)
        let len = (s as NSString).length
        marked = len > 0 ? NSRange(location: r.location, length: len) : NSRange(location: NSNotFound, length: 0)
        selection = NSRange(location: r.location + selectedRange.location, length: selectedRange.length)
        relayout()   // marked text isn't a query yet; no delegate call
    }

    func unmarkText() {
        marked = NSRange(location: NSNotFound, length: 0)
        changed()
    }

    func selectedRange() -> NSRange { selection }
    func markedRange() -> NSRange { marked }
    func hasMarkedText() -> Bool { marked.location != NSNotFound }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        let r = NSIntersectionRange(range, NSRange(location: 0, length: storage.length))
        actualRange?.pointee = r
        return NSAttributedString(string: storage.substring(with: r))
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [.underlineStyle] }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = range
        let x = xOffset(range.location)
        let r = NSRect(x: x, y: textTop, width: 1, height: lineHeight)
        guard let w = window else { return .zero }
        return w.convertToScreen(convert(r, to: nil))
    }

    func characterIndex(for point: NSPoint) -> Int {
        guard let w = window else { return 0 }
        let p = convert(w.convertPoint(fromScreen: point), from: nil)
        return index(atX: p.x)
    }

    override func doCommand(by selector: Selector) {
        // Commands that reach us via interpretKeyEvents on the slow path.
        switch selector {
        case #selector(NSResponder.deleteBackward(_:)): deleteBackward()
        case #selector(NSResponder.insertNewline(_:)): _ = command(.enter)
        case #selector(NSResponder.cancelOperation(_:)): _ = command(.escape)
        case #selector(NSResponder.moveUp(_:)): _ = command(.up)
        case #selector(NSResponder.moveDown(_:)): _ = command(.down)
        case #selector(NSResponder.moveLeft(_:)): move(to: step(left: true, false), extend: false)
        case #selector(NSResponder.moveRight(_:)): move(to: step(left: false, false), extend: false)
        default: break
        }
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        let i = index(atX: convert(event.locationInWindow, from: nil).x)
        if event.clickCount >= 2 {
            selectAll()
            return
        }
        move(to: i, extend: event.modifierFlags.contains(.shift))
    }

    override func mouseDragged(with event: NSEvent) {
        let i = index(atX: convert(event.locationInWindow, from: nil).x)
        if selection.length == 0 && i != selection.location { anchor = selection.location }
        selection = NSRange(location: min(anchor, i), length: abs(i - anchor))
        relayout()
    }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    // MARK: Layout & drawing

    private var lineHeight: CGFloat { (font.ascender - font.descender).rounded(.up) }
    private var textTop: CGFloat { ((bounds.height - lineHeight) / 2).rounded() }

    private func relayout() {
        let tRel = nowNanos()
        defer { Self.relayoutCost.add(nowNanos() - tRel) }
        let str = storage as String
        // Geometry line (no drawing) for caret/selection/hit testing.
        let attr = NSMutableAttributedString(string: str, attributes: [.font: font])
        line = CTLineCreateWithAttributedString(attr)
        let caretX = rawX(caretPosition)
        let width = bounds.width - 4
        if caretX - scrollX > width { scrollX = caretX - width }
        if caretX - scrollX < 0 { scrollX = max(0, caretX - 40) }
        if rawX(storage.length) < width { scrollX = 0 }
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        // Text (marked text is drawn underlined).
        if hasMarkedText() {
            let r = TextImage.render(str, font: font, color: .labelColor, scale: scale, appearance: effectiveAppearance)
            textLayer.contents = r.image
            textLayer.frame = CGRect(x: -scrollX - 1, y: textTop + font.ascender - r.baselineFromTop, width: r.size.width, height: r.size.height)
            let x0 = xOffset(marked.location), x1 = xOffset(NSMaxRange(marked))
            selectionLayer.isHidden = false
            selectionLayer.backgroundColor = NSColor.labelColor.withAlphaComponent(0.5).cgColor
            selectionLayer.frame = CGRect(x: x0, y: textTop + lineHeight - 1, width: x1 - x0, height: 1)
        } else {
            let t0 = nowNanos()
            let r = TextImage.render(str, font: font, color: .labelColor, scale: scale, appearance: effectiveAppearance)
            Self.renderCost.add(nowNanos() - t0)
            textLayer.contents = r.image
            textLayer.frame = CGRect(x: -scrollX - 1, y: textTop + font.ascender - r.baselineFromTop, width: r.size.width, height: r.size.height)
            if selection.length > 0 {
                let x0 = xOffset(selection.location), x1 = xOffset(NSMaxRange(selection))
                selectionLayer.isHidden = false
                effectiveAppearance.performAsCurrentDrawingAppearance {
                    selectionLayer.backgroundColor = (window?.firstResponder === self ? NSColor.selectedTextBackgroundColor
                                                      : NSColor.unemphasizedSelectedTextBackgroundColor).cgColor
                }
                selectionLayer.frame = CGRect(x: x0, y: textTop, width: x1 - x0, height: lineHeight)
            } else {
                selectionLayer.isHidden = true
            }
        }
        textLayer.contentsScale = scale
        placeholderLayer.isHidden = storage.length > 0
        caret.frame = CGRect(x: (caretX - scrollX).rounded(), y: textTop, width: 2, height: lineHeight)
        caret.isHidden = selection.length > 0 || window?.firstResponder !== self
        let tb = nowNanos()
        restartBlink()
        Self.blinkCost.add(nowNanos() - tb)
    }

    private func renderPlaceholder() {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let r = TextImage.render(placeholder, font: font, color: .placeholderTextColor, scale: scale, appearance: effectiveAppearance)
        placeholderLayer.contents = r.image
        placeholderLayer.contentsScale = scale
        placeholderLayer.frame = CGRect(x: -1, y: textTop + font.ascender - r.baselineFromTop, width: r.size.width, height: r.size.height)
    }

    private var caretPosition: Int { selection.location == anchor && selection.length > 0 ? NSMaxRange(selection) : selection.location }

    private func rawX(_ i: Int) -> CGFloat {
        guard let line else { return 0 }
        return CTLineGetOffsetForStringIndex(line, i, nil)
    }

    private func xOffset(_ i: Int) -> CGFloat { rawX(i) - scrollX }

    private func index(atX x: CGFloat) -> Int {
        guard let line else { return 0 }
        let i = CTLineGetStringIndexForPosition(line, CGPoint(x: x + scrollX, y: 0))
        return i == kCFNotFound ? storage.length : max(0, min(i, storage.length))
    }

    /// Solid while typing, then blinks (Core Animation; no redraws, no timers).
    private func restartBlink() {
        caret.removeAnimation(forKey: "blink")
        caret.backgroundColor = NSColor.textInsertionPointColor.cgColor
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.values = [1, 1, 0, 0]
        a.keyTimes = [0, 0.5, 0.5, 1]
        a.duration = 1.06
        a.repeatCount = .infinity
        a.beginTime = CACurrentMediaTime() + 0.6
        a.isRemovedOnCompletion = false
        caret.add(a, forKey: "blink")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        relayout(); renderPlaceholder()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        relayout(); renderPlaceholder()
    }
}

import AppKit
@preconcurrency import Contacts
import FredCore

/// The ⌥Space launcher: one search field, up to five results.
///
/// Every keystroke runs the full search synchronously on the main thread (tens of
/// microseconds) and updates the rows in the same run-loop turn, so the result is in
/// the very next frame — no debouncing, no async hop, nothing stale.
@MainActor
final class Launcher: NSObject, NSTextFieldDelegate {
    let panel = FloatingPanel(width: Theme.width)
    let field = SearchField()
    let list = ResultList(capacity: 9, width: Theme.width)
    let engine: Engine

    /// What each visible row refers to.
    enum Ref {
        case item(Int)
        case calc(Calculator.Result)
        case field(ContactCard.Field)
        case process(NSRunningApplication)
    }
    enum Mode { case search, contact(ContactCard), forceQuit }

    private var refs: [Ref] = []
    private var mode = Mode.search
    private var query = Matcher.Query(folded: [])
    private var runningApps: [NSRunningApplication] = []
    let keystrokeLatency = LatencyLog("keystroke→rows")
    let showLatency = LatencyLog("hotkey→shown")

    init(engine: Engine) {
        self.engine = engine
        super.init()
        field.frame = NSRect(x: 22, y: (Theme.fieldHeight - 34) / 2, width: Theme.width - 44, height: 34)
        field.delegate = self
        field.placeholderString = "Fred"
        panel.content.addSubview(field)
        list.frame.origin = NSPoint(x: 0, y: Theme.fieldHeight)
        panel.content.addSubview(list)
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.keyHandler = { [weak self] e in self?.handleKeyEquivalent(e) ?? false }
        list.onClick = { [weak self] i in self?.activate(i, modifiers: NSEvent.modifierFlags) }
    }

    var isVisible: Bool { panel.isVisible }

    // MARK: Show / hide

    func toggle(eventTime: Double? = nil) {
        if panel.isVisible { hide(); return }
        show(eventTime: eventTime)
    }

    func show(eventTime: Double? = nil) {
        engine.prepareLearning()
        mode = .search
        field.stringValue = ""
        field.placeholderString = "Fred"
        render([], [])
        panel.position(height: height())
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        if let t = eventTime {
            let ns = UInt64(max(0, (ProcessInfo.processInfo.systemUptime - t) * 1e9))
            showLatency.add(ns)
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    // MARK: Typing

    func controlTextDidChange(_ obj: Notification) { queryChanged() }

    func queryChanged() {
        let t0 = nowNanos()
        if case .contact = mode { mode = .search }
        let text = field.stringValue
        query = Matcher.Query(text)
        switch mode {
        case .forceQuit: renderForceQuit()
        default: renderSearch(text)
        }
        let dt = nowNanos() - t0
        keystrokeLatency.add(dt)
    }

    private func renderSearch(_ text: String) {
        var rows: [ResultList.Row] = []
        var r: [Ref] = []
        if let c = Calculator.evaluate(text) {
            rows.append(.init(title: c.display, icon: .atlas(engine.slot(.calculator))))
            r.append(.calc(c))
        }
        if query.count > 0 {
            let top = engine.searcher.search(query, k: Theme.maxRows - rows.count, learn: engine.learning, now: engine.now)
            let cat = engine.searcher.catalog
            for i in 0..<top.count {
                let item = top.item(i)
                rows.append(.init(title: cat.titles[item], icon: .atlas(engine.icon(item))))
                r.append(.item(item))
            }
        }
        render(rows, r)
    }

    private func render(_ rows: [ResultList.Row], _ r: [Ref], selected: Int = 0) {
        refs = r
        list.set(rows, selected: selected)
        panel.setHeight(height())
    }

    private func height() -> CGFloat {
        refs.isEmpty ? Theme.fieldHeight : Theme.fieldHeight + list.height + Theme.listPadding
    }

    // MARK: Keys

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        switch sel {
        case #selector(NSResponder.moveDown(_:)), #selector(NSResponder.moveDownAndModifySelection(_:)):
            if !refs.isEmpty { list.select((list.selected + 1) % refs.count) }
            return true
        case #selector(NSResponder.moveUp(_:)), #selector(NSResponder.moveUpAndModifySelection(_:)):
            if !refs.isEmpty { list.select((list.selected - 1 + refs.count) % refs.count) }
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            activate(list.selected, modifiers: NSEvent.modifierFlags)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            switch mode {
            case .search: hide()
            case .contact, .forceQuit:
                mode = .search
                field.placeholderString = "Fred"
                queryChanged()
            }
            return true
        case #selector(NSResponder.insertTab(_:)):
            return true   // reserved
        default:
            return false
        }
    }

    /// ⌘1…⌘9 pick a row; ⌘↩ alternate action; ⌘O open contact in Contacts.app.
    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }
        if let ch = e.charactersIgnoringModifiers, let d = Int(ch), d >= 1, d <= 9, mods == .command {
            if d <= refs.count { activate(d - 1, modifiers: []) }
            return true
        }
        if e.keyCode == 36 || e.keyCode == 76 {   // ⌘↩
            activate(list.selected, modifiers: .command)
            return true
        }
        if e.charactersIgnoringModifiers == "o", case .contact(let card) = mode {
            hide()
            Actions.open(url: "addressbook://" + card.identifier)
            return true
        }
        return false
    }

    // MARK: Activation

    func activate(_ i: Int, modifiers: NSEvent.ModifierFlags) {
        guard i >= 0, i < refs.count else { return }
        switch refs[i] {
        case .calc(let c):
            hide()
            Actions.copy(c.copy)
        case .item(let item):
            let cat = engine.searcher.catalog
            engine.recordPick(item: item, query: query.bytes, row: i)
            let payload = cat.payloads[item]
            switch cat.kinds[item] {
            case .app:
                hide()
                if modifiers.contains(.command) { Actions.revealInFinder(path: payload) } else { Actions.openApp(path: payload) }
            case .settings, .bookmark:
                hide()
                Actions.open(url: payload)
            case .contact:
                showContact(id: payload, name: cat.titles[item])
            case .command:
                guard let c = Command(rawValue: payload) else { return }
                if c == .forceQuit { enterForceQuit(); return }
                hide()
                Actions.run(c)
            }
        case .field(let f):
            hide()
            Actions.copy(f.value)
        case .process(let app):
            hide()
            if !Actions.dryRun { app.forceTerminate() } else { Log.info("dry run: force quit \(app.localizedName ?? "?")") }
        }
    }

    // MARK: Contact card

    private func showContact(id: String, name: String) {
        guard let card = ContactCard.load(identifier: id, name: name) else { return }
        mode = .contact(card)
        var rows: [ResultList.Row] = []
        var r: [Ref] = []
        for f in card.fields.prefix(list.capacity) {
            rows.append(.init(title: f.value, detail: f.label, icon: .atlas(engine.slot(f.icon))))
            r.append(.field(f))
        }
        if rows.isEmpty {
            rows.append(.init(title: name, detail: "no phone or email", icon: .atlas(engine.slot(.contact))))
            r.append(.field(.init(label: "name", value: name, icon: .contact)))
        }
        render(rows, r)
    }

    // MARK: Force quit

    private func enterForceQuit() {
        mode = .forceQuit
        runningApps = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && $0.processIdentifier != getpid()
        }
        field.stringValue = ""
        field.placeholderString = "Force quit…"
        query = Matcher.Query(folded: [])
        renderForceQuit()
    }

    private func renderForceQuit() {
        // Small list: match names directly with the same tiered matcher.
        var scored: [(Int32, NSRunningApplication)] = []
        for a in runningApps {
            let name = a.localizedName ?? "?"
            let s = query.count == 0 ? 0 : Matcher.score(query, text: name)
            if s >= 0 { scored.append((s, a)) }
        }
        scored.sort { $0.0 > $1.0 }
        var rows: [ResultList.Row] = []
        var r: [Ref] = []
        for (_, a) in scored.prefix(list.capacity) {
            let slot = a.bundleURL.flatMap { engine.atlas?.slot(path: $0.path) } ?? engine.slot(.generic)
            rows.append(.init(title: a.localizedName ?? "?", detail: "force quit", icon: .atlas(slot)))
            r.append(.process(a))
        }
        render(rows, r)
    }
}

/// The search field. Plain NSTextField (keeps IME, undo, accessibility) styled flat.
final class SearchField: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        drawsBackground = false
        focusRingType = .none
        font = Theme.fieldFont
        usesSingleLineMode = true
        cell?.wraps = false
        cell?.isScrollable = true
        isAutomaticTextCompletionEnabled = false
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
}

extension Matcher {
    /// Convenience for tiny ad-hoc lists (force quit): scores one display string.
    static func score(_ q: Query, text: String) -> Int32 {
        var t: [UInt8] = []
        let ws = Fold.fold(text, into: &t)
        let n = min(t.count, 255)
        guard n > 0 else { return -1 }
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: scratchCount)
        defer { scratch.deallocate() }
        return q.bytes.withUnsafeBufferPointer { qb in
            q.compact.withUnsafeBufferPointer { cb in
                t.withUnsafeBufferPointer { tb in
                    score(q, qb.baseAddress!, cb.baseAddress!, tb.baseAddress!, n,
                          n >= 64 ? ws : ws & ((1 << UInt64(n)) - 1), allowLoose: true, scratch)
                }
            }
        }
    }
}

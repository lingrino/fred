import AppKit
@preconcurrency import Contacts
import FredCore

/// The ⌥Space launcher: one search field, up to five results.
///
/// Every keystroke runs the full search synchronously on the main thread (tens of
/// microseconds) and updates the rows in the same run-loop turn, so the result is in
/// the very next frame — no debouncing, no async hop, nothing stale.
@MainActor
final class Launcher: NSObject, QueryFieldDelegate {
    let panel = FloatingPanel(width: Theme.width, heights: [Theme.fieldHeight] + (1...9).map { Theme.fieldHeight + CGFloat($0) * Theme.rowHeight + Theme.listPadding })
    let field = QueryField(frame: .zero)
    let list = ResultList(capacity: 9, width: Theme.width)
    let engine: Engine

    /// What each visible row refers to. Catalog rows carry the item's stable key: the
    /// catalog can be swapped by a background reindex while the panel is open, so a row's
    /// index is only a hint — activation resolves the key against the current catalog.
    enum Ref {
        case item(Int, key: UInt64)
        case calc(Calculator.Result)
        case field(ContactCard.Field)
        case process(NSRunningApplication)
    }
    enum Mode { case search, contact(ContactCard), forceQuit }

    private var refs: [Ref] = []
    private var mode = Mode.search
    private var query = Matcher.Query(folded: [])
    private var runningApps: [NSRunningApplication] = []
    /// search + row update only (CPU, our code)
    let searchLatency = LatencyLog("keystroke: search+rows")
    /// key event timestamp → frame drawn and committed to the window server
    let keystrokeLatency = LatencyLog("keystroke→committed")
    /// hotkey event timestamp → panel ordered in, drawn and committed
    let showLatency = LatencyLog("hotkey→committed")
    // Stage breakdown of a keystroke (see `queryChanged`).
    let stOS = LatencyLog("  stage: event→app (OS delivery)")
    let stDeliver = LatencyLog("  stage: event→handler")
    let stAppKit = LatencyLog("  stage: app received→handler")
    let stDispatch = LatencyLog("  stage: app received→field keyDown")
    let stRowsRender = LatencyLog("  stage: rows update")
    let stDisplay = LatencyLog("  stage: displayIfNeeded")
    let stFlush = LatencyLog("  stage: CATransaction.flush")
    let stResize = LatencyLog("  stage: window resize")
    let stDraw = LatencyLog("  stage: draw+commit")
    private var resizeNs: UInt64 = 0

    init(engine: Engine) {
        self.engine = engine
        super.init()
        field.frame = NSRect(x: 22, y: (Theme.fieldHeight - 40) / 2, width: Theme.width - 44, height: 40)
        field.delegate = self
        field.placeholder = ""
        panel.content.addSubview(field)
        list.frame.origin = NSPoint(x: 0, y: Theme.fieldHeight)
        panel.content.addSubview(list)
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.keyHandler = { [weak self] e in self?.handleKeyEquivalent(e) ?? false }
        list.onClick = { [weak self] i in self?.activate(i, modifiers: NSEvent.modifierFlags) }

    }

    var isVisible: Bool { panel.shown }

    // MARK: Show / hide

    func toggle(eventTime: Double? = nil) {
        if panel.shown { hide(); return }
        show(eventTime: eventTime)
    }

    let shDeliver = LatencyLog("  show: hotkey event→handler")
    let shPrep = LatencyLog("  show: reset state")
    let shPosition = LatencyLog("  show: position")
    let shOrder = LatencyLog("  show: orderFront")
    let shKey = LatencyLog("  show: makeKey")
    let shCommit = LatencyLog("  show: commit")

    func show(eventTime: Double? = nil) {
        let t0 = nowNanos()
        if let t = eventTime { shDeliver.add(Self.since(t)) }
        engine.prepareLearning()
        mode = .search
        field.text = ""
        field.placeholder = ""
        render([], [])
        let t1 = nowNanos()
        panel.position(height: height())
        let t2 = nowNanos()
        if DevMode.regular { NSApp.activate() }
        let t2b = nowNanos()
        panel.present()
        panel.makeFirstResponder(field)
        let t3 = nowNanos()
        commitNow()
        let t4 = nowNanos()
        shPrep.add(t1 - t0); shPosition.add(t2 - t1); shOrder.add(t2b - t2); shKey.add(t3 - t2b); shCommit.add(t4 - t3)
        if let t = eventTime { showLatency.add(Self.since(t)) }
    }

    /// Draws dirty views and pushes the CA transaction now instead of at the end of the
    /// run-loop turn — same work, but it lets us timestamp the moment the frame leaves.
    func commitNow() {
        let a = nowNanos()
        panel.displayIfNeeded()
        let b = nowNanos()
        CATransaction.flush()
        let c = nowNanos()
        if panel.alphaValue > 0 { stDisplay.add(b - a); stFlush.add(c - b) }
    }

    static func since(_ uptime: Double) -> UInt64 {
        UInt64(max(0, (ProcessInfo.processInfo.systemUptime - uptime) * 1e9))
    }

    /// Pays first-use costs (glass, fonts, Core Text, code paging) once at launch with an
    /// invisible, non-key show, so the first real ⌥Space is as fast as the hundredth.
    func warmUp() {
        guard !panel.shown else { return }
        panel.alphaValue = 0
        panel.position(height: panel.maxHeight)
        panel.orderFrontRegardless()
        panel.warmGlasses()
        for q in ["a", "ch", "sys set", "2+2"] {
            field.text = q
            queryChanged()
        }
        field.text = ""
        render([], [])
        commitNow()
        panel.park()
        for l in [searchLatency, keystrokeLatency, stOS, stDeliver, stAppKit, stDispatch, stRowsRender, stResize, stDraw, stDisplay, stFlush, QueryField.renderCost] { l.reset() }
    }

    func hide() {
        guard panel.shown else { return }
        panel.park()
    }

    /// The catalog was replaced (background reindex): if results are on screen, recompute
    /// them so rows, titles and indices all refer to the new catalog.
    func catalogChanged() {
        guard panel.shown, case .search = mode else { return }
        queryChanged()
    }

    // MARK: Typing

    func queryFieldDidChange(_ f: QueryField) { queryChanged() }

    func queryChanged() {
        let t0 = nowNanos()
        resizeNs = 0
        // Instrumentation: only for keystrokes (not programmatic changes).
        let fromKey = KeyTiming.received > 0 && t0 >= KeyTiming.received && t0 - KeyTiming.received < 50_000_000
        let eventTime = KeyTiming.eventTime
        if fromKey {
            stOS.add(UInt64(max(0, (Double(KeyTiming.received) / 1e9 - eventTime) * 1e9)))
            stDeliver.add(Self.since(eventTime))
            stAppKit.add(t0 - KeyTiming.received)
            if QueryField.keyDownAt >= KeyTiming.received { stDispatch.add(QueryField.keyDownAt - KeyTiming.received) }
            KeyTiming.received = 0
        }
        if case .contact = mode { mode = .search }
        let text = field.text
        query = Matcher.Query(text)
        switch mode {
        case .forceQuit: renderForceQuit()
        default: renderSearch(text)
        }
        searchLatency.add(nowNanos() - t0 - resizeNs)
        if panel.shown {
            stResize.add(resizeNs)
            let t1 = nowNanos()
            commitNow()
            stDraw.add(nowNanos() - t1)
            if fromKey { keystrokeLatency.add(Self.since(eventTime)) }
        }
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
                rows.append(.init(title: cat.titles[item], icon: .atlas(engine.icon(item)), titleItem: item))
                r.append(.item(item, key: cat.keys[item]))
            }
        }
        render(rows, r)
    }

    private func render(_ rows: [ResultList.Row], _ r: [Ref], selected: Int = 0) {
        refs = r
        let tr = nowNanos()
        list.set(rows, selected: selected)
        stRowsRender.add(nowNanos() - tr)
        let t = nowNanos()
        panel.setHeight(height())
        resizeNs = nowNanos() - t
    }

    private func height() -> CGFloat {
        refs.isEmpty ? Theme.fieldHeight : Theme.fieldHeight + list.height + Theme.listPadding
    }

    // MARK: Keys

    func queryField(_ f: QueryField, command: QueryField.Command) -> Bool {
        switch command {
        case .down:
            if !refs.isEmpty { list.select((list.selected + 1) % refs.count); commitNow() }
        case .up:
            if !refs.isEmpty { list.select((list.selected - 1 + refs.count) % refs.count); commitNow() }
        case .enter: activate(list.selected, modifiers: [])
        case .commandEnter: activate(list.selected, modifiers: .command)
        case .escape:
            switch mode {
            case .search, .contact: hide()
            case .forceQuit:
                mode = .search
                field.placeholder = ""
                queryChanged()
            }
        case .pageUp, .pageDown, .tab: break
        }
        return true
    }

    /// ⌘1…⌘9 pick a row; ⌘↩ alternate action; ⌘O open contact in Contacts.app.
    func handleKeyEquivalent(_ e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods.contains(.command) else { return false }
        if let ch = e.charactersIgnoringModifiers, let d = Int(ch), d >= 1, d <= 9, mods == .command {
            if d <= refs.count { activate(d - 1, modifiers: []) }
            return true
        }
        if e.charactersIgnoringModifiers == "o", case .contact(let card) = mode {
            hide()
            Actions.open(url: "addressbook://" + card.identifier)
            return true
        }
        // ⌘C on a contact card: copy the selected field's value (not the query text) and close.
        if e.charactersIgnoringModifiers == "c", mods == .command, case .contact = mode,
           list.selected < refs.count, case .field(let f) = refs[list.selected] {
            hide()
            Actions.copy(f.value)
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
        case .item(let hint, let key):
            let cat = engine.searcher.catalog
            let item: Int
            if hint < cat.count && cat.keys[hint] == key { item = hint }
            else if let found = cat.item(forKey: key) { item = found }
            else { queryChanged(); return }          // gone (app uninstalled): just refresh
            // Learning's "row" is the position among catalog results (the calculator row
            // isn't one).
            let calcRows = refs.prefix(i).filter { if case .calc = $0 { true } else { false } }.count
            engine.recordPick(item: item, query: query.bytes, row: i - calcRows)
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
            // Like clipboard history: put the value on the pasteboard and paste it into
            // the app you were in (still frontmost — the panel never activated Fred).
            hide()
            Actions.copy(f.value)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { Actions.postPaste() }
        case .process(let app):
            hide()
            if !Actions.dryRun { app.forceTerminate() } else { Log.info("dry run: force quit \(app.localizedName ?? "?")") }
        }
    }

    // MARK: Contact card

    /// Development hook: opens the first contact row's card (no side effects).
    func openFirstContact() -> Bool {
        let cat = engine.searcher.catalog
        for r in refs { if case .item(let i, _) = r, i < cat.count, cat.kinds[i] == .contact { showContact(id: cat.payloads[i], name: cat.titles[i]); return true } }
        return false
    }

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
        field.text = ""
        field.placeholder = "Force quit…"
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

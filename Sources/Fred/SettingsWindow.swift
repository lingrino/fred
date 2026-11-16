import AppKit
import FredCore

/// "Fred Settings": a read-only health page. Fred has no preferences (behaviour lives in
/// code); this window shows whether every privacy grant works — with a button straight to
/// the right System Settings pane when one doesn't — plus live status and performance.
///
/// Opened by the "Fred Settings" command or ⌘, in either panel. Updates once a second
/// while open; costs nothing when closed (the timer is stopped).
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private weak var app: AppDelegate?
    private var window: NSWindow?
    private var timer: Timer?
    private var lastCPU: (cpu: Double, wall: Double)?
    /// The app that was in front before the window opened; it gets focus back on close
    /// (Fred is an accessory app — with no window of its own left, nothing else would).
    private var previousApp: NSRunningApplication?

    // Value labels, updated in place.
    private var permRows: [(kind: Permissions.Kind, dot: NSTextField, state: NSTextField, button: NSButton)] = []
    private var statusLabels: [String: NSTextField] = [:]

    init(app: AppDelegate) { self.app = app }

    static let permissionInfo: [(Permissions.Kind, String, String, String)] = [
        (.contacts, "Contacts", "Search contacts", "Privacy_Contacts"),
        (.postEvents, "Accessibility", "Paste and type into your apps", "Privacy_Accessibility"),
        (.pasteboard, "Paste from Other Apps", "Clipboard history", "Privacy_Pasteboard"),
        (.chromeData, "Full Disk Access", "Chrome bookmarks", "Privacy_AllFiles"),
        (.finder, "Automation → Finder", "Empty Trash", "Privacy_Automation"),
        (.loginwindow, "Automation → loginwindow", "Sleep, Restart, Shut Down", "Privacy_Automation"),
    ]

    static let statusKeys = ["Hotkeys", "Login item", "Index", "Clipboard", "Uptime",
                             "CPU", "Memory", "Keystroke → frame", "⌘Space → frame", "Search + rows"]

    var isOpen: Bool { window?.isVisible ?? false }
    func close() { window?.close() }

    func show() {
        if window == nil { build() }
        Permissions.refreshAutomation(ask: false)
        refresh()
        if !NSApp.isActive { previousApp = NSWorkspace.shared.frontmostApplication }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        timer?.invalidate()
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        t.tolerance = 0.2
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Renders the window's content offscreen (`fredctl settings <png>`): no focus change.
    func snapshot(to path: String) -> String {
        if window == nil { build() }
        refresh()
        guard let v = window?.contentView else { return "no window" }
        v.layoutSubtreeIfNeeded()
        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return "no bitmap" }
        v.cacheDisplay(in: v.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return "encode failed" }
        do { try png.write(to: URL(fileURLWithPath: path)) } catch { return "write: \(error)" }
        return "wrote \(path) \(rep.pixelsWide)x\(rep.pixelsHigh)"
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
        lastCPU = nil
        if let prev = previousApp, NSApp.isActive {
            NSApp.yieldActivation(to: prev)
            prev.activate()
        }
        previousApp = nil
    }

    // MARK: Layout

    private func build() {
        let w = SettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Fred Settings"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.animationBehavior = .none

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        stack.addArrangedSubview(header("Permissions"))
        let perms = NSGridView()
        perms.rowSpacing = 8
        perms.columnSpacing = 10
        for (kind, name, purpose, _) in Self.permissionInfo {
            let dot = label("●", size: 13)
            let title = label(name, size: 13, weight: .medium)
            let sub = label(purpose, size: 11, color: .secondaryLabelColor)
            let names = NSStackView(views: [title, sub])
            names.orientation = .vertical
            names.alignment = .leading
            names.spacing = 1
            let state = label("", size: 12, color: .secondaryLabelColor)
            let b = NSButton(title: "Open…", target: self, action: #selector(openPermission(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.tag = permRows.count
            perms.addRow(with: [dot, names, state, b])
            permRows.append((kind, dot, state, b))
        }
        perms.column(at: 0).width = 14
        perms.column(at: 1).width = 300
        perms.column(at: 2).width = 100
        stack.addArrangedSubview(perms)

        stack.addArrangedSubview(header("Status"))
        let status = NSGridView()
        status.rowSpacing = 6
        status.columnSpacing = 12
        for key in Self.statusKeys {
            let k = label(key, size: 12, color: .secondaryLabelColor)
            let v = label("—", size: 12)
            v.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            status.addRow(with: [k, v])
            statusLabels[key] = v
        }
        status.column(at: 0).width = 150
        stack.addArrangedSubview(status)

        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        w.contentView = content
        w.setContentSize(NSSize(width: 560, height: stack.fittingSize.height))
        window = w
    }

    private func header(_ s: String) -> NSTextField { label(s, size: 15, weight: .semibold) }

    private func label(_ s: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.font = .systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    @objc private func openPermission(_ b: NSButton) {
        let anchor = Self.permissionInfo[b.tag].3
        Actions.open(url: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?" + anchor)
    }

    // MARK: Refresh

    func refresh() {
        guard let app, let engine = app.engine, let launcher = app.launcher else { return }
        for row in permRows {
            let st = Permissions.status(row.kind)
            row.dot.textColor = st == true ? .systemGreen : st == false ? .systemRed : .systemOrange
            row.state.stringValue = st == true ? "Working" : st == false ? "Not granted" : "Not yet asked"
            row.button.isHidden = st == true
        }
        let c = engine.catalog
        var kinds = [Int](repeating: 0, count: 5)
        for k in c.kinds { kinds[Int(k.rawValue)] += 1 }
        set("Hotkeys", "⌘Space \(HotKeys.status.first ?? "-") · ⌘⇧C \(HotKeys.status.dropFirst().first ?? "-")")
        set("Login item", LoginItem.statusLine)
        set("Index", "\(kinds[0]) apps · \(kinds[1]) settings · \(kinds[3]) bookmarks · \(kinds[4]) contacts")
        set("Clipboard", app.clipboard?.store.stats ?? "—")
        let up = Int(Date().timeIntervalSince(app.launchedAt))
        set("Uptime", up < 3600 ? "\(up / 60) min" : up < 86400 ? "\(up / 3600) h \(up % 3600 / 60) min" : "\(up / 86400) d \(up % 86400 / 3600) h")

        let cpuNow = Diagnostics.cpuSeconds(), wallNow = ProcessInfo.processInfo.systemUptime
        if let last = lastCPU, wallNow > last.wall {
            set("CPU", String(format: "%.1f %%  (%.2f s total)", (cpuNow - last.cpu) / (wallNow - last.wall) * 100, cpuNow))
        } else {
            set("CPU", String(format: "%.2f s total", cpuNow))
        }
        lastCPU = (cpuNow, wallNow)
        set("Memory", Diagnostics.footprintMB().map { String(format: "%.1f MB", $0) } ?? "—")
        set("Keystroke → frame", pct(launcher.keystrokeLatency))
        set("⌘Space → frame", pct(launcher.showLatency))
        set("Search + rows", launcher.searchLatency.percentile(0.5).map { String(format: "%.0f µs p50", Double($0) / 1000) } ?? "no samples yet")
    }

    private func pct(_ l: LatencyLog) -> String {
        guard let p50 = l.percentile(0.5), let p99 = l.percentile(0.99) else { return "no samples yet" }
        return String(format: "%.2f ms p50 · %.2f ms p99 · %d samples", Double(p50) / 1e6, Double(p99) / 1e6, l.count)
    }

    private func set(_ key: String, _ v: String) { statusLabels[key]?.stringValue = v }
}

/// Esc / ⌘W close the window.
final class SettingsWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        if e.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command, e.charactersIgnoringModifiers == "w" {
            close(); return true
        }
        return super.performKeyEquivalent(with: e)
    }
}

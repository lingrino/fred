import AppKit
import FredCore

/// Local control socket for development and maintenance (scripts/fredctl).
///
/// Lets the maintainer (Claude) inspect the running app with its real data and real
/// permissions: run queries, read latency stats, check grants, drive the UI for
/// screenshots. Unix socket, mode 0600, one line in → text out. Nothing here performs a
/// pick or an action on the user's behalf except `dryrun`-guarded testing hooks.
final class ControlServer: @unchecked Sendable {
    let path = Engine.dataDirPath + "/control.sock"
    private weak var app: AppDelegate?

    @MainActor init(app: AppDelegate) { self.app = app }

    func start() {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            let b = Array(path.utf8.prefix(raw.count - 1))
            raw.copyBytes(from: b)
            raw[b.count] = 0
        }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { Log.error("control: bind failed \(errno)"); close(fd); return }
        chmod(path, 0o600)
        listen(fd, 4)
        let t = Thread { [self] in
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { continue }
                self.serve(c)
            }
        }
        t.qualityOfService = .utility
        t.start()
    }

    private func serve(_ c: Int32) {
        defer { close(c) }
        var buf = [UInt8](repeating: 0, count: 4096)
        var data: [UInt8] = []
        while !data.contains(0x0A) {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            data += buf[0..<n]
        }
        let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let out = DispatchQueue.main.sync { MainActor.assumeIsolated { self.handle(line) } }
        let bytes = Array((out + "\n").utf8)
        _ = bytes.withUnsafeBufferPointer { write(c, $0.baseAddress, $0.count) }
    }

    @MainActor private func handle(_ line: String) -> String {
        guard let app else { return "no app" }
        let parts = line.split(separator: " ", maxSplits: 1)
        let cmd = parts.first.map(String.init) ?? ""
        let arg = parts.count > 1 ? String(parts[1]) : ""
        let e = app.engine!, l = app.launcher!
        switch cmd {
        case "stats":
            let c = e.catalog
            var kinds = [Int](repeating: 0, count: 5)
            for k in c.kinds { kinds[Int(k.rawValue)] += 1 }
            return """
            catalog: \(c.count) items (apps \(kinds[0]), settings \(kinds[1]), commands \(kinds[2]), bookmarks \(kinds[3]), contacts \(kinds[4])), \(c.index.count) entries, \(c.index.byteCount) text bytes
            atlas: \(e.atlas.map { "\($0.slots) icons" } ?? "not ready")
            \(l.keystrokeLatency.summary)
            \(l.showLatency.summary)
            \(app.clipboard?.statsLine ?? "clipboard: off")
            memory: \(residentMB()) MB resident
            """
        case "permissions": return Permissions.report()
        case "request": Permissions.requestMissing(); return Permissions.report()
        case "query":
            let q = Matcher.Query(arg)
            let t0 = nowNanos()
            let top = e.searcher.search(q, k: 9, learn: e.learning, now: e.now)
            let dt = nowNanos() - t0
            var s = "\(top.count) results in \(dt / 1000) µs\n"
            for i in 0..<top.count {
                let it = top.item(i)
                s += "  \(top.score(i))\t\(e.catalog.kinds[it])\t\(e.catalog.titles[it])\t(learned \(e.searcher.learned(it)))\n"
            }
            return s
        case "show": l.show(); return "ok"
        case "hide": l.hide(); return "ok"
        case "type":
            if !l.isVisible { l.show() }
            l.field.stringValue = arg
            l.field.currentEditor()?.selectedRange = NSRange(location: arg.utf16.count, length: 0)
            l.queryChanged()
            return "ok"
        case "key":
            // Simulate navigation keys in the launcher: down, up, esc.
            let sel: Selector? = switch arg {
            case "down": #selector(NSResponder.moveDown(_:))
            case "up": #selector(NSResponder.moveUp(_:))
            case "esc": #selector(NSResponder.cancelOperation(_:))
            default: nil
            }
            guard let sel, let tv = l.field.currentEditor() as? NSTextView else { return "?" }
            _ = l.control(l.field, textView: tv, doCommandBy: sel)
            return "ok"
        case "snapshot":
            // snapshot <png path> [query] — renders the launcher offscreen (no focus
            // change, glass backdrop not included) so layout can be checked while the
            // user is working.
            let bits = arg.split(separator: " ", maxSplits: 1).map(String.init)
            guard let out = bits.first else { return "usage: snapshot <path.png> [query]" }
            let wasVisible = l.isVisible
            if !wasVisible {
                // Ordered in invisibly and without becoming key: layers get drawn, the
                // user's focus is untouched.
                l.panel.alphaValue = 0
                l.panel.position(height: l.panel.frame.height)
                l.panel.orderFrontRegardless()
            }
            l.field.stringValue = bits.count > 1 ? bits[1] : ""
            l.queryChanged()
            let r = Snapshot.write(view: l.panel.glass, to: out)
            if !wasVisible { l.panel.orderOut(nil); l.panel.alphaValue = 1 }
            return r
        case "learn": return e.learning.debugDescription(catalog: e.catalog)
        case "reindex": app.indexer.reloadAll(); return "ok"
        case "dryrun": Actions.dryRun = arg != "off"; return "dryrun \(Actions.dryRun)"
        case "clip": return app.clipboard?.control(arg) ?? "clipboard: off"
        default:
            return "commands: stats permissions request query <q> show hide type <q> key down|up|esc learn reindex dryrun on|off clip …"
        }
    }

    private func residentMB() -> String {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? String(format: "%.1f", Double(info.phys_footprint) / 1_048_576) : "?"
    }
}

import AppKit
import Carbon

/// On-screen checks that need real key events — the paths `make smoke` can't reach
/// without taking focus. Fred posts the events itself through the HID tap (it has the
/// PostEvent grant), so the Carbon hotkey, AppKit dispatch and QueryField run exactly as
/// for a key press. Everything is typed into Fred's own launcher field; a step aborts if
/// that panel isn't key, so nothing reaches another app.
///
/// They take keyboard focus for a few seconds: run them only when the user is idle
/// (AGENTS.md "Control socket"). Results are read back with the same command, no args.
///   fredctl hotkeybench <n>   n × (⌘Space → type "safa" → hide): show + keystroke latency
///   fredctl live run          typeText (contact Enter) and ⌘, → Fred Settings
@MainActor
enum LiveTests {
    private(set) static var result = "not run"
    private static var running = false

    // MARK: hotkeybench

    static func hotkeyBench(_ l: Launcher, cycles: Int) -> String {
        guard let err = preflight(l) else {
            for x in logs(l) { x.reset() }
            begin()
            cycle(l, i: 0, n: cycles)
            return "started: \(cycles) cycles, ~\(cycles) s; then `fredctl hotkeybench`"
        }
        return err
    }

    static func logs(_ l: Launcher) -> [LatencyLog] {
        [l.showLatency, l.shDeliver, l.shPrep, l.shPosition, l.shOrder, l.shKey, l.shCommit,
         l.keystrokeLatency, l.stRowsRender, l.stResize, l.stDisplay, l.stDraw, l.stFlush]
    }

    /// "s" fills 5 rows, "sa"/"saf"/"safa" fewer: every keystroke can resize the glass.
    static let query = ["s", "a", "f", "a"]

    private static func cycle(_ l: Launcher, i: Int, n: Int) {
        if i == n { finishBench(l); return }
        showViaHotkey(l, step: "cycle \(i)") {
            type(l, query, step: "cycle \(i)") {
                after(0.1) { l.hide(); after(0.25) { cycle(l, i: i + 1, n: n) } }
            }
        }
    }

    private static func finishBench(_ l: Launcher) {
        var out = "\(l.showLatency.count) shows (µs: p50 p90 max)\n"
        for x in logs(l) {
            guard let p50 = x.percentile(0.5), let p90 = x.percentile(0.9), let mx = x.percentile(1) else { continue }
            out += String(format: "  %-40@ %7.0f %7.0f %7.0f\n", x.name as NSString, Double(p50) / 1e3, Double(p90) / 1e3, Double(mx) / 1e3)
        }
        end(out)
    }

    // MARK: live checks

    /// Longer than one 20-unit typeText chunk, with combining marks and an emoji pair.
    static let sample = "Grüße 👋🏽 +1 (555) 010-9999 x"

    static func live(_ l: Launcher, settings: SettingsWindowController) -> String {
        if let err = preflight(l) { return err }
        begin()
        var report: [String] = []
        showViaHotkey(l, step: "typeText") {
            Actions.typeText(sample)
            after(0.4) {
                let got = l.field.text
                report.append(got == sample ? "ok   typeText: \(got.count) characters arrived intact"
                                            : "FAIL typeText: got \"\(got)\"")
                // ⌘, while the launcher is key → launcher hides, Fred Settings opens.
                postKey(CGKeyCode(kVK_ANSI_Comma), flags: .maskCommand)
                after(0.5) {
                    report.append(!l.isVisible && settings.isOpen ? "ok   ⌘, opened Fred Settings"
                                                                  : "FAIL ⌘,: launcher visible \(l.isVisible), settings open \(settings.isOpen)")
                    settings.close()
                    after(0.4) {
                        report.append(NSApp.isActive ? "FAIL closing Fred Settings left Fred active"
                                                     : "ok   closing Fred Settings returned focus")
                        end(report.joined(separator: "\n"))
                    }
                }
            }
        }
        return "started; then `fredctl live`"
    }

    // MARK: Steps

    private static func preflight(_ l: Launcher) -> String? {
        if running { return "already running" }
        if HotKeys.status.first != "registered" { return "launcher hotkey not registered" }
        if !CGPreflightPostEventAccess() { return "no PostEvent permission" }
        if l.isVisible { l.hide() }
        return nil
    }

    private static func begin() { running = true; result = "running" }
    private static func end(_ s: String) { running = false; result = s }

    private static func abort(_ l: Launcher, _ why: String) {
        if l.isVisible { l.hide() }
        end("aborted: \(why)")
    }

    private static func showViaHotkey(_ l: Launcher, step: String, then: @escaping @MainActor () -> Void) {
        let (code, mods) = AppDelegate.launcherKey
        var flags: CGEventFlags = []
        if mods & cmdKey != 0 { flags.insert(.maskCommand) }
        if mods & shiftKey != 0 { flags.insert(.maskShift) }
        if mods & optionKey != 0 { flags.insert(.maskAlternate) }
        postKey(CGKeyCode(code), flags: flags)
        after(0.15) {
            guard l.isVisible, l.panel.isKeyWindow else { abort(l, "\(step): launcher not key after the hotkey"); return }
            then()
        }
    }

    private static func type(_ l: Launcher, _ keys: [String], step: String, k: Int = 0, then: @escaping @MainActor () -> Void) {
        if k == keys.count { then(); return }
        guard l.isVisible, l.panel.isKeyWindow else { abort(l, "\(step): launcher lost key while typing"); return }
        Actions.typeText(keys[k])
        after(0.08) { type(l, keys, step: step, k: k + 1, then: then) }
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cghidEventTap)
        }
    }

    private static func after(_ s: Double, _ f: @escaping @MainActor () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + s) { MainActor.assumeIsolated { f() } }
    }
}

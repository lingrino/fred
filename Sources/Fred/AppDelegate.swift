import AppKit
import Carbon.HIToolbox
import FredCore

/// Wires the app together. Startup order is latency-driven: the hotkey and the (empty)
/// panel exist before any indexing starts, so Fred is usable the instant it launches
/// and results fill in as sources finish (tens of ms).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: Engine!
    var launcher: Launcher!
    let indexer = Indexer()
    var control: ControlServer?
    var clipboard: ClipboardController?
    private var activity: NSObjectProtocol?

    /// ⌥Space launcher, ⌥⇧C clipboard.
    static let launcherKey = (code: kVK_Space, mods: optionKey)
    static let clipboardKey = (code: kVK_ANSI_C, mods: optionKey | shiftKey)

    /// Picks up a grant given while Fred is running (no OS notification exists for
    /// that): when a source is still empty and its permission now checks out, reindex.
    private func retryMissingSources() {
        var have = [Int](repeating: 0, count: 5)
        for k in engine.catalog.kinds { have[Int(k.rawValue)] += 1 }
        if have[Int(Catalog.Kind.bookmark.rawValue)] == 0, Permissions.status(.chromeData) == true {
            indexer.schedule(.bookmarks, delay: 0)
        }
        if have[Int(Catalog.Kind.contact.rawValue)] == 0, Permissions.status(.contacts) == true {
            indexer.schedule(.contacts, delay: 0)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let t0 = nowNanos()
        engine = Engine()
        launcher = Launcher(engine: engine)

        HotKeys.register(keyCode: Self.launcherKey.code, modifiers: Self.launcherKey.mods) { [weak self] t in
            self?.clipboard?.hide()
            self?.launcher.toggle(eventTime: t)
            self?.retryMissingSources()
        }

        clipboard = ClipboardController(engine: engine)
        clipboard?.startMonitoring()
        HotKeys.register(keyCode: Self.clipboardKey.code, modifiers: Self.clipboardKey.mods) { [weak self] _ in
            self?.launcher.hide()
            self?.clipboard?.toggle()
        }
        engine.onTitles = { [weak self] t in self?.launcher.list.titles = t }
        engine.onAtlas = { [weak self] a in
            self?.launcher.list.atlas = a
            self?.clipboard?.list.atlas = a
        }

        engine.onReady = { [weak self] in
            self?.launcher.warmUp()
            self?.clipboard?.warmUp()
            Log.info("ready \((nowNanos() - t0) / 1000) µs after launch")
        }
        indexer.onCatalog = { [weak self] c, apps, panes in
            self?.engine.setCatalog(c, apps: apps, panes: panes)
        }
        indexer.start()

        // Fred must answer a hotkey instantly at any time: opt out of App Nap and
        // timer coalescing that would otherwise park an idle background app.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Fred answers global hotkeys")

        control = ControlServer(app: self)
        control?.start()

        LoginItem.ensureRegistered()

        Permissions.requestMissing()
        Log.info("launched in \((nowNanos() - t0) / 1000) µs\n\(Permissions.report())")
    }
}

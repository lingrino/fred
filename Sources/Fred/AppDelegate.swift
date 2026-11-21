import AppKit
import Carbon.HIToolbox
import FredCore

/// Wires the app together. Startup order is latency-driven: the hotkey and the (empty)
/// panel exist before any indexing starts, so Fred is usable the instant it launches
/// and results fill in once the sources are read (~0.2 s; contacts are the slowest).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var engine: Engine!
    var launcher: Launcher!
    let indexer = Indexer()
    var control: ControlServer?
    var clipboard: ClipboardController?
    lazy var settings = SettingsWindowController(app: self)
    let launchedAt = Date()
    private var activity: NSObjectProtocol?

    /// ⌘Space launcher, ⌘⇧C clipboard.
    static let launcherKey = (code: kVK_Space, mods: cmdKey)
    static let clipboardKey = (code: kVK_ANSI_C, mods: cmdKey | shiftKey)

    /// An upgrade (`brew upgrade`) swaps the bundle on disk under the running process.
    /// Once changes inside it settle and its executable is a different file from the one
    /// Fred started from, Fred restarts into the new version. `make install` kills Fred
    /// first, so this only fires when something else replaced the app.
    private let launchedExecutable = fileID(Bundle.main.executablePath)
    private var selfChangeGeneration = 0

    private func selfChanged() {
        selfChangeGeneration &+= 1
        let generation = selfChangeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.selfChangeGeneration,
                      let now = fileID(Bundle.main.executablePath), now != self.launchedExecutable else { return }
                Log.info("Fred.app was replaced on disk: restarting into the new version")
                Actions.relaunch()
            }
        }
    }

    /// Picks up a grant given while Fred is running (no OS notification exists for
    /// that): when a source is still empty and its permission has just started checking
    /// out, reindex it — once, not on every hotkey (Chrome may simply have no bookmarks).
    private func retryMissingSources() {
        var have = [Int](repeating: 0, count: 5)
        for k in engine.catalog.kinds { have[Int(k.rawValue)] += 1 }
        if have[Int(Catalog.Kind.bookmark.rawValue)] == 0 {
            let ok = Permissions.status(.chromeData) == true
            if ok && !granted.bookmarks { indexer.schedule(.bookmarks, delay: 0) }
            granted.bookmarks = ok
        }
        if have[Int(Catalog.Kind.contact.rawValue)] == 0 {
            let ok = Permissions.status(.contacts) == true
            if ok && !granted.contacts { indexer.schedule(.contacts, delay: 0) }
            granted.contacts = ok
        }
    }
    private var granted = (bookmarks: false, contacts: false)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let t0 = nowNanos()
        var marks: [(String, UInt64)] = []
        func mark(_ s: String) { marks.append((s, nowNanos())) }

        // Hotkeys first: registered before any UI exists (a press during startup is
        // simply handled once the main thread gets to it).
        HotKeys.register(keyCode: Self.launcherKey.code, modifiers: Self.launcherKey.mods) { [weak self] t in
            guard let self, let launcher = self.launcher else { return }
            self.clipboard?.hide()
            launcher.toggle(eventTime: t)
            self.retryMissingSources()
        }
        HotKeys.register(keyCode: Self.clipboardKey.code, modifiers: Self.clipboardKey.mods) { [weak self] _ in
            self?.launcher?.hide()
            self?.clipboard?.toggle()
        }
        mark("hotkeys")

        // Indexing next: it runs on its own queue and overlaps everything below.
        indexer.onCatalog = { [weak self] c, apps, panes in
            self?.engine.setCatalog(c, apps: apps, panes: panes)
        }
        indexer.onSelfChanged = { [weak self] in self?.selfChanged() }
        indexer.start()
        mark("indexer")

        engine = Engine()
        mark("engine")
        launcher = Launcher(engine: engine)
        mark("launcher ui")

        clipboard = ClipboardController(engine: engine)
        clipboard?.startMonitoring()
        mark("clipboard")
        engine.onTitles = { [weak self] t in self?.launcher.list.titles = t }
        engine.onCatalogChanged = { [weak self] in self?.launcher?.catalogChanged() }
        launcher.onOpenSettings = { [weak self] in self?.settings.show() }
        clipboard?.onOpenSettings = { [weak self] in self?.settings.show() }
        engine.onAtlas = { [weak self] a in
            self?.launcher.list.atlas = a
            self?.clipboard?.list.atlas = a
        }
        engine.onReady = { [weak self] in
            self?.launcher.warmUp()
            self?.clipboard?.warmUp()
            Log.info("ready \((nowNanos() - t0) / 1000) µs after launch")
        }

        // Fred must answer a hotkey instantly at any time: opt out of App Nap and
        // timer coalescing that would otherwise park an idle background app.
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Fred answers global hotkeys")
        if ControlServer.enabled {
            control = ControlServer(app: self)
            control?.start()
            mark("control")
        }

        var line = "launched in \((nowNanos() - t0) / 1000) µs:"
        var prev = t0
        for (n, t) in marks { line += " \(n) \((t - prev) / 1000)"; prev = t }
        Log.info(line)

        // Not latency-relevant: after the first run-loop turn.
        DispatchQueue.main.async {
            CrashRelaunch.arm()
            LoginItem.ensureRegistered()
            Permissions.requestMissing()
            Log.info(Permissions.report())
        }
        DispatchQueue.global(qos: .utility).async { Converter.warm() }
    }

    /// Every `NSApp.terminate` (Quit Fred, Restart Fred, an upgrade, logout) ends here.
    func applicationWillTerminate(_ notification: Notification) {
        CrashRelaunch.disarm()
    }
}

/// Identity of the file at `path` (inode + modification time), nil if it doesn't exist.
private func fileID(_ path: String?) -> [Int]? {
    guard let path else { return nil }
    var st = stat()
    guard stat(path, &st) == 0 else { return nil }
    return [Int(st.st_ino), st.st_mtimespec.tv_sec, st.st_mtimespec.tv_nsec]
}

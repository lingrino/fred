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

    func applicationDidFinishLaunching(_ notification: Notification) {
        let t0 = nowNanos()
        engine = Engine()
        launcher = Launcher(engine: engine)

        HotKeys.register(keyCode: Self.launcherKey.code, modifiers: Self.launcherKey.mods) { [weak self] t in
            self?.clipboard?.hide()
            self?.launcher.toggle(eventTime: t)
        }

        clipboard = ClipboardController(engine: engine)
        clipboard?.startMonitoring()
        HotKeys.register(keyCode: Self.clipboardKey.code, modifiers: Self.clipboardKey.mods) { [weak self] _ in
            self?.launcher.hide()
            self?.clipboard?.toggle()
        }
        engine.onAtlas = { [weak self] a in
            self?.launcher.list.atlas = a
            self?.clipboard?.list.atlas = a
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

        Permissions.requestMissing()
        Log.info("launched in \((nowNanos() - t0) / 1000) µs\n\(Permissions.report())")
    }
}

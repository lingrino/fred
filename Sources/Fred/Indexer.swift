import AppKit
@preconcurrency import Contacts
import CoreServices
import FredCore

/// Keeps the catalog fresh.
///
/// Each source is re-read in full when it changes — every source is cheap enough that
/// diffing would only add bugs (apps ~40 ms, panes ~20 ms, bookmarks ~1 ms, contacts
/// tens of ms). Change signals: FSEvents on app roots and Chrome profile dirs, the
/// Contacts change notification, and wake from sleep. Settings panes and commands only
/// change with an OS update, so they are read once at launch.
///
/// After any source changes, a new immutable Catalog (with its search index) is built
/// on the indexing queue and handed to `onCatalog` on the main thread.
final class Indexer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "fred.index", qos: .utility)
    private var apps: [Catalog.Item] = []
    private var panes: [Catalog.Item] = []
    private var bookmarks: [Catalog.Item] = []
    private var contacts: [Catalog.Item] = []
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    /// Called on main with each new catalog and the raw app list (for icons).
    var onCatalog: (@MainActor (Catalog, [AppScanner.App], [SettingsScanner.Pane]) -> Void)?
    private var appList: [AppScanner.App] = []
    private var paneList: [SettingsScanner.Pane] = []
    /// Called on main when something inside Fred's own bundle changed on disk (an upgrade
    /// replacing it); the app roots are watched anyway, so this costs nothing extra.
    var onSelfChanged: (@MainActor () -> Void)?
    private let selfBundle = Bundle.main.bundlePath + "/"

    enum Source: Hashable { case apps, bookmarks, contacts, all }
    private var pendingSources: Set<Source> = []

    func start() {
        queue.async { self.reload([.all]) }
        watchFiles()
        // contactsd posts a change notification right after the first fetch; ignore the
        // first few seconds so launch doesn't fetch everything twice.
        let started = DispatchTime.now()
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { [weak self] _ in
            guard DispatchTime.now() > started + 10 else { return }
            self?.schedule(.contacts)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.schedule(.all)
        }
    }

    /// Debounced reload (FSEvents and Contacts fire in bursts). Requests that arrive
    /// while one is pending are merged.
    func schedule(_ s: Source, delay: Double = 0.5) {
        queue.async {
            self.pendingSources.insert(s)
            self.pending?.cancel()
            let work = DispatchWorkItem {
                let set = self.pendingSources
                self.pendingSources = []
                self.reload(set)
            }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Re-reads everything; also used when a permission is granted while running.
    func reloadAll() { schedule(.all, delay: 0) }

    private func reload(_ set: Set<Source>) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let all = set.contains(.all)
        // Sources are independent: load them concurrently (contacts alone is ~100 ms of
        // XPC to contactsd; apps/panes are file system bound).
        let doApps = all || set.contains(.apps), doPanes = all
        let doBookmarks = all || set.contains(.bookmarks), doContacts = all || set.contains(.contacts)
        // Each task writes only its own slot; concurrentPerform returns after all finish.
        final class Slots: @unchecked Sendable {
            var apps: [AppScanner.App]?, panes: [SettingsScanner.Pane]?
            var bookmarks: [Catalog.Item]?, contacts: [Catalog.Item]?
            // One stored property per task (distinct memory locations; no shared array).
            var ms0 = 0.0, ms1 = 0.0, ms2 = 0.0, ms3 = 0.0
            func set(_ k: Int, _ v: Double) {
                switch k { case 0: ms0 = v; case 1: ms1 = v; case 2: ms2 = v; default: ms3 = v }
            }
        }
        let r = Slots()
        DispatchQueue.concurrentPerform(iterations: 4) { k in
            let ts = DispatchTime.now().uptimeNanoseconds
            defer { r.set(k, Double(DispatchTime.now().uptimeNanoseconds - ts) / 1e6) }
            switch k {
            case 0 where doApps: r.apps = AppScanner.scan()
            case 1 where doPanes: r.panes = SettingsScanner.scan()
            case 2 where doBookmarks: r.bookmarks = ChromeBookmarks.items(ChromeBookmarks.load())
            case 3 where doContacts: r.contacts = ContactsSource.load()
            default: break
            }
        }
        if let a = r.apps { appList = a; apps = AppScanner.items(a) }
        if let p = r.panes { paneList = p; panes = SettingsScanner.items(p) }
        if let b = r.bookmarks { bookmarks = b }
        if let c = r.contacts { contacts = c }
        let catalog = Catalog(apps + panes + Command.items() + bookmarks + contacts)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        Log.info("index \(set): \(apps.count) apps, \(panes.count) panes, \(bookmarks.count) bookmarks, \(contacts.count) contacts, \(catalog.index.count) entries in \(String(format: "%.1f", ms)) ms (apps \(Int(r.ms0)), panes \(Int(r.ms1)), bookmarks \(Int(r.ms2)), contacts \(Int(r.ms3)) ms)")
        let al = appList, pl = paneList
        DispatchQueue.main.async { MainActor.assumeIsolated { self.onCatalog?(catalog, al, pl) } }
    }

    // MARK: FSEvents

    private func watchFiles() {
        var paths = AppScanner.roots.map(\.path).filter { FileManager.default.fileExists(atPath: $0) }
        paths.append(ChromeBookmarks.chromeDir)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        var context = FSEventStreamContext(version: 0, info: ctx, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, n, pathsPtr, _, _ in
            let me = Unmanaged<Indexer>.fromOpaque(info!).takeUnretainedValue()
            let paths = unsafeBitCast(pathsPtr, to: NSArray.self) as? [String] ?? []
            var apps = false, bms = false, selfChanged = false
            for p in paths.prefix(n) {
                if (p + "/").hasPrefix(me.selfBundle) { selfChanged = true }
                if p.hasPrefix(ChromeBookmarks.chromeDir) {
                    if p.hasSuffix("Bookmarks") || p.hasSuffix("Bookmarks/") || p.contains("/Bookmarks") { bms = true }
                } else { apps = true }
            }
            if apps { me.schedule(.apps, delay: 1.0) }
            if bms { me.schedule(.bookmarks, delay: 0.5) }
            if selfChanged { DispatchQueue.main.async { MainActor.assumeIsolated { me.onSelfChanged?() } } }
        }
        guard let s = FSEventStreamCreate(nil, cb, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }
}

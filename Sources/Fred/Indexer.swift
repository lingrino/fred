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

    enum Source { case apps, bookmarks, contacts, all }

    func start() {
        queue.async { self.reload(.all) }
        watchFiles()
        NotificationCenter.default.addObserver(forName: .CNContactStoreDidChange, object: nil, queue: nil) { [weak self] _ in
            self?.schedule(.contacts)
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.schedule(.all)
        }
    }

    /// Debounced reload (FSEvents and Contacts fire in bursts).
    func schedule(_ s: Source, delay: Double = 0.5) {
        queue.async {
            self.pending?.cancel()
            let work = DispatchWorkItem { self.reload(s) }
            self.pending = work
            self.queue.asyncAfter(deadline: .now() + delay, execute: work)
        }
    }

    /// Re-reads everything; also used when a permission is granted while running.
    func reloadAll() { schedule(.all, delay: 0) }

    private func reload(_ s: Source) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        if s == .all || s == .apps {
            appList = AppScanner.scan()
            apps = AppScanner.items(appList)
        }
        if s == .all {
            paneList = SettingsScanner.scan()
            panes = SettingsScanner.items(paneList)
        }
        if s == .all || s == .bookmarks { bookmarks = ChromeBookmarks.items(ChromeBookmarks.load()) }
        if s == .all || s == .contacts { contacts = ContactsSource.load() }
        let all = apps + panes + Command.items() + bookmarks + contacts
        let catalog = Catalog(all)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        Log.info("index \(s): \(apps.count) apps, \(panes.count) panes, \(bookmarks.count) bookmarks, \(contacts.count) contacts, \(catalog.index.count) entries in \(String(format: "%.1f", ms)) ms")
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
            var apps = false, bms = false
            for p in paths.prefix(n) {
                if p.hasPrefix(ChromeBookmarks.chromeDir) {
                    if p.hasSuffix("Bookmarks") || p.hasSuffix("Bookmarks/") || p.contains("/Bookmarks") { bms = true }
                } else { apps = true }
            }
            if apps { me.schedule(.apps, delay: 1.0) }
            if bms { me.schedule(.bookmarks, delay: 0.5) }
        }
        guard let s = FSEventStreamCreate(nil, cb, &context, paths as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.0,
                                          FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf)) else { return }
        FSEventStreamSetDispatchQueue(s, queue)
        FSEventStreamStart(s)
        stream = s
    }
}

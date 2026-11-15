import AppKit
import FredCore

/// Owns the launcher's data: current catalog + searcher, learning, icons.
/// Main-thread only; new catalogs arrive from the Indexer.
@MainActor
final class Engine {
    let searcher = Searcher(Catalog([]))
    let learning: Learning
    private(set) var atlas: IconAtlas?
    /// Atlas slot per catalog item (aligned with catalog item indices).
    private var itemIcons: [Int32] = []
    private var atlasPaths: [String] = []
    private var pendingApps: [AppScanner.App] = []
    private var pendingPanes: [SettingsScanner.Pane] = []
    var onAtlas: ((IconAtlas) -> Void)?
    var onTitles: ((TitleAtlas?) -> Void)?
    /// Fires after every catalog swap (main thread).
    var onCatalogChanged: (() -> Void)?
    /// Pre-rendered catalog titles; nil while (re)building — rows then rasterize.
    private(set) var titles: TitleAtlas?
    static let titleMaxWidth = Theme.width - (Theme.rowInset + 10 + Theme.iconSize + 12) - Theme.rowInset - 14
    /// Fires once, when the first catalog and its icons are in place.
    var onReady: (() -> Void)?

    nonisolated static let dataDirPath = NSHomeDirectory() + "/Library/Application Support/Fred"
    nonisolated static let dataDir: URL = {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Fred", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    init() {
        learning = Learning(logURL: Self.dataDir.appendingPathComponent("learning.log"))
    }

    var catalog: Catalog { searcher.catalog }
    var now: UInt32 { UInt32(Date().timeIntervalSince1970) }

    /// bundle id → (path, display name), for clipboard source-app icons and names.
    private var appsByID: [String: (path: String, name: String)] = [:]

    func appSlot(bundleID: String) -> Int32? {
        guard let p = appsByID[bundleID]?.path else { return nil }
        return atlas?.slot(path: p)
    }

    func appName(bundleID: String) -> String? { appsByID[bundleID]?.name }

    func setCatalog(_ c: Catalog, apps: [AppScanner.App], panes: [SettingsScanner.Pane]) {
        searcher.setCatalog(c)
        titles = nil
        onTitles?(nil)
        let scale = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let names = c.titles
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = nowNanos()
            let t = TitleAtlas(titles: names, font: Theme.rowFont, maxWidth: Engine.titleMaxWidth, scale: scale)
            Log.info("title atlas: \(names.count) titles, \(t.map { "\($0.width)x\($0.height)" } ?? "failed") in \((nowNanos() - t0) / 1000) µs")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.searcher.catalog === c else { return }   // superseded
                    self.titles = t
                    self.onTitles?(t)
                }
            }
        }
        var byID: [String: (path: String, name: String)] = [:]
        for a in apps { if let id = a.bundleID { byID[id] = (a.path, a.name) } }
        appsByID = byID
        learning.prepare(catalog: c, into: searcher, now: now)
        let paths = apps.map(\.path) + panes.map(\.path) + [Bundle.main.bundlePath]
        if paths != atlasPaths {
            atlasPaths = paths
            // Render icons off-main; rows show no icon for the first few ms after launch.
            DispatchQueue.global(qos: .userInitiated).async {
                let t0 = nowNanos()
                let a = IconAtlas(paths: paths)
                Log.info("icon atlas: \(a.slots) icons in \((nowNanos() - t0) / 1_000_000) ms")
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard paths == self.atlasPaths else { return }
                        self.atlas = a
                        self.mapIcons()
                        self.onAtlas?(a)
                        self.onCatalogChanged?()   // rows pick up real icons
                        self.onReady?()
                        self.onReady = nil
                    }
                }
            }
        }
        mapIcons()
        onCatalogChanged?()
    }

    private func mapIcons() {
        let c = catalog
        var icons = [Int32](repeating: 0, count: c.count)
        guard let a = atlas else { itemIcons = icons; return }
        let generic = a.slot(.generic)
        for i in 0..<c.count {
            let p = c.payloads[i]
            switch c.kinds[i] {
            case .app: icons[i] = a.slot(path: p) ?? generic
            case .settings:
                let u = SettingsScanner.openURL(p)
                let id = u.hasPrefix("x-apple.systempreferences:") ? String(u.dropFirst(26)) : u
                icons[i] = a.slot(path: SettingsScanner.extensionsDir + "/" + paneFile(id)) ?? paneSlot(id, a) ?? generic
            case .bookmark: icons[i] = a.slot(.bookmark)
            case .contact: icons[i] = a.slot(.contact)
            case .command:
                switch Command(rawValue: p) {
                case .emptyTrash: icons[i] = a.slot(.emptyTrash)
                case .sleep: icons[i] = a.slot(.sleep)
                case .lock: icons[i] = a.slot(.lock)
                case .restart: icons[i] = a.slot(.restart)
                case .shutDown: icons[i] = a.slot(.shutDown)
                case .forceQuit: icons[i] = a.slot(.forceQuit)
                case .quitFred, .restartFred, .fredSettings, .none: icons[i] = a.slot(path: Bundle.main.bundlePath) ?? a.slot(.fred)
                }
            }
        }
        itemIcons = icons
    }

    /// Pane payloads are URLs; the atlas is keyed by appex path. Map via bundle id.
    private var paneByID: [String: String] = [:]
    private func paneFile(_ id: String) -> String { paneByID[id] ?? "" }
    private func paneSlot(_ id: String, _ a: IconAtlas) -> Int32? {
        for p in atlasPaths where p.hasSuffix(".appex") || p.hasSuffix(".prefPane") {
            if Bundle(path: p)?.bundleIdentifier == id {
                paneByID[id] = (p as NSString).lastPathComponent
                return a.slot(path: p)
            }
        }
        return nil
    }

    func icon(_ item: Int) -> Int32 { item < itemIcons.count ? itemIcons[item] : 0 }
    func slot(_ s: IconAtlas.Static) -> Int32 { atlas?.slot(s) ?? -1 }

    // MARK: Learning

    func prepareLearning() { learning.prepare(catalog: catalog, into: searcher, now: now) }

    func recordPick(item: Int, query: [UInt8], row: Int) {
        learning.record(.init(time: now, key: catalog.keys[item], query: query, row: UInt8(min(row, 255))))
        learning.prepare(catalog: catalog, into: searcher, now: now)
    }
}

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

    func setCatalog(_ c: Catalog, apps: [AppScanner.App], panes: [SettingsScanner.Pane]) {
        searcher.setCatalog(c)
        learning.prepare(catalog: c, into: searcher, now: now)
        let paths = apps.map(\.path) + panes.map(\.path)
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
                    }
                }
            }
        }
        mapIcons()
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
                let id = p.hasPrefix("x-apple.systempreferences:") ? String(p.dropFirst(26)) : p
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
                case .quitFred, .restartFred, .none: icons[i] = a.slot(.fred)
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

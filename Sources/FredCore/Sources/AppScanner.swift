import Foundation

/// Finds installed applications by scanning well-known roots directly.
///
/// Measured on the target Mac: a full scan is ~3 ms (readdir) + ~12 ms for Finder
/// display names, so we just rescan whenever FSEvents says a root changed — there is
/// nothing to cache. Spotlight (`mdfind`) is slower, depends on index health and returns
/// frameworks/helpers; LaunchServices has no public "all apps" API.
///
/// Pitfalls handled:
///   - `/System/Volumes/Data/Applications` is a firmlink of `/Applications` — not scanned.
///   - Safari lives in a cryptex; `/Applications/Safari.app` is a symlink. We keep the
///     symlink path for display/open and dedupe by bundle id.
///   - Never descend into bundles; go at most `depth` levels into plain folders.
///   - Skip `LSBackgroundOnly` helpers. Keep `LSUIElement` menu-bar apps.
public enum AppScanner {
    public struct Root: Sendable { public let path: String; public let depth: Int }

    public static var roots: [Root] {
        let home = NSHomeDirectory()
        return [
            Root(path: "/Applications", depth: 2),
            Root(path: home + "/Applications", depth: 2),       // incl. Chrome Apps.localized
            Root(path: "/System/Applications", depth: 2),       // incl. Utilities
            Root(path: "/System/Library/CoreServices/Applications", depth: 1),
            Root(path: "/opt/homebrew/Cellar", depth: 3),       // formula-installed .apps
        ]
    }

    /// Single bundles outside the roots.
    public static let extras = ["/System/Library/CoreServices/Finder.app"]

    /// Fred doesn't list itself (it has Quit/Restart Fred commands instead).
    public static let ownBundleID = "dev.fred.Fred"

    public struct App: Sendable, Equatable {
        public var path: String
        public var name: String          // Finder display name, without ".app"
        public var fileName: String      // file name without ".app"
        public var bundleName: String?   // CFBundleName
        public var bundleID: String?
    }

    public static func scan() -> [App] {
        var found: [App] = []
        var seenIDs = Set<String>()
        var seenPaths = Set<String>()
        func consider(_ url: URL) {
            let path = url.path
            guard seenPaths.insert(path).inserted, let app = load(url) else { return }
            if let id = app.bundleID {
                guard id != ownBundleID, seenIDs.insert(id).inserted else { return }
            }
            found.append(app)
        }
        let fm = FileManager.default
        func walk(_ dir: URL, _ depth: Int) {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for name in names where !name.hasPrefix(".") {
                let url = dir.appendingPathComponent(name)
                if name.hasSuffix(".app") {
                    consider(url)
                } else if depth > 1 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue {
                        walk(url, depth - 1)
                    }
                }
            }
        }
        for r in roots { walk(URL(fileURLWithPath: r.path, isDirectory: true), r.depth) }
        for p in extras { consider(URL(fileURLWithPath: p, isDirectory: true)) }
        return found
    }

    static func load(_ url: URL) -> App? {
        let resolved = url.resolvingSymlinksInPath()
        let info = NSDictionary(contentsOf: resolved.appendingPathComponent("Contents/Info.plist")) as? [String: Any]
        if let info {
            if (info["LSBackgroundOnly"] as? Bool) == true || (info["LSBackgroundOnly"] as? String) == "1" { return nil }
        }
        var fileName = url.lastPathComponent
        if fileName.hasSuffix(".app") { fileName.removeLast(4) }
        var name = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? fileName
        if name.hasSuffix(".app") { name.removeLast(4) }
        let bundleName = info?["CFBundleName"] as? String
        return App(path: url.path, name: name, fileName: fileName,
                   bundleName: bundleName, bundleID: info?["CFBundleIdentifier"] as? String)
    }

    public static func items(_ apps: [App]) -> [Catalog.Item] {
        apps.map { a in
            var aliases: [String] = []
            if a.fileName != a.name { aliases.append(a.fileName) }
            if let b = a.bundleName, b != a.name, b != a.fileName, !b.isEmpty { aliases.append(b) }
            return Catalog.Item(kind: .app, title: a.name, aliases: aliases, payload: a.path,
                                key: Catalog.key(.app, a.bundleID ?? a.path))
        }
    }
}

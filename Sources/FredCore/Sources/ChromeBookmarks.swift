import Foundation

/// Google Chrome bookmarks across all profiles.
///
/// Profiles are listed in `<Chrome>/Local State` → profile.info_cache. Each profile dir
/// has `Bookmarks` (local) and, for signed-in profiles, `AccountBookmarks` (account
/// storage) — both JSON trees with roots bookmark_bar / other / synced and nodes
/// `{type: "url"|"folder", name, url, children}`. Chrome rewrites the files atomically,
/// so the app watches the profile directories, not the files.
public enum ChromeBookmarks {
    public static var chromeDir: String { NSHomeDirectory() + "/Library/Application Support/Google/Chrome" }

    public struct Bookmark: Sendable, Equatable {
        public var title: String
        public var url: String
        public var folder: String
    }

    /// Profile directories (absolute paths) that exist.
    public static func profileDirs() -> [String] {
        let base = chromeDir
        var names: [String] = []
        if let d = try? Data(contentsOf: URL(fileURLWithPath: base + "/Local State")),
           let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
           let prof = j["profile"] as? [String: Any],
           let cache = prof["info_cache"] as? [String: Any] {
            names = cache.keys.sorted()
        }
        if names.isEmpty { names = ["Default"] }
        return names.map { base + "/" + $0 }.filter { FileManager.default.fileExists(atPath: $0) }
    }

    public static func load() -> [Bookmark] {
        var out: [Bookmark] = []
        var seen = Set<String>()
        for dir in profileDirs() {
            for file in ["Bookmarks", "AccountBookmarks"] {
                guard let d = try? Data(contentsOf: URL(fileURLWithPath: dir + "/" + file)) else { continue }
                for b in parse(d) where seen.insert(b.url).inserted { out.append(b) }
            }
        }
        return out
    }

    public static func parse(_ data: Data) -> [Bookmark] {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = j["roots"] as? [String: Any] else { return [] }
        var out: [Bookmark] = []
        func walk(_ node: [String: Any], _ folder: String) {
            let type = node["type"] as? String
            if type == "url" {
                guard let url = node["url"] as? String, !url.hasPrefix("javascript:") else { return }
                var title = (node["name"] as? String) ?? ""
                if title.isEmpty { title = url }
                out.append(Bookmark(title: title, url: url, folder: folder))
            } else if let kids = node["children"] as? [[String: Any]] {
                let name = (node["name"] as? String) ?? folder
                for k in kids { walk(k, name) }
            }
        }
        for key in ["bookmark_bar", "other", "synced"] {
            if let r = roots[key] as? [String: Any] { walk(r, "") }
        }
        return out
    }

    /// Host without "www.", used as a secondary search field ("github.com").
    public static func host(_ url: String) -> String? {
        guard var h = URL(string: url)?.host else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }

    public static func items(_ bookmarks: [Bookmark]) -> [Catalog.Item] {
        bookmarks.map { b in
            var sec: [String] = []
            if let h = host(b.url), h != b.title { sec.append(h) }
            return Catalog.Item(kind: .bookmark, title: b.title, secondary: sec, payload: b.url)
        }
    }
}

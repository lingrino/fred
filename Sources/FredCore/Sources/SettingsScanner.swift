import Foundation

/// System Settings panes.
///
/// Since macOS 13 every pane is an ExtensionKit extension in
/// /System/Library/ExtensionKit/Extensions whose Info.plist declares
/// `EXAppExtensionAttributes.EXExtensionPointIdentifier = com.apple.Settings.extension.ui`.
/// The plist's CFBundleDisplayName is often an internal name ("PowerPreferences"), so the
/// user-facing name comes from the localized info dictionary, then Finder's name.
/// A pane opens with the URL `x-apple.systempreferences:<bundle id>`.
public enum SettingsScanner {
    public static let extensionsDir = "/System/Library/ExtensionKit/Extensions"
    static let point = "com.apple.Settings.extension.ui"

    /// Panes that only exist for specific hardware/management or are internal plumbing.
    static let hidden: Set<String> = [
        "com.apple.FollowUpSettings.FollowUpSettingsExtension",
        "com.apple.Coverage-Settings.extension",
        "com.apple.Classroom-Settings.extension",
        "com.apple.ClassKit-Settings.extension",
        "com.apple.CD-DVD-Settings.extension",
        "com.apple.SecurityImprovements-Settings.extension",
    ]

    /// Names used when the bundle gives nothing better (keyed by bundle id).
    static let fallbackNames: [String: String] = [
        "com.apple.Accessibility-Settings.extension": "Accessibility",
        "com.apple.AirDrop-Handoff-Settings.extension": "AirDrop & Handoff",
        "com.apple.ControlCenter-Settings.extension": "Control Center",
        "com.apple.Date-Time-Settings.extension": "Date & Time",
        "com.apple.Focus-Settings.extension": "Focus",
        "com.apple.systempreferences.GeneralSettings": "General",
        "com.apple.HeadphoneSettings": "Headphones",
        "com.apple.Internet-Accounts-Settings.extension": "Internet Accounts",
        "com.apple.Lock-Screen-Settings.extension": "Lock Screen",
        "com.apple.LoginItems-Settings.extension": "Login Items & Extensions",
        "com.apple.Mouse-Settings.extension": "Mouse",
        "com.apple.Network-Settings.extension": "Network",
        "com.apple.Battery-Settings.extension": "Battery",
        "com.apple.Software-Update-Settings.extension": "Software Update",
        "com.apple.Time-Machine-Settings.extension": "Time Machine",
        "com.apple.Trackpad-Settings.extension": "Trackpad",
        "com.apple.Users-Groups-Settings.extension": "Users & Groups",
        "com.apple.wifi-settings-extension": "Wi-Fi",
        "com.apple.settings.PrivacySecurity.extension": "Privacy & Security",
        "com.apple.Desktop-Settings.extension": "Desktop & Dock",
        "com.apple.systempreferences.AppleIDSettings": "Apple Account",
    ]

    /// Extra search terms for panes whose name hides what's inside.
    static let keywords: [String: [String]] = [
        "com.apple.Desktop-Settings.extension": ["Dock", "Mission Control", "Stage Manager", "Hot Corners",
                                                 "Default web browser", "Widgets", "Magnification", "Hide Dock"],
        "com.apple.wifi-settings-extension": ["WiFi", "Wireless", "Hotspot", "Known networks"],
        "com.apple.Trackpad-Settings.extension": ["Tap to click", "Natural scrolling", "Scroll direction",
                                                  "Tracking speed", "Force Click", "Gestures"],
        "com.apple.Mouse-Settings.extension": ["Tracking speed", "Natural scrolling", "Scroll direction", "Secondary click"],
        "com.apple.ControlCenter-Settings.extension": ["Control Center", "Battery percentage", "Menu bar items", "Clock"],
        "com.apple.Notifications-Settings.extension": ["Banners", "Alerts", "Notification previews"],
        "com.apple.Battery-Settings.extension": ["Energy", "Energy Saver", "Power"],
        "com.apple.Lock-Screen-Settings.extension": ["Screen Saver"],
        "com.apple.Localization-Settings.extension": ["Language", "Region"],
        "com.apple.Touch-ID-Settings.extension": ["Password", "Fingerprint"],
        "com.apple.settings.PrivacySecurity.extension": ["Security", "Permissions"],
        "com.apple.Network-Settings.extension": ["Ethernet", "Firewall"],
    ]

    public struct Pane: Sendable, Equatable {
        public var bundleID: String
        public var name: String
        public var path: String
        /// Settings inside the pane, from its own search-terms file: (title, keywords).
        /// The entry titled like the pane itself ("Appearance": "Dark Mode", "theme", …)
        /// becomes `searchTerms` instead.
        public var subsettings: [Sub] = []
        public var searchTerms: [String] = []
        public var url: String { "x-apple.systempreferences:" + bundleID }
    }

    public struct Sub: Sendable, Equatable {
        public var title: String
        public var keywords: [String]
    }

    public static func scan() -> [Pane] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: extensionsDir) else { return [] }
        var panes: [Pane] = []
        for n in names where n.hasSuffix(".appex") {
            let path = extensionsDir + "/" + n
            let url = URL(fileURLWithPath: path, isDirectory: true)
            guard let info = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
                  let ex = info["EXAppExtensionAttributes"] as? [String: Any],
                  ex["EXExtensionPointIdentifier"] as? String == point,
                  let id = info["CFBundleIdentifier"] as? String,
                  !hidden.contains(id) else { continue }
            let name = displayName(url: url, id: id, info: info)
            let (subs, own) = subsettings(url, paneName: name)
            panes.append(Pane(bundleID: id, name: name, path: path, subsettings: subs, searchTerms: own))
        }
        // Legacy/third-party .prefPane bundles (rare on modern macOS).
        for dir in ["/Library/PreferencePanes", NSHomeDirectory() + "/Library/PreferencePanes"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".prefPane") {
                let path = dir + "/" + n
                let id = Bundle(path: path)?.bundleIdentifier ?? path
                panes.append(Pane(bundleID: id, name: String(n.dropLast(9)), path: path))
            }
        }
        return pruneKeywords(panes).sorted { $0.name < $1.name }
    }

    /// Sub-setting terms shared by many settings ("privacy" ×25, "screen" ×16) can't
    /// single one out and only cost search time (each index entry is scanned per
    /// keystroke); they are dropped. A pane keeps its own terms ("dark" → Appearance).
    /// Terms repeating a word of the title add nothing anywhere. About a third go.
    static let maxTermShare = 4

    static func pruneKeywords(_ panes: [Pane]) -> [Pane] {
        var share: [String: Int] = [:]
        for p in panes {
            for k in Set(p.searchTerms.map { $0.lowercased() }) { share[k, default: 0] += 1 }
            for s in p.subsettings { for k in Set(s.keywords.map { $0.lowercased() }) { share[k, default: 0] += 1 } }
        }
        func keep(_ kws: [String], title: String, shared: Bool) -> [String] {
            let words = Set(title.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            var seen = Set<String>()
            return kws.filter {
                let k = $0.lowercased()
                return (shared || share[k, default: 0] < maxTermShare) && !words.contains(k) && k != title.lowercased() && seen.insert(k).inserted
            }
        }
        return panes.map { p in
            var p = p
            p.searchTerms = keep(p.searchTerms, title: p.name, shared: true)
            p.subsettings = p.subsettings.map { Sub(title: $0.title, keywords: keep($0.keywords, title: $0.title, shared: false)) }
            return p
        }
    }

    /// Names that win over anything the bundle says (the bundle picks the wrong one).
    static let forcedNames: [String: String] = [
        "com.apple.Battery-Settings.extension": "Battery",
    ]

    /// Each pane ships `Contents/Resources/en.lproj/*.searchTerms`: a plist of sections,
    /// each with `localizableStrings: [{title, index}]` where `index` is comma-separated
    /// keywords. That's what System Settings' own search uses.
    static func subsettings(_ appex: URL, paneName: String) -> (subs: [Sub], own: [String]) {
        let dir = appex.appendingPathComponent("Contents/Resources/en.lproj")
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return ([], []) }
        var out: [Sub] = []
        var own: [String] = []
        var seen = Set<String>()
        for f in files.sorted() where f.hasSuffix(".searchTerms") {
            guard let d = NSDictionary(contentsOf: dir.appendingPathComponent(f)) as? [String: Any] else { continue }
            for key in d.keys.sorted() {
                guard let section = d[key] as? [String: Any],
                      let strings = section["localizableStrings"] as? [[String: Any]] else { continue }
                for e in strings {
                    guard let title = (e["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
                          seen.insert(title.lowercased()).inserted else { continue }
                    let kw = ((e["index"] as? String) ?? "").split(separator: ",")
                        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if title.caseInsensitiveCompare(paneName) == .orderedSame { own = kw } else { out.append(Sub(title: title, keywords: kw)) }
                }
            }
        }
        return (out, own)
    }

    static func displayName(url: URL, id: String, info: [String: Any]) -> String {
        if let s = forcedNames[id] { return s }
        let b = Bundle(url: url)
        // object(forInfoDictionaryKey:) reads the localized InfoPlist.loctable.
        if let s = b?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String, isUserFacing(s) { return s }
        // Some panes (Battery, Touch ID) name themselves via sidebar representations.
        if let b, let ex = info["EXAppExtensionAttributes"] as? [String: Any],
           let attrs = ex["SettingsExtensionAttributes"] as? [String: Any],
           let reps = attrs["representations"] as? [[String: Any]] {
            for r in reps {
                if let k = r["sidebar-name"] as? String {
                    let s = b.localizedString(forKey: k, value: k, table: nil)
                    if s != k, isUserFacing(s) { return s }
                }
            }
        }
        if let s = fallbackNames[id] { return s }
        if let s = try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName {
            let t = s.hasSuffix(".appex") ? String(s.dropLast(6)) : s
            if isUserFacing(t) { return t }
        }
        if let s = info["CFBundleDisplayName"] as? String, !s.isEmpty { return s }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Internal names look like "PowerPreferences", "TimeMachineSettings", "XExtension".
    static func isUserFacing(_ s: String) -> Bool {
        if s.isEmpty { return false }
        for bad in ["Extension", "Settings", "Preferences", "Ext", "_macOS"] where s.hasSuffix(bad) && !s.contains(" ") {
            return false
        }
        return true
    }

    /// The pane itself, plus one weak item per sub-setting ("True Tone" → Displays). A
    /// sub-item's payload is the pane URL + "#title" (unique learning key; the fragment is
    /// dropped when opening).
    public static func items(_ panes: [Pane]) -> [Catalog.Item] {
        var out: [Catalog.Item] = []
        for p in panes {
            out.append(Catalog.Item(kind: .settings, title: p.name, secondary: keywords[p.bundleID] ?? [], payload: p.url,
                                    weakKeywords: Array(p.searchTerms.prefix(16))))
            for sub in p.subsettings {
                out.append(Catalog.Item(kind: .settings, title: sub.title, payload: p.url + "#" + sub.title,
                                        detail: p.name, weak: true, weakKeywords: Array(sub.keywords.prefix(16))))
            }
        }
        return out
    }

    /// The URL to open for a settings payload (strips a sub-setting's "#title").
    public static func openURL(_ payload: String) -> String {
        payload.split(separator: "#", maxSplits: 1).first.map(String.init) ?? payload
    }
}

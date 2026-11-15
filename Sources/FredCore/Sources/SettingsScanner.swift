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
        "com.apple.Desktop-Settings.extension": ["Dock", "Mission Control", "Stage Manager"],
        "com.apple.wifi-settings-extension": ["WiFi", "Wireless"],
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
        public var url: String { "x-apple.systempreferences:" + bundleID }
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
            panes.append(Pane(bundleID: id, name: displayName(url: url, id: id, info: info), path: path))
        }
        // Legacy/third-party .prefPane bundles (rare on modern macOS).
        for dir in ["/Library/PreferencePanes", NSHomeDirectory() + "/Library/PreferencePanes"] {
            for n in (try? fm.contentsOfDirectory(atPath: dir)) ?? [] where n.hasSuffix(".prefPane") {
                let path = dir + "/" + n
                let id = Bundle(path: path)?.bundleIdentifier ?? path
                panes.append(Pane(bundleID: id, name: String(n.dropLast(9)), path: path))
            }
        }
        return panes.sorted { $0.name < $1.name }
    }

    /// Names that win over anything the bundle says (the bundle picks the wrong one).
    static let forcedNames: [String: String] = [
        "com.apple.Battery-Settings.extension": "Battery",
    ]

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

    public static func items(_ panes: [Pane]) -> [Catalog.Item] {
        panes.map { p in
            Catalog.Item(kind: .settings, title: p.name, secondary: keywords[p.bundleID] ?? [], payload: p.url)
        }
    }
}

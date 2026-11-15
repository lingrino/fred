import AppKit
@preconcurrency import Contacts

/// Every privacy grant Fred needs, how to check it silently, and how to trigger the
/// system prompt / registration so it shows up in System Settings.
///
/// Grants are keyed on Fred's designated requirement (bundle id + signing certificate
/// leaf), which is stable across rebuilds because of the local signing identity — so
/// each grant only has to be given once.
///
///   contacts      Contacts                         prompt (Allow)
///   postEvents    "Device Control and Data Access" toggle (formerly Accessibility); paste ⌘V
///   pasteboard    Paste from Other Apps            set to Allow (clipboard history reads)
///   chromeData    Files & Folders → Google Chrome  toggle (macOS 27 app-data protection)
///   finder        Automation → Finder              prompt (Empty Trash)
@MainActor
enum Permissions {
    enum Kind: String, CaseIterable {
        case contacts, postEvents, pasteboard, chromeData, finder
    }

    static func status(_ k: Kind) -> Bool? {
        switch k {
        case .contacts:
            return CNContactStore.authorizationStatus(for: .contacts) == .authorized
        case .postEvents:
            return CGPreflightPostEventAccess()
        case .pasteboard:
            switch NSPasteboard.general.accessBehavior {
            case .alwaysAllow: return true
            case .alwaysDeny: return false
            default: return nil   // .default (never asked) or .ask
            }
        case .chromeData:
            let p = ChromeData.probePath
            return FileManager.default.isReadableFile(atPath: p) && (try? Data(contentsOf: URL(fileURLWithPath: p), options: .alwaysMapped)) != nil
        case .finder:
            return automationStatus(bundleID: "com.apple.finder", ask: false)
        }
    }

    /// Triggers prompts for anything not granted. Each OS prompt appears at most once.
    static func requestMissing() {
        if status(.contacts) != true {
            CNContactStore().requestAccess(for: .contacts) { _, _ in }
        }
        if status(.postEvents) != true {
            _ = CGRequestPostEventAccess()
        }
        if status(.pasteboard) != true {
            // A programmatic read registers Fred in "Paste from Other Apps" (and may alert).
            _ = NSPasteboard.general.string(forType: .string)
        }
        if status(.chromeData) != true {
            // A read attempt triggers the one-time "Data Access Blocked" notice and adds
            // Fred to Files & Folders, where the user can enable it.
            _ = try? Data(contentsOf: URL(fileURLWithPath: ChromeData.probePath))
        }
        if status(.finder) != true {
            DispatchQueue.global(qos: .utility).async { _ = automationStatus(bundleID: "com.apple.finder", ask: true) }
        }
    }

    nonisolated static func automationStatus(bundleID: String, ask: Bool) -> Bool? {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return nil }
        let st = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, ask)
        switch st {
        case noErr: return true
        case OSStatus(errAEEventNotPermitted): return false
        default: return nil   // -1744 would need consent / -600 Finder not running
        }
    }

    static func report() -> String {
        Kind.allCases.map { k in
            let s = status(k)
            return "\(k.rawValue): \(s == true ? "granted" : s == false ? "DENIED" : "not yet")"
        }.joined(separator: "\n")
    }
}

enum ChromeData {
    static let probePath = NSHomeDirectory() + "/Library/Application Support/Google/Chrome/Local State"
}

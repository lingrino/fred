/// Built-in system commands (emptytrash, sleep, lock, restart, shutdown, forcequit — none
/// with confirmation),
/// plus Fred's own lifecycle commands since Fred has no menu bar icon.
public enum Command: String, CaseIterable, Sendable {
    case emptyTrash = "emptytrash"
    case sleep
    case lock
    case restart
    case shutDown = "shutdown"
    case forceQuit = "forcequit"
    case quitFred = "quitfred"
    case restartFred = "restartfred"
    case fredSettings = "fredsettings"

    public var title: String {
        switch self {
        case .emptyTrash: "Empty Trash"
        case .sleep: "Sleep"
        case .lock: "Lock"
        case .restart: "Restart"
        case .shutDown: "Shut Down"
        case .forceQuit: "Force Quit…"
        case .quitFred: "Quit Fred"
        case .restartFred: "Restart Fred"
        case .fredSettings: "Fred Settings"
        }
    }

    /// One-word keywords — full-strength aliases.
    public var aliases: [String] {
        switch self {
        case .emptyTrash: ["emptytrash"]
        case .shutDown: ["shutdown"]
        case .forceQuit: ["forcequit"]
        default: []
        }
    }

    /// Synonyms — searchable, one tier weaker than the title.
    public var synonyms: [String] {
        switch self {
        case .emptyTrash: ["Trash"]
        case .restart: ["Reboot"]
        case .shutDown: ["Power Off"]
        case .forceQuit: ["Kill"]
        case .restartFred: ["Reload Fred"]
        case .fredSettings: ["Fred Preferences", "Fred Permissions"]
        case .lock: ["Lock Screen"]
        default: []
        }
    }

    public static func items() -> [Catalog.Item] {
        allCases.map { Catalog.Item(kind: .command, title: $0.title, aliases: $0.aliases, secondary: $0.synonyms, payload: $0.rawValue) }
    }
}

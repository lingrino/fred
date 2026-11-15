import ServiceManagement

/// Starts Fred at login via SMAppService (the app itself as the login item). Requires
/// the stable signature and the copy in /Applications; dev builds elsewhere skip it.
enum LoginItem {
    @MainActor
    static func ensureRegistered() {
        guard Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        let s = SMAppService.mainApp
        guard s.status != .enabled else { return }
        do { try s.register() } catch { Log.error("login item: \(error)") }
        Log.info("login item status: \(s.status.rawValue)")
    }

    static var statusLine: String {
        switch SMAppService.mainApp.status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval (System Settings → General → Login Items)"
        case .notRegistered: "not registered"
        case .notFound: "not found"
        @unknown default: "unknown"
        }
    }
}

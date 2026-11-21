import Foundation
import FredCore

/// Brings Fred back after it dies without saying goodbye: a trap, a memory kill, kill -9.
/// 0.0.48 crashed on 2026-11-21 and stayed down, hotkeys dead, until the user noticed: a
/// login item is started once, and nothing restarts it.
///
/// Each Fred keeps one small child: `/bin/sh` blocked reading a pipe only Fred can write.
/// "quit" on the pipe ends the child (every deliberate exit: Quit Fred, Restart Fred, an
/// upgrade's self-restart, logout, SIGTERM). End-of-file without it means Fred is gone,
/// and the child opens the bundle again, the way `Actions.relaunch` does. No polling.
///
/// Why not a launchd agent with KeepAlive: every start (login, upgrade, `make install`,
/// Restart Fred, Finder) would have to go through launchd or run unsupervised; the agent
/// is one more Login Items entry to allow on every Mac; and it starts Fred outside
/// LaunchServices, which the privacy grants have never been tried with.
///
/// A Fred that keeps crashing is not brought back forever: the child hands the times of
/// the recent crashes to the next Fred (`--crashed`), which doesn't arm once
/// `RelaunchPolicy` says so.
@MainActor
enum CrashRelaunch {
    /// For `fredctl stats` and Fred Settings: "armed", or "off: <why>".
    private(set) static var status = "off: not started yet"
    /// Set when this Fred was started after a crash: that crash, in Unix seconds.
    private(set) static var lastCrash: Int?

    /// Write end of the child's pipe; -1 until armed, then never closed or changed (the
    /// SIGTERM handler reads it off main, and a closed descriptor's number gets reused).
    nonisolated(unsafe) private static var goodbye: Int32 = -1
    nonisolated(unsafe) private static var leaving = false
    private static var helper: Process?
    private static var sigterm: DispatchSourceSignal?

    /// $0 = the bundle, $1 = the earlier crash times.
    private static let script = """
        read -r said; [ "$said" = quit ] && exit 0
        exec /usr/bin/open "$0" --args --crashed "$1,$(/bin/date +%s)"
        """

    static func arm() {
        guard goodbye < 0 else { return }
        let args = CommandLine.arguments
        let now = Int(Date().timeIntervalSince1970)
        var crashes: [Int] = []
        if let i = args.firstIndex(of: "--crashed"), i + 1 < args.count { crashes = RelaunchPolicy.recent(args[i + 1], now: now) }
        lastCrash = crashes.last
        if let last = crashes.last {
            Log.error("started again \(now - last) s after a crash (\(crashes.count) in the last \(RelaunchPolicy.window / 60) min)")
        }
        // A bare binary (run from .build) has a directory for a bundle path: `open` would
        // show it in Finder.
        let bundle = Bundle.main.bundlePath
        guard bundle.hasSuffix(".app") else { off("not running from an app bundle"); return }
        guard RelaunchPolicy.rearm(after: crashes) else {
            off("crashed \(crashes.count) times in \(RelaunchPolicy.window / 60) min, the next crash is final")
            return
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { off("pipe: errno \(errno)"); return }
        // Only Fred may hold the write end: a child that inherited it would keep the pipe
        // open after Fred is gone.
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, bundle, RelaunchPolicy.argument(crashes)]
        p.standardInput = FileHandle(fileDescriptor: fds[0], closeOnDealloc: false)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // Before Fred says goodbye, the child only exits if something killed it.
        p.terminationHandler = { _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { if !leaving { off("the helper process is gone") } } }
        }
        do { try p.run() } catch {
            close(fds[0]); close(fds[1])
            off("could not start the helper: \(error.localizedDescription)")
            return
        }
        close(fds[0])
        helper = p
        goodbye = fds[1]
        status = "armed"
        Log.info("crash relaunch armed (helper pid \(p.processIdentifier))")

        // SIGTERM (`pkill -x Fred` in `make install`, shutdown) is a deliberate exit too.
        // Handled off main, so a hung Fred still dies when told to.
        signal(SIGTERM, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global(qos: .userInteractive))
        let terminate: @Sendable () -> Void = {
            disarm()
            signal(SIGTERM, SIG_DFL)
            kill(getpid(), SIGTERM)
        }
        s.setEventHandler(handler: terminate)
        s.resume()
        sigterm = s
    }

    /// Fred is exiting on purpose: the child must not bring it back. Any thread; SIGPIPE
    /// is ignored (main.swift), so a child that is already gone is just an error return.
    nonisolated static func disarm() {
        leaving = true
        let fd = goodbye
        guard fd >= 0 else { return }
        _ = "quit\n".withCString { write(fd, $0, 5) }
    }

    private static func off(_ why: String) {
        status = "off: \(why)"
        Log.error("crash relaunch \(status)")
    }
}

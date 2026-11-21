/// When to stop bringing Fred back after crashes (the app's `CrashRelaunch` does the
/// relaunching). The times of the recent crashes travel from one Fred to the next as a
/// launch argument, "t1,t2,…" in epoch seconds: no state file that could go stale.
public enum RelaunchPolicy {
    /// At most `limit` relaunches for crashes within `window` seconds: a Fred that dies
    /// soon after every start must not be restarted forever.
    public static let limit = 3
    public static let window = 600

    /// The crash times in `arg` that still count at `now`. Anything unreadable, in the
    /// future (the clock was set back) or older than `window` is dropped.
    public static func recent(_ arg: String, now: Int) -> [Int] {
        arg.split(separator: ",").compactMap { Int($0) }.filter { $0 <= now && $0 > now - window }
    }

    /// Whether a Fred started after `crashes` is brought back if it crashes too.
    public static func rearm(after crashes: [Int]) -> Bool { crashes.count < limit }

    public static func argument(_ crashes: [Int]) -> String {
        crashes.map { String($0) }.joined(separator: ",")
    }
}

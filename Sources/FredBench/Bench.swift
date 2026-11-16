import FredCore
import Foundation

/// Search micro-benchmarks. The baselined numbers run over a synthetic, seeded catalog
/// shaped like a heavy real one (apps, settings panes with sub-settings, commands, 3,000
/// bookmarks, 1,500 contacts), so installing an app or an OS update doesn't move them;
/// the same queries over this Mac's real catalog are printed after, for reference only.
/// Runs at user-interactive QoS (P-cores), warms up, reports min/p50/p99 per query.
/// Each section has its own RNG seed, so no section's input depends on another's.
enum Bench {
    /// (name, p50 ns) of every benchmark, in print order; compared with / saved to the
    /// committed baseline (`make bench` / `make bench-save`).
    nonisolated(unsafe) static var results: [(name: String, p50: UInt64)] = []
    static let baselinePath = "Benchmarks/baseline.tsv"

    /// Records the median of `sorted` (ascending) under `name`.
    static func record(_ name: String, _ sorted: [UInt64]) { results.append((name, sorted[sorted.count / 2])) }

    static func run(save: Bool) {
        runAll()
        if save { saveBaseline() } else { compareBaseline() }
    }

    static func saveBaseline() {
        let body = results.map { "\($0.name)\t\($0.p50)" }.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(atPath: "Benchmarks", withIntermediateDirectories: true)
            try body.write(toFile: baselinePath, atomically: true, encoding: .utf8)
            print("\nsaved \(results.count) p50s to \(baselinePath)")
        } catch { print("\ncan't save baseline: \(error)") }
    }

    /// Medians move a few % run to run (±10% on sub-µs ones); ≥ 20% AND ≥ 0.5 µs slower
    /// is worth a look (run again first).
    static func compareBaseline() {
        guard let text = try? String(contentsOfFile: baselinePath, encoding: .utf8) else {
            print("\nno \(baselinePath) yet (make bench-save)"); return
        }
        var base: [String: UInt64] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: "\t")
            if f.count == 2, let v = UInt64(f[1]) { base[String(f[0])] = v }
        }
        print("\np50 vs \(baselinePath) (⚠ = ≥20% and ≥0.5 µs slower):")
        var flagged = 0
        for r in results {
            guard let b = base[r.name], b > 0 else { print(pad(r.name, 30), "new"); continue }
            let d = (Double(r.p50) - Double(b)) / Double(b) * 100
            let worse = d >= 20 && r.p50 >= b + 500
            if worse { flagged += 1 }
            print(pad(r.name, 30), fmt(b), "→", fmt(r.p50), String(format: "%+6.0f%%", d), worse ? "⚠" : "")
        }
        print(flagged == 0 ? "no regressions" : "\(flagged) regression(s) — rerun to rule out noise")
    }

    static let queries = ["f", "ch", "chr", "sys set", "goo cal", "vsc", "settngs", "a", "e", "re", "rea", "mes", "zzz", "x",
                          "system settings", "activity", "term", "kel", "co", "ma"]

    static func runAll() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        var rng = SplitMix(seed: 42)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let catalog = Catalog(syntheticApps(250, &rng) + syntheticSettings(45, subsettings: 650, &rng) + Command.items()
                              + syntheticBookmarks(3000, &rng) + syntheticContacts(1500, &rng))
        let t2 = DispatchTime.now().uptimeNanoseconds
        print("synthetic catalog: \(catalog.count) items, \(catalog.index.count) entries, \(catalog.index.byteCount) bytes")
        print(String(format: "  build index %.2f ms", Double(t2 - t1) / 1e6))
        searchBench(catalog, record: true)

        // Query construction (per keystroke) on its own.
        var qs: [UInt64] = []
        for _ in 0..<5000 {
            let a = DispatchTime.now().uptimeNanoseconds
            let q = Matcher.Query("sys set")
            let b = DispatchTime.now().uptimeNanoseconds
            blackHole(q.count)
            qs.append(b - a)
        }
        qs.sort()
        record("Matcher.Query", qs)
        print("Matcher.Query(\"sys set\"): p50 \(fmt(qs[qs.count / 2]))")

        var crng = SplitMix(seed: 7)
        clipBench(&crng)
        calcBench()
        converterBench()

        let t3 = DispatchTime.now().uptimeNanoseconds
        let real = Catalog(AppScanner.items(AppScanner.scan()) + SettingsScanner.items(SettingsScanner.scan()) + Command.items())
        let t4 = DispatchTime.now().uptimeNanoseconds
        print("\nthis Mac's catalog (not baselined): \(real.count) items, \(real.index.count) entries, scan + index \(String(format: "%.1f", Double(t4 - t3) / 1e6)) ms")
        searchBench(real, record: false)
    }

    static func searchBench(_ catalog: Catalog, record save: Bool) {
        var rng = SplitMix(seed: 99)
        let searcher = Searcher(catalog)
        let learn = Learning(logURL: nil)
        // Some learning history so boosts are exercised.
        let now: UInt32 = 1_800_000_000
        for i in 0..<400 {
            let item = Int(rng.next() % UInt64(catalog.count))
            let title = Array(Fold.query(catalog.titles[item]).prefix(Int(rng.next() % 4) + 1))
            learn.record(.init(time: now - UInt32(i * 3600), key: catalog.keys[item], query: title, row: 0))
        }
        learn.prepare(catalog: catalog, into: searcher, now: now)

        print("\nsearch (k=5, with learning), µs per query:")
        print("query                min     p50     p99")
        var total: [UInt64] = []
        for q in queries {
            let mq = Matcher.Query(q)
            var samples: [UInt64] = []
            for _ in 0..<200 { _ = searcher.search(mq, k: 5, learn: learn, now: now) }   // warm
            for _ in 0..<2000 {
                let a = DispatchTime.now().uptimeNanoseconds
                let r = searcher.search(mq, k: 5, learn: learn, now: now)
                let b = DispatchTime.now().uptimeNanoseconds
                blackHole(r.count)
                samples.append(b - a)
            }
            samples.sort()
            total += samples
            if save { record("search \"\(q)\"", samples) }
            print(pad(q, 18), fmt(samples[0]), fmt(samples[samples.count / 2]), fmt(samples[samples.count * 99 / 100]))
        }
        total.sort()
        print("all queries: p50 \(fmt(total[total.count / 2]))  p99 \(fmt(total[total.count * 99 / 100]))")
    }

    static func clipBench(_ rng: inout SplitMix) {
        let store = ClipStore(dir: nil)
        let words = ["kubernetes", "deploy", "error", "https://example.com/", "func", "return", "lorem", "ipsum", "dolor",
                     "select * from users", "TODO", "password reset", "invoice", "meeting notes", "café", "résumé"]
        let t0 = DispatchTime.now().uptimeNanoseconds
        for i in 0..<5000 {
            var s = ""
            let n = Int(rng.next() % 200) + 3
            for _ in 0..<n { s += words[Int(rng.next() % UInt64(words.count))] + (rng.next() % 7 == 0 ? "\n" : " ") }
            store.add(kind: .text, text: s, hash: UInt64(i) &* 0x9E37_79B9_7F4A_7C15, app: "com.app", time: UInt32(i))
        }
        let t1 = DispatchTime.now().uptimeNanoseconds
        print(String(format: "\nclipboard: 5000 clips added in %.1f ms", Double(t1 - t0) / 1e6))
        for q in ["", "kube", "example deploy", "zzzz", "résumé", "e"] {
            var samples: [UInt64] = []
            for _ in 0..<300 {
                let a = DispatchTime.now().uptimeNanoseconds
                let r = store.search(q, limit: 500)
                let b = DispatchTime.now().uptimeNanoseconds
                blackHole(r.count)
                samples.append(b - a)
            }
            samples.sort()
            record("clip \"\(q)\"", samples)
            print(pad("clip \"\(q)\"", 22), fmt(samples[0]), fmt(samples[samples.count / 2]), fmt(samples[samples.count * 99 / 100]))
        }
    }

    static func calcBench() {
        var samples: [UInt64] = []
        for _ in 0..<5000 {
            let a = DispatchTime.now().uptimeNanoseconds
            let r = Calculator.evaluate("(1200*3)/4 + 2^8")
            let b = DispatchTime.now().uptimeNanoseconds
            blackHole(r?.value ?? 0)
            samples.append(b - a)
        }
        samples.sort()
        record("calculator", samples)
        print("\ncalculator: p50 \(fmt(samples[samples.count / 2])) (includes result formatting)")
    }

    /// Every keystroke runs the converter (after the calculator declines), so typical
    /// non-conversion queries matter as much as real conversions.
    static func converterBench() {
        print("\nconverter (µs)          p0      p50     p99")
        let utc = TimeZone(identifier: "UTC")!
        for q in ["safari", "time machine", "2fold", "macos 27", "5 km in mi", "1 GiB to MB", "100 mbps in MB/s",
                  "72 f", "90 min", "3pm pst in tokyo", "tokyo time", "now in london"] {
            _ = Converter.evaluate(q, zone: utc)   // first-use table setup
            var samples: [UInt64] = []
            for _ in 0..<3000 {
                let a = DispatchTime.now().uptimeNanoseconds
                let r = Converter.evaluate(q, zone: utc)
                let b = DispatchTime.now().uptimeNanoseconds
                blackHole(r)
                samples.append(b - a)
            }
            samples.sort()
            record("converter \"\(q)\"", samples)
            print(pad("\"\(q)\"", 22), fmt(samples[0]), fmt(samples[samples.count / 2]), fmt(samples[samples.count * 99 / 100]))
        }
    }

    static let appWords = ["Goober", "Chroma", "Vivid", "Story", "Composer", "Studio", "Pixel", "Note", "Notes", "Code",
                           "Terminal", "Mail", "Music", "Photo", "Photos", "Calendar", "Settings", "System", "Monitor",
                           "Activity", "Disk", "Utility", "Sync", "Cloud", "Drive", "Office", "Sheets", "Writer", "Draw",
                           "Kelp", "Mesa", "Zephyr", "Tally", "Vector", "Script", "Editor", "Viewer", "Player", "Maps"]

    /// Apps with display names, file-name and CFBundleName aliases.
    static func syntheticApps(_ n: Int, _ rng: inout SplitMix) -> [Catalog.Item] {
        (0..<n).map { i in
            let k = Int(rng.next() % 3) + 1
            let name = (0..<k).map { _ in appWords[Int(rng.next() % UInt64(appWords.count))] }.joined(separator: " ")
            let aliases = rng.next() % 3 == 0 ? [name.replacingOccurrences(of: " ", with: "") + "\(i % 7)"] : []
            return Catalog.Item(kind: .app, title: name, aliases: aliases, payload: "/Applications/App\(i).app", key: UInt64(i))
        }
    }

    /// Panes with search terms, plus sub-settings (weak, with a detail and keywords) spread
    /// over them, like SettingsScanner produces.
    static func syntheticSettings(_ panes: Int, subsettings: Int, _ rng: inout SplitMix) -> [Catalog.Item] {
        let words = ["Display", "Displays", "Sound", "Keyboard", "Trackpad", "Mouse", "Network", "Battery", "Privacy",
                     "Security", "Appearance", "Desktop", "Dock", "Wallpaper", "Screen", "Saver", "Time", "Notifications",
                     "Focus", "Sharing", "General", "Login", "Items", "Accessibility", "Zoom", "Contrast", "Night", "Shift",
                     "True", "Tone", "Resolution", "Brightness", "Volume", "Input", "Output", "Language", "Region", "Siri",
                     "Spotlight", "Control", "Center", "Bluetooth", "Wi-Fi", "Energy", "Hot", "Corners", "Dark", "Mode"]
        func phrase(_ n: Int) -> String { (0..<n).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ") }
        var out: [Catalog.Item] = []
        var paneNames: [String] = []
        for p in 0..<panes {
            let name = phrase(Int(rng.next() % 2) + 1)
            paneNames.append(name)
            out.append(.init(kind: .settings, title: name, payload: "pane\(p)",
                             weakKeywords: (0..<Int(rng.next() % 6)).map { _ in phrase(Int(rng.next() % 2) + 1) }))
        }
        for s in 0..<subsettings {
            let pane = Int(rng.next() % UInt64(panes))
            out.append(.init(kind: .settings, title: phrase(Int(rng.next() % 3) + 1), payload: "pane\(pane)#\(s)",
                             detail: paneNames[pane], weak: true,
                             weakKeywords: (0..<Int(rng.next() % 5)).map { _ in phrase(Int(rng.next() % 3) + 1) }))
        }
        return out
    }

    static func syntheticBookmarks(_ n: Int, _ rng: inout SplitMix) -> [Catalog.Item] {
        let words = ["Project", "Pull", "Requests", "Goober", "Calendar", "Docs", "Drive", "Tracker", "Board", "Sprint", "Metrics",
                     "Dashboard", "Cloud", "Console", "Billing", "Notes", "Wiki", "Team", "Reading", "Reader", "Daily",
                     "News", "Tasks", "Issues", "Canvas", "Design", "System", "Status", "Page", "Docs", "API", "Reference"]
        return (0..<n).map { i in
            let k = Int(rng.next() % 5) + 1
            let title = (0..<k).map { _ in words[Int(rng.next() % UInt64(words.count))] }.joined(separator: " ")
            let host = words[Int(rng.next() % UInt64(words.count))].lowercased() + "\(i % 13).com"
            return Catalog.Item(kind: .bookmark, title: title, secondary: ChromeBookmarks.host("https://" + host + "/x").map { [$0] } ?? [],
                                payload: "https://\(host)/\(i)")
        }
    }

    static func syntheticContacts(_ n: Int, _ rng: inout SplitMix) -> [Catalog.Item] {
        let first = ["Alex", "Sam", "Jordan", "Taylor", "Robin", "Avery", "Pat", "Morgan", "Jamie", "Casey", "Riley", "Drew"]
        let last = ["Martin", "Smith", "Garcia", "Nguyen", "Kim", "Patel", "Jones", "Brown", "Lee", "Wilson", "Davis", "Lopez"]
        return (0..<n).map { i in
            let f = first[Int(rng.next() % 12)], l = last[Int(rng.next() % 12)]
            return Catalog.Item(kind: .contact, title: "\(f) \(l)", aliases: ["\(l) \(f)"], secondary: ["\(f.lowercased())\(i % 50)"],
                                payload: "C\(i):ABPerson")
        }
    }

    static func fmt(_ ns: UInt64) -> String { pad(String(format: "%.2f", Double(ns) / 1000), 7, left: true) }
    static func pad(_ s: String, _ n: Int, left: Bool = false) -> String {
        s.count >= n ? s : (left ? String(repeating: " ", count: n - s.count) + s : s + String(repeating: " ", count: n - s.count))
    }
}

struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Keeps results alive so the optimizer can't delete the work being measured.
@inline(never) func blackHole<T>(_ x: T) { withExtendedLifetime(x) {} }

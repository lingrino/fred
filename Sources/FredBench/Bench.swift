import FredCore
import Foundation

/// Search micro-benchmarks over this Mac's real catalog plus synthetic bookmarks/contacts
/// (so the index is heavier than today's: worst-case thinking). Runs at user-interactive
/// QoS (P-cores), warms up, reports min/p50/p99 per query.
enum Bench {
    static func run() {
        pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0)
        var rng = SplitMix(seed: 42)

        let t0 = DispatchTime.now().uptimeNanoseconds
        var items = AppScanner.items(AppScanner.scan()) + SettingsScanner.items(SettingsScanner.scan()) + Command.items()
        let realCount = items.count
        items += syntheticBookmarks(3000, &rng) + syntheticContacts(1500, &rng)
        let t1 = DispatchTime.now().uptimeNanoseconds
        let catalog = Catalog(items)
        let t2 = DispatchTime.now().uptimeNanoseconds
        print("catalog: \(realCount) real + \(items.count - realCount) synthetic items, \(catalog.index.count) entries, \(catalog.index.byteCount) bytes")
        print(String(format: "  scan %.1f ms, build index %.2f ms", Double(t1 - t0) / 1e6, Double(t2 - t1) / 1e6))

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

        let queries = ["f", "ch", "chr", "sys set", "goo cal", "vsc", "settngs", "a", "e", "re", "rea", "mes", "zzz", "x",
                       "system settings", "activity", "term", "kel", "co", "ma"]
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
            print(pad(q, 18), fmt(samples[0]), fmt(samples[samples.count / 2]), fmt(samples[samples.count * 99 / 100]))
        }
        total.sort()
        print("all queries: p50 \(fmt(total[total.count / 2]))  p99 \(fmt(total[total.count * 99 / 100]))")

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
        print("Matcher.Query(\"sys set\"): p50 \(fmt(qs[qs.count / 2]))")

        clipBench(&rng)
        calcBench()
        converterBench()
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
            print(pad("\"\(q)\"", 22), fmt(samples[0]), fmt(samples[samples.count / 2]), fmt(samples[samples.count * 99 / 100]))
        }
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

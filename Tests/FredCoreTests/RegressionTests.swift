import Foundation
import Testing
@testable import FredCore

/// One test per bug found in the 2026-11-14 code review.
@Suite struct RegressionTests {
    /// A fresh directory; tests remove it with `defer { clean(dir) }`.
    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fredreg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func clean(_ dir: URL) { try? FileManager.default.removeItem(at: dir) }

    func chop(_ url: URL, _ n: Int) throws {
        let h = try FileHandle(forWritingTo: url)
        let size = try h.seekToEnd()
        try h.truncate(atOffset: size - UInt64(n))
        try h.close()
    }

    @Test func tornLearningLogDoesNotSwallowLaterEvents() throws {
        let dir = tmpDir()
        defer { clean(dir) }
        let url = dir.appendingPathComponent("learning.log")
        do {
            let l = Learning(logURL: url)
            for i in 0..<3 { l.record(.init(time: 1_800_000_000 + UInt32(i), key: 7, query: Array("abc".utf8), row: 0)) }
        }
        try chop(url, 5)                                   // torn last record
        do {
            let l = Learning(logURL: url)
            for i in 0..<4 { l.record(.init(time: 1_800_000_100 + UInt32(i), key: 9, query: Array("xy".utf8), row: 0)) }
        }
        let events = EventLog.read(url).events
        #expect(events.count == 2 + 4)
        #expect(events.suffix(4).allSatisfy { $0.key == 9 && $0.query == Array("xy".utf8) })
    }

    @Test func tornClipLogDoesNotSwallowLaterClips() throws {
        let dir = tmpDir()
        defer { clean(dir) }
        let t: UInt32 = 1_800_000_000
        do {
            let s = ClipStore(dir: dir, now: t)
            for k in 0..<3 { let x = "first \(k)"; s.add(kind: .text, text: x, hash: ClipStore.hash(x, kind: .text), app: nil, time: t + UInt32(k)) }
        }
        try chop(dir.appendingPathComponent("clipboard.log"), 3)
        do {
            let s = ClipStore(dir: dir, now: t + 10)
            for k in 0..<4 { let x = "second \(k)"; s.add(kind: .text, text: x, hash: ClipStore.hash(x, kind: .text), app: nil, time: t + 10 + UInt32(k)) }
        }
        let s = ClipStore(dir: dir, now: t + 20)
        #expect(s.count == 2 + 4)
        #expect(s.text(s.count - 1) == "second 3")
    }

    @Test func nonASCIIClipKeepsLastCharacter() {
        let s = ClipStore(dir: nil)
        s.add(kind: .text, text: "café", hash: 1, app: nil, time: 1)
        s.add(kind: .text, text: "日本語", hash: 2, app: nil, time: 2)
        #expect(s.search("café", limit: 5) == [0])
        #expect(s.search("語", limit: 5) == [1])
    }

    @Test func symbolLedTitlesMatchExactAndPrefix() {
        #expect(tier("#general", "#general") == .exact)
        #expect(tier("#g", "#general") == .prefix)
        #expect(tier("(1)", "(1) Inbox") == .prefix)
    }

    @Test func thirtyTwoByteQueriesGetLearning() {
        let c = Catalog([.init(kind: .app, title: String(repeating: "a", count: 40), payload: "x"),
                         .init(kind: .app, title: String(repeating: "a", count: 41), payload: "y")])
        let s = Searcher(c)
        let l = Learning(logURL: nil)
        let q = Array(repeating: UInt8(ascii: "a"), count: 32)
        for i in 0..<4 { l.record(.init(time: 1_800_000_000 + UInt32(i), key: c.keys[1], query: q, row: 1)) }
        l.prepare(catalog: c, into: s, now: 1_800_000_010)
        let top = s.search(Matcher.Query(folded: q), k: 2, learn: l, now: 1_800_000_010)
        #expect(top.item(0) == 1)
        #expect(s.latch == 1)
    }

    @Test func acronymIsNotExponential() {
        let text = "z " + Array(repeating: "a", count: 31).joined(separator: " ")
        let q = String(repeating: "a", count: 14) + "z"
        let t0 = Date()
        _ = score(q, text)
        #expect(Date().timeIntervalSince(t0) < 0.05)
    }

    @Test func calculatorDeepInputIsRejectedNotCrashing() {
        #expect(Calculator.evaluate(String(repeating: "abs ", count: 100_000) + "1") == nil)
        #expect(Calculator.evaluate(String(repeating: "-", count: 300) + "1") == nil)
        #expect(Calculator.evaluate(String(repeating: "2^", count: 300) + "2") == nil)
        #expect(Calculator.evaluate("-(-(2))+1")?.display == "3")
    }

    @Test func exactMatchDoesNotHidePrefixMatches() {
        // "lock": the exact "Lock" command must not push the "Lock Screen" pane out.
        let c = Catalog([
            .init(kind: .command, title: "Lock", secondary: ["Lock Screen"], payload: "lock"),
            .init(kind: .settings, title: "Lock Screen", payload: "x-apple.systempreferences:com.apple.Lock-Screen-Settings.extension"),
            .init(kind: .app, title: "Clock", payload: "/System/Applications/Clock.app"),
        ])
        let s = Searcher(c)
        let l = Learning(logURL: nil)
        for i in 0..<5 { l.record(.init(time: 1_800_000_000 + UInt32(i), key: c.keys[0], query: Fold.query("lock"), row: 0)) }
        l.prepare(catalog: c, into: s, now: 1_800_000_100)
        let top = s.search(Matcher.Query("lock"), k: 5, learn: l, now: 1_800_000_100)
        let titles = (0..<top.count).map { c.titles[top.item($0)] }
        #expect(titles.prefix(2) == ["Lock", "Lock Screen"])
        // A weak (substring) match is still cut when strong matches exist: "Clock".
        #expect(!titles.contains("Clock"))
    }

    @Test func subSettingsRankBelowPanesAndApps() {
        // Sub-settings fill in below real apps and panes: "hot corners" is a keyword of
        // the Desktop & Dock pane and of an Accessibility sub-setting — the pane wins.
        let c = Catalog([
            .init(kind: .settings, title: "Dwell Corners", payload: "a#Dwell Corners", detail: "Accessibility", weak: true, weakKeywords: ["hot corners"]),
            .init(kind: .settings, title: "Desktop & Dock", secondary: ["Hot Corners"], payload: "dock"),
            .init(kind: .settings, title: "Clock", payload: "cc#Clock", detail: "Control Center", weak: true),
            .init(kind: .app, title: "Clock", payload: "/System/Applications/Clock.app"),
            .init(kind: .settings, title: "Displays", payload: "displays"),
            .init(kind: .settings, title: "Large clock", payload: "lock#Large clock", detail: "Lock Screen", weak: true, weakKeywords: ["display"]),
            .init(kind: .settings, title: "Display", payload: "a11y#Display", detail: "Accessibility", weak: true),
        ])
        let s = Searcher(c)
        let l = Learning(logURL: nil)
        func top(_ q: String) -> [String] {
            let r = s.search(Matcher.Query(q), k: 5, learn: l, now: 1_800_000_000)
            return (0..<r.count).map { c.titles[r.item($0)] }
        }
        #expect(top("hot corners").first == "Desktop & Dock")
        #expect(c.kinds[s.search(Matcher.Query("clock"), k: 5, learn: l, now: 1_800_000_000).item(0)] == .app)
        // A sub-item's keyword never outranks a pane title prefix.
        // "display": the Displays pane (prefix) before the sub-setting titled "Display"
        // (exact), before a sub-setting that merely has "display" as a keyword.
        #expect(top("display") == ["Displays", "Display", "Large clock"])
        // A pane's own search terms beat sub-items' terms: "dark" → Appearance first.
        let c2 = Catalog([
            .init(kind: .settings, title: "Appearance (Keyboard)", payload: "kb#Appearance", detail: "Keyboard", weak: true, weakKeywords: ["dark"]),
            .init(kind: .settings, title: "Appearance", payload: "appearance", weakKeywords: ["dark", "Dark Mode"]),
        ])
        let s2 = Searcher(c2)
        #expect(c2.titles[s2.search(Matcher.Query("dark"), k: 5, learn: l, now: 1_800_000_000).item(0)] == "Appearance")
    }

    @Test func learningPromotesSubSettingsOnPrefixQueries() {
        // 2026-11-16 review: picking the "True Tone" sub-setting 10× after typing "tr"
        // left it third, under two plain prefix matches — its role penalty (−450) made
        // the prefix hit look "weak", so learning was halved and the latch never applied.
        let c = Catalog([
            .init(kind: .app, title: "Translate", payload: "/System/Applications/Translate.app"),
            .init(kind: .settings, title: "Trackpad", payload: "trackpad"),
            .init(kind: .settings, title: "True Tone", payload: "displays#True Tone", detail: "Displays", weak: true),
        ])
        let s = Searcher(c)
        let l = Learning(logURL: nil)
        let now: UInt32 = 1_800_000_000
        func top(_ q: String) -> [String] {
            l.prepare(catalog: c, into: s, now: now + 100)
            let r = s.search(Matcher.Query(q), k: 5, learn: l, now: now + 100)
            return (0..<r.count).map { c.titles[r.item($0)] }
        }
        #expect(top("tr").first == "Translate")             // unlearned: real matches first
        for i in 0..<10 { l.record(.init(time: now + UInt32(i), key: c.keys[2], query: Fold.query("tr"), row: 2)) }
        #expect(top("tr").first == "True Tone")
        #expect(s.latch == 2)
    }

    @Test func decomposedAccentsFoldLikePrecomposed() {
        // File names come back from the file system decomposed (NFD): "e" + U+0301. The
        // combining mark must fold away without starting a word.
        let nfc = "Résumé Builder", nfd = nfc.decomposedStringWithCanonicalMapping
        #expect(nfd.unicodeScalars.count > nfc.unicodeScalars.count)
        #expect(score("resume", nfd) == score("resume", nfc))
        #expect(score("résumé builder", nfd) == score("résumé builder", nfc))
        #expect(tier("resume builder", nfd) == .exact)
        let s = ClipStore(dir: nil)
        s.add(kind: .text, text: "Crème brûlée".decomposedStringWithCanonicalMapping, hash: 1, app: nil, time: 1)
        #expect(s.search("creme brulee", limit: 5) == [0])
    }

    @Test func separatorRunsMatchExactly() {
        // "A - B" folded to "a   b" while the query folds to "a b": typing a title
        // exactly scored as a word-prefix match.
        #expect(tier("Notes - Work", "Notes - Work") == .exact)
        #expect(tier("Frog, Kermit", "Frog, Kermit") == .exact)
        #expect(tier("ratio: 16/9", "Ratio: 16 / 9") == .exact)
        #expect(tier("notes wo", "Notes - Work") == .prefix)
        #expect(tier("work", "-- Work --") == .exact)
    }

    @Test func pruneHandlesOutOfOrderTimes() {
        let s = ClipStore(dir: nil)
        let now: UInt32 = 1_900_000_000
        s.add(kind: .text, text: "new", hash: 1, app: nil, time: now - 10)
        s.add(kind: .text, text: "imported old", hash: 2, app: nil, time: now - 100 * 86400)
        #expect(s.prune(now: now) == 1)
        #expect(s.count == 1 && s.text(0) == "new")
    }
}

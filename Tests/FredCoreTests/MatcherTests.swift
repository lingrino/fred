import Testing
@testable import FredCore

/// Raw tier score of `query` against `text` (no kind/role adjustment).
func score(_ query: String, _ text: String, loose: Bool = true) -> Int32 {
    var t: [UInt8] = []
    let ws = Fold.fold(text, into: &t)
    let q = Matcher.Query(query)
    let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: Matcher.scratchCount)
    defer { scratch.deallocate() }
    return q.bytes.withUnsafeBufferPointer { qb in
        q.compact.withUnsafeBufferPointer { cb in
            t.withUnsafeBufferPointer { tb in
                Matcher.score(q, qb.baseAddress!, cb.baseAddress!, tb.baseAddress!, min(tb.count, 255),
                              ws & (tb.count >= 64 ? ~0 : (1 << UInt64(tb.count)) - 1), allowLoose: loose, scratch)
            }
        }
    }
}

func tier(_ query: String, _ text: String) -> Matcher.Tier? {
    let s = score(query, text)
    if s < 0 { return nil }
    return Matcher.Tier(rawValue: s - s % 100)
}

@Suite struct FoldTests {
    @Test func foldsCaseDiacriticsAndSeparators() {
        var out: [UInt8] = []
        Fold.fold("Café-Crème_Ü.app", into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "cafe creme u app")
    }

    @Test func wordStarts() {
        var out: [UInt8] = []
        let ws = Fold.fold("iTally 2Fold Gizmo4", into: &out)
        let expected: [Int] = [0, 1, 7, 8, 13, 18]
        var mask: UInt64 = 0
        for p in expected { mask |= 1 << UInt64(p) }
        #expect(ws == mask)
    }

    @Test func unicodeDashesAreSeparators() {
        var out: [UInt8] = []
        Fold.fold("Wi\u{2011}Fi\u{00A0}Settings", into: &out)
        #expect(String(decoding: out, as: UTF8.self) == "wi fi settings")
        #expect(tier("wi-fi", "Wi\u{2011}Fi") == .exact)
    }

    @Test func queryCollapsesSpaces() {
        #expect(String(decoding: Fold.query("  Sys   Set "), as: UTF8.self) == "sys set")
    }
}

@Suite struct MatcherTests {
    @Test func tiers() {
        #expect(tier("notes", "Notes") == .exact)
        #expect(tier("chr", "Chroma") == .prefix)
        #expect(tier("chr", "Goober Chroma") == .wordPrefix)
        #expect(tier("sys set", "System Settings") == .wordPrefix)
        #expect(tier("goo cal", "Goober Calendar") == .wordPrefix)
        #expect(tier("gc", "Goober Chroma") == .acronym)
        #expect(tier("vsc", "Vivid Story Composer") == .acronym)
        #expect(tier("gch", "Goober Chroma") == .acronym)
        #expect(tier("tal", "iTally") == .wordPrefix)
        #expect(tier("ock", "Clock") == .substring)
        #expect(tier("settngs", "System Settings") == .fuzzy)
        #expect(tier("sysset", "System Settings") == .acronym)   // run "sys" + run "set"
    }

    @Test func rejects() {
        #expect(tier("xyz", "Goober Chroma") == nil)
        #expect(tier("chromaz", "Goober Chroma") == nil)
        #expect(tier("ab", "a") == nil)
        #expect(tier("oo", "Goober") == nil)            // 2 chars: no substring tier
        #expect(tier("ober", "Goober Chroma") == .substring)
        #expect(tier("ygc", "System Settings") == nil)   // fuzzy needs first char on a word start
        #expect(tier("rea", "Rem Delta") == nil)          // fuzzy must be dense
        #expect(tier("chrma", "Chroma") == .fuzzy)
        #expect(score("c", "Goober Chroma", loose: false) < 0)   // bookmarks: 1 char = prefix only
        #expect(score("c", "Goober Chroma", loose: true) > 0)
    }

    @Test func orderingWithinTiers() {
        #expect(score("ch", "Chess") > score("ch", "Goober Chroma"))
        #expect(score("notes", "Notes") > score("notes", "Notes Helper"))
        #expect(score("lock", "Lock Screen") > score("lock", "Clock"))
        #expect(score("gc", "Goober Chroma") > score("gc", "Goober Cloud Console"))
        #expect(score("set", "System Settings") > score("set", "Smart Event Timer"))
        #expect(score("chr", "Goober Chroma") > score("chr", "Nice Hairy Rabbit Chroma"))
    }
}

@Suite struct SearchTests {
    func catalog() -> Catalog {
        Catalog([
            .init(kind: .app, title: "Finder", payload: "/System/Library/CoreServices/Finder.app"),
            .init(kind: .app, title: "FaceTime", payload: "/System/Applications/FaceTime.app"),
            .init(kind: .app, title: "Goober Chroma", payload: "/Applications/Goober Chroma.app"),
            .init(kind: .app, title: "Chess", payload: "/System/Applications/Chess.app"),
            .init(kind: .app, title: "Vivid Story Composer", aliases: ["Composer"], payload: "/Applications/Vivid Story Composer.app"),
            .init(kind: .app, title: "Vscan", payload: "/Applications/Vscan.app"),
            .init(kind: .settings, title: "Keyboard", payload: "com.apple.Keyboard-Settings.extension"),
            .init(kind: .contact, title: "Kermit Frog", payload: "abc:ABPerson"),
            .init(kind: .bookmark, title: "notebook", secondary: ["notebook.example"], payload: "https://notebook.example"),
            .init(kind: .command, title: "Restart", payload: "restart"),
        ])
    }

    func titles(_ s: Searcher, _ q: String, _ learn: Learning? = nil, now: UInt32 = 1_800_000_000) -> [String] {
        let top = s.search(Matcher.Query(q), k: 5, learn: learn, now: now)
        return (0..<top.count).map { s.catalog.titles[top.item($0)] }
    }

    @Test func basicRanking() {
        let s = Searcher(catalog())
        #expect(titles(s, "f").prefix(2) == ["Finder", "FaceTime"])
        #expect(titles(s, "ke") == ["Keyboard", "Kermit Frog"])
        #expect(titles(s, "composer").first == "Vivid Story Composer")    // alias exact
        #expect(titles(s, "vsc").first == "Vscan")                    // prefix beats acronym untrained
        #expect(titles(s, "xyz").isEmpty)
    }

    @Test func learningFlipsNearTies() {
        let c = catalog()
        let s = Searcher(c)
        let learn = Learning(logURL: nil)
        let t0: UInt32 = 1_800_000_000
        let chroma = c.keys[2]
        // Untrained: Chess (prefix) above Goober Chroma (word prefix).
        #expect(titles(s, "ch", learn, now: t0).first == "Chess")
        for i in 0..<3 {
            learn.record(.init(time: t0 + UInt32(i * 60), key: chroma, query: Fold.query("ch"), row: 1))
        }
        learn.prepare(catalog: c, into: s, now: t0 + 600)
        #expect(titles(s, "ch", learn, now: t0 + 600).first == "Goober Chroma")
        // Prefix generalization: "c" also learns Chroma (stored query "ch" starts with "c").
        #expect(titles(s, "c", learn, now: t0 + 600).first == "Goober Chroma")
        // Garbage can't win: learning doesn't make "ober" (substring) beat a real prefix.
        #expect(titles(s, "fi", learn, now: t0 + 600).first == "Finder")
    }

    @Test func competitionLetsHabitsSwitch() {
        let c = catalog()
        let s = Searcher(c)
        let learn = Learning(logURL: nil)
        var t: UInt32 = 1_800_000_000
        let finder = c.keys[0], facetime = c.keys[1]
        for _ in 0..<5 { learn.record(.init(time: t, key: facetime, query: Fold.query("f"), row: 0)); t += 60 }
        learn.prepare(catalog: c, into: s, now: t)
        #expect(titles(s, "f", learn, now: t).first == "FaceTime")
        for _ in 0..<5 { learn.record(.init(time: t, key: finder, query: Fold.query("f"), row: 1)); t += 60 }
        learn.prepare(catalog: c, into: s, now: t)
        #expect(titles(s, "f", learn, now: t).first == "Finder")
    }

    @Test func latchPinsWithoutHidingOthers() {
        let c = catalog()
        let s = Searcher(c)
        let learn = Learning(logURL: nil)
        var t: UInt32 = 1_800_000_000
        for _ in 0..<4 { learn.record(.init(time: t, key: c.keys[1], query: Fold.query("f"), row: 1)); t += 60 }
        learn.prepare(catalog: c, into: s, now: t)
        let r = titles(s, "f", learn, now: t)
        #expect(r.first == "FaceTime")
        #expect(r.contains("Finder"))
    }

    @Test func bookmarkHostsDropTLD() {
        #expect(ChromeBookmarks.host("https://www.example.com/pulls") == "example")
        #expect(ChromeBookmarks.host("https://docs.example.com/x") == "docs.example")
        #expect(ChromeBookmarks.host("https://bbc.co.uk/news") == "bbc")
        #expect(ChromeBookmarks.host("http://localhost:3000/") == "localhost")
        #expect(ChromeBookmarks.host("http://10.0.0.1/") == "10.0.0.1")
    }

    @Test func packedQueryPrefixRanges() {
        let a = PackedQuery(Fold.query("fin")), b = PackedQuery(Fold.query("f"))
        #expect(a.hasPrefix(b))
        #expect(!b.hasPrefix(a))
        #expect(b.lowerPad < a && a < b.upperPad)
        let long = PackedQuery(Array("abcdefghijklmnopqrstuvwxyz012345".utf8))
        #expect(long.hasPrefix(PackedQuery(Array("abcdefghijklmnopq".utf8))))
        #expect(!long.hasPrefix(PackedQuery(Array("abcdefghijklmnopz".utf8))))
    }
}

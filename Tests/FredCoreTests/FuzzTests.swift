import Foundation
import Testing
@testable import FredCore

/// Property tests over random inputs. Tests run as debug builds (bounds/overflow checks
/// ON), while release FredCore is -Ounchecked — so any out-of-bounds access these find
/// would be silent memory corruption in the shipped app.
@Suite struct FuzzTests {
    struct RNG {
        var s: UInt64
        mutating func next() -> UInt64 {
            s &+= 0x9E37_79B9_7F4A_7C15
            var z = s
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func int(_ n: Int) -> Int { Int(next() % UInt64(max(n, 1))) }
    }

    static let pieces: [String] = ["a", "b", "c", "e", "f", "o", "s", "t", "x", "z", "A", "C", "S", " ", "  ", "-", ".", "_",
                                   "/", "1", "9", "é", "Ü", "ß", "日本", "😀", "\u{2011}", "\u{00A0}", "ﬁ", "Chroma",
                                   "System", "Settings", "iTally", "+", "@", "%", "(", ")"]

    func randomString(_ r: inout RNG, maxPieces: Int) -> String {
        var s = ""
        for _ in 0..<r.int(maxPieces + 1) { s += Self.pieces[r.int(Self.pieces.count)] }
        return s
    }

    /// True if `q` (no spaces) is a subsequence of `t`.
    func isSubsequence(_ q: [UInt8], _ t: [UInt8]) -> Bool {
        var j = 0
        for c in q {
            while j < t.count && t[j] != c { j += 1 }
            if j == t.count { return false }
            j += 1
        }
        return true
    }

    @Test func matcherNeverOutOfBoundsAndOnlyMatchesSubsequences() {
        var r = RNG(s: 1)
        let scratch = UnsafeMutablePointer<Int32>.allocate(capacity: Matcher.scratchCount)
        defer { scratch.deallocate() }
        for iter in 0..<30_000 {
            let text = randomString(&r, maxPieces: iter % 10 == 0 ? 120 : 12)
            let query = randomString(&r, maxPieces: iter % 17 == 0 ? 30 : 4)
            var t: [UInt8] = []
            let ws = Fold.fold(text, into: &t)
            while t.last == 0x20 { t.removeLast() }
            guard !t.isEmpty else { continue }
            let n = min(t.count, SearchIndex.maxEntryLength)
            let mask = n >= 64 ? ws : ws & ((1 << UInt64(n)) - 1)
            let q = Matcher.Query(query)
            guard q.count > 0 else { continue }
            let s = q.bytes.withUnsafeBufferPointer { qb in
                q.compact.withUnsafeBufferPointer { cb in
                    t.withUnsafeBufferPointer { tb in
                        Matcher.score(q, qb.baseAddress!, cb.baseAddress!, tb.baseAddress!, n, mask,
                                      allowLoose: iter % 2 == 0, scratch)
                    }
                }
            }
            if s >= 0 {
                #expect(isSubsequence(q.compact, Array(t[0..<n])), "\(query) vs \(text)")
                #expect(s < 1500)
            }
        }
    }

    @Test func searcherInvariants() {
        var r = RNG(s: 2)
        var items: [Catalog.Item] = []
        for i in 0..<2000 {
            let kind = Catalog.Kind.allCases[r.int(5)]
            items.append(.init(kind: kind, title: randomString(&r, maxPieces: i % 50 == 0 ? 90 : 6),
                               aliases: r.int(3) == 0 ? [randomString(&r, maxPieces: 4)] : [],
                               secondary: r.int(3) == 0 ? [randomString(&r, maxPieces: 3)] : [],
                               payload: "p\(i)"))
        }
        let c = Catalog(items)
        let s = Searcher(c)
        let learn = Learning(logURL: nil)
        for i in 0..<300 {
            learn.record(.init(time: 1_800_000_000 + UInt32(i), key: c.keys[r.int(c.count)],
                               query: Array(Fold.query(randomString(&r, maxPieces: 3)).prefix(40)), row: UInt8(r.int(5))))
        }
        learn.prepare(catalog: c, into: s, now: 1_800_001_000)
        for _ in 0..<3000 {
            let q = Matcher.Query(randomString(&r, maxPieces: 5))
            let k = 1 + r.int(9)
            let top = s.search(q, k: k, learn: learn, now: 1_800_001_000)
            #expect(top.count <= k)
            var seen = Set<Int>()
            for i in 0..<top.count {
                #expect(top.item(i) >= 0 && top.item(i) < c.count)
                #expect(seen.insert(top.item(i)).inserted)          // no duplicate items
                if i > 0 { #expect(top.score(i - 1) >= top.score(i)) } // sorted
            }
        }
    }

    /// `Searcher.search` without any pruning: every entry scored down to the fuzzy tier.
    func exhaustive(_ s: Searcher, _ query: Matcher.Query, k: Int, learn: Learning, now: UInt32) -> TopK {
        var top = TopK(k: k)
        let m = query.count
        guard m > 0 else { return top }
        s.latch = -1
        learn.applyBoosts(query: query.bytes, catalog: s.catalog, into: s, now: now)
        defer {
            for i in s.touched { s.sparse[Int(i)] = 0 }
            s.touched.removeAll(keepingCapacity: true)
        }
        let idx = s.catalog.index
        var best = Int32.min
        let q0bit = Fold.charBit(query.bytes[0])
        query.bytes.withUnsafeBufferPointer { qb in
            query.compact.withUnsafeBufferPointer { cb in
                for e in 0..<idx.count {
                    if idx.masks[e] & query.mask != query.mask { continue }
                    let initialHit = idx.initials[e] & q0bit != 0
                    if !initialHit && m < 3 { continue }
                    let sp = idx.spans[e]
                    let n = Int(sp & 0xFF)
                    if n < query.compact.count { continue }
                    let packed = idx.items[e]
                    let kind = Int(packed >> 24 & 0xF), item = Int(packed & 0xFF_FFFF), role = Int(packed >> 28)
                    let learned = min(s.base[item] &+ s.sparse[item], Ranking.maxLearned)
                    let raw = Matcher.score(query, qb.baseAddress!, cb.baseAddress!, idx.bytes + Int(sp >> 8), n, idx.starts[e],
                                            allowLoose: kind != Int(Catalog.Kind.bookmark.rawValue), s.scratch,
                                            lowest: .fuzzy, initialHit: initialHit)
                    if raw < 0 { continue }
                    let adj = Ranking.adjust(raw, kind: kind, role: role)
                    var final = Ranking.blend(adj, raw: raw, learned: learned)
                    best = max(best, final)
                    if item == s.latch && raw >= Matcher.Tier.acronym.rawValue { final += Ranking.latchBonus }
                    top.insert(item: Int32(item), score: final, tie: learned << 8 | Int32(255 - n), raw: adj)
                }
            }
        }
        top.dropWeak(below: best == .min ? .min : best - Ranking.relativeCutoff)
        return top
    }

    @Test func pruningNeverChangesResults() {
        // Branch and bound must be invisible: same rows, same order, same scores as
        // scoring everything — with learning, latches, aliases and sub-settings.
        var r = RNG(s: 6)
        var items: [Catalog.Item] = []
        for i in 0..<1500 {
            let weak = r.int(4) == 0
            items.append(.init(kind: weak ? .settings : Catalog.Kind.allCases[r.int(5)],
                               title: randomString(&r, maxPieces: i % 60 == 0 ? 40 : 5),
                               aliases: r.int(4) == 0 ? [randomString(&r, maxPieces: 3)] : [],
                               secondary: r.int(4) == 0 ? [randomString(&r, maxPieces: 3)] : [],
                               payload: "p\(i)", weak: weak,
                               weakKeywords: r.int(3) == 0 ? [randomString(&r, maxPieces: 2)] : []))
        }
        let c = Catalog(items)
        let s = Searcher(c)
        let learn = Learning(logURL: nil)
        var queries: [String] = []
        for _ in 0..<60 { queries.append(randomString(&r, maxPieces: 2)) }
        for i in 0..<600 {
            // Repeated picks for a few queries, so some latch.
            let q = queries[r.int(queries.count)]
            learn.record(.init(time: 1_800_000_000 + UInt32(i), key: c.keys[r.int(40)], query: Fold.query(q), row: UInt8(r.int(5))))
        }
        learn.prepare(catalog: c, into: s, now: 1_800_001_000)
        var latched = 0
        for i in 0..<4000 {
            let text = i % 3 == 0 ? queries[r.int(queries.count)] : randomString(&r, maxPieces: 1 + r.int(4))
            let q = Matcher.Query(text)
            let k = 1 + r.int(9)
            let got = s.search(q, k: k, learn: learn, now: 1_800_001_000)
            if s.latch >= 0 { latched += 1 }
            let want = exhaustive(s, q, k: k, learn: learn, now: 1_800_001_000)
            #expect(got.count == want.count, "\(text)")
            for j in 0..<min(got.count, want.count) {
                #expect(got.item(j) == want.item(j) && got.score(j) == want.score(j), "\(text) row \(j)")
            }
        }
        #expect(latched > 0)   // the latch path was exercised
    }

    @Test func calculatorNeverCrashes() {
        var r = RNG(s: 3)
        let chars = Array("0123456789+-*/^%()., xepisqrtlogabs!=×÷ ")
        for _ in 0..<50_000 {
            var s = ""
            for _ in 0..<r.int(24) { s.append(chars[r.int(chars.count)]) }
            _ = Calculator.evaluate(s)
        }
        // Deep nesting is bounded, not a stack overflow.
        #expect(Calculator.evaluate(String(repeating: "(", count: 10_000) + "1" + String(repeating: ")", count: 10_000)) == nil)
    }

    @Test func clipStoreReplayMatchesMemory() throws {
        var r = RNG(s: 4)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fredfuzz-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var t: UInt32 = 1_800_000_000
        let s = ClipStore(dir: dir, now: t)
        for _ in 0..<2000 {
            t += UInt32(r.int(100))
            switch r.int(10) {
            case 0 where s.count > 0: s.delete(r.int(s.count))
            case 1 where s.count > 0: s.touch(r.int(s.count), time: t)
            default:
                let txt = randomString(&r, maxPieces: r.int(10) == 0 ? 400 : 8)
                guard !txt.isEmpty else { continue }
                s.add(kind: .text, text: txt, hash: ClipStore.hash(txt, kind: .text), app: r.int(2) == 0 ? "com.x" : nil, time: t)
            }
        }
        let mem = (0..<s.count).map { (s.text($0), s.time[$0], s.app($0)) }
        let s2 = ClipStore(dir: dir, now: t)
        let disk = (0..<s2.count).map { (s2.text($0), s2.time[$0], s2.app($0)) }
        #expect(mem.count == disk.count)
        for (a, b) in zip(mem, disk) { #expect(a.0 == b.0 && a.1 == b.1 && a.2 == b.2) }
        // Search returns exactly the clips containing every token (naive reference),
        // newest first.
        func has(_ hay: ArraySlice<UInt8>, _ tok: [UInt8]) -> Bool {
            guard tok.count <= hay.count else { return false }
            let h = Array(hay)
            for i in 0...(h.count - tok.count) where Array(h[i..<(i + tok.count)]) == tok { return true }
            return false
        }
        for _ in 0..<500 {
            let q = randomString(&r, maxPieces: 2)
            let tokens = Fold.query(q).split(separator: 0x20).map { Array($0) }
            let want = (0..<s2.count).reversed().filter { i in tokens.allSatisfy { has(s2.foldArena[s2.foldSpan[i]], $0) } }
            #expect(s2.search(q, limit: 100_000) == want, "\(q)")
        }
    }

    @Test func packedQueryOrderMatchesByteOrder() {
        var r = RNG(s: 5)
        for _ in 0..<5000 {
            let a = Array(Fold.query(randomString(&r, maxPieces: 6)).prefix(32))
            let b = Array(Fold.query(randomString(&r, maxPieces: 6)).prefix(32))
            let pa = PackedQuery(a), pb = PackedQuery(b)
            #expect((pa < pb) == a.lexicographicallyPrecedes(b))
            #expect(pa.hasPrefix(pb) == a.starts(with: b))
        }
    }
}

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
        // Searching random queries never crashes and only returns matches.
        for _ in 0..<500 {
            let q = randomString(&r, maxPieces: 2)
            for i in s2.search(q, limit: 50) { #expect(i >= 0 && i < s2.count) }
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

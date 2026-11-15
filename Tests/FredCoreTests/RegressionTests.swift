import Foundation
import Testing
@testable import FredCore

/// One test per bug found in the 2026-11-14 code review.
@Suite struct RegressionTests {
    func tmpDir() -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("fredreg-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func chop(_ url: URL, _ n: Int) throws {
        let h = try FileHandle(forWritingTo: url)
        let size = try h.seekToEnd()
        try h.truncate(atOffset: size - UInt64(n))
        try h.close()
    }

    @Test func tornLearningLogDoesNotSwallowLaterEvents() throws {
        let url = tmpDir().appendingPathComponent("learning.log")
        do {
            let l = Learning(logURL: url)
            for i in 0..<3 { l.record(.init(time: 1_800_000_000 + UInt32(i), key: 7, query: Array("abc".utf8), row: 0)) }
        }
        try chop(url, 5)                                   // torn last record
        do {
            let l = Learning(logURL: url)
            for i in 0..<4 { l.record(.init(time: 1_800_000_100 + UInt32(i), key: 9, query: Array("xy".utf8), row: 0)) }
        }
        let events = EventLog(url: url).loaded
        #expect(events.count == 2 + 4)
        #expect(events.suffix(4).allSatisfy { $0.key == 9 && $0.query == Array("xy".utf8) })
    }

    @Test func tornClipLogDoesNotSwallowLaterClips() throws {
        let dir = tmpDir()
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

    @Test func pruneHandlesOutOfOrderTimes() {
        let s = ClipStore(dir: nil)
        let now: UInt32 = 1_900_000_000
        s.add(kind: .text, text: "new", hash: 1, app: nil, time: now - 10)
        s.add(kind: .text, text: "imported old", hash: 2, app: nil, time: now - 100 * 86400)
        #expect(s.prune(now: now) == 1)
        #expect(s.count == 1 && s.text(0) == "new")
    }
}

import Foundation

/// What Fred has learned from your picks.
///
/// Ground truth is an append-only event log (one record per pick). Two aggregates are
/// derived by replaying it at startup and updated incrementally on each pick:
///
/// 1. **Frecency per item** (global habit): `s ← s·2^(−Δt/H) + 1` on use, read as
///    `F = s·2^(−age/H)`, H = 14 days. Exact, O(1), no bucket cliffs (cf. zoxide).
///
/// 2. **Query → item associations** (Firefox "adaptive history" + competition): keyed on
///    the exact folded query typed before the pick. On picking x after typing u, every
///    row (u, y) is multiplied by 0.8, then w(u, x) += 1 (1.5 if x wasn't the top row —
///    reaching past row 1 is a strong signal). Rows decay ×0.975/day and are dropped below
///    0.1. Lookup for the current input u takes, per item, the max over stored queries s
///    that start with u of w(s, x) × (2 if s == u). So typing "f" after you always pick
///    Finder for "f"/"fi" ranks Finder first, while "fa" only sees "fa…" rows.
///
/// A **latch** pins an item to row 1 for an exact query once it clearly owns it
/// (w ≥ 2.4 and ≥ 2× the runner-up — about three consistent picks).
///
/// Learned points: `raw = min(300, 15·log2(1+F) + 50·A)`, blended by `Ranking`.
public final class Learning {
    public static let halfLife: Double = 14 * 86400
    static let assocDecayPerDay: Double = 0.975
    static let competition: Float = 0.8
    static let pruneBelow: Float = 0.1

    // Frecency: sorted by key.
    var fKeys: [UInt64] = []
    var fS: [Float] = []
    var fT: [UInt32] = []

    // Associations: sorted by (query, key).
    struct Assoc {
        var q: PackedQuery
        var key: UInt64
        var w: Float
        var t: UInt32   // when `w` was last brought up to date
    }
    var assoc: [Assoc] = []

    let log: EventLog?

    /// `logURL` nil = in-memory only (tests).
    public init(logURL: URL?) {
        if let url = logURL {
            let l = EventLog(url: url)
            log = l
            for e in l.loaded { apply(e) }
            prune(now: UInt32(Date().timeIntervalSince1970))
        } else {
            log = nil
        }
    }

    // MARK: Recording

    public struct Event: Sendable, Equatable {
        public var time: UInt32          // unix seconds
        public var key: UInt64           // Catalog item key
        public var query: [UInt8]        // folded query (≤ 32 bytes)
        public var row: UInt8            // 0-based row the item was shown at
        public init(time: UInt32, key: UInt64, query: [UInt8], row: UInt8) {
            self.time = time; self.key = key; self.query = Array(query.prefix(32)); self.row = row
        }
    }

    /// Records a pick: persists it and updates the aggregates.
    public func record(_ e: Event) {
        log?.append(e)
        apply(e)
    }


    public var isEmpty: Bool { fKeys.isEmpty && assoc.isEmpty }

    func apply(_ e: Event) {
        // Frecency.
        var lo = lowerBound(fKeys, e.key)
        if lo < fKeys.count && fKeys[lo] == e.key {
            fS[lo] = Float(decay(Double(fS[lo]), from: fT[lo], to: e.time)) + 1
            fT[lo] = max(fT[lo], e.time)
        } else {
            fKeys.insert(e.key, at: lo); fS.insert(1, at: lo); fT.insert(e.time, at: lo)
        }
        // Associations: competition among rows for the same query, then reinforce.
        guard !e.query.isEmpty else { return }
        let pq = PackedQuery(e.query)
        let r = range(of: pq)
        var found = -1
        for i in r {
            assoc[i].w = Float(Double(assoc[i].w) * dayDecay(from: assoc[i].t, to: e.time)) * Self.competition
            assoc[i].t = max(assoc[i].t, e.time)
            if assoc[i].key == e.key { found = i }
        }
        let gain: Float = e.row == 0 ? 1 : 1.5
        if found >= 0 {
            assoc[found].w += gain
        } else {
            lo = r.lowerBound
            while lo < r.upperBound && assoc[lo].key < e.key { lo += 1 }
            assoc.insert(Assoc(q: pq, key: e.key, w: gain, t: e.time), at: lo)
        }
    }

    func prune(now: UInt32) {
        assoc.removeAll { Float(Double($0.w) * dayDecay(from: $0.t, to: now)) < Self.pruneBelow }
    }

    // MARK: Query-time

    /// Writes every item's frecency points into the searcher's dense base array. Called
    /// when the panel opens and after each pick (frecency only changes then).
    public func prepare(catalog: Catalog, into s: Searcher, now: UInt32) {
        s.clearBase()
        for i in 0..<fKeys.count {
            guard let item = catalog.item(forKey: fKeys[i]) else { continue }
            let f = decay(Double(fS[i]), from: fT[i], to: now)
            let pts = Int32(15 * log2(1 + f))
            if pts > 0 { s.setBase(item: item, pts) }
        }
    }

    /// Adds query-association points (and the latch) for input `u`. Called once per
    /// keystroke before the scan; touches only the few rows whose query starts with u.
    public func applyBoosts(query u: [UInt8], catalog: Catalog, into s: Searcher, now: UInt32) {
        guard !u.isEmpty else { return }
        // Association part: rows whose query starts with u, per-item max.
        let pu = PackedQuery(u)
        // Rows whose query starts with u lie in [u+00…, u+FF…). A full 32-byte u has no
        // room for padding: its only "extensions" are rows equal to it.
        var lo = lowerBoundQ(pu.lowerPad)
        var hi = pu.len >= 32 ? range(of: pu).upperBound : lowerBoundQ(pu.upperPad)
        if hi < lo { hi = lo }
        // Small inline accumulation: (item, best A) — few rows match a given prefix.
        var bestItem = InlineArray<16, Int32>(repeating: -1)
        var bestA = InlineArray<16, Float>(repeating: 0)
        var nBest = 0
        // Latch tracking for the exact query.
        var exTop: Float = 0, exSecond: Float = 0, exTopItem: Int32 = -1
        while lo < hi {
            let row = assoc[lo]; lo += 1
            guard row.q.hasPrefix(pu) else { continue }
            guard let item = catalog.item(forKey: row.key) else { continue }
            let w = Float(Double(row.w) * dayDecay(from: row.t, to: now))
            let exact = row.q == pu
            let a = exact ? 2 * w : w
            if exact {
                if w > exTop { exSecond = exTop; exTop = w; exTopItem = Int32(item) }
                else if w > exSecond { exSecond = w }
            }
            var k = 0
            while k < nBest && bestItem[k] != Int32(item) { k += 1 }
            if k < nBest { if a > bestA[k] { bestA[k] = a } }
            else if nBest < 16 { bestItem[nBest] = Int32(item); bestA[nBest] = a; nBest += 1 }
            else {
                // Full: replace the weakest so the 16 strongest associations survive.
                var w = 0
                for j in 1..<16 where bestA[j] < bestA[w] { w = j }
                if a > bestA[w] { bestItem[w] = Int32(item); bestA[w] = a }
            }
        }
        for k in 0..<nBest { s.addBoost(item: Int(bestItem[k]), Int32(50 * bestA[k])) }
        if exTopItem >= 0 && exTop >= 2.4 && exTop >= 2 * exSecond { s.latch = Int(exTopItem) }
    }

    // MARK: Helpers

    func decay(_ v: Double, from: UInt32, to: UInt32) -> Double {
        guard to > from else { return v }
        return v * exp2(-Double(to - from) / Self.halfLife)
    }

    func dayDecay(from: UInt32, to: UInt32) -> Double {
        guard to > from else { return 1 }
        return pow(Self.assocDecayPerDay, Double(to - from) / 86400)
    }

    func lowerBound(_ a: [UInt64], _ k: UInt64) -> Int {
        var lo = 0, hi = a.count
        while lo < hi { let m = (lo + hi) >> 1; if a[m] < k { lo = m + 1 } else { hi = m } }
        return lo
    }

    func lowerBoundQ(_ q: PackedQuery) -> Int {
        var lo = 0, hi = assoc.count
        while lo < hi { let m = (lo + hi) >> 1; if assoc[m].q < q { lo = m + 1 } else { hi = m } }
        return lo
    }

    /// Rows with exactly query `q`.
    func range(of q: PackedQuery) -> Range<Int> {
        let lo = lowerBoundQ(q)
        var hi = lo
        while hi < assoc.count && assoc[hi].q == q { hi += 1 }
        return lo..<hi
    }

    public func debugDescription(catalog: Catalog) -> String {
        var s = "frecency items: \(fKeys.count), assoc rows: \(assoc.count)\n"
        for r in assoc.prefix(200) {
            let name = catalog.item(forKey: r.key).map { catalog.titles[$0] } ?? "?"
            s += "  \(r.q.string) → \(name) w=\(r.w)\n"
        }
        return s
    }
}

/// A folded query of ≤ 32 bytes packed big-endian into four words, so byte-lexicographic
/// order is integer order and "starts with" ranges are contiguous: every query starting
/// with u sorts between u+00… and u+FF… (folded text never contains 0x00 or 0xFF).
public struct PackedQuery: Comparable, Sendable {
    var w0: UInt64 = 0, w1: UInt64 = 0, w2: UInt64 = 0, w3: UInt64 = 0
    var len: UInt8 = 0

    init(_ b: [UInt8], pad: UInt8 = 0) {
        let n = min(b.count, 32)
        len = UInt8(n)
        var words = InlineArray<4, UInt64>(repeating: 0)
        for i in 0..<32 {
            let byte = i < n ? b[i] : pad
            words[i >> 3] |= UInt64(byte) << UInt64(56 - 8 * (i & 7))
        }
        w0 = words[0]; w1 = words[1]; w2 = words[2]; w3 = words[3]
    }

    var lowerPad: PackedQuery { self }
    var upperPad: PackedQuery {
        var p = PackedQuery(bytes, pad: 0xFF); p.len = 32; return p
    }

    var bytes: [UInt8] {
        var out: [UInt8] = []
        let ws = [w0, w1, w2, w3]
        for i in 0..<Int(len) { out.append(UInt8(truncatingIfNeeded: ws[i >> 3] >> UInt64(56 - 8 * (i & 7)))) }
        return out
    }

    var string: String { String(decoding: bytes, as: UTF8.self) }

    func hasPrefix(_ p: PackedQuery) -> Bool {
        guard len >= p.len else { return false }
        let n = Int(p.len)
        func mask(_ word: Int) -> UInt64 {
            let bytesInWord = max(0, min(8, n - word * 8))
            return bytesInWord == 0 ? 0 : (bytesInWord == 8 ? ~0 : ~(~UInt64(0) >> UInt64(8 * bytesInWord)))
        }
        return (w0 ^ p.w0) & mask(0) == 0 && (w1 ^ p.w1) & mask(1) == 0
            && (w2 ^ p.w2) & mask(2) == 0 && (w3 ^ p.w3) & mask(3) == 0
    }

    public static func < (a: PackedQuery, b: PackedQuery) -> Bool {
        if a.w0 != b.w0 { return a.w0 < b.w0 }
        if a.w1 != b.w1 { return a.w1 < b.w1 }
        if a.w2 != b.w2 { return a.w2 < b.w2 }
        if a.w3 != b.w3 { return a.w3 < b.w3 }
        return a.len < b.len
    }

    public static func == (a: PackedQuery, b: PackedQuery) -> Bool {
        a.w0 == b.w0 && a.w1 == b.w1 && a.w2 == b.w2 && a.w3 == b.w3 && a.len == b.len
    }
}

/// Append-only binary log of learning events.
///
/// File: "FRDL" magic + u32 version, then records:
///     u32 time | u64 key | u8 row | u8 qlen | qlen bytes      (little-endian)
final class EventLog {
    let url: URL
    private var handle: FileHandle?
    static let magic: [UInt8] = Array("FRDL".utf8) + [1, 0, 0, 0]

    /// Events read at open (the file's valid prefix).
    private(set) var loaded: [Learning.Event] = []

    init(url: URL) {
        self.url = url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: Data(Self.magic))
        }
        let (events, goodEnd, size) = Self.read(url)
        loaded = events
        handle = try? FileHandle(forWritingTo: url)
        // A torn tail (crash or full disk mid-append) must be cut off before appending,
        // or every later record would be misparsed behind it.
        if goodEnd < size { try? handle?.truncate(atOffset: UInt64(goodEnd)) }
        _ = try? handle?.seekToEnd()
    }

    func append(_ e: Learning.Event) {
        var d = Data(capacity: 14 + e.query.count)
        withUnsafeBytes(of: e.time.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: e.key.littleEndian) { d.append(contentsOf: $0) }
        d.append(e.row)
        d.append(UInt8(e.query.count))
        d.append(contentsOf: e.query)
        try? handle?.write(contentsOf: d)
    }

    func flush() { try? handle?.synchronize() }

    func readAll() -> [Learning.Event] { Self.read(url).events }

    /// Valid events, the offset just past the last complete record, and the file size.
    /// A file without the magic header is treated as empty (rewritten from scratch).
    static func read(_ url: URL) -> (events: [Learning.Event], goodEnd: Int, size: Int) {
        guard let data = try? Data(contentsOf: url) else { return ([], 0, 0) }
        guard data.count >= 8, Array(data.prefix(4)) == Array(magic.prefix(4)) else {
            // Unrecognized: start over with just a header.
            try? Data(magic).write(to: url)
            return ([], 8, 8)
        }
        var out: [Learning.Event] = []
        var good = 8
        data.withUnsafeBytes { raw in
            var i = 8
            let n = raw.count
            while i + 14 <= n {
                let t = raw.loadUnaligned(fromByteOffset: i, as: UInt32.self).littleEndian
                let k = raw.loadUnaligned(fromByteOffset: i + 4, as: UInt64.self).littleEndian
                let row = raw[i + 12]
                let ql = Int(raw[i + 13])
                guard ql <= 32, i + 14 + ql <= n else { break }   // torn tail / garbage
                let q = Array(raw[(i + 14)..<(i + 14 + ql)])
                out.append(.init(time: t, key: k, query: q, row: row))
                i += 14 + ql
                good = i
            }
        }
        return (out, good, data.count)
    }
}

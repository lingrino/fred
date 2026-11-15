/// Top-K results kept in fixed inline storage — no heap, no sorting pass.
///
/// Insertion keeps slots sorted by (score desc, tie desc). An item appears at most once:
/// aliases of the same item compete for its single slot.
public struct TopK: Sendable {
    public static let capacity = 9
    public private(set) var count = 0
    public let k: Int
    var items = InlineArray<9, Int32>(repeating: -1)
    var scores = InlineArray<9, Int32>(repeating: .min)
    var ties = InlineArray<9, Int32>(repeating: .min)

    public init(k: Int) { precondition(k > 0 && k <= Self.capacity); self.k = k }

    public func item(_ i: Int) -> Int { Int(items[i]) }
    public func score(_ i: Int) -> Int32 { scores[i] }

    /// Score an insertion must reach to enter (when full).
    @inline(__always) var floor: Int32 { count < k ? .min : scores[k - 1] }

    mutating func dropBelow(_ threshold: Int32) {
        while count > 0 && scores[count - 1] < threshold { count -= 1 }
    }

    @inline(__always)
    mutating func insert(item: Int32, score: Int32, tie: Int32) {
        if count == k && (score < scores[k - 1] || (score == scores[k - 1] && tie <= ties[k - 1])) { return }
        // Same item already present? Keep the better one.
        var at = -1
        for i in 0..<count where items[i] == item { at = i; break }
        if at >= 0 {
            if score < scores[at] || (score == scores[at] && tie <= ties[at]) { return }
        } else {
            at = count < k ? count : k - 1
            if count < k { count += 1 }
        }
        var i = at
        while i > 0 && (scores[i - 1] < score || (scores[i - 1] == score && ties[i - 1] < tie)) {
            items[i] = items[i - 1]; scores[i] = scores[i - 1]; ties[i] = ties[i - 1]
            i -= 1
        }
        items[i] = item; scores[i] = score; ties[i] = tie
    }
}

/// How text tiers, source kind, entry role and learning combine into one score.
public enum Ranking {
    /// Fine-score prior per kind (never crosses a tier): apps, commands, settings,
    /// contacts, bookmarks.
    static let kindPrior: InlineArray<8, Int32> = [20, 10, 15, 0, 5, 0, 0, 0]
    //                                     app settings command bookmark contact
    /// Results scoring more than this below the best are dropped: when "rea" has strong
    /// prefix hits, scattered fuzzy hits are noise, but they stay when nothing is better.
    static let relativeCutoff: Int32 = 350
    static let maxLearned: Int32 = 300
    static let latchBonus: Int32 = 5000

    /// Adjusts a raw tier score for the entry's kind and role.
    @inline(__always)
    static func adjust(_ s: Int32, kind: Int, role: Int) -> Int32 {
        let base = s - s % 100
        var fine = s - base + kindPrior[kind]
        if role == 1 { fine -= 5 }
        fine = max(0, min(99, fine))   // ≤ fineMax(79) + prior(20)
        return base + fine - (role == 2 ? 100 : 0)
    }

    /// The weakest tier whose best possible final score (fine 99, this item's learning)
    /// still reaches `floor`. Secondary-role entries score 100 lower, so this is an upper
    /// bound for them too.
    @inline(__always)
    static func lowestUsefulTier(floor: Int32, learned: Int32) -> Matcher.Tier {
        if floor == .min { return .fuzzy }
        if Matcher.Tier.fuzzy.rawValue + 99 + learned / 4 >= floor { return .fuzzy }
        if Matcher.Tier.substring.rawValue + 99 + learned / 2 >= floor { return .substring }
        if Matcher.Tier.acronym.rawValue + 99 + learned >= floor { return .acronym }
        return .wordPrefix
    }

    /// Learning can lift strong tiers fully, weak tiers only partly: garbage never wins.
    @inline(__always)
    static func blend(_ s: Int32, learned: Int32) -> Int32 {
        let l = min(learned, maxLearned)
        if s >= Matcher.Tier.acronym.rawValue { return s + l }
        if s >= Matcher.Tier.substring.rawValue { return s + l / 2 }
        return s + l / 4
    }
}

/// Runs a query over a catalog. Holds reusable scratch sized to the catalog so the hot
/// path never allocates. Main-thread only (one instance per UI).
public final class Searcher {
    public private(set) var catalog: Catalog
    /// Frecency points per item (dense), filled by `Learning.prepare`.
    var base: UnsafeMutablePointer<Int32>
    /// Query-association points per item for the current query (sparse; reset after).
    var sparse: UnsafeMutablePointer<Int32>
    var cap: Int
    var touched: [Int32] = []
    /// Item pinned to row 1 for the current exact query, or -1.
    public var latch = -1
    let scratch: UnsafeMutablePointer<Int32>

    public init(_ catalog: Catalog) {
        self.catalog = catalog
        cap = max(catalog.count, 1)
        base = .allocate(capacity: cap); base.initialize(repeating: 0, count: cap)
        sparse = .allocate(capacity: cap); sparse.initialize(repeating: 0, count: cap)
        scratch = .allocate(capacity: Matcher.scratchCount)
        touched.reserveCapacity(256)
    }

    deinit { base.deallocate(); sparse.deallocate(); scratch.deallocate() }

    public func setCatalog(_ c: Catalog) {
        catalog = c
        if c.count > cap {
            base.deallocate(); sparse.deallocate()
            cap = c.count
            base = .allocate(capacity: cap); sparse = .allocate(capacity: cap)
        }
        base.initialize(repeating: 0, count: cap)
        sparse.initialize(repeating: 0, count: cap)
        touched.removeAll(keepingCapacity: true)
    }

    public func clearBase() { base.update(repeating: 0, count: cap) }
    public func setBase(item i: Int, _ v: Int32) { base[i] = v }

    @inline(__always)
    public func addBoost(item i: Int, _ value: Int32) {
        if sparse[i] == 0 { touched.append(Int32(i)) }
        sparse[i] &+= value
    }

    /// Learned points currently applied to item `i` (for debugging/tests).
    public func learned(_ i: Int) -> Int32 { min(base[i] + sparse[i], Ranking.maxLearned) }

    public func search(_ query: Matcher.Query, k: Int, learn: Learning? = nil, now: UInt32 = 0) -> TopK {
        var top = TopK(k: k)
        let m = query.count
        if m == 0 { return top }
        latch = -1
        learn?.applyBoosts(query: query.bytes, catalog: catalog, into: self, now: now)
        defer {
            for i in touched { sparse[Int(i)] = 0 }
            touched.removeAll(keepingCapacity: true)
        }
        let idx = catalog.index
        let qm = query.mask
        let minLen = query.compact.count
        let latch = self.latch
        var bestUnpinned = Int32.min
        let q0bit = Fold.charBit(query.bytes[0])
        query.bytes.withUnsafeBufferPointer { qb in
            query.compact.withUnsafeBufferPointer { cb in
                let qp = qb.baseAddress!, cp = cb.baseAddress!
                let masks = idx.masks, spans = idx.spans, starts = idx.starts, items = idx.items, bytes = idx.bytes
                let initials = idx.initials
                let base = self.base, sparse = self.sparse, scratch = self.scratch
                for e in 0..<idx.count {
                    if masks[e] & qm != qm { continue }
                    let initialHit = initials[e] & q0bit != 0
                    if !initialHit && m < 3 { continue }
                    let sp = spans[e]
                    let n = Int(sp & 0xFF)
                    if n < minLen { continue }
                    let packed = items[e]
                    let kind = Int(packed >> 24 & 0xF)
                    let item = Int(packed & 0xFF_FFFF)
                    let learned = min(base[item] &+ sparse[item], Ranking.maxLearned)
                    // Branch and bound: skip tiers that can't beat what we already have,
                    // even at their best fine score with this item's learning.
                    let floor = max(top.floor, bestUnpinned == .min ? .min : bestUnpinned - Ranking.relativeCutoff)
                    let lowest = Ranking.lowestUsefulTier(floor: floor, learned: learned)
                    if !initialHit && lowest.rawValue > Matcher.Tier.substring.rawValue { continue }
                    let raw = Matcher.score(query, qp, cp, bytes + Int(sp >> 8), n, starts[e],
                                            allowLoose: kind != Int(Catalog.Kind.bookmark.rawValue), scratch,
                                            lowest: lowest, initialHit: initialHit)
                    if raw < 0 { continue }
                    let s = Ranking.adjust(raw, kind: kind, role: Int(packed >> 28))
                    var final = Ranking.blend(s, learned: learned)
                    if final > bestUnpinned { bestUnpinned = final }
                    if item == latch && s >= Matcher.Tier.acronym.rawValue { final += Ranking.latchBonus }
                    // Ties: more learned first, then shorter entries.
                    top.insert(item: Int32(item), score: final, tie: learned << 8 | Int32(255 - n))
                }
            }
        }
        // Relative cutoff ignores the latch pin, so a pinned row doesn't hide the rest.
        top.dropBelow(bestUnpinned == .min ? .min : bestUnpinned - Ranking.relativeCutoff)
        return top
    }
}

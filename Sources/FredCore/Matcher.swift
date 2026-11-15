/// Tiered matching of a folded query against one folded entry.
///
/// Every (query, entry) pair is classified into the first tier that applies; the tier
/// sets the score band and a fine score (0–99) orders entries inside the band:
///
///     tier         base  rule
///     EXACT        1300  entry == query
///     PREFIX        900  entry starts with query
///     WORDPREFIX    800  each query token is a prefix of a word, words in order ("sys set" → System Settings)
///     ACRONYM       700  ≥2 chars, each starting a new word or continuing a run ("gc", "vsc", "gch")
///     SUBSTRING     500  contiguous anywhere, query ≥3 chars
///     FUZZY         300  subsequence with the first char on a word start, query ≥3 chars (fzf-v2 DP)
///
/// Short queries are strict: 1 char allows only EXACT/PREFIX (+WORDPREFIX for non-
/// bookmarks), 2 chars stop at ACRONYM. This is what keeps garbage out of the top 5.
/// Learning (see `Ranking`) can lift good matches by up to 300 — enough to cross one to
/// three tiers among good matches, never enough to promote FUZZY/SUBSTRING noise.
///
/// Word starts come from `Fold`: index 0, after a separator, camelCase humps,
/// letter↔digit transitions. Only the first 64 bytes carry word-start bits.
public enum Matcher {
    public enum Tier: Int32, Sendable {
        case fuzzy = 300, substring = 500, acronym = 700, wordPrefix = 800, prefix = 900, exact = 1300
    }

    public static let maxQuery = 32
    static let neg: Int32 = -1 << 20

    /// A folded query split into what the tiers need. Built once per keystroke.
    public struct Query {
        public let bytes: [UInt8]          // folded, single spaces between tokens
        public let mask: UInt64            // char-presence mask (spaces excluded)
        public let compact: [UInt8]        // bytes without spaces (acronym/fuzzy)
        public let tokens: [Range<Int>]    // token ranges into `bytes`
        public var count: Int { bytes.count }

        public init(folded: [UInt8]) {
            let b = Array(folded.prefix(Matcher.maxQuery))
            bytes = b
            mask = Fold.charMask(b)
            compact = b.filter { $0 != 0x20 }
            var toks: [Range<Int>] = []
            var s = 0
            for (i, c) in b.enumerated() where c == 0x20 {
                if i > s { toks.append(s..<i) }
                s = i + 1
            }
            if s < b.count { toks.append(s..<b.count) }
            tokens = toks
        }

        public init(_ s: String) { self.init(folded: Fold.query(s)) }
    }

    /// Score of `q` against entry text `t[0..<n]` with word-start mask `ws`, or -1.
    /// `allowLoose` = false restricts 1-char queries to EXACT/PREFIX (used for bookmarks).
    @inline(__always)
    /// `scratch` must hold `scratchCount` Int32s; it is the DP's working memory, owned by
    /// the caller so the hot path never allocates.
    public static func score(_ q: Query, _ qp: UnsafePointer<UInt8>, _ cp: UnsafePointer<UInt8>,
                             _ t: UnsafePointer<UInt8>, _ n: Int, _ ws: UInt64, allowLoose: Bool,
                             _ scratch: UnsafeMutablePointer<Int32>) -> Int32 {
        let m = q.count
        if q.compact.count > n { return -1 }
        // EXACT / PREFIX
        if m <= n && t[0] == qp[0] && memeq(qp, t, m) {
            if m == n { return Tier.exact.rawValue + 99 }
            return Tier.prefix.rawValue + 99 - min(40, Int32(n - m))
        }
        if m == 1 {
            guard allowLoose else { return -1 }
            // WORDPREFIX for a single char: first later word starting with it.
            var w = ws & ~1
            var idx: Int32 = 1
            while w != 0 {
                let p = w.trailingZeroBitCount
                if t[p] == qp[0] { return Tier.wordPrefix.rawValue + fineWordPrefix(idx, n, 1) }
                w &= w - 1; idx += 1
            }
            return -1
        }
        if let s = wordPrefix(q, qp, t, n, ws) { return s }
        let cm = q.compact.count
        if q.tokens.count == 1 || cm >= 2 {
            if let s = acronym(cp, cm, t, n, ws) { return s }
        }
        if m < 3 { return -1 }
        if let s = substring(qp, m, t, n) { return s }
        return fuzzy(cp, cm, t, n, ws, scratch)
    }

    // MARK: - Tiers

    @inline(__always)
    static func fineWordPrefix(_ firstWord: Int32, _ n: Int, _ matched: Int) -> Int32 {
        max(0, 99 - 4 * firstWord - min(40, Int32(n - matched)) / 2)
    }

    /// Tokens must be prefixes of words, in order (words need not be adjacent).
    @inline(__always)
    static func wordPrefix(_ q: Query, _ qp: UnsafePointer<UInt8>, _ t: UnsafePointer<UInt8>,
                           _ n: Int, _ ws: UInt64) -> Int32? {
        var w = ws
        var wordIdx: Int32 = 0
        var first: Int32 = -1
        var matched = 0
        var minPos = 0
        for tok in q.tokens {
            let len = tok.count
            var found = false
            while w != 0 {
                let p = w.trailingZeroBitCount
                w &= w - 1
                let thisWord = wordIdx
                wordIdx += 1
                if p < minPos { continue }
                if p + len <= n && memeq(qp + tok.lowerBound, t + p, len) {
                    if first < 0 { first = thisWord }
                    matched += len
                    minPos = p + len
                    found = true
                    break
                }
            }
            if !found { return nil }
        }
        return Tier.wordPrefix.rawValue + fineWordPrefix(first, n, matched)
    }

    /// Each query byte starts a new word or continues the current run. Backtracking
    /// search over word starts; query and word counts are tiny.
    @inline(__always)
    static func acronym(_ c: UnsafePointer<UInt8>, _ m: Int, _ t: UnsafePointer<UInt8>, _ n: Int,
                        _ ws: UInt64) -> Int32? {
        guard m >= 2 else { return nil }
        let limit = min(n, 64)
        let wordsMask = limit == 64 ? ws : ws & ((1 << UInt64(limit)) - 1)
        // `used` collects word starts where a run began, for the fine score.
        var used: UInt64 = 0
        guard acr(c, 0, m, t, limit, wordsMask, -1, &used) else { return nil }
        let totalWords = Int32(wordsMask.nonzeroBitCount)
        let lastStart = 63 - used.leadingZeroBitCount
        let wordsUpToLast = Int32((wordsMask & ((2 << UInt64(lastStart)) &- 1)).nonzeroBitCount)
        let matchedWords = Int32(used.nonzeroBitCount)
        let skipped = wordsUpToLast - matchedWords
        let uncovered = totalWords - wordsUpToLast
        return Tier.acronym.rawValue + max(0, 99 - 15 * skipped - 5 * uncovered)
    }

    /// Can c[i...] be matched with c[i] at a word start after `prev`, or (if i > 0) at prev+1?
    static func acr(_ c: UnsafePointer<UInt8>, _ i: Int, _ m: Int, _ t: UnsafePointer<UInt8>, _ n: Int,
                    _ ws: UInt64, _ prev: Int, _ used: inout UInt64) -> Bool {
        if i == m { return true }
        // Continue the run inside the current word.
        if i > 0 && prev + 1 < n && t[prev + 1] == c[i] && (ws >> UInt64(prev + 1)) & 1 == 0 {
            if acr(c, i + 1, m, t, n, ws, prev + 1, &used) { return true }
        }
        // Jump to a later word start.
        var w = prev + 1 >= 64 ? 0 : ws & ~((1 << UInt64(prev + 1)) &- 1)
        while w != 0 {
            let p = w.trailingZeroBitCount
            w &= w - 1
            if t[p] == c[i] {
                let before = used
                used |= 1 << UInt64(p)
                if acr(c, i + 1, m, t, n, ws, p, &used) { return true }
                used = before
            }
        }
        return false
    }

    @inline(__always)
    static func substring(_ q: UnsafePointer<UInt8>, _ m: Int, _ t: UnsafePointer<UInt8>, _ n: Int) -> Int32? {
        if m > n { return nil }
        let c0 = q[0]
        var p = 0
        while p + m <= n {
            if t[p] == c0 && memeq(q, t + p, m) {
                return Tier.substring.rawValue + max(0, 99 - min(40, Int32(p)) - min(40, Int32(n - m)) / 2)
            }
            p += 1
        }
        return nil
    }

    // MARK: - FUZZY (fzf v2 DP, first char forced onto a word start)

    static let fMatch: Int32 = 16
    static let fWord: Int32 = 10
    static let fConsecutive: Int32 = 4
    static let fGapStart: Int32 = 3
    static let fGapExt: Int32 = 1

    @inline(__always)
    static func fuzzy(_ q: UnsafePointer<UInt8>, _ m: Int, _ t: UnsafePointer<UInt8>, _ n: Int, _ ws: UInt64,
                      _ scratch: UnsafeMutablePointer<Int32>) -> Int32 {
        guard m >= 3, m <= n else { return -1 }
        let s = dp(q, m, t, n, ws, scratch)
        if s <= neg / 2 { return -1 }
        // Normalize: best possible is every byte on a word start with first doubled.
        let maxS = fMatch * Int32(m) + fWord * Int32(m + 1)
        let fine = max(0, min(99, s * 99 / maxS))
        return Tier.fuzzy.rawValue + fine
    }

    @inline(__always)
    static func wbonus(_ j: Int, _ ws: UInt64) -> Int32 {
        j < 64 && (ws >> UInt64(j)) & 1 != 0 ? fWord : 0
    }

    /// Two-row DP. S[i][j] = best score with q[0...i] matched and q[i] at t[j];
    /// R[i][j] = bonus of the first byte of the consecutive run ending there.
    public static let scratchCount = 4 * 256

    static func dp(_ q: UnsafePointer<UInt8>, _ m: Int, _ t: UnsafePointer<UInt8>, _ n: Int, _ ws: UInt64,
                   _ buf: UnsafeMutablePointer<Int32>) -> Int32 {
        do {
            var prevS = buf, prevR = prevS + 256
            var curS = prevS + 512, curR = prevS + 768
            for p in 0..<n { prevS[p] = neg; curS[p] = neg }
            // Row 0: only word starts.
            var any = false
            for p in 0..<n where t[p] == q[0] && wbonus(p, ws) > 0 {
                prevS[p] = fMatch + 2 * fWord; prevR[p] = fWord; any = true
            }
            if !any { return neg }
            for i in 1..<m {
                let c = q[i]
                var gapBest = neg
                for p in 0..<n {
                    gapBest -= fGapExt
                    if p >= 2 {
                        let g = prevS[p - 2] - fGapStart
                        if g > gapBest { gapBest = g }
                    }
                    if t[p] != c || p < i { curS[p] = neg; continue }
                    let b = wbonus(p, ws)
                    var s = neg, r: Int32 = 0
                    if p > 0 && prevS[p - 1] > neg / 2 {
                        let rb = max(prevR[p - 1], b)
                        s = prevS[p - 1] + fMatch + max(rb, fConsecutive); r = rb
                    }
                    if gapBest > neg / 2 {
                        let g = gapBest + fMatch + b
                        if g > s { s = g; r = b }
                    }
                    curS[p] = s; curR[p] = r
                }
                swap(&prevS, &curS); swap(&prevR, &curR)
            }
            var best = neg
            for p in 0..<n where prevS[p] > best { best = prevS[p] }
            return best
        }
    }

    @inline(__always)
    static func memeq(_ a: UnsafePointer<UInt8>, _ b: UnsafePointer<UInt8>, _ n: Int) -> Bool {
        var k = 0
        while k < n { if a[k] != b[k] { return false }; k += 1 }
        return true
    }
}

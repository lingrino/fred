import Foundation

/// Clipboard history: in-memory struct-of-arrays + append-only log on disk.
///
/// Entries are kept oldest → newest (append order); the UI walks backwards. Re-copying
/// existing content moves it to the end (newest) instead of duplicating it. Entries
/// older than `retention` (90 days) are dropped at load and periodically.
///
/// Search is token-AND substring matching over the first `searchBytes` of folded text,
/// newest first — fuzzy subsequence matching is useless on long text (any 3 letters
/// match everything), and for history "most recent" is the right order.
///
/// Disk format (`clipboard.log`): "FRDC" + u32 version, then records
///     u8 op | u32 time | u64 hash | ...
///     op 1 ADD:    u8 kind | u16 appLen | app | u32 textLen | text
///     op 2 TOUCH:  (nothing more) — entry with `hash` becomes newest at `time`
///     op 3 DELETE: (nothing more)
/// Images live next to the log as `images/<hash>.png`; their entry text is a label.
/// The log (and the in-memory arenas) are rewritten compactly when they have accumulated
/// garbage: at load, and from the hourly prune.
public final class ClipStore {
    public enum Kind: UInt8, Sendable { case text = 0, image = 1, files = 2 }

    public static let retention: UInt32 = 90 * 86400
    public static let searchBytes = 4096
    public static let maxTextBytes = 8 << 20

    // SoA, index = age order.
    public private(set) var time: [UInt32] = []
    public private(set) var kind: [Kind] = []
    public private(set) var hash: [UInt64] = []
    var app: [UInt16] = []
    var textSpan: [Range<Int>] = []     // into textArena
    var foldSpan: [Range<Int>] = []     // into foldArena
    var mask: [UInt64] = []
    var textArena: [UInt8] = []
    var foldArena: [UInt8] = []
    var apps: [String] = []             // interned source app bundle ids
    var appIndex: [String: UInt16] = [:]

    public var count: Int { time.count }
    let dir: URL?
    private var logURL: URL?
    private var log: AppendFile?
    private var garbageBytes = 0

    /// `dir` nil = in-memory (tests).
    public init(dir: URL?, now: UInt32 = UInt32(Date().timeIntervalSince1970)) {
        self.dir = dir
        guard let dir else { return }
        try? FileManager.default.createDirectory(at: imagesDir!, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("clipboard.log")
        logURL = url
        _ = AppendFile.claim(url, header: Self.magic)
        let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let goodEnd = replay(url)
        let pruned = prune(now: now, persist: false)
        // Rewrite when there's garbage to drop or the tail is torn/corrupt (a torn tail
        // left in place would swallow every later append).
        var clean = goodEnd == before
        if pruned > 0 || garbageBytes > 1 << 20 || garbageBytes > before / 4 || !clean {
            clean = rewrite(url)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(Self.magic), attributes: [.posixPermissions: 0o600])
        }
        log = AppendFile(url, validLength: !clean && goodEnd >= 8 ? goodEnd : nil)
    }

    static let magic: [UInt8] = Array("FRDC".utf8) + [1, 0, 0, 0]
    public var imagesDir: URL? { dir?.appendingPathComponent("images", isDirectory: true) }

    public func imageURL(_ h: UInt64) -> URL? {
        imagesDir?.appendingPathComponent(String(format: "%016llx.png", h))
    }

    // MARK: Accessors

    // Public accessors check `i`: FredCore builds with -Ounchecked, where an index that
    // went stale under a caller would read arbitrary memory instead of trapping.

    public func text(_ i: Int) -> String {
        guard i >= 0 && i < count else { return "" }
        return String(decoding: textArena[textSpan[i]], as: UTF8.self)
    }

    /// The first `n` bytes of the text (a cut multi-byte character becomes U+FFFD): for
    /// row titles and previews, which must not cost O(clip size).
    public func head(_ i: Int, bytes n: Int) -> String {
        guard i >= 0 && i < count else { return "" }
        let sp = textSpan[i]
        return String(decoding: textArena[sp.lowerBound..<min(sp.upperBound, sp.lowerBound + n)], as: UTF8.self)
    }

    public func byteCount(_ i: Int) -> Int { i >= 0 && i < count ? textSpan[i].count : 0 }

    public func app(_ i: Int) -> String? {
        guard i >= 0 && i < count else { return nil }
        let a = app[i]
        return a == 0 ? nil : apps[Int(a) - 1]
    }

    public func index(ofHash h: UInt64) -> Int? { hash.lastIndex(of: h) }

    // MARK: Mutation

    /// Adds content (or bumps it to newest if already present). Returns the entry index.
    @discardableResult
    public func add(kind k: Kind, text: String, hash h: UInt64, app: String?, time t: UInt32) -> Int {
        if let i = index(ofHash: h) {
            touch(i, time: t)
            return count - 1
        }
        var bytes = Array(text.utf8)
        if bytes.count > Self.maxTextBytes { bytes.removeLast(bytes.count - Self.maxTextBytes) }
        append(kind: k, textBytes: bytes, hash: h, app: app, time: t)
        writeAdd(kind: k, hash: h, app: app, text: bytes, time: t)
        return count - 1
    }

    public func touch(_ i: Int, time t: UInt32) {
        guard i >= 0 && i < count else { return }
        let h = hash[i]
        moveToEnd(i, time: t)
        writeOp(2, time: t, hash: h)
    }

    public func delete(_ i: Int) {
        guard i >= 0 && i < count else { return }
        let h = hash[i]
        if kind[i] == .image, let u = imageURL(h) { try? FileManager.default.removeItem(at: u) }
        remove(at: i)
        writeOp(3, time: 0, hash: h)
    }

    /// Drops entries older than the retention window. Returns how many were removed.
    @discardableResult
    public func prune(now: UInt32, persist: Bool = true) -> Int {
        let cutoff = now > Self.retention ? now - Self.retention : 0
        // Usually the oldest entries are first, but a clock change can leave times out of
        // order, so scan everything (hourly, a few thousand entries).
        var removed = 0
        var i = count - 1
        while i >= 0 {
            if time[i] < cutoff {
                if kind[i] == .image, let u = imageURL(hash[i]) { try? FileManager.default.removeItem(at: u) }
                if persist { writeOp(3, time: 0, hash: hash[i]) }
                remove(at: i)
                removed += 1
            }
            i -= 1
        }
        if persist { compactIfNeeded() }
        return removed
    }

    /// Deleted and pruned clips stay in the log and the arenas until a rewrite; Fred runs
    /// for weeks, so don't wait for the next launch once there's a lot of it.
    func compactIfNeeded() {
        guard let url = logURL, garbageBytes > max(4 << 20, textArena.count / 2) else { return }
        log = nil   // the rewrite replaces the file; appends must go to the new one
        rewrite(url)
        log = AppendFile(url)
    }

    // MARK: Search

    /// Indices of matching entries, newest first, at most `limit`.
    /// Every space-separated token of `query` must occur (substring, folded).
    public func search(_ query: String, limit: Int) -> [Int] {
        let q = Fold.query(query)
        var out: [Int] = []
        out.reserveCapacity(min(limit, count))
        if q.isEmpty {
            var i = count - 1
            while i >= 0 && out.count < limit { out.append(i); i -= 1 }
            return out
        }
        let tokens = q.split(separator: 0x20).map { Array($0) }
        let anchors = tokens.map(Self.rarestByte)
        let qmask = Fold.charMask(q)
        foldArena.withUnsafeBufferPointer { arena in
            let base = arena.baseAddress!
            var i = count - 1
            while i >= 0 && out.count < limit {
                defer { i -= 1 }
                if mask[i] & qmask != qmask { continue }
                let span = foldSpan[i]
                var all = true
                for (t, tok) in tokens.enumerated() where !contains(base + span.lowerBound, span.count, tok, anchor: anchors[t]) {
                    all = false; break
                }
                if all { out.append(i) }
            }
        }
        return out
    }

    /// memchr for the needle's rarest byte (`anchor`, its offset in the needle), then
    /// compare — libc memchr is NEON-vectorized, and anchoring on "x" rather than the "e"
    /// of "example" skips most false starts in English text.
    @inline(__always)
    func contains(_ hay: UnsafePointer<UInt8>, _ n: Int, _ needle: [UInt8], anchor a: Int) -> Bool {
        let m = needle.count
        guard m > 0, m <= n else { return m == 0 }
        return needle.withUnsafeBufferPointer { nb in
            let byte = Int32(nb[a])
            var p = hay + a                       // anchor positions that leave room for the needle
            let end = hay + (n - m + 1) + a
            while p < end {
                guard let hit = memchr(p, byte, end - p) else { return false }
                let h = UnsafePointer(hit.assumingMemoryBound(to: UInt8.self))
                if memcmp(h - a, nb.baseAddress!, m) == 0 { return true }
                p = h + 1
            }
            return false
        }
    }

    /// Offset of the needle byte least likely to occur in text: letters by English
    /// frequency, anything else (digits, symbols, non-ASCII) rarer than any letter.
    static func rarestByte(_ needle: [UInt8]) -> Int {
        let common = Array("etaoinsrhldcumfpgwybvkxjqz ".utf8)   // most → least frequent
        var best = 0, bestRank = -1
        for (i, b) in needle.enumerated() {
            let rank = common.firstIndex(of: b) ?? common.count
            if rank > bestRank { best = i; bestRank = rank }
        }
        return best
    }

    // MARK: Internals

    private func intern(_ a: String?) -> UInt16 {
        guard let a, !a.isEmpty else { return 0 }
        if let i = appIndex[a] { return i }
        apps.append(a)
        let i = UInt16(apps.count)
        appIndex[a] = i
        return i
    }

    private func append(kind k: Kind, textBytes: [UInt8], hash h: UInt64, app a: String?, time t: UInt32) {
        let ts = textArena.count
        textArena.append(contentsOf: textBytes)
        let fs = foldArena.count
        let head = textBytes.prefix(Self.searchBytes)
        Self.foldFast(head, into: &foldArena)
        time.append(t); kind.append(k); hash.append(h); app.append(intern(a))
        textSpan.append(ts..<textArena.count)
        foldSpan.append(fs..<foldArena.count)
        mask.append(Fold.charMask(foldArena[fs..<foldArena.count]))
    }

    /// ASCII fast path for folding long text; falls back to full Unicode folding.
    static func foldFast(_ bytes: ArraySlice<UInt8>, into out: inout [UInt8]) {
        var ascii = true
        for b in bytes where b >= 0x80 { ascii = false; break }
        if ascii {
            // No reserveCapacity here: reserving exactly per clip defeats the array's
            // geometric growth and made loading 10k clips quadratic (0.7 s vs 40 ms).
            for b in bytes {
                if b >= 0x41 && b <= 0x5A { out.append(b | 0x20) }
                else if Fold.isSeparator(b) || b == 0x0A || b == 0x0D { out.append(0x20) }
                else { out.append(b) }
            }
        } else {
            // The search window may cut a multi-byte character; String(decoding:) turns a
            // broken tail into U+FFFD instead of dropping valid characters.
            let s = String(decoding: bytes, as: UTF8.self)
            let start = out.count
            Fold.fold(s, into: &out)
            for k in start..<out.count where out[k] == 0x0A || out[k] == 0x0D { out[k] = 0x20 }
        }
    }

    private func remove(at i: Int) {
        garbageBytes += textSpan[i].count + foldSpan[i].count
        time.remove(at: i); kind.remove(at: i); hash.remove(at: i); app.remove(at: i)
        textSpan.remove(at: i); foldSpan.remove(at: i); mask.remove(at: i)
    }

    private func moveToEnd(_ i: Int, time t: UInt32) {
        let k = kind[i], h = hash[i], a = app[i], ts = textSpan[i], fs = foldSpan[i], m = mask[i]
        time.remove(at: i); kind.remove(at: i); hash.remove(at: i); app.remove(at: i)
        textSpan.remove(at: i); foldSpan.remove(at: i); mask.remove(at: i)
        time.append(t); kind.append(k); hash.append(h); app.append(a)
        textSpan.append(ts); foldSpan.append(fs); mask.append(m)
    }

    // MARK: Log

    private func writeOp(_ op: UInt8, time t: UInt32, hash h: UInt64) {
        guard let log else { return }
        var d = Data(capacity: 13)
        d.append(op)
        withUnsafeBytes(of: t.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: h.littleEndian) { d.append(contentsOf: $0) }
        log.append(d)
    }

    private func writeAdd(kind k: Kind, hash h: UInt64, app a: String?, text: [UInt8], time t: UInt32) {
        log?.append(Self.encodeAdd(kind: k, hash: h, app: a, text: text, time: t))
    }

    static func encodeAdd(kind k: Kind, hash h: UInt64, app a: String?, text: [UInt8], time t: UInt32) -> Data {
        let ab = Array((a ?? "").utf8.prefix(65535))
        var d = Data(capacity: 20 + ab.count + text.count)
        d.append(1)
        withUnsafeBytes(of: t.littleEndian) { d.append(contentsOf: $0) }
        withUnsafeBytes(of: h.littleEndian) { d.append(contentsOf: $0) }
        d.append(k.rawValue)
        withUnsafeBytes(of: UInt16(ab.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: ab)
        withUnsafeBytes(of: UInt32(text.count).littleEndian) { d.append(contentsOf: $0) }
        d.append(contentsOf: text)
        return d
    }

    /// Replays the log; returns the offset just past the last complete record (0 if the
    /// file is missing or has no complete header; `AppendFile.claim` has already moved
    /// a foreign or other-version file aside).
    private func replay(_ url: URL) -> Int {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped), data.count >= 8,
              Array(data.prefix(8)) == Self.magic else { return 0 }
        var good = 8
        data.withUnsafeBytes { raw in
            var i = 8
            let n = raw.count
            func u32(_ o: Int) -> UInt32 { raw.loadUnaligned(fromByteOffset: o, as: UInt32.self).littleEndian }
            func u64(_ o: Int) -> UInt64 { raw.loadUnaligned(fromByteOffset: o, as: UInt64.self).littleEndian }
            while i + 13 <= n {
                let op = raw[i], t = u32(i + 1), h = u64(i + 5)
                i += 13
                switch op {
                case 1:
                    guard i + 3 <= n else { return }
                    let k = Kind(rawValue: raw[i]) ?? .text
                    let al = Int(raw.loadUnaligned(fromByteOffset: i + 1, as: UInt16.self).littleEndian)
                    guard i + 3 + al + 4 <= n else { return }
                    let a = String(decoding: UnsafeRawBufferPointer(rebasing: raw[(i + 3)..<(i + 3 + al)]), as: UTF8.self)
                    let tl = Int(u32(i + 3 + al))
                    let ts = i + 7 + al
                    guard ts + tl <= n else { return }   // torn tail
                    let text = Array(UnsafeRawBufferPointer(rebasing: raw[ts..<(ts + tl)]))
                    if let j = index(ofHash: h) { remove(at: j) }
                    append(kind: k, textBytes: text, hash: h, app: a.isEmpty ? nil : a, time: t)
                    i = ts + tl
                case 2:
                    if let j = index(ofHash: h) { moveToEnd(j, time: t); garbageBytes += 13 }
                case 3:
                    if let j = index(ofHash: h) { remove(at: j) }
                    garbageBytes += 13
                default:
                    return   // corrupt: keep what we have
                }
                good = i
            }
        }
        return good
    }

    /// Writes the live entries as a fresh log and atomically replaces the old one.
    @discardableResult
    private func rewrite(_ url: URL) -> Bool {
        var d = Data(Self.magic)
        for i in 0..<count {
            d.append(Self.encodeAdd(kind: kind[i], hash: hash[i], app: app(i), text: Array(textArena[textSpan[i]]), time: time[i]))
        }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try d.write(to: tmp, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tmp.path)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch { return false }
        // Compact arenas too.
        var ta: [UInt8] = [], fa: [UInt8] = []
        ta.reserveCapacity(textArena.count); fa.reserveCapacity(foldArena.count)
        for i in 0..<count {
            let ts = ta.count; ta.append(contentsOf: textArena[textSpan[i]]); textSpan[i] = ts..<ta.count
            let fs = fa.count; fa.append(contentsOf: foldArena[foldSpan[i]]); foldSpan[i] = fs..<fa.count
        }
        textArena = ta; foldArena = fa
        garbageBytes = 0
        // Remove orphaned image files.
        if let idir = imagesDir, let files = try? FileManager.default.contentsOfDirectory(atPath: idir.path) {
            let live = Set((0..<count).filter { kind[$0] == .image }.map { String(format: "%016llx.png", hash[$0]) })
            for f in files where !live.contains(f) { try? FileManager.default.removeItem(at: idir.appendingPathComponent(f)) }
        }
        return true
    }

    /// FNV-1a 64 — stable content hash for dedupe and image file names.
    public static func hash(_ bytes: UnsafeRawBufferPointer, seed: UInt64 = 0) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325 ^ seed
        for b in bytes { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }

    public static func hash(_ s: String, kind: Kind) -> UInt64 {
        var s = s
        return s.withUTF8 { hash(UnsafeRawBufferPointer($0), seed: UInt64(kind.rawValue)) }
    }

    public var stats: String {
        let images = kind.filter { $0 == .image }.count
        return "\(count) clips (\(images) images), text \(textArena.count / 1024) KB, oldest \(time.first.map { "\((UInt32(Date().timeIntervalSince1970) - $0) / 86400)d" } ?? "-")"
    }
}

/// The searchable form of every catalog entry, laid out for the matcher's scan.
///
/// Struct-of-arrays inside ONE allocation, each array 128-byte aligned (Apple Silicon
/// cache line):
///
///     masks  [UInt64] × n   char-presence mask — the only array touched for every entry
///     spans  [UInt32] × n   (start << 8) | len  into `bytes` (len ≤ 255, start < 16 MiB)
///     starts [UInt64] × n   word-start bitmask over the first 64 folded bytes
///     initials [UInt64] × n char mask of the bytes AT word starts (first-char prefilter)
///     items  [UInt32] × n   item index (low 24 bits) | kind << 24 | role << 28
///     bytes  [UInt8]        folded text of all entries, back to back, + 16 bytes padding
///
/// An item can own several entries (aliases: an app's file name and display name, a
/// bookmark's title and host). The index is immutable after `init`; a new one is built
/// whenever the catalog changes, and it is `Sendable` so it can be built off-main.
public final class SearchIndex: @unchecked Sendable {
    public let count: Int
    @usableFromInline let masks: UnsafePointer<UInt64>
    @usableFromInline let spans: UnsafePointer<UInt32>
    @usableFromInline let starts: UnsafePointer<UInt64>
    @usableFromInline let initials: UnsafePointer<UInt64>
    @usableFromInline let items: UnsafePointer<UInt32>
    @usableFromInline let bytes: UnsafePointer<UInt8>
    private let block: UnsafeMutableRawPointer
    public let byteCount: Int

    public static let maxEntryLength = 255
    static let line = 128

    /// How an entry relates to its item; affects score (see `Ranking.adjust`).
    public enum Role: UInt8, Sendable {
        case primary = 0    // the title
        case alias = 1      // derived name: file name, CFBundleName, nickname (−5 fine)
        case secondary = 2  // weaker field: bookmark host, contact email (one tier lower)
    }

    /// One searchable string and the item it belongs to.
    public struct Entry: Sendable {
        public var text: String
        public var item: UInt32
        public var kind: Catalog.Kind
        public var role: Role
        public init(_ text: String, item: UInt32, kind: Catalog.Kind, role: Role = .primary) {
            self.text = text; self.item = item; self.kind = kind; self.role = role
        }
    }

    @inline(__always) static func pack(item: UInt32, kind: Catalog.Kind, role: Role) -> UInt32 {
        precondition(item < 1 << 24)
        return item | UInt32(kind.rawValue) << 24 | UInt32(role.rawValue) << 28
    }

    public init(_ entries: [Entry]) {
        // Fold everything into a temporary arena first; sizes are known afterwards.
        var arena: [UInt8] = []
        arena.reserveCapacity(entries.count * 24)
        var spans: [UInt32] = []; spans.reserveCapacity(entries.count)
        var starts: [UInt64] = []; starts.reserveCapacity(entries.count)
        var masks: [UInt64] = []; masks.reserveCapacity(entries.count)
        var initials: [UInt64] = []; initials.reserveCapacity(entries.count)
        var items: [UInt32] = []; items.reserveCapacity(entries.count)
        var tmp: [UInt8] = []
        for e in entries {
            tmp.removeAll(keepingCapacity: true)
            let ws = Fold.fold(e.text, into: &tmp)
            // Trim trailing separators; cap length.
            while tmp.last == 0x20 { tmp.removeLast() }
            if tmp.isEmpty { continue }
            let len = min(tmp.count, Self.maxEntryLength)
            let start = arena.count
            precondition(start < 1 << 24, "search arena exceeds 16 MiB")
            arena.append(contentsOf: tmp[0..<len])
            spans.append(UInt32(start) << 8 | UInt32(len))
            let w = len >= 64 ? ws : ws & ((1 << UInt64(len)) &- 1)
            starts.append(w)
            masks.append(Fold.charMask(tmp[0..<len]))
            var ini: UInt64 = 0, bits = w
            while bits != 0 { ini |= Fold.charBit(tmp[bits.trailingZeroBitCount]); bits &= bits &- 1 }
            initials.append(ini)
            items.append(Self.pack(item: e.item, kind: e.kind, role: e.role))
        }
        let n = spans.count
        count = n
        byteCount = arena.count

        func up(_ x: Int) -> Int { (x + Self.line - 1) & ~(Self.line - 1) }
        let oMasks = 0
        let oSpans = up(oMasks + n * 8)
        let oStarts = up(oSpans + n * 4)
        let oInitials = up(oStarts + n * 8)
        let oItems = up(oInitials + n * 8)
        let oBytes = up(oItems + n * 4)
        let total = up(oBytes + arena.count + 16)
        block = UnsafeMutableRawPointer.allocate(byteCount: max(total, Self.line), alignment: Self.line)
        block.initializeMemory(as: UInt8.self, repeating: 0, count: max(total, Self.line))

        let m = (block + oMasks).bindMemory(to: UInt64.self, capacity: n)
        let s = (block + oSpans).bindMemory(to: UInt32.self, capacity: n)
        let w = (block + oStarts).bindMemory(to: UInt64.self, capacity: n)
        let ini = (block + oInitials).bindMemory(to: UInt64.self, capacity: n)
        let it = (block + oItems).bindMemory(to: UInt32.self, capacity: n)
        let b = (block + oBytes).bindMemory(to: UInt8.self, capacity: arena.count + 16)
        masks.withUnsafeBufferPointer { m.update(from: $0.baseAddress!, count: n) }
        spans.withUnsafeBufferPointer { s.update(from: $0.baseAddress!, count: n) }
        starts.withUnsafeBufferPointer { w.update(from: $0.baseAddress!, count: n) }
        initials.withUnsafeBufferPointer { ini.update(from: $0.baseAddress!, count: n) }
        items.withUnsafeBufferPointer { it.update(from: $0.baseAddress!, count: n) }
        arena.withUnsafeBufferPointer { b.update(from: $0.baseAddress!, count: arena.count) }
        self.masks = UnsafePointer(m); self.spans = UnsafePointer(s); self.starts = UnsafePointer(w)
        self.initials = UnsafePointer(ini)
        self.items = UnsafePointer(it); self.bytes = UnsafePointer(b)
    }

    deinit { block.deallocate() }

    /// Folded text of entry `e` (for tests and debugging).
    public func text(_ e: Int) -> String {
        let sp = spans[e]
        return String(decoding: UnsafeBufferPointer(start: bytes + Int(sp >> 8), count: Int(sp & 0xFF)), as: UTF8.self)
    }

    public func item(_ e: Int) -> UInt32 { items[e] & 0xFF_FFFF }
}

/// Everything the launcher can show, merged from all sources, plus its search index.
///
/// Items are stored struct-of-arrays. Only `kind`, `keys`, and the search index are read
/// during a search; strings are touched only for the ≤5 rows actually displayed.
/// Immutable once built: sources publish new item lists, the app builds a new Catalog
/// off-main and swaps it in.
public final class Catalog: @unchecked Sendable {
    public enum Kind: UInt8, Sendable, CaseIterable {
        case app = 0, settings, command, bookmark, contact
    }

    /// One item as produced by a source.
    public struct Item: Sendable {
        public var kind: Kind
        /// Shown in the result row.
        public var title: String
        /// Derived names: file name vs display name, CFBundleName, nickname.
        public var aliases: [String]
        /// Weaker searchable fields: bookmark host, contact email/company.
        public var secondary: [String]
        /// Kind-specific action payload: app path, URL, contact identifier, command id.
        public var payload: String
        /// Stable identity used by learning; survives re-indexing and restarts.
        public var key: UInt64
        /// Right-aligned context shown in the row (e.g. the pane a sub-setting lives in).
        public var detail: String?
        /// A sub-item such as "True Tone" (in Displays): its title ranks below app/pane
        /// title matches (role `subTitle`, see `Ranking.rolePenalty`).
        public var weak: Bool
        /// Noisy synonyms (System Settings search terms): role `subKeyword`, far below
        /// any title, so they only fill rows nothing better wants.
        public var weakKeywords: [String]

        public init(kind: Kind, title: String, aliases: [String] = [], secondary: [String] = [],
                    payload: String, key: UInt64? = nil, detail: String? = nil, weak: Bool = false,
                    weakKeywords: [String] = []) {
            self.kind = kind; self.title = title; self.aliases = aliases; self.secondary = secondary
            self.payload = payload
            self.key = key ?? Catalog.key(kind, payload)
            self.detail = detail; self.weak = weak; self.weakKeywords = weakKeywords
        }
    }

    public let count: Int
    public let kinds: [Kind]
    public let titles: [String]
    public let payloads: [String]
    public let details: [String?]
    public let keys: [UInt64]
    public let index: SearchIndex
    /// (key, item) sorted by key — maps learning records to current item indices.
    let keyOrder: [(key: UInt64, item: UInt32)]

    public init(_ items: [Item]) {
        count = items.count
        kinds = items.map(\.kind)
        titles = items.map(\.title)
        payloads = items.map(\.payload)
        details = items.map(\.detail)
        keys = items.map(\.key)
        var entries: [SearchIndex.Entry] = []
        entries.reserveCapacity(items.count * 2)
        for (i, it) in items.enumerated() {
            entries.append(.init(it.title, item: UInt32(i), kind: it.kind, role: it.weak ? .subTitle : .primary))
            for a in it.aliases where a != it.title {
                entries.append(.init(a, item: UInt32(i), kind: it.kind, role: .alias))
            }
            for a in it.secondary { entries.append(.init(a, item: UInt32(i), kind: it.kind, role: .secondary)) }
            for a in it.weakKeywords { entries.append(.init(a, item: UInt32(i), kind: it.kind, role: it.weak ? .subKeyword : .paneTerm)) }
        }
        index = SearchIndex(entries)
        keyOrder = items.indices.map { (items[$0].key, UInt32($0)) }.sorted { $0.key < $1.key }
    }

    /// Item index for a learning key, or nil if the item no longer exists.
    public func item(forKey k: UInt64) -> Int? {
        var lo = 0, hi = keyOrder.count
        while lo < hi {
            let mid = (lo + hi) >> 1
            if keyOrder[mid].key < k { lo = mid + 1 } else { hi = mid }
        }
        return lo < keyOrder.count && keyOrder[lo].key == k ? Int(keyOrder[lo].item) : nil
    }

    /// FNV-1a over kind + payload. Stable across runs (unlike Swift's seeded Hasher).
    public static func key(_ kind: Kind, _ payload: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        h = (h ^ UInt64(kind.rawValue)) &* 0x100_0000_01b3
        for b in payload.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return h
    }
}

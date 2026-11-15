import Foundation

/// Text folding: turns display strings into the byte form the matcher compares.
///
/// Folded text is UTF-8 where:
///   - ASCII letters are lowercase,
///   - non-ASCII letters are case/diacritic/width folded ("É" → "e", "ﬁ" → "fi"),
///   - separators (space, tab, - _ . / : ,) all become a single 0x20 byte,
///   - everything else is kept verbatim.
///
/// Folding runs at index-build time (off the hot path) and once per keystroke for the
/// query. Both sides use the same function so equality is plain byte equality.
public enum Fold {
    /// Separator bytes that fold to a space. Only ASCII.
    @inline(__always)
    static func isSeparator(_ c: UInt8) -> Bool {
        c == 0x20 || c == 0x09 || c == UInt8(ascii: "-") || c == UInt8(ascii: "_") || c == UInt8(ascii: ".")
            || c == UInt8(ascii: "/") || c == UInt8(ascii: ":") || c == UInt8(ascii: ",")
    }

    /// Appends the folded bytes of `s` to `out` and returns a word-start bitmask: bit j is
    /// set when folded byte j (relative to where this call started appending) begins a word.
    /// Only the first 64 folded bytes can carry word-start bits.
    ///
    /// Word starts: the first character; a letter/digit after a separator or symbol;
    /// an uppercase letter after a lowercase one ("iTally" → i|Tally); a digit after a
    /// letter ("Gizmo4"); a letter after a digit ("2Fold").
    @discardableResult
    public static func fold(_ s: String, into out: inout [UInt8]) -> UInt64 {
        let base = out.count
        var starts: UInt64 = 0
        // Character classes of the previous scalar: 0 none/separator, 1 lower, 2 upper, 3 digit, 4 other-letter
        var prev: UInt8 = 0
        for scalar in s.unicodeScalars {
            let v = scalar.value
            let pos = out.count - base
            var cls: UInt8
            if v < 0x80 {
                let c = UInt8(v)
                if c >= 0x61 && c <= 0x7A { cls = 1; out.append(c) }
                else if c >= 0x41 && c <= 0x5A { cls = 2; out.append(c | 0x20) }
                else if c >= 0x30 && c <= 0x39 { cls = 3; out.append(c) }
                else if isSeparator(c) { cls = 0; out.append(0x20) }
                else { cls = 0; out.append(c) }   // symbols: kept, but act like separators for word starts
            } else {
                let props = scalar.properties
                if props.isAlphabetic {
                    cls = props.isUppercase ? 2 : (props.isLowercase ? 1 : 4)
                } else if props.numericType != nil {
                    cls = 3
                } else if props.isWhitespace {
                    cls = 0
                } else {
                    cls = 0
                }
                let gc = props.generalCategory
                if props.isWhitespace || gc == .dashPunctuation || gc == .spaceSeparator
                    || gc == .connectorPunctuation || gc == .format {
                    // Unicode dashes (‑ – —), NBSP, ZWJ etc. behave like ASCII separators.
                    cls = 0
                    out.append(0x20)
                } else {
                    let folded = String(Character(scalar)).folding(
                        options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
                    for b in folded.utf8 { out.append(b < 0x80 ? lowerASCII(b) : b) }
                }
            }
            // The first non-separator byte always starts a word, even a symbol or emoji
            // ("#general", "(1) Inbox"), so exact/prefix matching works for such titles.
            if pos == 0 && out.count > base && out[base] != 0x20 { starts |= 1 }
            if cls != 0 && pos < 64 {
                let isStart: Bool
                switch (prev, cls) {
                case (0, _): isStart = true
                case (1, 2): isStart = true          // camelCase hump
                case (1, 3), (2, 3), (4, 3): isStart = true  // letter → digit
                case (3, 1), (3, 2), (3, 4): isStart = true  // digit → letter
                default: isStart = false
                }
                if isStart { starts |= 1 << UInt64(pos) }
            }
            prev = cls
        }
        return starts
    }

    @inline(__always) static func lowerASCII(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }

    /// Folds a query. Leading/trailing separators are dropped and runs of separators
    /// collapse to one space, so "  sys   set " behaves like "sys set".
    public static func query(_ s: String) -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity(s.utf8.count + 4)
        fold(s, into: &raw)
        var out: [UInt8] = []
        out.reserveCapacity(raw.count)
        var lastSpace = true
        for c in raw {
            if c == 0x20 {
                if !lastSpace { out.append(0x20) }
                lastSpace = true
            } else {
                out.append(c); lastSpace = false
            }
        }
        if out.last == 0x20 { out.removeLast() }
        return out
    }

    /// 64-bit "which characters occur" mask used to reject entries before matching.
    /// a–z → bits 0–25, 0–9 → bits 26–35, any other non-space byte → bits 36–63 by value.
    /// Spaces set nothing, so a query's spaces never reject anything.
    @inline(__always)
    public static func charBit(_ c: UInt8) -> UInt64 {
        if c >= 0x61 && c <= 0x7A { return 1 << UInt64(c &- 0x61) }
        if c >= 0x30 && c <= 0x39 { return 1 << UInt64(26 &+ (c &- 0x30)) }
        if c == 0x20 { return 0 }
        return 1 << UInt64(36 &+ (c % 28))
    }

    public static func charMask<C: Collection>(_ bytes: C) -> UInt64 where C.Element == UInt8 {
        var m: UInt64 = 0
        for c in bytes { m |= charBit(c) }
        return m
    }
}

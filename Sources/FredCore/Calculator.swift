import Foundation

/// Inline calculator for the launcher ("2+2" → 4).
///
/// A recursive-descent parser over the query's UTF-8 bytes that evaluates directly
/// (no AST, no allocation). Grammar, loosest binding first:
///
///     expr    := term (('+' | '-') term)*
///     term    := factor (('*' | '/' | '%' | '×' | '÷' | 'x') factor | implicit-mul factor)*
///     factor  := unary ('^' factor)?            -- right associative; also '**'
///     unary   := ('-' | '+') unary | postfix
///     postfix := primary ('!')*
///     primary := number | constant | func '(' expr ')' | func primary | '(' expr ')'
///
/// Accepts "1,000" (thousands separators are ignored).
/// `%` is modulo. A query only counts as math when it parses completely AND contains an
/// operator or function — a bare "42" or a word like "2fold" is not a calculation.
public enum Calculator {
    public struct Result: Equatable, Sendable {
        public let value: Double
        /// What is shown in the result row, with thousands grouping ("1,234.5").
        public let display: String
        /// What Enter copies: no grouping ("1234.5").
        public let copy: String
    }

    public static func evaluate(_ query: String) -> Result? {
        var q = query
        return q.withUTF8 { buf -> Result? in
            var p = Parser(buf)
            p.skipSpace()
            if p.peek == UInt8(ascii: "=") { p.i += 1; p.sawOperator = true } // "=expr" also works
            guard let v = p.parseExpr() else { return nil }
            p.skipSpace()
            guard p.i == buf.count, p.sawOperator, p.sawNumber, v.isFinite else { return nil }
            return Result(value: v, display: format(v, grouping: true), copy: format(v, grouping: false))
        }
    }

    // MARK: - Formatting

    /// Formats with up to 12 significant digits, which hides binary floating-point noise
    /// (0.1+0.2 → "0.3") while keeping integers exact up to 1e12.
    static func format(_ v: Double, grouping: Bool) -> String {
        if v == 0 { return "0" }
        let mag = abs(v)
        if mag >= 1e15 || mag < 1e-9 {
            // Scientific: 1.234e+20
            var s = String(format: "%.10g", v)
            if let e = s.firstIndex(of: "e") {
                var mant = String(s[..<e]); let exp = String(s[e...])
                if mant.contains(".") { while mant.hasSuffix("0") { mant.removeLast() }; if mant.hasSuffix(".") { mant.removeLast() } }
                s = mant + exp
            }
            return s
        }
        // Digits after the decimal point so total significant digits is 12.
        let intDigits = mag >= 1 ? Int(log10(mag).rounded(.down)) + 1 : 0
        let frac = max(0, min(12 - intDigits, 12))
        var s = String(format: "%.\(frac)f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        if s == "-0" { s = "0" }
        guard grouping else { return s }
        // Insert ',' every 3 integer digits.
        var neg = false
        if s.hasPrefix("-") { neg = true; s.removeFirst() }
        let parts = s.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let intPart = Array(parts[0])
        var grouped = ""
        grouped.reserveCapacity(intPart.count + intPart.count / 3 + 1)
        for (k, ch) in intPart.enumerated() {
            if k > 0 && (intPart.count - k) % 3 == 0 { grouped.append(",") }
            grouped.append(ch)
        }
        var out = neg ? "-" + grouped : grouped
        if parts.count == 2 { out += "." + parts[1] }
        return out
    }
}

private struct Parser {
    let b: UnsafeBufferPointer<UInt8>
    var i = 0
    var sawOperator = false
    var sawNumber = false
    var depth = 0

    init(_ b: UnsafeBufferPointer<UInt8>) { self.b = b }

    var peek: UInt8 { i < b.count ? b[i] : 0 }

    mutating func skipSpace() { while i < b.count && (b[i] == 0x20 || b[i] == 0x09) { i += 1 } }

    /// Matches a multi-byte UTF-8 operator such as "×" (C3 97) or "÷" (C3 B7).
    mutating func eat(_ bytes: (UInt8, UInt8)) -> Bool {
        if i + 1 < b.count && b[i] == bytes.0 && b[i + 1] == bytes.1 { i += 2; return true }
        return false
    }

    mutating func parseExpr() -> Double? {
        depth += 1; defer { depth -= 1 }
        guard depth < 64, var lhs = parseTerm() else { return nil }
        while true {
            skipSpace()
            let c = peek
            if c == UInt8(ascii: "+") { i += 1; sawOperator = true; guard let r = parseTerm() else { return nil }; lhs += r }
            else if c == UInt8(ascii: "-") { i += 1; sawOperator = true; guard let r = parseTerm() else { return nil }; lhs -= r }
            else if eat((0xE2, 0x88)) { // U+2212 MINUS SIGN is E2 88 92
                guard peek == 0x92 else { return nil }
                i += 1; sawOperator = true; guard let r = parseTerm() else { return nil }; lhs -= r
            }
            else { return lhs }
        }
    }

    mutating func parseTerm() -> Double? {
        guard var lhs = parseFactor() else { return nil }
        while true {
            skipSpace()
            let c = peek
            if c == UInt8(ascii: "*") && !(i + 1 < b.count && b[i + 1] == UInt8(ascii: "*")) {
                i += 1; sawOperator = true; guard let r = parseFactor() else { return nil }; lhs *= r
            } else if c == UInt8(ascii: "/") {
                i += 1; sawOperator = true; guard let r = parseFactor() else { return nil }; lhs /= r
            } else if c == UInt8(ascii: "%") {
                i += 1; sawOperator = true; guard let r = parseFactor() else { return nil }
                lhs = lhs.truncatingRemainder(dividingBy: r)
            } else if eat((0xC3, 0x97)) || eat((0xC3, 0xB7)) {
                let div = b[i - 1] == 0xB7
                sawOperator = true; guard let r = parseFactor() else { return nil }
                lhs = div ? lhs / r : lhs * r
            } else if c == UInt8(ascii: "x") && i + 1 < b.count && startsNumber(b[i + 1] == 0x20 ? afterSpaces(i + 1) : i + 1) {
                // "3x4" or "3 x 4" as multiplication (but not "exp" etc: only when a number follows)
                i += 1; sawOperator = true; guard let r = parseFactor() else { return nil }; lhs *= r
            } else if c == UInt8(ascii: "(") || isLetter(c) && c != UInt8(ascii: "x") {
                // Implicit multiplication: "2(3+4)", "2pi", "3 sqrt(4)"
                sawOperator = true
                guard let r = parseFactor() else { return nil }; lhs *= r
            } else {
                return lhs
            }
        }
    }

    func afterSpaces(_ j: Int) -> Int { var k = j; while k < b.count && b[k] == 0x20 { k += 1 }; return k }
    func startsNumber(_ j: Int) -> Bool {
        guard j < b.count else { return false }
        let c = b[j]
        return (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: ".") || c == UInt8(ascii: "(")
    }

    mutating func parseFactor() -> Double? {
        guard let base = parseUnary() else { return nil }
        skipSpace()
        if peek == UInt8(ascii: "^") {
            i += 1; sawOperator = true
            guard let e = parseFactor() else { return nil }
            return pow(base, e)
        }
        if peek == UInt8(ascii: "*") && i + 1 < b.count && b[i + 1] == UInt8(ascii: "*") {
            i += 2; sawOperator = true
            guard let e = parseFactor() else { return nil }
            return pow(base, e)
        }
        return base
    }

    mutating func parseUnary() -> Double? {
        skipSpace()
        if peek == UInt8(ascii: "-") { i += 1; guard let v = parseUnary() else { return nil }; return -v }
        if peek == UInt8(ascii: "+") { i += 1; return parseUnary() }
        guard var v = parsePrimary() else { return nil }
        while peek == UInt8(ascii: "!") {
            i += 1; sawOperator = true
            guard v >= 0, v <= 170, v == v.rounded() else { return nil }
            var f = 1.0; var k = 2.0; while k <= v { f *= k; k += 1 }; v = f
        }
        return v
    }

    mutating func parsePrimary() -> Double? {
        skipSpace()
        let c = peek
        if c == UInt8(ascii: "(") {
            i += 1
            guard let v = parseExpr() else { return nil }
            skipSpace()
            guard peek == UInt8(ascii: ")") else { return nil }
            i += 1
            return v
        }
        if (c >= 0x30 && c <= 0x39) || c == UInt8(ascii: ".") { return parseNumber() }
        if isLetter(c) { return parseIdentifier() }
        return nil
    }

    func isLetter(_ c: UInt8) -> Bool { (c | 0x20) >= 0x61 && (c | 0x20) <= 0x7A }

    /// Number with optional thousands separators ("1,000,000"), fraction and exponent.
    /// The digits are copied into a small stack buffer and handed to strtod.
    mutating func parseNumber() -> Double? {
        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: 64) { tmp -> Double? in
            var n = 0
            func put(_ c: UInt8) -> Bool { guard n < 63 else { return false }; tmp[n] = CChar(bitPattern: c); n += 1; return true }
            var any = false
            while i < b.count {
                let c = b[i]
                if c >= 0x30 && c <= 0x39 { guard put(c) else { return nil }; any = true; i += 1 }
                else if c == UInt8(ascii: ","), any, isDigits(i + 1, 3),
                        !(i + 4 < b.count && b[i + 4] >= 0x30 && b[i + 4] <= 0x39) {
                    i += 1 // grouping separator: exactly three digits must follow
                } else { break }
            }
            if peek == UInt8(ascii: ".") {
                guard put(b[i]) else { return nil }
                i += 1
                while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { guard put(b[i]) else { return nil }; any = true; i += 1 }
            }
            guard any else { return nil }
            // Exponent: 1e10, 2.5E-3 — only when digits follow, so "2e" stays 2·e.
            if (peek | 0x20) == UInt8(ascii: "e") {
                var j = i + 1
                if j < b.count && (b[j] == UInt8(ascii: "-") || b[j] == UInt8(ascii: "+")) { j += 1 }
                if j < b.count && b[j] >= 0x30 && b[j] <= 0x39 {
                    while i < j { guard put(b[i]) else { return nil }; i += 1 }
                    while i < b.count, b[i] >= 0x30 && b[i] <= 0x39 { guard put(b[i]) else { return nil }; i += 1 }
                }
            }
            tmp[n] = 0
            sawNumber = true
            return strtod(tmp.baseAddress!, nil)
        }
    }

    func isDigits(_ from: Int, _ n: Int) -> Bool {
        guard from + n <= b.count else { return false }
        for k in from..<(from + n) where !(b[k] >= 0x30 && b[k] <= 0x39) { return false }
        return true
    }

    mutating func parseIdentifier() -> Double? {
        let start = i
        while i < b.count, isLetter(b[i]) || (b[i] >= 0x30 && b[i] <= 0x39 && i > start) { i += 1 }
        var name = 0 as UInt64  // pack up to 8 lowercase letters for a branch-free compare
        let len = i - start
        guard len <= 8 else { return nil }
        for k in start..<i { name = name << 8 | UInt64(b[k] | 0x20) }
        func id(_ s: StaticString) -> UInt64 {
            var v: UInt64 = 0
            s.withUTF8Buffer { for c in $0 { v = v << 8 | UInt64(c) } }
            return v
        }
        switch name {
        case id("pi"): sawNumber = true; return Double.pi
        case id("e"): sawNumber = true; return M_E
        case id("tau"): sawNumber = true; return 2 * Double.pi
        default: break
        }
        let fn: ((Double) -> Double)?
        switch name {
        case id("sqrt"): fn = { $0.squareRoot() }
        case id("cbrt"): fn = { cbrt($0) }
        case id("sin"): fn = { sin($0) }
        case id("cos"): fn = { cos($0) }
        case id("tan"): fn = { tan($0) }
        case id("asin"): fn = { asin($0) }
        case id("acos"): fn = { acos($0) }
        case id("atan"): fn = { atan($0) }
        case id("sinh"): fn = { sinh($0) }
        case id("cosh"): fn = { cosh($0) }
        case id("tanh"): fn = { tanh($0) }
        case id("log"), id("log10"): fn = { log10($0) }
        case id("log2"): fn = { log2($0) }
        case id("ln"): fn = { Foundation.log($0) }
        case id("exp"): fn = { Foundation.exp($0) }
        case id("abs"): fn = { abs($0) }
        case id("round"): fn = { $0.rounded() }
        case id("floor"): fn = { $0.rounded(.down) }
        case id("ceil"): fn = { $0.rounded(.up) }
        case id("trunc"): fn = { $0.rounded(.towardZero) }
        default: fn = nil
        }
        guard let f = fn else { return nil }
        sawOperator = true
        skipSpace()
        guard let arg = peek == UInt8(ascii: "(") ? parsePrimary() : parseUnary() else { return nil }
        return f(arg)
    }
}

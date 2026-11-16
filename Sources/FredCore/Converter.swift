import Foundation

/// A one-row instant answer shown above search results (calculator, conversions, times).
public struct InstantAnswer: Equatable, Sendable {
    public enum Kind: Sendable { case math, unit, time }
    public let kind: Kind
    /// Row text, e.g. "3.10686 mi" or "6:00 AM JST".
    public let title: String
    /// Right-aligned context, e.g. "5 km" or "Tokyo · Mon (+1 day)".
    public let detail: String?
    /// What Enter copies.
    public let copy: String

    public init(kind: Kind, title: String, detail: String?, copy: String) {
        self.kind = kind; self.title = title; self.detail = detail; self.copy = copy
    }
}

/// Offline unit, data-size and time-zone conversion for queries like
/// "5 km in mi", "180lb", "1.5 GiB to MB", "100 Mbps in MB/s", "90 min",
/// "3pm PST in Tokyo", "now in London", "tokyo time".
///
/// Static tables plus the OS time-zone database; no network. Runs on every keystroke the
/// calculator declines, so (bench: `make bench`):
///   - the gate is one allocation-free pass over the bytes — a query needs a digit, or
///     "time" anywhere, or to start with now/noon/midnight; everything else exits there;
///   - parsing works on UTF-8 bytes (units and zone names are ASCII apart from caseless
///     symbols like ° µ ², so ASCII folding is enough);
///   - times are offset arithmetic (`secondsFromGMT`), never DateFormatter/Calendar.
public enum Converter {
    public static func evaluate(_ query: String, now: Date? = nil, zone: TimeZone? = nil) -> InstantAnswer? {
        var n = 0, digit = false, timey = false, leading = true
        var last4: UInt32 = 0                    // last 4 bytes, ASCII-lowercased
        var head: UInt64 = 0                     // first 8 bytes after leading spaces
        for c in query.utf8 {
            if leading && c == 0x20 { continue }
            leading = false
            if n == 80 { return nil }
            let lc = c &- 0x41 < 26 ? c | 0x20 : c
            if c &- 0x30 < 10 { digit = true }
            last4 = last4 << 8 | UInt32(lc)
            if last4 == 0x7469_6D65 { timey = true }          // "time"
            if n < 8 { head |= UInt64(lc) << (8 * UInt64(n)) }
            n += 1
        }
        guard n >= 2 else { return nil }
        if !digit && !timey {
            timey = startsWith(head, "now") || startsWith(head, "noon") || startsWith(head, "midnight")
            guard timey else { return nil }
        }
        let t = Text(query)
        if let a = TimeConversion.evaluate(t, now: now, local: zone) { return a }
        return digit ? UnitConversion.evaluate(t) : nil
    }

    /// Builds the lookup tables (and the OS time-zone caches) ahead of the first keystroke.
    /// Safe from any thread; call once at launch off the main thread.
    public static func warm() {
        _ = UnitConversion.byName.count + UnitConversion.bySymbol.count + TimeConversion.cities.count
        _ = evaluate("3pm pst in tokyo")
        _ = evaluate("5 km in mi")
    }

    private static func startsWith(_ head: UInt64, _ p: StaticString) -> Bool {
        var v: UInt64 = 0, mask: UInt64 = 0
        let b = UnsafeBufferPointer(start: p.utf8Start, count: p.utf8CodeUnitCount)
        for (i, c) in b.enumerated() { v |= UInt64(c) << (8 * UInt64(i)); mask |= 0xFF << (8 * UInt64(i)) }
        return head & mask == v
    }

    static let connectors: [[UInt8]] = [" to ", " in ", " into ", " as ", " -> ", "->", " => ", " = "].map { Array($0.utf8) }

    /// Splits "left <connector> right" at the LAST connector (so "1 in in cm" works).
    static func split(_ t: Text) -> (Text, Text)? {
        let l = t.l
        var i = l.count - 2
        while i > 0 {
            for c in connectors where i + c.count <= l.count && l[i..<(i + c.count)].elementsEqual(c) {
                let left = t[0..<i], right = t[(i + c.count)..<l.count]
                return left.isEmpty || right.isEmpty ? nil : (left, right)
            }
            i -= 1
        }
        return nil
    }

    /// Up to `sig` significant digits, trailing zeros trimmed, optional "," grouping.
    /// Integer digit generation; String(format:) only for very large/small magnitudes.
    static func format(_ v: Double, sig: Int = 6, grouping: Bool) -> String {
        if v == 0 { return "0" }
        let mag = abs(v)
        if !(mag < 1e15) || mag < 1e-6 { return String(format: "%.\(sig)g", v) }
        let intDigits = mag >= 1 ? Int(log10(mag).rounded(.down)) + 1 : 0
        let frac = max(0, sig - intDigits)
        var scale: UInt64 = 1
        for _ in 0..<frac { scale *= 10 }
        let n = UInt64((mag * Double(scale)).rounded())
        var ip = n / scale
        let fp = n % scale
        var out: [UInt8] = []
        out.reserveCapacity(32)
        if v < 0 && n != 0 { out.append(0x2D) }
        var rev: [UInt8] = []
        repeat { rev.append(UInt8(ip % 10) + 0x30); ip /= 10 } while ip > 0
        for k in stride(from: rev.count - 1, through: 0, by: -1) {
            out.append(rev[k])
            if grouping && k > 0 && k % 3 == 0 { out.append(0x2C) }
        }
        if fp > 0 {
            var f = [UInt8](repeating: 0x30, count: frac)
            var x = fp, k = frac - 1
            while x > 0 { f[k] = UInt8(x % 10) + 0x30; x /= 10; k -= 1 }
            while f.last == 0x30 { f.removeLast() }
            out.append(0x2E)
            out += f
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// A query (or part of one) as trimmed UTF-8 bytes plus an ASCII-lowercased copy.
struct Text {
    let b: [UInt8]
    let l: [UInt8]

    init(_ s: String) { self.init(Array(s.utf8)[...]) }

    init(_ s: ArraySlice<UInt8>) {
        var lo = s.startIndex, hi = s.endIndex
        while lo < hi, s[lo] == 0x20 { lo += 1 }
        while hi > lo, s[hi - 1] == 0x20 { hi -= 1 }
        b = Array(s[lo..<hi])
        l = b.map { $0 &- 0x41 < 26 ? $0 | 0x20 : $0 }
    }

    var count: Int { b.count }
    var isEmpty: Bool { b.isEmpty }
    var string: String { String(decoding: b, as: UTF8.self) }
    var lower: String { String(decoding: l, as: UTF8.self) }
    subscript(r: Range<Int>) -> Text { Text(b[r]) }
    func hasPrefix(_ p: String) -> Bool { l.starts(with: p.utf8) }
    func hasSuffix(_ p: String) -> Bool { l.count >= p.utf8.count && l[(l.count - p.utf8.count)...].elementsEqual(p.utf8) }
    func equals(_ p: String) -> Bool { l.elementsEqual(p.utf8) }
}

@inline(__always) func isDigit(_ c: UInt8) -> Bool { c &- 0x30 < 10 }

// MARK: - Units

enum UnitConversion {
    enum Dim: UInt8 { case length, mass, volume, temperature, speed, area, duration, data, dataRate, frequency }

    struct Unit {
        let symbol: String       // display
        let dim: Dim
        let factor: Double       // value × factor = base unit (temperature: see `toBase`)
        let offset: Double       // temperature only
        let names: [String]      // lowercase aliases
        let target: String?      // default conversion target symbol
    }

    // Base units: m, kg, L, K(handled), m/s, m², s, byte, bit/s, Hz.
    static let table: [Unit] = [
        // length
        .init(symbol: "mm", dim: .length, factor: 0.001, offset: 0, names: ["mm", "millimeter", "millimeters", "millimetre", "millimetres"], target: "in"),
        .init(symbol: "cm", dim: .length, factor: 0.01, offset: 0, names: ["cm", "centimeter", "centimeters", "centimetre", "centimetres"], target: "in"),
        .init(symbol: "m", dim: .length, factor: 1, offset: 0, names: ["m", "meter", "meters", "metre", "metres"], target: "ft"),
        .init(symbol: "km", dim: .length, factor: 1000, offset: 0, names: ["km", "kilometer", "kilometers", "kilometre", "kilometres", "kms"], target: "mi"),
        .init(symbol: "in", dim: .length, factor: 0.0254, offset: 0, names: ["in", "inch", "inches", "\""], target: "cm"),
        .init(symbol: "ft", dim: .length, factor: 0.3048, offset: 0, names: ["ft", "foot", "feet", "'"], target: "m"),
        .init(symbol: "yd", dim: .length, factor: 0.9144, offset: 0, names: ["yd", "yds", "yard", "yards"], target: "m"),
        .init(symbol: "mi", dim: .length, factor: 1609.344, offset: 0, names: ["mi", "mile", "miles"], target: "km"),
        .init(symbol: "nmi", dim: .length, factor: 1852, offset: 0, names: ["nmi", "nautical mile", "nautical miles"], target: "km"),
        // mass
        .init(symbol: "mg", dim: .mass, factor: 1e-6, offset: 0, names: ["mg", "milligram", "milligrams"], target: "g"),
        .init(symbol: "g", dim: .mass, factor: 0.001, offset: 0, names: ["g", "gram", "grams", "gr"], target: "oz"),
        .init(symbol: "kg", dim: .mass, factor: 1, offset: 0, names: ["kg", "kgs", "kilo", "kilos", "kilogram", "kilograms"], target: "lb"),
        .init(symbol: "t", dim: .mass, factor: 1000, offset: 0, names: ["tonne", "tonnes", "metric ton", "metric tons"], target: "lb"),
        .init(symbol: "oz", dim: .mass, factor: 0.028349523125, offset: 0, names: ["oz", "ounce", "ounces"], target: "g"),
        .init(symbol: "lb", dim: .mass, factor: 0.45359237, offset: 0, names: ["lb", "lbs", "pound", "pounds"], target: "kg"),
        .init(symbol: "st", dim: .mass, factor: 6.35029318, offset: 0, names: ["st", "stone", "stones"], target: "kg"),
        // volume (US customary)
        .init(symbol: "ml", dim: .volume, factor: 0.001, offset: 0, names: ["ml", "milliliter", "milliliters", "millilitre", "millilitres"], target: "fl oz"),
        .init(symbol: "L", dim: .volume, factor: 1, offset: 0, names: ["l", "liter", "liters", "litre", "litres"], target: "gal"),
        .init(symbol: "tsp", dim: .volume, factor: 0.00492892159375, offset: 0, names: ["tsp", "teaspoon", "teaspoons"], target: "ml"),
        .init(symbol: "tbsp", dim: .volume, factor: 0.01478676478125, offset: 0, names: ["tbsp", "tablespoon", "tablespoons"], target: "ml"),
        .init(symbol: "fl oz", dim: .volume, factor: 0.0295735295625, offset: 0, names: ["fl oz", "floz", "fluid ounce", "fluid ounces"], target: "ml"),
        .init(symbol: "cup", dim: .volume, factor: 0.2365882365, offset: 0, names: ["cup", "cups"], target: "ml"),
        .init(symbol: "pt", dim: .volume, factor: 0.473176473, offset: 0, names: ["pint", "pints"], target: "L"),
        .init(symbol: "qt", dim: .volume, factor: 0.946352946, offset: 0, names: ["qt", "quart", "quarts"], target: "L"),
        .init(symbol: "gal", dim: .volume, factor: 3.785411784, offset: 0, names: ["gal", "gallon", "gallons"], target: "L"),
        // temperature (factor/offset: K = v × factor + offset)
        .init(symbol: "°C", dim: .temperature, factor: 1, offset: 273.15, names: ["c", "°c", "ºc", "celsius", "centigrade"], target: "°F"),
        .init(symbol: "°F", dim: .temperature, factor: 5.0 / 9.0, offset: 255.3722222222222, names: ["f", "°f", "ºf", "fahrenheit"], target: "°C"),
        .init(symbol: "K", dim: .temperature, factor: 1, offset: 0, names: ["k", "kelvin"], target: "°C"),
        // speed
        .init(symbol: "m/s", dim: .speed, factor: 1, offset: 0, names: ["m/s", "mps", "meters per second"], target: "km/h"),
        .init(symbol: "km/h", dim: .speed, factor: 1 / 3.6, offset: 0, names: ["km/h", "kmh", "kph", "kmph", "kilometers per hour"], target: "mph"),
        .init(symbol: "mph", dim: .speed, factor: 0.44704, offset: 0, names: ["mph", "miles per hour"], target: "km/h"),
        .init(symbol: "kn", dim: .speed, factor: 0.514444444, offset: 0, names: ["kn", "kt", "knot", "knots"], target: "km/h"),
        // area
        .init(symbol: "m²", dim: .area, factor: 1, offset: 0, names: ["m2", "m²", "sqm", "sq m", "square meter", "square meters"], target: "ft²"),
        .init(symbol: "km²", dim: .area, factor: 1e6, offset: 0, names: ["km2", "km²", "sq km", "square kilometer", "square kilometers"], target: "mi²"),
        .init(symbol: "ft²", dim: .area, factor: 0.09290304, offset: 0, names: ["ft2", "ft²", "sqft", "sq ft", "square foot", "square feet"], target: "m²"),
        .init(symbol: "mi²", dim: .area, factor: 2589988.110336, offset: 0, names: ["mi2", "mi²", "sq mi", "square mile", "square miles"], target: "km²"),
        .init(symbol: "acre", dim: .area, factor: 4046.8564224, offset: 0, names: ["acre", "acres", "ac"], target: "m²"),
        .init(symbol: "ha", dim: .area, factor: 10000, offset: 0, names: ["ha", "hectare", "hectares"], target: "acre"),
        // duration
        .init(symbol: "ns", dim: .duration, factor: 1e-9, offset: 0, names: ["ns", "nanosecond", "nanoseconds"], target: nil),
        .init(symbol: "µs", dim: .duration, factor: 1e-6, offset: 0, names: ["µs", "us", "microsecond", "microseconds"], target: nil),
        .init(symbol: "ms", dim: .duration, factor: 0.001, offset: 0, names: ["ms", "millisecond", "milliseconds"], target: nil),
        .init(symbol: "s", dim: .duration, factor: 1, offset: 0, names: ["s", "sec", "secs", "second", "seconds"], target: nil),
        .init(symbol: "min", dim: .duration, factor: 60, offset: 0, names: ["min", "mins", "minute", "minutes"], target: nil),
        .init(symbol: "h", dim: .duration, factor: 3600, offset: 0, names: ["h", "hr", "hrs", "hour", "hours"], target: nil),
        .init(symbol: "d", dim: .duration, factor: 86400, offset: 0, names: ["d", "day", "days"], target: nil),
        .init(symbol: "wk", dim: .duration, factor: 604800, offset: 0, names: ["wk", "wks", "week", "weeks"], target: nil),
        .init(symbol: "mo", dim: .duration, factor: 2629746, offset: 0, names: ["mo", "month", "months"], target: nil),
        .init(symbol: "yr", dim: .duration, factor: 31556952, offset: 0, names: ["yr", "yrs", "year", "years"], target: nil),
        // data size (decimal SI and binary IEC); base = byte
        .init(symbol: "bit", dim: .data, factor: 0.125, offset: 0, names: ["bit", "bits"], target: "B"),
        .init(symbol: "B", dim: .data, factor: 1, offset: 0, names: ["b", "byte", "bytes"], target: nil),
        .init(symbol: "KB", dim: .data, factor: 1e3, offset: 0, names: ["kb", "kilobyte", "kilobytes"], target: "KiB"),
        .init(symbol: "MB", dim: .data, factor: 1e6, offset: 0, names: ["mb", "megabyte", "megabytes"], target: "MiB"),
        .init(symbol: "GB", dim: .data, factor: 1e9, offset: 0, names: ["gb", "gigabyte", "gigabytes"], target: "GiB"),
        .init(symbol: "TB", dim: .data, factor: 1e12, offset: 0, names: ["tb", "terabyte", "terabytes"], target: "TiB"),
        .init(symbol: "PB", dim: .data, factor: 1e15, offset: 0, names: ["pb", "petabyte", "petabytes"], target: "PiB"),
        .init(symbol: "KiB", dim: .data, factor: 1024, offset: 0, names: ["kib", "kibibyte", "kibibytes"], target: "KB"),
        .init(symbol: "MiB", dim: .data, factor: 1_048_576, offset: 0, names: ["mib", "mebibyte", "mebibytes"], target: "MB"),
        .init(symbol: "GiB", dim: .data, factor: 1_073_741_824, offset: 0, names: ["gib", "gibibyte", "gibibytes"], target: "GB"),
        .init(symbol: "TiB", dim: .data, factor: 1_099_511_627_776, offset: 0, names: ["tib", "tebibyte", "tebibytes"], target: "TB"),
        .init(symbol: "PiB", dim: .data, factor: 1_125_899_906_842_624, offset: 0, names: ["pib", "pebibyte", "pebibytes"], target: "PB"),
        .init(symbol: "Kbit", dim: .data, factor: 125, offset: 0, names: ["kbit", "kbits", "kilobit", "kilobits"], target: "KB"),
        .init(symbol: "Mbit", dim: .data, factor: 125_000, offset: 0, names: ["mbit", "mbits", "megabit", "megabits"], target: "MB"),
        .init(symbol: "Gbit", dim: .data, factor: 125_000_000, offset: 0, names: ["gbit", "gbits", "gigabit", "gigabits"], target: "GB"),
        .init(symbol: "Tbit", dim: .data, factor: 125_000_000_000, offset: 0, names: ["tbit", "tbits", "terabit", "terabits"], target: "TB"),
        // data rate; base = bit/s
        .init(symbol: "bps", dim: .dataRate, factor: 1, offset: 0, names: ["bps", "bit/s"], target: nil),
        .init(symbol: "Kbps", dim: .dataRate, factor: 1e3, offset: 0, names: ["kbps", "kbit/s"], target: "KB/s"),
        .init(symbol: "Mbps", dim: .dataRate, factor: 1e6, offset: 0, names: ["mbps", "mbit/s"], target: "MB/s"),
        .init(symbol: "Gbps", dim: .dataRate, factor: 1e9, offset: 0, names: ["gbps", "gbit/s"], target: "MB/s"),
        .init(symbol: "KB/s", dim: .dataRate, factor: 8e3, offset: 0, names: ["kb/s", "kbytes/s"], target: "Kbps"),
        .init(symbol: "MB/s", dim: .dataRate, factor: 8e6, offset: 0, names: ["mb/s", "mbytes/s", "mbps bytes"], target: "Mbps"),
        .init(symbol: "GB/s", dim: .dataRate, factor: 8e9, offset: 0, names: ["gb/s"], target: "Gbps"),
        .init(symbol: "MiB/s", dim: .dataRate, factor: 8_388_608, offset: 0, names: ["mib/s"], target: "Mbps"),
        // frequency
        .init(symbol: "Hz", dim: .frequency, factor: 1, offset: 0, names: ["hz", "hertz"], target: nil),
        .init(symbol: "kHz", dim: .frequency, factor: 1e3, offset: 0, names: ["khz"], target: "Hz"),
        .init(symbol: "MHz", dim: .frequency, factor: 1e6, offset: 0, names: ["mhz"], target: "GHz"),
        .init(symbol: "GHz", dim: .frequency, factor: 1e9, offset: 0, names: ["ghz"], target: "MHz"),
    ]

    /// Case-sensitive spellings that differ from their lowercase meaning: "Mb" is a
    /// megabit, "MB"/"mb" a megabyte; "Mb/s" is megabits per second.
    static let caseSensitive: [String: String] = [
        "Kb": "Kbit", "Mb": "Mbit", "Gb": "Gbit", "Tb": "Tbit",
        "Kb/s": "Kbps", "Mb/s": "Mbps", "Gb/s": "Gbps", "MB/s": "MB/s", "KB/s": "KB/s", "GB/s": "GB/s",
    ]

    static let byName: [String: Int] = {
        var d: [String: Int] = [:]
        for (i, u) in table.enumerated() {
            d[u.symbol.lowercased()] = d[u.symbol.lowercased()] ?? i
            for n in u.names { d[n] = i }
        }
        return d
    }()
    static let bySymbol: [String: Int] = {
        var d: [String: Int] = [:]
        for (i, u) in table.enumerated() { d[u.symbol] = i }
        return d
    }()

    static func unit(_ t: Text) -> Int? {
        guard !t.isEmpty, t.count <= 24 else { return nil }
        if let sym = caseSensitive[t.string] { return bySymbol[sym] }
        if let i = byName[t.lower] { return i }
        if t.l.starts(with: [0xC2, 0xB0]) { return byName[String(decoding: t.l.dropFirst(2), as: UTF8.self)] }   // "°"
        return nil
    }

    static func evaluate(_ t: Text) -> InstantAnswer? {
        let left: Text, right: Text?
        if let (l, r) = Converter.split(t) { left = l; right = r } else { left = t; right = nil }
        guard let (v, from, at) = quantity(left) else { return nil }
        let src = table[from]
        // "4k", "3d", "2m": a number glued to a one-letter unit is more often the start of
        // a search ("4K…", "3D…") than a conversion. "3 d" and "2m in ft" still convert,
        // and so do "72F" / "20c".
        if right == nil, left.count - at == 1, isDigit(left.l[at - 1]), src.symbol != "°F", src.symbol != "°C" { return nil }
        var to: Int
        if let r = right {
            guard let u = unit(r) else { return nil }
            to = u
        } else if src.dim == .duration {
            to = bestDuration(v * src.factor, excluding: from)
        } else if src.dim == .data && src.target == nil {
            to = bestBytes(v * src.factor)
        } else if src.dim == .dataRate && src.target == nil {
            to = bySymbol["Mbps"]!
        } else if let sym = src.target, let u = bySymbol[sym] {
            to = u
        } else {
            return nil
        }
        let dst = table[to]
        guard dst.dim == src.dim, to != from || right != nil else { return nil }
        let out: Double
        if src.dim == .temperature {
            out = (v * src.factor + src.offset - dst.offset) / dst.factor
        } else {
            out = v * src.factor / dst.factor
        }
        guard out.isFinite else { return nil }
        return InstantAnswer(kind: .unit, title: Converter.format(out, grouping: true) + " " + dst.symbol,
                             detail: Converter.format(v, grouping: true) + " " + src.symbol,
                             copy: Converter.format(out, grouping: false))
    }

    /// "5km", "5 km", "1,000 ft", "2*1024 MiB", "-40 °F". The unit starts where a
    /// number-ish run ends and something else begins; the leftmost such point that
    /// parses wins (= the longest unit suffix).
    static func quantity(_ t: Text) -> (value: Double, unit: Int, unitStart: Int)? {
        let c = t.l
        guard c.count >= 2 else { return nil }
        for i in 1..<c.count {
            let p = c[i - 1], x = c[i]
            guard isDigit(p) || p == 0x20 || p == 0x29 || p == 0x2E else { continue }       // digit ␠ ) .
            guard !(isDigit(x) || x == 0x20 || x == 0x2E || x == 0x2C || numberSymbols.contains(x)) else { continue }
            guard let u = unit(t[i..<c.count]), let v = number(t[0..<i]) else { continue }
            return (v, u, i)
        }
        return nil
    }

    static let numberSymbols: [UInt8] = Array("+-*/^%()".utf8)

    static func number(_ t: Text) -> Double? {
        guard !t.isEmpty else { return nil }
        // Commas only as thousands separators: "1,5" is not 15.
        let plain: String? = !t.b.contains(0x2C) ? t.string
            : grouped(t.b) ? String(decoding: t.b.filter { $0 != 0x2C }, as: UTF8.self) : nil
        if let plain {
            if let v = Double(plain) { return v }
            if plain.hasPrefix("+"), let v = Double(plain.dropFirst()) { return v }
        }
        return Calculator.evaluate(t.string)?.value
    }

    /// "1,000,000.5", "-12,345": commas only between groups of exactly three digits.
    static func grouped(_ b: [UInt8]) -> Bool {
        var i = 0, run = 0, sawComma = false
        if i < b.count && (b[i] == 0x2D || b[i] == 0x2B) { i += 1 }   // - +
        while i < b.count && b[i] != 0x2E {                          // up to "."
            if isDigit(b[i]) { run += 1 }
            else if b[i] == 0x2C {
                if run == 0 || run > 3 || (sawComma && run != 3) { return false }
                sawComma = true; run = 0
            } else { return false }
            i += 1
        }
        return !sawComma || run == 3
    }

    /// The largest duration unit (s…yr) in which the value is ≥ 1.
    static func bestDuration(_ seconds: Double, excluding: Int) -> Int {
        for sym in ["yr", "mo", "wk", "d", "h", "min", "s", "ms", "µs", "ns"] {
            let i = bySymbol[sym]!
            if i != excluding && abs(seconds) / table[i].factor >= 1 { return i }
        }
        return bySymbol["s"]!
    }

    static func bestBytes(_ bytes: Double) -> Int {
        for sym in ["PiB", "TiB", "GiB", "MiB", "KiB"] where abs(bytes) >= table[bySymbol[sym]!].factor {
            return bySymbol[sym]!
        }
        return bySymbol["B"]!
    }
}

// MARK: - Time zones

enum TimeConversion {
    /// Extra names for zones; city names come from the tz database itself.
    static let aliases: [String: String] = [
        "pt": "America/Los_Angeles", "pst": "America/Los_Angeles", "pdt": "America/Los_Angeles",
        "et": "America/New_York", "est": "America/New_York", "edt": "America/New_York",
        "ct": "America/Chicago", "cst": "America/Chicago", "cdt": "America/Chicago",
        "mt": "America/Denver", "mst": "America/Denver", "mdt": "America/Denver",
        "utc": "UTC", "gmt": "GMT", "z": "UTC", "zulu": "UTC",
        "nyc": "America/New_York", "ny": "America/New_York", "new york city": "America/New_York",
        "boston": "America/New_York", "dc": "America/New_York", "washington": "America/New_York",
        "atlanta": "America/New_York", "miami": "America/New_York",
        "sf": "America/Los_Angeles", "san francisco": "America/Los_Angeles", "la": "America/Los_Angeles",
        "seattle": "America/Los_Angeles", "portland": "America/Los_Angeles", "san diego": "America/Los_Angeles",
        "austin": "America/Chicago", "dallas": "America/Chicago", "houston": "America/Chicago",
        "hawaii": "Pacific/Honolulu", "india": "Asia/Kolkata", "bangalore": "Asia/Kolkata", "bengaluru": "Asia/Kolkata",
        "mumbai": "Asia/Kolkata", "delhi": "Asia/Kolkata", "new delhi": "Asia/Kolkata", "ist": "Asia/Kolkata",
        "beijing": "Asia/Shanghai", "china": "Asia/Shanghai", "japan": "Asia/Tokyo", "jst": "Asia/Tokyo",
        "korea": "Asia/Seoul", "uk": "Europe/London", "england": "Europe/London", "bst": "Europe/London",
        "cet": "Europe/Paris", "cest": "Europe/Paris", "germany": "Europe/Berlin", "france": "Europe/Paris",
        "aest": "Australia/Sydney", "aedt": "Australia/Sydney",
        "local": "", "here": "",
    ]

    /// "tokyo" → Asia/Tokyo, "new york" → America/New_York, … from the tz database.
    static let cities: [String: String] = {
        var d: [String: String] = [:]
        for id in TimeZone.knownTimeZoneIdentifiers {
            guard let last = id.split(separator: "/").last else { continue }
            d[last.replacingOccurrences(of: "_", with: " ").lowercased()] = id
        }
        return d
    }()

    static func zone(_ t: Text, local: TimeZone?) -> TimeZone? {
        guard !t.isEmpty, t.count <= 40 else { return nil }
        let key = String(decoding: t.l.map { $0 == 0x5F ? 0x20 : $0 }, as: UTF8.self)
        if let id = aliases[key] { return id.isEmpty ? (local ?? .current) : TimeZone(identifier: id) }
        if let id = cities[key] { return TimeZone(identifier: id) }
        if t.count <= 5, t.l.allSatisfy({ $0 &- 0x61 < 26 }) {
            return TimeZone(abbreviation: String(decoding: t.l.map { $0 & 0xDF }, as: UTF8.self))
        }
        if t.b.contains(0x2F) { return TimeZone(identifier: t.string) }   // "Europe/Paris"
        return nil
    }

    /// Parses a clock time at the start of `t` ("3pm", "3:30 pm", "15:45", "noon").
    /// Returns (hour, minute, rest).
    static func clock(_ t: Text) -> (Int, Int, Text)? {
        if t.hasPrefix("noon") { return (12, 0, t[4..<t.count]) }
        if t.hasPrefix("midnight") { return (0, 0, t[8..<t.count]) }
        let c = t.l
        var i = 0, h = 0, m = 0, digits = 0
        while i < c.count, digits < 2, isDigit(c[i]) { h = h * 10 + Int(c[i] - 0x30); i += 1; digits += 1 }
        guard digits > 0 else { return nil }
        var hasColon = false
        if i < c.count, c[i] == 0x3A {
            hasColon = true
            i += 1
            var md = 0
            while i < c.count, md < 2, isDigit(c[i]) { m = m * 10 + Int(c[i] - 0x30); i += 1; md += 1 }
            guard md == 2 else { return nil }
        }
        let afterNumber = i
        while i < c.count, c[i] == 0x20 { i += 1 }
        var meridiem: UInt8 = 0
        if i < c.count, c[i] == 0x61 || c[i] == 0x70 {                      // a / p
            let next = i + 1 < c.count ? c[i + 1] : 0x20
            let after = i + 2 < c.count ? c[i + 2] : 0x20
            // "am"/"pm"/"a"/"p" — but not the start of a word like "pst" or "amsterdam".
            if (next == 0x6D && after == 0x20) || next == 0x20 {
                meridiem = c[i]
                i += next == 0x6D ? 2 : 1
            }
        }
        if meridiem == 0 { i = afterNumber }
        guard hasColon || meridiem != 0 else { return nil }   // bare "3" isn't a time
        if meridiem != 0 {
            guard h >= 1 && h <= 12 else { return nil }
            if meridiem == 0x61 { h = h == 12 ? 0 : h } else { h = h == 12 ? 12 : h + 12 }
        }
        guard h < 24, m < 60 else { return nil }
        if i < c.count, c[i] != 0x20 { return nil }
        return (h, m, t[i..<c.count])
    }

    static let weekdays = ["Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed"]   // day 0 = 1970-01-01

    static func evaluate(_ t: Text, now: Date?, local: TimeZone?) -> InstantAnswer? {
        var dst: TimeZone, src: TimeZone? = nil
        var hm: (Int, Int)?
        if let (l, r) = Converter.split(t) {
            // Cheap left-side checks first: most "x in y" queries are unit conversions.
            if !(l.equals("now") || l.equals("time") || l.equals("the time")) {
                guard let (h, m, rest) = clock(l) else { return nil }
                hm = (h, m)
                if !rest.isEmpty { guard let z = zone(rest, local: local) else { return nil }; src = z }
            }
            guard let d = zone(r, local: local) else { return nil }
            dst = d
        } else if t.hasSuffix(" time"), let d = zone(t[0..<(t.count - 5)], local: local) {
            dst = d
        } else if t.hasPrefix("time "), let d = zone(t[5..<t.count], local: local) {
            dst = d
        } else {
            return nil
        }
        let from = src ?? local ?? .current
        let nowS = (now ?? Date()).timeIntervalSince1970
        var utc = nowS
        if let (h, m) = hm {
            // h:m on today's date in the source zone; the offset is re-read at the target
            // instant so DST changes later today are honoured.
            let off0 = Double(from.secondsFromGMT(for: Date(timeIntervalSince1970: nowS)))
            let target = ((nowS + off0) / 86400).rounded(.down) * 86400 + Double(h * 3600 + m * 60)
            utc = target - Double(from.secondsFromGMT(for: Date(timeIntervalSince1970: target - off0)))
        }
        let date = Date(timeIntervalSince1970: utc)
        let ld = utc + Double(dst.secondsFromGMT(for: date))
        let ls = utc + Double(from.secondsFromGMT(for: date))
        let dayD = (ld / 86400).rounded(.down), dayS = (ls / 86400).rounded(.down)
        let sec = Int(ld - dayD * 86400)
        let hh = sec / 3600, mm = sec % 3600 / 60
        let time = "\(hh % 12 == 0 ? 12 : hh % 12):\(mm < 10 ? "0" : "")\(mm) \(hh < 12 ? "AM" : "PM")"

        let id = dst.identifier
        let place = String(id.split(separator: "/").last ?? Substring(id)).replacingOccurrences(of: "_", with: " ")
        // Real abbreviations (EST, PST, GMT) read well; macOS gives "GMT+9" for many
        // zones, where the city name is clearer.
        var abbr = dst.abbreviation(for: date) ?? place
        if abbr == "GMT+0" || abbr == "GMT+00:00" { abbr = "GMT" }
        if abbr.hasPrefix("GMT") && abbr != "GMT" { abbr = place }

        let delta = Int(dayD - dayS)
        // The title already names the place when the zone has no real abbreviation.
        var detail = (abbr == place ? "" : place + " · ") + weekdays[((Int(dayD) % 7) + 7) % 7]
        if delta != 0 { detail += delta > 0 ? " (+\(delta) day)" : " (\(delta) day)" }
        return InstantAnswer(kind: .time, title: time + " " + abbr, detail: detail, copy: time)
    }
}

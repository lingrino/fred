import Foundation
import Testing
@testable import FredCore

@Suite struct ConverterTests {
    func c(_ q: String) -> String? { Converter.evaluate(q)?.title }

    @Test func lengthsAndMass() {
        #expect(c("5 km in mi") == "3.10686 mi")
        #expect(c("5km to miles") == "3.10686 mi")
        #expect(c("5 km") == "3.10686 mi")               // default target
        #expect(c("6 ft in cm") == "182.88 cm")
        #expect(c("1 in in cm") == "2.54 cm")            // "in" as unit and connector
        #expect(c("180 lb") == "81.6466 kg")
        #expect(c("1,000 ft in m") == "304.8 m")
        #expect(c("2*1024 mb in gb") == "2.048 GB")       // expression as quantity
    }

    @Test func temperature() {
        #expect(c("100 f to c") == "37.7778 °C")
        #expect(c("-40 c in f") == "-40 °F")
        #expect(c("0 c") == "32 °F")
        #expect(c("300 kelvin to c") == "26.85 °C")
    }

    @Test func techUnits() {
        #expect(c("1 GiB to MB") == "1,073.74 MB")
        #expect(c("1 GB") == "0.931323 GiB")
        #expect(c("500 MiB in GB") == "0.524288 GB")
        #expect(c("100 Mb in MB") == "12.5 MB")         // capital-M lowercase-b = megabit
        #expect(c("100 mbps in MB/s") == "12.5 MB/s")
        #expect(c("1 Gbps") == "125 MB/s")
        #expect(c("4096 bytes") == "4 KiB")
        #expect(c("3 ghz in mhz") == "3,000 MHz")
    }

    @Test func durations() {
        #expect(c("90 min") == "1.5 h")
        #expect(c("90 min in s") == "5,400 s")
        #expect(c("36 hours") == "1.5 d")
        #expect(c("2 weeks in days") == "14 d")
        #expect(c("1500 ms") == "1.5 s")
    }

    @Test func notConversions() {
        #expect(c("chroma") == nil)
        #expect(c("2+2") == nil)                         // calculator, not converter
        #expect(c("5 km in kg") == nil)                  // dimension mismatch
        #expect(c("route 66") == nil)
        #expect(c("2fold") == nil)
        #expect(c("sign in") == nil)
    }

    @Test func reviewEdges() {
        // 2026-11-16 review: a comma that isn't a thousands separator isn't ignored.
        #expect(c("1,5 km") == nil)
        #expect(c("1,500 m in km") == "1.5 km")
        // Lowercase kb/s, mb/s, gb/s are all bytes per second (like kb, mb, gb).
        #expect(c("8000 kb/s in mb/s") == "8 MB/s")
        #expect(c("1000 Kb/s in Mb/s") == "1 Mbps")       // capital K/M + b = bits
        // A number glued to a one-letter unit is usually a search ("4K…", "3D…").
        #expect(c("4k") == nil)
        #expect(c("3d") == nil)
        #expect(c("24h") == nil)
        #expect(c("2m") == nil)
        #expect(c("3 d") == "72 h")
        #expect(c("2m in ft") == "6.56168 ft")
        #expect(c("72F") == "22.2222 °C")                  // temperatures still work
    }

    @Test func formatting() {
        #expect(Converter.format(9.9999996, grouping: true) == "10")          // rounding carries
        #expect(Converter.format(-40, grouping: true) == "-40")
        #expect(Converter.format(1234567.4, grouping: true) == "1,234,567")
        #expect(Converter.format(1234567.4, grouping: false) == "1234567")
        #expect(Converter.format(0.000123456, grouping: true) == "0.000123")
        #expect(Converter.format(123456, grouping: true) == "123,456")
        #expect(Converter.format(2e20, grouping: true) == "2e+20")
        #expect(Converter.format(-0.5, grouping: true) == "-0.5")
    }

    @Test func parsingEdges() {
        #expect(c("  5 km  ") == "3.10686 mi")                 // surrounding spaces
        #expect(c("5 KM IN MI") == "3.10686 mi")               // case-insensitive
        #expect(c("5 km in") == nil)                           // mid-typing: no half answer
        #expect(c("(2+3)km") == "3.10686 mi")
        #expect(c("-40 °F") == "-40 °C")
        #expect(c("5e3 m in km") == "5 km")
        #expect(c(String(repeating: "1", count: 100) + " km") == nil)   // over the length cap
        #expect(c("nan km") == nil)
    }

    @Test func timeZones() {
        let utc = TimeZone(identifier: "UTC")!
        // 2026-11-15 12:00 UTC (a Sunday).
        let now = Date(timeIntervalSince1970: 1_794_744_000)
        func t(_ q: String) -> InstantAnswer? { Converter.evaluate(q, now: now, zone: utc) }
        #expect(t("3pm pst in tokyo")?.title == "8:00 AM Tokyo")
        #expect(t("3pm pst in tokyo")?.detail == "Mon (+1 day)")
        #expect(t("15:30 utc to new york")?.title == "10:30 AM EST")
        #expect(t("now in london")?.title == "12:00 PM GMT")
        #expect(t("tokyo time")?.title == "9:00 PM Tokyo")
        #expect(t("midnight to tokyo")?.title == "9:00 AM Tokyo")
        #expect(t("10am amsterdam to london")?.title == "9:00 AM GMT")
        #expect(t("noon et to pt")?.title == "9:00 AM PST")
        #expect(t("9am to ist")?.copy == "2:30 PM")
        #expect(t("15:00 utc to Europe/Paris")?.title == "4:00 PM Paris")   // raw tz identifier
        #expect(t("time machine") == nil)
        #expect(t("screen time") == nil)
        #expect(t("11pm pst to tokyo")?.detail == "Mon (+1 day)")
        #expect(t("1am tokyo to pst")?.detail == "Los Angeles · Sat (-1 day)")
        #expect(t("3 in tokyo") == nil || t("3 in tokyo")?.kind != .time)   // bare "3" isn't a time
    }
}

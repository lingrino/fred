import Testing
@testable import FredCore

@Suite struct CalculatorTests {
    func v(_ s: String) -> String? { Calculator.evaluate(s)?.display }
    func c(_ s: String) -> String? { Calculator.evaluate(s)?.copy }

    @Test func basics() {
        #expect(v("2+2") == "4")
        #expect(v("2 + 2") == "4")
        #expect(v("10-3*2") == "4")
        #expect(v("(10-3)*2") == "14")
        #expect(v("7/2") == "3.5")
        #expect(v("2^10") == "1,024")
        #expect(v("2**3") == "8")
        #expect(v("2^3^2") == "512")       // right associative
        #expect(v("-3+5") == "2")
        #expect(v("10 % 3") == "1")
        #expect(v("5!") == "120")
        #expect(v("3x4") == "12")
        #expect(v("3 × 4") == "12")
        #expect(v("8 ÷ 2") == "4")
        #expect(v("=42") == "42")
    }

    @Test func floatsAreCleaned() {
        #expect(v("0.1+0.2") == "0.3")
        #expect(v("1/3") == "0.333333333333")
        #expect(v("2/3*3") == "2")
    }

    @Test func groupingAndCopy() {
        #expect(v("1000*1000") == "1,000,000")
        #expect(c("1000*1000") == "1000000")
        #expect(v("1,000+1") == "1,001")     // input grouping separators ignored
        #expect(v("-1234.5*2") == "-2,469")
    }

    @Test func functionsAndConstants() {
        #expect(v("sqrt(16)") == "4")
        #expect(v("sqrt 16") == "4")
        #expect(v("2pi") == "6.28318530718")
        #expect(v("abs(-3)") == "3")
        #expect(v("log(1000)") == "3")
        #expect(v("1e3+1") == "1,001")
    }

    @Test func reviewEdges() {
        // 2026-11-16 review: unary minus binds looser than ^, as in written math.
        #expect(v("-2^2") == "-4")
        #expect(v("0-2^2") == "-4")
        #expect(v("(-2)^2") == "4")
        #expect(v("2^-2") == "0.25")
        #expect(v("2*-3") == "-6")
        #expect(v("-3!") == "-6")
        // Hex literals ("0x10" was 0 × 10); a bare one converts.
        #expect(v("0x10") == "16")
        #expect(v("0xff+1") == "256")
        #expect(v("0x") == nil)
        // Cancellation noise below the operands' precision is zero, not 5.55e-17.
        #expect(v("0.1+0.2-0.3") == "0")
        #expect(v("1e-20*1") == "1e-20")
    }

    @Test func notMath() {
        #expect(v("42") == nil)            // bare number: not a calculation
        #expect(v("2fold") == nil)
        #expect(v("chroma") == nil)
        #expect(v("2+") == nil)
        #expect(v("(2+3") == nil)
        #expect(v("") == nil)
        #expect(v("1/0") == nil)           // inf is not shown
        #expect(v("e") == nil)              // no operator
        #expect(v("pi") == nil)
    }
}

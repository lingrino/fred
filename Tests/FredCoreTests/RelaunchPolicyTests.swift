import Testing
@testable import FredCore

@Suite struct RelaunchPolicyTests {
    let now = 1_800_000_000

    @Test func firstCrashesAreRelaunched() {
        #expect(RelaunchPolicy.rearm(after: []))
        #expect(RelaunchPolicy.rearm(after: RelaunchPolicy.recent("\(now - 5)", now: now)))
        #expect(RelaunchPolicy.rearm(after: RelaunchPolicy.recent("\(now - 60),\(now - 5)", now: now)))
    }

    @Test func aCrashLoopStops() {
        let loop = RelaunchPolicy.recent("\(now - 20),\(now - 10),\(now - 1)", now: now)
        #expect(loop.count == RelaunchPolicy.limit)
        #expect(!RelaunchPolicy.rearm(after: loop))
    }

    @Test func oldCrashesDoNotCount() {
        // One crash an hour is relaunched every time.
        let hourly = RelaunchPolicy.recent("\(now - 7200),\(now - 3600),\(now - 1)", now: now)
        #expect(hourly == [now - 1])
        #expect(RelaunchPolicy.rearm(after: hourly))
        #expect(RelaunchPolicy.recent("\(now - RelaunchPolicy.window)", now: now).isEmpty)
        #expect(RelaunchPolicy.recent("\(now - RelaunchPolicy.window + 1)", now: now).count == 1)
    }

    @Test func theArgumentSurvivesTheShell() {
        // The helper appends its own crash time to whatever it was given, even nothing.
        #expect(RelaunchPolicy.recent(",\(now - 1)", now: now) == [now - 1])
        #expect(RelaunchPolicy.recent("", now: now).isEmpty)
        #expect(RelaunchPolicy.recent("x,-5,99999999999999999999999,\(now + 100),\(now)", now: now) == [now])
        let crashes = [now - 30, now - 2]
        #expect(RelaunchPolicy.recent(RelaunchPolicy.argument(crashes) + ",\(now)", now: now) == crashes + [now])
        #expect(RelaunchPolicy.argument([]) == "")
    }
}

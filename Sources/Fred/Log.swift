import Foundation
import os

/// Unified logging. Read with:
///   /usr/bin/log stream --predicate 'subsystem == "dev.fred.Fred"' --level info
enum Log {
    static let logger = Logger(subsystem: "dev.fred.Fred", category: "fred")
    static func info(_ s: String) { logger.notice("\(s, privacy: .public)") }
    static func error(_ s: String) { logger.error("\(s, privacy: .public)") }
}

/// Monotonic nanoseconds (CLOCK_UPTIME_RAW, same base as mach_absolute_time).
@inline(__always) func nowNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

/// Fixed-size latency recorder (no allocation after init). Main-thread only.
/// Exposed through the control socket: `fredctl stats`.
final class LatencyLog {
    let name: String
    private var samples: [UInt64]
    private var next = 0
    private var filled = false

    init(_ name: String, capacity: Int = 512) {
        self.name = name
        samples = Array(repeating: 0, count: capacity)
    }

    func reset() { next = 0; filled = false }

    func add(_ ns: UInt64) {
        samples[next] = ns
        next += 1
        if next == samples.count { next = 0; filled = true }
    }

    /// Quantile q ∈ [0, 1] of recorded samples, or nil when empty.
    func percentile(_ q: Double) -> UInt64? {
        let n = filled ? samples.count : next
        guard n > 0 else { return nil }
        let s = samples[0..<n].sorted()
        return s[min(n - 1, Int(Double(n) * q))]
    }

    var count: Int { filled ? samples.count : next }

    var summary: String {
        let n = filled ? samples.count : next
        guard n > 0 else { return "\(name): no samples" }
        let s = samples[0..<n].sorted()
        func us(_ v: UInt64) -> String { String(format: "%.1fµs", Double(v) / 1000) }
        return "\(name): n=\(n) min=\(us(s[0])) p50=\(us(s[n / 2])) p90=\(us(s[n * 9 / 10])) p99=\(us(s[min(n - 1, n * 99 / 100)])) max=\(us(s[n - 1]))"
    }
}


/// Process resource readings for Fred Settings and `fredctl stats`.
enum Diagnostics {
    /// Physical memory footprint in MB (what Activity Monitor calls "Memory").
    static func footprintMB() -> Double? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : nil
    }

    /// Total CPU time (user + system) used by Fred so far, in seconds.
    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        func s(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return s(u.ru_utime) + s(u.ru_stime)
    }
}

import Foundation

/// Monotonic nanosecond timestamps for latency measurement.
///
/// Every pipeline event carries one of these so the latency budget in docs/PLAN.md
/// section 5 is measured rather than estimated. Uses the uptime clock, which does
/// not jump when the wall clock changes.
public enum MonotonicClock {
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public static func milliseconds(from start: UInt64, to end: UInt64) -> Double {
        end >= start ? Double(end - start) / 1_000_000 : -Double(start - end) / 1_000_000
    }

    public static func millisecondsSince(_ start: UInt64) -> Double {
        milliseconds(from: start, to: now())
    }
}

/// Measures the duration of a block in milliseconds.
@discardableResult
public func measureMilliseconds<T>(_ body: () throws -> T) rethrows -> (result: T, ms: Double) {
    let start = MonotonicClock.now()
    let result = try body()
    return (result, MonotonicClock.millisecondsSince(start))
}

@discardableResult
public func measureMilliseconds<T>(_ body: () async throws -> T) async rethrows -> (result: T, ms: Double) {
    let start = MonotonicClock.now()
    let result = try await body()
    return (result, MonotonicClock.millisecondsSince(start))
}

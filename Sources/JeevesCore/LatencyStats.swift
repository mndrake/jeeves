import Foundation

/// Summary statistics for a set of latency samples, in milliseconds.
public struct LatencyStats: Sendable, Equatable {
    public let count: Int
    public let min: Double
    public let p50: Double
    public let p95: Double
    public let max: Double
    public let mean: Double

    /// Returns nil for an empty sample set.
    public init?(_ samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        count = sorted.count
        min = sorted[0]
        max = sorted[sorted.count - 1]
        mean = sorted.reduce(0, +) / Double(sorted.count)
        p50 = Self.percentile(sorted, 0.50)
        p95 = Self.percentile(sorted, 0.95)
    }

    /// Linear interpolation between closest ranks on pre-sorted input.
    public static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        precondition(!sorted.isEmpty && (0...1).contains(q))
        if sorted.count == 1 { return sorted[0] }
        let position = q * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = Swift.min(lower + 1, sorted.count - 1)
        let fraction = position - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
    }

    /// One-line summary such as `n=20 p50=412.0 p95=655.3 min=380.2 max=702.9 ms`.
    public var summary: String {
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        return "n=\(count) p50=\(f(p50)) p95=\(f(p95)) min=\(f(min)) max=\(f(max)) ms"
    }
}

import Testing
@testable import JeevesCore

@Suite struct LatencyStatsTests {
    @Test func percentilesInterpolate() throws {
        let stats = try #require(LatencyStats([10, 20, 30, 40, 50]))
        #expect(stats.p50 == 30)
        #expect(abs(stats.p95 - 48) < 1e-9)
        #expect(stats.min == 10 && stats.max == 50 && stats.mean == 30)
    }

    @Test func singleSampleAndEmpty() {
        #expect(LatencyStats([7])?.p95 == 7)
        #expect(LatencyStats([]) == nil)
    }
}

@Suite struct CommandLineFlagsTests {
    @Test func parsesValuesSwitchesAndPositionals() {
        let flags = CommandLineFlags(["--n", "5", "--mode=fast", "--dry-run", "file.wav", "--last"], switches: ["dry-run"])
        #expect(flags.int("n", default: 0) == 5)
        #expect(flags.string("mode", default: "") == "fast")
        #expect(flags.has("dry-run") && flags.has("last"))
        #expect(flags.positional == ["file.wav"])
        #expect(flags.double("missing", default: 1.5) == 1.5)
    }

    @Test func unknownBareFlagStillConsumesAFollowingValue() {
        let flags = CommandLineFlags(["--out", "results.json"])
        #expect(flags.string("out", default: "") == "results.json")
        #expect(flags.positional.isEmpty)
    }
}

@Suite struct ClockTests {
    @Test func monotonicAndMilliseconds() {
        let a = MonotonicClock.now()
        let b = MonotonicClock.now()
        #expect(b >= a)
        #expect(MonotonicClock.milliseconds(from: 0, to: 2_500_000) == 2.5)
        #expect(MonotonicClock.milliseconds(from: 2_500_000, to: 0) == -2.5)
    }
}

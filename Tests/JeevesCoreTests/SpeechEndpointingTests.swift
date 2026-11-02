import Testing
@testable import JeevesCore

@Suite struct SilenceEndpointerTests {
    /// Feeds 10 ms chunks: `pattern` is a list of (level dB, number of chunks).
    func run(_ endpointer: inout SilenceEndpointer, _ pattern: [(Float, Int)]) -> [SilenceEndpointer.EndOfSpeech] {
        var ends: [SilenceEndpointer.EndOfSpeech] = []
        var wall: UInt64 = 0
        for (level, count) in pattern {
            for _ in 0..<count {
                wall += 10_000_000
                if let end = endpointer.process(levelDecibels: level, duration: 0.01, capturedAt: wall) { ends.append(end) }
            }
        }
        return ends
    }

    @Test func reportsEndAfterSilenceThreshold() throws {
        var endpointer = SilenceEndpointer(speechThresholdDecibels: -45, silenceDuration: 0.4)
        let ends = run(&endpointer, [(-80, 50), (-20, 100), (-80, 39)])
        #expect(ends.isEmpty)  // 390 ms of silence: not yet
        let more = run(&endpointer, [(-80, 1)])
        let end = try #require(more.first)
        #expect(abs(end.speechStart - 0.5) < 1e-9)
        #expect(abs(end.audioTime - 1.5) < 1e-9)
        #expect(end.wallTime == 1_500_000_000)  // capture time of the last loud chunk
        #expect(end.detectedAt == 10_000_000)  // first chunk of the second run, whose clock restarts at 0
    }

    @Test func shortPausesDoNotSplitAnUtterance() {
        var endpointer = SilenceEndpointer(silenceDuration: 0.4)
        let ends = run(&endpointer, [(-20, 50), (-80, 20), (-20, 50), (-80, 45)])
        #expect(ends.count == 1)
        #expect(abs(ends[0].speechStart - 0) < 1e-9)
        #expect(abs(ends[0].audioTime - 1.2) < 1e-9)
    }

    @Test func ignoresBlipsAndReportsEachUtteranceOnce() {
        var endpointer = SilenceEndpointer(silenceDuration: 0.4, minimumSpeechDuration: 0.15)
        let ends = run(&endpointer, [(-20, 5), (-80, 60), (-20, 30), (-80, 100), (-20, 30), (-80, 50)])
        #expect(ends.map(\.audioTime).count == 2)  // the 50 ms blip is dropped
        #expect(!endpointer.isInSpeech)
    }
}

@Suite struct FinalLatencyMatcherTests {
    func end(_ audioTime: Double, wallMs: UInt64) -> SilenceEndpointer.EndOfSpeech {
        .init(speechStart: audioTime - 1, audioTime: audioTime, wallTime: wallMs * 1_000_000, detectedAt: 0)
    }

    @Test func matchesFinalsToEndsAndMeasuresFromSpeechEnd() {
        var matcher = FinalLatencyMatcher()
        matcher.speechEnded(end(3.0, wallMs: 3_000))
        #expect(matcher.finalArrived(audioEnd: 2.0, at: 3_100_000_000).isEmpty)  // earlier speech
        #expect(matcher.finalArrived(audioEnd: 3.2, at: 3_650_000_000) == [650])
        #expect(matcher.unmatched == 0 && matcher.latenciesMs == [650])
    }

    @Test func finalsThatSwallowAPauseCountAsMerged() {
        var matcher = FinalLatencyMatcher(lateTolerance: 0.5, mergeThreshold: 1.5)
        matcher.speechEnded(end(5.0, wallMs: 5_000))
        matcher.speechEnded(end(9.0, wallMs: 9_000))
        let resolved = matcher.finalArrived(audioEnd: 9.1, at: 9_800_000_000)
        #expect(resolved == [800])
        #expect(matcher.merged == 1 && matcher.detected == 2 && matcher.unmatched == 0)
    }
}

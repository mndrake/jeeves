import Testing
@testable import JeevesCore

@Suite struct CapturePlannerTests {
    func process(_ id: UInt32, _ bundle: String, playing: Bool = false) -> AudioProcessInfo {
        AudioProcessInfo(objectID: id, pid: Int32(id) + 1000, bundleID: bundle, isRunningOutput: playing)
    }

    let chrome = "com.google.Chrome"
    let helper = "com.google.Chrome.helper"

    @Test func browserMatchingUsesPrefixes() {
        #expect(Browser.chrome.owns(bundleID: "com.google.Chrome.helper.renderer"))
        #expect(!Browser.chrome.owns(bundleID: "com.apple.Safari"))
        #expect(Browser.safari.owns(bundleID: "com.apple.WebKit.GPU"))
        #expect(!Browser.firefox.owns(bundleID: nil))
    }

    @Test func waitsThenStartsWhenTheBrowserAppears() {
        let others = [process(1, "com.spotify.client", playing: true)]
        #expect(CapturePlanner.decide(browser: .chrome, processes: others, tapped: nil, canRetarget: true) == .waitForBrowser)
        let withChrome = others + [process(2, chrome), process(3, helper)]
        #expect(CapturePlanner.decide(browser: .chrome, processes: withChrome, tapped: nil, canRetarget: true) == .start([2, 3]))
    }

    @Test func retargetsWhenSupportedAndTheSetChanges() {
        let list = [process(2, chrome), process(3, helper), process(4, helper)]
        #expect(CapturePlanner.decide(browser: .chrome, processes: list, tapped: [2, 3], canRetarget: true) == .retarget([2, 3, 4]))
        #expect(CapturePlanner.decide(browser: .chrome, processes: list, tapped: [2, 3, 4], canRetarget: true) == .none)
    }

    @Test func withoutRetargetOnlyRebuildsForAPlayingMissedProcess() {
        let quiet = [process(2, chrome), process(3, helper), process(4, helper)]
        #expect(CapturePlanner.decide(browser: .chrome, processes: quiet, tapped: [2, 3], canRetarget: false) == .none)
        let playing = [process(2, chrome), process(3, helper), process(4, helper, playing: true)]
        #expect(CapturePlanner.decide(browser: .chrome, processes: playing, tapped: [2, 3], canRetarget: false)
                == .rebuild([2, 3, 4], reason: "new chrome audio process is playing"))
        // A process that went away needs no action: its object is simply gone.
        #expect(CapturePlanner.decide(browser: .chrome, processes: [process(2, chrome)], tapped: [2, 3], canRetarget: false) == .none)
    }

    @Test func rebuildsAfterRestartAndStopsWhenTheBrowserQuits() {
        let restarted = [process(7, chrome), process(8, helper)]
        #expect(CapturePlanner.decide(browser: .chrome, processes: restarted, tapped: [2, 3], canRetarget: true)
                == .rebuild([7, 8], reason: "chrome restarted"))
        #expect(CapturePlanner.decide(browser: .chrome, processes: [], tapped: [2, 3], canRetarget: true)
                == .stop(reason: "chrome has no audio processes"))
    }
}

@Suite struct ExponentialBackoffTests {
    @Test func doublesThenCapsAndResets() {
        var backoff = ExponentialBackoff(initial: 0.25, maximum: 2, multiplier: 2)
        #expect((0..<6).map { _ in backoff.nextDelay() } == [0.25, 0.5, 1, 2, 2, 2])
        backoff.reset()
        #expect(backoff.nextDelay() == 0.25)
    }
}

@Suite struct TimelineAlignerTests {
    let ms: UInt64 = 1_000_000

    @Test func neverFillsDuringNormalCaptureEvenWithDrift() {
        var aligner = TimelineAligner()
        var t: UInt64 = 10_000 * ms
        for _ in 0..<1000 {
            t += 11 * ms  // 10 ms chunks arriving every 11 ms: drift, not loss
            #expect(aligner.silenceBefore(chunkDuration: 0.01, capturedAt: t, afterRestart: false) == 0)
        }
        #expect(aligner.filledSeconds == 0)
    }

    @Test func fillsTheGapLeftByARebuild() {
        var aligner = TimelineAligner(maximumFill: 5, tolerance: 0.05)
        var t: UInt64 = 10_000 * ms
        for _ in 0..<100 {
            t += 10 * ms
            _ = aligner.silenceBefore(chunkDuration: 0.01, capturedAt: t, afterRestart: false)
        }
        t += 410 * ms  // 400 ms of audio lost while the tap was rebuilt
        let fill = aligner.silenceBefore(chunkDuration: 0.01, capturedAt: t, afterRestart: true)
        #expect(abs(fill - 0.4) < 0.001)
        #expect(abs(aligner.emittedSeconds - 1.41) < 0.001)
    }

    @Test func capsLongGapsAndIgnoresTinyOnes() {
        var aligner = TimelineAligner(maximumFill: 2, tolerance: 0.05)
        var t: UInt64 = 1_000 * ms
        _ = aligner.silenceBefore(chunkDuration: 0.01, capturedAt: t, afterRestart: false)
        t += 30 * ms
        #expect(aligner.silenceBefore(chunkDuration: 0.01, capturedAt: t, afterRestart: true) == 0)  // 20 ms: under tolerance
        t += 10_000 * ms
        #expect(aligner.silenceBefore(chunkDuration: 0.01, capturedAt: t, afterRestart: true) == 2)
    }
}

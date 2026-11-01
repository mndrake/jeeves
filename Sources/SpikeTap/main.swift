// M0 spike: capture a browser's call audio with a Core Audio process tap.
//
//   swift run spike-tap --list
//   swift run spike-tap --browser chrome [--strategy pids] --seconds 60 [--wav recordings/call.wav]
//
// Strategies: pids (the browser's processes; default), system (everything except
// Jeeves), bundle (CATapDescription.bundleIDs, macOS 26; captured nothing from Chrome
// in M0). Prints callbacks, frames, gaps, level and CPU every 5 seconds whether or not
// audio arrives, and stops on time. macOS asks for "system audio recording" permission
// for the app that launched the binary (your terminal) the first time.
#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import JeevesCore

let flags = CommandLineFlags(switches: ["list", "help"])

if flags.has("help") {
    print("usage: spike-tap --list | --browser chrome|safari|edge|arc|firefox [--strategy pids|system|bundle] [--seconds 60] [--wav out.wav]")
    exit(0)
}

if flags.has("list") {
    let processes = try AudioProcess.all().sorted { ($0.bundleID ?? "") < ($1.bundleID ?? "") }
    print("Core Audio processes (\(processes.count)):")
    for process in processes {
        let owner = Browser.allCases.first { $0.owns(process) }.map { "  <- \($0.rawValue)" } ?? ""
        print("  \(process)\(owner)")
    }
    exit(0)
}

guard let browser = Browser(rawValue: flags.string("browser", default: "chrome")),
      let strategy = TapStrategy(rawValue: flags.string("strategy", default: "pids")) else {
    log("unknown --browser or --strategy; see --help")
    exit(2)
}
let seconds = flags.double("seconds", default: 60)

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

let target = try ProcessTap.target(for: browser, strategy: strategy)
let tap = ProcessTap(target: target)
log("tapping \(browser.rawValue) via \(strategy.rawValue): \(target)")
let chunks = try tap.start()
let stats0 = tap.stats
log("tap format: \(stats0.inputSampleRate) Hz x \(stats0.inputChannels) ch -> 16000 Hz x 1 ch")

let writer = try flags.values["wav"].map { path -> WAVWriter in
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try WAVWriter(url: url, format: tap.outputFormat)
}

let startWall = MonotonicClock.now()
let startCPU = cpuSeconds()

// Consume audio on its own task (writes the WAV, measures hand-off lag) so the clock
// below keeps running even if the tap delivers nothing.
let consumer = Task {
    var lags: [Double] = []
    var writeError: Error?
    for await chunk in chunks {
        lags.append(MonotonicClock.millisecondsSince(chunk.capturedAt))
        if writeError == nil {
            do { try writer?.write(chunk.buffer) } catch { writeError = error }
        }
    }
    return (lags, writeError)
}

var elapsed = 0.0
var warned = false
while elapsed < seconds {
    let step = min(5, seconds - elapsed)
    try await Task.sleep(for: .seconds(step))
    elapsed += step
    let s = tap.stats
    let cpu = (cpuSeconds() - startCPU) / max(elapsed, 0.001) * 100
    print(String(format: "%5.0fs  callbacks %6ld (empty %ld)  in %8ld  out %8ld  gaps %3ld  peak %6.1f dB  audible %5ld  cpu %4.1f%%",
                 elapsed, s.callbacks, s.emptyCallbacks, s.inputFrames, s.outputFrames, s.discontinuities,
                 tap.takeIntervalPeak(), s.audibleChunks, cpu))
    if !warned && s.callbacks == 0 {
        print("  no IO callbacks at all: the tap's audio device is not running. Check the system audio recording permission for your terminal.")
        warned = true
    } else if !warned && s.inputFrames == 0 {
        print("  callbacks arrive but carry no audio: this strategy is not capturing \(browser.rawValue). Try --strategy pids or system.")
        warned = true
    }
}
tap.stop()
let (deliveryLags, writeError) = await consumer.value

let s = tap.stats
let wall = MonotonicClock.millisecondsSince(startWall) / 1000
let verdict: String
if s.callbacks == 0 {
    verdict = "NO IO: the tap never ran (permission?)"
} else if s.inputFrames == 0 {
    verdict = "NOT CAPTURING: callbacks with no audio"
} else if s.audibleChunks == 0 {
    verdict = "SILENT: audio frames arrived but all below -50 dBFS (was anyone talking?)"
} else if s.discontinuities > 0 {
    verdict = "CAPTURING WITH GAPS"
} else {
    verdict = "CAPTURING"
}
print("""

summary  browser=\(browser.rawValue) strategy=\(strategy.rawValue) seconds=\(String(format: "%.0f", wall))
  verdict      \(verdict)
  input        \(s.inputSampleRate) Hz x \(s.inputChannels) ch, \(s.inputFrames) frames (\(String(format: "%.1f", Double(s.inputFrames) / max(s.inputSampleRate, 1))) s of audio)
  output       \(s.outputFrames) frames at 16 kHz (\(String(format: "%.1f", Double(s.outputFrames) / 16_000)) s)
  callbacks    \(s.callbacks), of which \(s.emptyCallbacks) carried no audio
  gaps         \(s.discontinuities) (\(s.droppedFrames) frames), conversion errors \(s.conversionErrors)
  audible      \(s.audibleChunks) of \(s.callbacks - s.emptyCallbacks) chunks above -50 dBFS
  cpu          \(String(format: "%.1f", (cpuSeconds() - startCPU) / max(wall, 0.001) * 100))% of one core
  chunk lag    \(LatencyStats(deliveryLags)?.summary ?? "-")  (IO callback to consumer)
""")
if let writeError { log("WAV write failed: \(writeError)") }
#else
print("spike-tap needs macOS 26 or later (Core Audio process taps).")
#endif

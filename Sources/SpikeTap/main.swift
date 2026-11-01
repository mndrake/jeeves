// M0 spike: capture a browser's call audio with a Core Audio process tap.
//
//   swift run spike-tap --list
//   swift run spike-tap --browser chrome --strategy bundle --seconds 60 [--wav recordings/call.wav]
//
// Strategies: bundle (CATapDescription.bundleIDs, macOS 26), pids (the browser's helper
// processes), system (everything except Jeeves). Run each against a live Meet call and
// record which one captures the remote side. Prints callbacks, frames, gaps and CPU
// every 5 seconds. macOS asks for "system audio recording" permission for the app that
// launched the binary (your terminal) the first time.
#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import JeevesCore

let flags = CommandLineFlags(switches: ["list", "help"])

if flags.has("help") {
    print("usage: spike-tap --list | --browser chrome|safari|edge|arc|firefox [--strategy bundle|pids|system] [--seconds 60] [--wav out.wav]")
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
      let strategy = TapStrategy(rawValue: flags.string("strategy", default: "bundle")) else {
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
var lastReport = startWall
var peak: Float = -160
var loudChunks = 0
var deliveryLags: [Double] = []

for await chunk in chunks {
    try writer?.write(chunk.buffer)
    peak = max(peak, chunk.rmsDecibels)
    if chunk.rmsDecibels > -50 { loudChunks += 1 }
    deliveryLags.append(MonotonicClock.millisecondsSince(chunk.capturedAt))

    let now = MonotonicClock.now()
    if MonotonicClock.milliseconds(from: lastReport, to: now) >= 5_000 {
        lastReport = now
        let s = tap.stats
        let elapsed = MonotonicClock.milliseconds(from: startWall, to: now) / 1000
        let cpu = (cpuSeconds() - startCPU) / elapsed * 100
        print(String(format: "%5.0fs  callbacks %6ld  in %8ld  out %8ld  gaps %3ld (%ld frames)  peak %6.1f dB  cpu %4.1f%%",
                     elapsed, s.callbacks, s.inputFrames, s.outputFrames, s.discontinuities, s.droppedFrames, peak, cpu))
        peak = -160
    }
    if MonotonicClock.millisecondsSince(startWall) >= seconds * 1000 { break }
}
tap.stop()

let s = tap.stats
let elapsed = MonotonicClock.millisecondsSince(startWall) / 1000
print("""

summary  browser=\(browser.rawValue) strategy=\(strategy.rawValue) seconds=\(String(format: "%.0f", elapsed))
  input        \(s.inputSampleRate) Hz x \(s.inputChannels) ch, \(s.inputFrames) frames (\(String(format: "%.1f", Double(s.inputFrames) / max(s.inputSampleRate, 1))) s of audio)
  output       \(s.outputFrames) frames at 16 kHz (\(String(format: "%.1f", Double(s.outputFrames) / 16_000)) s)
  gaps         \(s.discontinuities) (\(s.droppedFrames) frames), conversion errors \(s.conversionErrors)
  audible      \(loudChunks) of \(s.callbacks) chunks above -50 dBFS  (0 means the tap heard silence: try another strategy)
  cpu          \(String(format: "%.1f", (cpuSeconds() - startCPU) / elapsed * 100))% of one core
  chunk lag    \(LatencyStats(deliveryLags)?.summary ?? "-")  (IO callback to consumer)
""")
#else
print("spike-tap needs macOS 26 or later (Core Audio process taps).")
#endif

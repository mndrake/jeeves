// M1 soak and resilience test for supervised capture (CaptureSession).
//
//   spike-capture [--browser chrome] [--strategy pids] [--minutes 60] [--report-every 60] [--wav out.wav]
//
// Runs one CaptureSession for the whole period and prints every status change as it
// happens (waiting, capturing, reconnecting and why). A progress line every
// --report-every seconds shows audio totals, gaps, restarts, CPU and memory. The summary
// checks the M1 exit criteria (docs/M1.md): no gaps inside a tap, every restart back
// within 2 s, under 5% of one core, memory flat, and the audio timeline covering the
// whole run.
//
// Exercise it during a run: connect and disconnect AirPods, open a new Meet tab, quit
// and reopen Chrome, or start this before Chrome is running.
#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import JeevesCore

let flags = CommandLineFlags(switches: ["help"])
if flags.has("help") {
    print("usage: spike-capture [--browser chrome|safari|edge|arc|firefox] [--strategy pids|system|bundle] [--minutes 60] [--report-every 60] [--wav out.wav]")
    exit(0)
}
guard let browser = Browser(rawValue: flags.string("browser", default: "chrome")),
      let strategy = TapStrategy(rawValue: flags.string("strategy", default: "pids")) else {
    log("unknown --browser or --strategy; see --help")
    exit(2)
}
let minutes = flags.double("minutes", default: 60)
let reportEvery = max(5, flags.double("report-every", default: 60))

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
        + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
}

/// Peak resident memory in MB (ru_maxrss is in bytes on macOS).
func peakMemoryMB() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Double(usage.ru_maxrss) / 1_048_576
}

func clock(_ seconds: Double) -> String {
    String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
}

let session = CaptureSession(browser: browser, strategy: strategy)
let writer = try flags.values["wav"].map { path -> WAVWriter in
    let url = URL(fileURLWithPath: path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    return try WAVWriter(url: url, format: session.outputFormat)
}

print("spike-capture  browser=\(browser.rawValue) strategy=\(strategy.rawValue) minutes=\(String(format: "%g", minutes))")
let start = MonotonicClock.now()
let startCPU = cpuSeconds()
let events = session.start()

let consumer = Task {
    var writeError: Error?
    var statusLog: [String] = []
    for await event in events {
        switch event {
        case .audio(let chunk):
            if writeError == nil {
                do { try writer?.write(chunk.buffer) } catch { writeError = error }
            }
        case .status(let status):
            let line = "[\(clock(MonotonicClock.millisecondsSince(start) / 1000))] \(status)"
            statusLog.append(line)
            print(line)
        }
    }
    return (statusLog, writeError)
}

var elapsed = 0.0
var memoryAfterWarmup: Double?
let total = minutes * 60
while elapsed < total {
    let step = min(reportEvery, total - elapsed)
    try await Task.sleep(for: .seconds(step))
    elapsed += step
    let s = session.statistics
    let cpu = (cpuSeconds() - startCPU) / max(elapsed, 0.001) * 100
    let memory = peakMemoryMB()
    if memoryAfterWarmup == nil, elapsed >= min(60, total) { memoryAfterWarmup = memory }
    print(String(format: "  %@  audio %7.1f s  filled %5.2f s  callbacks %8ld  gaps %ld  audible %7ld  restarts %ld  retargets %ld  cpu %4.1f%%  mem %5.1f MB",
                 clock(elapsed), s.outputSeconds, s.silenceFilledSeconds, s.callbacks, s.discontinuities,
                 s.audibleChunks, s.restarts.count, s.retargets, cpu, memory))
}

session.stop()
let (_, writeError) = await consumer.value
let s = session.statistics
let wall = MonotonicClock.millisecondsSince(start) / 1000
let cpu = (cpuSeconds() - startCPU) / max(wall, 0.001) * 100
let memoryEnd = peakMemoryMB()
let outages = s.restartLog.outageDurationsMs
let worstOutage = outages.max() ?? 0
let coverage = s.outputSeconds / max(wall, 0.001)

func check(_ ok: Bool) -> String { ok ? "PASS" : "FAIL" }
print("""

summary  browser=\(browser.rawValue) strategy=\(strategy.rawValue) wall=\(clock(wall))
  audio        \(String(format: "%.1f", s.outputSeconds)) s emitted (\(String(format: "%.1f", s.silenceFilledSeconds)) s of it silence filled during restarts), coverage \(String(format: "%.1f", coverage * 100))%
  input        \(s.inputSampleRate) Hz x \(s.inputChannels) ch, \(s.callbacks) callbacks (\(s.emptyCallbacks) empty), \(s.audibleChunks) audible chunks
  retarget     \(s.retargets) in place, \(s.retargetFailures) refused; supported: \(s.retargetSupported.map { $0 ? "yes" : "no" } ?? "not needed")
  startup      \(s.startupMs.map { String(format: "first audio %.0f ms after the first tap started", $0) } ?? "no audio received")
  restarts     \(s.restarts.count) in \(outages.count + s.restartLog.unrecovered) outages\(outages.isEmpty ? "" : ", worst outage \(String(format: "%.0f", worstOutage)) ms")
""")
for restart in s.restarts {
    let at = MonotonicClock.milliseconds(from: start, to: restart.at) / 1000
    let outcome = restart.superseded ? "retried again before audio returned"
        : restart.outageMs.map { String(format: "audio back, outage %.0f ms", $0) } ?? "not recovered before stop"
    print("    [\(clock(at))] \(restart.reason)  \(outcome)")
}
print("""
  checks
    \(check(s.discontinuities == 0))  no gaps inside a tap (\(s.discontinuities) gaps, \(s.droppedFrames) frames)
    \(check(worstOutage <= 2_000 && s.restartLog.unrecovered == 0))  every outage back within 2 s
    \(check(cpu < 5))  CPU under 5% of one core (\(String(format: "%.1f", cpu))%)
    \(check(memoryEnd - (memoryAfterWarmup ?? memoryEnd) < 20))  memory flat after the first minute (peak \(String(format: "%.1f", memoryAfterWarmup ?? 0)) -> \(String(format: "%.1f", memoryEnd)) MB)
    \(check(coverage > 0.98 || s.callbacks == 0))  audio timeline covers the run (\(String(format: "%.1f", coverage * 100))%; low if the browser was not running)
""")
if let writeError { log("WAV write failed: \(writeError)") }
#else
print("spike-capture needs macOS 26 or later (Core Audio process taps).")
#endif

// M0 spike: Apple SpeechAnalyzer latency and throughput.
//
//   swift run spike-stt recordings/call.wav [--mode fast|accurate]        # offline file
//   swift run spike-stt --live --browser chrome [--strategy bundle] [--seconds 120] [--mode fast]
//
// File mode reports the real-time factor and prints final segments with timestamps
// (paste them next to a reference transcript to estimate word error rate in M2).
// Live mode taps the browser and reports how far behind real time final results
// arrive: the "audio to STT final segment" line of the latency budget (target 500 ms).
// --vocab "Sonnet,Opus,Haiku,max_tokens" passes contextual strings to the analyzer.
#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import JeevesCore
import Transcription

let flags = CommandLineFlags(switches: ["live", "help", "partials"])
if flags.has("help") {
    print("usage: spike-stt <file.wav> | --live --browser chrome [--strategy bundle|pids|system] [--seconds 120] [--mode fast|accurate] [--vocab a,b,c] [--partials]")
    exit(0)
}

guard #available(macOS 26.0, *) else {
    print("spike-stt needs macOS 26 or later (SpeechAnalyzer).")
    exit(1)
}

let mode = TranscriberMode(rawValue: flags.string("mode", default: "fast")) ?? .fast
let vocabulary = flags.values["vocab"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ?? DomainVocabulary.anthropic

let setupStart = MonotonicClock.now()
let session = try await SpeechAnalyzerSession.start(mode: mode, contextualStrings: vocabulary)
log("SpeechAnalyzer ready in \(String(format: "%.0f", MonotonicClock.millisecondsSince(setupStart))) ms; locale \(session.locale.identifier), format \(session.audioFormat)")

if flags.has("live") {
    guard let browser = Browser(rawValue: flags.string("browser", default: "chrome")),
          let strategy = TapStrategy(rawValue: flags.string("strategy", default: "bundle")) else {
        log("unknown --browser or --strategy")
        exit(2)
    }
    let seconds = flags.double("seconds", default: 120)
    let tap = ProcessTap(target: try ProcessTap.target(for: browser, strategy: strategy), outputFormat: session.audioFormat)
    let chunks = try tap.start()
    let audioStart = MonotonicClock.now()
    let showPartials = flags.has("partials")

    // Feed audio on its own task; collect results on this one.
    let feeder = Task.detached {
        for await chunk in chunks { session.feed(chunk.buffer) }
    }

    let reader = Task {
        var finalLags: [Double] = []
        var partialLags: [Double] = []
        for try await update in session.updates {
            // How far behind the live audio this result is: wall time since the first
            // buffer, minus the audio time the result ends at.
            let lag = MonotonicClock.milliseconds(from: audioStart, to: update.receivedAt) - update.audioEnd * 1000
            if update.isFinal {
                finalLags.append(lag)
                print(String(format: "[%7.2f-%7.2f] +%4.0f ms  %@", update.audioStart, update.audioEnd, lag, update.text))
            } else {
                partialLags.append(lag)
                if showPartials { print(String(format: "    partial +%4.0f ms  %@", lag, update.text)) }
            }
        }
        return (finalLags, partialLags)
    }

    try await Task.sleep(for: .seconds(seconds))
    tap.stop()
    feeder.cancel()
    try await session.finish()
    let (finals, partials) = try await reader.value
    print("""

    live summary  mode=\(mode.rawValue) browser=\(browser.rawValue) strategy=\(strategy.rawValue)
      final lag    \(LatencyStats(finals)?.summary ?? "no finals: was anyone talking?")
      partial lag  \(LatencyStats(partials)?.summary ?? "-")
      tap gaps     \(tap.stats.discontinuities)
    """)
} else {
    guard let path = flags.positional.first else {
        log("pass a WAV file, or --live; see --help")
        exit(2)
    }
    let start = MonotonicClock.now()
    let reader = Task {
        var finals: [TranscriptUpdate] = []
        var firstFinalMs: Double?
        for try await update in session.updates where update.isFinal {
            if firstFinalMs == nil { firstFinalMs = MonotonicClock.millisecondsSince(start) }
            finals.append(update)
            print(String(format: "[%7.2f-%7.2f] %@", update.audioStart, update.audioEnd, update.text))
        }
        return (finals, firstFinalMs)
    }
    let audioSeconds = try feedFile(URL(fileURLWithPath: path), to: session)
    try await session.finish()
    let (finals, firstFinalMs) = try await reader.value
    let wall = MonotonicClock.millisecondsSince(start) / 1000
    let words = finals.reduce(0) { $0 + $1.text.split(separator: " ").count }
    print("""

    file summary  mode=\(mode.rawValue)  \(path)
      audio        \(String(format: "%.1f", audioSeconds)) s, \(finals.count) final segments, \(words) words
      wall time    \(String(format: "%.1f", wall)) s  (real-time factor \(String(format: "%.3f", wall / max(audioSeconds, 0.001))); below 1 is faster than real time)
      first final  \(firstFinalMs.map { String(format: "%.0f ms", $0) } ?? "-")
    """)
}
#else
print("spike-stt needs macOS 26 or later (SpeechAnalyzer).")
#endif

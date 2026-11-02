// M0 spike: Apple SpeechAnalyzer latency and throughput.
//
//   swift run spike-stt recordings/call.wav [--mode fast|accurate]        # offline file
//   swift run spike-stt --live --browser chrome [--strategy pids] [--seconds 120] [--mode fast]
//
// File mode reports the real-time factor and prints final segments with timestamps
// (paste them next to a reference transcript to estimate word error rate in M2).
// Live mode taps the browser and reports how far behind real time final results
// arrive: the "audio to STT final segment" line of the latency budget (target 500 ms).
// --vocab "Sonnet,Opus,Haiku,max_tokens" passes contextual strings to the analyzer.
//
// Finalize experiment (live mode): Jeeves detects the end of speech itself (audio above
// --speech-db, then --silence-ms of quiet). Every run reports "speech end to final":
// how long after the speaker stopped the final text arrived. With --finalize-on-silence
// the spike also calls SpeechAnalyzer.finalize(through:) at each detected end, instead
// of waiting for the engine's own decision. Compare a run with and without it:
//   spike-stt --live --seconds 60
//   spike-stt --live --seconds 60 --finalize-on-silence [--silence-ms 300]
#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import JeevesCore
import Synchronization
import Transcription

let flags = CommandLineFlags(switches: ["live", "help", "partials", "finalize-on-silence"])
if flags.has("help") {
    print("usage: spike-stt <file.wav> | --live --browser chrome [--strategy pids|system|bundle] [--seconds 120] [--mode fast|accurate] [--vocab a,b,c] [--partials] [--finalize-on-silence] [--silence-ms 400] [--speech-db -45]")
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
          let strategy = TapStrategy(rawValue: flags.string("strategy", default: "pids")) else {
        log("unknown --browser or --strategy")
        exit(2)
    }
    let seconds = flags.double("seconds", default: 120)
    let tap = ProcessTap(target: try ProcessTap.target(for: browser, strategy: strategy), outputFormat: session.audioFormat)
    let chunks = try tap.start()
    let audioStart = MonotonicClock.now()
    let showPartials = flags.has("partials")

    let finalizeOnSilence = flags.has("finalize-on-silence")
    let silenceMs = flags.double("silence-ms", default: 400)
    let speechDB = Float(flags.double("speech-db", default: -45))
    let sampleRate = session.audioFormat.sampleRate
    let endpoints = EndpointLog()

    // Feed audio and detect ends of speech on one task; read results on another.
    let feeder = Task.detached {
        var endpointer = SilenceEndpointer(speechThresholdDecibels: speechDB, silenceDuration: silenceMs / 1000)
        var peak: Float = -160
        var nextHeartbeat = 10.0
        for await chunk in chunks {
            session.feed(chunk.buffer)
            peak = max(peak, chunk.rmsDecibels)
            let duration = Double(chunk.buffer.frameLength) / sampleRate
            if let end = endpointer.process(levelDecibels: chunk.rmsDecibels, duration: duration, capturedAt: chunk.capturedAt) {
                endpoints.speechEnded(end)
                if finalizeOnSilence {
                    // A little past the last loud chunk so trailing phonemes are included.
                    let through = end.audioTime + 0.05
                    Task {
                        do { try await session.finalize(throughSeconds: through) } catch { endpoints.finalizeFailed() }
                    }
                }
            }
            if endpointer.audioTime >= nextHeartbeat {
                print(String(format: "  -- %3.0fs of audio, peak %.1f dB, %ld speech ends so far", endpointer.audioTime, peak, endpoints.detectedCount))
                nextHeartbeat += 10
                peak = -160
            }
        }
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
                let fromSpeechEnd = endpoints.finalArrived(audioEnd: update.audioEnd, at: update.receivedAt)
                let note = fromSpeechEnd.map { String(format: "  (%.0f ms after speech ended)", $0) }.joined()
                print(String(format: "[%7.2f-%7.2f] +%4.0f ms  %@%@", update.audioStart, update.audioEnd, lag, update.text, note))
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
    let matcher = endpoints.snapshot
    print("""

    live summary  mode=\(mode.rawValue) browser=\(browser.rawValue) strategy=\(strategy.rawValue) finalize-on-silence=\(finalizeOnSilence ? "on" : "off")
      final lag           \(LatencyStats(finals)?.summary ?? "no finals: was anyone talking?")
      partial lag         \(LatencyStats(partials)?.summary ?? "-")
      speech end to final \(LatencyStats(matcher.latenciesMs)?.summary ?? "no matched speech ends")
      speech ends         \(matcher.detected) detected (silence \(Int(silenceMs)) ms, speech above \(Int(speechDB)) dBFS); \(matcher.latenciesMs.count) matched, \(matcher.merged) merged into longer finals, \(matcher.unmatched) never finalized
      finalize errors     \(endpoints.finalizeErrors)
      tap gaps            \(tap.stats.discontinuities)

    "speech end to final" includes the \(Int(silenceMs)) ms silence wait when finalize-on-silence is on.
    Partial text is usable at the silence threshold itself, so compare against \(Int(silenceMs)) ms.
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
/// Shared between the feeding task and the results task.
final class EndpointLog: Sendable {
    private let state = Mutex((matcher: FinalLatencyMatcher(), finalizeErrors: 0))

    func speechEnded(_ end: SilenceEndpointer.EndOfSpeech) { state.withLock { $0.matcher.speechEnded(end) } }
    func finalArrived(audioEnd: Double, at time: UInt64) -> [Double] {
        state.withLock { $0.matcher.finalArrived(audioEnd: audioEnd, at: time) }
    }
    func finalizeFailed() { state.withLock { $0.finalizeErrors += 1 } }
    var detectedCount: Int { state.withLock { $0.matcher.detected } }
    var finalizeErrors: Int { state.withLock { $0.finalizeErrors } }
    var snapshot: FinalLatencyMatcher { state.withLock { $0.matcher } }
}
#else
print("spike-stt needs macOS 26 or later (SpeechAnalyzer).")
#endif

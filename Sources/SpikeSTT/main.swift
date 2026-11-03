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
//
// M2: at each detected end of speech the spike prints the provisional text Jeeves would
// act on (latest partial, aliases applied) and, when the final arrives, whether it
// differed. --second-pass parakeet|parakeet-boost re-transcribes each utterance's audio
// with Parakeet (--model v2|v3|ultra) and reports how long after the speaker stopped the
// better text was ready.
//
// --trace call.jsonl (file or live mode) records a call trace for question-assembly
// calibration with spike-qa (docs/QUESTIONS.md): audio levels and every transcript
// result, no audio. On a recording this runs faster than real time:
//   spike-stt interview.wav --trace interview.jsonl
#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import Foundation
import JeevesCore
import Synchronization
import Transcription

let flags = CommandLineFlags(switches: ["live", "help", "partials", "finalize-on-silence"])
if flags.has("help") {
    print("usage: spike-stt <file.wav> | --live --browser chrome [--strategy pids|system|bundle] [--seconds 120] [--mode fast|accurate] [--vocab a,b,c] [--partials] [--finalize-on-silence] [--silence-ms 400] [--speech-db -45] [--second-pass parakeet|parakeet-boost] [--model v2|v3|ultra] [--trace call.jsonl]")
    exit(0)
}

guard #available(macOS 26.0, *) else {
    print("spike-stt needs macOS 26 or later (SpeechAnalyzer).")
    exit(1)
}

let mode = TranscriberMode(rawValue: flags.string("mode", default: "fast")) ?? .fast
let vocabulary = flags.values["vocab"].map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
    ?? DomainVocabulary.anthropic

/// A call trace writer for --trace, if given.
func makeTrace(path: String?, source: String, name: String, engine: String) -> CallTraceWriter? {
    guard let path else { return nil }
    do {
        return try CallTraceWriter(url: URL(fileURLWithPath: path),
                                   header: .init(source: source, name: name, engine: engine,
                                                 created: ISO8601DateFormatter().string(from: Date())))
    } catch {
        FileHandle.standardError.write(Data("cannot write trace \(path): \(error)\n".utf8))
        exit(2)
    }
}

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
    let aliases = AliasTable.anthropic

    // Optional Parakeet second pass, loaded before capture starts so loading is not timed.
    let secondPass: ParakeetTranscriber?
    if let choice = flags.values["second-pass"] {
        guard choice == "parakeet" || choice == "parakeet-boost",
              let model = ParakeetModel(rawValue: flags.string("model", default: "v2")) else {
            log("--second-pass takes parakeet or parakeet-boost; --model takes v2, v3 or ultra")
            exit(2)
        }
        guard session.audioFormat.sampleRate == 16_000 else {
            log("second pass needs 16 kHz audio; SpeechAnalyzer chose \(session.audioFormat.sampleRate) Hz")
            exit(2)
        }
        log("loading Parakeet \(model.rawValue)\(choice == "parakeet-boost" ? " with vocabulary boosting" : "")...")
        let boostTerms = choice == "parakeet-boost"
            ? ParakeetTranscriber.vocabulary(terms: vocabulary, aliases: aliases) : []
        secondPass = try await ParakeetTranscriber.load(model: model, vocabulary: boostTerms)
    } else {
        secondPass = nil
    }
    let ring = secondPass == nil ? nil : AudioRing(sampleRate: 16_000, capacitySeconds: 60)

    // Supervised capture: survives new browser processes and output-device changes,
    // and fills restart gaps with silence so result timestamps stay aligned.
    let capture = CaptureSession(browser: browser, strategy: strategy, outputFormat: session.audioFormat)
    let events = capture.start()
    let audioStart = MonotonicClock.now()
    let showPartials = flags.has("partials")

    let finalizeOnSilence = flags.has("finalize-on-silence")
    let silenceMs = flags.double("silence-ms", default: 400)
    let speechDB = Float(flags.double("speech-db", default: -45))
    let sampleRate = session.audioFormat.sampleRate
    let endpoints = EndpointLog()
    let trace = makeTrace(path: flags.values["trace"], source: "live", name: browser.rawValue, engine: "SpeechAnalyzer \(mode.rawValue)")

    // Feed audio and detect ends of speech on one task; read results on another.
    let feeder = Task.detached {
        var endpointer = SilenceEndpointer(speechThresholdDecibels: speechDB, silenceDuration: silenceMs / 1000)
        var peak: Float = -160
        var nextHeartbeat = 10.0
        for await event in events {
            guard case .audio(let chunk) = event else {
                if case .status(let status) = event { print("  [capture] \(status)") }
                continue
            }
            session.feed(chunk.buffer)
            ring?.append(chunk.buffer.floatSamples)
            peak = max(peak, chunk.rmsDecibels)
            let duration = Double(chunk.buffer.frameLength) / sampleRate
            trace?.audio(levelDecibels: chunk.rmsDecibels, duration: duration)
            if let end = endpointer.process(levelDecibels: chunk.rmsDecibels, duration: duration, capturedAt: chunk.capturedAt) {
                let provisional = endpoints.speechEnded(end)
                print("  >> at \(Int(silenceMs)) ms of silence: \(aliases.apply(to: provisional))")
                if let secondPass, let ring {
                    // The utterance with a little context either side.
                    let clip = ring.clip(from: end.speechStart - 0.3, to: end.audioTime + 0.25)
                    Task {
                        do {
                            let result = try await secondPass.transcribe(clip)
                            let after = MonotonicClock.milliseconds(from: end.wallTime, to: MonotonicClock.now())
                            endpoints.secondPassDone(latencyMs: after, processingMs: result.processingMs)
                            print(String(format: "  >> second pass +%.0f ms after speech ended (%.0f ms to transcribe %.1f s): %@",
                                         after, result.processingMs, result.audioSeconds, aliases.apply(to: result.bestText)))
                        } catch {
                            print("  >> second pass failed: \(error)")
                        }
                    }
                }
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
            trace?.update(update, at: MonotonicClock.milliseconds(from: audioStart, to: update.receivedAt) / 1000)
            for comparison in endpoints.resultArrived(update) where !comparison.identical {
                print(String(format: "  << final differs from the provisional text (%.0f%% WER): %@",
                             comparison.wordErrorRate.rate * 100, comparison.final))
            }
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
    capture.stop()
    feeder.cancel()
    try await session.finish()
    let (finals, partials) = try await reader.value
    trace?.close()
    let matcher = endpoints.snapshot
    let comparisons = endpoints.comparisons
    let identical = comparisons.filter(\.identical).count
    let meanWER = comparisons.isEmpty ? 0 : comparisons.map(\.wordErrorRate.rate).reduce(0, +) / Double(comparisons.count)
    let secondPassStats = endpoints.secondPassStats
    print("""

    live summary  mode=\(mode.rawValue) browser=\(browser.rawValue) strategy=\(strategy.rawValue) finalize-on-silence=\(finalizeOnSilence ? "on" : "off")
      final lag           \(LatencyStats(finals)?.summary ?? "no finals: was anyone talking?")
      partial lag         \(LatencyStats(partials)?.summary ?? "-")
      speech end to final \(LatencyStats(matcher.latenciesMs)?.summary ?? "no matched speech ends")
      speech ends         \(matcher.detected) detected (silence \(Int(silenceMs)) ms, speech above \(Int(speechDB)) dBFS); \(matcher.latenciesMs.count) matched, \(matcher.merged) merged into longer finals, \(matcher.unmatched) never finalized
      partial vs final    \(comparisons.count) utterances compared, \(identical) identical (\(comparisons.isEmpty ? 0 : identical * 100 / comparisons.count)%), mean WER of provisional vs final \(String(format: "%.1f", meanWER * 100))%
      second pass         \(secondPass == nil ? "off" : "after speech ended \(LatencyStats(secondPassStats.latencies)?.summary ?? "-"); transcribing \(LatencyStats(secondPassStats.processing)?.summary ?? "-")")
      finalize errors     \(endpoints.finalizeErrors)
      capture             \(capture.statistics.discontinuities) gaps, \(capture.statistics.restarts.count) restarts, \(String(format: "%.2f", capture.statistics.silenceFilledSeconds)) s silence filled

    "speech end to final" includes the \(Int(silenceMs)) ms silence wait when finalize-on-silence is on.
    Partial text is usable at the silence threshold itself, so compare against \(Int(silenceMs)) ms.
    """)
} else {
    guard let path = flags.positional.first else {
        log("pass a WAV file, or --live; see --help")
        exit(2)
    }
    let start = MonotonicClock.now()
    let trace = makeTrace(path: flags.values["trace"], source: "file", name: URL(fileURLWithPath: path).lastPathComponent,
                          engine: "SpeechAnalyzer \(mode.rawValue)")
    let reader = Task {
        var finals: [TranscriptUpdate] = []
        var firstFinalMs: Double?
        for try await update in session.updates {
            // A file is transcribed faster than real time, so record each result as
            // available when its audio ends, as if it had been live with no lag.
            trace?.update(update, at: update.audioEnd)
            guard update.isFinal else { continue }
            if firstFinalMs == nil { firstFinalMs = MonotonicClock.millisecondsSince(start) }
            finals.append(update)
            print(String(format: "[%7.2f-%7.2f] %@", update.audioStart, update.audioEnd, update.text))
        }
        return (finals, firstFinalMs)
    }
    let audioSeconds = try feedFile(URL(fileURLWithPath: path), to: session) { buffer in
        trace?.audio(levelDecibels: buffer.rmsDecibels, duration: Double(buffer.frameLength) / buffer.format.sampleRate)
    }
    try await session.finish()
    let (finals, firstFinalMs) = try await reader.value
    trace?.close()
    if let trace { print("trace written to \(trace.url.path); replay it with spike-qa (docs/QUESTIONS.md)") }
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
    private let state = Mutex((matcher: FinalLatencyMatcher(), finalizeErrors: 0, tracker: UtteranceTracker(),
                               secondPassLatencies: [Double](), secondPassProcessing: [Double]()))

    /// Records an end of speech; returns the provisional text Jeeves would act on.
    func speechEnded(_ end: SilenceEndpointer.EndOfSpeech) -> String {
        state.withLock {
            $0.matcher.speechEnded(end)
            return $0.tracker.speechEnded(end)
        }
    }
    func resultArrived(_ update: TranscriptUpdate) -> [UtteranceTracker.Comparison] {
        state.withLock { $0.tracker.update(update) }
    }
    func secondPassDone(latencyMs: Double, processingMs: Double) {
        state.withLock {
            $0.secondPassLatencies.append(latencyMs)
            $0.secondPassProcessing.append(processingMs)
        }
    }
    var comparisons: [UtteranceTracker.Comparison] { state.withLock { $0.tracker.comparisons } }
    var secondPassStats: (latencies: [Double], processing: [Double]) {
        state.withLock { ($0.secondPassLatencies, $0.secondPassProcessing) }
    }
    func finalArrived(audioEnd: Double, at time: UInt64) -> [Double] {
        state.withLock { $0.matcher.finalArrived(audioEnd: audioEnd, at: time) }
    }
    func finalizeFailed() { state.withLock { $0.finalizeErrors += 1 } }
    var detectedCount: Int { state.withLock { $0.matcher.detected } }
    var finalizeErrors: Int { state.withLock { $0.finalizeErrors } }
    var snapshot: FinalLatencyMatcher { state.withLock { $0.matcher } }
}

/// The last `capacitySeconds` of fed audio, addressable by session audio time, so an
/// utterance can be cut out and re-transcribed.
final class AudioRing: Sendable {
    let sampleRate: Double
    let capacitySeconds: Double
    private let state = Mutex((samples: [Float](), startSeconds: 0.0))

    init(sampleRate: Double, capacitySeconds: Double) {
        self.sampleRate = sampleRate
        self.capacitySeconds = capacitySeconds
    }

    func append(_ samples: [Float]) {
        let rate = sampleRate, capacity = Int(capacitySeconds * sampleRate)
        state.withLock { ring in
            ring.samples += samples
            // Trim in large steps so appends stay cheap.
            let excess = ring.samples.count - capacity
            if excess > Int(10 * rate) {
                ring.samples.removeFirst(excess)
                ring.startSeconds += Double(excess) / rate
            }
        }
    }

    func clip(from start: Double, to end: Double) -> [Float] {
        let rate = sampleRate
        return state.withLock { ring in
            let lower = max(0, Int(((start - ring.startSeconds) * rate).rounded()))
            let upper = min(ring.samples.count, Int(((end - ring.startSeconds) * rate).rounded()))
            return lower < upper ? Array(ring.samples[lower..<upper]) : []
        }
    }
}
#else
print("spike-stt needs macOS 26 or later (SpeechAnalyzer).")
#endif

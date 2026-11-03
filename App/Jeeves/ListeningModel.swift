import AudioCapture
@preconcurrency import AVFoundation
import Foundation
import JeevesCore
import Observation
import Transcription

/// Owns one listening session: browser tap -> SpeechAnalyzer -> transcript, and at
/// each end of speech (400 ms of silence by default) hands the provisional utterance to
/// question assembly, which detects questions over the whole turn and keeps their
/// lead-in (docs/QUESTIONS.md). With "Save call traces" on, the session is recorded
/// for offline calibration with spike-qa.
@MainActor
@Observable
final class ListeningModel {
    enum Phase: Equatable {
        case idle
        case starting
        case listening
        case failed(String)
    }

    var phase: Phase = .idle
    var browser: Browser = .chrome
    var strategy: TapStrategy = .processes
    var levelDecibels: Float = -160
    var partial = ""
    var finals: [String] = []
    /// The capture supervisor's latest status ("capturing 12 processes, output: AirPods").
    var captureStatus = ""
    private(set) var finalLags: [Double] = []
    /// The most recent utterance, for "Answer last" when detection missed a question.
    private(set) var lastUtterance = ""
    /// The last utterance detection judged a question, and why (shown under the transcript).
    private(set) var lastDetection: String?

    /// Called with each detected question, and again when a follow-up revises it.
    var onQuestion: (@MainActor (QuestionAssembler.Event) -> Void)?

    /// Question assembly settings (Settings > Question detection), saved across launches.
    var assembly: QuestionAssembler.Settings {
        didSet {
            assembler.settings = assembly
            if let data = try? JSONEncoder().encode(assembly) { UserDefaults.standard.set(data, forKey: "questionAssembly") }
        }
    }
    /// Silence that ends an utterance, in milliseconds. Applies from the next start.
    var silenceMs: Double {
        didSet { UserDefaults.standard.set(silenceMs, forKey: "silenceMs") }
    }
    /// Record each session to AppPaths.traces for spike-qa.
    var saveTraces: Bool {
        didSet { UserDefaults.standard.set(saveTraces, forKey: "saveTraces") }
    }
    private(set) var lastTraceURL: URL?

    private var tracker = UtteranceTracker()
    private var assembler = QuestionAssembler()
    private var trace: CallTraceWriter?
    private var audioStart: UInt64 = 0
    /// Session audio time the current stretch of speech started, while someone talks.
    private var speechStart: Double?

    init() {
        let stored = UserDefaults.standard.data(forKey: "questionAssembly")
            .flatMap { try? JSONDecoder().decode(QuestionAssembler.Settings.self, from: $0) }
        assembly = stored ?? QuestionAssembler.Settings()
        silenceMs = UserDefaults.standard.object(forKey: "silenceMs") as? Double ?? 400
        saveTraces = UserDefaults.standard.bool(forKey: "saveTraces")
        assembler = QuestionAssembler(settings: assembly)
    }

    private var capture: CaptureSession?
    private var session: SpeechAnalyzerSession?
    private var runTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?

    var isRunning: Bool { phase == .starting || phase == .listening }

    var statusText: String {
        switch phase {
        case .idle: "Idle"
        case .starting: "Starting..."
        case .listening: "Listening to \(browser.rawValue.capitalized)"
        case .failed(let message): message
        }
    }

    /// p50/p95 of how far final results trail live audio (latency budget: 500 ms).
    var lagSummary: String? {
        LatencyStats(finalLags).map { "final lag p50 \(Int($0.p50)) ms, p95 \(Int($0.p95)) ms (n=\($0.count))" }
    }

    func start() {
        guard !isRunning else { return }
        phase = .starting
        partial = ""
        finals = []
        finalLags = []
        captureStatus = ""
        lastUtterance = ""
        lastDetection = nil
        tracker = UtteranceTracker()
        assembler = QuestionAssembler(settings: assembly)
        speechStart = nil
        runTask = Task { await run() }
    }

    func stop() {
        capture?.stop()
        capture = nil
        feedTask?.cancel()
        feedTask = nil
        let session = self.session
        self.session = nil
        Task { try? await session?.finish() }
        runTask?.cancel()
        runTask = nil
        trace?.close()
        trace = nil
        levelDecibels = -160
        if case .failed = phase { return }
        phase = .idle
    }

    private func run() async {
        do {
            let session = try await SpeechAnalyzerSession.start(mode: .fast, contextualStrings: DomainVocabulary.anthropic)
            // The supervisor follows the browser's processes and output-device changes,
            // and fills restart gaps with silence so result timestamps stay aligned.
            let capture = CaptureSession(browser: browser, strategy: strategy, outputFormat: session.audioFormat)
            let events = capture.start()
            self.session = session
            self.capture = capture
            phase = .listening
            let audioStart = MonotonicClock.now()
            self.audioStart = audioStart
            let silence = silenceMs / 1000
            if saveTraces { startTrace(silence: silence) }
            let trace = self.trace

            // Feed audio off the main actor; publish the level at most 10 times a second.
            feedTask = Task.detached { [weak self] in
                var lastLevel: UInt64 = 0
                // Runs on the same chunks the speech engine gets, so its audio clock
                // matches the transcript's timestamps.
                var endpointer = SilenceEndpointer(silenceDuration: silence)
                var speaking = false
                for await event in events {
                    switch event {
                    case .audio(let chunk):
                        session.feed(chunk.buffer)
                        let sampleRate = chunk.buffer.format.sampleRate
                        let duration = sampleRate > 0 ? Double(chunk.buffer.frameLength) / sampleRate : 0
                        trace?.audio(levelDecibels: chunk.rmsDecibels, duration: duration)
                        if let end = endpointer.process(levelDecibels: chunk.rmsDecibels, duration: duration,
                                                        capturedAt: chunk.capturedAt) {
                            speaking = false
                            await MainActor.run { self?.speechEnded(end) }
                        }
                        if !speaking, let start = endpointer.currentSpeechStart {
                            speaking = true
                            await MainActor.run { self?.speechStart = start }
                        }
                        if chunk.capturedAt &- lastLevel > 100_000_000 {
                            lastLevel = chunk.capturedAt
                            let level = chunk.rmsDecibels
                            await MainActor.run { self?.levelDecibels = level }
                        }
                    case .status(let status):
                        let text = status.description
                        await MainActor.run { self?.captureStatus = text }
                    }
                }
            }

            for try await update in session.updates {
                trace?.update(update, at: MonotonicClock.milliseconds(from: audioStart, to: update.receivedAt) / 1000)
                for comparison in tracker.update(update) {
                    handle(assembler.utteranceFinalized(.init(text: comparison.final, start: comparison.speechStart,
                                                              end: comparison.audioEnd)))
                }
                // A reply that starts with no pause ends the question mid-speech.
                if let start = speechStart {
                    let now = MonotonicClock.milliseconds(from: audioStart, to: update.receivedAt) / 1000
                    handle(assembler.speechInProgress(.init(text: tracker.provisionalText(from: start), start: start, end: now)))
                }
                if update.isFinal {
                    finals.append(update.text)
                    if finals.count > 200 { finals.removeFirst(finals.count - 200) }
                    partial = ""
                    finalLags.append(MonotonicClock.milliseconds(from: audioStart, to: update.receivedAt) - update.audioEnd * 1000)
                } else {
                    partial = update.text
                }
            }
        } catch is CancellationError {
            return
        } catch {
            phase = .failed("\(error)")
            stop()
        }
    }
}

extension ListeningModel {
    /// The last minute or so of the call, for the answer prompt's context.
    func recentTranscript() -> String {
        (finals.suffix(8) + (partial.isEmpty ? [] : [partial])).joined(separator: " ")
    }

    /// The latest utterance with the turn before it, for "Answer last".
    var lastTurn: (leadIn: String, utterance: String)? { assembler.lastTurn }

    fileprivate func speechEnded(_ end: SilenceEndpointer.EndOfSpeech) {
        speechStart = nil
        let utterance = tracker.speechEnded(end)
        guard !utterance.isEmpty else { return }
        lastUtterance = utterance
        handle(assembler.utteranceEnded(.init(text: utterance, start: end.speechStart, end: end.audioTime)))
    }

    private func handle(_ event: QuestionAssembler.Event?) {
        guard let event else { return }
        let question = event.question
        let label = question.revision > 0 ? "Follow-up" : "Question"
        lastDetection = "\(label) (\(question.reason.rawValue)): \(question.text)"
        trace?.question(question.text, reason: question.reason.rawValue,
                        at: MonotonicClock.millisecondsSince(audioStart) / 1000)
        onQuestion?(event)
    }

    private func startTrace(silence: Double) {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        let url = AppPaths.traces.appendingPathComponent("call-\(formatter.string(from: Date())).jsonl")
        let settings: [String: Double] = [
            "silence": silence, "leadInGap": assembly.leadInGap, "leadInSeconds": assembly.leadInSeconds,
            "leadInWords": Double(assembly.leadInWords), "followUpWindow": assembly.followUpWindow,
        ]
        trace = try? CallTraceWriter(url: url, header: .init(source: "live", name: browser.rawValue,
                                                            engine: "SpeechAnalyzer fast",
                                                            created: ISO8601DateFormatter().string(from: Date()),
                                                            settings: settings))
        lastTraceURL = trace?.url
    }
}

extension TapStrategy {
    var label: String {
        switch self {
        case .processes: "Browser processes (recommended)"
        case .system: "All system audio"
        case .bundleIDs: "Bundle ID (experimental)"
        }
    }
}

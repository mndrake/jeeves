import AudioCapture
@preconcurrency import AVFoundation
import Foundation
import JeevesCore
import Observation
import Transcription

/// Owns one listening session: browser tap -> SpeechAnalyzer -> transcript, and at
/// each end of speech (400 ms of silence) hands the provisional utterance to question
/// detection (docs/prd/03).
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

    /// Called with each detected question.
    var onQuestion: (@MainActor (String) -> Void)?

    private var tracker = UtteranceTracker()
    private let detector = QuestionDetector()

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

            // Feed audio off the main actor; publish the level at most 10 times a second.
            feedTask = Task.detached { [weak self] in
                var lastLevel: UInt64 = 0
                // Runs on the same chunks the speech engine gets, so its audio clock
                // matches the transcript's timestamps.
                var endpointer = SilenceEndpointer()
                for await event in events {
                    switch event {
                    case .audio(let chunk):
                        session.feed(chunk.buffer)
                        let sampleRate = chunk.buffer.format.sampleRate
                        let duration = sampleRate > 0 ? Double(chunk.buffer.frameLength) / sampleRate : 0
                        if let end = endpointer.process(levelDecibels: chunk.rmsDecibels, duration: duration,
                                                        capturedAt: chunk.capturedAt) {
                            await MainActor.run { self?.speechEnded(end) }
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
                tracker.update(update)
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

    fileprivate func speechEnded(_ end: SilenceEndpointer.EndOfSpeech) {
        let utterance = tracker.speechEnded(end)
        guard !utterance.isEmpty else { return }
        lastUtterance = utterance
        if let detection = detector.detect(utterance) {
            lastDetection = "Question (\(detection.reason.rawValue)): \(detection.question)"
            onQuestion?(detection.question)
        }
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

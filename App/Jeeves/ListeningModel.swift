import AudioCapture
import Foundation
import JeevesCore
import Observation
import Transcription

/// Owns one listening session: browser tap -> SpeechAnalyzer -> transcript.
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
    private(set) var finalLags: [Double] = []

    private var tap: ProcessTap?
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
        runTask = Task { await run() }
    }

    func stop() {
        tap?.stop()
        tap = nil
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
            let target = try ProcessTap.target(for: browser, strategy: strategy)
            let tap = ProcessTap(target: target, outputFormat: session.audioFormat)
            let chunks = try tap.start()
            self.session = session
            self.tap = tap
            phase = .listening
            let audioStart = MonotonicClock.now()

            // Feed audio off the main actor; publish the level at most 10 times a second.
            feedTask = Task.detached { [weak self] in
                var lastLevel: UInt64 = 0
                for await chunk in chunks {
                    session.feed(chunk.buffer)
                    if chunk.capturedAt &- lastLevel > 100_000_000 {
                        lastLevel = chunk.capturedAt
                        let level = chunk.rmsDecibels
                        await MainActor.run { self?.levelDecibels = level }
                    }
                }
            }

            for try await update in session.updates {
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

extension TapStrategy {
    var label: String {
        switch self {
        case .processes: "Browser processes (recommended)"
        case .system: "All system audio"
        case .bundleIDs: "Bundle ID (experimental)"
        }
    }
}

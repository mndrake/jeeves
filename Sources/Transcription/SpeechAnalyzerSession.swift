#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import CoreMedia
import Foundation
import JeevesCore
import Speech

public enum TranscriptionError: Error, CustomStringConvertible {
    case unsupportedLocale(Locale)
    case unavailable
    case noAudioFormat

    public var description: String {
        switch self {
        case .unsupportedLocale(let locale): "SpeechTranscriber does not support \(locale.identifier)"
        case .unavailable: "SpeechTranscriber is not available on this Mac"
        case .noAudioFormat: "no audio format is compatible with the installed speech assets"
        }
    }
}

/// Result-delivery configurations compared in the M2 shoot-out.
public enum TranscriberMode: String, CaseIterable, Sendable {
    /// Volatile + fast results (Apple's `timeIndexedProgressiveTranscription` preset).
    case fast
    /// Volatile results without the fast-results bias: slower partials, better finals.
    case accurate
}

/// One live transcription session on Apple's on-device SpeechAnalyzer (macOS 26).
///
/// Feed buffers in `audioFormat` with `feed(_:)` (safe from the tap's IO queue),
/// read `updates`, and call `finish()` at the end.
@available(macOS 26.0, *)
public final class SpeechAnalyzerSession: @unchecked Sendable {
    public let locale: Locale
    /// The format `feed(_:)` expects. Create the tap with this as its output format.
    public let audioFormat: AVAudioFormat
    public let updates: AsyncThrowingStream<TranscriptUpdate, Error>

    private let analyzer: SpeechAnalyzer
    private let transcriber: SpeechTranscriber
    private let input: AsyncStream<AnalyzerInput>.Continuation
    private let resultsTask: Task<Void, Never>

    /// Resolves the locale, installs speech assets if needed (may download once), and
    /// starts the analyzer so the first buffer is transcribed without warm-up delay.
    ///
    /// - Parameter contextualStrings: vocabulary hints (product names, API terms).
    public static func start(locale requested: Locale = Locale(identifier: "en-US"),
                             mode: TranscriberMode = .fast,
                             contextualStrings: [String] = []) async throws -> SpeechAnalyzerSession {
        guard SpeechTranscriber.isAvailable else { throw TranscriptionError.unavailable }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) else {
            throw TranscriptionError.unsupportedLocale(requested)
        }
        let reporting: Set<SpeechTranscriber.ReportingOption> = mode == .fast ? [.volatileResults, .fastResults] : [.volatileResults]
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: reporting,
                                            attributeOptions: [.audioTimeRange])

        if await AssetInventory.status(forModules: [transcriber]) != .installed,
           let installation = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            log("downloading speech assets for \(locale.identifier)...")
            try await installation.downloadAndInstall()
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw TranscriptionError.noAudioFormat
        }

        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = contextualStrings
            try await analyzer.setContext(context)
        }
        try await analyzer.prepareToAnalyze(in: format)

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: inputStream)
        return SpeechAnalyzerSession(locale: locale, format: format, analyzer: analyzer,
                                     transcriber: transcriber, input: inputContinuation)
    }

    private init(locale: Locale, format: AVAudioFormat, analyzer: SpeechAnalyzer,
                 transcriber: SpeechTranscriber, input: AsyncStream<AnalyzerInput>.Continuation) {
        self.locale = locale
        self.audioFormat = format
        self.analyzer = analyzer
        self.transcriber = transcriber
        self.input = input

        let (updates, continuation) = AsyncThrowingStream.makeStream(of: TranscriptUpdate.self)
        self.updates = updates
        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let range = result.range
                    continuation.yield(TranscriptUpdate(
                        // Segments after the first start with a space; consumers join segments themselves.
                        text: String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines),
                        isFinal: result.isFinal,
                        audioStart: range.start.seconds.isFinite ? range.start.seconds : 0,
                        audioEnd: range.end.seconds.isFinite ? range.end.seconds : 0,
                        receivedAt: MonotonicClock.now()))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    /// Queues audio for analysis. The buffer must be in `audioFormat`.
    public func feed(_ buffer: AVAudioPCMBuffer) {
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Forces final results for all audio up to `seconds` of session audio time (nil:
    /// everything consumed so far), instead of waiting for the engine's own end-of-
    /// utterance decision. Waits until that audio has been consumed.
    public func finalize(throughSeconds seconds: Double?) async throws {
        let time = seconds.map { CMTime(seconds: $0, preferredTimescale: CMTimeScale(audioFormat.sampleRate.rounded())) }
        try await analyzer.finalize(through: time)
    }

    /// Ends input, finalizes pending volatile results, and ends `updates`.
    public func finish() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        await resultsTask.value
    }

    /// Stops immediately, discarding pending results.
    public func cancel() async {
        input.finish()
        await analyzer.cancelAndFinishNow()
        resultsTask.cancel()
    }
}

/// Reads an audio file and feeds it to a session as fast as the analyzer accepts it.
/// Used for the offline shoot-out (word error rate, real-time factor).
@available(macOS 26.0, *)
public func feedFile(_ url: URL, to session: SpeechAnalyzerSession, chunkFrames: AVAudioFrameCount = 4_096) throws -> Double {
    let file = try AVAudioFile(forReading: url)
    let converter = try PCMConverter(from: file.processingFormat, to: session.audioFormat)
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunkFrames) else {
        throw TranscriptionError.noAudioFormat
    }
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: chunkFrames)
        if buffer.frameLength == 0 { break }
        if let converted = try converter.convert(buffer) { session.feed(converted) }
    }
    return Double(file.length) / file.processingFormat.sampleRate
}
#endif

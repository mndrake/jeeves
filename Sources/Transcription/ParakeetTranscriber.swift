#if os(macOS)
@preconcurrency import AVFoundation
import AudioCapture
import FluidAudio
import Foundation
import JeevesCore

/// Parakeet model variants worth comparing for Jeeves (FluidAudio 0.18 names).
public enum ParakeetModel: String, CaseIterable, Sendable {
    /// English-only Parakeet TDT 0.6B v2: FluidAudio's "highest recall" English model.
    case v2
    /// Multilingual v3, FluidAudio's library default.
    case v3
    /// Parakeet Ultra: post-trained v3, FluidAudio's recommended multilingual model.
    case ultra

    var version: AsrModelVersion {
        switch self {
        case .v2: .v2
        case .v3: .v3
        case .ultra: .ultra
        }
    }
}

public struct ParakeetResult: Sendable {
    public let text: String
    /// Text after CTC vocabulary boosting, when boosting changed something.
    public let boostedText: String?
    public let audioSeconds: Double
    public let processingMs: Double

    public var bestText: String { boostedText ?? text }
}

/// Batch Parakeet transcription through FluidAudio, used two ways in M2: whole files for
/// the engine comparison (`spike-asr`), and single utterances as a second pass after
/// SpeechAnalyzer's fast partials (`spike-stt --second-pass`).
///
/// Optional vocabulary boosting rescans the audio with a small CTC model for listed terms
/// (and their misheard aliases) and corrects the transcript when they are present.
public actor ParakeetTranscriber {
    public nonisolated let model: ParakeetModel
    public nonisolated let boostingTerms: Int
    private let asr: AsrManager
    private let boosting: VocabularyBoostingSession?
    private let decoderLayers: Int

    /// Downloads models on first use (Parakeet about 0.5 GB; the boosting model about
    /// 100 MB), then loads them. Later calls load from FluidAudio's cache.
    public static func load(model: ParakeetModel = .v2,
                            vocabulary: [CustomVocabularyTerm] = []) async throws -> ParakeetTranscriber {
        let models = try await AsrModels.downloadAndLoad(version: model.version)
        let asr = AsrManager()
        try await asr.loadModels(models)
        var boosting: VocabularyBoostingSession?
        if !vocabulary.isEmpty {
            let ctcModels = try await CtcModels.downloadAndLoad(variant: .ctc110m)
            boosting = try await VocabularyBoostingSession(vocabulary: CustomVocabularyContext(terms: vocabulary),
                                                           ctcModels: ctcModels)
        }
        let layers = await asr.decoderLayerCount
        return ParakeetTranscriber(model: model, asr: asr, boosting: boosting, decoderLayers: layers,
                                   boostingTerms: boosting?.vocabulary.terms.count ?? 0)
    }

    private init(model: ParakeetModel, asr: AsrManager, boosting: VocabularyBoostingSession?,
                 decoderLayers: Int, boostingTerms: Int) {
        self.model = model
        self.asr = asr
        self.boosting = boosting
        self.decoderLayers = decoderLayers
        self.boostingTerms = boostingTerms
    }

    /// Transcribes 16 kHz mono samples in one pass.
    public func transcribe(_ samples: [Float]) async throws -> ParakeetResult {
        let start = MonotonicClock.now()
        var state = TdtDecoderState.make(decoderLayers: decoderLayers)
        let result = try await asr.transcribe(samples, decoderState: &state)
        var boosted: String?
        if let boosting,
           let output = await boosting.rescore(text: result.text, tokenTimings: result.tokenTimings ?? [], audioSamples: samples),
           output.wasModified {
            boosted = output.text
        }
        return ParakeetResult(text: result.text, boostedText: boosted, audioSeconds: Double(samples.count) / 16_000,
                              processingMs: MonotonicClock.millisecondsSince(start))
    }

    /// Vocabulary terms from a term list, with aliases from an alias table attached to the
    /// matching canonical terms.
    public static func vocabulary(terms: [String], aliases: AliasTable) -> [CustomVocabularyTerm] {
        var aliasesByTerm: [String: [String]] = [:]
        for entry in aliases.entries { aliasesByTerm[entry.canonical.lowercased(), default: []] += entry.aliases }
        var seen = Set<String>()
        let all = terms + aliases.entries.map(\.canonical)
        return all.compactMap { term in
            guard seen.insert(term.lowercased()).inserted else { return nil }
            let termAliases = aliasesByTerm[term.lowercased()]
            return CustomVocabularyTerm(text: term, aliases: termAliases)
        }
    }
}

/// Reads an audio file of any format as 16 kHz mono Float32 samples.
public func readSamples16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let converter = try PCMConverter(from: file.processingFormat, to: target)
    let chunk: AVAudioFrameCount = 16_384
    guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return [] }
    var samples: [Float] = []
    samples.reserveCapacity(Int(Double(file.length) * 16_000 / file.processingFormat.sampleRate) + 1024)
    while file.framePosition < file.length {
        try file.read(into: buffer, frameCount: chunk)
        if buffer.frameLength == 0 { break }
        if let converted = try converter.convert(buffer) { samples += converted.floatSamples }
    }
    return samples
}

extension AVAudioPCMBuffer {
    /// Channel 0 as Float32 samples (Int16 buffers are scaled to -1...1).
    public var floatSamples: [Float] {
        let frames = Int(frameLength)
        if let data = floatChannelData?[0] { return Array(UnsafeBufferPointer(start: data, count: frames)) }
        if let data = int16ChannelData?[0] { return (0..<frames).map { Float(data[$0]) / 32_768 } }
        return []
    }
}
#endif

// M2 speech-engine comparison on audio files: word error rate, domain-term recall, speed.
//
//   spike-asr <file.wav ...> [--reference ref.txt] [--terms terms.txt]
//             [--engines apple,parakeet,parakeet-boost] [--model v2|v3|ultra] [--out results.json]
//
// Each file needs a reference transcript: --reference, or a .txt with the same name next
// to the audio. Engines:
//   apple            Apple SpeechAnalyzer (fast mode), with the terms as contextual strings
//   apple-accurate   SpeechAnalyzer without the fast-results bias
//   parakeet         FluidAudio Parakeet (--model, default v2 English), one batch pass
//   parakeet-boost   Parakeet plus CTC vocabulary boosting for the terms and known aliases
// Every engine is also scored after the alias table ("cloud code" -> "Claude Code").
// First use downloads Parakeet (about 0.5 GB) and the boosting model (about 100 MB).
#if os(macOS)
import AudioCapture
import Foundation
import JeevesCore
import Transcription

let flags = CommandLineFlags(switches: ["help"])
if flags.has("help") || flags.positional.isEmpty {
    print("usage: spike-asr <file.wav ...> [--reference ref.txt] [--terms terms.txt] [--engines apple,apple-accurate,parakeet,parakeet-boost] [--model v2|v3|ultra] [--out results.json]")
    exit(flags.has("help") ? 0 : 2)
}
guard #available(macOS 26.0, *) else {
    print("spike-asr needs macOS 26 or later.")
    exit(1)
}

let engines = flags.string("engines", default: "apple,parakeet,parakeet-boost").split(separator: ",").map(String.init)
guard let model = ParakeetModel(rawValue: flags.string("model", default: "v2")) else {
    log("unknown --model; use v2, v3 or ultra")
    exit(2)
}
let terms: [String] = try flags.values["terms"].map { path in
    try String(contentsOfFile: path, encoding: .utf8).split(whereSeparator: \.isNewline)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
} ?? DomainVocabulary.anthropic
let aliases = AliasTable.anthropic

struct Row: Codable {
    var file: String
    var engine: String
    var referenceWords: Int
    var wer: Double
    var substitutions: Int
    var deletions: Int
    var insertions: Int
    var termsFound: Int
    var termsExpected: Int
    var missedTerms: [String]
    var audioSeconds: Double
    var processingSeconds: Double
    var text: String
}

@MainActor func transcribeWithApple(_ url: URL, mode: TranscriberMode) async throws -> String {
    let session = try await SpeechAnalyzerSession.start(mode: mode, contextualStrings: terms)
    let reader = Task {
        var finals: [String] = []
        for try await update in session.updates where update.isFinal { finals.append(update.text) }
        return finals
    }
    _ = try feedFile(url, to: session)
    try await session.finish()
    return try await reader.value.joined(separator: " ")
}

var parakeet: ParakeetTranscriber?
var parakeetBoost: ParakeetTranscriber?
var rows: [Row] = []

for path in flags.positional {
    let url = URL(fileURLWithPath: path)
    let referencePath = flags.values["reference"] ?? url.deletingPathExtension().appendingPathExtension("txt").path
    guard let reference = try? String(contentsOfFile: referencePath, encoding: .utf8) else {
        log("no reference transcript for \(path) (looked for \(referencePath)); skipping")
        continue
    }
    let samples = try readSamples16k(url)
    let audioSeconds = Double(samples.count) / 16_000
    log("\n\(url.lastPathComponent): \(String(format: "%.1f", audioSeconds)) s, \(TranscriptText.words(reference).count) reference words")

    for engine in engines {
        let start = MonotonicClock.now()
        let text: String
        switch engine {
        case "apple":
            text = try await transcribeWithApple(url, mode: .fast)
        case "apple-accurate":
            text = try await transcribeWithApple(url, mode: .accurate)
        case "parakeet":
            if parakeet == nil {
                log("loading Parakeet \(model.rawValue)...")
                parakeet = try await ParakeetTranscriber.load(model: model)
            }
            text = try await parakeet!.transcribe(samples).text
        case "parakeet-boost":
            if parakeetBoost == nil {
                log("loading Parakeet \(model.rawValue) with vocabulary boosting...")
                parakeetBoost = try await ParakeetTranscriber.load(
                    model: model, vocabulary: ParakeetTranscriber.vocabulary(terms: terms, aliases: aliases))
            }
            text = try await parakeetBoost!.transcribe(samples).bestText
        default:
            log("unknown engine \(engine); skipping")
            continue
        }
        let seconds = MonotonicClock.millisecondsSince(start) / 1000
        for (name, hypothesis) in [(engine, text), (engine + "+aliases", aliases.apply(to: text))] {
            let wer = WordErrorRate(reference: reference, hypothesis: hypothesis)
            let recall = TermRecall(terms: terms, reference: reference, hypothesis: hypothesis)
            rows.append(Row(file: url.lastPathComponent, engine: name, referenceWords: wer.referenceWords, wer: wer.rate,
                            substitutions: wer.substitutions, deletions: wer.deletions, insertions: wer.insertions,
                            termsFound: recall.found, termsExpected: recall.expected,
                            missedTerms: recall.misses.map { "\($0.term) \($0.found)/\($0.expected)" },
                            audioSeconds: audioSeconds, processingSeconds: seconds, text: hypothesis))
        }
        log("  \(engine): \(String(format: "%.2f", seconds)) s")
    }
}

func pad(_ text: String, _ width: Int) -> String { text.padding(toLength: max(width, text.count), withPad: " ", startingAt: 0) }

print("\n" + pad("file", 22) + pad("engine", 26) + pad("WER", 8) + pad("terms", 10) + pad("speed", 10) + "missed terms")
for row in rows {
    let speed = row.processingSeconds > 0 ? String(format: "%.0fx", row.audioSeconds / row.processingSeconds) : "-"
    print(pad(String(row.file.prefix(21)), 22) + pad(row.engine, 26) + pad(String(format: "%.1f%%", row.wer * 100), 8)
          + pad("\(row.termsFound)/\(row.termsExpected)", 10) + pad(speed, 10) + row.missedTerms.joined(separator: ", "))
}

print("\nTotals across files (WER weighted by reference words)")
var seen: [String] = []
for row in rows where !seen.contains(row.engine) { seen.append(row.engine) }
for engine in seen {
    let group = rows.filter { $0.engine == engine }
    let words = group.reduce(0) { $0 + $1.referenceWords }
    let errors = group.reduce(0) { $0 + $1.substitutions + $1.deletions + $1.insertions }
    let found = group.reduce(0) { $0 + $1.termsFound }, expected = group.reduce(0) { $0 + $1.termsExpected }
    print("  " + pad(engine, 26) + pad(String(format: "WER %.1f%%", words > 0 ? Double(errors) / Double(words) * 100 : 0), 12)
          + "terms \(found)/\(expected)")
}

if let out = flags.values["out"] {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(rows).write(to: URL(fileURLWithPath: out))
    log("wrote \(rows.count) rows (with full transcripts) to \(out)")
}
#else
print("spike-asr needs macOS 26 or later.")
#endif
